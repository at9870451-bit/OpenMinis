#!/bin/sh
# Install the official signed Alpine Node/npm closure bundled with Amore.
# Must be explicitly launched by the user. This script NEVER downloads files.
set -eu
SRC=$(CDPATH= cd -- "${1:-.}" && pwd)
NODE_VERSION=22.23.5-r0
NPM_VERSION=10.9.1-r0
LOCK=/var/lock/amore-node-runtime
mkdir -p /var/lock
if ! mkdir "$LOCK" 2>/dev/null; then
    previous=$(cat "$LOCK/pid" 2>/dev/null || true)
    case "$previous" in
        ''|*[!0-9]*) echo 'Node install lock exists but its owner cannot be identified. Inspect /var/lock/amore-node-runtime in the terminal.' >&2; exit 20 ;;
        *)
            if kill -0 "$previous" 2>/dev/null; then
                echo 'Another offline Node installation is running.' >&2; exit 20
            fi
            rm -rf "$LOCK"
            mkdir "$LOCK" || exit 20 ;;
    esac
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
fail() { echo "$2" >&2; exit "$1"; }
[ "$(apk --print-arch)" = aarch64 ] || fail 21 'This bundle requires Alpine aarch64, not x86 or x86_64.'
release=$(cat /etc/alpine-release)
case "$release" in 3.21|3.21.*) ;; *) fail 22 "This bundle requires Alpine 3.21; installed rootfs is $release. No packages were changed." ;; esac
cd "$SRC"
sha256sum -c SHA256SUMS || fail 23 'Bundled runtime checksum failed; reinstall the App.'
# The user-selected rootfs already contains the Alpine public trust keys.
# Never use --allow-untrusted or trust a key delivered by the input package.
for package in ./*.apk; do
    apk verify "$package" || fail 24 "Alpine signature verification failed: $package"
done
WORK=$(mktemp -d /var/cache/amore-node.XXXXXX)
cleanup() { rm -rf "$WORK" "$LOCK"; }
trap cleanup EXIT
mkdir -p "$WORK/main/aarch64" "$WORK/community/aarch64"
ln -s "$SRC/main.APKINDEX.tar.gz" "$WORK/main/aarch64/APKINDEX.tar.gz"
ln -s "$SRC/community.APKINDEX.tar.gz" "$WORK/community/aarch64/APKINDEX.tar.gz"
for repository in main community; do
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        case "$package" in *[!a-zA-Z0-9.+_-]*|.*) fail 25 'Unsafe bundled package name.' ;; esac
        ln -s "$SRC/$package" "$WORK/$repository/aarch64/$package"
    done < "$SRC/$repository.packages"
done
printf '%s\n%s\n' "$WORK/main" "$WORK/community" > "$WORK/repositories"
# Only nodejs and npm are world targets. Dependencies are selected by apk from
# the original Alpine-signed indexes; already satisfied core libraries remain.
if ! apk add --simulate --no-network --no-cache --repositories-file "$WORK/repositories" --wait 30 \
    "nodejs=$NODE_VERSION" "npm=$NPM_VERSION" > "$WORK/plan" 2>&1; then
    cat "$WORK/plan" >&2
    fail 26 'The offline dependency plan could not be resolved. Nothing was installed.'
fi
cat "$WORK/plan"
# Do not silently downgrade, remove, purge or replace an existing core runtime.
# Installing a missing dependency or a necessary forward update is allowed by
# the confirmation dialog; unsupported changes require a separate repair.
while IFS= read -r line; do
    case "$line" in
        *') Downgrading '*|*') Purging '*|*') Removing '*|*') Replacing '*)
            fail 27 'The offline plan would downgrade or remove existing packages; installation stopped.' ;;
    esac
done < "$WORK/plan"
apk add --no-network --no-cache --repositories-file "$WORK/repositories" --wait 30 \
    "nodejs=$NODE_VERSION" "npm=$NPM_VERSION" || fail 28 'Offline apk installation failed. Read the package-manager output above.'
node --version || fail 29 'Node was installed but cannot start.'
npm --version || fail 29 'npm was installed but cannot start.'
npx --version || fail 29 'npx was installed but cannot start.'
node "$SRC/smoke-test.js" || fail 29 'Node runtime checks failed.'
# Avoid pinning future apk upgrades to this bundle's snapshot. Preserve every
# other world entry; only release the two constraints introduced above.
while IFS= read -r entry; do
    case "$entry" in
        "nodejs=$NODE_VERSION") printf '%s\n' nodejs ;;
        "npm=$NPM_VERSION") printf '%s\n' npm ;;
        *) printf '%s\n' "$entry" ;;
    esac
done < /etc/apk/world > "$WORK/world.after"
cp "$WORK/world.after" /etc/apk/world || fail 30 'Installed, but could not update apk world constraints.'
echo 'AMORE_NODE_OFFLINE_READY'
