#!/usr/bin/env bash
# CI-only Apple Developer ID signing + notarization for trusted macOS updates.
# Zero credentials => development-only ad-hoc build. Partial => hard failure.
set -euo pipefail
umask 077
app="${1:-packaged/Kiri Moby.app}"
keys=( MACOS_DEVELOPER_ID_P12_BASE64 MACOS_DEVELOPER_ID_P12_PASSWORD MACOS_DEVELOPER_ID_IDENTITY APPLE_NOTARY_KEY_BASE64 APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID )
present=0
for key in "${keys[@]}"; do
  [[ -z "${!key:-}" ]] || present=$((present+1))
done
if (( present == 0 )); then
  echo "No Apple Developer ID secrets: development-only ad-hoc app, NOT a signed distribution"
  [[ -z "${GITHUB_OUTPUT:-}" ]] || echo 'notarized=false' >> "$GITHUB_OUTPUT"
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] ||
    echo "⚠️ Ad-hoc development app only. No Gatekeeper-trusted distribution produced." >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi
if (( present != ${#keys[@]} )); then
  echo "Incomplete Apple Developer ID signing secrets ($present of ${#keys[@]}). Refusing to publish." >&2
  exit 2
fi
[[ "$MACOS_DEVELOPER_ID_IDENTITY" == "Developer ID Application: "* ]] || {
  echo "Requires a Developer ID Application certificate (not Apple Development)" >&2
  exit 2
}
[[ "$(uname -s)" == Darwin && -d "$app" ]] || {
  echo "macOS and an assembled Kiri Moby.app are required" >&2
  exit 2
}
resource="$app/Contents/Resources"
gui="$app/Contents/MacOS/kiri"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/kiri-sign.XXXXXXXX")"
keychain="$work/signing.keychain-db"
keychain_pw="$(openssl rand -hex 24)"
login="$HOME/Library/Keychains/login.keychain-db"
cleanup() {
  security default-keychain -d user -s "$login" >/dev/null 2>&1 || true
  security list-keychains -d user -s "$login" >/dev/null 2>&1 || true
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT
# Read secrets from environment, not command-line parameters or action logs.
python3 - "$work" <<'PY'
import base64, os, pathlib, sys
directory = pathlib.Path(sys.argv[1])
for key, filename in (
    ("MACOS_DEVELOPER_ID_P12_BASE64", "identity.p12"),
    ("APPLE_NOTARY_KEY_BASE64", "AuthKey.p8"),
):
    data = base64.b64decode(os.environ[key], validate=True)
    if not data:
        raise ValueError("empty secret: " + key)
    path = directory / filename
    path.write_bytes(data)
    path.chmod(0o600)
PY
security create-keychain -p "$keychain_pw" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$keychain_pw" "$keychain"
security list-keychains -d user -s "$keychain" "$login"
security default-keychain -d user -s "$keychain"
security import "$work/identity.p12" -k "$keychain" -P "$MACOS_DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_pw" "$keychain" >/dev/null
security find-identity -v -p codesigning "$keychain" |
  grep -F -- "\"$MACOS_DEVELOPER_ID_IDENTITY\"" >/dev/null || {
    echo "Imported P12 does not contain MACOS_DEVELOPER_ID_IDENTITY" >&2
    exit 2
  }
sign() {
  local item="$1"
  shift
  codesign --force --sign "$MACOS_DEVELOPER_ID_IDENTITY" --keychain "$keychain" \
    --timestamp --options runtime "$@" "$item"
  codesign --verify --strict --verbose=2 "$item"
}
# Must sign nested Mach-O files before the outer .app; the VZ helper needs
# com.apple.security.virtualization, the stock Docker tools do not.
sign "$resource/bin/kiri-moby-host" --entitlements crates/kiri/kiri.entitlements
for item in "$resource/bin/docker" \
            "$resource/bin/cli-plugins/docker-compose" \
            "$resource/bin/cli-plugins/docker-buildx"; do
  sign "$item"
done
sign "$gui" --entitlements crates/kiri/kiri.entitlements
sign "$app" --entitlements crates/kiri/kiri.entitlements
codesign --verify --deep --strict --verbose=2 "$app"

dmg="Kiri-Moby-macos-arm64-notarized.dmg"
# Use the same Finder drag-to-Applications layout for signed releases.
bash scripts/moby/package-dmg-macos.sh "$app" "$dmg"
xcrun notarytool submit "$dmg" \
  --key "$work/AuthKey.p8" --key-id "$APPLE_NOTARY_KEY_ID" \
  --issuer "$APPLE_NOTARY_ISSUER_ID" \
  --wait --output-format json > "$work/result.json"
python3 - "$work/result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
if result.get("status") != "Accepted":
    print("Notarization failed: %s (id=%s)" %
          (result.get("status"), result.get("id")), file=sys.stderr)
    sys.exit(1)
print("Notarization accepted:", result.get("id"))
PY
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
shasum -a 256 "$dmg" > "$dmg.sha256"
[[ -z "${GITHUB_OUTPUT:-}" ]] || echo 'notarized=true' >> "$GITHUB_OUTPUT"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "✅ Developer ID + Hardened Runtime + notarized/stapled DMG"
    echo "Signed bundle ID: dev.kiri.app.moby"
    echo "Artifact: $dmg"
  } >> "$GITHUB_STEP_SUMMARY"
fi
echo "Developer ID notarized/stapled DMG produced."
