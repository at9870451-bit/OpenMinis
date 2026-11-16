#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$RUNNER_TEMP/amore-plugin-install-tests"
rm -rf "$HARNESS"
mkdir -p "$HARNESS/Sources/InstallerUnderTest" "$HARNESS/Tests/InstallerTests"
cp "$REPO_ROOT/src/ios/Views/ContentView/Plugins/PluginManifest.swift" "$HARNESS/Sources/InstallerUnderTest/"
cp "$REPO_ROOT/src/ios/Views/ContentView/Plugins/PluginInstaller.swift" "$HARNESS/Sources/InstallerUnderTest/"
cp "$REPO_ROOT/src/ios/Views/ContentView/Plugins/PluginJSRuntime.swift" "$HARNESS/Sources/InstallerUnderTest/"
cp "$REPO_ROOT/src/ios/Packages/AmorePluginArchive/Tests/AmorePluginArchiveTests/Fixtures/valid-deflated.zip" "$HARNESS/Tests/InstallerTests/echo.zip"
cp "$REPO_ROOT/src/ios/Packages/AmorePluginArchive/Tests/AmorePluginArchiveTests/Fixtures/renamed-config.zip" "$HARNESS/Tests/InstallerTests/renamed-config.zip"
cp "$REPO_ROOT/scripts/plugin-install-tests.swift" "$HARNESS/Tests/InstallerTests/InstallerTests.swift"
python3 - "$HARNESS" "$REPO_ROOT" <<'PY'
import pathlib,json,sys
h=pathlib.Path(sys.argv[1]);r=pathlib.Path(sys.argv[2])
(h/'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "InstallerUnderTest", platforms: [.macOS(.v13)], dependencies: [
 .package(path: '''+json.dumps(str(r/'src/ios/Packages/AmorePluginArchive'))+''')], targets: [
 .target(name: "InstallerUnderTest", dependencies: ["AmorePluginArchive"]),
 .testTarget(name: "InstallerTests", dependencies: ["InstallerUnderTest", "AmorePluginArchive"], resources: [.copy("echo.zip"), .copy("renamed-config.zip")])])
''')
(h/'Sources/InstallerUnderTest/Localization.swift').write_text('''import Foundation
func AppLocalized(_ value: StaticString) -> String { value.description }
''')
PY
swift test --package-path "$HARNESS" 2>&1 | tee "$REPO_ROOT/plugin-install-tests.log"
