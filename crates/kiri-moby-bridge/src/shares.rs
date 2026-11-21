//! Linux Guest-side decoding and validation of the Swift Host's share map.
//! Paths are hex-encoded for safe transport on the Linux kernel cmdline.

use std::collections::BTreeSet;
use std::io::{self, ErrorKind};
use std::path::{Component, Path, PathBuf};

const MAX_SHARES: usize = 16;
const MAX_SPEC_BYTES: usize = 1800;

fn invalid(message: &str) -> io::Error {
    io::Error::new(ErrorKind::InvalidInput, message)
}

/// Restrict authorized mountpoints to a proper subdirectory of Mac /Users or /Volumes.
fn allowed_target(value: &str) -> bool {
    let path = Path::new(value);
    let components: Vec<_> = path.components().collect();
    path.is_absolute()
        && components.len() >= 3
        && (path.starts_with("/Users/") || path.starts_with("/Volumes/"))
        && components.iter().all(|p| matches!(p, Component::RootDir | Component::Normal(_)))
        && !value.contains("//")
        && !value.contains("/./")
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
        // Encode only inside this test. Production encode now lives in Swift Host.
        let encoded = paths.iter().enumerate().map(|(i, path)| {
            format!("s{i}@{}", path.as_bytes().iter()
                .map(|byte| format!("{byte:02x}")).collect::<String>())
        }).collect::<Vec<_>>().join(",");
        let roundtrip = decode(&encoded).unwrap();
        assert_eq!(roundtrip, vec![
            ("s0".into(), PathBuf::from(&paths[0])),
            ("s1".into(), PathBuf::from(&paths[1])),
        ]);
        assert!(encoded.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'@' || c == b','));
    }
    #[test]
    fn rejects_corrupt_and_duplicate_share_map() {
        let duplicate = "s0@2f55736572732f612f646576,s1@2f55736572732f612f646576";
        assert!(decode(duplicate).is_err());
        assert!(decode("s0@2f").is_err());
        assert!(decode("s1@2f55736572732f612f64").is_err());
        assert!(decode("s0@zz").is_err());
        assert!(decode(&"a".repeat(MAX_SPEC_BYTES + 1)).is_err());
        let too_many = (0..17).map(|i| format!("s{i}@2f55736572732f612f646576")).collect::<Vec<_>>().join(",");
        assert!(decode(&too_many).is_err());
    }
}
