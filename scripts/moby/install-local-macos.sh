#!/bin/bash
# Kiri Moby personal-use installer. Scoped quarantine opt-in; no global spctl changes.
set -euo pipefail
umask 077
trustdir="$HOME/Library/Application Support/Kiri Moby"
trustfile="$trustdir/trust-local-builds-v1"
trustmark="w101723/kiri: opt-in local development app updates"
help() {
  echo "Usage: $0 --trust-local-builds | --status | --revoke-local-trust" >&2
  echo "       $0 [--verify] <Kiri-Moby-macos-arm64-app.zip|.tgz>" >&2
}
trusted() {
  [[ -f "$trustfile" && ! -L "$trustdir" && ! -L "$trustfile" ]] &&
    [[ "$(cat "$trustfile")" == "$trustmark" ]]
}
case "${1:-}" in
  --status)
    if trusted; then echo "Kiri local build consent: enabled"; else echo "Kiri local build consent: disabled"; fi
    exit 0;;
  --revoke-local-trust)
    [[ ! -L "$trustdir" && ! -L "$trustfile" ]] || exit 2
    rm -f "$trustfile"
    echo "Local build consent revoked."
    exit 0;;
  --trust-local-builds)
    [[ "$(uname -s)" == Darwin ]] || { echo "macOS only" >&2; exit 2; }
    if trusted; then echo "Already enabled."; exit 0; fi
    [[ -t 0 ]] || { echo "One-time interactive consent required" >&2; exit 2; }
    echo "This will allow future versions of your own Kiri Moby.app to be"
    echo "installed with the download quarantine removed after verifying checksums"
    echo "and code signatures. It skips per-build Gatekeeper verification for Kiri"
    echo "only. It does NOT notarize the app or disable macOS-wide security."
    echo "Only use Kiri artifacts you trust from github.com/w101723/kiri."
    echo "Type TRUST KIRI to authorize this local-only update procedure:"
    read -r answer
    [[ "$answer" == "TRUST KIRI" ]] || { echo "Cancelled"; exit 2; }
    [[ ! -L "$trustdir" && ! -L "$trustfile" && ! -e "$trustfile" ]] ||
      { echo "Trust location is unsafe or already exists" >&2; exit 2; }
    mkdir -p "$trustdir"
    chmod 700 "$trustdir"
    (set -C; printf '%s\n' "$trustmark" > "$trustfile")
    chmod 600 "$trustfile"
    echo "Enabled. Future updates via this installer need no repeated Gatekeeper override."
    exit 0;;
esac
verify=false
if [[ "${1:-}" == --verify ]]; then verify=true; shift; fi
[[ $# -eq 1 && -f "$1" ]] || { help; exit 2; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] ||
  { echo "Apple Silicon macOS required" >&2; exit 2; }
if ! $verify && ! trusted; then
  echo "First run: bash Kiri-Moby-install-local.sh --trust-local-builds" >&2
  exit 2
fi
for tool in python3 shasum codesign lipo xattr tar; do
  command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 2; }
done
if ! $verify && pgrep -x kiri-moby-host >/dev/null 2>&1; then
  echo "Stop Kiri Moby VM before upgrading to preserve the Docker disk." >&2
  exit 2
fi
parent="${KIRI_MOBY_APP_PARENT:-$HOME/Applications}"
[[ "$parent" == /* && ! -L "$parent" ]] ||
  { echo "Install parent must be an absolute path, not a symlink" >&2; exit 2; }
mkdir -p "$parent"
dest="$parent/Kiri Moby.app"
[[ ! -L "$dest" ]] || { echo "Refusing symlink destination" >&2; exit 2; }
stage="$(mktemp -d "$parent/.kiri-stage.XXXXXXXX")"
backup=""
cleanup() {
  if [[ -n "$backup" && -d "$backup" && ! -d "$dest" ]]; then
    mv "$backup" "$dest" || echo "Rollback needed: $backup" >&2
  fi
  rm -rf -- "$stage"
}
trap cleanup EXIT
mkdir "$stage/artifact"
case "$1" in
  *.zip)
    python3 - "$1" "$stage/artifact" <<'PY'
import pathlib, sys, zipfile
dest = pathlib.Path(sys.argv[2])
allowed = {"Kiri-Moby-macos-arm64-app.tgz",
           "Kiri-Moby-macos-arm64-app.tgz.sha256",
           "Kiri-Moby-install-local.sh", "DEV-ADHOC-ONLY.txt"}
with zipfile.ZipFile(sys.argv[1]) as bundle:
    names = set()
    for obj in bundle.infolist():
        if obj.filename not in allowed or obj.filename in names or obj.is_dir():
            sys.exit("Unrecognized or duplicate GitHub artifact ZIP entry")
        if obj.file_size > 1000000000 or ((obj.external_attr >> 16) & 0o170000) == 0o120000:
            sys.exit("Unsafe GitHub artifact ZIP member")
        names.add(obj.filename)
        (dest / obj.filename).write_bytes(bundle.read(obj))
PY
    ;;
  *.tgz)
    cp "$1" "$stage/artifact/Kiri-Moby-macos-arm64-app.tgz"
    [[ -f "$1.sha256" ]] || { echo "Missing $1.sha256" >&2; exit 2; }
    cp "$1.sha256" "$stage/artifact/Kiri-Moby-macos-arm64-app.tgz.sha256"
    ;;
  *) echo "Expected GitHub app artifact .zip or .tgz" >&2; exit 2;;
esac
name="Kiri-Moby-macos-arm64-app.tgz"
[[ -s "$stage/artifact/$name" && -s "$stage/artifact/$name.sha256" ]] ||
  { echo "Missing App artifact or checksum" >&2; exit 2; }
python3 - "$stage/artifact/$name.sha256" "$stage/artifact/$name" <<'PY'
from pathlib import Path
import re, sys, tarfile
s=Path(sys.argv[1]).read_text(encoding="ascii").strip()
if not re.fullmatch(r'[a-fA-F0-9]{64}  Kiri-Moby-macos-arm64-app\.tgz',s):
    sys.exit("Unexpected SHA256 manifest")
with tarfile.open(sys.argv[2],"r:gz") as archive:
    for member in archive:
        path=member.name.removeprefix("./")
        if not (path=="Kiri Moby.app" or path.startswith("Kiri Moby.app/")):
            sys.exit("Unexpected archive member: "+member.name)
        if ".." in path.split("/") or not (member.isfile() or member.isdir()):
            sys.exit("Unsafe archive member: "+member.name)
        if member.size>1000000000:
            sys.exit("Oversized archive member")
PY
(cd "$stage/artifact" && shasum -a 256 -c "$name.sha256")
tar -xzf "$stage/artifact/$name" -C "$stage" "Kiri Moby.app"
candidate="$stage/Kiri Moby.app"
[[ -d "$candidate" && ! -L "$candidate" ]] ||
  { echo "Kiri Moby.app missing in build" >&2; exit 2; }
bundleid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")"
[[ "$bundleid" == dev.kiri.app.moby ]] || { echo "Unexpected bundle ID: $bundleid" >&2; exit 2; }
revision="$candidate/Contents/Resources/SOURCE_REVISION"
[[ -f "$revision" ]] || { echo "Missing source revision" >&2; exit 2; }
grep -Eq '^[0-9a-fA-F]{40}$' "$revision" || { echo "Invalid source revision" >&2; exit 2; }
for program in "$candidate/Contents/MacOS/kiri" \
  "$candidate/Contents/Resources/bin/kiri-moby-host" \
  "$candidate/Contents/Resources/bin/docker" \
  "$candidate/Contents/Resources/bin/cli-plugins/docker-compose" \
  "$candidate/Contents/Resources/bin/cli-plugins/docker-buildx"; do
  [[ -f "$program" && ! -L "$program" ]] || { echo "Missing executable: $program" >&2; exit 2; }
  [[ "$(lipo "$program" -archs)" == arm64 ]] ||
    { echo "Expected ARM64 executable: $program" >&2; exit 2; }
  codesign --verify --strict "$program"
done
codesign --verify --deep --strict "$candidate"
if $verify; then echo "Verified: manifest checksum, bundle identity, ARM64 and app signatures"; exit 0; fi

# Only after one-time explicit consent, and ONLY inside the checked Kiri app.
xattr -dr com.apple.quarantine "$candidate" 2>/dev/null || :
if xattr -lr "$candidate" 2>/dev/null | grep -Fq com.apple.quarantine; then
  echo "Quarantine removal failed; refusing install" >&2; exit 2
fi
codesign --verify --deep --strict "$candidate"
if [[ -d "$dest" ]]; then
  backup="$parent/Kiri Moby.app.backup.$(date '+%Y%m%d-%H%M%S').$$"
  mv "$dest" "$backup"
fi
mv "$candidate" "$dest"
echo "Installed $dest"
[[ -z "$backup" ]] || echo "Previous app backup retained: $backup"
echo "Kiri Docker disk untouched: $HOME/.kiri-moby/vm/data.img"
echo "Open with: open \"$dest\""
