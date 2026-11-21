from pathlib import Path
import unittest
r=Path(__file__).resolve().parents[1]
class FirstFrame(unittest.TestCase):
 def test_phone_icons_no_sync_uikit_or_network_in_first_frame(self):
  fast=(r/'src/ios/Views/ContentView/Marquee/AmoreFastAppIcon.swift').read_text()
  pane=(r/'src/ios/Views/ContentView/Marquee/AmoreShortcutAppIcon.swift').read_text()
  task=(r/'src/ios/Views/Chat/AmoreDeviceTaskCapsule.swift').read_text()
  for s in (fast,pane,task):
   for forbidden in ('AppIconStore.shared.icon(','.load(app)', 'AmoreInstalledAppIcon(', 'SystemIcons.icon(', 'pngData()', 'UIImage(contentsOfFile:', 'URLSession'):
    self.assertNotIn(forbidden,s)
  self.assertIn('AmoreFastAppIcon(appName: item.appName',pane)
  self.assertIn('AmoreFastAppIcon(appName: id',task)
  for name in ['meituan','meituan-waimai','xianyu']:
   self.assertTrue((r/f'src/ios/PokiPortAssets.xcassets/AmoreCarried-{name}.imageset/{name}.png').is_file())
 def test_native_core_and_mode_unchanged(self):
  s=(r/'src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift').read_text()
  self.assertIn('AmoreDeviceTools.run(',s)
  self.assertIn('AmorePureChatMode.isEnabled(',s)
if __name__=='__main__':unittest.main()
