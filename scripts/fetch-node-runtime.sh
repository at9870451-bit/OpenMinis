#!/bin/sh
# Regenerate the committed offline runtime on Linux with apk-tools installed.
# Downloads only; never changes the current machine's installed packages.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT="$ROOT/src/ios/NodeRuntime"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cache" "$OUT"
printf '%s\n%s\n' \
 https://dl-cdn.alpinelinux.org/alpine/v3.21/main \
 https://dl-cdn.alpinelinux.org/alpine/v3.21/community > "$WORK/repositories"
apk --arch aarch64 --repositories-file "$WORK/repositories" --cache-dir "$WORK/cache" update
apk --arch aarch64 --repositories-file "$WORK/repositories" --cache-dir "$WORK/cache" \
 fetch --recursive --output "$OUT" nodejs=22.23.5-r0 npm=10.9.1-r0
for package in "$OUT"/*.apk; do apk verify "$package"; done
# Do not silently refresh snapshots: manifest/index files must be regenerated
# and committed together, followed by verify-node-bundle.py and Linux CI.
python3 "$ROOT/scripts/verify-node-bundle.py"
