#!/bin/bash
# Run ONLY in an isolated Linux CI worker, never against the user's rootfs.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$REPO/src/ios/NodeRuntime"
WORK="${RUNNER_TEMP:?}/amore-node-offline-test"
ROOT="$WORK/root"
mkdir -p "$ROOT"
python3 "$REPO/scripts/verify-node-bundle.py"
ARCHIVE=alpine-minirootfs-3.21.0-aarch64.tar.gz
URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/$ARCHIVE"
curl -fSL --retry 3 --connect-timeout 20 "$URL" -o "$WORK/$ARCHIVE"
curl -fSL --retry 3 --connect-timeout 20 "$URL.sha256" -o "$WORK/rootfs.sha256"
(cd "$WORK" && sha256sum -c rootfs.sha256)
sudo tar -xzf "$WORK/$ARCHIVE" -C "$ROOT"
sudo mkdir -p "$ROOT/opt/amore-node" "$ROOT/dev" "$ROOT/proc"
sudo cp -a "$BUNDLE/." "$ROOT/opt/amore-node/"
sudo cp /usr/bin/qemu-aarch64-static "$ROOT/usr/bin/"
sudo mount --bind /dev "$ROOT/dev"
sudo mount -t proc none "$ROOT/proc"
cleanup() { sudo umount "$ROOT/proc" || true; sudo umount "$ROOT/dev" || true; }
trap cleanup EXIT
# The install has its own --no-network, and the entire guest is additionally
# in an empty network namespace. Prove no runtime package is already present.
sudo unshare --net chroot "$ROOT" /bin/sh -c '
 set -eu
 test ! -e /usr/bin/node
 test ! -e /usr/bin/npm
 sh /opt/amore-node/install.sh /opt/amore-node
 node --version; npm --version; npx --version
 node /opt/amore-node/smoke-test.js
 NODE_OPTIONS=--jitless node /opt/amore-node/smoke-test.js
 mkdir -p /tmp/amore-npm-test/pkg /tmp/amore-npm-test/user
 printf "{\"name\":\"amore-local-echo\",\"version\":\"1.0.0\",\"bin\":{\"amore-echo\":\"cli.js\"}}" > /tmp/amore-npm-test/pkg/package.json
 printf "#!/usr/bin/env node\nconsole.log(\"AMORE_OFFLINE_NPM_OK\");\n" > /tmp/amore-npm-test/pkg/cli.js
 chmod +x /tmp/amore-npm-test/pkg/cli.js
 cd /tmp/amore-npm-test/user
 npm install --offline --ignore-scripts --no-audit --no-fund ../pkg
 ./node_modules/.bin/amore-echo
 # Reinstall is safe and remains completely offline.
 sh /opt/amore-node/install.sh /opt/amore-node
 # Package corruption must fail before apk changes anything.
 cp /lib/apk/db/installed /tmp/before-corrupt-test
 first=$(ls /opt/amore-node/*.apk | head -1)
 printf "corrupt" >> "$first"
 if sh /opt/amore-node/install.sh /opt/amore-node; then echo "CORRUPTION WAS ACCEPTED"; exit 1; fi
 cmp /lib/apk/db/installed /tmp/before-corrupt-test
 echo "AMORE_OFFLINE_NODE_LINUX_TESTS_PASSED"
' 2>&1 | tee "$REPO/node-runtime-linux-tests.log"
