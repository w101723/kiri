//! Apple Silicon VM support via macOS Virtualization.framework.
//! The Linux ARM64 Guest remains a separate boot image; this crate does not
//! implement a Linux or Windows host runtime.

mod stop;

use std::path::PathBuf;

/// One host directory the guest sees over virtiofs, under `name`:
/// `/mnt/<tag>/<name>` in the guest.
#[derive(Debug, Clone)]
pub struct ShareDir {
    pub name: String,
    pub dir: PathBuf,
}

/// The host directories shared with the guest, under one virtiofs tag.
///
/// Named directories rather than their parent: the guest is given the folders
/// a bind mount may name, not the disk they sit on, so a container that
/// reaches the share (a bind of its root, or `--cap-add SYS_ADMIN` and a
/// `mount -t virtiofs <tag>`) gets no more than those folders.
#[derive(Debug, Clone)]
pub struct Share {
    pub tag: String,
    pub dirs: Vec<ShareDir>,
}

#[cfg(target_os = "macos")]
mod apple;
#[cfg(target_os = "macos")]
pub use apple::*;

