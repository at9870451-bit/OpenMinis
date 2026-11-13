#!/bin/sh
set -eu
BASE=/opt/amore-localbot
ROOT=/opt/snowluma-qqbot
STATUS=/var/minis/workspace/amore-localbot-install.status
mkdir -p /var/minis/workspace "$ROOT"
log() { printf '%s\n' "$*" | tee -a "$STATUS"; }
: > "$STATUS"
[ "$(uname -m)" = aarch64 ] || { log "ERROR: expected aarch64, got $(uname -m)"; exit 2; }
[ -s "$BASE/qqbot-package/qqbot/run.py" ] || { log 'ERROR: bundled QQBot core is missing'; exit 3; }
[ -s "$BASE/protocol/go-cqhttp" ] || { log 'ERROR: bundled ARM64 protocol binary is missing'; exit 3; }
log 'Installing native Alpine ARM64 Python dependencies…'
apk update >> "$STATUS" 2>&1 || { log 'ERROR: apk update failed'; exit 4; }
apk add python3 py3-httpx py3-websockets py3-yaml py3-qrcode py3-pillow libstdc++ >> "$STATUS" 2>&1 || { log 'ERROR: Alpine dependency install failed'; exit 5; }
log 'Staging clean QQBot core under /opt/snowluma-qqbot…'
cp -R "$BASE/qqbot-package/qqbot/." "$ROOT/"
mkdir -p "$ROOT/protocol"
cp "$BASE/protocol/go-cqhttp" "$ROOT/protocol/go-cqhttp"
chmod 0755 "$ROOT/protocol/go-cqhttp"
cp "$BASE/protocol/config.yml" "$ROOT/protocol/config.yml"
mkdir -p "$ROOT/config" "$ROOT/data" "$ROOT/plugins_ext"
if [ ! -f "$ROOT/config/config.json" ]; then cp "$BASE/qqbot-package/qqbot/config/config.json" "$ROOT/config/config.json"; fi
cat > "$ROOT/start-protocol.sh" <<'SH2'
#!/bin/sh
set -eu
cd /opt/snowluma-qqbot/protocol
if grep -Eq '^[[:space:]]+uin:[[:space:]]*0' config.yml; then echo 'Set your QQ UIN in config.yml before login.'; exit 10; fi
exec ./go-cqhttp -c ./config.yml
SH2
cat > "$ROOT/start-bot.sh" <<'SH2'
#!/bin/sh
set -eu
cd /opt/snowluma-qqbot
export PYTHONPATH="$PWD"
exec python3 ./run.py --no-tray --no-webui
SH2
chmod 0755 "$ROOT/start-protocol.sh" "$ROOT/start-bot.sh"
log 'Local-only install complete: OneBot WS 127.0.0.1:3001, HTTP 127.0.0.1:5700.'
log 'AI, plugins and automatic replies are disabled; no service was started.'
log 'Enter your own QQ UIN in /opt/snowluma-qqbot/protocol/config.yml, then start protocol in the app to scan the QR.'
