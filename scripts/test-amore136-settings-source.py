#!/usr/bin/env python3
"""Source/colour invariants only; NOT an iOS build, native blur or tap test."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = ROOT / "src/ios/Views/Settings"
CONTENT = ROOT / "src/ios/Views/ContentView"
sheet = (SETTINGS / "SettingsSheet.swift").read_text()
helper = (CONTENT / "Settings/AmoreSettingsGlassStyle.swift").read_text()
icon = (CONTENT / "Settings/SettingsFeatureIcon.swift").read_text()
appearance = (SETTINGS / "AppearanceSettingsView.swift").read_text()
sidebar = (CONTENT / "Sidebar/AmoreSidebarShortcuts.swift").read_text()

# The original IDs remain decodable, but retired footer entries cannot be
# selected or routed. No unrelated Settings target is removed.
enum_cases = sidebar.split("enum AmoreSidebarShortcut:", 1)[1].split("enum Destination", 1)[0]
ids = re.findall(r"^    case (.+)$", enum_cases, re.M)
assert len([x.strip() for row in ids for x in row.split(",")]) == 30
assert "case .privacyPolicy, .feedback: return false" in sidebar
assert ".filter { $0 != .privacyPolicy && $0 != .feedback }" in sidebar
assert 'return AmoreSidebarShortcut(rawValue: id)' in sidebar
for retired in ['showPrivacyPolicy', 'showFeedbackDialog', 'SettingsPrivacyBrowser',
                'makeFeedbackEmailURL', 'makeBugReportURL', '"privacy-policy"', '"feedback"']:
    assert retired not in sheet, retired
for existing in ['ProviderInstancesView()', 'ModelGroupsView()', 'UsageStatsView()',
                 'ToolsSettingsView()', 'HelperSettingsView()', 'SkillsManagementView()',
                 'SoulSettingsView()', 'RootfsManagementView()', 'ISHTerminalView()',
                 'AmoreMarketplaceView()', 'MemoryManagementView()',
                 'ContextCompressionSettingsView()', 'MCPIntegrationsView()',
                 'EnvironmentVariablesView()', 'StorageManagementView()',
                 'SharedFoldersSettingsView()', 'MountedFoldersSettingsView()',
                 'CloudSyncSettingsV2View()', 'BackupAndRestoreView()',
                 'OffloadPermissionSettingsView()', 'FaceIDProtectionSettingsView()',
                 'LogManagementView(', 'AboutView()', 'HomeShortcutsSettingsView()',
                 'DeveloperConnectionView()']:
    assert existing in sheet, existing
assert '.amoreDeviceSetupDestinations()' in sheet
assert '.navigationDestination(for: SettingsDestination.self)' in sheet
assert sheet.index('.amoreDeviceSetupDestinations()') < sheet.index('.navigationDestination(for: SettingsDestination.self)')

# Theme source is unchanged; only row paint is modernised.
assert 'static let storageKey = "amore.appearance"' in (CONTENT / 'AmoreAppearance.swift').read_text()
for removed in ['AppIconOption', 'iconOptions', 'setAlternateIconName', 'supportsAlternateIcons', 'Text("App Icon")']:
    assert removed not in appearance, removed
assert (ROOT / 'src/ios/Assets.xcassets/AppIcon.appiconset/Contents.json').exists()
assert (ROOT / 'src/ios/Info.plist').exists()
for required in ['.scrollContentBackground(.hidden)', 'AmoreChatBackdrop(home: true)',
                 '.regularMaterial', '#if compiler(>=6.2)', '#available(iOS 26.0, *)',
                 '.glassEffect(.regular, in: shape)', '.allowsHitTesting(false)',
                 'accessibilityReduceTransparency', 'increaseContrast']:
    assert required in helper, required
# Exclude comments: references explaining prohibited changes are not calls.
code = re.sub(r'//[^\n]*', '', helper)
for forbidden in ['.padding(', '.frame(', 'GeometryReader', '.shadow(', '.gesture(',
                  '.onTapGesture', '.interactive(', '@AppStorage', '.preferredColorScheme', '.id(']:
    assert forbidden not in code, forbidden
for name in ['AppearanceSettingsView', 'OffloadPermissionSettingsView',
             'EnhancedBackgroundSettingsView', 'ToolsSettingsView', 'HelperSettingsView',
             'HomeShortcutsSettingsView', 'SoulSettingsView', 'MemoryManagementView',
             'EnvironmentVariablesView', 'FaceIDProtectionSettingsView', 'AboutView',
             'LogManagementView', 'StorageManagementView', 'SharedFoldersSettingsView',
             'MountedFoldersSettingsView', 'ConfigAuditView', 'ConfigAuditDetailView']:
    source = (SETTINGS / (name + '.swift')).read_text()
    assert '.amoreSettingsGlass()' in source, name
    assert '.amoreSettingsGlassRows()' in source, name

# Contrast calculations run on the actual production hex values.
def luminance(n):
    c = [((n >> x) & 255) / 255 for x in (16, 8, 0)]
    c = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in c]
    return sum(x * y for x, y in zip(c, [.2126, .7152, .0722]))

for field, background in [('lightHex', 0xFFFFFF), ('darkHex', 0x1C1F27)]:
    values = re.findall(r'case \.(\w+): (0x[0-9A-F]+)', icon.split('var ' + field, 1)[1].split('\n    }', 1)[0])
    assert [name for name, value in values] == ['red', 'orange', 'yellow', 'green', 'cyan', 'blue', 'purple']
    ratios = []
    for name, value in values:
        a, b = luminance(int(value, 16)), luminance(background)
        ratio = (max(a, b) + .05) / (min(a, b) + .05)
        assert ratio >= 4.5, (name, field, ratio)
        ratios.append(round(ratio, 2))
    print(field, 'AA ink ratios', ratios)

print('PASS: settings source/routing/palette invariants (not a Swift build or UI test)')
