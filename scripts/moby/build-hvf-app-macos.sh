#!/usr/bin/env bash
# Assemble a separate local macOS 27 app; never modify an installed app.
set -euo pipefail
umask 077
root="$(cd "$(dirname "$0")/../.." && pwd)"
[[ $# -ge 1 && $# -le 3 ]] || {
  printf 'Usage: %s /path/to/verified/guest-assets [source-app-for-cli] [build-directory]\n' "$0" >&2
  exit 2
}
[[ $(uname -sm) == 'Darwin arm64' && $(sw_vers -productVersion) == 27.* ]] || {
  printf 'Requires Apple Silicon running macOS 27\n' >&2; exit 2;
}
assets="$(cd "$1" && pwd -P)"
resources="${2:-/Applications/Kiri Moby.app}/Contents/Resources"
work="${3:-$root/target/hvf-probe-work}"
mkdir -p "$work"
work="$(cd "$work" && pwd -P)"
files=(Image initramfs.cpio data.img.tgz system.img.tgz rootfs.revision)
for file in "${files[@]}" SHA256SUMS; do
  [[ -s "$assets/$file" && ! -L "$assets/$file" ]] || { printf 'Missing Guest asset: %s\n' "$file" >&2; exit 1; }
done
(cd "$assets" && shasum -a 256 -c SHA256SUMS)

host_build="$(bash "$root/scripts/moby/build-hvf-probe-macos.sh" --helper "$work")"
helper="$(printf '%s\n' "$host_build" | grep '^Probe: ' | cut -c8-)"
[[ -x "$helper" ]]
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" MACOSX_DEPLOYMENT_TARGET=27.0
# SwiftPM's Clang module cache embeds the exact path; keep the canonical
# scratch path separate from any earlier /var-prefixed tool invocation.
ui=(--package-path "$root/crates/kiri/native" --scratch-path "$work/local-ui27" -c release --product kiri-moby-ui
    --triple arm64-apple-macosx27.0 -Xswiftc -DKIRI_HVF_LOCAL)
xcrun swift build "${ui[@]}"
bin="$(xcrun swift build "${ui[@]}" --show-bin-path)"
output="$(mktemp -d "$work/local-app.XXXXXXXX")"
app="$output/Kiri Moby HVF.app"
mac="$app/Contents/MacOS"
res="$app/Contents/Resources"
mkdir -p "$mac" "$res/guest" "$res/bin/cli-plugins"
cp "$bin/kiri-moby-ui" "$mac/"
for bundle in "$bin"/*.bundle; do [[ ! -d "$bundle" ]] || ditto "$bundle" "$res/$(basename "$bundle")"; done
for file in "${files[@]}" SHA256SUMS; do cp "$assets/$file" "$res/guest/"; done
# Changing any boot asset invalidates the local install cache.
shasum -a 1 "$res/guest/SHA256SUMS" | cut -d ' ' -f 1 > "$res/SOURCE_REVISION"
cp "$resources/Kiri.icns" "$res/"
cp "$root/LICENSE" "$root/NOTICE" "$res/"
cp "$work/libkrun/LICENSE" "$res/LICENSE-libkrun"
cp "$work/libslirp/COPYRIGHT" "$res/COPYRIGHT-libslirp"
cp "$resources/bin/docker" "$res/bin/"
for name in docker-compose docker-buildx; do cp "$resources/bin/cli-plugins/$name" "$res/bin/cli-plugins/"; done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.kiri.app.moby.hvf.local</string>
  <key>CFBundleExecutable</key><string>kiri-moby-ui</string>
  <key>CFBundleName</key><string>Kiri Moby HVF</string>
  <key>CFBundleDisplayName</key><string>Kiri Moby HVF</string>
  <key>CFBundleIconFile</key><string>Kiri</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
bash "$root/scripts/moby/package-helper-macos.sh" "$app" "$helper" --local-hvf
nested="$app/Contents/Library/Helpers/Kiri Moby Helper.app"
for item in "$res/bin/docker" "$res/bin/cli-plugins/"* "$nested/Contents/Frameworks/"*; do
  codesign --force --sign - "$item"
done
codesign --force --sign - --entitlements "$root/crates/kiri/native/hvf/hypervisor.entitlements" "$nested"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
links="$(otool -L "$mac/kiri-moby-ui" "$nested/Contents/MacOS/Kiri Moby Helper" "$nested/Contents/Frameworks/libkrun.1.dylib")"
[[ $links == *'/Hypervisor.framework/'* && $links != *'/Virtualization.framework/'* ]]
printf 'Local HVF App: %s\n' "$app"
