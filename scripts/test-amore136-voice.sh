#!/bin/bash
# Isolated real-manager unit host. No providers, bridge, microphone or network.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ARTIFACTS="${AMORE136_ARTIFACTS:-$ROOT/workspace/amore136-voice-$RUN_ID}"
HOST="${AMORE136_HOST:-$ARTIFACTS/host}"
command -v python3 >/dev/null || { echo 'ERROR: python3 is required.' >&2; exit 1; }
# Refuse source/artifact overlap and reused source directories. Never rm -rf.
python3 - "$ROOT" "$HOST" "$ARTIFACTS" <<'PY'
from pathlib import Path
import sys
root, host, artifacts = [Path(p).expanduser().resolve() for p in sys.argv[1:]]
for path in (host, artifacts):
    for protected in (root / 'src', root / 'scripts', root / 'vendor', root / 'deps'):
        if path == protected or path in protected.parents or protected in path.parents:
            raise SystemExit(f'ERROR: unsafe output path: {path}')
for child in ('App', 'Tests', 'AmoreVoice136.xcodeproj', 'build'):
    if (host / child).exists():
        raise SystemExit(f'ERROR: use a fresh AMORE136_HOST; {host / child} exists')
host.mkdir(parents=True, exist_ok=True)
artifacts.mkdir(parents=True, exist_ok=True)
PY
HOST="$(cd "$HOST" && pwd)"
ARTIFACTS="$(cd "$ARTIFACTS" && pwd)"
mkdir -p "$HOST/App" "$HOST/Tests"
for name in VoiceCallContracts VoiceCallServiceContracts VoiceStateMachine VoiceSessionManager VoiceCallWAV; do
  cp "$ROOT/src/ios/Views/ContentView/VoiceCall/$name.swift" "$HOST/App/"
done
cp "$ROOT/src/ios/Providers/Voice/VoiceTextSanitizer.swift" "$HOST/App/"
python3 - "$ROOT/scripts/Amore136VoiceTests.swift" "$HOST/Tests/Amore136VoiceTests.swift" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
old = '@testable import Amore134Components'
assert text.count(old) == 1, 'Test module import changed: review host mapping'
Path(sys.argv[2]).write_text(text.replace(old, '@testable import AmoreVoice136'))
PY
cat > "$HOST/App/TestHost.swift" <<'SWIFT'
import SwiftUI

// Only missing app-level dependencies. Never fake VoiceSessionManager or its state.
func AppLocalized(_ key: String) -> String { key }
@MainActor
final class VoiceOutputState {
    static let shared = VoiceOutputState()
    private init() {}
    // connect() stops global read-aloud; no global speech service in this host.
    func stop() {}
}

@main
@MainActor
struct AmoreVoice136App: App {
    var body: some Scene {
        WindowGroup {
            Text("Amore 1.36 real manager / injected boundary unit tests")
        }
    }
}
SWIFT
cat > "$HOST/project.yml" <<'YAML'
name: AmoreVoice136
options:
  deploymentTarget:
    iOS: '18.0'
settings:
  base:
    SWIFT_VERSION: '5.0'
    SWIFT_STRICT_CONCURRENCY: minimal
    SWIFT_TREAT_WARNINGS_AS_ERRORS: NO
    SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated
    CODE_SIGNING_ALLOWED: NO
targets:
  AmoreVoice136:
    type: application
    platform: iOS
    sources: [App]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.amore.voice136
        PRODUCT_MODULE_NAME: AmoreVoice136
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        TARGETED_DEVICE_FAMILY: '1,2'
  Amore136VoiceTests:
    type: bundle.unit-test
    platform: iOS
    sources: [Tests]
    dependencies:
      - target: AmoreVoice136
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.amore.voice136.tests
        GENERATE_INFOPLIST_FILE: YES
schemes:
  AmoreVoice136:
    build:
      targets:
        AmoreVoice136: all
        Amore136VoiceTests: [test]
    test:
      gatherCoverageData: false
      targets: [Amore136VoiceTests]
YAML
# Audit the exact bytes copied; no code extraction, manager patch or replacement.
python3 - "$ROOT" "$HOST" "$ARTIFACTS/source-manifest.json" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, host, out = map(Path, sys.argv[1:])
voice = Path('src/ios/Views/ContentView/VoiceCall')
sources = [voice / (n + '.swift') for n in (
    'VoiceCallContracts', 'VoiceCallServiceContracts', 'VoiceStateMachine',
    'VoiceSessionManager', 'VoiceCallWAV')]
sources += [Path('src/ios/Providers/Voice/VoiceTextSanitizer.swift')]
records = []
for relative in sources:
    original, copied = root / relative, host / 'App' / relative.name
    assert original.read_bytes() == copied.read_bytes(), f'Copy mismatch: {relative}'
    records.append({'source': str(relative), 'copy': str(copied),
                    'sha256': hashlib.sha256(copied.read_bytes()).hexdigest()})
assert sorted(p.name for p in (host / 'App').glob('*.swift')) == sorted(
    [p.name for p in sources] + ['TestHost.swift'])
test = (host / 'Tests/Amore136VoiceTests.swift').read_text()
assert '@testable import AmoreVoice136' in test
assert '@testable import Amore134Components' not in test
assert 'bundle.ui-testing' not in (host / 'project.yml').read_text()
manifest = {'mode': 'unit-tests; no real permission, microphone, provider or network',
            'productionCopies': records,
            'hostOnlyStubs': ['AppLocalized(String)', 'VoiceOutputState.shared.stop()'],
            'excluded': ['VoiceCallServices.swift', 'VoiceCallConversationBridge.swift',
                         'VoiceCallView.swift', 'VoiceCallAudioIO.swift'],
            'testCount': test.count('    func test')}
out.write_text(json.dumps(manifest, indent=2) + '\n')
print(f"SOURCE COPY AUDIT OK: {len(records)} byte-identical files; {manifest['testCount']} tests")
PY
printf 'Host: %s\nArtifacts: %s\n' "$HOST" "$ARTIFACTS"
if [[ "${AMORE136_PREPARE_ONLY:-0}" == "1" ]]; then
  echo 'PREPARED ONLY: source/path audit passed; no Xcode project generation, build or XCTest executed.'
  exit 0
fi
[[ "$(uname -s)" == "Darwin" ]] || { echo 'ERROR: runtime tests require macOS + Xcode. Use AMORE136_PREPARE_ONLY=1 for source audit only.' >&2; exit 1; }
for tool in xcrun xcodebuild xcodegen; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required; install Xcode/XcodeGen separately (this script does not install or download dependencies)." >&2; exit 1; }
done
(cd "$HOST" && xcodegen generate) 2>&1 | tee "$ARTIFACTS/xcodegen.log"
xcodebuild -version > "$ARTIFACTS/xcode-version.txt"
xcrun simctl list devices available --json > "$ARTIFACTS/simulators.json"
# Accept only an available iOS 18+ iPhone simulator, even for an explicit ID.
DEST="$(python3 - "$ARTIFACTS/simulators.json" "${AMORE136_SIMULATOR_ID:-}" <<'PY'
import json, re, sys
from pathlib import Path
devices = json.loads(Path(sys.argv[1]).read_text())['devices']
candidates = []
for runtime, entries in devices.items():
    version = re.search(r'\.iOS-(\d+)-', runtime)
    if not version or int(version[1]) < 18:
        continue
    candidates += [d for d in entries if d.get('isAvailable') and 'iPhone' in d['name']]
if sys.argv[2]:
    candidates = [d for d in candidates if d['udid'] == sys.argv[2]]
if not candidates:
    raise SystemExit('ERROR: no matching available iOS 18+ iPhone simulator; set AMORE136_SIMULATOR_ID to a valid UDID.')
candidates.sort(key=lambda d: d.get('state') != 'Booted')
print(candidates[0]['udid'])
PY
)"
RESULT="$ARTIFACTS/amore136-voice.xcresult"
LOG="$ARTIFACTS/xcodebuild-test.log"
ATTACHMENTS="$ARTIFACTS/attachments"
[[ ! -e "$RESULT" && ! -e "$LOG" && ! -e "$ATTACHMENTS" ]] || { echo 'ERROR: evidence already exists; use a fresh AMORE136_ARTIFACTS.' >&2; exit 1; }
xcrun simctl boot "$DEST" 2>/dev/null || true
xcrun simctl bootstatus "$DEST" -b
# Start with a nonempty array: macOS Bash 3.2 + nounset rejects empty arrays.
BUILD_ARGS=(test -project "$HOST/AmoreVoice136.xcodeproj" -scheme AmoreVoice136
  -destination "platform=iOS Simulator,id=$DEST" -destination-timeout 120
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
  -disableAutomaticPackageResolution -derivedDataPath "$HOST/build"
  -resultBundlePath "$RESULT" CODE_SIGNING_ALLOWED=NO)
if [[ -n "${AMORE136_TEST_ONLY:-}" ]]; then
  while IFS= read -r selected; do
    [[ -z "$selected" ]] || BUILD_ARGS+=("-only-testing:$selected")
  done <<< "$AMORE136_TEST_ONLY"
fi
# No UI-test target, services, permissions, package resolution or paid API calls.
set +e
xcodebuild "${BUILD_ARGS[@]}" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e
printf '%s\n' "$STATUS" > "$ARTIFACTS/xcodebuild-exit-code.txt"
if [[ -d "$RESULT" ]]; then
  if ! xcrun xcresulttool export attachments --path "$RESULT" --output-path "$ATTACHMENTS" \
      > "$ARTIFACTS/attachments-export.log" 2>&1; then
    echo "WARNING: attachment export failed; inspect $ARTIFACTS/attachments-export.log. Original xcresult retained." >&2
  fi
fi
printf 'xcodebuild exit: %s\nLog: %s\nResult bundle: %s\nAttachments (if any): %s\n' "$STATUS" "$LOG" "$RESULT" "$ATTACHMENTS"
exit "$STATUS"
