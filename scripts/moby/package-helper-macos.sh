#!/usr/bin/env bash
set -euo pipefail

# Bundle the independent Swift VM Host without changing its executable code.
[[ $# -eq 2 ]] || {
  echo "Usage: $0 '/path/to/Kiri Moby.app' /path/to/kiri-moby-host" >&2
  exit 2
}
app="$1"
binary="$2"
[[ -d "$app/Contents" && -f "$binary" && ! -L "$binary" ]] || {
  echo "Expected an assembled App and regular Swift Host binary" >&2
  exit 2
}
helper="$app/Contents/Library/Helpers/Kiri Moby Helper.app"
[[ ! -e "$helper" && ! -L "$helper" ]] || {
  echo "Refusing to overwrite existing Helper bundle: $helper" >&2
  exit 2
}
mkdir -p "$helper/Contents/MacOS"
cp "$binary" "$helper/Contents/MacOS/Kiri Moby Helper"
chmod 755 "$helper/Contents/MacOS/Kiri Moby Helper"
cat > "$helper/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.kiri.app.moby.helper</string>
  <key>CFBundleName</key><string>Kiri Moby Helper</string>
  <key>CFBundleDisplayName</key><string>Kiri Moby Helper</string>
  <key>CFBundleExecutable</key><string>Kiri Moby Helper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
echo "Packaged headless Swift VM Helper: $helper"
