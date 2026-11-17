# Poki Setup for Mac

The native macOS app: a SwiftUI shell (`Sources/PokiSetup`) over the Rust core, which runs as the
bundled `poki-setup-bridge` helper (JSON lines over a pipe). Build on a Mac with Xcode and Rust:

    desktop/mac/scripts/bundle.sh universal "$PWD/dist"

The default build is universal. It includes arm64 and x86_64 in the app, bridge, and command line
tool. Use `native` only for local development on the build Mac.

CI (`.github/workflows/desktop-mac.yml`) builds it, checks the core against Apple, re-signs a real
Poki IPA and verifies it with Apple's codesign, and saves screenshots of every page. Before CI
uploads an installer, it mounts the DMG and checks that every Mach-O file contains both architectures:

    desktop/mac/scripts/check-universal.sh dist/*.dmg

## Developer ID signing and notarization

Without secrets the app is signed ad hoc, and macOS asks people to right-click > Open the first time.
With these repository secrets (Settings > Secrets and variables > Actions), CI signs it with
Developer ID, notarizes the DMG with `notarytool`, staples the ticket and checks it with `spctl`:

| Secret | What |
| --- | --- |
| `MACOS_CERT_P12` | A "Developer ID Application" certificate and its private key, exported from Keychain Access as .p12, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | The password chosen when exporting the .p12 |
| `NOTARY_KEY_ID` | App Store Connect API key ID (Users and Access > Integrations > Team Keys, role Developer) |
| `NOTARY_ISSUER_ID` | The Issuer ID shown above that key list |
| `NOTARY_KEY_P8` | The contents of the downloaded AuthKey_XXXX.p8 file |

Instead of the API key, notarization also takes `NOTARY_APPLE_ID`, `NOTARY_APP_PASSWORD` (an
app-specific password from account.apple.com) and `APPLE_TEAM_ID`.

Only the Account Holder of a paid Apple Developer Program team can create a Developer ID
Application certificate (developer.apple.com > Certificates > +). Enterprise certificates cannot
be notarized.
