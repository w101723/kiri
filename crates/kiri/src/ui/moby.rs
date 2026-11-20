//! Native macOS Kiri GUI backend for the one upstream Moby Docker Engine.
//! No requests to the obsolete Kiri daemon or its /kiri/* private endpoints.
//! All Docker state lives in dockerd, in ~/.kiri-moby/vm/data.img.

use std::fs::{self, OpenOptions};
use std::os::unix::fs::OpenOptionsExt;
use std::io::{self, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use crate::client;
use super::{Cmd, emit, menu_state, path_escape};

fn data_dir() -> io::Result<PathBuf> {
    if let Some(path) = std::env::var_os("KIRI_MOBY_DATA_DIR") {
        return Ok(PathBuf::from(path));
    }
    Ok(PathBuf::from(std::env::var_os("HOME").ok_or_else(|| io::Error::other("HOME not set"))?).join(".kiri-moby"))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
struct VmResources { cpus: usize, memory_mib: u64 }

fn host_cpu_limit() -> usize {
    std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(1, 16)
}
#[cfg(target_os = "macos")]
fn host_memory_limit() -> u64 {
    let mut bytes = 0_u64;
    let mut length = std::mem::size_of::<u64>();
    let rc = unsafe {
        libc::sysctlbyname(b"hw.memsize\0".as_ptr().cast(),
            (&mut bytes as *mut u64).cast(), &mut length, std::ptr::null_mut(), 0)
    };
    let host = if rc == 0 && length == std::mem::size_of::<u64>() {
        bytes / (1024 * 1024)
    } else { 8 * 1024 };
    (host.saturating_sub(1024).min(host.saturating_mul(3) / 4)
        .min(65_536).max(1024) / 256) * 256
}
#[cfg(not(target_os = "macos"))]
fn host_memory_limit() -> u64 { 65_536 }
fn default_vm_resources() -> VmResources {
    VmResources { cpus: host_cpu_limit().min(4), memory_mib: host_memory_limit().min(4096) }
}
fn validate_vm_resources(value: VmResources) -> io::Result<VmResources> {
    if !(1..=host_cpu_limit()).contains(&value.cpus)
        || !(1024..=host_memory_limit()).contains(&value.memory_mib)
        || value.memory_mib % 256 != 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidInput,
            format!("VM resources require 1-{} CPUs and 1024-{} MiB in 256 MiB steps",
                host_cpu_limit(), host_memory_limit())));
    }
    Ok(value)
}
fn vm_resources_file() -> io::Result<PathBuf> { Ok(data_dir()?.join("vm-resources.json")) }
fn read_vm_resources() -> io::Result<VmResources> {
    let bytes = match fs::read(vm_resources_file()?) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(default_vm_resources()),
        Err(e) => return Err(e),
    };
    let config: VmResources = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    validate_vm_resources(config)
}
fn save_vm_resources(config: VmResources) -> io::Result<()> {
    let config = validate_vm_resources(config)?;
    let dir = data_dir()?;
    fs::create_dir_all(&dir)?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    let destination = vm_resources_file()?;
    let staging = destination.with_extension(format!("json.{}.tmp", std::process::id()));
    let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&staging)?;
    file.write_all(&serde_json::to_vec_pretty(&config).map_err(io::Error::other)?)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    drop(file);
    fs::rename(&staging, &destination)
}
fn vm_resource_snapshot() -> io::Result<Value> {
    let config = read_vm_resources()?;
    Ok(json!({"cpus":config.cpus, "memory_mib":config.memory_mib,
        "max_cpus":host_cpu_limit(), "max_memory_mib":host_memory_limit()}))
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
    let Some(resources) = resources() else { return Ok(()); };
    let assets = resources.join("guest");
    if !assets.is_dir() { return Ok(()); }

    let files = [
        "Image", "initramfs.cpio", "data.img.tgz",
        "system.img.tgz", "rootfs.revision", "SHA256SUMS",
    ];
    let source_revision = resources.join("SOURCE_REVISION");
    if source_revision.is_file() {
        // App upgrades only: replace the bundled, versioned Guest boot
        // assets as ONE directory, never edit the writable Docker data disk.
        // Acquire the SAME disk lock used by the Host to avoid upgrading while
        // any VM owns the persistent ext4 disk, even if its API isn't ready.
        use std::os::fd::AsRawFd;
        let lock = OpenOptions::new().create(true).read(true).write(true)
            .open(data.join("moby-vm.lock"))?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::new(io::ErrorKind::WouldBlock,
                "Kiri Moby VM is running or starting; refusing to change Guest assets"));
        }
        let rev = fs::read_to_string(&source_revision)?;
        let rev = rev.trim();
        if rev.len() != 40 || !rev.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(io::Error::new(io::ErrorKind::InvalidData,
                "invalid bundled SOURCE_REVISION"));
        }
        if fs::symlink_metadata(&dest).is_ok_and(|meta| meta.file_type().is_symlink()) {
            return Err(io::Error::new(io::ErrorKind::InvalidData,
                "refusing to install Guest into symlink"));
        }
        let installed = fs::read_to_string(dest.join("SOURCE_REVISION"))
            .ok().is_some_and(|old| old.trim() == rev);
        if installed && files.iter().all(|file| dest.join(file).is_file()) {
            return Ok(());
        }
        for file in files {
            if !assets.join(file).is_file() {
                return Err(io::Error::new(io::ErrorKind::NotFound,
                    format!("bundled Kiri Moby Guest asset is missing: {file}")));
            }
        }
        let stage = data.join(format!(".guest-staging-{}", std::process::id()));
        if stage.exists() {
            return Err(io::Error::new(io::ErrorKind::AlreadyExists,
                format!("partial Guest asset staging at {}", stage.display())));
        }
        fs::create_dir(&stage)?;
        fs::set_permissions(&stage, fs::Permissions::from_mode(0o700))?;
        // Files are the signed App's copy; check the bundled SHA256SUMS before
        // publishing the new assets. Old assets remain intact on any failure.
        for file in files {
            fs::copy(assets.join(file), stage.join(file))?;
        }
        let verified = Command::new("/usr/bin/shasum")
            .args(["-a", "256", "-c", "SHA256SUMS"])
            .current_dir(&stage)
            .stdout(Stdio::null())
            .status()?;
        if !verified.success() {
            return Err(io::Error::new(io::ErrorKind::InvalidData,
                "bundled Guest asset SHA256 verification failed"));
        }
        fs::write(stage.join("SOURCE_REVISION"), format!("{rev}\n"))?;

        // Keep a whole rollback directory. There are only two renames:
        // either boot assets are old, or new. Docker layers and volumes are
        // NEVER inside guest/, and are never copied or removed here.
        let backup = data.join(format!("guest-backup-{}-{}", rev, std::process::id()));
        if backup.exists() {
            return Err(io::Error::new(io::ErrorKind::AlreadyExists,
                format!("Guest backup already exists at {}", backup.display())));
        }
        let had_old = dest.exists();
        if had_old { fs::rename(&dest, &backup)?; }
        if let Err(error) = fs::rename(&stage, &dest) {
            if had_old { let _ = fs::rename(&backup, &dest); }
            return Err(error);
        }
        // Lock is released when its owning descriptor is dropped. The new
        // launcher then takes that same exclusive lock before VM creation.
        return Ok(());
    }

    // CLI/sideloaded installs without an App SOURCE_REVISION still retain
    // historical copy-if-missing behavior, not automatic upgrade behavior.
    fs::create_dir_all(&dest)?;
    fs::set_permissions(&dest, fs::Permissions::from_mode(0o700))?;
    for file in files {
        if !dest.join(file).is_file() && assets.join(file).is_file() {
            let staging = dest.join(format!(".{file}.new"));
            if staging.exists() {
                return Err(io::Error::new(io::ErrorKind::AlreadyExists,
                    format!("partial Guest asset install at {}", staging.display())));
            }
            fs::copy(assets.join(file), &staging)?;
            fs::rename(&staging, dest.join(file))?;
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
    let resources = read_vm_resources()?;
    let mut child = Command::new(binary);
    // The GUI's explicit authorization list is the only source of Mac
    // directory access: never inherit legacy broad share or manual-port
    // overrides from a terminal that happened to launch the app.
    child.env("KIRI_MOBY_DATA_DIR", &data)
        .env("KIRI_MOBY_CPUS", resources.cpus.to_string())
        .env("KIRI_MOBY_MEMORY_MIB", resources.memory_mib.to_string())
        .env_remove("KIRI_MOBY_SHARE_MAC")
        .env_remove("KIRI_MOBY_SHARE_DIRS")
        .env_remove("KIRI_MOBY_TCP_PORTS")
        .env_remove("KIRI_MOBY_DISABLE_PORT_FORWARD");
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

fn memory_status() -> Value {
    // Host-only control endpoint; never tunnel this to Docker or the Guest.
    let Ok(path) = data_dir() else { return Value::Null };
    let Ok(mut stream) = UnixStream::connect(path.join("run/host-control.sock")) else { return Value::Null };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(350)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(350)));
    if stream.write_all(b"STAT\n").is_err() { return Value::Null; }
    let mut bytes = [0u8; 256];
    match std::io::Read::read(&mut stream, &mut bytes) {
        Ok(len) => serde_json::from_slice(&bytes[..len]).unwrap_or(Value::Null),
        Err(_) => Value::Null,
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
            "info":info, "version":version, "memory": memory_status(), "shares": read_shares().unwrap_or_default(),
            "vm_config": vm_resource_snapshot()?
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
                "shares": read_shares().unwrap_or_default(),
                "vm_config":vm_resource_snapshot().unwrap_or(Value::Null)}).to_string());
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
    if pos == 0 { return String::from_utf8_lossy(body).chars().take(240_000).collect(); }
    String::from_utf8_lossy(&out).chars().take(240_000).collect()
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
            let tail = value["tail"].as_str().unwrap_or("200")
                .parse::<usize>().unwrap_or(200).clamp(10, 5000);
            let path = format!("/containers/{}/logs?stdout=1&stderr=1&tail={tail}&timestamps=1", path_escape(id));
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
        "exec" => {
            let command = value["command"].as_str().unwrap_or("");
            if id.is_empty() || command.trim().is_empty() {
                return Err(io::Error::new(io::ErrorKind::InvalidInput,
                    "choose a container and a nonempty command"));
            }
            docker_command(&["exec", id, "sh", "-c", command])
        }
        "create_volume" => {
            let created = require_ok(client::request("POST", "/volumes/create", Some(&json!({"Name":name}))))?;
            Ok(format!("Volume created: {}", created["Name"].as_str().unwrap_or(name)))
        }
        "create_network" => {
            let created = require_ok(client::request("POST", "/networks/create", Some(&json!({"Name":name,"Driver":"bridge"}))))?;
            Ok(format!("Network created: {}", created["Id"].as_str().unwrap_or(name)))
        }
        "compose_up" | "compose_down" | "compose_ps" | "compose_logs" => {
            let compose = value["path"].as_str().unwrap_or("");
            let path = Path::new(compose);
            if !path.is_file() || !matches!(path.extension().and_then(|e| e.to_str()), Some("yaml" | "yml")) {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, "choose an existing Compose .yaml/.yml file"));
            }
            let file = path.to_str().ok_or_else(|| io::Error::other("non-UTF8 Compose path"))?;
            match action {
                "compose_up" => docker_command(&["compose", "-f", file, "up", "-d"]),
                "compose_down" => docker_command(&["compose", "-f", file, "down"]),
                "compose_logs" => docker_command(&["compose", "-f", file, "logs", "--no-color", "--tail", "200"]),
                _ => docker_command(&["compose", "-f", file, "ps"]),
            }
        }
        "build" => {
            let context = value["path"].as_str().unwrap_or("");
            let image = value["name"].as_str().unwrap_or("");
            if image.is_empty() || !Path::new(context).is_dir() {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, "provide an image tag and existing build directory"));
            }
            let platform = value["platform"].as_str().unwrap_or("linux/arm64");
            if platform != "linux/arm64" && platform != "linux/amd64" {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, "unsupported Buildx platform"));
            }
            docker_command(&["buildx", "build", "--platform", platform, "--load", "-t", image, context])
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

pub(super) fn engine(rx: Receiver<Cmd>, tx: Sender<Cmd>) {
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
                let tx = tx.clone();
                emit(json!({"type":"busy","label":"Pull image"}).to_string());
                thread::spawn(move || {
                    result_event("Pull image", docker_command(&["pull", &image]));
                    let _ = tx.send(Cmd::Refresh);
                });
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
                let label = value["action"].as_str().unwrap_or("Docker operation").to_owned();
                // Long-running docker build, Compose, pull and exec operations
                // must never block the GUI coordinator or the VM Stop action.
                if ["build", "compose_up", "compose_down", "compose_logs",
                    "compose_ps", "logs", "exec"].contains(&label.as_str()) {
                    let tx = tx.clone();
                    emit(json!({"type":"busy","label":label}).to_string());
                    thread::spawn(move || {
                        result_event(&label, execute(&value));
                        let _ = tx.send(Cmd::Refresh);
                    });
                } else {
                    result_event(&label, execute(&value));
                    if !["inspect", "open_local"].contains(&label.as_str()) {
                        refresh(); last_update = Instant::now();
                    }
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
    fn vm_resource_limits_reject_unsafe_settings() {
        let valid = default_vm_resources();
        assert_eq!(validate_vm_resources(valid).unwrap(), valid);
        assert!(validate_vm_resources(VmResources {
            cpus: 0, memory_mib: valid.memory_mib
        }).is_err());
        assert!(validate_vm_resources(VmResources {
            cpus: host_cpu_limit() + 1, memory_mib: valid.memory_mib
        }).is_err());
        assert!(validate_vm_resources(VmResources {
            cpus: valid.cpus, memory_mib: 768
        }).is_err());
        assert!(validate_vm_resources(VmResources {
            cpus: valid.cpus, memory_mib: valid.memory_mib + 1
        }).is_err());
        assert!(validate_vm_resources(VmResources {
            cpus: valid.cpus, memory_mib: host_memory_limit() + 256
        }).is_err());
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


/// Native SwiftUI frontend's narrow, short-lived command bridge.
///
/// The Finder-launched SwiftUI binary invokes Contents/MacOS/kiri with this
/// private subcommand. All Docker operations keep using the existing Rust
/// Moby adapter and private ~/.kiri-moby/run/docker.sock. No WebKit process,
/// HTTP server, second engine, or new data store is introduced.
///
/// Only one JSON response is written to stdout; diagnostic logs stay stderr.
pub(super) fn native_command(args: &[String]) -> io::Result<()> {
    // PTY transport: the native App owns the terminal and passes a real TTY
    // through this existing signed CLI. Never route terminal bytes through JSON.
    if args.first().map(String::as_str) == Some("terminal") {
        let id = args.get(1).ok_or_else(|| io::Error::new(
            io::ErrorKind::InvalidInput, "container ID required"))?;
        if id.is_empty() || !id.bytes().all(|b| b.is_ascii_hexdigit()) || id.len() > 64 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid container ID"));
        }
        let docker = client::docker_cli().ok_or_else(|| io::Error::new(
            io::ErrorKind::NotFound, "Docker CLI unavailable"))?;
        let status = Command::new(docker)
            .args(["exec", "-it", id, "/bin/sh"])
            .env("DOCKER_HOST", format!("unix://{}", socket_path()?.display()))
            .env_remove("DOCKER_CONTEXT")
            .env("TERM", "xterm-256color")
            .stdin(Stdio::inherit()).stdout(Stdio::inherit()).stderr(Stdio::inherit())
            .status()?;
        if !status.success() {
            return Err(io::Error::other(format!("terminal exited: {status}")));
        }
        return Ok(());
    }
    let result: io::Result<Value> = (|| {
        let operation = args.first().map(String::as_str).unwrap_or("");
        let value = match operation {
            "snapshot" => {
                if !client::alive() {
                    json!({"online":false, "containers":[], "images":[], "volumes":[],
                        "networks":[], "shares":read_shares()?, "memory":Value::Null,
                        "vm_config":vm_resource_snapshot()?})
                } else {
                    let containers = client::get("/containers/json?all=1")?;
                    let images = client::get("/images/json")?;
                    let volumes = client::get("/volumes")?;
                    let networks = client::get("/networks")?;
                    let info = client::get("/info")?;
                    let version = client::get("/version")?;
                    json!({"online":true, "containers":containers, "images":images,
                        "volumes":volumes["Volumes"], "networks":networks,
                        "info":info, "version":version,
                        "memory":memory_status(), "shares":read_shares()?,
                        "vm_config":vm_resource_snapshot()?})
                }
            }
            "configure" => {
                let cpu = args.get(1).ok_or_else(||
                    io::Error::new(io::ErrorKind::InvalidInput, "CPU count required"))?
                    .parse::<usize>().map_err(|_| io::Error::new(
                        io::ErrorKind::InvalidInput, "invalid CPU count"))?;
                let memory = args.get(2).ok_or_else(||
                    io::Error::new(io::ErrorKind::InvalidInput, "memory limit required"))?
                    .parse::<u64>().map_err(|_| io::Error::new(
                        io::ErrorKind::InvalidInput, "invalid memory limit"))?;
                let apply = match args.get(3).map(String::as_str) {
                    Some("apply") => true,
                    Some("save") => false,
                    _ => return Err(io::Error::new(io::ErrorKind::InvalidInput,
                        "expected configure <cpu> <memory_mib> <apply|save>")),
                };
                let next = validate_vm_resources(VmResources { cpus: cpu, memory_mib: memory })?;
                let modified = next != read_vm_resources()?;
                if modified { save_vm_resources(next)?; }
                let active = client::alive();
                // A previously saved (but not yet applied) setting also
                // requires a restart; comparing only the JSON file is wrong.
                let pending = if active {
                    let live_memory = memory_status()["vm_memory_ceiling_mib"].as_u64();
                    let live_cpus = client::get("/info").ok()
                        .and_then(|info| info["NCPU"].as_u64());
                    live_memory != Some(next.memory_mib) || live_cpus != Some(next.cpus as u64)
                } else { false };
                if apply && active && pending {
                    stop_vm()?;
                    start_vm()?;
                }
                json!({"message": if active && apply && pending {
                    "VM restarted with the configured CPU and memory limits"
                } else if active && pending {
                    "Settings saved; VM restart is required to apply them"
                } else if active {
                    "VM CPU and memory limits are already applied"
                } else {
                    "Settings saved; limits will take effect on next VM start"
                }})
            }
            "start" => {
                start_vm()?;
                json!({"message":"Moby VM started"})
            }
            "stop" => {
                stop_vm()?;
                json!({"message":"VM stopped; Docker disk synced"})
            }
            "restart" => {
                if client::alive() { stop_vm()?; }
                start_vm()?;
                json!({"message":"Moby VM restarted"})
            }
            "pull" => {
                let name = args.get(1).ok_or_else(|| io::Error::other("image required"))?;
                json!({"message":docker_command(&["pull", name])?})
            }
            "run" => {
                let name = args.get(1).ok_or_else(|| io::Error::other("image required"))?;
                json!({"message":run_image(name, &[])?})
            }
            "rmi" => {
                let id = args.get(1).ok_or_else(|| io::Error::other("image ID required"))?;
                require_ok(client::request("DELETE", &format!("/images/{}", path_escape(id)), None))?;
                json!({"message":"Image removed"})
            }
            "rmvol" => {
                let name = args.get(1).ok_or_else(|| io::Error::other("volume name required"))?;
                require_ok(client::request("DELETE", &format!("/volumes/{}", path_escape(name)), None))?;
                json!({"message":"Volume removed"})
            }
            "rmnet" => {
                let id = args.get(1).ok_or_else(|| io::Error::other("network ID required"))?;
                require_ok(client::request("DELETE", &format!("/networks/{}", path_escape(id)), None))?;
                json!({"message":"Network removed"})
            }
            "container" => {
                let action = args.get(1).map(String::as_str).unwrap_or("");
                let id = args.get(2).ok_or_else(|| io::Error::other("container ID required"))?;
                let path = format!("/containers/{}", path_escape(id));
                match action {
                    "remove" => { require_ok(client::request("DELETE", &format!("{path}?force=1"), None))?; }
                    "start" | "stop" | "restart" | "pause" | "unpause" => {
                        require_ok(client::request("POST", &format!("{path}/{action}"), None))?;
                    }
                    _ => return Err(io::Error::other("unsupported container action")),
                }
                json!({"message":format!("{action}: {}", &id[..id.len().min(12)])})
            }
            "action" => {
                let encoded = args.get(1).ok_or_else(|| io::Error::other("JSON action required"))?;
                let input: Value = serde_json::from_str(encoded).map_err(io::Error::other)?;
                json!({"message":execute(&input)?})
            }
            _ => return Err(io::Error::new(io::ErrorKind::InvalidInput,
                "moby-native: expected snapshot/configure/start/stop/restart/pull/run/rmi/rmvol/rmnet/container/action")),
        };
        Ok(value)
    })();
    let reply = match result {
        Ok(value) => {
            let mut response = json!({"ok":true});
            if let Some(fields) = value.as_object() {
                for (key, val) in fields { response[key] = val.clone(); }
            }
            response
        }
        Err(err) => json!({"ok":false, "error":err.to_string()}),
    };
    println!("{reply}");
    Ok(())
}
