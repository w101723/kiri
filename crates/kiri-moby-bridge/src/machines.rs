//! Machine and Kubernetes lifecycle control, OrbStack-style.
//!
//! One VM hosts everything: the btrfs data disk carries a subvolume per
//! machine rootfs, k3s state for the local cluster, and the docker subvolume.
//! Machines are full-distro rootfs subvolumes (cloned from official distro
//! images via `docker export`) whose PID1 is the distro's real init (systemd
//! where present) running in private mount/PID namespaces. The host drives
//! this module over an authenticated AF_VSOCK control channel (port 2379);
//! the vsock boundary is the authentication, mirroring the Docker port.

use std::collections::HashMap;
use std::io::{self, BufRead, Read, Write};
use std::sync::Mutex;
use std::time::Duration;
use std::path::Path;
use std::process::Command;

pub const MACHINE_VSOCK_PORT: u32 = 2379;

const MACHINES_ROOT: &str = "/mnt/data/machines";
const MAX_REQUEST_BYTES: u64 = 64 * 1024;
static OPERATIONS: Mutex<()> = Mutex::new(());

fn machine_rootfs(name: &str) -> String {
    format!("{MACHINES_ROOT}/{name}/rootfs")
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn sh(program: &str, args: &[&str]) -> io::Result<String> {
    let result = Command::new(program).args(args).output()?;
    if result.status.success() {
        Ok(String::from_utf8_lossy(&result.stdout).into_owned())
    } else {
        Err(io::Error::other(format!(
            "{program} failed: {}",
            String::from_utf8_lossy(&result.stderr)
        )))
    }
}

/// True once the btrfs data layout is mounted (init mounts /mnt/data).
pub fn data_layout_ready() -> bool {
    Path::new("/mnt/data/machines").is_dir() && Path::new("/mnt/data/docker").is_dir()
}

/// Distro presets accepted by `machine create`. Each maps to the official
/// arm64 image whose rootfs the machine subvolume is cloned from.
pub const DISTROS: &[(&str, &str)] = &[
    ("alpine", "alpine:3.22"),
    ("debian", "debian:trixie"),
    ("ubuntu", "ubuntu:noble"),
    ("fedora", "fedora:41"),
];

fn distro_image(distro: &str) -> Option<&'static str> {
    DISTROS.iter().find(|(name, _)| *name == distro).map(|(_, image)| *image)
}

/// Creates a machine by cloning an official distro image rootfs into a fresh
/// btrfs subvolume. `docker create` + `docker export` yields the rootfs tree;
/// unpacking into the subvolume keeps it snapshot-ready.
pub fn machine_create(distro: &str, name: &str) -> Result<String, String> {
    if !data_layout_ready() {
        return Err("data disk is not mounted (btrfs layout expected)".into());
    }
    if !valid_name(name) {
        return Err("machine name must be [A-Za-z0-9_-]{1,64}".into());
    }
    let rootfs = machine_rootfs(name);
    let parent = format!("{MACHINES_ROOT}/{name}");
    if Path::new(&parent).exists() {
        return Err(format!("machine '{name}' already exists or has an incomplete creation"));
    }
    let image = distro_image(distro)
        .ok_or_else(|| format!("unknown distro '{distro}'; supported: {}", {
            let names: Vec<&str> = DISTROS.iter().map(|(n, _)| *n).collect();
            names.join(", ")
        }))?;

    let container = format!("kiri-machine-seed-{name}");
    sh("docker", &["create", "--name", &container, image])
        .map_err(|e| format!("docker create failed: {e}"))?;
    // mkdir first: `btrfs subvolume create` needs the (otherwise absent)
    // per-machine parent, and refuses to create a subvolume over a dir.
    let unpack = sh(
        "sh",
        &[
            "-c",
            &format!(
                "set -o pipefail; mkdir {MACHINES_ROOT}/{name} && btrfs subvolume create {rootfs}.new && docker export {container} | tar -xpf - -C {rootfs}.new && mv -T {rootfs}.new {rootfs} && rm -f {rootfs}/.dockerenv"
            ),
        ],
    );
    let _ = sh("docker", &["rm", "-f", &container]);
    if let Err(error) = unpack {
        let _ = sh("btrfs", &["subvolume", "delete", &format!("{rootfs}.new")]);
        let _ = std::fs::remove_dir(&parent);
        return Err(format!("rootfs unpack failed: {error}"));
    }

    // A machine needs a resolvable init; distro images carry /sbin/init.
    if !Path::new(&format!("{rootfs}/sbin/init")).exists()
        && !Path::new(&format!("{rootfs}/usr/sbin/init")).exists()
    {
        let _ = machine_delete(name);
        return Err(format!("image {image} has no /sbin/init; not machine-capable"));
    }
    std::fs::write(format!("{parent}/distro"), distro)
        .map_err(|e| format!("machine metadata write failed: {e}"))?;
    Ok(format!("machine '{name}' created ({distro})"))
}

/// Lists machines and their running state (PID of the machine's init).
pub fn machine_list() -> Vec<(String, bool, String)> {
    let mut machines = Vec::new();
    let Ok(entries) = std::fs::read_dir(MACHINES_ROOT) else {
        return machines;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if Path::new(&machine_rootfs(&name)).is_dir() {
            let running = machine_pid(&name).is_some();
            let distro = std::fs::read_to_string(entry.path().join("distro"))
                .unwrap_or_else(|_| "linux".into()).trim().to_string();
            machines.push((name, running, distro));
        }
    }
    machines.sort();
    machines
}

/// The PID (root namespace view) of a running machine's init: the process
/// chrooted into this machine's rootfs whose comm is init/systemd. A
/// namespace-relative marker cannot work — `echo $$` inside
/// `unshare --pid --fork` always writes 1, and signalling guest PID 1 would
/// power off the whole VM.
fn machine_pid(name: &str) -> Option<u32> {
    if !valid_name(name) { return None; }
    let rootfs = machine_rootfs(name);
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return None;
    };
    for entry in entries.flatten() {
        let Some(pid) = entry.file_name().to_str().and_then(|s| s.parse::<u32>().ok()) else {
            continue;
        };
        // The chroot boundary is visible as /proc/<pid>/root -> <rootfs>.
        let Ok(root) = std::fs::read_link(format!("/proc/{pid}/root")) else {
            continue;
        };
        if root.to_string_lossy() != rootfs {
            continue;
        }
        let Ok(comm) = std::fs::read_to_string(format!("/proc/{pid}/comm")) else {
            continue;
        };
        if comm.trim() == "init" || comm.trim() == "systemd" {
            return Some(pid);
        }
    }
    None
}

/// Starts a machine: private mount/PID namespaces, its rootfs subvolume as
/// /, the distro's real init as PID1. Runs detached; `machine_pid` finds it
/// again through its /proc root link.
pub fn machine_start(name: &str) -> Result<String, String> {
    if !valid_name(name) { return Err("invalid machine name".into()); }
    if machine_pid(name).is_some() { return Ok(format!("machine '{name}' already running")); }
    let rootfs = machine_rootfs(name);
    if !Path::new(&rootfs).is_dir() {
        return Err(format!("machine '{name}' does not exist"));
    }
    for dir in ["dev", "sys", "proc", "run"] {
        std::fs::create_dir_all(format!("{rootfs}/{dir}"))
            .map_err(|e| format!("prepare machine mountpoints: {e}"))?;
    }
    // The mount namespace is private; never share the host's /run/docker.sock.
    let script = format!(
        "unshare --mount --pid --fork --mount-proc={rootfs}/proc \
         sh -c 'mount --make-rprivate / && \
                mount --rbind /dev {rootfs}/dev && \
                mount --rbind /sys {rootfs}/sys && \
                mount -t tmpfs tmpfs {rootfs}/run && \
                exec chroot {rootfs} /sbin/init' \
         >{MACHINES_ROOT}/{name}/boot.log 2>&1 </dev/null &"
    );
    sh("sh", &["-c", &script]).map_err(|e| format!("machine start failed: {e}"))?;
    for _ in 0..40 {
        if machine_pid(name).is_some() { return Ok(format!("machine '{name}' started")); }
        std::thread::sleep(Duration::from_millis(100));
    }
    let log = std::fs::read_to_string(format!("{MACHINES_ROOT}/{name}/boot.log"))
        .unwrap_or_default();
    Err(format!("machine '{name}' init failed: {}", log.chars().take(1200).collect::<String>()))
}

fn rooted_process_exists(rootfs: &str) -> bool {
    let Ok(entries) = std::fs::read_dir("/proc") else { return true };
    entries.flatten().filter_map(|entry| {
        entry.file_name().to_str().and_then(|v| v.parse::<u32>().ok())
    }).any(|pid| {
        std::fs::read_link(format!("/proc/{pid}/root"))
            .map(|root| root.to_string_lossy() == rootfs
                || root.to_string_lossy().starts_with(&format!("{rootfs}/")))
            .unwrap_or(false)
    })
}

pub fn machine_stop(name: &str) -> Result<String, String> {
    if !valid_name(name) { return Err("invalid machine name".into()); }
    let Some(pid) = machine_pid(name) else {
        return Ok(format!("machine '{name}' is not running"));
    };
    let _ = Command::new("kill").args(["-s", "SIGRTMIN+3", &pid.to_string()]).status();
    for _ in 0..20 {
        if machine_pid(name).is_none() { return Ok(format!("machine '{name}' stopped")); }
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = Command::new("kill").arg(pid.to_string()).status();
    for _ in 0..20 {
        if machine_pid(name).is_none() { return Ok(format!("machine '{name}' stopped")); }
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = Command::new("kill").args(["-9", &pid.to_string()]).status();
    for _ in 0..30 {
        if machine_pid(name).is_none() { return Ok(format!("machine '{name}' stopped")); }
        std::thread::sleep(Duration::from_millis(100));
    }
    Err(format!("machine '{name}' init remains alive; data preserved"))
}

pub fn machine_delete(name: &str) -> Result<String, String> {
    if !valid_name(name) { return Err("invalid machine name".into()); }
    machine_stop(name)?;
    let rootfs = machine_rootfs(name);
    if !Path::new(&rootfs).exists() { return Ok(format!("machine '{name}' did not exist")); }
    if rooted_process_exists(&rootfs) {
        return Err(format!("machine '{name}' still has live processes; data preserved"));
    }
    // Never fall back to rm -rf on a mounted or busy btrfs subvolume.
    sh("btrfs", &["subvolume", "delete", &rootfs])
        .map_err(|e| format!("btrfs refused deletion (data preserved): {e}"))?;
    let parent = format!("{MACHINES_ROOT}/{name}");
    for file in ["distro", "boot.log"] {
        match std::fs::remove_file(format!("{parent}/{file}")) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("rootfs removed but metadata cleanup failed: {e}")),
        }
    }
    std::fs::remove_dir(&parent).map_err(|e| format!("metadata directory cleanup failed: {e}"))?;
    Ok(format!("machine '{name}' deleted"))
}

pub fn machine_exec(name: &str, command: &str) -> Result<String, String> {
    if !valid_name(name) { return Err("invalid machine name".into()); }
    let pid = machine_pid(name).ok_or_else(|| format!("machine '{name}' is not running"))?;
    // -m/-p alone leaves the caller's rootfs intact. --root adopts the
    // target machine init's chroot, --wd=/ prevents inheriting the host CWD.
    sh("nsenter", &["--target", &pid.to_string(), "--mount", "--pid",
        "--root", "--wd=/", "--", "/bin/sh", "-c", command])
        .map_err(|e| format!("machine exec failed: {e}"))
}

// MARK: - Kubernetes (k3s in the same VM)

const K8S_BIN: &str = "/mnt/data/k8s/bin/k3s";
const K8S_BIN_DIR: &str = "/mnt/data/k8s/bin";
const K8S_DATA: &str = "/mnt/data/k8s/state";

/// Downloads the pinned k3s single binary into the k8s subvolume on demand;
/// the seed ships no cluster runtime (same policy as the engine).
fn ensure_k3s() -> Result<(), String> {
    if Path::new(K8S_BIN).exists() {
        return Ok(());
    }
    let version = "v1.33.4+k3s1";
    let url = format!(
        "https://github.com/k3s-io/k3s/releases/download/{version}/k3s-arm64"
    );
    let script = format!(
        "mkdir -p {K8S_BIN_DIR} && curl -fsSL '{url}' -o {K8S_BIN}.tmp && chmod 0755 {K8S_BIN}.tmp && mv {K8S_BIN}.tmp {K8S_BIN}"
    );
    sh("sh", &["-c", script.as_str()])
        .map(|_| ())
        .map_err(|e| format!("k3s download failed: {e}"))
}

pub fn k8s_enable() -> Result<String, String> {
    if k8s_status() == "running" {
        return Ok("kubernetes already running".into());
    }
    ensure_k3s()?;
    let script = format!(
        "K3S_DATA_DIR={K8S_DATA} nohup env K3S_KUBECONFIG_MODE=0600 \
         {K8S_BIN} server --disable traefik --data-dir {K8S_DATA} \
         --write-kubeconfig /mnt/data/k8s/kubeconfig \
         >/mnt/data/k8s/k3s.log 2>&1 & echo $! > {K8S_DATA}.pid"
    );
    std::fs::create_dir_all(K8S_DATA).map_err(|e| e.to_string())?;
    sh("sh", &["-c", script.as_str()]).map_err(|e| format!("k3s start failed: {e}"))?;
    Ok("kubernetes starting; kubeconfig at /mnt/data/k8s/kubeconfig".into())
}

fn k8s_pid() -> Option<u32> {
    let pid = std::fs::read_to_string(format!("{K8S_DATA}.pid"))
        .ok()?.trim().parse::<u32>().ok()?;
    let executable = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    (executable == Path::new(K8S_BIN)).then_some(pid)
}
pub fn k8s_disable() -> Result<String, String> {
    if let Some(pid) = k8s_pid() {
        sh("kill", &[&pid.to_string()]).map_err(|e| format!("k3s stop failed: {e}"))?;
        for _ in 0..50 {
            if k8s_pid().is_none() { break; }
            std::thread::sleep(Duration::from_millis(100));
        }
        if k8s_pid().is_some() { return Err("k3s has not stopped".into()); }
    }
    let _ = std::fs::remove_file(format!("{K8S_DATA}.pid"));
    Ok("kubernetes stopped (state kept)".into())
}
pub fn k8s_status() -> String {
    if k8s_pid().is_some() { "running" } else { "disabled" }.into()
}

// JSON-line protocol parser: strict flat string-only object, including JSON
// escapes and UTF-16 surrogate pairs. Invalid inputs are rejected, not
// truncated to a different shell command.
fn hex4(bytes: &[u8], pos: &mut usize) -> Result<u16, String> {
    let mut n = 0u16;
    for _ in 0..4 {
        let digit = *bytes.get(*pos).ok_or("truncated unicode escape")?;
        n = (n << 4) | (digit as char).to_digit(16)
            .ok_or("invalid unicode escape")? as u16;
        *pos += 1;
    }
    Ok(n)
}
fn json_string(src: &str, pos: &mut usize) -> Result<String, String> {
    let bytes = src.as_bytes();
    if bytes.get(*pos) != Some(&b'"') { return Err("expected JSON string".into()); }
    *pos += 1;
    let mut value = String::new();
    let mut chunk = *pos;
    while let Some(&byte) = bytes.get(*pos) {
        match byte {
            b'"' => { value.push_str(&src[chunk..*pos]); *pos += 1; return Ok(value); }
            b'\\' => {
                value.push_str(&src[chunk..*pos]);
                *pos += 1;
                let escape = *bytes.get(*pos).ok_or("truncated escape")?;
                *pos += 1;
                match escape {
                    b'"' => value.push('"'), b'\\' => value.push('\\'),
                    b'/' => value.push('/'), b'n' => value.push('\n'),
                    b'r' => value.push('\r'), b't' => value.push('\t'),
                    b'b' => value.push('\u{0008}'), b'f' => value.push('\u{000c}'),
                    b'u' => {
                        let code = hex4(bytes, pos)?;
                        let scalar = if (0xD800..=0xDBFF).contains(&code) {
                            if bytes.get(*pos..*pos + 2) != Some(&b"\\u"[..]) {
                                return Err("missing low surrogate".into());
                            }
                            *pos += 2;
                            let low = hex4(bytes, pos)?;
                            if !(0xDC00..=0xDFFF).contains(&low) {
                                return Err("invalid low surrogate".into());
                            }
                            0x10000 + ((code as u32 - 0xD800) << 10) + (low as u32 - 0xDC00)
                        } else { code as u32 };
                        value.push(char::from_u32(scalar).ok_or("invalid unicode escape")?);
                    }
                    _ => return Err("invalid JSON escape".into()),
                }
                chunk = *pos;
            }
            0..=31 => return Err("unescaped control character".into()),
            _ => *pos += 1,
        }
    }
    Err("unterminated JSON string".into())
}
fn parse_fields(src: &str) -> Result<HashMap<String, String>, String> {
    let b = src.as_bytes();
    let mut i = 0usize;
    let whitespace = |i: &mut usize| {
        while b.get(*i).is_some_and(|x| matches!(x, b' ' | b'\t' | b'\r' | b'\n')) { *i += 1; }
    };
    whitespace(&mut i);
    if b.get(i) != Some(&b'{') { return Err("expected JSON object".into()); }
    i += 1;
    let mut result = HashMap::new();
    loop {
        whitespace(&mut i);
        if b.get(i) == Some(&b'}') { i += 1; break; }
        let key = json_string(src, &mut i)?;
        whitespace(&mut i);
        if b.get(i) != Some(&b':') { return Err("expected colon".into()); }
        i += 1;
        whitespace(&mut i);
        let val = json_string(src, &mut i)?;
        if result.insert(key, val).is_some() { return Err("duplicate JSON key".into()); }
        whitespace(&mut i);
        match b.get(i) {
            Some(b',') => i += 1,
            Some(b'}') => { i += 1; break; }
            _ => return Err("expected comma or closing brace".into()),
        }
    }
    whitespace(&mut i);
    if i != b.len() { return Err("trailing data".into()); }
    Ok(result)
}

/// Wire protocol: one JSON line per request, one JSON line per reply.
/// {"op":"machine_create","distro":"alpine","name":"dev"}
/// {"op":"machine_start","name":"dev"}
/// {"op":"machine_stop","name":"dev"}
/// {"op":"machine_delete","name":"dev"}
/// {"op":"machine_list"} {"op":"machine_exec","name":"dev","command":"uname -a"}
/// {"op":"k8s_enable"} {"op":"k8s_disable"} {"op":"k8s_status"}
pub fn dispatch(line: &str) -> String {
    let reply = dispatch_inner(line);
    format!("{reply}\n")
}

fn dispatch_inner(line: &str) -> String {
    let fields = match parse_fields(line) {
        Ok(fields) => fields,
        Err(error) => return format!("{{\"ok\":false,\"error\":\"{}\"}}", escape(&error)),
    };
    let field = |name: &str| fields.get(name).map(String::as_str).unwrap_or("");
    let op = field("op");
    // Serialize mutations while allowing list/status queries to run concurrently.
    let _guard = if matches!(op, "machine_create" | "machine_start" | "machine_stop"
        | "machine_delete" | "machine_exec" | "k8s_enable" | "k8s_disable") {
        Some(OPERATIONS.lock().unwrap_or_else(|e| e.into_inner()))
    } else { None };
    let result: Result<String, String> = match op {
        "machine_create" => machine_create(field("distro"), field("name")),
        "machine_start" => machine_start(field("name")),
        "machine_stop" => machine_stop(field("name")),
        "machine_delete" => machine_delete(field("name")),
        "machine_exec" => machine_exec(field("name"), field("command")),
        "machine_list" => Ok(machine_list().into_iter()
            .map(|(name, running, distro)| format!(
                "{name}:{}:{distro}", if running { "running" } else { "stopped" }))
            .collect::<Vec<_>>().join(", ")),
        "k8s_enable" => k8s_enable(),
        "k8s_disable" => k8s_disable(),
        "k8s_status" => Ok(k8s_status()),
        "ping" => Ok("pong".into()),
        _ => Err(format!("unknown op '{op}'")),
    };
    match result {
        Ok(message) => format!("{{\"ok\":true,\"message\":\"{}\"}}", escape(&message)),
        Err(error) => format!("{{\"ok\":false,\"error\":\"{}\"}}", escape(&error)),
    }
}

fn escape(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n")
}

/// Serves the control channel: one line-buffered request per connection.
pub fn serve(stream: std::os::unix::net::UnixStream) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let mut reader = io::BufReader::new(stream);
    let mut line = String::new();
    let reply = match (&mut reader).take(MAX_REQUEST_BYTES + 1).read_line(&mut line) {
        Ok(0) => return,
        Ok(n) if n as u64 > MAX_REQUEST_BYTES =>
            "{\"ok\":false,\"error\":\"request too large\"}\n".to_string(),
        Ok(_) if !line.ends_with('\n') =>
            "{\"ok\":false,\"error\":\"missing request newline\"}\n".to_string(),
        Ok(_) => dispatch(line.trim_end_matches(['\r', '\n'])),
        Err(_) => "{\"ok\":false,\"error\":\"cannot read request\"}\n".to_string(),
    };
    let _ = reader.get_mut().write_all(reply.as_bytes());

}
