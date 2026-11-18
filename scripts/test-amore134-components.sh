#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${AMORE134_HOST:-${RUNNER_TEMP:-/tmp}/amore134-component-tests}"
mkdir -p "$HOST/App" "$HOST/Tests" "$HOST/UITests"
for name in AmoreTheme PokiDrawerMotion AmoreDrawerPresentation PokiComposerMaterial PokiControlSurface DrawerShortcut PokiMessageSurface; do cp "$ROOT/src/ios/Views/ContentView/$name.swift" "$HOST/App/"; done
for name in AmoreMarquee HomeShortcut AmoreHomeShortcutStore AmoreHomeMarqueePanel AmoreHomeShortcutCatalog AmoreHomeShortcutManager AmoreHomeMarqueeSource AmoreMarqueeClock; do cp "$ROOT/src/ios/Views/ContentView/Marquee/$name.swift" "$HOST/App/"; done
cp "$ROOT/src/ios/Views/ContentView/Sidebar/AmoreSidebarShortcuts.swift" "$HOST/App/"
cp "$ROOT/src/ios/Views/ContentView/Settings/SettingsFeatureIcon.swift" "$HOST/App/"
cp "$ROOT/vendor/poki/native/ios-app/Poki/AmoreConversationChrome.swift" "$HOST/App/"
cp "$ROOT/vendor/poki/native/ios-app/Poki/App/AmoreCompanion.swift" "$HOST/App/"
cp "$ROOT/vendor/poki/native/ios-app/Poki/App/AmoreAnimatedPortrait.swift" "$HOST/App/"
cp "$ROOT/vendor/poki/native/ios-app/Poki/AmoreAvatarPreview.swift" "$HOST/App/"
cp "$ROOT/vendor/poki/native/ios-app/Poki/App/Glass.swift" "$HOST/App/"
cp "$ROOT/src/ios/Views/Chat/AIChatView/Support/ChatColors.swift" "$HOST/App/"
cp "$ROOT/src/ios/Views/ContentView/AmoreAvatarDraftRouter.swift" "$HOST/App/"
cp "$ROOT/src/ios/Views/Chat/AIChatView/AmoreHomeActionRouter.swift" "$HOST/App/"
cp "$ROOT/scripts/Amore134ComponentTests.swift" "$HOST/Tests/"
cp "$ROOT/scripts/Amore135CompanionTests.swift" "$HOST/Tests/"
for name in AmoreMarqueeReasoningTests Amore135GlassSidebarTests; do
python3 - "$ROOT/scripts/$name.swift" "$HOST/Tests/$name.swift" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[2]).write_text(Path(sys.argv[1]).read_text().replace('@testable import PokiComponents', '@testable import Amore134Components'))
PY
done
cp "$ROOT/scripts/Amore134NavigationUITests.swift" "$HOST/UITests/"
cp "$ROOT/scripts/Amore135HeaderUITests.swift" "$HOST/UITests/"
cp "$ROOT/scripts/Amore135HeaderProbe.swift" "$HOST/App/"
# Complete production UIKit menu and drawer members, never a handwritten fake.
# Its DEBUG dependencies and all closures target inert test-host state only.
python3 "$ROOT/scripts/extract-amore135-header-host.py" "$ROOT" "$HOST"
# Extract, never recreate, the production route and NavigationLink component.
# Only the destination payload is overlaid: real device services cannot run here.
python3 - "$ROOT" "$HOST" <<'PY'
import hashlib, json, pathlib, re, sys
root, host = map(pathlib.Path, sys.argv[1:])
base = root / 'vendor/poki/native/ios-app/Poki'
records = []

def extract(relative, declaration):
    path = base / relative
    text = path.read_text()
    assert text.count(declaration) == 1, f'Expected exactly one {declaration} in {path}'
    start = text.index(declaration)
    opening = text.index('{', start)
    depth = 0
    # Tokenize comments/strings before counting braces; fail closed on source drift.
    tokens = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}]')
    end = None
    for token in tokens.finditer(text, opening):
        if token.group() == '{': depth += 1
        elif token.group() == '}':
            depth -= 1
            if depth == 0:
                end = token.end()
                break
    assert end is not None, f'Unbalanced declaration: {declaration}'
    source = text[start:end]
    records.append(dict(path=str(path.relative_to(root)),
                        startLine=text.count('\n', 0, start) + 1,
                        declaration=declaration,
                        sha256=hashlib.sha256(source.encode()).hexdigest()))
    return source

step = extract('App/SetupState.swift', 'enum SetupStep: String, CaseIterable, Identifiable')
link = extract('Setup/SetupView.swift', 'struct SetupStepLink<Content: View>: View')
modifier = extract('AmoreDeviceIntegration.swift', '@MainActor\n    func amoreDeviceSetupDestinations() -> some View')
assert 'NavigationLink(value: step)' in link
assert '.accessibilityIdentifier("setup.step.\\(step.rawValue)")' in link
assert 'navigationDestination(for: SetupStep.self) { step in' in modifier
payload = '''SetupStepPage(step: step)
                .environment(AmoreDeviceServices.model)
                .settingsPage()'''
assert modifier.count(payload) == 1, 'Production destination changed: review test overlay'
patched = modifier.replace(payload, 'Amore134SetupStepDestinationProbe(step: step)')
assert patched.replace('Amore134SetupStepDestinationProbe(step: step)', payload) == modifier
raw_cases = re.search(r'^    case ([A-Za-z, ]+)$', step, re.M)
assert raw_cases, 'SetupStep cases changed: review runtime expectation'
cases = [s.strip() for s in raw_cases.group(1).split(',')]
assert cases == ['runner', 'developerMode', 'loopback', 'pairing', 'automation', 'background']
settings = (root / 'src/ios/Views/Settings/SettingsSheet.swift').read_text()
assert '.amoreDeviceSetupDestinations()' in settings, 'Production Settings lost its parent registration'
(host / 'App/ExtractedSetupNavigation.swift').write_text(
    '// Generated from production at test build time. Do not hand-edit.\n'
    'import SwiftUI\nimport Foundation\n\n' + step + '\n\n' + link +
    '\n\n// TEST OVERLAY: original modifier, device page payload replaced only.\n'
    'public extension View {\n' + patched + '\n}\n')
manifest = dict(extractions=records, rawValues=cases,
                overlay='Only SetupStepPage/environment/settingsPage replaced by an explicitly labelled navigation probe',
                scope='Same-type link and parent NavigationStack only; not ConnectionView services or real DDI/permissions')
(host / 'navigation-source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
PY
cat > "$HOST/App/NavigationProbe.swift" <<'EOF'
import SwiftUI

// Test-only dependency stub. It does not redefine or alter SetupStep/rawValue.
// It selects the in-process shown/wording branch; the probe deliberately uses allCases.
enum AutomationPath {
    case inProcess, runner
    static var current: AutomationPath { .inProcess }
}

struct Amore134NavigationProbe: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            // Register on the eager parent, never on a List row or pushed page.
            VStack(spacing: 0) {
                Text("Same-type link / parent-stack probe; no real device permissions")
                    .font(.caption)
                    .accessibilityIdentifier("amore134.navigation.root")
                List {
                    ForEach(SetupStep.allCases) { step in
                        SetupStepLink(step: step) {
                            Label(step.title, systemImage: step.symbol)
                        }
                    }
                }
            }
            .navigationTitle("Connection Probe")
            .navigationBarTitleDisplayMode(.inline)
            .amoreDeviceSetupDestinations()
        }
        .safeAreaInset(edge: .bottom) {
            Text("Parent stack depth: \(path.count)")
                .accessibilityIdentifier("amore134.navigation.pathDepth")
        }
    }
}

struct Amore134SetupStepDestinationProbe: View {
    let step: SetupStep
    var body: some View {
        VStack(spacing: 16) {
            Text("navigation probe for SetupStep \(step.rawValue)")
                .accessibilityIdentifier("amore134.navigation.destination.\(step.rawValue)")
            Text(step.rawValue)
                .accessibilityIdentifier("amore134.navigation.rawValue")
            Text("TEST PLACEHOLDER — not a real DDI or device-permission page")
        }
        .navigationTitle("SetupStep Probe")
        .navigationBarTitleDisplayMode(.inline)
        // Intentionally retain the native NavigationStack Back button.
    }
}
EOF
cat > "$HOST/App/TestHost.swift" <<'EOF'
import SwiftUI
import UIKit
func AppLocalized(_ key: StaticString) -> String { key.description }
func AppLocalized(_ key: String) -> String { key }
enum ChatColor { static let fieldEdge = Color(uiColor: .systemGray4) }
enum RuntimePage: String { case tools, subAgents, skills, memory, rootfs, localBot, soul }
enum SettingsDeepLinkTarget: Equatable { case providers, modelGroups, usage, developerConnection, appearance, mcpIntegrations, environments, storage, sharedFolders, mountedFolders, permissions, logs, background, about }
enum BiometricAuth {
 static var isAvailable: Bool { true }
 static var biometryDisplayName: String { "Face ID" }
 static var biometryIconName: String { "faceid" }
}
struct AppLocalization {
 static var current: String {
  ProcessInfo.processInfo.arguments.contains("-amore135-header-probe") ||
   ProcessInfo.processInfo.arguments.contains("-amore135-drawer-probe") ? "en" : "zh-Hans"
 }
}
enum AppBundle { static var current: Bundle { .main } }
extension View { func appFontScale() -> some View { self } }
struct ChatHistoryButtonStyle: ButtonStyle {
 func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.7 : 1) }
}
@main struct Amore134Components: App {
 var body: some Scene {
  WindowGroup {
   if ProcessInfo.processInfo.arguments.contains("-amore135-header-probe") {
    Amore135HeaderProbe()
   } else if ProcessInfo.processInfo.arguments.contains("-amore135-drawer-probe") {
    Amore135DrawerProbe()
   } else if ProcessInfo.processInfo.arguments.contains("-amore134-navigation-probe") {
    Amore134NavigationProbe()
   } else {
    Text("Amore real component host")
     .accessibilityIdentifier("amore134.defaultHost")
   }
  }
 }
}
EOF
cat > "$HOST/project.yml" <<'EOF'
name: Amore134Components
options:
  deploymentTarget:
    iOS: '18.0'
settings:
  base:
    SWIFT_VERSION: '5.0'
    CODE_SIGNING_ALLOWED: NO
targets:
  Amore134Components:
    type: application
    platform: iOS
    sources: [App]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.amore.components134
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
  Amore134Tests:
    type: bundle.unit-test
    platform: iOS
    sources: [Tests]
    dependencies:
      - target: Amore134Components
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.amore.components134.tests
        GENERATE_INFOPLIST_FILE: YES
  Amore134NavigationUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: [UITests]
    dependencies:
      - target: Amore134Components
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.amore.components134.navigationuitests
        GENERATE_INFOPLIST_FILE: YES
        TEST_TARGET_NAME: Amore134Components
schemes:
  Amore134Components:
    build:
      targets:
        Amore134Components: all
        Amore134Tests: [test]
        Amore134NavigationUITests: [test]
    test:
      targets: [Amore134Tests, Amore134NavigationUITests]
EOF
# Source-only generation is a portability check, NEVER a substitute for UI taps.
if [[ "${AMORE134_PREPARE_ONLY:-0}" == "1" ]]; then
  echo "PREPARED ONLY: $HOST (no build or runtime UI test executed)"
  exit 0
fi
command -v xcrun >/dev/null || { echo 'ERROR: Xcode + an iOS Simulator are required for runtime tests.' >&2; exit 1; }
command -v xcodegen >/dev/null || brew install xcodegen
(cd "$HOST" && xcodegen generate)
DEST="${AMORE134_SIMULATOR_ID:-$(xcrun simctl list devices available --json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next(x["udid"] for a in d["devices"].values() for x in a if x.get("isAvailable") and "iPhone" in x["name"]))')}"
RESULT="${AMORE134_RESULT_BUNDLE:-$ROOT/amore134-components.xcresult}"
LOG="${AMORE134_TEST_LOG:-$ROOT/amore134-components.log}"
SNAPSHOTS="${AMORE134_SNAPSHOTS:-$ROOT/amore134-component-snapshots}"
# Do not destroy previous evidence or allow xcodebuild to merge an old result.
[[ ! -e "$RESULT" ]] || { echo "ERROR: $RESULT exists; set AMORE134_RESULT_BUNDLE to a fresh path." >&2; exit 1; }
xcrun simctl boot "$DEST" 2>/dev/null || true
xcrun simctl bootstatus "$DEST" -b
TEST_FILTERS=()
if [[ -n "${AMORE_TEST_ONLY:-}" ]]; then
  while IFS= read -r selected; do
    [[ -z "$selected" ]] || TEST_FILTERS+=("-only-testing:$selected")
  done <<< "$AMORE_TEST_ONLY"
fi
set +e
xcodebuild test -project "$HOST/Amore134Components.xcodeproj" -scheme Amore134Components -destination "platform=iOS Simulator,id=$DEST" -parallel-testing-enabled NO -derivedDataPath "$HOST/build" -resultBundlePath "$RESULT" "${TEST_FILTERS[@]}" CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e
if [[ -d "$RESULT" ]]; then
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$SNAPSHOTS" || true
fi
exit "$STATUS"
