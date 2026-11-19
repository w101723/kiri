//! Byte-transparent, full-duplex stream forwarding for Moby's Docker Engine API.
//!
//! This deliberately does not parse Docker API HTTP messages. Docker exec,
//! attach, builds, logs and long-lived event streams must retain their exact
//! bytes and half-close semantics. The Engine in the Linux VM is authoritative.

#![cfg(unix)]

use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::thread;

/// Relay a connection in both directions, including independent write-side
/// EOFs. Either stream may wrap a vsock fd; neither needs to be AF_UNIX.
///
/// A Docker API connection can upgrade into a raw duplex stream; forwarding
/// at the byte level rather than HTTP-request level preserves that behavior.
pub fn relay(mut client: UnixStream, mut engine: UnixStream) -> io::Result<()> {
    let mut from_client = client.try_clone()?;
    let mut to_engine = engine.try_clone()?;

    let upstream = thread::spawn(move || {
        let result = io::copy(&mut from_client, &mut to_engine);
        let _ = to_engine.shutdown(Shutdown::Write);
        result
    });

    let downstream = io::copy(&mut engine, &mut client);
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
