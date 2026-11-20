//! The `kiri` command.

use std::process::ExitCode;

#[cfg(target_os = "macos")]
mod bench;
#[cfg(target_os = "macos")]
mod boot;
// builds, cli_pins, scan and tools on Linux too: the daemon reads an
// image's layers and scans it for kiri-win, whose window can't reach the
// store inside WSL (daemon/api.rs).
#[cfg(unix)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod builds;
// The engine stops when its app is deleted under it (kiri-win includes it
// for Windows).
#[cfg(unix)]
mod appwatch;
// Which builder plain `docker build` uses: Docker's or Kiri's.
#[cfg(unix)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod buildwith;
#[cfg(unix)]
mod cli_pins;
#[cfg(unix)]
mod client;
#[cfg(unix)]
mod daemon;
#[cfg(unix)]
mod diag;
#[cfg(target_os = "macos")]
mod docker;
mod flavor;
mod images;
#[cfg(unix)]
mod guest;
#[cfg(target_os = "macos")]
mod import;
#[cfg(unix)]
mod k8s;
// kubectl's own file, which `kiri k8s` puts its context in.
#[cfg(unix)]
mod kubeconfig;
#[cfg(unix)]
mod machine;
#[cfg(unix)]
mod run;
#[cfg(unix)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod scan;
#[cfg(target_os = "macos")]
mod setup;
#[cfg(unix)]
mod usb;
#[cfg(unix)]
mod stale;
#[cfg(target_os = "macos")]
mod share;
#[cfg(target_os = "macos")]
mod ui;
#[cfg(unix)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod tools;
#[cfg(target_os = "macos")]
mod update;

const USAGE: &str = "\
usage: kiri COMMAND          docker's commands, on Kiri: kiri run, ps, exec,
                             logs, stop, rm, images, pull, build, compose…
       kiri daemon
       kiri ui [--start] [--view containers|images|volumes|networks]
       kiri setup [--use] [--no-agent] | kiri setup --uninstall
       kiri build-with [docker|kiri]   which builder docker build uses
       kiri update [--check]
       kiri diag logs [-f] [--ui|--engine|--cli] [--errors] [-n N]
       kiri diag report [--out PATH] [--send]   (a file to send us, tokens taken out)
       kiri PORT [NAME]           share a local port on the internet (same as kiri share PORT)
       kiri share PORT|CONTAINER [--name N] | share login | logout | status
       kiri k8s start [--use] | stop | status | delete | set [--lan on|off] [--tls-san NAME,…] [--port N]
       kiri usb [list] | attach DEVICE | detach DEVICE   USB devices for containers, beta (Mac: pass through to the VM)
       kiri machine create NAME [--distro D] | list | shell NAME | stop | delete NAME
       kiri import [orbstack | desktop-linux] [--list | [--force] [image|volume|container NAME]]
       kiri bench [--runs N] [--image IMAGE] [--network none|bridge]
       kiri boot [--console] [--pings N]
       kiri raw run [--rm] [-e KEY=VALUE]... IMAGE [COMMAND...]   (its own guest, no daemon)
       kiri raw pull <image> | raw images | raw rmi <image>...";

fn main() -> ExitCode {
    flavor::init();
    let args: Vec<String> = std::env::args().skip(1).collect();
    // Which process this is, for its log and crash reports.
    #[cfg(unix)]
    diag::init(match args.first().map(String::as_str) {
        Some("daemon") => diag::Part::Daemon,
        // Only a build with the window: elsewhere `kiri ui` is a plain
        // command whose message must reach the terminal, not the log's pipe.
        #[cfg(any(target_os = "macos", all(target_os = "linux", feature = "window")))]
        Some("ui") => diag::Part::Ui,
        #[cfg(target_os = "macos")]
        None if setup::launched_from_app() => diag::Part::Ui,
        _ => diag::Part::Cli,
    });
    let result: std::io::Result<()> = match args.first().map(String::as_str) {
        #[cfg(target_os = "macos")]
        Some("daemon") => Err(std::io::Error::other("Custom Kiri daemon is no longer the macOS engine; open Kiri Moby GUI")),
        #[cfg(unix)]
        Some("raw") => match args.get(1).map(String::as_str) {
            Some("run") => run::run(&args[2..]),
            Some("pull") => images::pull(&args[2..]),
            Some("images") => images::list(&args[2..]),
            Some("rmi") => images::remove(&args[2..]),
            _ => {
                eprintln!("{USAGE}");
                return ExitCode::FAILURE;
            }
        },
        #[cfg(target_os = "macos")]
        Some("bench") => bench::run(&args[1..]),
        #[cfg(target_os = "macos")]
        Some("boot") => boot::run(&args[1..]),
        #[cfg(target_os = "macos")]
        Some("moby-native") => ui::native_moby_command(&args[1..]),
        #[cfg(target_os = "macos")]
        Some("setup") => Err(std::io::Error::other(
            "Legacy Kiri setup disabled on macOS: it could replace OrbStack's Docker context; Moby uses its own socket")),
        #[cfg(target_os = "macos")]
        Some("share") => share::run(&args[1..]),
        // `kiri 3000`: share a port straight away.
        #[cfg(target_os = "macos")]
        Some(a) if share::is_shorthand(a) => share::run(&args),
        #[cfg(unix)]
        Some("build-with") => buildwith::cli(&args[1..]),
        #[cfg(unix)]
        Some("k8s") => k8s::run(&args[1..]),
        #[cfg(unix)]
        Some("machine") => machine::run(&args[1..]),
        #[cfg(unix)]
        Some("usb") => usb::run(&args[1..]),
        #[cfg(target_os = "macos")]
        Some("import") => import::run(&args[1..]),
        #[cfg(target_os = "macos")]
        Some("update") => update::run(&args[1..]),
        #[cfg(unix)]
        Some("diag") => diag::run(&args[1..]),
        // Opening Kiri.app: set up on first launch, then the window.
        #[cfg(target_os = "macos")]
        None if setup::launched_from_app() => ui::run(true, None),
        #[cfg(target_os = "macos")]
        Some("ui") => ui::run(
            args.iter().any(|a| a == "--start"),
            args.iter().position(|a| a == "--view").and_then(|i| args.get(i + 1)).cloned(),
        ),
        #[cfg(target_os = "macos")]
        Some(c) if docker::handles(c) => {
            engine_version_check();
            docker::run(&args)
        }
        // Windows: the engine's commands, by the `kiri` in WSL.
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::FAILURE;
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            // The subcommand only: arguments can carry values.
            #[cfg(unix)]
            if !e.to_string().starts_with("usage:") {
                // Opened from Finder or the Dock there is none: "open" (#250).
                diag::warn!("command failed", command = args.first().map_or(Some("open"), |a| (a.len() <= 20 && a.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')).then_some(a.as_str())).unwrap_or(""), error = e);
            }
            eprintln!("kiri: {e}");
            ExitCode::FAILURE
        }
    }
}

// Apple Silicon only: Linux GTK, WSL bridge and Windows host entrypoints removed.
#[cfg(any(not(unix), target_os = "macos"))]
fn engine_version_check() {}

