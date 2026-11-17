#!/bin/bash
# Builds Poki Setup.app and its DMG on a Mac: the SwiftUI shell plus the Rust bridge.
#   desktop/mac/scripts/bundle.sh [universal|native] [out-dir]
# Needs Xcode (swift) and Rust. Signs ad hoc unless MAC_SIGN_IDENTITY is set.
set -euo pipefail
MODE="${1:-universal}"
OUT="${2:-$(pwd)/dist}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP="$(cd "$HERE/.." && pwd)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$DESKTOP/Cargo.toml" | head -1)"
BUILD="${BUILD_NUMBER:-$(git -C "$DESKTOP" rev-list --count HEAD 2>/dev/null || echo 1)}"
mkdir -p "$OUT"
export POKI_SETUP_BUILD="$BUILD"

echo "== Rust bridge and command line tool ($MODE)"
# poki-setup (the command line tool for agents and scripts) ships inside the app next to the bridge.
if [ "$MODE" = universal ]; then
  rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
  for T in aarch64-apple-darwin x86_64-apple-darwin; do
    (cd "$DESKTOP" && cargo build --release -p poki-setup-bridge -p poki-setup-cli --target "$T")
  done
  for B in poki-setup-bridge poki-setup; do
    lipo -create -output "$OUT/$B" "$DESKTOP/target/aarch64-apple-darwin/release/$B" "$DESKTOP/target/x86_64-apple-darwin/release/$B"
  done
  SWIFT_ARCHS=(--arch arm64 --arch x86_64)
else
  (cd "$DESKTOP" && cargo build --release -p poki-setup-bridge -p poki-setup-cli)
  cp "$DESKTOP/target/release/poki-setup-bridge" "$OUT/poki-setup-bridge"
  cp "$DESKTOP/target/release/poki-setup" "$OUT/poki-setup"
  SWIFT_ARCHS=()
fi

echo "== SwiftUI app"
(cd "$HERE" && swift build -c release ${SWIFT_ARCHS[@]+"${SWIFT_ARCHS[@]}"})
BIN="$(cd "$HERE" && swift build -c release ${SWIFT_ARCHS[@]+"${SWIFT_ARCHS[@]}"} --show-bin-path)/PokiSetup"

APP="$OUT/Poki Setup.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PokiSetup"
cp "$OUT/poki-setup-bridge" "$APP/Contents/MacOS/poki-setup-bridge"
cp "$OUT/poki-setup" "$APP/Contents/MacOS/poki-setup"
cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$HERE/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "== Sign"
IDENTITY="${MAC_SIGN_IDENTITY:--}"
# A Developer ID signature needs a secure timestamp for notarization; an ad hoc one cannot have it.
if [ "$IDENTITY" = "-" ]; then TS=--timestamp=none; else TS=--timestamp; fi
KC=()
if [ -n "${MAC_SIGN_KEYCHAIN:-}" ]; then KC=(--keychain "$MAC_SIGN_KEYCHAIN"); fi
codesign --force --options runtime "$TS" ${KC[@]+"${KC[@]}"} -s "$IDENTITY" "$APP/Contents/MacOS/poki-setup-bridge"
# Same code identity as the bridge, so the command line tool opens the keychain items the app made
# (the Apple session, the kept password) without a keychain prompt.
codesign --force --options runtime "$TS" ${KC[@]+"${KC[@]}"} -s "$IDENTITY" --identifier poki-setup-bridge "$APP/Contents/MacOS/poki-setup"
codesign --force --options runtime "$TS" ${KC[@]+"${KC[@]}"} -s "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "== DMG"
DMG="$OUT/PokiSetup-$VERSION-macos.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Poki Setup" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp ${KC[@]+"${KC[@]}"} -s "$IDENTITY" "$DMG"
fi
echo "$DMG"
