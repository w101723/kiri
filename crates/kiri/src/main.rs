//! Native Apple Silicon Kiri Moby controller. The Finder app is SwiftUI/AppKit.
#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
compile_error!("The Kiri Moby host controller is supported only on macOS Apple Silicon (arm64).");

mod client;
mod moby;

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("moby-native") => moby::native_command(&args[1..]),
        _ => {
            eprintln!("Usage: kiri moby-native <operation> (native Kiri Moby app only)");
            return ExitCode::FAILURE;
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("kiri-moby: {error}");
            ExitCode::FAILURE
        }
    }
}
