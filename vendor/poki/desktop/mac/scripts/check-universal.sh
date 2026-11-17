#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <PokiSetup.dmg>" >&2
  exit 2
fi

MOUNT="$(mktemp -d)"
trap 'hdiutil detach "$MOUNT" -quiet; rmdir "$MOUNT"' EXIT
hdiutil attach "$1" -readonly -nobrowse -mountpoint "$MOUNT" -quiet

MACOS="$MOUNT/Poki Setup.app/Contents/MacOS"
for B in PokiSetup poki-setup poki-setup-bridge; do
  if [ ! -f "$MACOS/$B" ] || [[ "$(file -b "$MACOS/$B")" != *Mach-O* ]]; then
    echo "FAIL: missing Mach-O executable: $B" >&2
    exit 1
  fi
done

FAILED=0
COUNT=0
while IFS= read -r -d '' B; do
  if [[ "$(file -b "$B")" != *Mach-O* ]]; then continue; fi
  COUNT=$((COUNT + 1))
  ARCHS="$(lipo -archs "$B")"
  echo "${B#"$MOUNT/"}: $ARCHS"
  if [[ " $ARCHS " != *" arm64 "* || " $ARCHS " != *" x86_64 "* ]]; then
    echo "FAIL: ${B#"$MOUNT/"} must contain arm64 and x86_64" >&2
    FAILED=1
  fi
done < <(find "$MOUNT" -type f -print0)

if [ "$FAILED" -ne 0 ]; then exit 1; fi
echo "PASS: all $COUNT Mach-O files contain arm64 and x86_64"
