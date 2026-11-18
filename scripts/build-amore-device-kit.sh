#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/vendor/poki/native/ios-app"
LAUNCHER="$ROOT/vendor/poki/native/launcher"
DERIVED="$ROOT/build-device-kit"
PRODUCTS="$DERIVED/Build/Products/Release-iphoneos"
OUT="$ROOT/deps/AmoreDeviceKit"
for cmd in xcodegen xcodebuild xcrun rustup cargo rg python3; do command -v "$cmd" >/dev/null; done
export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
export IPHONEOS_DEPLOYMENT_TARGET=18.0
bash "$LAUNCHER/fetch-idevice.sh"
rustup target add aarch64-apple-ios
cargo build --release --locked --target aarch64-apple-ios --manifest-path "$LAUNCHER/Cargo.toml" --target-dir "$LAUNCHER/target" 2>&1 | tee device-rust.log
(cd "$APP" && xcodegen generate --spec project-fusion.yml)
xcodebuild build -project "$APP/AmoreDeviceServices.xcodeproj" -scheme AmoreDeviceKit -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= 2>&1 | tee device-swift.log
mkdir -p "$OUT/SwiftModules" "$OUT/Resources" "$OUT/ClangModules/PokiNative"
ditto "$PRODUCTS/AmoreDeviceKit.framework" "$OUT/AmoreDeviceKit.framework"
# Static Xcode frameworks do not automatically absorb every transitive product.
# Merge the original C/Rust and SwiftPM object products into one linkable archive.
python3 scripts/merge-device-static-products.py "$PRODUCTS" "$OUT" "$LAUNCHER/target/aarch64-apple-ios/release/libpoki_launcher.a"
for module in "$PRODUCTS"/*.swiftmodule; do [[ -e "$module" ]] && ditto "$module" "$OUT/SwiftModules/$(basename "$module")"; done
for bundle in "$PRODUCTS"/*.bundle; do [[ -d "$bundle" ]] && ditto "$bundle" "$OUT/Resources/$(basename "$bundle")"; done
for folder in "$PRODUCTS/AmoreDeviceKit.framework"/*.lproj; do [[ -d "$folder" ]] && ditto "$folder" "$OUT/Resources/$(basename "$folder")"; done
for file in "$PRODUCTS/AmoreDeviceKit.framework"/*.md; do [[ -f "$file" ]] && cp "$file" "$OUT/Resources/"; done
cp "$APP/Poki/Native/"*.h "$OUT/ClangModules/PokiNative/"
cp "$APP/Poki/Native/module.modulemap" "$OUT/ClangModules/PokiNative/"
# WebRTC is a third-party runtime dependency, not a second app or UI framework.
python3 - "$DERIVED" "$OUT" <<'PY'
import pathlib,plistlib,shutil,sys
root,out=map(pathlib.Path,sys.argv[1:])
for info in root.glob('SourcePackages/artifacts/**/WebRTC.xcframework/Info.plist'):
 data=plistlib.loads(info.read_bytes())
 for lib in data['AvailableLibraries']:
  if lib['SupportedPlatform']=='ios' and not lib.get('SupportedPlatformVariant') and 'arm64' in lib['SupportedArchitectures']:
   src=info.parent/lib['LibraryIdentifier']/lib['LibraryPath'];shutil.copytree(src,out/'WebRTC.framework',dirs_exist_ok=True,symlinks=True)
if not (out/'WebRTC.framework/WebRTC').is_file():
 p=root/'Build/Products/Release-iphoneos/WebRTC.framework'
 if p.is_dir():shutil.copytree(p,out/'WebRTC.framework',dirs_exist_ok=True,symlinks=True)
assert (out/'WebRTC.framework/WebRTC').is_file(),'WebRTC runtime missing'
PY
xcrun nm -gU "$OUT/AmoreDeviceKit.framework/AmoreDeviceKit" > device-defined-symbols.txt 2>device-nm-warnings.log || true
rg -q 'AmoreDeviceServices' "$OUT/static-swift-symbols.txt"
if rg -q 'OBJC_CLASS_.*AmorePokiEntry' device-defined-symbols.txt; then echo 'Old application factory must not exist' >&2; exit 1; fi
file "$OUT/AmoreDeviceKit.framework/AmoreDeviceKit"
printf '%s\n' 'Static AmoreDeviceKit built; not embedded as a dynamic framework.'
