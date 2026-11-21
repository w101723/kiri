//! Linux arm64 guest-side transport. The real dockerd owns the Docker API
//! socket and all container state; this program only relays bytes to it.
//!
//! Expected to be executed by the future Moby guest init after networking,
//! cgroups and persistent storage have been initialized.

#[cfg(not(all(target_os = "linux", target_arch = "aarch64")))]
fn main() {
    eprintln!("kiri-moby-guest is only supported on Linux aarch64");
    std::process::exit(2);
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
fn main() -> std::io::Result<()> {
    use std::io::{self, Read};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::net::UnixStream;
    use std::net::TcpStream;
    use std::thread;
    use std::time::Duration;

    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--version") {
        println!(
            "kiri-moby-guest {} ({})",
            env!("CARGO_PKG_VERSION"),
            option_env!("GITHUB_SHA").unwrap_or("local-build")
        );
        return Ok(());
    }
    if args.get(1).map(String::as_str) == Some("--mount-shares") {
        use std::ffi::CString;
        use std::path::Path;
        if args.len() != 3 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput,
                "--mount-shares requires an encoded share map"));
        }
        let shares = kiri_moby_bridge::shares::decode(&args[2])?;
        for (name, mount_path) in shares {
            let source = format!("/mnt/mac/{name}");
            if !Path::new(&source).is_dir() {
                return Err(io::Error::new(io::ErrorKind::NotFound,
                    format!("VirtioFS share unavailable: {source}")));
            }
            std::fs::create_dir_all(&mount_path)?;
            let from = CString::new(source).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL source"))?;
            let to = CString::new(mount_path.to_string_lossy().as_bytes())
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL target"))?;
            // SAFETY: Validated, NUL-terminated strings remain live through
            // this synchronous syscall. Extra pointers are null.
            if unsafe {
                libc::mount(from.as_ptr(), to.as_ptr(), std::ptr::null(), libc::MS_BIND, std::ptr::null())
            } != 0 {
                return Err(io::Error::last_os_error());
            }
            eprintln!("kiri-moby-guest: mounted authorized directory {}", mount_path.display());
        }
        return Ok(());
    }

    if args.get(1).map(String::as_str) == Some("--set-clock") {
        if args.len() != 3 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "--set-clock requires a Unix epoch argument"));
        }
        let seconds: i64 = args[2].parse().map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidInput, "invalid Unix epoch")
        })?;
        // Reject values wildly outside modern Docker/TLS validity. A host
        // already using a broken clock should fail visibly, not silently
        // produce an unusable Docker engine.
        if !(1_700_000_000..=4_102_444_800).contains(&seconds) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "host Unix epoch outside permitted range"));
        }
        let proposed = libc::timespec {
            tv_sec: seconds as libc::time_t,
            tv_nsec: 0,
        };
        // SAFETY: clock_settime reads one fully initialized timespec.
        if unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &proposed) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let mut observed = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        // SAFETY: clock_gettime writes one valid timespec into the buffer.
        if unsafe { libc::clock_gettime(libc::CLOCK_REALTIME, &mut observed) } != 0 {
            return Err(io::Error::last_os_error());
        }
        if (observed.tv_sec as i64 - seconds).abs() > 120 {
            return Err(io::Error::other("CLOCK_REALTIME did not match host boot time"));
        }
        eprintln!("kiri-moby-guest: CLOCK_REALTIME synchronized: {}", observed.tv_sec);
        return Ok(());
    }

    const DOCKER_VSOCK_PORT: u32 = 2375; // AF_VSOCK; never a TCP listener
    const CONTROL_VSOCK_PORT: u32 = 2376; // authenticated by guest-only vsock boundary
    const TCP_FORWARD_VSOCK_PORT: u32 = 2377; // Docker guest TCP published ports
    const MEMORY_VSOCK_PORT: u32 = 2378; // read-only /proc/meminfo telemetry


    // SAFETY: creates an AF_VSOCK stream socket and transfers ownership to
    // OwnedFd immediately; all addresses and lengths are initialized.
    fn listen(port: u32) -> io::Result<OwnedFd> {
        unsafe {
            let fd = libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0);
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            let socket = OwnedFd::from_raw_fd(fd);
            let mut addr: libc::sockaddr_vm = std::mem::zeroed();
            addr.svm_family = libc::AF_VSOCK as libc::sa_family_t;
            addr.svm_cid = libc::VMADDR_CID_ANY;
            addr.svm_port = port;
            let result = libc::bind(
                socket.as_raw_fd(),
                (&addr as *const libc::sockaddr_vm).cast(),
                std::mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t,
            );
            if result < 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::listen(socket.as_raw_fd(), 128) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(socket)
        }
    }

    let control = listen(CONTROL_VSOCK_PORT)?;
    // A real guest PID 1 supervises dockerd/containerd. Ask it to stop
    // gracefully before host VZ retires its disk (not a forced power loss).
    thread::spawn(move || loop {
        // SAFETY: kernel returns a newly-owned fd or -1; no pointers passed.
        let peer = unsafe {
            libc::accept4(control.as_raw_fd(), std::ptr::null_mut(), std::ptr::null_mut(), libc::SOCK_CLOEXEC)
        };
        if peer < 0 {
            continue;
        }
        // SAFETY: accept4 returned an owned fd.
        let mut stream = UnixStream::from(unsafe { OwnedFd::from_raw_fd(peer) });
        let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
        let mut command = [0u8; 9];
        if stream.read_exact(&mut command).is_ok() && command == *b"SHUTDOWN\n" {
            eprintln!("moby guest: graceful shutdown requested");
            // SAFETY: PID 1 is our init shell and has a SIGTERM trap.
            unsafe { libc::kill(1, libc::SIGTERM) };
            return;
        }
    });

    // Read-only memory telemetry over private AF_VSOCK. No shell commands,
    // cache clearing or host-visible Docker API extensions.
    let mem_listener = listen(MEMORY_VSOCK_PORT)?;
    thread::spawn(move || loop {
        use std::io::Write;
        let peer = unsafe {
            libc::accept4(mem_listener.as_raw_fd(), std::ptr::null_mut(),
                std::ptr::null_mut(), libc::SOCK_CLOEXEC)
        };
        if peer < 0 { continue; }
        let mut stream = UnixStream::from(unsafe { OwnedFd::from_raw_fd(peer) });
        if let Ok(contents) = std::fs::read_to_string("/proc/meminfo") {
            if let Some(sample) = kiri_moby_bridge::memory::GuestMemory::from_meminfo(&contents) {
                let _ = stream.write_all(sample.wire().as_bytes());
            }
        }
    });

    // A Mac listener sends the destination port as two network-order bytes.
    // We connect to the *guest* published port, not directly to a container:
    // Docker Engine remains the owner of container NAT and port semantics.
    let forwards = listen(TCP_FORWARD_VSOCK_PORT)?;
    thread::spawn(move || loop {
        // SAFETY: accept4 yields an owned fd, with no user pointers.
        let fd = unsafe {
            libc::accept4(forwards.as_raw_fd(), std::ptr::null_mut(), std::ptr::null_mut(), libc::SOCK_CLOEXEC)
        };
        if fd < 0 { continue; }
        // SAFETY: accept4 succeeded and ownership is transferred once.
        let peer = unsafe { OwnedFd::from_raw_fd(fd) };
        thread::spawn(move || {
            let mut from_host = UnixStream::from(peer);
            let mut header = [0u8; 2];
            if from_host.read_exact(&mut header).is_err() { return; }
            let port = u16::from_be_bytes(header);
            if port == 0 { return; }
            match TcpStream::connect(("127.0.0.1", port)) {
                Ok(to_docker) => {
                    let fd: OwnedFd = to_docker.into();
                    if let Err(err) = kiri_moby_bridge::relay(from_host, UnixStream::from(fd)) {
                        eprintln!("guest TCP published-port relay ended: {err}");
                    }
                }
                Err(err) => eprintln!("guest published port {port} not reachable: {err}"),
            }
        });
    });

    let socket = listen(DOCKER_VSOCK_PORT)?;
    let engine_path = std::env::var("KIRI_MOBY_ENGINE_SOCKET")
        .unwrap_or_else(|_| "/var/run/docker.sock".into());

    eprintln!("moby guest bridge listening on vsock:{DOCKER_VSOCK_PORT}");
    loop {
        // SAFETY: accept4 returns an owned client fd, or -1 with errno.
        let peer = unsafe {
            libc::accept4(
                socket.as_raw_fd(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                libc::SOCK_CLOEXEC,
            )
        };
        if peer < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        // SAFETY: accept4 succeeded and this worker exclusively owns the fd.
        let peer = unsafe { OwnedFd::from_raw_fd(peer) };
        let path = engine_path.clone();
        thread::spawn(move || {
            let client = UnixStream::from(peer);
            let mut engine = None;
            for _ in 0..40 {
                match UnixStream::connect(&path) {
                    Ok(sock) => {
                        engine = Some(sock);
                        break;
                    }
                    Err(_) => thread::sleep(Duration::from_millis(250)),
                }
            }
            if let Some(engine) = engine {
                if let Err(error) = kiri_moby_bridge::relay(client, engine) {
                    eprintln!("moby guest proxy connection ended: {error}");
                }
            } else {
                eprintln!("moby guest: dockerd socket was not ready: {path}");
            }
        });
    }
}
