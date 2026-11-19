from pathlib import Path
import unittest, hashlib
R=Path(__file__).resolve().parents[1]
C=R/'src/ios/Views/ContentView'
class TransparentDrawerSourceTests(unittest.TestCase):
 def test_all_ancestor_full_blue_fills_are_removed(self):
  s=(C/'ContentView+Layout.swift').read_text()
  self.assertNotIn('.background(PokiTheme.sidebar',s)
  self.assertNotIn('PokiTheme.sidebar.ignoresSafeArea()',s)
  self.assertIn('AmoreTransparentDrawer(',s)
  self.assertNotIn('PokiDrawerConversationPanel(',s)
 def test_one_chat_branch_no_snapshot_no_new_vm(self):
  s=(C/'AmoreTransparentDrawer.swift').read_text()
  self.assertEqual(s.count('            chat\n'),1)
  self.assertNotIn('UIImage',s);self.assertNotIn('AIChatView(',s)
  self.assertNotIn('.snapshot',s);self.assertNotIn('.id(',s)
  self.assertNotIn('.scaleEffect',s)
  self.assertNotIn('drawerWidth * phase,',s.split('            chat\n')[1].split('            if ')[0])
  self.assertIn('Color.clear',s);self.assertIn('.fill(.ultraThinMaterial)',s)
 def test_full_opacity_only_when_accessibility_requires_it(self):
  s=(C/'AmoreTransparentDrawer.swift').read_text()
  self.assertIn('reduceTransparency || increasedContrast',s)
  self.assertIn('Color(uiColor: .systemBackground)',s)
  backdrop=s.split('struct AmoreDrawerBackdrop: View',1)[1].split('struct AmoreTransparentDrawer<',1)[0]
  self.assertNotIn('.opacity(',backdrop)
  self.assertIn('.allowsHitTesting(false)',backdrop)
  self.assertIn('.allowsHitTesting(!drawerIsPresented)',s)
  self.assertIn('.disabled(drawerIsPresented)',s)
  self.assertIn('.accessibilityHidden(drawerIsPresented)',s)
 def test_keep_existing_history_and_actions(self):
  s=(C/'ContentView+Layout.swift').read_text()
  for token in ['drawerHistory.groups','drawerSessionRow(session)','rebuildDrawerGroups()',
                'AmoreSidebarShortcuts(interactionEnabled: !drawerIsSliding)',
                'startHomeChat()','activeToolSheet = .settings','DeepLinkCoordinator.shared.pendingSettingsTarget = .home',
                '.amoreDrawerFooterGlass(in: Capsule())','.amoreDrawerFooterGlass(in: Circle())',
                '.frame(width: 132, height: 52)','.frame(width: 52, height: 52)',
                'DragGesture(minimumDistance: 16','.accessibilityAction(.escape)',
                'EdgeSwipeCatcher(enabled: !showHistoryDrawer']:
   self.assertIn(token,s)
 def test_theme_and_semantic_row_colour(self):
  s=(C/'AmoreTheme.swift').read_text()
  for token in ['static let uiSidebar = UIColor.clear','static let uiSidebarInk = UIColor.label',
                'static let uiSidebarSelected = UIColor.label.withAlphaComponent(0.08)']:
   self.assertIn(token,s)
if __name__=='__main__':
 unittest.main(verbosity=2)
