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
if not re.search(
    r"ForEach\(\[Page\.containers, \.images, \.volumes, \.networks, \.compose, \.builds\]",
    NEW,
) or "navButton(.settings)" not in NEW:
    errors.append("Native sidebar navigation order does not match approved reference image")

checks = [
    ('@Published var isLight = true', "Reference default light appearance"),
    ('Text("Kiri – Moby")', "Native window branding"),
    ('frame(height: 58)', "Reference-sized title strip"),
    ('? 60 : 258', "Reference sidebar width"),
    ('Text("资源")', "Resource sidebar section"),
    ('Text("系统")', "System sidebar section"),
    ('Text("虚拟机 (Moby)")', "VM sidebar navigation"),
    ('Text("VM 运行中")', "Live VM status chip"),
    ('liveMemoryLabel', "Live memory utilization summary"),
    ('diskFreeLabel', "Host available disk counter"),
    ('case .containers: "容器"', "Native localized container label"),
    ('Label("新建容器"', "New container toolbar"),
    ('TextField("搜索容器…"', "Container search field"),
    ('tableTitle("名称"', "Container name"),
    ('tableTitle("镜像"', "Container image"),
    ('tableTitle("状态"', "Container state"),
    ('tableTitle("端口"', "Container ports"),
    ('tableTitle("SHARE"', "Local port shortcut column"),
    ('tableTitle("创建时间"', "Container created"),
    ('tableTitle("操作"', "Container inline actions"),
    ('containerSelection(item.Id)', "Container selection checkbox"),
    ('containerStateBadge(item)', "Container status badges"),
    ('selectedContainerIDs.contains(item.Id)', "Selected row highlighting"),
    ('"cube.transparent"', "Reference container icon"),
    ('localPortShortcut(item)', "Explicit local-port shortcut"),
    ('containerOp("start"', "Start container"),
    ('containerOp("stop"', "Stop container"),
    ('containerOp("restart"', "Restart container"),
    ('containerOp("pause"', "Pause container"),
    ('containerOp("unpause"', "Resume container"),
    ('containerOp("remove"', "Remove container"),
    ('openExecTerminal(container.Id', "Native interactive Exec window"),
    ('openContainerLogs(container.Id', "Native floating logs window"),
    ('Toggle("实时跟随"', "Logs follow control"),
    ('Text("最近 1,000 行")', "Log retention selector"),
    ('Button("清空"', "Clear logs"),
    ('Label("中断 (Ctrl+C)"', "Interactive terminal interrupt"),
    ('Button("拉取镜像")', "Pull image"),
    ('Button("创建 Volume")', "Create volume"),
    ('Button("创建网络")', "Create network"),
    ('if !["bridge","host","none"].contains(item.Name)', "Protect default networks"),
    ('Text("Compose 项目")', "Compose project list"),
    ('private var composeProjects: [String]', "Compose project grouping"),
    ('ForEach(composeProjects, id:', "Compose expandable groups"),
    ('"com.docker.compose.service"', "Compose service labels"),
    ('ForEach(members)', "Compose nested containers"),
    ('Button("构建镜像")', "Buildx"),
    ('"linux/arm64"', "Buildx ARM64"),
    ('"linux/amd64"', "Buildx AMD64"),
    ('Text("虚拟机资源上限")', "Host-aware VM resource controls"),
    ('Stepper(value: $model.resourceCPUs', "VM CPU selector"),
    ('Slider(', "VM memory slider"),
    ('Button("仅保存")', "Persist VM settings"),
    ('"保存并重启 VM"', "Apply VM configuration"),
    ('Text("Mac 目录共享")', "Mac shares settings"),
    ('Button("选择共享目录…")', "Mac share picker"),
    ('Button("应用更改并重启 VM")', "Apply shares and restart"),
    ('OrbStack/default Docker context unchanged', "Independent Docker context footer"),
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
