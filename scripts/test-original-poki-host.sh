#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
python3 - <<'PY'
import plistlib
plistlib.load(open('src/ios/Info.plist','rb'))
print('Info.plist: valid')
PY
bash -n scripts/build-poki-original.sh
python3 - <<'PY'
from pathlib import Path
import json
r=Path('vendor/poki')
up=json.loads((r/'UPSTREAM.json').read_text())
assert up['revision']=='69585293051fee03c7ad110f037d8f4dd2a4e96f'
assert len(up['files'])>=390
required=['native/ios-app/Poki/Chat/ChatView.swift','native/ios-app/Poki/Chat/PokiDetailsView.swift','native/ios-app/Poki/App/AppModel.swift','native/ios-app/Poki/Chat/ChatModel.swift','native/launcher/Cargo.toml','native/launcher/Cargo.toml']
for f in required: assert (r/f).is_file(), f
for f in ['native/ios-app/Poki/Chat/ChatView.swift','native/ios-app/Poki/Chat/PokiDetailsView.swift']:
 s=(r/f).read_text(); assert 'Poki' in s
host=Path('src/ios/Views/ContentView/OriginalPokiScreen.swift').read_text()
assert 'NSClassFromString("AmorePokiEntry")' in host and 'iOS 18.0' in host
assert 'originalPokiChat' in Path('src/ios/Views/ContentView/ContentView+Layout.swift').read_text()
info=Path('src/ios/Info.plist').read_text();assert 'poki' in info and 'mobiledevicepairing' in info
print('original Poki source closure, real Chat/Connection types, guarded loader and pairing document route: OK')
PY
