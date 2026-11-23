#!/usr/bin/env python3
"""Drawer-footer source invariants only; NOT a Swift build, blur or tap test."""
from hashlib import sha256
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / "src/ios/Views/ContentView"
LAYOUT = (CONTENT / "ContentView+Layout.swift").read_text()
HELPER = (CONTENT / "AmoreDrawerFooterGlass.swift").read_text()


def declaration(text, name):
    assert text.count(name) == 1, name
    start = text.index(name)
    opening = text.index("{", start)
    depth = 0
    for token in re.finditer(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}]', text[opening:]):
        if token[0] == "{":
            depth += 1
        elif token[0] == "}":
            depth -= 1
            if depth == 0:
                return text[start:opening + token.end()]
    raise AssertionError("Unbalanced declaration: " + name)


FOOTER = declaration(LAYOUT, "private var drawerAccountFooter: some View")
CODE = re.sub(r"//[^\n]*", "", HELPER)


class DrawerFooterSourceTests(unittest.TestCase):
    def test_original_footer_unchanged_except_two_paint_sites(self):
        restored = FOOTER.replace(
            ".amoreDrawerFooterGlass(in: Capsule())", ".foregroundStyle(PokiTheme.sidebarInk)")
        restored = restored.replace(
            ".frame(width: 52, height: 52)\n                    .amoreDrawerFooterGlass(in: Circle())",
            ".foregroundStyle(PokiTheme.sidebarInk)\n                    .frame(width: 52, height: 52)")
        # Exact pre-change production member: actions/route/AX/layout cannot drift.
        self.assertEqual(sha256(restored.encode()).hexdigest(),
                         "3ec5a35bddbaa1e97edc9a7589e871ef489d02debaeddced9dd3322479aa3c59")

    def test_only_individual_buttons_receive_glass_not_the_bar(self):
        self.assertEqual(LAYOUT.count(".amoreDrawerFooterGlass("), 2)
        self.assertEqual(FOOTER.count(".amoreDrawerFooterGlass(in: Capsule())"), 1)
        self.assertEqual(FOOTER.count(".amoreDrawerFooterGlass(in: Circle())"), 1)
        self.assertTrue(FOOTER.endswith(".background(PokiTheme.sidebar)\n    }"))
        for forbidden in ["Divider(", "Rectangle(", "glassEffect(", ".overlay(",
                          "sidebarAction", "sidebarControl", "Color.blue", "Color.black"]:
            self.assertNotIn(forbidden, FOOTER)
        history = declaration(LAYOUT, "private var historyDrawer: some View")
        self.assertIn("drawerAccountFooter", history)
        scroll = declaration(history, "ScrollView {")
        self.assertNotIn("drawerAccountFooter", scroll)
        self.assertLess(history.index(scroll) + len(scroll), history.index("drawerAccountFooter"))
        self.assertIn(".background(PokiTheme.sidebar.ignoresSafeArea())", history)
        theme = (CONTENT / "AmoreTheme.swift").read_text()
        self.assertIn("static let uiSidebar = uiBackground", theme)
        self.assertIn("static let uiBackground = pair(0xF5F8FC, 0x05070D)", theme)

    def test_geometry_single_line_and_original_semantics(self):
        for required in [".frame(width: 132, height: 52)", ".frame(width: 52, height: 52)",
                         ".contentShape(Capsule())", ".contentShape(Circle())",
                         ".lineLimit(1)", ".minimumScaleFactor(0.75)", "Spacer(minLength: 8)",
                         ".padding(.horizontal, 12)", ".padding(.vertical, 10)",
                         ".disabled(drawerIsSliding)", "startHomeChat()",
                         "DeepLinkCoordinator.shared.pendingSettingsTarget = .home",
                         "activeToolSheet = .settings",
                         '.accessibilityLabel(AmoreSidebarText.newConversation)',
                         '.accessibilityLabel(AppLocalized("Settings"))',
                         '.accessibilityIdentifier("amore.sidebar.newConversation")',
                         '.accessibilityIdentifier("amore.sidebar.settings")']:
            self.assertIn(required, FOOTER)
        self.assertEqual(FOOTER.count("guard !drawerIsSliding else { return }"), 2)
        self.assertEqual(FOOTER.count("snapDrawer(open: false)"), 2)
        self.assertEqual(FOOTER.count(".buttonStyle(.plain)"), 2)

    def test_native_untinted_glass_and_material_availability(self):
        for required in ["#if compiler(>=6.2)", "#available(iOS 26.0, *)",
                         "Color.clear.glassEffect(.regular, in: shape).clipShape(shape)",
                         "shape.fill(.regularMaterial).clipShape(shape)"]:
            self.assertIn(required, CODE)
        for forbidden in [".tint(", ".opacity(", ".interactive(", "PokiTheme.sidebar", "Color.blue"]:
            self.assertNotIn(forbidden, CODE)
        policy = declaration(CODE, "static func surface(")
        self.assertIn("if reduceTransparency || increaseContrast { return .opaque }", policy)
        self.assertIn("return supportsLiquidGlass ? .glass : .material", policy)

    def test_system_accessibility_fallback_and_semantic_ink(self):
        for required in ["@Environment(\\.accessibilityReduceTransparency)",
                         "@Environment(\\.colorSchemeContrast)",
                         "increaseContrast: contrast == .increased",
                         "if surface == .opaque", "shape.fill(Color(uiColor: .secondarySystemBackground))",
                         ".foregroundStyle(Color(uiColor: .label))",
                         "shape.strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)"]:
            self.assertIn(required, CODE)

    def test_background_has_no_layout_hit_testing_or_extra_accessibility(self):
        for required in [".allowsHitTesting(false)", ".accessibilityHidden(true)",
                         ".background { AmoreDrawerFooterGlass(shape: shape) }"]:
            self.assertIn(required, CODE)
        for forbidden in [".frame(", ".padding(", "GeometryReader", ".gesture(", ".onTapGesture",
                          ".shadow(", ".buttonStyle(", "Button {", "onAppear", "@AppStorage",
                          ".preferredColorScheme(", ".environment(", ".allowsHitTesting(true)"]:
            self.assertNotIn(forbidden, CODE)


if __name__ == "__main__":
    print("Source-only checks: no iOS runtime, App compilation, native-blur screenshot or touch claim.")
    unittest.main(verbosity=2)
