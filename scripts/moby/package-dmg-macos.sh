#!/usr/bin/env bash
# Create the standard Finder drag-to-Applications macOS disk image.
# No shell installer is needed for normal App installation.
set -euo pipefail
umask 022

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 '/path/to/Kiri Moby.app' /path/to/output.dmg" >&2
  exit 2
fi
app="$1"
output="$2"
[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS required to create DMG" >&2; exit 2; }
[[ -d "$app" && -f "$app/Contents/Info.plist" ]] || {
  echo "Expected signed Kiri Moby.app" >&2
  exit 2
}
[[ "$output" == *.dmg ]] || { echo "Output must be .dmg" >&2; exit 2; }
for command in ditto hdiutil codesign shasum; do
  command -v "$command" >/dev/null || { echo "Missing $command" >&2; exit 2; }
done
id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
[[ "$id" == "dev.kiri.app.moby" ]] || {
  echo "Unexpected bundle identifier: $id" >&2
  exit 2
}
codesign --verify --deep --strict --verbose=2 "$app"

# The mounted disk contains exactly the App, an Applications symlink and a
# small readme. ditto preserves the signed bundle's symlinks and metadata.
stage="$(mktemp -d "${RUNNER_TEMP:-/tmp}/kiri-dmg.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/volume"
ditto "$app" "$stage/volume/Kiri Moby.app"
ln -s /Applications "$stage/volume/Applications"
cat > "$stage/volume/Install Kiri Moby.txt" <<'GUIDE'
Kiri Moby — macOS Apple Silicon

安装 / Install:
1. 将 Kiri Moby.app 拖到 Applications（应用程序）文件夹。
   Drag Kiri Moby.app to the Applications shortcut.
2. 在“应用程序”中启动 Kiri Moby，无需运行安装脚本。
   Open Kiri Moby from Applications. No shell installer required.
3. 升级时，先停止 Kiri Moby VM，再用新版 .app 覆盖旧版。
   Stop the Kiri Moby VM before replacing the app on an upgrade.

请检查下载产物名称中的签名类型：
- DeveloperID-notarized：已使用 Apple Developer ID 签名并通过公证。
- DEV-PERSONAL-CERT：使用同一张个人签名证书（非 Apple 公证）。
  首次通过受限的本地安装脚本授权并记录证书指纹；以后请用该安装脚本升级。
  直接从下载 DMG 拖拽到应用程序，仍可能被 macOS Gatekeeper 拦截。
- DEV-ADHOC：没有稳定签名身份，仅供测试；下载后可能被拦截。
  若要求固定签名，请先配置 KIRI_PERSONAL_SIGN_* Secrets。
  这不是应用损坏，标准 DMG 不能代替 Apple 公证。
不要全局关闭 macOS 安全保护。

Check the artifact's SIGNING CLASS in its filename:
- DeveloperID-notarized: Apple Developer ID signed, notarized and stapled.
- DEV-PERSONAL-CERT: same private signing cert across builds; use the
  once-authorized certificate-pinning installer for subsequent updates.
  Directly opening quarantined downloaded DMGs may still trigger Gatekeeper.
- DEV-ADHOC: no stable signer; development-only.
Do not disable system-wide macOS security to run a development build.

Docker 数据存于 ~/.kiri-moby/，不会随着 App 的替换而删除。
The existing Docker VM disk and container data are stored separately.
GUIDE

# Do not allow an unexpected/partial DMG to masquerade as a completed build.
mkdir -p "$(dirname "$output")"
[[ ! -e "$output" ]] || { echo "Refusing to overwrite existing DMG $output" >&2; exit 2; }
tmp="$output.partial.dmg"
[[ ! -e "$tmp" ]] || { echo "Incomplete previous DMG found: $tmp" >&2; exit 2; }
trap 'rm -rf -- "$stage"; rm -f -- "$tmp"' EXIT
hdiutil create -quiet -fs HFS+ -volname "Kiri Moby" \
  -srcfolder "$stage/volume" -format UDZO -ov "$tmp"
hdiutil verify "$tmp" >/dev/null
# Verify the Finder experience and nested signature from the image itself.
# Use an explicit private mountpoint so other mounted Kiri DMGs are untouched.
mountpoint="$stage/mounted"
mkdir -p "$mountpoint"
mounted=false
detach_on_exit() {
  if $mounted; then
    hdiutil detach -quiet "$mountpoint" || :
  fi
  rm -rf -- "$stage"
  rm -f -- "$tmp"
}
trap detach_on_exit EXIT
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mountpoint" "$tmp"
mounted=true
[[ -L "$mountpoint/Applications" ]] &&
  [[ "$(readlink "$mountpoint/Applications")" == "/Applications" ]] &&
  [[ -d "$mountpoint/Kiri Moby.app" ]] ||
    { echo "Invalid Finder drag-to-Applications DMG layout" >&2; exit 2; }
codesign --verify --deep --strict "$mountpoint/Kiri Moby.app"
hdiutil detach -quiet "$mountpoint"
mounted=false
mv "$tmp" "$output"
shasum -a 256 "$output" > "$output.sha256"
echo "Standard macOS Finder installation image ready: $output"
