# Kiri Moby: fixed personal code-signing identity

For private use, a persistent self-signed code-signing certificate can preserve
stable code identity across CI builds. **It is not Apple Developer ID and will
not pass Gatekeeper on a freshly downloaded quarantined app by itself.**

This personal workflow is scoped to Kiri Moby. It does not turn off macOS
security globally or require buying an Apple developer subscription.

## One-time setup

On a trusted Mac, from a clone of the moby-engine branch:

    bash scripts/moby/setup-personal-signing-macos.sh

It creates a ten-year personal code-signing certificate and encrypted P12
under ~/.config/kiri-moby/signing, then prints the SHA256 fingerprint.

If you already have authenticated GitHub CLI installed:

    bash scripts/moby/setup-personal-signing-macos.sh --upload

Otherwise add these three GitHub Actions repository Secrets manually, using
the corresponding local files printed by the setup script:

- KIRI_PERSONAL_SIGN_P12_BASE64 (contents of p12-base64)
- KIRI_PERSONAL_SIGN_P12_PASSWORD (contents of p12-password)
- KIRI_PERSONAL_SIGN_CERT_SHA256 (contents of cert-sha256)

Also create Actions Repository variable KIRI_REQUIRE_PERSONAL_SIGNING=true.
This blocks accidental fallback to an unstable Ad-hoc signature if any
signing secret is missing.

Securely back up personal.p12 and the password. Never paste private keys,
P12 data, or passwords into chat, commits, tickets, or CI logs. Never
regenerate your signing certificate for a routine release.

## Repeated CI builds

Launch the Kiri Moby unified macOS ARM64 milestone bundle on moby-engine.
The CI imports the same P12 into a temporary keychain, signs all nested
binaries and the outer Kiri Moby.app, verifies the actual embedded leaf
certificate SHA256, and removes the temporary keychain.

Personal artifacts are clearly labeled DEV-PERSONAL-CERT. Only Developer ID
and Apple notarization produce a normal Gatekeeper-trusted distribution.

## First local installation

Download and extract the GitHub Actions app ZIP, which bundles the installer
and SHA256-verified app archive. Execute:

    bash Kiri-Moby-install-local.sh --trust-local-builds
    bash Kiri-Moby-install-local.sh /absolute/path/to/Kiri-Moby-macos-arm64-DEV-PERSONAL-CERT-app.zip

The consent step happens once. The installer verifies the bundle identity,
the integrity of the archive, signatures and architecture. The first stable
personal signing certificate is pinned under the current user's
~/Library/Application Support/Kiri Moby directory.

For every following update, after stopping the VM, run the same install
command using the newly downloaded app ZIP. It checks that the certificate
fingerprint has not changed and removes quarantine ONLY from the verified
staged Kiri app. No repeated Privacy & Security approval is needed with this
installer route; never disable global Gatekeeper.

**Directly dragging a fresh, quarantined DEV-PERSONAL-CERT DMG into
Applications may still trigger Gatekeeper.** A private self-signed cert is
not Apple notarization. This is why the authorized, certificate-pinning
installer is part of the personal-use workflow.

Inspect state with the installer --status option. If you intentionally rotate
the personal signing certificate, revoke the local pin and explicitly
reauthorize. Normal builds keep the same signer automatically.

The Docker data disk at ~/.kiri-moby is never modified by this installer.
The certificate-signed CI path cannot be fully verified until the owner
actually supplies the required private GitHub Secrets and a Mac verifies
a resulting build.


## Private CA-issued signing identities (Kiri Moby Code Signing)

If the existing P12 was issued by a custom intermediate CA, the P12 usually
contains the leaf key/certificate and intermediate CA, but NOT the original
self-signed **root CA public certificate**. On a new macOS GitHub runner,
codesign requires a complete path to the actual private root; merely trusting
the intermediate as root is not sufficient.

Configure a *fourth* GitHub Actions Secret named
`KIRI_PERSONAL_SIGN_CA_PEM_BASE64`. Its value is the Base64
encoding of the root CA's **PUBLIC X.509 certificate in PEM format**. This
certificate has no private keys; do NOT upload `root.key` or a
root CA P12. On the Mac where the original CA was created:

    ROOT_CRT="/absolute/path/to/your/root-ca.crt"
    openssl x509 -in "$ROOT_CRT" -noout -subject -issuer -text
    openssl x509 -in "$ROOT_CRT" -outform PEM |
      base64 | tr -d '\r\n' |
      gh secret set KIRI_PERSONAL_SIGN_CA_PEM_BASE64 -R w101723/kiri

The output of the first command should contain `CA:TRUE`;
the root's `subject` and `issuer` should be equal.
If the original certificate was not saved to a file but is installed in
macOS Keychain, export its **public certificate only** from Keychain Access.

The CI script extracts the intermediate(s) already contained in the P12,
cryptographically verifies the full chain to this public root, then
trusts that root for code signing **only on GitHub's disposable macOS
runner**. It never modifies trust settings on your own Mac, nor changes
your existing signing key or leaf certificate. Only the leaf certificate
SHA256 is pinned for stable version-to-version identity.

The full Kiri Moby build runs a quick real-P12 signing preflight before it
compiles the expensive Linux Guest kernel and macOS GUI. If the root
certificate is missing or mismatched, the workflow fails immediately with
an actionable error rather than recompiling all artifacts and failing late.
