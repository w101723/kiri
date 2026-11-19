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
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::net::UnixStream;
    use std::thread;
    use std::time::Duration;

    const DOCKER_VSOCK_PORT: u32 = 2375; // AF_VSOCK; never a TCP listener

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
