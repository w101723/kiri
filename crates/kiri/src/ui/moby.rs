//! Native macOS Kiri GUI backend for the one upstream Moby Docker Engine.
//! No requests to the obsolete Kiri daemon or its /kiri/* private endpoints.
//! All Docker state lives in dockerd, in ~/.kiri-moby/vm/data.img.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use crate::client;
use super::{Cmd, emit, menu_state, path_escape};

fn data_dir() -> io::Result<PathBuf> {
    if let Some(path) = std::env::var_os("KIRI_MOBY_DATA_DIR") {
        return Ok(PathBuf::from(path));
    }
    Ok(PathBuf::from(std::env::var_os("HOME").ok_or_else(|| io::Error::other("HOME not set"))?).join(".kiri-moby"))
}
fn shares_file() -> io::Result<PathBuf> {
    Ok(data_dir()?.join("authorized-shares.json"))
}
fn allowed_share(value: &str) -> bool {
    let path = Path::new(value);
    let clean = path.is_absolute()
        && (path.starts_with("/Users/") || path.starts_with("/Volumes/"))
        && !value.contains("//") && !value.contains("/./") && !value.contains(',')
        && path.components().all(|part| matches!(part,
            std::path::Component::RootDir | std::path::Component::Normal(_)));
    clean && path.components().count() >= 3
}
fn read_shares() -> io::Result<Vec<String>> {
    let path = shares_file()?;
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(err) => return Err(err),
    };
    let paths: Vec<String> = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    if paths.len() > 16 || paths.iter().any(|p| !allowed_share(p))
        || paths.iter().collect::<std::collections::BTreeSet<_>>().len() != paths.len()
    {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid authorized share config"));
    }
    Ok(paths)
}
fn save_shares(paths: &[String]) -> io::Result<()> {
    if paths.len() > 16 || paths.iter().any(|p| !allowed_share(p)) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid directory authorization"));
    }
    let dir = data_dir()?;
    fs::create_dir_all(&dir)?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    let path = shares_file()?;
    let tmp = path.with_extension("json.new");
    let payload = serde_json::to_vec(paths).map_err(io::Error::other)?;
    let mut file = OpenOptions::new().write(true).create_new(true).open(&tmp)?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
    file.write_all(&payload)?;
    file.sync_all()?;
    drop(file);
    fs::rename(&tmp, &path)
}
fn add_share(path: &str) -> io::Result<String> {
    if !allowed_share(path) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput,
            "share must be a project folder beneath /Users or /Volumes"));
    }
    if !Path::new(path).is_dir() {
        return Err(io::Error::new(io::ErrorKind::NotFound, "selected share directory is missing"));
    }
    let mut paths = read_shares()?;
    if paths.iter().any(|existing| existing == path) {
        return Ok("Directory already authorized".to_owned());
    }
    paths.push(path.to_owned());
    save_shares(&paths)?;
    Ok("Directory authorized. Apply changes by restarting the Moby VM.".to_owned())
}
fn remove_share(path: &str) -> io::Result<String> {
    let mut paths = read_shares()?;
    if !paths.iter().any(|p| p == path) { return Err(io::Error::other("share not found")); }
    paths.retain(|p| p != path);
    save_shares(&paths)?;
    Ok("Authorization removed. Restart the VM to revoke the current VirtioFS mapping.".to_owned())
}

fn resources() -> Option<PathBuf> {
    Some(std::env::current_exe().ok()?.parent()?.join("../Resources"))
}
fn socket_path() -> io::Result<PathBuf> { Ok(data_dir()?.join("run/docker.sock")) }
fn host_binary() -> io::Result<PathBuf> {
    let data = data_dir()?;
    for candidate in [resources().map(|r| r.join("bin/kiri-moby-host")), Some(data.join("bin/kiri-moby-host"))].into_iter().flatten() {
        if candidate.is_file() { return Ok(candidate); }
    }
    Err(io::Error::new(io::ErrorKind::NotFound,
        "Kiri Moby Host launcher missing: install the unified Moby app/host bundle"))
}

fn install_guest_assets(data: &Path) -> io::Result<()> {
    let dest = data.join("guest");
    fs::create_dir_all(&dest)?;
    fs::set_permissions(&dest, fs::Permissions::from_mode(0o700))?;
    let Some(assets) = resources().map(|r| r.join("guest")) else {
        return Ok(());
    };
    // Do not modify the VM's existing disk or mutate boot assets while it runs.
    // Upgrades of existing assets are handled offline by the verified
    // milestone installer, not by a running GUI.
    for file in ["Image", "initramfs.cpio", "data.img.tgz"] {
        let target = dest.join(file);
        if !target.is_file() && assets.join(file).is_file() {
            let staging = dest.join(format!(".{file}.new"));
            if staging.exists() {
                return Err(io::Error::new(io::ErrorKind::AlreadyExists,
                    format!("partial guest asset install at {}", staging.display())));
            }
            fs::copy(assets.join(file), &staging)?;
            fs::rename(&staging, &target)?;
        }
    }
    Ok(())
}

fn start_vm() -> io::Result<()> {
    if client::alive() { return Ok(()); }
    let data = data_dir()?;
    fs::create_dir_all(&data)?;
    fs::set_permissions(&data, fs::Permissions::from_mode(0o700))?;
    install_guest_assets(&data)?;
    let binary = host_binary()?;
    fs::create_dir_all(data.join("logs"))?;
    let logfile = data.join("logs/gui-host.log");
    let stdout = OpenOptions::new().create(true).append(true).open(&logfile)?;
    fs::set_permissions(&logfile, fs::Permissions::from_mode(0o600))?;
    let stderr = stdout.try_clone()?;
    let authorized_shares = read_shares()?;
    let mut child = Command::new(binary);
    child.env("KIRI_MOBY_DATA_DIR", &data);
    if !authorized_shares.is_empty() {
        child.env("KIRI_MOBY_SHARE_DIRS", authorized_shares.join(","));
    }
    child.stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .spawn()?;
    // Reopening the GUI leaves the same VM running; never create two engines.
    for _ in 0..160 {
        if client::alive() { return Ok(()); }
        thread::sleep(Duration::from_millis(250));
    }
    Err(io::Error::other(format!(
        "Moby VM did not become ready; see {}", logfile.display()
    )))
}

fn stop_vm() -> io::Result<()> {
    let control = data_dir()?.join("run/host-control.sock");
    let mut stream = UnixStream::connect(&control)
        .map_err(|e| io::Error::other(format!("cannot control running Moby VM: {e}")))?;
    stream.set_read_timeout(Some(Duration::from_secs(3)))?;
    stream.write_all(b"STOP\n")?;
    use std::io::Read;
    let mut response = [0_u8; 3];
    stream.read_exact(&mut response)?;
    if &response != b"OK\n" {
        return Err(io::Error::other("Moby Host refused VM stop"));
    }
    for _ in 0..160 {
        if !client::alive() { return Ok(()); }
        thread::sleep(Duration::from_millis(250));
    }
    Err(io::Error::other("Moby VM shutdown did not finish within its timeout"))
}
fn require_ok(r: io::Result<client::Response>) -> io::Result<Value> {
    let r = r?;
    if !r.ok() {
        return Err(io::Error::other(format!("Docker HTTP {}: {}", r.status, r.error())));
    }
    Ok(r.json())
}
fn result_event(name: &str, result: io::Result<String>) {
    match result {
        Ok(message) => emit(json!({"type":"operation","ok":true,"label":name,"message":message}).to_string()),
        Err(error) => emit(json!({"type":"operation","ok":false,"label":name,"message":error.to_string()}).to_string()),
    }
}

fn refresh() {
    let snapshot = (|| -> io::Result<Value> {
        let containers = client::get("/containers/json?all=1")?;
        let images = client::get("/images/json")?;
        let volumes = client::get("/volumes")?;
        let networks = client::get("/networks")?;
        let info = client::get("/info")?;
        let version = client::get("/version")?;
        Ok(json!({
            "type":"snapshot", "online":true,
            "containers":containers, "images":images,
            "volumes":volumes["Volumes"], "networks":networks,
            "info":info, "version":version, "shares": read_shares().unwrap_or_default()
        }))
    })();
    match snapshot {
        Ok(state) => {
            let mut menu = menu_state();
            menu.vm = "Running";
            menu.running = state["containers"].as_array().into_iter().flatten()
                .filter(|c| c["State"] == "running")
                .map(|c| {
                    let id = c["Id"].as_str().unwrap_or("").to_owned();
                    let name = c["Names"][0].as_str().unwrap_or("").trim_start_matches('/').to_owned();
                    let address = c["Ports"].as_array().and_then(|ports| {
                        ports.iter().filter(|p| p["Type"] == "tcp").find_map(|p| {
                            let port = p["PublicPort"].as_u64()?;
                            (1..=65535).contains(&port).then(|| format!("http://127.0.0.1:{port}/"))
                        })
                    });
                    (id, name, address)
                }).collect();
            drop(menu);
            emit(state.to_string());
        }
        Err(error) => {
            let mut menu = menu_state();
            menu.vm = "Stopped";
            menu.running.clear();
            drop(menu);
            emit(json!({"type":"snapshot","online":false,"error":error.to_string(),
                "containers":[],"images":[],"volumes":[],"networks":[],
                "shares": read_shares().unwrap_or_default()}).to_string());
        }
    }
}

fn decode_logs(body: &[u8]) -> String {
    // Docker non-TTY logs are multiplexed: [stream,0,0,0,len:u32be,data].
    // TTY container logs are plain bytes. Bound the renderer's text size.
    let mut pos = 0;
    let mut out = Vec::new();
    while pos + 8 <= body.len()
        && matches!(body[pos], 1 | 2 | 3)
        && body[pos + 1..pos + 4] == [0, 0, 0]
    {
        let len = u32::from_be_bytes(body[pos + 4..pos + 8].try_into().unwrap()) as usize;
        if len > body.len().saturating_sub(pos + 8) { break; }
        out.extend_from_slice(&body[pos + 8..pos + 8 + len]);
        pos += 8 + len;
    }
    if pos == 0 { return String::from_utf8_lossy(body).chars().take(60_000).collect(); }
    String::from_utf8_lossy(&out).chars().take(60_000).collect()
}

fn docker_command(args: &[&str]) -> io::Result<String> {
    let docker = client::docker_cli().ok_or_else(|| io::Error::new(io::ErrorKind::NotFound,
        "Docker CLI/Compose not installed or bundled in Kiri Moby app"))?;
    let output = Command::new(docker).args(args)
        .env("DOCKER_HOST", format!("unix://{}", socket_path()?.display()))
        .env_remove("DOCKER_CONTEXT")
        .output()?;
    let mut message = String::from_utf8_lossy(&output.stdout).to_string();
    message.push_str(&String::from_utf8_lossy(&output.stderr));
    message.truncate(message.floor_char_boundary(message.len().min(60_000)));
    if !output.status.success() {
        return Err(io::Error::other(format!("Docker CLI exited {}: {message}", output.status)));
    }
    Ok(message)
}

fn run_image(image: &str, env: &[String]) -> io::Result<String> {
    if image.is_empty() { return Err(io::Error::new(io::ErrorKind::InvalidInput, "image required")); }
    let body = json!({
        "Image":image, "Env":env,
        "HostConfig":{"PublishAllPorts":true}
    });
    let created = require_ok(client::request("POST", "/containers/create", Some(&body)))?;
    let id = created["Id"].as_str().ok_or_else(|| io::Error::other("Docker did not return a container ID"))?;
    match require_ok(client::request("POST", &format!("/containers/{id}/start"), None)) {
        Ok(_) => Ok(format!("Container started: {}", &id[..id.len().min(12)])),
        Err(e) => {
            // Do not delete the failed container automatically: its inspect
            // data and logs are useful for diagnosing failed starts.
            Err(e)
        }
    }
}
fn execute(value: &Value) -> io::Result<String> {
    let action = value["action"].as_str().unwrap_or("");
    let id = value["id"].as_str().unwrap_or("");
    let name = value["name"].as_str().unwrap_or("");
    match action {
        "inspect" => {
            let kind = value["kind"].as_str().unwrap_or("containers");
            let path = match kind {
                "containers" => format!("/containers/{}/json", path_escape(id)),
                "images" => format!("/images/{}/json", path_escape(id)),
                "volumes" => format!("/volumes/{}", path_escape(id)),
                "networks" => format!("/networks/{}", path_escape(id)),
                _ => return Err(io::Error::new(io::ErrorKind::InvalidInput, "unknown inspect type")),
            };
            let json = client::get(&path)?;
            serde_json::to_string_pretty(&json).map_err(io::Error::other)
        }
        "logs" => {
            let path = format!("/containers/{}/logs?stdout=1&stderr=1&tail=200&timestamps=1", path_escape(id));
            let output = client::request("GET", &path, None)?;
            if !output.ok() { return Err(io::Error::other(output.error())); }
            Ok(decode_logs(&output.body))
        }
        "authorize_share" => {
            add_share(value["path"].as_str().unwrap_or(""))
        }
        "remove_share" => {
            remove_share(value["path"].as_str().unwrap_or(""))
        }
        "apply_shares" => {
            if client::alive() { stop_vm()?; }
            start_vm()?;
            Ok("Shared folders applied; Moby VM restarted successfully".to_owned())
        }
        "create_volume" => {
            let created = require_ok(client::request("POST", "/volumes/create", Some(&json!({"Name":name}))))?;
            Ok(format!("Volume created: {}", created["Name"].as_str().unwrap_or(name)))
        }
        "create_network" => {
            let created = require_ok(client::request("POST", "/networks/create", Some(&json!({"Name":name,"Driver":"bridge"}))))?;
            Ok(format!("Network created: {}", created["Id"].as_str().unwrap_or(name)))
        }
        "compose_up" | "compose_down" | "compose_ps" => {
            let compose = value["path"].as_str().unwrap_or("");
            let path = Path::new(compose);
            if !path.is_file() || !matches!(path.extension().and_then(|e| e.to_str()), Some("yaml" | "yml")) {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, "choose an existing Compose .yaml/.yml file"));
            }
            let file = path.to_str().ok_or_else(|| io::Error::other("non-UTF8 Compose path"))?;
            match action {
                "compose_up" => docker_command(&["compose", "-f", file, "up", "-d"]),
                "compose_down" => docker_command(&["compose", "-f", file, "down"]),
                _ => docker_command(&["compose", "-f", file, "ps"]),
            }
        }
        "build" => {
            let context = value["path"].as_str().unwrap_or("");
            let image = value["name"].as_str().unwrap_or("");
            if image.is_empty() || !Path::new(context).is_dir() {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, "provide an image tag and existing build directory"));
            }
            docker_command(&["build", "-t", image, context])
        }
        "open_local" => {
            let url = value["url"].as_str().unwrap_or("");
            let allowed = url.strip_prefix("http://127.0.0.1:")
                .and_then(|v| v.split('/').next())
                .is_some_and(|n| n.parse::<u16>().is_ok_and(|p| p > 0));
            if !allowed { return Err(io::Error::new(io::ErrorKind::InvalidInput, "only localhost Docker ports may be opened")); }
            Command::new("/usr/bin/open").arg(url).spawn()?;
            Ok(format!("Opened {url}"))
        }
        _ => Err(io::Error::new(io::ErrorKind::InvalidInput, format!("Unsupported Moby operation: {action}")))
    }
}

pub(super) fn handle(message: &str, tx: &Sender<Cmd>) {
    let Ok(value) = serde_json::from_str::<Value>(message) else { return; };
    let cmd = value["cmd"].as_str().unwrap_or("");
    let submit = |command| { let _ = tx.send(command); };
    match cmd {
        "ready" | "refresh" => submit(Cmd::Refresh),
        "connect" | "start" => submit(Cmd::Connect),
        "stop" => submit(Cmd::Stop),
        "pull" => submit(Cmd::Pull(value["name"].as_str().unwrap_or("").to_owned())),
        "run" => submit(Cmd::Run(value["name"].as_str().unwrap_or("").to_owned(), Vec::new())),
        "rmi" => submit(Cmd::RemoveImage(value["name"].as_str().unwrap_or("").to_owned(), Vec::new())),
        "rmvol" => submit(Cmd::RemoveVolume(value["name"].as_str().unwrap_or("").to_owned())),
        "rmnet" => submit(Cmd::RemoveNetwork(value["id"].as_str().unwrap_or("").to_owned())),
        "container" => submit(Cmd::Container {
            action: value["action"].as_str().unwrap_or("").to_owned(),
            id: value["id"].as_str().unwrap_or("").to_owned()
        }),
        "moby" => {
            if value["action"] == "choose_compose" {
                super::window::pick_compose_file(
                    "Choose Docker Compose file", &["yaml".into(), "yml".into()],
                    move |path| { if let Some(path) = path {
                        emit(json!({"type":"selected_compose","path":path}).to_string());
                    } }
                );
            } else if value["action"] == "choose_share" {
                let tx = tx.clone();
                super::window::pick_share_directory(move |path| {
                    if let Some(path) = path {
                        let _ = tx.send(Cmd::Moby(json!({
                            "action":"authorize_share",
                            "path":path.to_string_lossy().to_string()
                        })));
                    }
                });
            } else { submit(Cmd::Moby(value)); }
        }
        _ => emit(json!({"type":"operation","ok":false,"label":"Command",
            "message":format!("Unsupported GUI command: {cmd}")}).to_string()),
    }
}

pub(super) fn engine(rx: Receiver<Cmd>, _tx: Sender<Cmd>) {
    let mut last_update = Instant::now() - Duration::from_secs(30);
    let mut stopped = false;
    loop {
        match rx.recv_timeout(Duration::from_millis(500)) {
            Ok(Cmd::Quit) | Err(RecvTimeoutError::Disconnected) => break,
            Ok(Cmd::Connect | Cmd::Start) => {
                emit(json!({"type":"vm","state":"starting"}).to_string());
                let result = start_vm().map(|()| "Standard Moby Docker Engine started".to_owned());
                result_event("Start VM", result);
                stopped = false;
                refresh();
                last_update = Instant::now();
            }
            Ok(Cmd::Stop) => {
                emit(json!({"type":"vm","state":"stopping"}).to_string());
                result_event("Stop VM", stop_vm().map(|()| "VM stopped, ext4 disk synced".to_owned()));
                stopped = true;
                refresh();
                last_update = Instant::now();
            }
            Ok(Cmd::Refresh) => {
                refresh();
                last_update = Instant::now();
            }
            Ok(Cmd::Pull(image)) => {
                result_event("Pull image", docker_command(&["pull", &image]));
                refresh(); last_update = Instant::now();
            }
            Ok(Cmd::Run(image, env)) => {
                result_event("Run container", run_image(&image, &env));
                refresh(); last_update = Instant::now();
            }
            Ok(Cmd::RemoveImage(image, _)) => {
                result_event("Remove image", require_ok(
                    client::request("DELETE", &format!("/images/{}", path_escape(&image)), None)
                ).map(|_| format!("Image removed: {image}")));
                refresh(); last_update = Instant::now();
            }
            Ok(Cmd::Container { action, id }) => {
                let operation = match action.as_str() {
                    "remove" => require_ok(client::request("DELETE", &format!("/containers/{}?force=1", path_escape(&id)), None)),
                    "start" | "stop" | "restart" | "pause" | "unpause" => require_ok(
                        client::request("POST", &format!("/containers/{}/{}", path_escape(&id), action), None)),
                    _ => Err(io::Error::new(io::ErrorKind::InvalidInput, "unsupported container action")),
                };
                result_event(&action, operation.map(|_| format!("{action}: {}", &id[..id.len().min(12)])));
                refresh(); last_update = Instant::now();
            }
            Ok(Cmd::RemoveVolume(name)) => {
                result_event("Remove volume", require_ok(
                    client::request("DELETE", &format!("/volumes/{}", path_escape(&name)), None)
                ).map(|_| format!("Volume removed: {name}")));
                refresh(); last_update = Instant::now();
            }
            Ok(Cmd::RemoveNetwork(id)) => {
                result_event("Remove network", require_ok(
                    client::request("DELETE", &format!("/networks/{}", path_escape(&id)), None)
                ).map(|_| "Network removed".into()));
                refresh(); last_update = Instant::now();
            }
            Ok(Cmd::Moby(value)) => {
                let label = value["action"].as_str().unwrap_or("Docker operation");
                result_event(label, execute(&value));
                if label != "inspect" && label != "logs" && label != "open_local" {
                    refresh(); last_update = Instant::now();
                }
            }
            Ok(_) => result_event("Moby", Err(io::Error::new(io::ErrorKind::Unsupported,
                "This legacy-only action is not supported by standard Docker Engine"))),
            Err(RecvTimeoutError::Timeout) => {
                if !stopped && last_update.elapsed() > Duration::from_secs(10) {
                    refresh();
                    last_update = Instant::now();
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shares_must_be_explicit_normalized_user_folders() {
        for allowed in ["/Users/alice/dev", "/Users/alice/My Projects",
            "/Volumes/ExternalSSD/projects"] {
            assert!(allowed_share(allowed), "unexpectedly rejected {allowed}");
        }
        for denied in ["/", "/Users", "/Users/", "/Users/../etc",
            "/Users/alice/../../etc", "/Volumes", "/etc", "/var/lib/docker",
            "/Users/a/./dev", "/Users//a/dev", "/Users/a/b,c", "Users/a/dev"] {
            assert!(!allowed_share(denied), "unexpectedly permitted {denied}");
        }
    }

    #[test]
    fn docker_raw_log_frames_are_decoded() {
        let mut frames = vec![1,0,0,0,0,0,0,3];
        frames.extend_from_slice(b"abc");
        frames.extend_from_slice(&[2,0,0,0,0,0,0,3]);
        frames.extend_from_slice(b"xyz");
        assert_eq!(decode_logs(&frames), "abcxyz");
        assert_eq!(decode_logs(b"plain\n"), "plain\n");
    }
}
