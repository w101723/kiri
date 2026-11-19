//! Experimental macOS arm64 host-side bridge for a STANDARD Docker Engine VM.
//!
//! Requires a separately provisioned Linux Guest containing dockerd and the
//! kiri-moby-guest proxy. This is not wired to the existing Kiri application
//! yet. It never modifies OrbStack's or Colima's sockets or Docker contexts.

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
fn main() {
    eprintln!("kiri-moby-host is only supported on macOS Apple Silicon");
    std::process::exit(2);
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn main() -> std::io::Result<()> {
    use std::io::{self, Write};
    use std::net::TcpListener;
    use std::os::fd::OwnedFd;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::thread;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use kiri_vmm::{Config, Share, ShareDir, Vm};

    let build_revision = option_env!("GITHUB_SHA").unwrap_or("local-build");
    if std::env::args().nth(1).as_deref() == Some("--version") {
        println!("kiri-moby-host {} ({build_revision})", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    eprintln!("Kiri Moby Host: {} ({build_revision})", env!("CARGO_PKG_VERSION"));

    const DOCKER_VSOCK_PORT: u32 = 2375; // AF_VSOCK, NOT TCP
    const CONTROL_VSOCK_PORT: u32 = 2376; // graceful shutdown
    const TCP_FORWARD_VSOCK_PORT: u32 = 2377; // published port transport

    let data = match std::env::var_os("KIRI_MOBY_DATA_DIR") {
        Some(path) => PathBuf::from(path),
        None => {
            let home = std::env::var_os("HOME")
                .ok_or_else(|| io::Error::other("HOME is not defined"))?;
            PathBuf::from(home).join(".kiri-moby")
        }
    };
    std::fs::create_dir_all(&data)?;
    // The data folder can contain a Docker API socket (root-equivalent
    // access to the Guest); it must not be accessible to other local users.
    std::fs::set_permissions(&data, std::fs::Permissions::from_mode(0o700))?;

    let guest = data.join("guest");
    let kernel = guest.join("Image");
    let initrd = guest.join("initramfs.cpio");
    for required in [&kernel, &initrd] {
        if !required.is_file() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!(
                    "missing Moby guest asset {} (see docs/MOBY_ENGINE.md)",
                    required.display(),
                ),
            ));
        }
    }
    // The guest disk has a separate lifecycle from the read-only boot assets.
    // Never modify upstream Kiri's disk, or decompress into its directories.
    let vm_dir = data.join("vm");
    std::fs::create_dir_all(&vm_dir)?;
    std::fs::set_permissions(&vm_dir, std::fs::Permissions::from_mode(0o700))?;
    let disk = vm_dir.join("data.img");
    if !disk.is_file() {
        let archive = guest.join("data.img.tgz");
        if !archive.is_file() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("missing initial disk template {} (see docs/MOBY_ENGINE.md)", archive.display()),
            ));
        }
        let staging = vm_dir.join("staging");
        if staging.exists() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("staging directory exists; inspect before retrying: {}", staging.display()),
            ));
        }
        std::fs::create_dir_all(&staging)?;
        // Extract precisely the expected member, never an arbitrary tar tree.
        let unpacked = std::process::Command::new("/usr/bin/tar")
            .arg("-xzf")
            .arg(&archive)
            .arg("-C")
            .arg(&staging)
            .arg("data.img")
            .status()?;
        if !unpacked.success() {
            return Err(io::Error::other("failed to extract Moby guest ext4 disk template"));
        }
        std::fs::rename(staging.join("data.img"), &disk)?;
        std::fs::remove_dir(&staging)?;
    }

    // Explicit per-directory shares preserve the same Mac path in the Guest
    // without sharing the entirety of /Users or /Volumes. The kernel cmdline
    // carries an ASCII-only hex-encoded mapping; no shell/path injection.
    // Both this and the Guest apply strict path validation.
    let share_all = std::env::var("KIRI_MOBY_SHARE_MAC").ok().as_deref() == Some("1");
    let share_dirs = std::env::var("KIRI_MOBY_SHARE_DIRS").unwrap_or_default();
    if share_all && !share_dirs.trim().is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput,
            "KIRI_MOBY_SHARE_MAC=1 cannot be combined with KIRI_MOBY_SHARE_DIRS"));
    }
    let mut share_spec = String::new();
    let share = if !share_dirs.trim().is_empty() {
        let mut dirs = Vec::new();
        let mut selected = Vec::new();
        for input in share_dirs.split(',') {
            if input.is_empty() || input.trim() != input
                || !kiri_moby_bridge::shares::allowed_target(input)
            {
                return Err(io::Error::new(io::ErrorKind::InvalidInput,
                    format!("share must be a normalized absolute project directory under /Users or /Volumes: {input}")));
            }
            let resolved = std::path::Path::new(input).canonicalize()?;
            if !resolved.is_dir() {
                return Err(io::Error::new(io::ErrorKind::InvalidInput,
                    format!("Mac share is not a directory: {input}")));
            }
            let name = format!("s{}", dirs.len());
            selected.push(input.to_owned());
            dirs.push(ShareDir { name, dir: resolved });
        }
        // Enforce duplicate, traversal, count and size limits at the common
        // protocol boundary, and again on the Linux side before mount().
        share_spec = kiri_moby_bridge::shares::encode(&selected)?;
        eprintln!("Kiri Moby: {} explicit writable Mac directories authorized", dirs.len());
        Some(Share { tag: "kiri-mac".to_owned(), dirs })
    } else if share_all {
        eprintln!("WARNING: legacy KIRI_MOBY_SHARE_MAC=1 allows writable Mac /Users and /Volumes");
        Some(Share {
            tag: "kiri-mac".to_owned(),
            dirs: vec![
                ShareDir { name: "Users".to_owned(), dir: PathBuf::from("/Users") },
                ShareDir { name: "Volumes".to_owned(), dir: PathBuf::from("/Volumes") },
            ],
        })
    } else {
        eprintln!("Mac directory sharing disabled (use KIRI_MOBY_SHARE_DIRS=/Users/.../Projects)");
        None
    };

    let log_dir = data.join("logs");
    std::fs::create_dir_all(&log_dir)?;
    std::fs::set_permissions(&log_dir, std::fs::Permissions::from_mode(0o700))?;
    let console_log_path = log_dir.join("console.log");
    let console_log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&console_log_path)?;
    std::fs::set_permissions(&console_log_path, std::fs::Permissions::from_mode(0o600))?;
    eprintln!("Moby VM console: {}", console_log_path.display());

    let cpus = std::env::var("KIRI_MOBY_CPUS").ok().and_then(|v| v.parse::<usize>().ok()).filter(|v| (1..=16).contains(v)).unwrap_or(4);
    let memory_mib = std::env::var("KIRI_MOBY_MEMORY_MIB").ok().and_then(|v| v.parse::<u64>().ok()).filter(|v| (1024..=65536).contains(v)).unwrap_or(4096);
    // Virtualization.framework guests may start with a 1970 RTC.
    // Pass the actual host clock at VM creation so HTTPS image pulls work.
    let boot_epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| io::Error::other(format!("host clock before Unix epoch: {e}")))?
        .as_secs();
    let mut vm = Vm::start(Config {
        cpus,
        memory_mib,
        kernel,
        initrd,
        cmdline: format!(
            "console=hvc0 rdinit=/init panic=-1 kiri.moby_boot_time={boot_epoch}{}",
            if share_spec.is_empty() { String::new() }
            else { format!(" kiri.moby_shares={share_spec}") }
        ),
        console: Some(console_log.into()),
        agent_port: 5556,
        disk: Some(disk),
        share,
        rosetta_tag: Some("rosetta".into()),
        nat_mac: Some("02:4b:69:72:69:01".into()),
    })?;

    let run_dir = data.join("run");
    std::fs::create_dir_all(&run_dir)?;
    std::fs::set_permissions(&run_dir, std::fs::Permissions::from_mode(0o700))?;
    let path = run_dir.join("docker.sock");

    // Do not unlink an existing socket: it may be another live daemon, a
    // symlink, or a stale path the user needs to investigate explicitly.
    if std::fs::symlink_metadata(&path).is_ok() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("socket already exists at {}; refusing to replace it", path.display()),
        ));
    }
    let listener = UnixListener::bind(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;

    eprintln!("Moby VM started. Docker API: unix://{}", path.display());
    eprintln!("No default Docker context or /var/run/docker.sock has been changed.");

    let connector = Arc::new(vm.connector());
    let stopping = Arc::new(AtomicBool::new(false));
    ctrlc::set_handler({
        let stopping = Arc::clone(&stopping);
        move || stopping.store(true, Ordering::Release)
    }).map_err(|e| io::Error::other(format!("failed to register SIGINT/SIGTERM handler: {e}")))?;

    // Experimental explicit localhost-only TCP port forwarding:
    // KIRI_MOBY_TCP_PORTS="8080:8080,5432:5432" means
    // Mac localhost:8080 -> Guest published TCP port 8080 (created by Docker).
    // Docker still owns DNAT and container networking inside the VM.
    // Explicit rules override Docker API auto-discovery for TCP ports.
    // The automatic watcher uses bounded Docker API polling for now;
    // an event-stream implementation and UDP are follow-up work.
    let manual_ports = std::env::var("KIRI_MOBY_TCP_PORTS").unwrap_or_default();
    // During initial VM/Engine smoke tests, avoid automatic Docker API
    // probes and any Mac TCP port listeners.
    let disable_ports = std::env::var("KIRI_MOBY_DISABLE_PORT_FORWARD").ok().as_deref() == Some("1");
    let port_watcher = if !disable_ports && manual_ports.trim().is_empty() {
        // Docker /events triggers fast reconciliation; a 30s snapshot
        // recovers missed transitions. Join the worker before retiring VM.
        Some(kiri_moby_bridge::ports::start(
            path.clone(), Arc::clone(&connector), Arc::clone(&stopping)
        ))
    } else {
        None
    };
    for rule in manual_ports.split(',').filter(|s| !s.is_empty() && !disable_ports) {
        let (host, guest) = rule.split_once(':')
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, format!("invalid KIRI_MOBY_TCP_PORTS entry: {rule}")))?;
        let parse = |v: &str| -> io::Result<u16> {
            v.parse::<u16>().ok().filter(|p| *p > 0)
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, format!("invalid port: {v}")))
        };
        let host_port = parse(host)?;
        let guest_port = parse(guest)?;
        let tcp_listener = TcpListener::bind(("127.0.0.1", host_port))?;
        tcp_listener.set_nonblocking(true)?;
        eprintln!("Moby port forwarding: 127.0.0.1:{host_port} -> guest:{guest_port}/tcp");
        let connector = Arc::clone(&connector);
        let stopping = Arc::clone(&stopping);
        thread::spawn(move || {
            while !stopping.load(Ordering::Acquire) {
                let client = match tcp_listener.accept() {
                    Ok((client, _)) => client,
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(100));
                        continue;
                    }
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => {
                        eprintln!("Moby TCP listener stopped ({host_port}): {e}");
                        return;
                    }
                };
                let connector = Arc::clone(&connector);
                thread::spawn(move || {
                    let stream = match connector.connect(TCP_FORWARD_VSOCK_PORT) {
                        Ok(stream) => stream,
                        Err(error) => {
                            eprintln!("Moby manual TCP 127.0.0.1:{host_port}: Guest vsock connect failed: {error}");
                            return;
                        }
                    };
                    let fd = match stream.fd.try_clone() {
                        Ok(fd) => fd,
                        Err(error) => {
                            eprintln!("Moby manual TCP 127.0.0.1:{host_port}: Guest vsock fd clone failed: {error}");
                            return;
                        }
                    };
                    let mut to_guest = UnixStream::from(fd);
                    if let Err(error) = to_guest.write_all(&guest_port.to_be_bytes()) {
                        eprintln!("Moby manual TCP 127.0.0.1:{host_port}: Guest port header failed: {error}");
                        return;
                    }
                    let client: OwnedFd = client.into();
                    if let Err(error) = kiri_moby_bridge::relay(UnixStream::from(client), to_guest) {
                        if !matches!(error.kind(), io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset)
                            || std::env::var_os("KIRI_MOBY_DEBUG").is_some()
                        {
                            eprintln!("Moby manual TCP 127.0.0.1:{host_port} relay failed: {error}");
                        }
                    }
                    drop(stream);
                });
            }
        });
    }

    // Avoid waiting forever in accept() after Ctrl-C, so dockerd can stop
    // cleanly and flush the ext4 data disk before VM destruction.
    listener.set_nonblocking(true)?;
    while !stopping.load(Ordering::Acquire) {
        let client = match listener.accept() {
            Ok((client, _)) => client,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(100));
                continue;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        let connector = Arc::clone(&connector);
        thread::spawn(move || {
            let mut connected = None;
            for _ in 0..120 {
                match connector.connect(DOCKER_VSOCK_PORT) {
                    Ok(stream) => {
                        connected = Some(stream);
                        break;
                    }
                    Err(_) => thread::sleep(Duration::from_millis(250)),
                }
            }
            match connected {
                Some(stream) => {
                    // Keep the VZ connection alive throughout HTTP Upgrade,
                    // Docker attach and BuildKit's long-running streams.
                    match stream.fd.try_clone() {
                        Ok(fd) => {
                            if let Err(error) = kiri_moby_bridge::relay(client, UnixStream::from(fd)) {
                                if !matches!(error.kind(), io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset)
                                    || std::env::var_os("KIRI_MOBY_DEBUG").is_some()
                                {
                                    eprintln!("Moby API relay ended: {error}");
                                }
                            }
                        }
                        Err(error) => eprintln!("Cannot clone vsock fd: {error}"),
                    }
                    drop(stream);
                }
                None => eprintln!("Moby guest vsock bridge is not ready"),
            }
        });
    }

    eprintln!("Stopping standard Docker Engine gracefully...");
    // Ensure /events curl is killed and reaped, and Mac TCP listeners have
    // closed, before releasing the guest or reusing their localhost ports.
    if let Some(worker) = port_watcher {
        if worker.join().is_err() {
            eprintln!("Kiri/Moby: port watcher panicked during shutdown");
        }
    }
    if let Ok(control) = connector.connect(CONTROL_VSOCK_PORT) {
        if let Ok(fd) = control.fd.try_clone() {
            let mut control = UnixStream::from(fd);
            let _ = control.write_all(b"SHUTDOWN\n");
        }
    }
    // The VM must release its disk before a replacement opens it.
    let shutdown = vm.retire(Duration::from_secs(25), Duration::from_secs(10));
    drop(listener);
    let _ = std::fs::remove_file(&path);
    shutdown?;
    Ok(())
}
