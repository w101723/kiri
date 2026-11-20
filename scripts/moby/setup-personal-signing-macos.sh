#!/usr/bin/env bash
# Once per personal Kiri Moby signer. Run on a trusted Mac, NOT in CI.
# Usage: bash scripts/moby/setup-personal-signing-macos.sh [--upload]
# With --upload and authenticated gh CLI, configures 3 GitHub Actions Secrets.
# Never generate a fresh signing identity during CI or a normal update.
set -euo pipefail
umask 077
[[ "$(uname -s)" == Darwin ]] || { echo "Run on your trusted Mac" >&2; exit 2; }
upload=false
if [[ $# -eq 1 && "$1" == "--upload" ]]; then
  upload=true
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--upload]" >&2; exit 2
fi
dir="$(printenv KIRI_PERSONAL_SIGN_DIR || true)"
[[ -n "$dir" ]] || dir="$HOME/.config/kiri-moby/signing"
[[ "$dir" == /* && ! -L "$dir" ]] || {
  echo "Signing directory must be absolute and not a symlink" >&2; exit 2;
}
mkdir -p "$dir"
chmod 700 "$dir"
cert="$dir/personal-cert.pem"
p12="$dir/personal.p12"
passfile="$dir/p12-password"
if [[ -e "$cert" || -e "$p12" || -e "$passfile" ]]; then
  [[ -s "$cert" && -s "$p12" && -s "$passfile" ]] || {
    echo "Partial signing identity exists; refusing automatic regeneration" >&2; exit 2;
  }
  echo "Reusing existing persistent personal signing certificate."
else
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  cat > "$tmp/openssl.cnf" <<'CONF'
[ req ]
prompt = no
distinguished_name = dn
default_md = sha256
x509_extensions = v3_code
[ dn ]
CN = Kiri Moby Personal Code Signing
O = Personal Development
[ v3_code ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
CONF
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -keyout "$tmp/private.pem" -out "$cert" -config "$tmp/openssl.cnf"
  openssl rand -hex 24 > "$passfile"
  openssl pkcs12 -export -inkey "$tmp/private.pem" -in "$cert" \
    -out "$p12" -passout "file:$passfile" \
    -name "Kiri Moby Personal Code Signing"
  chmod 600 "$cert" "$p12" "$passfile"
  echo "Created ten-year personal code-signing identity (encrypted P12)."
fi
cert_sha="$(openssl x509 -in "$cert" -outform DER | shasum -a 256 | awk '{print $1}')"
printf '%s\n' "$cert_sha" > "$dir/cert-sha256"
chmod 600 "$dir/cert-sha256"
base64 < "$p12" | tr -d '\r\n' > "$dir/p12-base64"
chmod 600 "$dir/p12-base64"

echo
echo "Personal certificate SHA256: $cert_sha"
echo "Back up $p12 and $passfile securely; keep using the SAME key for every update."
if ! $upload; then
  echo
  echo "In w101723/kiri -> Settings -> Secrets and variables -> Actions,"
  echo "add these repository secrets from your LOCAL files (do not paste secrets in chat):"
  echo "  KIRI_PERSONAL_SIGN_P12_BASE64    <- $dir/p12-base64"
  echo "  KIRI_PERSONAL_SIGN_P12_PASSWORD  <- $passfile"
  echo "  KIRI_PERSONAL_SIGN_CERT_SHA256   <- $dir/cert-sha256"
  echo "Then create Repository variable KIRI_REQUIRE_PERSONAL_SIGNING = true."
  echo "This makes CI REFUSE ad-hoc fallback if your P12 is unavailable."
  echo
  echo "Or run again with --upload if you already have an authenticated gh CLI."
  exit 0
fi
command -v gh >/dev/null || {
  echo "gh CLI not installed; nothing uploaded. Use GitHub Settings manually." >&2
  exit 2
}
gh auth status >/dev/null
gh secret set KIRI_PERSONAL_SIGN_P12_BASE64 -R w101723/kiri < "$dir/p12-base64"
gh secret set KIRI_PERSONAL_SIGN_P12_PASSWORD -R w101723/kiri < "$passfile"
gh secret set KIRI_PERSONAL_SIGN_CERT_SHA256 -R w101723/kiri < "$dir/cert-sha256"
gh variable set KIRI_REQUIRE_PERSONAL_SIGNING -R w101723/kiri --body true
echo "Persistent signer secrets and fail-closed requirement configured."
