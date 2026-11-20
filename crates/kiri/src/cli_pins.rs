//! Pinned Docker CLI, Compose, Buildx and Grype tools for macOS Apple
//! Silicon. No Windows, WSL, Intel-Mac or Linux-host download artifacts.
//! The Linux ARM64 Moby Guest packages its own container runtime.

#![allow(dead_code)]

pub const DOCKER_CLI: (&str, &str) = (
    "29.9.2", "ea8a2ce5ac31f9f5f3fb711a7a485e1e46cc7a69798a629a70306f6e6af25b7a",
);
pub const COMPOSE: (&str, &str) = (
    "v5.6.1", "fcce41226abd2b7b2936094e688bbd61284673dddafea542e08cb9a3b4423a8b",
);
pub const BUILDX: (&str, &str) = (
    "v0.38.1", "6f20ba2437865311ef99015bf5d1039c3c8e4d2177c1c64aa41b134b5ecd3012",
);
pub const GRYPE: (&str, &str) = (
    "0.120.1", "cf97957fa467d25575ec2cc3228289f391ea51cf88b9cffc5f83dc03d4cbc732",
);

pub fn docker_url(version: &str) -> String {
    format!("https://download.docker.com/mac/static/stable/aarch64/docker-{version}.tgz")
}

pub fn compose_url(version: &str) -> String {
    format!("https://github.com/docker/compose/releases/download/{version}/docker-compose-darwin-aarch64")
}

pub fn buildx_name(version: &str) -> String {
    format!("buildx-{version}.darwin-arm64")
}

pub fn buildx_url(version: &str) -> String {
    format!("https://github.com/docker/buildx/releases/download/{version}/{}", buildx_name(version))
}

pub fn grype_url(version: &str) -> String {
    format!("https://github.com/anchore/grype/releases/download/v{version}/grype_{version}_darwin_arm64.tar.gz")
}

/// Retains the old tools/scan call contract, with a single Apple Silicon
/// architecture and no compile-time references to removed host platforms.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct MacArch;

impl MacArch {
    pub const HOST: Self = Self;

    pub const fn tools(self) -> [(&'static str, &'static str); 3] {
        [DOCKER_CLI, COMPOSE, BUILDX]
    }

    pub const fn grype(self) -> (&'static str, &'static str) {
        GRYPE
    }

    pub const fn compose_arch(self) -> &'static str {
        "aarch64"
    }

    pub const fn go_arch(self) -> &'static str {
        "arm64"
    }

    pub fn docker_url(self, version: &str) -> String { docker_url(version) }
    pub fn compose_url(self, version: &str) -> String { compose_url(version) }
    pub fn buildx_name(self, version: &str) -> String { buildx_name(version) }
    pub fn buildx_url(self, version: &str) -> String { buildx_url(version) }
    pub fn grype_url(self, version: &str) -> String { grype_url(version) }
}
