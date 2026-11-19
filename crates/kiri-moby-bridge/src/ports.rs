//! macOS TCP port publishing for the real Moby Docker Engine.
//!
//! Docker's /events stream signals when to reconcile. GET /containers/json
//! remains the source of truth for the desired ports, and a low-frequency
//! full scan catches missed events / reconnects. No second container DB.
//!
//! TCP is exposed only on Mac loopback; no UDP or LAN exposure in this phase.

#![cfg(target_os = "macos")]

use std::collections::BTreeMap;
use std::io::{self, BufRead, BufReader, Write};
use std::net::TcpListener;
use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{mpsc, Arc, Mutex};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use kiri_vmm::Connector;

const TCP_FORWARD_VSOCK_PORT: u32 = 2377;
const FULL_RECONCILE_INTERVAL: Duration = Duration::from_secs(30);
const FAILED_RECONCILE_RETRY: Duration = Duration::from_secs(2);
const STOP_POLL_INTERVAL: Duration = Duration::from_millis(200);

fn published_ports(doc: &serde_json::Value) -> BTreeMap<u16, u16> {
    let mut ports = BTreeMap::new();
    let Some(containers) = doc.as_array() else { return ports };
    for container in containers {
        let Some(rows) = container.get("Ports").and_then(|v| v.as_array()) else { continue };
        for row in rows {
            if row.get("Type").and_then(|v| v.as_str()) != Some("tcp") { continue; }
            let Some(host) = row.get("PublicPort").and_then(|v| v.as_u64()).and_then(|p| u16::try_from(p).ok()) else { continue };
            if host == 0 { continue; }
            // A Mac localhost listener connects through guest NAT to the
            // *published* port, never to the container's private IP.
            ports.insert(host, host);
        }
    }
    ports
}

fn memory_relevant_event(event: &serde_json::Value) -> bool {
    if event.get("Type").or_else(|| event.get("type"))
        .and_then(|value| value.as_str()) != Some("container")
    {
        return false;
    }
    matches!(
        event.get("Action").or_else(|| event.get("status")).and_then(|x| x.as_str()),
        Some("die" | "stop" | "destroy" | "oom")
    )
}

fn port_relevant_event(event: &serde_json::Value) -> bool {
    if event.get("Type").or_else(|| event.get("type")).and_then(|x| x.as_str()) != Some("container") {
        return false;
    }
    matches!(
        event.get("Action").or_else(|| event.get("status")).and_then(|x| x.as_str()),
        Some("start" | "die" | "stop" | "destroy" | "kill" | "restart" | "pause" | "unpause")
    )
}

fn list_published(socket: &PathBuf) -> io::Result<BTreeMap<u16, u16>> {
    // curl handles HTTP/1.1 Unix socket details and can be timed out.
    let out = Command::new("/usr/bin/curl")
        .args(["--fail", "--silent", "--show-error", "--max-time", "3", "--noproxy", "*", "--unix-socket"])
        .arg(socket)
        .arg("http://localhost/containers/json?all=0")
        .output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "dockerd list containers failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    let parsed: serde_json::Value = serde_json::from_slice(&out.stdout)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    Ok(published_ports(&parsed))
}

struct ActiveListener {
    guest: u16,
    stopping: Arc<AtomicBool>,
    worker: JoinHandle<()>,
}

fn tcp_listener(
    host: u16,
    guest: u16,
    connector: Arc<Connector>,
    shutdown: Arc<AtomicBool>,
    global_stop: Arc<AtomicBool>,
) -> io::Result<JoinHandle<()>> {
    let listener = TcpListener::bind(("127.0.0.1", host))?;
    listener.set_nonblocking(true)?;
    eprintln!("Kiri/Moby: published 127.0.0.1:{host} -> guest:{guest}/tcp");
    Ok(thread::spawn(move || {
        while !shutdown.load(Ordering::Acquire) && !global_stop.load(Ordering::Acquire) {
            let client = match listener.accept() {
                Ok((client, _)) => client,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(50));
                    continue;
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => {
                    eprintln!("Kiri/Moby TCP port {host} listener stopped unexpectedly: {e}");
                    return;
                }
            };
            let connector = Arc::clone(&connector);
            thread::spawn(move || {
                let stream = match connector.connect(TCP_FORWARD_VSOCK_PORT) {
                    Ok(stream) => stream,
                    Err(error) => {
                        eprintln!("Kiri/Moby: localhost:{host} -> Guest vsock failed: {error}");
                        return;
                    }
                };
                let fd = match stream.fd.try_clone() {
                    Ok(fd) => fd,
                    Err(error) => {
                        eprintln!("Kiri/Moby: localhost:{host} Guest vsock fd clone failed: {error}");
                        return;
                    }
                };
                let mut to_guest = UnixStream::from(fd);
                if let Err(error) = to_guest.write_all(&guest.to_be_bytes()) {
                    eprintln!("Kiri/Moby: localhost:{host} -> Guest port {guest} header failed: {error}");
                    return;
                }
                let client: OwnedFd = client.into();
                if let Err(error) = crate::relay(UnixStream::from(client), to_guest) {
                    if !matches!(error.kind(), io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset)
                        || std::env::var_os("KIRI_MOBY_DEBUG").is_some()
                    {
                        eprintln!("Kiri/Moby: localhost:{host} -> Guest port {guest} relay failed: {error}");
                    }
                }
                drop(stream);
            });
        }
    }))
}

// Joining the owning listener thread is important: otherwise a destroy+start
// arriving in the same event burst may get EADDRINUSE from the old listener.
fn stop_listener(host: u16, active: ActiveListener) {
    active.stopping.store(true, Ordering::Release);
    if active.worker.join().is_err() {
        eprintln!("Kiri/Moby: localhost:{host} listener panicked during shutdown");
    }
    eprintln!("Kiri/Moby: unpublished 127.0.0.1:{host}/tcp");
}

fn reconcile(
    active: &mut BTreeMap<u16, ActiveListener>,
    desired: BTreeMap<u16, u16>,
    connector: &Arc<Connector>,
    stop: &Arc<AtomicBool>,
) {
    let obsolete: Vec<u16> = active.iter().filter_map(|(host, previous)| {
        if desired.get(host) != Some(&previous.guest) { Some(*host) } else { None }
    }).collect();
    for host in obsolete {
        if let Some(listener) = active.remove(&host) {
            stop_listener(host, listener);
        }
    }

    for (host, guest) in desired {
        if active.contains_key(&host) { continue; }
        let shutdown = Arc::new(AtomicBool::new(false));
        match tcp_listener(host, guest, Arc::clone(connector), Arc::clone(&shutdown), Arc::clone(stop)) {
            Ok(worker) => {
                active.insert(host, ActiveListener { guest, stopping: shutdown, worker });
            }
            Err(e) => {
                // A previously unavailable Mac port will be retried on the
                // next Docker event or periodic full reconciliation.
                eprintln!("Kiri/Moby: cannot publish 127.0.0.1:{host}/tcp: {e}");
            }
        }
    }
}

fn sleep_until_retry(stop: &AtomicBool) {
    for _ in 0..10 {
        if stop.load(Ordering::Acquire) { break; }
        thread::sleep(Duration::from_millis(200));
    }
}

/// Subscribe to Docker events without writing our own HTTP chunked parser.
/// curl --no-buffer emits newline-delimited Docker event JSON through stdout.
/// The child is owned in shared state so the coordinator can kill/reap it
/// when the VM stops, rather than leaving an orphaned curl process.
fn watch_events(
    socket: PathBuf,
    notices: mpsc::SyncSender<()>,
    memory_kick: Option<mpsc::SyncSender<()>>,
    stop: Arc<AtomicBool>,
    child: Arc<Mutex<Option<Child>>>,
) {
    while !stop.load(Ordering::Acquire) {
        let spawned = Command::new("/usr/bin/curl")
            .args([
                "--no-buffer", "--include", "--fail", "--silent", "--show-error",
                "--connect-timeout", "3", "--noproxy", "*", "--unix-socket",
            ])
            .arg(&socket)
            .arg("http://localhost/events")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn();

        let mut process = match spawned {
            Ok(process) => process,
            Err(error) => {
                eprintln!("Kiri/Moby: cannot subscribe to Docker /events: {error}");
                sleep_until_retry(&stop);
                continue;
            }
        };
        let Some(stdout) = process.stdout.take() else {
            let _ = process.kill();
            let _ = process.wait();
            sleep_until_retry(&stop);
            continue;
        };
        {
            let mut guard = child.lock().unwrap_or_else(|e| e.into_inner());
            if stop.load(Ordering::Acquire) {
                let _ = process.kill();
                let _ = process.wait();
                break;
            }
            *guard = Some(process);
        }

        let mut in_headers = true;
        let mut good_http_status = false;
        for line in BufReader::new(stdout).lines() {
            if stop.load(Ordering::Acquire) { break; }
            let Ok(line) = line else { break };
            if in_headers {
                if line.starts_with("HTTP/") {
                    good_http_status = line.contains(" 200 ");
                } else if line.is_empty() {
                    in_headers = false;
                    if good_http_status {
                        // Subscribed successfully: a fresh snapshot covers the
                        // gap between the previous scan and event readiness.
                        let _ = notices.try_send(());
                        eprintln!("Kiri/Moby: Docker /events subscribed; fallback scan every 30s");
                    }
                }
                continue;
            }
            if let Ok(event) = serde_json::from_str::<serde_json::Value>(&line) {
                if port_relevant_event(&event) {
                    let _ = notices.try_send(()); // coalesce event bursts
                }
                // No destructive cache drop: an exit merely speeds the next
                // memory reading and cautiously re-evaluates balloon headroom.
                if memory_relevant_event(&event) {
                    if let Some(kick) = &memory_kick {
                        let _ = kick.try_send(());
                    }
                }
            }
        }
        {
            let mut guard = child.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(mut process) = guard.take() {
                let _ = process.kill();
                let _ = process.wait();
            }
        }
        if !stop.load(Ordering::Acquire) {
            // Docker/Guest may be restarting. Do not discard existing Mac
            // listeners on API failure; reconcile only with a valid snapshot.
            sleep_until_retry(&stop);
            let _ = notices.try_send(());
        }
    }
}

/// Start event-driven port reconciliation with periodic, bounded snapshots.
/// The stop token is the same one used to gracefully retire the VM.
pub fn start(socket: PathBuf, connector: Arc<Connector>, stop: Arc<AtomicBool>,
    memory_kick: Option<mpsc::SyncSender<()>>) -> JoinHandle<()> {
    thread::spawn(move || {
        let (sender, receiver) = mpsc::sync_channel::<()>(1);
        let child = Arc::new(Mutex::new(None));
        let event_child = Arc::clone(&child);
        let event_stop = Arc::clone(&stop);
        let event_socket = socket.clone();
        let watcher = thread::spawn(move || {
            watch_events(event_socket, sender, memory_kick, event_stop, event_child)
        });

        // Baseline scan catches already-running containers after VM restart.
        // Events trigger immediate additional scans; periodic polling remains
        // a recovery mechanism, not the main update path.
        let mut active = BTreeMap::<u16, ActiveListener>::new();
        let mut next_scan = Instant::now();
        while !stop.load(Ordering::Acquire) {
            let wait = next_scan.saturating_duration_since(Instant::now())
                .min(STOP_POLL_INTERVAL);
            if receiver.recv_timeout(wait).is_ok() {
                // Discard queued duplicates; re-read the Docker state ONCE.
                while receiver.try_recv().is_ok() {}
                next_scan = Instant::now();
            }
            if Instant::now() < next_scan { continue; }

            match list_published(&socket) {
                Ok(desired) => {
                    reconcile(&mut active, desired, &connector, &stop);
                    next_scan = Instant::now() + FULL_RECONCILE_INTERVAL;
                }
                Err(error) => {
                    if std::env::var_os("KIRI_MOBY_DEBUG").is_some() {
                        eprintln!("Kiri/Moby: Docker API reconciliation delayed: {error}");
                    }
                    next_scan = Instant::now() + FAILED_RECONCILE_RETRY;
                }
            }
        }

        // Kill and reap the streaming curl before releasing VM resources.
        if let Some(mut process) = child.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = process.kill();
            let _ = process.wait();
        }
        let _ = watcher.join();
        for (host, listener) in active {
            stop_listener(host, listener);
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn extracts_only_public_tcp_ports() {
        let v = json!([
            {"Ports": [
                {"IP":"0.0.0.0","PrivatePort":80,"PublicPort":18080,"Type":"tcp"},
                {"PrivatePort":6379,"Type":"tcp"},
                {"PublicPort":5353,"Type":"udp"},
                {"PublicPort":70000,"Type":"tcp"}
            ]},
            {"Ports":[{"PrivatePort":3306,"PublicPort":13306,"Type":"tcp"}]}
        ]);
        assert_eq!(published_ports(&v), BTreeMap::from([(18080,18080),(13306,13306)]));
    }

    #[test]
    fn ignores_invalid_docker_list_responses() {
        for v in [json!(null), json!({"Ports":[{"PublicPort":123,"Type":"tcp"}]}),
                  json!([{"Ports":[{"PublicPort":0,"Type":"tcp"}]}])] {
            assert!(published_ports(&v).is_empty());
        }
    }

    #[test]
    fn memory_release_events_are_narrowly_scoped() {
        for action in ["die", "stop", "destroy", "oom"] {
            assert!(memory_relevant_event(&json!({"Type":"container","Action":action})));
        }
        for action in ["start", "create", "restart", "exec_start", "pause", "unpause"] {
            assert!(!memory_relevant_event(&json!({"Type":"container","Action":action})));
        }
        assert!(!memory_relevant_event(&json!({"Type":"image","Action":"destroy"})));
    }

    #[test]
    fn recognizes_lifecycle_events_and_ignores_unrelated_ones() {
        for action in ["start", "die", "stop", "destroy", "kill", "restart", "pause", "unpause"] {
            assert!(port_relevant_event(&json!({"Type":"container","Action":action})));
        }
        assert!(port_relevant_event(&json!({"type":"container","status":"start"})));
        for sample in [
            json!({"Type":"image","Action":"pull"}),
            json!({"Type":"network","Action":"connect"}),
            json!({"Type":"container","Action":"exec_start"}),
            json!({"Type":"container","Action":"create"}),
            json!({"Type":"container"}),
            json!({}),
        ] {
            assert!(!port_relevant_event(&sample));
        }
    }
}
