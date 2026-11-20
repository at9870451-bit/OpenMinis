from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[1]
class PhoneAndPureChat(unittest.TestCase):
 def read(self,path):return (R/path).read_text()
 def test_immutable_baseline(self):
  self.assertEqual((R/'src/ios/Minis.xcodeproj/project.pbxproj').read_text().count('MARKETING_VERSION = 1.39;'),0)
  s=self.read('src/ios/Views/ContentView/ContentView+Layout.swift')
  self.assertNotIn('AmoreTransparentDrawer(',s)
 def test_pure_chat_no_tool_advertisement_and_dispatch(self):
  a=self.read('src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift');b=self.read('src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift');c=self.read('src/ios/Agent/Chat/AIChatViewModel+AgentLoop.swift');p=self.read('src/ios/Views/Chat/AIChatView/Support/ChatExecutionModePolicy.swift')
  self.assertIn('static let executionGateInstalled = true',p)
  self.assertIn('AmorePureChatMode.isEnabled(sessionID: sessionId, draftID: draftId) else { return [] }',a)
  self.assertLess(b.index('if AmorePureChatMode.isEnabled('),b.index('switch tu.name'))
  self.assertIn('directAnswerOnly && !pureChatThisRun',c)
  self.assertIn('if !pureChatThisRun, let sid',c)
  self.assertIn('ChatExecutionModePolicy.pureChatInstruction',self.read('src/ios/Agent/Chat/AIChatViewModel+SystemPrompt.swift'))
 def test_phone_only_real_poki_core(self):
  d=self.read('src/ios/Views/ContentView/AmoreDeviceTools.swift');a=self.read('src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift');b=self.read('src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift');c=self.read('src/ios/Agent/Chat/AIChatViewModel+AgentLoop.swift')
  self.assertIn('AmoreDeviceServices.execute(',d)
  self.assertIn('if phoneOnlyThisTurn { return AmoreDeviceTools.definitions }',a)
  self.assertIn('if phoneOnlyThisTurn && tu.name != "device_control"',b)
  self.assertIn('AmoreCapsuleApps.bundleIDs(namedIn: phoneTaskText)',c)
  self.assertIn('phoneOnlyThisTurn = false',c)
 def test_original_poki_icon_not_fake_task(self):
  s=self.read('src/ios/Views/Chat/AmoreDeviceTaskCapsule.swift');p=self.read('vendor/poki/native/ios-app/Poki/AmoreAppCapsules.swift')
  for x in ('block.toolStatus','block.content','block.toolInputArgs') :self.assertIn(x,s)
  self.assertIn('TaskApps.launches(inArguments:',p)
  self.assertIn('AppIconStore.shared.icon(',p)
  self.assertIn('PillView(data: data)',p)
if __name__=='__main__':unittest.main(verbosity=2)
