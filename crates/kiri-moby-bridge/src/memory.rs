//! Linux Guest memory telemetry. The balloon governor runs only in Swift Host.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct GuestMemory {
    pub total_kib: u64,
    pub available_kib: u64,
    pub cached_kib: u64,
}

impl GuestMemory {
    pub fn from_meminfo(contents: &str) -> Option<Self> {
        fn field(s: &str, key: &str) -> Option<u64> {
            s.lines().find_map(|line| {
                let (name, value) = line.split_once(':')?;
                (name == key).then(|| value.split_whitespace().next()?.parse().ok()).flatten()
            })
        }
        let sample = Self {
            total_kib: field(contents, "MemTotal")?,
            available_kib: field(contents, "MemAvailable")?,
            cached_kib: field(contents, "Cached").unwrap_or(0),
        };
        sample.valid().then_some(sample)
    }

    fn valid(self) -> bool {
        self.total_kib >= 512 * 1024
            && self.total_kib <= 256 * 1024 * 1024
            && self.available_kib <= self.total_kib
            && self.cached_kib <= self.total_kib
    }

    pub fn wire(self) -> String {
        format!("KIRI_MEM_V1 {} {} {}\n", self.total_kib, self.available_kib, self.cached_kib)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_guest_meminfo_and_formats_host_protocol() {
        let source = "MemTotal: 4194304 kB\nMemAvailable: 3145728 kB\nCached: 20480 kB\n";
        let sample = GuestMemory::from_meminfo(source).unwrap();
        assert_eq!(sample.wire(), "KIRI_MEM_V1 4194304 3145728 20480\n");
        assert!(GuestMemory::from_meminfo("MemTotal: 0 kB\nMemAvailable: 0 kB").is_none());
        assert!(GuestMemory::from_meminfo("MemTotal: 4194304 kB\nMemAvailable: 9999999 kB").is_none());
        assert!(GuestMemory::from_meminfo("MemTotal: 4194304 kB").is_none());
    }
}
