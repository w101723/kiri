#!/usr/bin/env python3
"""Static UI contract: original Moby controls plus approved native Compose/VM updates.

The native SwiftUI app must also compile and undergo real-device acceptance.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
OLD = (ROOT / "crates/kiri/src/ui/moby.html").read_text(encoding="utf-8")
NEW = (ROOT / "crates/kiri/native/MobyApp.swift").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github/workflows/moby-milestone.yml").read_text()
SIGNER = (ROOT / "scripts/moby/sign-personal-macos.sh").read_text()
INSTALL = (ROOT / "scripts/moby/install-local-macos.sh").read_text()
errors = []

def has(haystack, needle, label):
    if needle not in haystack:
        errors.append(f"{label}: missing {needle!r}")

legacy_nav = re.findall(
    r'<button data-page="([^"]+)"',
    OLD.split("<aside>", 1)[1].split("</aside>", 1)[0])
if legacy_nav != [
    "containers", "compose", "images", "volumes", "networks", "build", "settings"
]:
    errors.append("Original Moby navigation unexpectedly changed")
# HIG-native navigation intentionally replaces all legacy hand-painted bars.
if not all(token in NEW for token in (
    "NavigationSplitView {", "List(selection:", ".listStyle(.sidebar)",
    ".navigationSplitViewColumnWidth(", "nativeSidebarItem(.settings)",
    ".toolbar {", ".searchable(text:", "VSplitView {",
)):
    errors.append("Native macOS NavigationSplitView/toolbar/sidebar contract is incomplete")

checks = [
    ('NavigationSplitView {', "System managed split navigation"),
    ('.listStyle(.sidebar)', "macOS vibrancy sidebar material"),
    ('.badge(count)', "Native sidebar counter badges"),
    ('.searchable(text: $model.search, placement: .toolbar', "System toolbar search"),
    ('ToolbarItem(placement: .primaryAction)', "Native primary action"),
    ('.popover(isPresented: $showVMPopover)', "Compact VM popover"),
    ('vmResourcePopover', "VM resource and restart popover"),
    ('VSplitView {', "Resizable vertical workspace splitter"),
    ('nativeConsoleDrawer', "Unified bottom console"),
    ('WindowGroup("容器控制台", id: "container-console"', "Real macOS console windows"),
    ('openWindow(id: "container-console", value: selected)', "Pop-out from drawer"),
    ('tabbingMode = .preferred', "AppKit native window tabbing"),
    ('ConsoleSession: Codable, Hashable, Identifiable', "Stable typed sessions"),
    ('NativeLogTextView: NSViewRepresentable', "Incremental NSTextView log renderer"),
    ('ConsoleAppearance.canvas', "Consistent charcoal console canvas"),
    ('ConsoleAppearance.toolbar', "Single compact shared console tab bar"),
    ('ScrollView(.horizontal, showsIndicators: false)', "Compact scrollable console tabs"),
    ('CompactContainerMetrics(stats:', "Compact CPU/RAM-only resource cells"),
    ('LabeledContent("网络接收（累计）"', "Network and disk moved into detail popover"),
    ('Button("localhost:\\(String(published)) ↗")', "Port number grouping disabled"),

    ('view.usesFindBar = true', "AppKit native find bar"),
    ('storage.append(NSAttributedString(', "Incremental log text insertion"),
    ('Table(sorted, selection: $selectedContainerIDs, sortOrder: $tableSortOrder)', "Native NSTableView backed container table"),
    ('TableColumn("名称"', "Sortable container name"),
    ('TableColumn("镜像"', "Sortable container image"),
    ('TableColumn("状态"', "Sortable container state"),
    ('TableColumn("CPU / 内存"', "Live container resource column"),
    ('containerResourceCell(item)', "Docker stats resource cells"),
    ('containerResourceCell(container)', "Compose resource cells"),
    ('model.refreshContainerStats()', "Periodic Docker stats refresh"),
    ('TableColumn("端口"', "Ports column"),
    ('Button("localhost:', "Native localhost port link in Ports column"),
    ('TableColumn("创建时间"', "Sortable creation date"),
    ('TableColumn("操作"', "Native operations column"),
    ('.contextMenu(forSelectionType: String.self)', "Native batch context menu"),
    ('"删除选中的', "Multi-selection delete confirmation"),
    ('containerOp("start"', "Start container"),
    ('containerOp("stop"', "Stop container"),
    ('containerOp("restart"', "Restart container"),
    ('containerOp("pause"', "Pause container"),
    ('containerOp("unpause"', "Resume container"),
    ('containerOp("remove"', "Remove container"),
    ('openConsole(.exec', "Exec opens console drawer"),
    ('openConsole(.logs', "Logs opens console drawer"),
    ('sendConsoleCommand(.toggleFollow', "Live log follow control"),
    ('Button("最近 1,000 行")', "Log tail options"),
    ('sendConsoleCommand(.clear', "Clear logs"),
    ('sendConsoleCommand(.interrupt', "Exec interrupt"),
    ('Button("拉取镜像")', "Docker image pull"),
    ('Button("创建 Volume")', "Docker volume creation"),
    ('Button("创建网络")', "Docker network creation"),
    ('if !["bridge","host","none"].contains(item.Name)', "Protected default networks"),
    ('Text("Compose 项目")', "Expandable Compose project list"),
    ('private var composeProjects: [String]', "Compose group discovery"),
    ('ForEach(composeProjects, id:', "Compose grouped projects"),
    ('"com.docker.compose.service"', "Compose service label"),
    ('ForEach(members)', "Compose container rows"),
    ('Button("构建镜像")', "Buildx"),
    ('"linux/arm64"', "ARM64 target"),
    ('"linux/amd64"', "AMD64 target"),
    ('Text("虚拟机资源上限")', "VM CPU RAM settings"),
    ('Stepper(value: $model.resourceCPUs', "VM CPU control"),
    ('Slider(', "VM memory slider"),
    ('Button("仅保存")', "Persistent VM settings"),
    ('"保存并重启 VM"', "Apply VM config by restart"),
    ('Text("Mac 目录共享")', "Explicit shared Mac directories"),
    ('Button("选择共享目录…")', "Shares panel"),
    ('Button("应用更改并重启 VM")', "Apply shares"),
    ('OrbStack/default Docker context unchanged', "Private Docker context footer"),
]
for key, label in checks:
    has(NEW, key, label)

for label in ("Containers", "Images", "Volumes", "Networks", "Compose", "Builds", "Settings"):
    has(OLD, label, "Original navigation")
    has(NEW, label, "Native navigation")

has(WORKFLOW, "CFBundleExecutable</key><string>kiri-moby-ui", "Native Finder binary")
for text, label in [(SIGNER, "Personal signer"), (INSTALL, "Local installer")]:
    has(text, "Contents/MacOS/kiri-moby-ui", label)

# The Linux ARM64 Guest IS required for Apple Silicon Docker VM.
for required in ("guest/kernel/build.sh", "scripts/moby/build-guest.sh"):
    if not (ROOT / required).is_file():
        errors.append(f"Required Docker Guest build source missing: {required}")
for forbidden in (
    "crates/kiri-win", "crates/kiri-init", "crates/kiri/src/ui/gtk.rs",
    "crates/kiri/src/ui/linux.rs", "packaging/linux", "installer/windows",
):
    if (ROOT / forbidden).exists():
        errors.append(f"Unsupported host source remains: {forbidden}")

if errors:
    print("FAIL: Native Moby parity contract:\n  - " + "\n  - ".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"PASS: {len(checks)} native Moby UI parity assertions and macOS-only scope.")
