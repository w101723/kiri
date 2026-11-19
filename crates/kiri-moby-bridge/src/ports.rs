//! macOS published TCP-port reconciliation for a STANDARD Docker Engine.
//!
//! Docker Engine remains authoritative. We read GET /containers/json from
//! dockerd on a private Unix socket; no Kiri container state DB or API proxy
//! rewriting. The macOS listener forwards to dockerd's *published guest port*,
//! not directly to a container IP. TCP only for this milestone.
//!
//! TODO: replace short polling with Docker /events subscriptions; implement UDP
//! and preserve published bind-address semantics. Current safe default only
//! exposes ports on Mac 127.0.0.1.

#![cfg(target_os = "macos")]

use std::collections::BTreeMap;
use std::io::{self, Write};
use std::net::TcpListener;
use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

use kiri_vmm::Connector;

const TCP_FORWARD_VSOCK_PORT: u32 = 2377;
const POLL_INTERVAL: Duration = Duration::from_secs(2);

fn published_ports(doc: &serde_json::Value) -> BTreeMap<u16, u16> {
    let mut ports = BTreeMap::new();
    let Some(containers) = doc.as_array() else { return ports };
    for container in containers {
        let Some(rows) = container.get("Ports").and_then(|v| v.as_array()) else { continue };
        for row in rows {
            if row.get("Type").and_then(|v| v.as_str()) != Some("tcp") { continue; }
            let Some(host) = row.get("PublicPort").and_then(|v| v.as_u64()).and_then(|p| u16::try_from(p).ok()) else { continue };
            if host == 0 { continue; }
            // The guest Docker Engine uses the same published port as the Mac
            // for ordinary -p 8080:80. Do not bypass Docker's guest-side NAT.
            ports.insert(host, host);
        }
    }
    ports
}

fn list_published(socket: &PathBuf) -> io::Result<BTreeMap<u16, u16>> {
    // macOS ships /usr/bin/curl. A bounded CLI call avoids implementing a
    // second fragile HTTP/chunked parser for the Docker Engine API.
    let out = Command::new("/usr/bin/curl")
        .args(["--fail", "--silent", "--show-error", "--max-time", "3", "--unix-socket"])
        .arg(socket)
        .arg("http://localhost/containers/json?all=0")
        .output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!("dockerd list containers failed: {}", String::from_utf8_lossy(&out.stderr))));
    }
    let parsed: serde_json::Value = serde_json::from_slice(&out.stdout)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    Ok(published_ports(&parsed))
}

fn tcp_listener(
    host: u16,
    guest: u16,
    connector: Arc<Connector>,
    shutdown: Arc<AtomicBool>,
) -> io::Result<()> {
    let listener = TcpListener::bind(("127.0.0.1", host))?;
    listener.set_nonblocking(true)?;
    eprintln!("Kiri/Moby: published 127.0.0.1:{host} -> guest:{guest}/tcp");
    thread::spawn(move || {
        while !shutdown.load(Ordering::Acquire) {
            let client = match listener.accept() {
                Ok((client, _)) => client,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(100));
                    continue;
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => {
                    eprintln!("Kiri/Moby TCP port {host} listener stopped: {e}");
                    return;
                }
            };
            let connector = Arc::clone(&connector);
            thread::spawn(move || {
                let Ok(stream) = connector.connect(TCP_FORWARD_VSOCK_PORT) else { return };
                let Ok(fd) = stream.fd.try_clone() else { return };
                let mut to_guest = UnixStream::from(fd);
                if to_guest.write_all(&guest.to_be_bytes()).is_ok() {
                    let client: OwnedFd = client.into();
                    let _ = crate::relay(UnixStream::from(client), to_guest);
                }
                drop(stream);
            });
        }
    });
    Ok(())
}

/// Start a background port reconciler. Its stop token belongs to the VM host.
/// Call only once for this VM, and only when explicit manual mapping is unset.
pub fn start(socket: PathBuf, connector: Arc<Connector>, stop: Arc<AtomicBool>) {
    thread::spawn(move || {
        let mut published: BTreeMap<u16, (u16, Arc<AtomicBool>)> = BTreeMap::new();
        while !stop.load(Ordering::Acquire) {
            if let Ok(current) = list_published(&socket) {
                let removed: Vec<u16> = published.keys().copied()
                    .filter(|p| !current.contains_key(p) || current[p] != published[p].0).collect();
                for p in removed {
                    if let Some((_, token)) = published.remove(&p) {
                        token.store(true, Ordering::Release);
                    }
                }
                for (host, guest) in current {
                    if published.contains_key(&host) { continue; }
                    let token = Arc::new(AtomicBool::new(false));
                    match tcp_listener(host, guest, Arc::clone(&connector), Arc::clone(&token)) {
                        Ok(()) => { published.insert(host, (guest, token)); }
                        Err(e) => eprintln!("Kiri/Moby: could not publish 127.0.0.1:{host}: {e}"),
                    }
                }
            }
            thread::sleep(POLL_INTERVAL);
        }
        for (_, (_, token)) in published {
            token.store(true, Ordering::Release);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_docker_publish_metadata_not_container_internal_ports() {
        let v = json!([
            { "Ports": [
                { "IP": "0.0.0.0", "PrivatePort": 80, "PublicPort": 8080, "Type": "tcp" },
                { "PrivatePort": 5000, "Type": "tcp" },
                { "IP": "0.0.0.0", "PrivatePort": 53, "PublicPort": 5353, "Type": "udp" }
            ] },
            { "Ports": [
                { "PrivatePort": 6379, "PublicPort": 16379, "Type": "tcp" }
            ] }
        ]);
        assert_eq!(published_ports(&v), BTreeMap::from([(8080, 8080), (16379, 16379)]));
    }

    #[test]
    fn malformed_or_missing_docker_ports_are_ignored() {
        for v in [
            json!(null),
            json!({"Ports":[{"PublicPort":8080,"Type":"tcp"}]}),
            json!([{"Ports":[{"PublicPort":70000,"Type":"tcp"}]}]),
            json!([{"Ports":[{"PublicPort":0,"Type":"tcp"}]}])
        ] {
            assert!(published_ports(&v).is_empty());
        }
    }
}
