#!/usr/bin/env python3
"""End-to-end check of the bridge on a Mac without an iPhone.

Starts poki-setup-bridge, talks to it over its pipe as the app does, and checks:
- it answers app_info and account;
- sign-in reaches Apple and Apple judges the credentials (a made-up Apple Account must get
  "wrong Apple Account or password" (or "locked", once Apple locks the made-up account), not -80045, which means Apple refused our identity data);
- phones answers (an empty list on CI, since no iPhone is attached);
- bad input gives a readable error, and the helper keeps running.
"""
import json, os, subprocess, sys, tempfile, time

bridge = sys.argv[1]
home = tempfile.mkdtemp(prefix="poki-e2e-")
env = dict(os.environ, HOME=home, POKI_SETUP_FILE_SECRETS="1", RUST_LOG="poki_setup_core=info")
p = subprocess.Popen([bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr, env=env, text=True, bufsize=1)

def read_until(pred, timeout=120):
    end = time.time() + timeout
    while time.time() < end:
        line = p.stdout.readline()
        if not line:
            raise SystemExit("bridge closed its output")
        msg = json.loads(line)
        if pred(msg):
            return msg
    raise SystemExit("timed out")

def call(i, cmd, args=None, timeout=120):
    p.stdin.write(json.dumps({"id": i, "cmd": cmd, "args": args or {}}) + "\n")
    p.stdin.flush()
    return read_until(lambda m: m.get("id") == i, timeout)

failures = []
def check(name, ok, detail):
    print(("PASS " if ok else "FAIL ") + name + ": " + json.dumps(detail)[:400])
    if not ok:
        failures.append(name)

read_until(lambda m: m.get("event") == "ready", 30)
r = call(1, "app_info")
check("app_info", "ok" in r and r["ok"]["os"] == "macos", r)
r = call(2, "account")
check("account (signed out)", "ok" in r and r["ok"]["signed_in"] is False, r)
for attempt in range(3):
    r = call(3 + attempt, "sign_in", {"apple_id": "poki.setup.ci.nobody@example.com", "password": "not-a-real-password-1A", "keep_password": False}, 180)
    msg = r.get("err", {}).get("message", "")
    if "cannot be completed" not in msg:
        break
check("sign-in reaches Apple, Apple judges the password", r.get("err", {}).get("kind") == "apple" and any(w in r["err"]["message"].lower() for w in ("wrong", "locked")), r)
r = call(10, "phones")
check("phones answers", "ok" in r or r.get("err", {}).get("kind") == "usbmuxd", r)
r = call(11, "connector_snippets", {"url": "not a link"})
check("bad input is a readable error", "err" in r and r["err"]["message"], r)
r = call(12, "ping")
check("helper still running", r.get("ok") == "pong", r)
p.stdin.close()
p.wait(10)
if failures:
    raise SystemExit("failed: " + ", ".join(failures))
print("all checks passed")
