#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
HOST=${AMORE140_GATE_HOST:-${RUNNER_TEMP:-/tmp}/amore140-gate}
mkdir -p "$HOST/Sources/Gate" "$HOST/Tests/GateTests"
cp "$ROOT/src/ios/Views/Chat/AIChatView/Support/ChatExecutionModePolicy.swift" "$HOST/Sources/Gate/"
cp "$ROOT/src/ios/Views/ContentView/AmorePhoneTaskPolicy.swift" "$HOST/Sources/Gate/"
python3 - "$ROOT/src/ios/MinisTests/ChatExecutionModePolicyTests.swift" "$ROOT/src/ios/MinisTests/AmorePhoneTaskPolicyTests.swift" "$HOST/Tests/GateTests" <<'PY'
from pathlib import Path
import sys
for name in sys.argv[1:3]:
 p=Path(name);s=p.read_text().replace('@testable import Minis','@testable import Gate')
 (Path(sys.argv[3])/p.name).write_text(s)
PY
cat > "$HOST/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Amore140Gate", platforms: [.macOS(.v13)], targets: [.target(name:"Gate"), .testTarget(name:"GateTests",dependencies:["Gate"])])
SWIFT
python3 "$ROOT/scripts/test-amore140-policy.py"
python3 "$ROOT/scripts/test-amore-app-capsules.py"
if [ "${AMORE140_PREPARE_ONLY:-0}" = 1 ]; then echo "PREPARED ONLY: $HOST";exit 0;fi
command -v swift >/dev/null || { echo 'Swift toolchain required to execute real mode tests' >&2;exit 1; }
swift test --package-path "$HOST" --disable-sandbox 2>&1 | tee "$HOST/swift-test.log"
