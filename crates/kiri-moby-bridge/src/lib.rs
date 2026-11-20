//! Byte-transparent, full-duplex stream forwarding for Moby's Docker Engine API.
//!
//! This deliberately does not parse Docker API HTTP messages. Docker exec,
//! attach, builds, logs and long-lived event streams must retain their exact
//! bytes and half-close semantics. The Engine in the Linux VM is authoritative.

#![cfg(unix)]

use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::thread;

/// A Virtualization.framework AF_VSOCK fd may have O_NONBLOCK set. On
/// EAGAIN we must wait for readiness, not close the Docker API connection.
/// poll() also avoids burning a CPU core while waiting for streamed output.
fn wait_ready(socket: &UnixStream, events: libc::c_short) -> io::Result<()> {
    loop {
        let mut descriptor = libc::pollfd {
            fd: socket.as_raw_fd(),
            events,
            revents: 0,
        };
        // SAFETY: descriptor is a valid, initialized pollfd for one live
        // socket. The call does not retain the pointer after returning.
        let ready = unsafe { libc::poll(&mut descriptor, 1, -1) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if descriptor.revents & libc::POLLNVAL != 0 {
            return Err(io::Error::new(io::ErrorKind::NotConnected, "invalid Docker relay socket"));
        }
        return Ok(());
    }
}

/// Preserve partially written bytes across EAGAIN (std::io::copy cannot
/// transparently retry after WouldBlock). Works with blocking AND
/// nonblocking AF_UNIX/AF_VSOCK/TCP stream fds on macOS and Linux.
fn transfer(from: &mut UnixStream, to: &mut UnixStream) -> io::Result<u64> {
    let mut bytes = [0u8; 64 * 1024];
    let mut total = 0u64;
    loop {
        let size = match from.read(&mut bytes) {
            Ok(0) => return Ok(total),
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                wait_ready(from, libc::POLLIN)?;
                continue;
            }
            Err(e) => return Err(e),
        };
        let mut sent = 0;
        while sent < size {
            match to.write(&bytes[sent..size]) {
                Ok(0) => return Err(io::Error::new(io::ErrorKind::WriteZero, "Docker relay write returned zero")),
                Ok(n) => {
                    sent += n;
                    total += n as u64;
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    wait_ready(to, libc::POLLOUT)?;
                }
                Err(e) => return Err(e),
            }
        }
    }
}

/// Relay a connection in both directions, including independent write-side
/// EOFs. Either stream may wrap a vsock fd; neither needs to be AF_UNIX.
///
/// A Docker API connection can upgrade into a raw duplex stream; forwarding
/// at the byte level rather than HTTP-request level preserves that behavior.
pub fn relay(mut client: UnixStream, mut engine: UnixStream) -> io::Result<()> {
    let mut from_client = client.try_clone()?;
    let mut to_engine = engine.try_clone()?;

    let upstream = thread::spawn(move || {
        let result = transfer(&mut from_client, &mut to_engine);
        let _ = to_engine.shutdown(Shutdown::Write);
        if result.is_err() {
            // Unblock the opposite direction too when a peer fails.
            let _ = from_client.shutdown(Shutdown::Both);
            let _ = to_engine.shutdown(Shutdown::Both);
        }
        result
    });

    let downstream = transfer(&mut engine, &mut client);
    let _ = client.shutdown(Shutdown::Write);

    // On a broken downstream, unblock the upstream copier too.
    if downstream.is_err() {
        let _ = client.shutdown(Shutdown::Both);
        let _ = engine.shutdown(Shutdown::Both);
    }

    let upstream = upstream
        .join()
        .map_err(|_| io::Error::other("client-to-engine relay panicked"))?;

    downstream?;
    upstream?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forwards_binary_payload_and_independent_eof_in_both_directions() {
        let (mut client, bridge_client) = UnixStream::pair().unwrap();
        let (bridge_engine, mut engine) = UnixStream::pair().unwrap();
        let proxy = thread::spawn(move || relay(bridge_client, bridge_engine));

        let request = vec![0x55u8; 256 * 1024];
        let response = vec![0xaau8; 128 * 1024];
        let expected_request = request.clone();
        let expected_response = response.clone();

        let client_thread = thread::spawn(move || {
            client.write_all(&request).unwrap();
            client.shutdown(Shutdown::Write).unwrap();
            let mut received = Vec::new();
            client.read_to_end(&mut received).unwrap();
            received
        });

        let mut received = Vec::new();
        engine.read_to_end(&mut received).unwrap();
        assert_eq!(received, expected_request);

        engine.write_all(&response).unwrap();
        engine.shutdown(Shutdown::Write).unwrap();

        assert_eq!(client_thread.join().unwrap(), expected_response);
        proxy.join().unwrap().unwrap();
    }

    #[test]
    fn retries_nonblocking_reads_without_dropping_docker_response() {
        let (mut cli, bridge_cli) = UnixStream::pair().unwrap();
        let (bridge_engine, mut dockerd) = UnixStream::pair().unwrap();
        bridge_cli.set_nonblocking(true).unwrap();
        bridge_engine.set_nonblocking(true).unwrap();

        let relay_thread = thread::spawn(move || relay(bridge_cli, bridge_engine));
        let payload = vec![0x5au8; 2 * 1024 * 1024];
        let expected = payload.clone();
        let cli_thread = thread::spawn(move || {
            cli.write_all(&payload).unwrap();
            cli.shutdown(Shutdown::Write).unwrap();
            let mut response = Vec::new();
            cli.read_to_end(&mut response).unwrap();
            response
        });
        // Force the relay to observe an empty socket (WouldBlock), then
        // fill its receive buffer enough to exercise partial writes.
        thread::sleep(std::time::Duration::from_millis(30));
        let mut received = Vec::new();
        dockerd.read_to_end(&mut received).unwrap();
        assert_eq!(received, expected);
        dockerd.write_all(b"HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\n\\r\\nOK").unwrap();
        dockerd.shutdown(Shutdown::Write).unwrap();
        assert_eq!(cli_thread.join().unwrap(), b"HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\n\\r\\nOK");
        relay_thread.join().unwrap().unwrap();
    }

    #[test]
    fn preserves_docker_http_upgrade_and_raw_stream_bytes() {
        let (mut client, bridge_client) = UnixStream::pair().unwrap();
        let (bridge_engine, mut engine) = UnixStream::pair().unwrap();
        let proxy = thread::spawn(move || relay(bridge_client, bridge_engine));

        let upgrade = b"POST /exec/example/start HTTP/1.1\r\nHost: docker\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n";
        client.write_all(upgrade).unwrap();
        let mut actual = vec![0; upgrade.len()];
        engine.read_exact(&mut actual).unwrap();
        assert_eq!(actual, upgrade);

        let reply = b"HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\n\r\n";
        engine.write_all(reply).unwrap();
        let mut actual_reply = vec![0; reply.len()];
        client.read_exact(&mut actual_reply).unwrap();
        assert_eq!(actual_reply, reply);

        // An upgraded connection is no longer HTTP; preserve arbitrary bytes.
        let binary = [0, 255, 1, 2, 0, 128, 3, 4];
        client.write_all(&binary).unwrap();
        let mut actual_binary = [0u8; 8];
        engine.read_exact(&mut actual_binary).unwrap();
        assert_eq!(actual_binary, binary);

        client.shutdown(Shutdown::Write).unwrap();
        engine.shutdown(Shutdown::Write).unwrap();
        proxy.join().unwrap().unwrap();
    }
}
 

#[cfg(target_os = "macos")]
pub mod ports;

/// Validated path mapping shared by the macOS launcher and Linux Guest.
pub mod shares;

/// Adaptive Guest memory telemetry and conservative balloon policy.
pub mod memory;
