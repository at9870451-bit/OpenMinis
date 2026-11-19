#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${AMORE138_DEVICE_HOST:-${RUNNER_TEMP:-/tmp}/amore138-device-execution}"
mkdir -p "$HOST"
python3 - "$ROOT" "$HOST" <<'PY'
from pathlib import Path
import sys,re,hashlib,json
r,h=map(Path,sys.argv[1:]);p=r/'vendor/poki/native/ios-app/Poki';s=(p/'App/AppModel.swift').read_text();records=[]
def extract(marker):
 assert s.count(marker)==1,marker
 start=s.index(marker);opening=s.index('{',start);depth=0
 for token in re.finditer(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}]',s[opening:]):
  if token[0]=='{':depth+=1
  elif token[0]=='}':
   depth-=1
   if depth==0:
    value=s[start:opening+token.end()];records.append({'declaration':marker,'sha256':hashlib.sha256(value.encode()).hexdigest()});return value
 raise AssertionError('Unbalanced member '+marker)
members=[extract('    func runTool('),extract('    func wakeRunner('),extract('    private func closeBecausePokiOpened()')]
# Only visibility is changed for the test's external harness caller; method body
# is the exact production member. The actual compiler later builds AppModel.
members[-1]=members[-1].replace('private func','func',1)
fixture=(r/'scripts/Amore138DeviceExecutionTests.swift').read_text();assert fixture.count('// APPMODEL_MEMBERS')==1
(h/'Main.swift').write_text(fixture.replace('// APPMODEL_MEMBERS','\n'.join(members)))
for name in ['AmoreDeviceExecution.swift','AmoreDeviceStatus.swift']:(h/name).write_bytes((p/name).read_bytes())
(h/'source-manifest.json').write_text(json.dumps({'productionMembers':records,'scope':'Exact AppModel bodies with fake OS/core/launcher and visibility-only overlay; not actual device acceptance'},indent=2))
print('Prepared exact production member fixtures:',len(records))
PY
if [[ "${AMORE138_DEVICE_PREPARE_ONLY:-0}" == "1" ]]; then
 echo "Prepared only; no Swift build or device action executed"
 exit 0
fi
command -v swiftc >/dev/null
swiftc -parse-as-library -swift-version 5 "$HOST/Main.swift" "$HOST/AmoreDeviceExecution.swift" "$HOST/AmoreDeviceStatus.swift" -o "$HOST/device-regressions"
"$HOST/device-regressions" 2>&1 | tee "${AMORE138_DEVICE_TEST_LOG:-$ROOT/amore138-device-execution.log}"
