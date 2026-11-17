#!/usr/bin/env bash
# Prepares the idevice checkout PokiLauncher builds against: the revision bin/setup pins, with
# native/patches/*.patch applied, in .deps/idevice-launcher. bin/setup's own .deps/idevice stays an
# unmodified checkout, so setup and `poki update` keep working next to it. Safe to run again.
#   native/launcher/fetch-idevice.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
revision="$(sed -n 's/^revision=//p' "$root/bin/setup")"
dir="$root/.deps/idevice-launcher"
patches=("$root"/native/patches/*.patch)
[ -n "$revision" ] || { echo "no idevice revision in bin/setup" >&2; exit 1; }

if [ -e "$dir" ]; then
  if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$revision" ]; then
    echo "$dir is not idevice $revision; it was left unchanged. Remove it and run this again." >&2
    exit 1
  fi
  for patch in "${patches[@]}"; do
    git -C "$dir" apply --reverse --check "$patch" 2>/dev/null || {
      echo "$dir does not match native/patches; it was left unchanged. Remove it and run this again." >&2
      exit 1
    }
  done
  echo "idevice for PokiLauncher is ready in $dir"
  exit 0
fi

mkdir -p "$root/.deps"
git init -q "$dir"
git -C "$dir" fetch -q --depth 1 https://github.com/jkcoxson/idevice.git "$revision"
git -C "$dir" checkout -q --detach FETCH_HEAD
for patch in "${patches[@]}"; do git -C "$dir" apply "$patch"; done
echo "idevice $revision with Poki's patches is ready in $dir"
