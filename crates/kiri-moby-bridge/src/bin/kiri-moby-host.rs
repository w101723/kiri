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
    use std::io;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

    use kiri_vmm::{Config, Share, ShareDir, Vm};

    const DOCKER_VSOCK_PORT: u32 = 2375; // AF_VSOCK, NOT TCP

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
    let disk = guest.join("data.img");
    for required in [&kernel, &initrd, &disk] {
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

    let share = Share {
        tag: "kiri-mac".to_owned(),
        dirs: vec![
            ShareDir { name: "Users".to_owned(), dir: PathBuf::from("/Users") },
            ShareDir { name: "Volumes".to_owned(), dir: PathBuf::from("/Volumes") },
        ],
    };

    let vm = Vm::start(Config {
        cpus: 2,
        memory_mib: 2048,
        kernel,
        initrd,
        cmdline: "console=hvc0 rdinit=/init panic=-1".into(),
        console: None,
        agent_port: 5556,
        disk: Some(disk),
        share: Some(share),
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
    for client in listener.incoming() {
        let client = client?;
        let connector = Arc::clone(&connector);
        thread::spawn(move || {
            let mut connected = None;
            // The guest bootstrap may still be starting dockerd.
            for _ in 0..40 {
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
                    // Keep the VZ connection owner alive until the proxy exits.
                    match stream.fd.try_clone() {
                        Ok(fd) => {
                            if let Err(error) = kiri_moby_bridge::relay(client, UnixStream::from(fd)) {
                                eprintln!("Moby API relay ended: {error}");
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

    // Keep the VM alive for the lifetime of the listener.
    drop(vm);
    Ok(())
}
