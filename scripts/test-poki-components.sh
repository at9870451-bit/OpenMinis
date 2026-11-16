#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${RUNNER_TEMP:-/tmp}/amore-poki-component-tests"
mkdir -p "$HOST/App" "$HOST/Tests"
cp "$ROOT/src/ios/Views/ContentView/AmoreTheme.swift" "$HOST/App/"
cp "$ROOT/src/ios/Views/ContentView/PokiDrawerMotion.swift" "$HOST/App/"
cp "$ROOT/src/ios/Views/ContentView/PluginImportPicker.swift" "$HOST/App/"
cp "$ROOT/src/ios/Views/ContentView/DrawerShortcut.swift" "$HOST/App/"
cp "$ROOT/scripts/PokiComponentTests.swift" "$HOST/Tests/"
cat > "$HOST/App/HostApp.swift" <<'EOF'
import SwiftUI
import UIKit
func AppLocalized(_ key: StaticString) -> String { key.description }
@main struct PokiComponentsApp: App {
    var body: some Scene {
        WindowGroup { Text("Isolated component test host").background(PokiTheme.background) }
    }
}
EOF
cat > "$HOST/project.yml" <<'EOF'
name: PokiComponents
options:
  deploymentTarget:
    iOS: "16.0"
settings:
  base:
    SWIFT_VERSION: "5.0"
    CODE_SIGNING_ALLOWED: NO
targets:
  PokiComponents:
    type: application
    platform: iOS
    sources: [App]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.amore.poki-component-tests
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
  PokiComponentTests:
    type: bundle.unit-test
    platform: iOS
    sources: [Tests]
    dependencies:
      - target: PokiComponents
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.amore.poki-component-tests.unit
        GENERATE_INFOPLIST_FILE: YES
schemes:
  PokiComponents:
    build:
      targets:
        PokiComponents: all
        PokiComponentTests: [test]
    test:
      targets: [PokiComponentTests]
EOF
which xcodegen >/dev/null || brew install xcodegen
(cd "$HOST" && xcodegen generate)
DEST=$(xcrun simctl list devices available --json | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next(x["udid"] for a in d["devices"].values() for x in a if x.get("isAvailable") and "iPhone" in x["name"]))')
xcodebuild test -project "$HOST/PokiComponents.xcodeproj" -scheme PokiComponents \
  -destination "platform=iOS Simulator,id=$DEST" -derivedDataPath "$HOST/build" \
  -resultBundlePath "$ROOT/poki-components.xcresult" CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$ROOT/poki-component-tests.log"
xcrun xcresulttool export attachments --path "$ROOT/poki-components.xcresult" \
  --output-path "$ROOT/poki-component-snapshots"
