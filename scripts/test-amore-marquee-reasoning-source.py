#!/usr/bin/env python3
"""Source contracts + mathematical reference only; NOT a Swift/iOS runtime test."""
from pathlib import Path
import re
import math
import unittest

ROOT = Path(__file__).resolve().parents[1]
MARQUEE = ROOT / 'src/ios/Views/ContentView/Marquee'
CHAT = ROOT / 'src/ios/Views/Chat/AIChatView'

def read(path):
    return path.read_text()

class SourceContracts(unittest.TestCase):
    def test_real_blank_chat_gate_and_input(self):
        s = read(CHAT / 'AIChatView+MessagesArea.swift')
        self.assertIn('AmoreHomeShortcutPolicy.shouldShow(', s)
        self.assertIn('vm.inputText = prompt', s)
        self.assertIn('inputFocused = true', s)
        self.assertIn('pastedTextCount: vm.pastedTexts.count', s)
        self.assertIn('isEditing: vm.editingMessageIndex != nil', s)
        self.assertIn('isProcessing: vm.isProcessing', s)
        self.assertIn('AmoreHomeMarqueeSource(', s)
        self.assertNotIn('views/rootfs', s)
        body = s.split('if AmoreHomeShortcutPolicy.shouldShow(')[1].split('.accessibilityIdentifier("chat.blankHome.shortcuts")')[0]
        self.assertNotRegex(body, r'vm\.(send|sendMessage|retry)\(')
        self.assertNotIn('if vm.sessionId == nil\n', body)

    def test_observed_single_source_and_local_management(self):
        s = read(MARQUEE / 'AmoreHomeMarqueeSource.swift')
        for value in ['@ObservedObject private var store = AmoreHomeShortcutStore.shared',
                      'items: store.visibleItems', 'revision: store.revision',
                      'scenePhase == .active', 'AmoreHomeShortcutManager()',
                      'AmoreHomeShortcutEditor(', 'AmoreShortcutRoutes.settingsURL',
                      'openLink: openURL']:
            self.assertIn(value, s)

    def test_original_copy_and_wrap_algorithm_remains(self):
        original = read(ROOT / 'vendor/poki/native/ios-app/Poki/Chat/Marquee.swift')
        port = read(MARQUEE / 'AmoreMarquee.swift')
        for line in ['let one = (size.width + spacing) / CGFloat(copies)',
                     'let needed = max(4, Int(((bounds.width + spacing) / one).rounded(.up)) + 3)',
                     'period = (size.width + spacing) / CGFloat(copies)',
                     'while x >= 2 * period { x -= period }',
                     'while x < period { x += period }']:
            self.assertIn(line, original)
            self.assertIn(line, port)
        self.assertIn('clock.advance(to: now', port)
        self.assertIn('active && loops && !stopped', port)
        self.assertIn('link?.invalidate()', port)

    def test_two_speeds_accessibility_and_power(self):
        s = read(MARQUEE / 'AmoreHomeMarqueePanel.swift')
        for value in ['speed: 20, start: 64', 'speed: -18, start: 0', 'loops: !voiceOver',
                      '!reduceMotion && !lowPower && !writing', 'onManage', 'onEdit(item)',
                      'setHidden(true, id: item.id)', 'remove(id: item.id)']:
            self.assertIn(value, s)
        hidden = s.split('setHidden(true, id: item.id)')[1].split('Button(role: .destructive)')[0]
        self.assertNotIn('remove(', hidden)
        self.assertNotIn('asyncAfter', s)

    def test_catalog_has_34_unique_supported_entries(self):
        s = read(MARQUEE / 'AmoreHomeShortcutCatalog.swift')
        entries = re.findall(r'^\s+(?:prompt|page|phone)\("([^"\n]+)"', s, re.M)
        self.assertEqual(len(entries), 34)
        self.assertEqual(len(entries), len(set(entries)))
        self.assertTrue({'new-task','summarize','code','translate','shortcuts','rootfs'} <= set(entries))
        routes = read(ROOT / 'src/ios/Shared/DeepLinkRouter.swift')
        for path in re.findall(r'^\s+page\([^\n]+, "([^"\n]+)"\)', s, re.M):
            if path != 'shortcuts':
                self.assertIn('"' + path + '"', routes)
        self.assertNotIn('views/rootfs', s)
        self.assertNotIn('Poki', s.replace("Poki's app-automation workflows", ''))

    def test_data_migration_and_management(self):
        policy = read(MARQUEE / 'HomeShortcut.swift')
        for value in ['messageCount == 0', 'attachmentCount == 0', 'pastedTextCount == 0',
                      '!isLoading && !isProcessing && !isEditing', 'seen.insert(item.id).inserted',
                      'previousDefaultIDs.contains(item.id)', 'result[index].hidden = hidden',
                      'u.user == nil && u.password == nil']:
            self.assertIn(value, policy)
        store = read(MARQUEE / 'AmoreHomeShortcutStore.swift')
        for value in ['amore.home.shortcuts.v1', 'storage: UserDefaults = .standard',
                      'func update(', 'func setHidden(', 'func restoreDefaults(',
                      'replacement.hidden = items[index].hidden', '!decoded.isEmpty',
                      'storage.integer(forKey: catalogKey) < 3']:
            self.assertIn(value, store)
        manager = read(MARQUEE / 'AmoreHomeShortcutManager.swift')
        for value in ['AmoreShortcutRoutes.pages', 'try store.add(item)', 'try store.update(item)',
                      'errorMessage = error.localizedDescription', 'store.restoreDefaults()',
                      'store.setHidden(!item.hidden, id: item.id)']:
            self.assertIn(value, manager)
        self.assertNotIn('try?', manager)

    def test_reasoning_is_in_both_original_plus_branches(self):
        s = read(CHAT / 'AIChatView+ComposerControls.swift')
        plus = s.split('/// True while the capsule has no text')[0]
        self.assertEqual(plus.count('if composerOffersThinkingLevels {'), 2)
        self.assertEqual(plus.count('vm.setThinkingLevel(level)'), 1)
        for value in ['vm.currentModelSupportsReasoning && !vm.availableThinkingLevels.isEmpty',
                      '[ThinkingLevel.off] + vm.availableThinkingLevels',
                      'vm.currentThinkingLevel == level', 'checkmark.circle.fill',
                      'level == .off || vm.availableThinkingLevels.contains(level)',
                      'if #available(iOS 17, *)', '.confirmationDialog(', 'Image("ThinkingIcon")']:
            self.assertIn(value, plus)
        self.assertNotIn('@AppStorage', plus)
        self.assertNotIn('UserDefaults', plus)
        self.assertNotIn('ThinkingLevel.allCases', plus)
        vm = read(ROOT / 'src/ios/Agent/Chat/AIChatViewModel+ThinkingLevel.swift')
        self.assertIn('cfg.thinkingLevel = clamped', vm)
        self.assertIn('pendingThinkingLevel = clamped', vm)
        self.assertIn('func flushPendingThinkingLevel()', vm)

    def test_clock_production_formula_matches_reference(self):
        s = read(MARQUEE / 'AmoreMarqueeClock.swift')
        for value in ['min(max(0, now - last), 0.1)',
                      'velocity += (target - velocity) * delta * 3',
                      'truncatingRemainder(dividingBy: period)',
                      'resumeAt = now + Self.rest', 'rest: TimeInterval = 2']:
            self.assertIn(value, s)
        # Numerical reference for the source-locked easing/wrap, not Swift execution.
        for speed in [20, -18]:
            velocity = 0.0
            drift = 0.0
            for frame in range(1800):
                delta = 1 / 60
                velocity += (speed - velocity) * delta * 3
                drift = math.fmod(drift + velocity * delta, 100)
                if drift < 0: drift += 100
                self.assertTrue(0 <= drift < 100)
            self.assertAlmostEqual(velocity, speed, places=5)

if __name__ == '__main__':
    unittest.main(verbosity=2)
