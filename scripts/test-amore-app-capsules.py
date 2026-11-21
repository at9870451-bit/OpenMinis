#!/usr/bin/env python3
"""Source-level capsule contract checks; no iOS SDK, pairing or app launch.

Run: python3 scripts/test-amore-app-capsules.py
"""
from pathlib import Path
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'src/ios'
POKI = ROOT / 'vendor/poki/native/ios-app'


class CapsuleContract(unittest.TestCase):
    def read(self, relative):
        return (ROOT / relative).read_text()

    def test_original_catalog_and_capsule_logic_reused(self):
        known = self.read('vendor/poki/native/ios-app/Shared/KnownApps.swift')
        self.assertIn('KnownApp("com.meituan.imeituan", icon: "meituan"', known)
        self.assertIn('KnownApp("com.meituan.itakeaway", icon: "meituan-waimai"', known)
        self.assertIn('KnownApp("com.taobao.fleamarket", icon: "xianyu"', known)
        bridge = self.read('vendor/poki/native/ios-app/Poki/AmoreAppCapsules.swift')
        for part in ('AppIconStore.shared.icon', 'AppIconStore.shared.load',
                     'TaskApps.launches(inArguments:', 'PillView(data: data)',
                     'call["action"] as? String == "do"'):
            self.assertIn(part, bridge)
        self.assertNotIn('DefaultAppIcon', bridge)

    def test_assets_are_original_bit_for_bit(self):
        for name in ('meituan', 'meituan-waimai', 'xianyu'):
            source = POKI / f'Poki/AppIcons/{name}.png'
            asset = IOS / f'PokiPortAssets.xcassets/AmoreCarried-{name}.imageset'
            self.assertEqual((asset / f'{name}.png').read_bytes(), source.read_bytes())
            self.assertEqual(json.loads((asset / 'Contents.json').read_text())['images'][0]['filename'], f'{name}.png')

    def test_home_uses_actual_icon_not_implied_launch(self):
        panel = self.read('src/ios/Views/ContentView/Marquee/AmoreHomeMarqueePanel.swift')
        self.assertIn('AmoreShortcutAppIcon', panel)
        self.assertIn('onAction(item.action)', panel)
        self.assertNotIn('AmoreDeviceServices.execute', panel)

    def test_tool_card_reflects_live_execution_not_prompt(self):
        card = self.read('src/ios/Views/Chat/AmoreDeviceTaskCapsule.swift')
        self.assertIn('block.toolInputArgs', card)
        self.assertIn('block.toolStatus', card)
        self.assertIn('block.content', card)
        self.assertIn('AmoreCapsuleApps.requestedLaunches', card)
        self.assertNotIn('UserDefaults', card)
        self.assertNotIn('AmoreHomeShortcutCatalog.items', card)
        view = self.read('src/ios/Views/Chat/AssistantBlockView.swift')
        self.assertIn('AmoreDeviceTaskCapsule', view)

    def test_source_safety_barriers(self):
        call = self.read('src/ios/Views/ContentView/AmoreDeviceToolRequest.swift')
        self.assertIn('action=do requires arguments_json with an actions array', call)
        backend = self.read('src/ios/Views/ContentView/AmoreDeviceTools.swift')
        self.assertIn('AmoreDeviceServices.execute(', backend)
        self.assertIn('guard AmoreDeviceServices.isEnabled', backend)
        self.assertIn('MARKETING_VERSION = 1.41', self.read('src/ios/Minis.xcodeproj/project.pbxproj'))
        first = self.read('src/ios/Views/ContentView/Marquee/AmoreShortcutAppIcon.swift')
        self.assertIn('AmoreFastAppIcon', first)
        self.assertNotIn('AmoreInstalledAppIcon(', first)
        self.assertIn('TaskApps.launches(inArguments:', self.read('vendor/poki/native/ios-app/Poki/AmoreAppCapsules.swift'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
