//! Shared Mac/Guest share-map protocol, with pure Rust unit tests.
//! Paths are hex-encoded for safe transport on the Linux kernel cmdline.

use std::collections::BTreeSet;
use std::io::{self, ErrorKind};
use std::path::{Component, Path, PathBuf};

pub const MAX_SHARES: usize = 16;
pub const MAX_SPEC_BYTES: usize = 1800;

fn invalid(message: &str) -> io::Error {
    io::Error::new(ErrorKind::InvalidInput, message)
}

/// Restrict authorized mountpoints to a proper subdirectory of Mac /Users or /Volumes.
pub fn allowed_target(value: &str) -> bool {
    let path = Path::new(value);
    let components: Vec<_> = path.components().collect();
    path.is_absolute()
        && components.len() >= 3
        && (path.starts_with("/Users/") || path.starts_with("/Volumes/"))
        && components.iter().all(|p| matches!(p, Component::RootDir | Component::Normal(_)))
        && !value.contains("//")
        && !value.contains("/./")
}

/// ASCII-only cmdline map: a series of named, lowercase hex path entries.
pub fn encode(paths: &[String]) -> io::Result<String> {
    if paths.is_empty() || paths.len() > MAX_SHARES {
        return Err(invalid("requires 1..16 share directories"));
    }
    let mut names = BTreeSet::new();
    let mut result = Vec::new();
    for (i, path) in paths.iter().enumerate() {
        if !allowed_target(path) || !names.insert(path) {
            return Err(invalid("unsafe or duplicate share directory"));
        }
        let encoded: String = path.as_bytes().iter().map(|b| format!("{b:02x}")).collect();
        result.push(format!("s{i}@{encoded}"));
    }
    let spec = result.join(",");
    if spec.len() > MAX_SPEC_BYTES {
        return Err(invalid("share map exceeds kernel cmdline budget"));
    }
    Ok(spec)
}

/// The Guest re-validates every path and ordered slot before mounting.
pub fn decode(spec: &str) -> io::Result<Vec<(String, PathBuf)>> {
    if spec.is_empty() || spec.len() > MAX_SPEC_BYTES {
        return Err(invalid("missing or oversized Mac share map"));
    }
    let mut paths = BTreeSet::new();
    let mut result = Vec::new();
    for (i, entry) in spec.split(',').enumerate() {
        if i >= MAX_SHARES { return Err(invalid("too many share entries")); }
        let (label, hex) = entry.split_once('@').ok_or_else(|| invalid("bad share entry"))?;
        if label != format!("s{i}") || hex.is_empty() || hex.len() % 2 != 0 {
            return Err(invalid("bad share slot or hex length"));
        }
        let mut bytes = Vec::with_capacity(hex.len() / 2);
        for pair in hex.as_bytes().chunks_exact(2) {
            let digits = std::str::from_utf8(pair).map_err(|_| invalid("share map is not ASCII"))?;
            bytes.push(u8::from_str_radix(digits, 16).map_err(|_| invalid("bad hex share path"))?);
        }
        let path = String::from_utf8(bytes).map_err(|_| invalid("share path is not UTF-8"))?;
        if !allowed_target(&path) || !paths.insert(path.clone()) {
            return Err(invalid("unsafe or duplicate Guest mount destination"));
        }
        result.push((label.to_owned(), PathBuf::from(path)));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_mounting_mac_or_guest_system_roots() {
        for bad in ["/", "/Users", "/Volumes", "/Users/../etc",
                    "/Users/a/../../etc", "/etc", "/var/lib/docker",
                    "/Users//a/work", "/Users/a/./work", "Users/a/work"] {
            assert!(!allowed_target(bad), "bad path accepted: {bad}");
        }
        for good in ["/Users/alice/work", "/Users/alice/My Projects",
                     "/Users/小王/工程", "/Volumes/SSD/Repo"] {
            assert!(allowed_target(good), "rejected valid path: {good}");
        }
    }
    #[test]
    fn share_map_round_trip_unicode_and_spaces() {
        let paths = vec!["/Users/小王/My Projects".to_owned(),
                         "/Volumes/SSD 1/Repo".to_owned()];
        let encoded = encode(&paths).unwrap();
        let roundtrip = decode(&encoded).unwrap();
        assert_eq!(roundtrip, vec![
            ("s0".into(), PathBuf::from(&paths[0])),
            ("s1".into(), PathBuf::from(&paths[1])),
        ]);
        assert!(encoded.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'@' || c == b','));
    }
    #[test]
    fn rejects_corrupt_and_duplicate_share_map() {
        assert!(encode(&["/Users/a/dev".into(), "/Users/a/dev".into()]).is_err());
        assert!(decode("s0@2f").is_err());
        assert!(decode("s1@2f55736572732f612f64").is_err());
        assert!(decode("s0@zz").is_err());
        assert!(decode(&"a".repeat(MAX_SPEC_BYTES + 1)).is_err());
        let too_many = (0..17).map(|i| format!("/Users/a/{i}")).collect::<Vec<_>>();
        assert!(encode(&too_many).is_err());
    }
}
