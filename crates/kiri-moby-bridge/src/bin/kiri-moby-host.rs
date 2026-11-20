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
    use kiri_moby_bridge::memory::{GuestMemory, Governor};
    use std::sync::{mpsc, Mutex};


    let build_revision = option_env!("GITHUB_SHA").unwrap_or("local-build");
    if std::env::args().nth(1).as_deref() == Some("--version") {
        println!("kiri-moby-host {} ({build_revision})", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    eprintln!("Kiri Moby Host: {} ({build_revision})", env!("CARGO_PKG_VERSION"));

    const DOCKER_VSOCK_PORT: u32 = 2375; // AF_VSOCK, NOT TCP
    const CONTROL_VSOCK_PORT: u32 = 2376; // graceful shutdown
    const TCP_FORWARD_VSOCK_PORT: u32 = 2377; // published port transport
    const MEMORY_VSOCK_PORT: u32 = 2378; // read-only Guest telemetry


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

    // Exclusive VM-disk ownership before constructing the VZ VM. Two GUI
    // processes must never mount the same writable ext4 image concurrently.
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::FileTypeExt;
    let single_host_lock = std::fs::OpenOptions::new()
        .create(true).read(true).write(true)
        .open(data.join("moby-vm.lock"))?;
    if unsafe { libc::flock(single_host_lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(io::Error::new(io::ErrorKind::AlreadyExists,
            "another Kiri Moby Host owns this VM/data.img; refusing concurrent mount"));
    }
    let run_paths = data.join("run");
    for name in ["docker.sock", "host-control.sock"] {
        let old = run_paths.join(name);
        if let Ok(meta) = std::fs::symlink_metadata(&old) {
            if !meta.file_type().is_socket() {
                return Err(io::Error::new(io::ErrorKind::AlreadyExists,
                    format!("refusing non-socket path {}", old.display())));
            }
            if UnixStream::connect(&old).is_ok() {
                return Err(io::Error::new(io::ErrorKind::AlreadyExists,
                    format!("Kiri Moby socket is active at {}", old.display())));
            }
            // The exclusive lock is held and the socket has no live server.
            // Recover a stale socket after a previous crash; never unlink a
            // symlink, regular file or a currently connected Engine.
            std::fs::remove_file(&old)?;
        }
    }

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

    // On-disk OS seed is read-only to the Guest. Replace it only while holding
    // exclusive ownership of the VM/data.img, and never rewrite user data.
    // Existing Kiri installations are upgraded inside Linux only if the
    // rootfs revision is different; normal boots perform no userspace copy.
    let seed_archive = guest.join("system.img.tgz");
    let seed_revision_path = guest.join("rootfs.revision");
    let revision = std::fs::read_to_string(&seed_revision_path).map_err(|e| {
        io::Error::new(e.kind(), format!("missing rootfs.revision (install upgraded Guest assets): {e}"))
    })?;
    let revision = revision.trim();
    if revision.len() != 64 || !revision.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(io::Error::new(io::ErrorKind::InvalidData,
            "invalid rootfs.revision; refusing to start with unverified seed"));
    }
    if !seed_archive.is_file() {
        return Err(io::Error::new(io::ErrorKind::NotFound,
            format!("missing read-only system seed {}; install matching Guest bundle",
                seed_archive.display())));
    }
    let seed_disk = vm_dir.join("system.img");
    let seed_stamp = vm_dir.join("system.revision");
    let needs_seed_update = !seed_disk.is_file()
        || std::fs::read_to_string(&seed_stamp).ok().as_deref().map(str::trim) != Some(revision);
    if needs_seed_update {
        let staging = vm_dir.join("system-staging");
        if staging.exists() {
            return Err(io::Error::new(io::ErrorKind::AlreadyExists,
                format!("incomplete seed upgrade at {}; inspect manually", staging.display())));
        }
        std::fs::create_dir_all(&staging)?;
        let unpacked = std::process::Command::new("/usr/bin/tar")
            .arg("-xzf").arg(&seed_archive).arg("-C").arg(&staging)
            .arg("system.img").status()?;
        if !unpacked.success() || !staging.join("system.img").is_file() {
            return Err(io::Error::other("failed to extract verified system.img seed"));
        }
        let fsync = std::fs::OpenOptions::new().read(true)
            .open(staging.join("system.img"))?;
        fsync.sync_all()?;
        drop(fsync);
        std::fs::rename(staging.join("system.img"), &seed_disk)?;
        std::fs::remove_dir(&staging)?;
        let tmp = vm_dir.join("system.revision.new");
        let mut stamp = std::fs::OpenOptions::new().write(true)
            .create_new(true).open(&tmp)?;
        stamp.write_all(revision.as_bytes())?;
        stamp.write_all(b"\n")?;
        stamp.sync_all()?;
        drop(stamp);
        std::fs::rename(tmp, &seed_stamp)?;
        eprintln!("Kiri Moby: installed read-only userspace seed rev={revision}");
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

    // Opt-in, one-shot diagnostic only. Never force cache eviction in normal Docker operation.
    let idle_drop_caches = std::env::var("KIRI_MOBY_IDLE_DROP_CACHES")
        .ok().as_deref() == Some("1");
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
            "console=hvc0 rdinit=/init panic=-1 kiri.moby_boot_time={boot_epoch}{}{}",
            if share_spec.is_empty() { String::new() }
            else { format!(" kiri.moby_shares={share_spec}") },
            if idle_drop_caches { " kiri.moby_idle_drop_caches=1" } else { "" }
        ),
        console: Some(console_log.into()),
        agent_port: 5556,
        disk: Some(disk),
        seed_disk: Some(seed_disk),
        share,
        rosetta_tag: Some("rosetta".into()),
        nat_mac: Some("02:4b:69:72:69:01".into()),
    })?;

    if idle_drop_caches {
        eprintln!("Kiri Moby memory lab: experimental one-shot idle file-cache eviction enabled");
    }
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

    // Private local lifecycle channel for the native Kiri GUI. This is
    // separate from Docker Engine and never forwarded into the Guest.
    // Same-user access is already root-equivalent through docker.sock.
    let control_path = run_dir.join("host-control.sock");
    if std::fs::symlink_metadata(&control_path).is_ok() {
        return Err(io::Error::new(io::ErrorKind::AlreadyExists,
            format!("control socket exists; refusing to replace {}", control_path.display())));
    }
    let control_listener = UnixListener::bind(&control_path)?;
    std::fs::set_permissions(&control_path, std::fs::Permissions::from_mode(0o600))?;
    control_listener.set_nonblocking(true)?;
    // Human-readable, same-user-only diagnostics. Target is the guest's
    // balloon target, NOT proven macOS physical-memory reclamation.
    let memory_report = Arc::new(Mutex::new((memory_mib, 0_u64, 0_u64)));
    let control_memory = Arc::clone(&memory_report);
    let control_stop = Arc::clone(&stopping);
    let control_worker = thread::spawn(move || {
        while !control_stop.load(Ordering::Acquire) {
            match control_listener.accept() {
                Ok((mut client, _)) => {
                    use std::io::Read;
                    let _ = client.set_read_timeout(Some(Duration::from_secs(2)));
                    let mut request = [0_u8; 5];
                    if client.read_exact(&mut request).is_ok() && &request == b"STAT\n" {
                        let (target, total, available) = *control_memory.lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner());
                        let output = format!(
                            "{{\"balloon_target_mib\":{target},\"guest_total_kib\":{total},\"guest_available_kib\":{available},\"host_reclaimed_bytes\":null}}\n"
                        );
                        let _ = client.write_all(output.as_bytes());
                    } else if &request == b"STOP\n" {
                        let _ = client.write_all(b"OK\n");
                        control_stop.store(true, Ordering::Release);
                    } else {
                        let _ = client.write_all(b"ERR\n");
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(100));
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) => {
                    eprintln!("Kiri Moby local lifecycle listener stopped: {error}");
                    return;
                }
            }
        }
    });

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
    let (memory_kick_tx, memory_kick_rx) = mpsc::sync_channel::<()>(1);
    // Keep the sender alive even when the port watcher is disabled. The
    // receiver can then wait with a timeout without spinning on disconnect.
    let _memory_kick_keepalive = memory_kick_tx.clone();
    let port_watcher = if !disable_ports && manual_ports.trim().is_empty() {
        // Docker /events triggers fast reconciliation; a 30s snapshot
        // recovers missed transitions. Join the worker before retiring VM.
        Some(kiri_moby_bridge::ports::start(
            path.clone(), Arc::clone(&connector), Arc::clone(&stopping),
            Some(memory_kick_tx)
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

    // Periodic lightweight Guest samples must never hold up Docker API
    // accept, Compose, or Buildx. Missing or malformed telemetry is fail-open:
    // retain the current memory target rather than risking an OOM.
    let (memory_tx, memory_rx) = mpsc::sync_channel::<(GuestMemory, bool)>(1);
    let memory_stop = Arc::clone(&stopping);
    let memory_connector = Arc::clone(&connector);
    let memory_worker = thread::spawn(move || {
        let mut exited_container = false;
        while !memory_stop.load(Ordering::Acquire) {
            if let Ok(stream) = memory_connector.connect(MEMORY_VSOCK_PORT) {
                if let Ok(fd) = stream.fd.try_clone() {
                    let mut peer = UnixStream::from(fd);
                    let mut bytes = [0_u8; 128];
                    let mut len = 0;
                    // VZ AF_VSOCK can remain O_NONBLOCK after duplication.
                    // Poll until a complete newline-terminated sample arrives,
                    // with a strict bound so shutdown never waits on a peer.
                    let deadline = std::time::Instant::now() + Duration::from_millis(700);
                    while len < bytes.len() && std::time::Instant::now() < deadline {
                        let mut pfd = libc::pollfd {
                            fd: peer.as_raw_fd(),
                            events: libc::POLLIN,
                            revents: 0,
                        };
                        let ready = unsafe { libc::poll(&mut pfd, 1, 100) };
                        if ready <= 0 { continue; }
                        if pfd.revents & libc::POLLIN == 0 { break; }
                        match std::io::Read::read(&mut peer, &mut bytes[len..]) {
                            Ok(0) => break,
                            Ok(n) => {
                                len += n;
                                if bytes[..len].contains(&b'\n') { break; }
                            }
                            Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
                            Err(_) => break,
                        }
                    }
                    if len > 0 && bytes[..len].last() == Some(&b'\n') {
                        if let Ok(line) = std::str::from_utf8(&bytes[..len]) {
                            if let Some(sample) = GuestMemory::from_wire(line) {
                                let _ = memory_tx.try_send((sample, exited_container));
                            }
                        }
                    }
                }
            }
            // Normal interval is two seconds; Docker exit/stop events cut
            // short the wait to promptly re-sample reclaimed memory.
            exited_container = memory_kick_rx.recv_timeout(Duration::from_secs(2)).is_ok();
            while memory_kick_rx.try_recv().is_ok() {
                exited_container = true;
            }
        }
    });
    let adaptive_memory = std::env::var("KIRI_MOBY_MEMORY_POLICY")
        .ok().as_deref() != Some("off");
    let mut memory_governor = Governor::new(memory_mib);
    eprintln!("Kiri Moby memory: adaptive={} ceiling={}MiB (macOS RSS recovery is not guaranteed)",
        adaptive_memory, memory_mib);

    // Avoid waiting forever in accept() after Ctrl-C, so dockerd can stop
    // cleanly and flush the ext4 data disk before VM destruction.
    listener.set_nonblocking(true)?;
    while !stopping.load(Ordering::Acquire) {
        while let Ok((sample, exited_container)) = memory_rx.try_recv() {
            if exited_container { memory_governor.released_hint(); }
            let old_target = memory_governor.target_mib();
            let new_target = if adaptive_memory { memory_governor.update(sample) } else { None };
            if let Some(next_mib) = new_target {
                if vm.set_memory_target(next_mib * 1024 * 1024).is_some() {
                    eprintln!("Kiri Moby memory: balloon target {} -> {} MiB, Guest MemAvailable={} MiB",
                        old_target, next_mib, sample.available_kib / 1024);
                } else {
                    // Disable attempted updates if Virtualization.framework did
                    // not supply a traditional balloon device.
                    eprintln!("Kiri Moby memory: VZ balloon device unavailable");
                }
            }
            *memory_report.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) =
                (memory_governor.target_mib(), sample.total_kib, sample.available_kib);
        }
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
    if memory_worker.join().is_err() {
        eprintln!("Kiri Moby memory telemetry worker panicked");
    }
    if control_worker.join().is_err() {
        eprintln!("Kiri Moby local lifecycle worker panicked");
    }
    let _ = std::fs::remove_file(&control_path);
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
