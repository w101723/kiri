//! Private Docker API client. The system Docker context is never modified.
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;
use serde_json::Value;

pub fn socket() -> io::Result<PathBuf> {
    let dir = if let Some(path) = std::env::var_os("KIRI_MOBY_DATA_DIR") {
        PathBuf::from(path)
    } else {
        PathBuf::from(std::env::var_os("HOME").ok_or_else(|| io::Error::other("HOME not set"))?)
            .join(".kiri-moby")
    };
    Ok(dir.join("run/docker.sock"))
}

pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

impl Response {
    pub fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or(Value::Null)
    }

    /// The daemon's `{"message": …}` on failure, or the body as text.
    pub fn error(&self) -> String {
        self.json()["message"].as_str().map(str::to_owned).unwrap_or_else(|| String::from_utf8_lossy(&self.body).into_owned())
    }

    pub fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }
}

fn connect(timeout: Option<Duration>) -> io::Result<UnixStream> {
    let s = UnixStream::connect(socket()?)?;
    s.set_read_timeout(timeout)?;
    Ok(s)
}

fn head(r: &mut impl BufRead) -> io::Result<(u16, Option<usize>, bool)> {
    let mut line = String::new();
    r.read_line(&mut line)?;
    let status = line.split_whitespace().nth(1).and_then(|s| s.parse().ok()).ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "bad status line"))?;
    let (mut len, mut chunked) = (None, false);
    loop {
        line.clear();
        if r.read_line(&mut line)? == 0 {
            break;
        }
        let l = line.trim_end();
        if l.is_empty() {
            break;
        }
        if let Some((k, v)) = l.split_once(':') {
            match k.to_ascii_lowercase().as_str() {
                "content-length" => len = v.trim().parse().ok(),
                "transfer-encoding" => chunked = v.trim().eq_ignore_ascii_case("chunked"),
                _ => {}
            }
        }
    }
    Ok((status, len, chunked))
}

/// Reads one chunk of a chunked body; `None` at the end.
fn chunk(r: &mut impl BufRead) -> io::Result<Option<Vec<u8>>> {
    let mut line = String::new();
    if r.read_line(&mut line)? == 0 {
        return Ok(None);
    }
    let n = usize::from_str_radix(line.trim().split(';').next().unwrap_or(""), 16).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "bad chunk"))?;
    if n == 0 {
        return Ok(None);
    }
    let mut buf = vec![0; n + 2];
    r.read_exact(&mut buf)?;
    buf.truncate(n);
    Ok(Some(buf))
}

/// One request; the whole body is read, chunked or not.
pub fn request(method: &str, path: &str, body: Option<&Value>) -> io::Result<Response> {
    send(method, path, body, "")
}

/// A GET the window makes on its own (status, lists): it doesn't count as
/// use, so it never keeps an idle VM awake.
pub fn get_background(path: &str) -> io::Result<Value> {
    let r = send("GET", path, None, "X-Kiri-Background: 1\r\n")?;
    if !r.ok() {
        return Err(io::Error::other(r.error()));
    }
    Ok(r.json())
}

fn send(method: &str, path: &str, body: Option<&Value>, extra: &str) -> io::Result<Response> {
    send_timeout(method, path, body, extra, Duration::from_secs(120))
}

fn send_timeout(method: &str, path: &str, body: Option<&Value>, extra: &str, timeout: Duration) -> io::Result<Response> {
    let mut s = connect(Some(timeout))?;
    let payload = body.map(Value::to_string).unwrap_or_default();
    // The window's action this is part of, for the engine's log lines.
    let op = "";
    write!(
        s,
        "{method} {path} HTTP/1.1\r\nHost: kiri\r\nConnection: close\r\n{extra}{op}Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{payload}",
        payload.len()
    )?;
    let mut r = BufReader::new(s);
    let (status, len, chunked) = head(&mut r)?;
    let mut body = Vec::new();
    // These never have a body, and the daemon keeps the connection open.
    if status == 204 || status == 304 {
        return Ok(Response { status, body });
    }
    if chunked {
        while let Some(c) = chunk(&mut r)? {
            body.extend_from_slice(&c);
        }
    } else if let Some(n) = len {
        body.resize(n, 0);
        r.read_exact(&mut body)?;
    } else {
        r.read_to_end(&mut body)?;
    }
    Ok(Response { status, body })
}

pub fn get(path: &str) -> io::Result<Value> {
    let r = request("GET", path, None)?;
    if !r.ok() {
        return Err(io::Error::other(r.error()));
    }
    Ok(r.json())
}

/// Bounded, background-only Docker telemetry request. Unlike long-running
/// image pulls/builds, a hung stats request must not stall the native UI.
/// This is a socket I/O timeout, not a global Docker Engine configuration.
pub fn get_background_timeout(path: &str, timeout: Duration) -> io::Result<Value> {
    let r = send_timeout("GET", path, None, "X-Kiri-Background: 1\r\n", timeout)?;
    if !r.ok() {
        return Err(io::Error::other(format!("Docker HTTP {}: {}", r.status, r.error())));
    }
    Ok(r.json())
}

/// Whether the daemon answers at all.
pub fn alive() -> bool {
    send("GET", "/_ping", None, "X-Kiri-Background: 1\r\n").is_ok_and(|r| r.ok())
}


/// Use the Docker CLI bundled with the signed app, with a PATH fallback for development.
pub fn docker_cli() -> Option<PathBuf> {
    let bundled = std::env::current_exe().ok()?
        .parent()?.join("../Resources/bin/docker");
    if bundled.is_file() { return Some(bundled); }
    std::env::var_os("PATH").and_then(|path| std::env::split_paths(&path)
        .map(|dir| dir.join("docker")).find(|candidate| candidate.is_file()))
}
