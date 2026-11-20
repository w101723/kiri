#!/usr/bin/env bash
# Optional stable *personal* code signing: same P12 -> same identity each CI build.
# A self-signed personal identity is NOT Developer ID and is NOT notarization.
# No credentials => retain the clearly labeled ad-hoc DEV build.
set -euo pipefail
umask 077
[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS required" >&2; exit 2; }
app="${1:-packaged/Kiri Moby.app}"
[[ -d "$app" ]] || { echo "App not found: $app" >&2; exit 2; }
keys=(KIRI_PERSONAL_SIGN_P12_BASE64 KIRI_PERSONAL_SIGN_P12_PASSWORD KIRI_PERSONAL_SIGN_CERT_SHA256)
present=0
for key in "${keys[@]}"; do
  [[ -z "${!key:-}" ]] || present=$((present+1))
done
if ((present == 0)); then
  if [[ "${KIRI_REQUIRE_PERSONAL_SIGNING:-false}" == true ]]; then
    echo "RELEASE BLOCKED: personal signing is required but P12 signing secrets are missing" >&2
    exit 2
  fi
  echo "No persistent personal signer: development build remains ad-hoc (signature identity changes on rebuild)."
  [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "signed=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
if ((present != ${#keys[@]})); then
  echo "Incomplete stable personal signing secrets ($present of ${#keys[@]}); refusing to build." >&2
  exit 2
fi
[[ "$KIRI_PERSONAL_SIGN_CERT_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]] || {
  echo "KIRI_PERSONAL_SIGN_CERT_SHA256 must contain 64 hexadecimal characters" >&2
  exit 2
}
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/kiri-personal-sign.XXXXXXXX")"
keychain="$work/signing.keychain-db"
keychain_pw="$(openssl rand -hex 24)"
login="$HOME/Library/Keychains/login.keychain-db"
cleanup() {
  security default-keychain -d user -s "$login" >/dev/null 2>&1 || :
  security list-keychains -d user -s "$login" >/dev/null 2>&1 || :
  security delete-keychain "$keychain" >/dev/null 2>&1 || :
  rm -rf -- "$work"
}
trap cleanup EXIT
python3 - "$work/personal.p12" <<'PY'
import base64, os, pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_bytes(base64.b64decode(os.environ["KIRI_PERSONAL_SIGN_P12_BASE64"], validate=True))
p.chmod(0o600)
PY
security create-keychain -p "$keychain_pw" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$keychain_pw" "$keychain"
security list-keychains -d user -s "$keychain" "$login"
security default-keychain -d user -s "$keychain"
security import "$work/personal.p12" -k "$keychain" -P "$KIRI_PERSONAL_SIGN_P12_PASSWORD" -T /usr/bin/codesign
# Self-signed personal identities don't chain to Apple by default. Trust them
# ONLY within this temporary CI code-signing keychain, not on the user's Mac.
printf '%s' "$KIRI_PERSONAL_SIGN_P12_PASSWORD" > "$work/p12-password"
openssl pkcs12 -in "$work/personal.p12" -clcerts -nokeys \
  -passin "file:$work/p12-password" -out "$work/chain.pem"
openssl x509 -in "$work/chain.pem" -out "$work/leaf.pem"

# Certificates issued by our private CA need a trusted issuer *on this CI
# runner*. A valid imported identity is not sufficient: codesign attempts to
# build a chain to a trusted anchor, and otherwise fails errSecInternalComponent.
# The P12 may contain its issuing intermediate CA from -certfile. Extract CA
# certs only: NEVER trust the non-CA leaf as a root, which macOS can reject.
openssl pkcs12 -in "$work/personal.p12" -cacerts -nokeys \
  -passin "file:$work/p12-password" -out "$work/issuer-chain.pem"
if [[ -n "${KIRI_PERSONAL_SIGN_CA_PEM_BASE64:-}" ]]; then
  python3 - "$work/extra-chain.pem" <<'PY'
import base64, os, pathlib, sys
pathlib.Path(sys.argv[1]).write_bytes(
    base64.b64decode(os.environ["KIRI_PERSONAL_SIGN_CA_PEM_BASE64"], validate=True)
)
PY
  cat "$work/extra-chain.pem" >> "$work/issuer-chain.pem"
fi
python3 - "$work/issuer-chain.pem" "$work" <<'PY'
import pathlib, re, sys
chain = pathlib.Path(sys.argv[1]).read_text(errors="replace")
certs = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", chain, re.S)
for index, cert in enumerate(certs):
    (pathlib.Path(sys.argv[2]) / ("issuer-%d.pem" % index)).write_text(cert + "\n")
print("Available CA certificates:", len(certs))
PY
leaf_subject="$(openssl x509 -in "$work/leaf.pem" -noout -subject | sed 's/^subject[ =]*//')"
leaf_issuer="$(openssl x509 -in "$work/leaf.pem" -noout -issuer | sed 's/^issuer[ =]*//')"
if [[ "$leaf_subject" != "$leaf_issuer" ]]; then
  # An intermediate trusted "as root" is insufficient for some macOS
  # codesign policies: the entire chain must reach the genuine self-signed
  # private CA ROOT. The P12 normally embeds the intermediate but not root.
  # The additional public root PEM can be passed with
  # KIRI_PERSONAL_SIGN_CA_PEM_BASE64 (private root key is NOT required).
  root_cert=""
  for ca in "$work"/issuer-*.pem; do
    [[ -s "$ca" ]] || continue
    openssl x509 -in "$ca" -noout -text | grep -Fq 'CA:TRUE' || continue
    ca_subject="$(openssl x509 -in "$ca" -noout -subject | sed 's/^subject[ =]*//')"
    ca_issuer="$(openssl x509 -in "$ca" -noout -issuer | sed 's/^issuer[ =]*//')"
    [[ "$ca_subject" == "$ca_issuer" ]] || continue
    # Only trust a root cryptographically confirmed to anchor THIS leaf
    # through the included intermediate(s).
    if openssl verify -CAfile "$ca" \
        -untrusted "$work/issuer-chain.pem" "$work/leaf.pem" >/dev/null 2>&1; then
      root_cert="$ca"
      break
    fi
  done
  if [[ -z "$root_cert" ]]; then
    echo "PRIVATE CA ROOT MISSING: P12 contains the signer and issuing intermediate but not a trusted self-signed root." >&2
    echo "Provide only the PUBLIC root CA PEM via KIRI_PERSONAL_SIGN_CA_PEM_BASE64. Do not upload the root private key." >&2
    exit 2
  fi
  if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
    echo "Automatic private-root trust is restricted to disposable GitHub macOS runners; cannot alter trust on this Mac." >&2
    exit 2
  fi
  # Explicit admin trust for code signing, inside this disposable CI VM only.
  # macOS codesign must be able to find the actual root in System.keychain.
  perl -e 'alarm 20; exec @ARGV' \
    sudo -n security add-trusted-cert -d -r trustRoot \
      -p codeSign -k /Library/Keychains/System.keychain "$root_cert" || {
    echo "Cannot install trusted code-signing root in temporary macOS CI runner." >&2
    exit 2
  }
  echo "Verified complete private-CA chain; trusted its public root in ephemeral CI System.keychain."
fi
# Self-signed code identities are discoverable without -v even if no
# system-wide trust policy recognizes them. Never change the user's trust.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_pw" "$keychain" >/dev/null
# Keychains may contain other imported identities (for example, when
# signing with two test certificates on the same ephemeral runner). Select
# the exact SHA-1 certificate identity from this P12; NEVER choose the first
# available signer by display name or assume there is only one identity.
identity="$(openssl x509 -in "$work/leaf.pem" -outform DER | shasum -a 1 | awk '{print toupper($1)}')"
if ! security find-identity -p codesigning "$keychain" | grep -Fqi "$identity"; then
  echo "P12 leaf certificate does not have a usable code-signing private key in the ephemeral Keychain." >&2
  exit 2
fi
sign() {
  # Hardened Runtime is needed for Apple notarization, but not for a private
  # local-only build. Private PKI identities can be rejected by macOS while
  # constructing an Apple-style chain when --options runtime is requested.
  # Developer ID notarization is handled separately in sign-notarize-macos.sh.
  codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$@"
}
res="$app/Contents/Resources"
sign --entitlements crates/kiri/kiri.entitlements "$res/bin/kiri-moby-host"
for bin in "$res/bin/docker" "$res/bin/cli-plugins/docker-compose" "$res/bin/cli-plugins/docker-buildx"; do
  sign "$bin"
done
sign --entitlements crates/kiri/kiri.entitlements "$app/Contents/MacOS/kiri"
if [[ -f "$app/Contents/MacOS/kiri-moby-ui" ]]; then
  sign "$app/Contents/MacOS/kiri-moby-ui"
fi
sign --entitlements crates/kiri/kiri.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"
# Pin the exact LEAF certificate DER fingerprint; do not trust an arbitrary CN.
codesign -d --extract-certificates="$work/leaf-" "$app" >/dev/null 2>&1
[[ -s "$work/leaf-0" ]] || { echo "No signer certificate attached to app" >&2; exit 2; }
fingerprint="$(shasum -a 256 "$work/leaf-0" | awk '{print $1}')"
expected_sha="$(printf '%s' "$KIRI_PERSONAL_SIGN_CERT_SHA256" | tr '[:upper:]' '[:lower:]')"
if [[ "$fingerprint" != "$expected_sha" ]]; then
  echo "PERSONAL SIGNER MISMATCH: certificate differs from pinned secret!" >&2
  exit 2
fi
# The complete App archive must be created *after* re-signing.
tar -czf Kiri-Moby-macos-arm64-app.tgz -C packaged "Kiri Moby.app"
shasum -a 256 Kiri-Moby-macos-arm64-app.tgz > Kiri-Moby-macos-arm64-app.tgz.sha256
[[ -z "${GITHUB_OUTPUT:-}" ]] || {
  echo "signed=true" >> "$GITHUB_OUTPUT"
  echo "cert_sha256=$fingerprint" >> "$GITHUB_OUTPUT"
}
[[ -z "${GITHUB_STEP_SUMMARY:-}" ]] ||
  echo "Personal fixed signing identity: certificate SHA256 $fingerprint. This is not notarization." >> "$GITHUB_STEP_SUMMARY"
echo "Fixed personal signer applied to all Kiri Moby.app executables, certificate SHA256: $fingerprint"
