#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${RUNNER_TEMP:-/tmp}/amore134-component-tests"
mkdir -p "$HOST/App" "$HOST/Tests"
for name in AmoreTheme PokiDrawerMotion AmoreDrawerPresentation PokiComposerMaterial PokiControlSurface DrawerShortcut; do cp "$ROOT/src/ios/Views/ContentView/$name.swift" "$HOST/App/"; done
for name in AmoreMarquee HomeShortcut AmoreHomeShortcutStore AmoreHomeMarqueePanel AmoreHomeShortcutCatalog AmoreHomeShortcutManager AmoreHomeMarqueeSource AmoreMarqueeClock; do cp "$ROOT/src/ios/Views/ContentView/Marquee/$name.swift" "$HOST/App/"; done
cp "$ROOT/src/ios/Views/ContentView/Sidebar/AmoreSidebarShortcuts.swift" "$HOST/App/"
cp "$ROOT/src/ios/Views/ContentView/Settings/SettingsFeatureIcon.swift" "$HOST/App/"
cp "$ROOT/vendor/poki/native/ios-app/Poki/AmoreConversationChrome.swift" "$HOST/App/"
cp "$ROOT/vendor/poki/native/ios-app/Poki/App/AmoreCompanion.swift" "$HOST/App/"
cp "$ROOT/vendor/poki/native/ios-app/Poki/App/Glass.swift" "$HOST/App/"
cp "$ROOT/src/ios/Views/Chat/AIChatView/AmoreHomeActionRouter.swift" "$HOST/App/"
cp "$ROOT/scripts/Amore134ComponentTests.swift" "$HOST/Tests/"
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
struct AppLocalization { static let current = "zh-Hans" }
enum AppBundle { static var current: Bundle { .main } }
extension View { func appFontScale() -> some View { self } }
struct ChatHistoryButtonStyle: ButtonStyle {
 func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.7 : 1) }
}
@main struct Amore134Components: App {
 var body: some Scene { WindowGroup { Text("Amore real component host") } }
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
schemes:
  Amore134Components:
    build:
      targets:
        Amore134Components: all
        Amore134Tests: [test]
    test:
      targets: [Amore134Tests]
EOF
command -v xcodegen >/dev/null || brew install xcodegen
(cd "$HOST" && xcodegen generate)
DEST="$(xcrun simctl list devices available --json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next(x["udid"] for a in d["devices"].values() for x in a if x.get("isAvailable") and "iPhone" in x["name"]))')"
xcodebuild test -project "$HOST/Amore134Components.xcodeproj" -scheme Amore134Components -destination "platform=iOS Simulator,id=$DEST" -derivedDataPath "$HOST/build" -resultBundlePath "$ROOT/amore134-components.xcresult" CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$ROOT/amore134-components.log"
xcrun xcresulttool export attachments --path "$ROOT/amore134-components.xcresult" --output-path "$ROOT/amore134-component-snapshots"
