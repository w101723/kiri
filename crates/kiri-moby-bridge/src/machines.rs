//! Machine and Kubernetes lifecycle control, OrbStack-style.
//!
//! One VM hosts everything: the btrfs data disk carries a subvolume per
//! machine rootfs, k3s state for the local cluster, and the docker subvolume.
//! Machines are full-distro rootfs subvolumes (cloned from official distro
//! images via `docker export`) whose PID1 is the distro's real init (systemd
//! where present) running in private mount/PID namespaces. The host drives
//! this module over an authenticated AF_VSOCK control channel (port 2379);
//! the vsock boundary is the authentication, mirroring the Docker port.

use std::io::{self, BufRead, Write};
use std::path::Path;
use std::process::Command;

pub const MACHINE_VSOCK_PORT: u32 = 2379;

const MACHINES_ROOT: &str = "/mnt/data/machines";

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
    if Path::new(&rootfs).exists() {
        return Err(format!("machine '{name}' already exists"));
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
                "mkdir {MACHINES_ROOT}/{name} && btrfs subvolume create {rootfs}.new && docker export {container} | tar -xpf - -C {rootfs}.new && mv -T {rootfs}.new {rootfs} && rm -f {rootfs}/.dockerenv"
            ),
        ],
    );
    let _ = sh("docker", &["rm", "-f", &container]);
    unpack.map_err(|e| format!("rootfs unpack failed: {e}"))?;

    // A machine needs a resolvable init; distro images carry /sbin/init.
    if !Path::new(&format!("{rootfs}/sbin/init")).exists()
        && !Path::new(&format!("{rootfs}/usr/sbin/init")).exists()
    {
        let _ = machine_delete(name);
        return Err(format!("image {image} has no /sbin/init; not machine-capable"));
    }
    Ok(format!("machine '{name}' created ({distro})"))
}

/// Lists machines and their running state (PID of the machine's init).
pub fn machine_list() -> Vec<(String, bool)> {
    let mut machines = Vec::new();
    let Ok(entries) = std::fs::read_dir(MACHINES_ROOT) else {
        return machines;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if Path::new(&machine_rootfs(&name)).is_dir() {
            let running = machine_pid(&name).is_some();
            machines.push((name, running));
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
    if !valid_name(name) {
        return Err("invalid machine name".into());
    }
    if machine_pid(name).is_some() {
        return Ok(format!("machine '{name}' already running"));
    }
    let rootfs = machine_rootfs(name);
    if !Path::new(&rootfs).is_dir() {
        return Err(format!("machine '{name}' does not exist"));
    }
    // unshare --fork leaves the distro init as PID1 of the new namespace;
    // the backgrounded unshare keeps a root-namespace PID that `machine_pid`
    // locates via the init's /proc root link.
    let script = format!(
        "unshare --mount --pid --fork --mount-proc={rootfs}/proc \
         sh -c 'mount --rbind /dev {rootfs}/dev; \
                mount --rbind /sys {rootfs}/sys; \
                mount --rbind /run {rootfs}/run-host; \
                exec chroot {rootfs} /sbin/init' >/dev/null 2>&1 &"
    );
    sh("sh", &["-c", script.as_str()]).map_err(|e| format!("machine start failed: {e}"))?;
    Ok(format!("machine '{name}' started"))
}

pub fn machine_stop(name: &str) -> Result<String, String> {
    match machine_pid(name) {
        None => Ok(format!("machine '{name}' is not running")),
        Some(pid) => {
            // SIGRTMIN+3 is systemd's poweroff; plain SIGTERM for sysv init.
            // BusyBox init ignores neither but reacts to neither immediately,
            // so the escalation below is what actually reaps it.
            let _ = Command::new("kill")
                .args(["-s", "SIGRTMIN+3", &pid.to_string()])
                .status();
            std::thread::sleep(std::time::Duration::from_secs(2));
            let _ = Command::new("kill").arg(pid.to_string()).status();
            std::thread::sleep(std::time::Duration::from_secs(2));
            if machine_pid(name).is_some() {
                let _ = Command::new("kill").args(["-9", &pid.to_string()]).status();
            }
            Ok(format!("machine '{name}' stopped"))
        }
    }
}

pub fn machine_delete(name: &str) -> Result<String, String> {
    if !valid_name(name) {
        return Err("invalid machine name".into());
    }
    let _ = machine_stop(name);
    let rootfs = machine_rootfs(name);
    if !Path::new(&rootfs).exists() {
        return Ok(format!("machine '{name}' did not exist"));
    }
    sh("btrfs", &["subvolume", "delete", &rootfs])
        .or_else(|_| sh("rm", &["-rf", &rootfs]))
        .map_err(|e| format!("machine delete failed: {e}"))?;
    Ok(format!("machine '{name}' deleted"))
}

/// Executes one command inside a running machine via its rootfs (chroot into
/// the same namespaces the init runs in is not addressable without nsenter;
/// nsenter -t <init pid> joins them).
pub fn machine_exec(name: &str, command: &str) -> Result<String, String> {
    let pid = machine_pid(name).ok_or_else(|| format!("machine '{name}' is not running"))?;
    sh(
        "nsenter",
        &["-t", &pid.to_string(), "-m", "-p", "--", "/bin/sh", "-c", command],
    )
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

pub fn k8s_disable() -> Result<String, String> {
    if let Ok(pid) = std::fs::read_to_string(format!("{K8S_DATA}.pid")) {
        let _ = Command::new("kill").arg(pid.trim()).status();
        let _ = std::fs::remove_file(format!("{K8S_DATA}.pid"));
    }
    Ok("kubernetes stopped (state kept)".into())
}

pub fn k8s_status() -> String {
    match std::fs::read_to_string(format!("{K8S_DATA}.pid")) {
        Ok(pid) if Path::new(&format!("/proc/{}/comm", pid.trim())).exists() => "running".into(),
        _ => "disabled".into(),
    }
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

fn field<'a>(json: &'a str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let start = json.find(&needle)? + needle.len();
    let rest = &json[start..];
    let colon = rest.find(':')?;
    let rest = rest[colon + 1..].trim_start();
    let quoted = rest.strip_prefix('"')?;
    let end = quoted.find('"')?;
    Some(quoted[..end].to_string())
}

fn dispatch_inner(line: &str) -> String {
    let op = field(line, "op").unwrap_or_default();
    let name = field(line, "name").unwrap_or_default();
    let result: Result<String, String> = match op.as_str() {
        "machine_create" => machine_create(&field(line, "distro").unwrap_or_default(), &name),
        "machine_start" => machine_start(&name),
        "machine_stop" => machine_stop(&name),
        "machine_delete" => machine_delete(&name),
        "machine_exec" => machine_exec(&name, &field(line, "command").unwrap_or_default()),
        "machine_list" => Ok(machine_list()
            .into_iter()
            .map(|(name, running)| format!("{name}:{}", if running { "running" } else { "stopped" }))
            .collect::<Vec<_>>()
            .join(", ")),
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
    let mut reader = io::BufReader::new(stream);
    let mut line = String::new();
    match reader.read_line(&mut line) {
        Ok(0) | Err(_) => return,
        Ok(_) => {}
    }
    let reply = dispatch(line.trim_end());
    if let Some(mut stream) = reader.get_mut().try_clone().ok() {
        let _ = stream.write_all(reply.as_bytes());
    }
}
