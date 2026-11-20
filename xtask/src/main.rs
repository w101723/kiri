//! Kiri Moby build helpers for macOS Apple Silicon only.
//! The Linux ARM64 Docker guest is a separate Moby guest build and is NOT
//! the removed legacy Kiri Linux host/WSL container runtime.
//!
//!   cargo xtask check       -- original UI parity and Rust arm64 code checks
//!   cargo xtask ui          -- build the native SwiftUI/AppKit arm64 GUI
//!   cargo xtask host        -- compile the Moby Host and local CLI for arm64
//!   cargo xtask all         -- check + ui + host
//!
//! The complete signed .app, Guest, Docker/Compose/Buildx and DMG are created
//! by .github/workflows/moby-milestone.yml, not by this lightweight helper.

use std::env;
use std::fs;
use std::io::{self, Error, ErrorKind};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

const MAC_TRIPLE: &str = "aarch64-apple-darwin";
const MIN_MACOS: &str = "14.0";

fn run(cmd: &mut Command) -> io::Result<()> {
    eprintln!("$ {cmd:?}");
    let status = cmd.status()?;
    if !status.success() {
        return Err(Error::other(format!("command failed: {status}")));
    }
    Ok(())
}

fn output(cmd: &mut Command) -> io::Result<String> {
    let result = cmd.output()?;
    if !result.status.success() {
        return Err(Error::other(format!("command failed: {cmd:?}: {}",
                                      String::from_utf8_lossy(&result.stderr))));
    }
    String::from_utf8(result.stdout)
        .map(|v| v.trim().to_owned()).map_err(Error::other)
}

fn root() -> io::Result<PathBuf> {
    Ok(Path::new(env!("CARGO_MANIFEST_DIR")).parent()
       .ok_or_else(|| Error::other("missing repository root"))?.to_path_buf())
}

fn require_mac() -> io::Result<()> {
    if env::consts::OS != "macos" {
        return Err(Error::new(ErrorKind::Unsupported,
            "Kiri Moby host build supports macOS Apple Silicon only; Linux is the Guest OS inside the VM"));
    }
    Ok(())
}

fn check(root: &Path) -> io::Result<()> {
    run(Command::new("python3")
        .current_dir(root)
        .arg("scripts/moby/check-native-ui-parity.py"))?;
    run(Command::new("cargo").current_dir(root)
        .args(["check", "-p", "kiri", "--target", MAC_TRIPLE]))?;
    run(Command::new("cargo").current_dir(root)
        .args(["check", "-p", "kiri-moby-bridge", "--bin", "kiri-moby-host",
               "--target", MAC_TRIPLE]))?;
    Ok(())
}

fn swiftui(root: &Path) -> io::Result<()> {
    let sdk = output(Command::new("xcrun").args(["--sdk", "macosx", "--show-sdk-path"]))?;
    let dest = root.join("target/kiri-moby-native-ui-arm64");
    if let Some(dir) = dest.parent() { fs::create_dir_all(dir)?; }
    run(Command::new("swiftc").current_dir(root)
        .args(["-parse-as-library", "-O", "-target", "arm64-apple-macosx14.0",
               "-sdk", &sdk, "crates/kiri/native/MobyApp.swift", "-o"])
        .arg(&dest))?;
    let arch = output(Command::new("lipo").arg("-archs").arg(&dest))?;
    if arch != "arm64" {
        return Err(Error::other(format!("native GUI is {arch}, expected arm64")));
    }
    let links = output(Command::new("otool").arg("-L").arg(&dest))?;
    if links.lines().any(|line| line.contains("WebKit") || line.contains("JavaScriptCore")) {
        return Err(Error::other("SwiftUI GUI directly depends on WebKit/JavaScriptCore"));
    }
    eprintln!("Native SwiftUI GUI: {}", dest.display());
    Ok(())
}

fn host(root: &Path) -> io::Result<()> {
    run(Command::new("cargo").current_dir(root)
        .env("MACOSX_DEPLOYMENT_TARGET", MIN_MACOS)
        .args(["build", "--release", "-p", "kiri-moby-bridge", "--bin",
               "kiri-moby-host", "--target", MAC_TRIPLE]))?;
    run(Command::new("cargo").current_dir(root)
        .env("MACOSX_DEPLOYMENT_TARGET", MIN_MACOS)
        .args(["build", "--release", "-p", "kiri", "--target", MAC_TRIPLE]))?;
    eprintln!("Host/CLI built for arm64; a fully signed unified app needs CI's Moby Guest bundle.");
    Ok(())
}

fn main() -> ExitCode {
    let task = env::args().nth(1).unwrap_or_default();
    let result = (|| {
        require_mac()?;
        let root = root()?;
        match task.as_str() {
            "check" => check(&root),
            "ui" => swiftui(&root),
            "host" => host(&root),
            "all" => {
                check(&root)?;
                swiftui(&root)?;
                host(&root)
            }
            "release" | "app" | "dmg" => Err(Error::new(ErrorKind::Unsupported,
                "full P12-signed Moby Guest+Host+SwiftUI .app/DMG: use the moby-milestone GitHub Actions workflow")),
            _ => Err(Error::new(ErrorKind::InvalidInput,
                "usage: cargo xtask <check|ui|host|all> (macOS 14+, arm64 target only)")),
        }
    })();
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("kiri xtask: {error}");
            ExitCode::FAILURE
        }
    }
}
