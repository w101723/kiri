//! Conservative adaptive memory policy shared by the Guest and macOS Host.
//! A lower virtio-balloon target is NOT proof that macOS released physical pages.

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

    pub fn from_wire(line: &str) -> Option<Self> {
        let mut parts = line.split_whitespace();
        if parts.next()? != "KIRI_MEM_V1" { return None; }
        let sample = Self {
            total_kib: parts.next()?.parse().ok()?,
            available_kib: parts.next()?.parse().ok()?,
            cached_kib: parts.next()?.parse().ok()?,
        };
        (parts.next().is_none() && sample.valid()).then_some(sample)
    }
}

pub struct Governor {
    max_mib: u64,
    target_mib: u64,
    quiet_samples: u8,
}

impl Governor {
    pub fn new(max_mib: u64) -> Self {
        Self { max_mib, target_mib: max_mib, quiet_samples: 0 }
    }

    pub fn target_mib(&self) -> u64 { self.target_mib }

    /// A Docker die/stop/destroy/oom event asks for an early sample. We
    /// retain the MemAvailable safeguards before contracting the balloon.
    pub fn released_hint(&mut self) {
        self.quiet_samples = self.quiet_samples.max(2);
    }

    /// Virtualization.framework exposes traditional ballooning. Contraction is
    /// gradual; expansion is immediate. Always leave substantial spare Guest
    /// memory for dockerd, builds, allocations and caches.
    pub fn update(&mut self, sample: GuestMemory) -> Option<u64> {
        const FLOOR_MIB: u64 = 1_024;
        const HEADROOM_MIB: u64 = 1_024;
        const STEP_MIB: u64 = 256;
        const HYSTERESIS_MIB: u64 = 128;

        if self.max_mib < FLOOR_MIB { return None; }
        let total = sample.total_kib / 1024;
        let available = sample.available_kib / 1024;
        // Linux continues to count pages held by an inflated balloon in
        // MemTotal. Do not mistake those pages for used container memory.
        let inflated = self.max_mib.saturating_sub(self.target_mib);
        let used = total.saturating_sub(available).saturating_sub(inflated);
        let desired = used.saturating_add(HEADROOM_MIB).clamp(FLOOR_MIB, self.max_mib);

        let next = if available < 512 && self.target_mib < self.max_mib {
            // Deflate promptly before a memory-starved guest OOMs. A burst can
            // still OOM before the next poll; do not promise zero OOM risk.
            self.quiet_samples = 0;
            self.target_mib.saturating_add(1_024).max(desired).min(self.max_mib)
        } else if desired > self.target_mib.saturating_add(HYSTERESIS_MIB) {
            self.quiet_samples = 0;
            desired
        } else if desired.saturating_add(STEP_MIB) < self.target_mib
            && available > HEADROOM_MIB + STEP_MIB
        {
            // Require three consecutive idle samples before reclaiming.
            self.quiet_samples = self.quiet_samples.saturating_add(1);
            if self.quiet_samples < 3 { return None; }
            self.target_mib - STEP_MIB
        } else {
            self.quiet_samples = 0;
            return None;
        };
        if next == self.target_mib { return None; }
        self.target_mib = next;
        Some(next)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(available_mib: u64) -> GuestMemory {
        GuestMemory { total_kib: 4_096 * 1024, available_kib: available_mib * 1024, cached_kib: 100 * 1024 }
    }

    #[test]
    fn parses_linux_meminfo_and_rejects_corrupt_wire_samples() {
        let text = "MemTotal: 4194304 kB\nMemFree: 123 kB\nMemAvailable: 3145728 kB\nCached: 20480 kB\n";
        let stats = GuestMemory::from_meminfo(text).unwrap();
        assert_eq!(GuestMemory::from_wire(&stats.wire()), Some(stats));
        assert!(GuestMemory::from_wire("KIRI_MEM_V1 4194304 9999999 0").is_none());
        assert!(GuestMemory::from_wire("KIRI_MEM_V1 0 0 0").is_none());
        assert!(GuestMemory::from_wire("KIRI_MEM_V1 4194304 1024 0 trailing").is_none());
    }

    #[test]
    fn idle_guest_contracts_conservatively_and_never_below_floor() {
        let mut policy = Governor::new(4_096);
        assert_eq!(policy.update(sample(3_200)), None);
        assert_eq!(policy.update(sample(3_200)), None);
        assert_eq!(policy.update(sample(3_200)), Some(3_840));
        for _ in 0..150 { policy.update(sample(3_200)); }
        assert!(policy.target_mib() >= 1_024);
        assert!(policy.target_mib() <= 4_096);
    }

    #[test]
    fn pressure_deflates_fast_and_does_not_shrink_under_low_available() {
        let mut policy = Governor::new(4_096);
        for _ in 0..12 { policy.update(sample(3_200)); }
        let before = policy.target_mib();
        assert!(before < 4_096);
        assert!(policy.update(sample(200)).is_some());
        assert!(policy.target_mib() > before);
    }

    #[test]
    fn release_hint_requires_real_available_headroom() {
        let mut policy = Governor::new(4_096);
        policy.released_hint();
        assert_eq!(policy.update(sample(3_200)), Some(3_840));
        policy.released_hint();
        let before = policy.target_mib();
        let _ = policy.update(sample(800));
        assert!(policy.target_mib() >= before, "low memory must not shrink the target");
    }

    #[test]
    fn keeps_configured_ceiling() {
        let mut policy = Governor::new(1_024);
        for _ in 0..15 { assert_eq!(policy.update(sample(3_200)), None); }
        assert_eq!(policy.target_mib(), 1_024);
    }
}
