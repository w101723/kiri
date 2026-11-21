#!/usr/bin/env python3
"""Enforce that the shipped macOS application has no embedded web frontend.

This check covers Kiri-owned source, the built .app resource tree, and direct
Mach-O framework dependencies. Third-party license text and the macOS Info.plist
(XML metadata) are not executable web frontend assets.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = [
    ROOT / "crates/kiri/native/MobyApp.swift",
    ROOT / "crates/kiri/native/MobyRuntime.swift",
    ROOT / "crates/kiri/native/KiriMobyHost.swift",
    ROOT / "crates/kiri/native/ArcBoxContainerModel.swift",
    ROOT / "crates/kiri/native/ArcBoxAppColors.swift",
    ROOT / "crates/kiri/native/ArcBoxAppMetrics.swift",
    ROOT / "crates/kiri/native/ArcBoxLiquidGlass.swift",
    ROOT / "crates/kiri/native/ArcBoxDetailTabPicker.swift",
    ROOT / "crates/kiri/native/ArcBoxResourceListRowView.swift",
    ROOT / "crates/kiri/native/ArcBoxContainerListCells.swift",
    ROOT / "crates/kiri/native/ArcBoxInfoRow.swift",
    ROOT / "crates/kiri/native/ArcBoxInfoTableView.swift",
    ROOT / "crates/kiri/native/ArcBoxIconButton.swift",
    ROOT / "crates/kiri/native/ArcBoxStatusBadge.swift",
    ROOT / "crates/kiri/native/ArcBoxToolbarSeparator.swift",
    ROOT / "crates/kiri/native/KiriArcBoxContainersList.swift",
    ROOT / "crates/kiri/native/KiriArcBoxContainerInfoTab.swift",
    ROOT / "crates/kiri/native/KiriArcBoxResourceView.swift",
    ROOT / "crates/kiri/native/MobyUITheme.swift",
    ROOT / "crates/kiri/native/MobyUIModels.swift",
    ROOT / "crates/kiri/native/MobyModel.swift",
    ROOT / "crates/kiri/native/MobyTelemetry.swift",
    ROOT / "crates/kiri/native/MobyDockerEvents.swift",
    ROOT / "crates/kiri/native/MobyTerminal.swift",
    ROOT / "crates/kiri/native/MobyUIComponents.swift",
    ROOT / "crates/kiri/native/MobyContainerWorkspace.swift",
]
ASSET_SUFFIXES = {
    ".html", ".htm", ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx",
    ".css", ".scss", ".less", ".webmanifest",
}
FORBIDDEN_SOURCE = [
    re.compile(pattern) for pattern in (
        r"(?m)^\s*import\s+(?:WebKit|JavaScriptCore)\b",
        r"\b(?:WKWebView|WKUserContentController|WKNavigationDelegate|"
        r"WKScriptMessageHandler|JSContext|JSValue|JavaScriptCore|"
        r"NSWebView|WebView)\b",
        r"(?i)<\s*(?:script|style|iframe|html)(?:\s|>)",
        r"(?i)\b(?:eval|document\.write|innerHTML)\s*\(",
        r"kiri-menubar-template@2x\.png",
    )
]


def verify_source(errors: list[str]) -> None:
    for file in SOURCES:
        if not file.is_file():
            errors.append(f"Missing native Swift source: {file}")
            continue
        content = file.read_text(encoding="utf-8")
        for pattern in FORBIDDEN_SOURCE:
            if pattern.search(content):
                errors.append(f"Web/frontend API or obsolete icon reference in {file.name}: {pattern.pattern}")
    app = "\n".join(s.read_text(encoding="utf-8") for s in SOURCES if s.name not in ("MobyRuntime.swift", "KiriMobyHost.swift"))
    for needle in ('NSImage(size: size, flipped: false)', 'NSSize(width: 18, height: 18)',
                   'func face(_ vertices: [NSPoint], alpha: CGFloat)',
                   'let radius: CGFloat = 6.2',
                   'context.compositingOperation = .destinationOut',
                   'gaps.lineWidth = 1.2',
                   '.opacity(model.online ? 1 : 0.42)',
                   'image.isTemplate = true', '.renderingMode(.template)'):
        if needle not in app:
            errors.append(f"Native monochrome status bar drawing missing: {needle}")
    for needle in ('Bundle.main.url(forResource: "Kiri", withExtension: "icns")',
                   '.renderingMode(.original)', 'image.isTemplate = false'):
        if needle in app:
            errors.append(f"Colorful Dock icon leaked into status-bar rendering: {needle}")
    if not (ROOT / "brand/icon/png/kiri-app-icon-1024.png").is_file():
        errors.append("Current branded icon source missing")
    if (ROOT / "brand/icon/png/kiri-menubar-template@2x.png").exists():
        errors.append("Obsolete independent menu-bar image remains in brand resources")
    # Prevent reintroducing the retired second PTY engine, orphaned UI helpers,
    # or host-side Rust responsibilities already migrated to Swift.
    retired_ui = (
        "HSplitView {", ".searchable(text: $model.search, placement: .toolbar",
        "private var detailHeader: some View",
        "ExecTerminalSession", "openpty(", "ContainerRowView: View",
        "func overviewCard(", "func localPortShortcut(",
        "func containerStateBadge(", "func containerSelection(",
        "liveLogContainerID",
    )
    for symbol in retired_ui:
        if symbol in app:
            errors.append(f"Retired duplicate or unused native UI component restored: {symbol}")
    host = SOURCES[2].read_text(encoding="utf-8")
    if "VZVirtioSocketListenerDelegate" in host or "setSocketListener(" in host:
        errors.append("Unused guest-initiated vsock listener was restored to Swift Host")
    guest_memory = (ROOT / "crates/kiri-moby-bridge/src/memory.rs").read_text(encoding="utf-8")
    if "pub struct Governor" in guest_memory:
        errors.append("Dead Rust Host balloon governor was restored to Linux Guest")
    guest_shares = (ROOT / "crates/kiri-moby-bridge/src/shares.rs").read_text(encoding="utf-8")
    if "pub fn encode(" in guest_shares:
        errors.append("Retired Rust Host share-map encoder was restored to Linux Guest")
    notice = (ROOT / "NOTICE").read_text(encoding="utf-8")
    if any(name in notice.lower() for name in ("webkit2gtk", "webview2-com", "javascriptcore-rs", "xterm.js")):
        errors.append("Legacy web runtime license manifest was reintroduced into native NOTICE")


def verify_app(root: pathlib.Path, errors: list[str]) -> None:
    if not root.is_dir():
        errors.append(f"Application bundle missing: {root}")
        return
    resources = root / "Contents/Resources"
    icon = resources / "Kiri.icns"
    if not icon.is_file() or icon.stat().st_size < 1000:
        errors.append("Missing or empty Kiri.icns for the Finder/Dock app icon")
    import plistlib
    try:
        with (root / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("CFBundleIconFile") != "Kiri":
            errors.append("Finder/Dock app icon mismatch: CFBundleIconFile must be Kiri")
    except (OSError, ValueError, plistlib.InvalidFileException) as exc:
        errors.append(f"Invalid native app Info.plist: {exc}")
    for f in root.rglob("*"):
        if not f.is_file():
            continue
        if f.suffix.lower() in ASSET_SUFFIXES:
            errors.append(f"Web frontend asset in .app: {f.relative_to(root)}")
        if f.name == "kiri-menubar-template@2x.png":
            errors.append("Stale menu-bar icon included in the App resources")
    preview = (root / "Contents/MacOS/kiri-moby-ui-preview").exists()
    helper_bundle = root / "Contents/Library/Helpers/Kiri Moby Helper.app"
    helper_binary = helper_bundle / "Contents/MacOS/Kiri Moby Helper"
    if not preview:
        try:
            with (helper_bundle / "Contents/Info.plist").open("rb") as stream:
                helper_info = plistlib.load(stream)
            expected = {
                "CFBundleIdentifier": "dev.kiri.app.moby.helper",
                "CFBundleExecutable": "Kiri Moby Helper",
                "CFBundleName": "Kiri Moby Helper",
                "LSUIElement": True,
            }
            for key, value in expected.items():
                if helper_info.get(key) != value:
                    errors.append(f"Unexpected Helper {key}: {helper_info.get(key)!r}")
        except (OSError, ValueError, plistlib.InvalidFileException) as exc:
            errors.append(f"Invalid nested Kiri Moby Helper.app Info.plist: {exc}")
    binaries = [root / ("Contents/MacOS/kiri-moby-ui-preview" if preview
                        else "Contents/MacOS/kiri-moby-ui")]
    if not preview:
        binaries.append(helper_binary)
    for binary in binaries:
        if not binary.is_file() or binary.is_symlink():
            errors.append(f"Missing native App executable: {binary}")
            continue
        result = subprocess.run(["otool", "-L", str(binary)],
                                capture_output=True, text=True, check=False)
        if result.returncode or re.search(r"WebKit|JavaScriptCore", result.stdout, re.I):
            errors.append(f"Unexpected web framework or otool failure: {binary}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=pathlib.Path)
    args = parser.parse_args()
    errors: list[str] = []
    verify_source(errors)
    if args.app:
        verify_app(args.app, errors)
    if errors:
        print("FAIL: Native-only runtime audit:\n - " + "\n - ".join(errors), file=sys.stderr)
        return 1
    print("PASS: native App sources, monochrome template menu-bar mark and no web frontend assets"
          + (" / framework links" if args.app else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
