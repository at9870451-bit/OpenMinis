#!/usr/bin/env bash
# Run from the repository root: bash scripts/build-poki-original.sh
# Uses CI's selected Xcode/toolchain. Builds no Amore app, signs nothing, and
# never calls provisioning, Apple-account, pairing or runtime connection APIs.
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  printf '%s\n' 'Usage: bash scripts/build-poki-original.sh' \
    'Requires macOS, selected Xcode, XcodeGen, Rust/rustup, Python 3 and ripgrep.' \
    'Output: build-poki/Build/Products/Release-iphoneos/Poki.framework' \
    'Copies WebRTC.framework beside it when Poki links it dynamically.'
  exit 0
fi
[[ $# == 0 ]] || { echo 'Unexpected arguments; use --help.' >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
vendor="$root/vendor/poki"
app="$vendor/native/ios-app"
launcher="$vendor/native/launcher"
derived="$root/build-poki"
products="$derived/Build/Products/Release-iphoneos"
fail() { printf 'build-poki-original: %s\n' "$*" >&2; exit 1; }
[[ $(uname -s) == Darwin ]] || fail 'macOS/Xcode required; no iOS build was performed.'
for tool in xcodegen xcodebuild xcrun rustup cargo git python3 rg ditto; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing required tool: $tool"
done

# Keep the original workspace intact. In particular desktop/core inherits its
# workspace manifest, and Rust include_str! inputs live outside desktop/core.
for relative in \
  native/ios-app/project-amore.yml \
  native/ios-app/Poki/AmorePortEntry.swift \
  native/ios-app/Poki/Native/module.modulemap \
  native/ios-app/Poki/Native/InProcess.h \
  native/ios-app/Poki/Native/RecoveredNative.h \
  native/ios-app/Poki/Native/poki_launcher.h \
  native/ios-app/Poki/Native/InProcess.m \
  native/ios-app/Poki/Native/RecoveredNative.m \
  native/ios/PokiCore/Package.swift \
  native/ios-gym/check/GymScorecard.swift \
  native/launcher/Cargo.toml native/launcher/Cargo.lock \
  native/launcher/fetch-idevice.sh bin/setup \
  desktop/Cargo.toml desktop/core/Cargo.toml \
  desktop/cli/Cargo.toml desktop/bridge/Cargo.toml \
  desktop/app/src-tauri/Cargo.toml \
  desktop/AGENT-PROMPT.md desktop/core/certs/AppleRootCA.der \
  config/release-source.json deploy/cf-relay/worker.js; do
  [[ -f "$vendor/$relative" ]] || fail "Incomplete vendored workspace: $relative"
done
[[ -d "$app/Shared" && -d "$app/Poki/Assets.xcassets" ]] || fail 'Missing prepared shared sources/assets.'
# Never run make-assets.sh: it would overwrite the already replaced branding.

mkdir -p "$derived"
xcodebuild -version
export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
export IPHONEOS_DEPLOYMENT_TARGET=18.0
# Use the current Rust toolchain, not an unpinned upgrade or a global default
# change. Explicit target-dir must match project-amore.yml even on CI runners
# that export their own CARGO_TARGET_DIR.
bash "$launcher/fetch-idevice.sh"
rustup target add aarch64-apple-ios
cargo build --release --locked --target aarch64-apple-ios \
  --manifest-path "$launcher/Cargo.toml" --target-dir "$launcher/target" \
  2>&1 | tee "$derived/launcher-build.log"
[[ -s "$launcher/target/aarch64-apple-ios/release/libpoki_launcher.a" ]] \
  || fail 'Rust launcher static library was not produced.'

# The spec resides beside Poki/Shared, so its local package is ../ios/PokiCore.
# Its only build graph is Poki -> PokiNative + Swift packages; no app/appex.
(cd "$app" && xcodegen generate --spec project-amore.yml)
xcodebuild build \
  -project "$app/PokiOriginal.xcodeproj" -scheme Poki \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO IPHONEOS_DEPLOYMENT_TARGET=18.0 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  CODE_SIGN_ENTITLEMENTS= \
  2>&1 | tee "$derived/poki-build.log"
framework="$products/Poki.framework"
[[ -s "$framework/Poki" && -d "$framework/Modules/Poki.swiftmodule" ]] \
  || fail 'Poki.framework or its Swift module is missing.'
xcrun otool -hv "$framework/Poki" | rg -q DYLIB \
  || fail 'Poki must be a dynamic framework for Bundle.load.'
xcrun nm -gU "$framework/Poki" > "$derived/poki-exports.txt"
rg -q 'OBJC_CLASS_.*AmorePokiEntry' "$derived/poki-exports.txt" \
  || fail 'Exported Objective-C class AmorePokiEntry is missing.'
xcrun otool -L "$framework/Poki" > "$derived/poki-linked-libraries.txt"

# SPM may place the prebuilt WebRTC in its artifacts cache instead of Products.
# Embed it in the *host's* Frameworks directory, never nested in Poki.framework.
if rg -q 'WebRTC\.framework/' "$derived/poki-linked-libraries.txt"; then
  if [[ ! -s "$products/WebRTC.framework/WebRTC" ]]; then
    rg --files --hidden --no-ignore "$derived/SourcePackages" \
      -g Info.plist > "$derived/package-plists.txt" || true
    webrtc="$(python3 - "$derived/package-plists.txt" <<'PY'
import pathlib, plistlib, sys
for name in pathlib.Path(sys.argv[1]).read_text().splitlines():
    path = pathlib.Path(name)
    if path.parent.suffix != '.xcframework':
        continue
    with path.open('rb') as stream:
        info = plistlib.load(stream)
    for lib in info.get('AvailableLibraries', []):
        if (lib.get('SupportedPlatform') == 'ios'
                and not lib.get('SupportedPlatformVariant')
                and 'arm64' in lib.get('SupportedArchitectures', [])
                and lib.get('LibraryPath') == 'WebRTC.framework'):
            framework = path.parent / lib['LibraryIdentifier'] / lib['LibraryPath']
            if (framework / 'WebRTC').is_file():
                print(framework)
                sys.exit(0)
sys.exit('No arm64 iphoneos WebRTC.framework in resolved package artifacts')
PY
)"
    ditto "$webrtc" "$products/WebRTC.framework"
  fi
  [[ -s "$products/WebRTC.framework/WebRTC" ]] || fail 'Dynamic WebRTC dependency missing.'
  printf 'Host must also embed and sign: %s\n' "$products/WebRTC.framework"
fi
printf '\nBuilt unsigned, iOS18+ dynamically loaded module: %s\n' "$framework"
printf '%s\n' \
  'Host integration: embed/sign Poki.framework; do not strongly link the iOS16 host.' \
  'Load only on iOS18+, then call ObjC AmorePokiEntry.viewController:.' \
  'No tunnel/widget appex or VPN entitlement is built; use external connection.' \
  'A successful build/link is not a real-device pairing/connection/automation test.'
