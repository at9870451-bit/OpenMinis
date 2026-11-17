#!/bin/bash
# Signs a Poki IPA with a throwaway identity (no Apple Account) and has Apple's own codesign
# check the result: signature valid on disk, ids rewritten, entitlements present.
#   sign-check.sh <poki-setup CLI> <Poki-external-unsigned.ipa> [Poki-signing.zip]
set -euo pipefail
CLI="$1"; IPA="$2"; ZIP="${3:-}"
WORK="$(mktemp -d)"
export HOME="$WORK/home"; mkdir -p "$HOME"
"$CLI" selftest-sign --ipa "$IPA" ${ZIP:+--signing-zip "$ZIP"} --out "$WORK/signed.ipa"
cd "$WORK" && unzip -q signed.ipa -d out
APP="$(ls -d out/Payload/*.app | head -1)"
fail=0
step() { echo "== $1"; }
step "codesign --verify (app and extensions)"
codesign --verify --deep --strict --verbose=4 "$APP" || fail=1
for ext in "$APP"/PlugIns/*.appex; do
  [ -e "$ext" ] || continue
  codesign --verify --strict --verbose=2 "$ext" || fail=1
done
step "signature details"
codesign -dvvv "$APP" 2>&1 | grep -E "Identifier=|TeamIdentifier=|Authority=|Format=|CodeDirectory" || fail=1
step "bundle ids"
ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"; echo "app: $ID"
[ "$ID" = "nz.zheha.poki.SELFTEST01" ] || { echo "unexpected app id"; fail=1; }
GROUP="$(/usr/libexec/PlistBuddy -c 'Print :PokiAppGroup' "$APP/Info.plist" 2>/dev/null || true)"; echo "PokiAppGroup: $GROUP"
for ext in "$APP"/PlugIns/*.appex; do
  [ -e "$ext" ] || continue
  echo "$(basename "$ext"): $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ext/Info.plist")"
done
step "entitlements"
ENTS="$(codesign -d --entitlements :- "$APP" 2>&1 || true)"
echo "$ENTS" | sed -n '/<plist/,/<\/plist>/p'
echo "$ENTS" | grep -q "SELFTEST01.nz.zheha.poki.SELFTEST01" || { echo "application-identifier missing"; fail=1; }
echo "$ENTS" | grep -q "group.nz.zheha.poki.SELFTEST01" || { echo "app group missing"; fail=1; }
step "no packet tunnel extension"
if ls "$APP"/PlugIns/ 2>/dev/null | grep -qi tunnel; then echo "tunnel extension still present"; fail=1; else echo "none"; fi
[ "$fail" = 0 ] && echo "SIGNING CHECK PASSED" || { echo "SIGNING CHECK FAILED"; exit 1; }
