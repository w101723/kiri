# Kiri Moby: macOS Gatekeeper / signed distribution

## Root cause

The original Actions build uses `codesign --sign -`, an **ad-hoc signature**.
Ad-hoc signing helps local executable integrity, but does not establish an
Apple-trusted developer identity. Downloaded builds are quarantined and macOS
Gatekeeper may require a fresh Security → Open Anyway approval per version.

The durable fix is to sign **every new release with the same Developer ID
Application identity**, enable Hardened Runtime, submit the signed distribution
to Apple's notarization service, and staple its ticket. A consistent bundle
identifier (`dev.kiri.app.moby`) is already present. No global disabling
of Gatekeeper, and no automated removal of quarantine.

Apple documentation:
- https://developer.apple.com/developer-id/
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- https://developer.apple.com/documentation/security/customizing-the-notarization-workflow

## One-time GitHub configuration (six encrypted repository secrets)

In the GitHub repository, open **Settings → Secrets and variables → Actions**.
You need an Apple Developer Program team with a Developer ID Application
certificate exported **with its private key** to an encrypted `.p12`, and
an App Store Connect API key with notarization access (`.p8` plus Key ID
and Issuer ID).

| GitHub Actions secret | Contents |
| --- | --- |
| `MACOS_DEVELOPER_ID_P12_BASE64` | Complete Developer ID Application `.p12` as one-line base64 |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | Password used when exporting the `.p12` |
| `MACOS_DEVELOPER_ID_IDENTITY` | Full identity, e.g. `Developer ID Application: Company (TEAMID)` |
| `APPLE_NOTARY_KEY_BASE64` | Complete App Store Connect API `.p8` as one-line base64 |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API Key ID |
| `APPLE_NOTARY_ISSUER_ID` | API issuer UUID |

On your Mac, derive base64 values (paste these **only** into GitHub Secrets,
never an issue, chat, Git commit or build log):

```bash
base64 < DeveloperID.p12 | tr -d '\\n'
base64 < AuthKey_XXXXXXXXXX.p8 | tr -d '\\n'
security find-identity -v -p codesigning
```

## Release

Actions → **Kiri Moby unified macOS ARM64 milestone bundle** →
**Run workflow** on `memory-reclaim`. If all six secrets are present,
the workflow re-signs the macOS ARM64 GUI, Kiri Host (with Apple VZ
entitlement), official Docker CLI/Compose/Buildx and outer .app using
`--options runtime --timestamp`, notarizes the distribution DMG using
`xcrun notarytool`, requires an `Accepted` response, and staples/validates
the DMG. It then uploads **`Kiri-Moby-macos-arm64-DeveloperID-notarized`**.

The existing **`Kiri-Moby-macos-arm64-app`** artifact remains an
**ad-hoc development-only** tarball. It is explicitly labeled as such.
Without signing secrets, that artifact still builds but **no notarized DMG
is published**. If only some signing secrets exist, the step fails rather
than silently claiming that an ad-hoc app is a release.

For stable updates, use the **notarized DMG**: download its GitHub artifact
ZIP, open the DMG, and replace `Kiri Moby.app` in `/Applications` after
stopping the Kiri VM. Keep the same Developer ID team between releases.
This does not delete or migrate your `~/.kiri-moby/vm/data.img`.

Verify on a real Apple Silicon Mac:

```bash
codesign -dv --verbose=4 "/Applications/Kiri Moby.app" 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|flags'
codesign --verify --deep --strict --verbose=2 "/Applications/Kiri Moby.app"
spctl --assess --type execute --verbose=4 "/Applications/Kiri Moby.app"
xcrun stapler validate "/path/to/Kiri-Moby-macos-arm64-notarized.dmg"
```

Even a properly notarized app can still request ordinary first-launch,
access/permission or security confirmations; a revoked certificate would
also be rejected. No automatic bypass is attempted.

**Verification boundary:** The CI fallback (without Apple secrets) can
be tested automatically, but the real signing/notarization workflow
cannot be validated until valid Apple Developer credentials are configured.
