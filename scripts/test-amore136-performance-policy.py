#!/usr/bin/env python3
"""Offline contract tests. No network, packages, simulator or credentials.
With Swift installed, also compiles/runs the REAL pure Swift policy/planner.
Without Swift, source checks + explicitly labelled Python behaviour mirrors only.
"""
from pathlib import Path
import copy
import json
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'src/ios'

def read(path):
    return (IOS / path).read_text()

POLICY = read('Views/ContentView/AmorePerformancePolicy.swift')
WORKFLOW = read('Views/ContentView/AmoreWorkflowOutput.swift')
LOOP = read('Agent/Chat/AIChatViewModel+AgentLoop.swift')
MISC = read('Agent/Chat/AIChatViewModel+Misc.swift')
CONCURRENT = read('Agent/Chat/AIChatViewModel+ConcurrentTools.swift')
FOLDS = read('Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+ToolFolding.swift')
SNAPSHOT = read('Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+Snapshot.swift')
NODE = read('Views/ContentView/NodeOnlineRuntime.swift')
ROOTFS = read('iSH/RootfsManager.swift')

def swift_block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]

GREETINGS = json.loads('[' + re.search(r'return \[(.*?)\]\.contains\(greeting\)', POLICY).group(1) + ']')

def omits(text, prior=0, attachments=False, approval=False, helper=False, resuming=False):
    # Behaviour mirror, with the allow-list read from production Swift source.
    return (not any([prior, attachments, approval, helper, resuming]) and
            text.strip().lower().strip('!！.。?？～~') in GREETINGS)

def ranges(inputs):
    # Behaviour mirror for the pure Swift ranges function.
    result, start = [], None
    for i, value in enumerate(inputs + ['barrier']):
        if value in ('thinking', 'note', 'success'):
            if start is None: start = i
        elif start is not None:
            result.append((start, i - 1))
            start = None
    return result

class PerformancePolicyTests(unittest.TestCase):
    def test_unambiguous_greetings_have_zero_tools(self):
        for text in ['Hi!', ' hello ', '你好！', '您好', '哈囉', '早上好。']:
            with self.subTest(text=text): self.assertTrue(omits(text))

    def test_continue_is_never_a_greeting(self):
        for text in ['继续', '繼續', 'continue', '好的', 'yes', 'OK', '做吧']:
            self.assertFalse(omits(text))
            self.assertFalse(omits(text, prior=4))

    def test_explicit_device_file_live_and_verification_keep_tools(self):
        for text in ['你好，检查设备', 'hello, check my device', '读取电量',
                     '帮我打开文件', '最新新闻', '核实这条信息', 'hi /var/minis/a.txt']:
            self.assertFalse(omits(text))

    def test_any_task_context_attachment_resume_or_approval_keeps_tools(self):
        for kw in [{'prior': 1}, {'attachments': True}, {'approval': True},
                   {'helper': True}, {'resuming': True}]:
            self.assertFalse(omits('hello', **kw))

    def test_gate_uses_no_extra_llm_and_is_local_to_turn(self):
        gate = swift_block(POLICY, 'static func omitsTools')
        for key in ['priorMessageCount == 0', '!hasAttachments', '!hasPendingApproval', '!isHelper', '!isResuming']:
            self.assertIn(key, gate)
        self.assertNotIn('await', gate)
        self.assertIn('var tools = directAnswerOnly ? [] : makeAgentTools()', LOOP)
        # Pure Chat intentionally keeps already-injected memory context even
        # though it exposes zero tools; ordinary zero-tool greetings still skip it.
        self.assertEqual(LOOP.count('if memoryEnabled && (!directAnswerOnly || pureChatThisRun)'), 2)
        self.assertIn('if directAnswerOnly && !pureChatThisRun {', LOOP)
        self.assertIn('directAnswerOnly = false', LOOP)
        self.assertIn('tools = makeAgentTools()', LOOP)
        self.assertIn('AmoreToolPolicy.directAnswerRule', read('Agent/Chat/AIChatViewModel+SystemPrompt.swift'))

    def test_open_chat_does_not_boot_or_poll_kernel(self):
        self.assertIn('func ensureKernelBooted() {}', MISC)
        for path in ['Agent/Chat/AIChatViewModel+Send.swift', 'Agent/Chat/AIChatViewModel+Rerun.swift']:
            source = read(path)
            self.assertNotIn('while self.kernelStatus == .booting', source)
            self.assertNotIn('ensureKernelBooted()', source)
        self.assertIn('try await ensureKernelReadyForTool()', CONCURRENT)
        coordinator = read('Agent/ISH/ISHExecutionCoordinator.swift')
        self.assertIn('try await AmoreKernelReadiness.shared.ensureReady()', coordinator)
        terminal = read('Views/Rootfs/ISHTerminalView.swift')
        self.assertIn('try await AmoreKernelReadiness.shared.ensureReady()', terminal)
        self.assertNotIn('boot(withRootPath:', terminal)

    def test_single_flight_caches_only_complete_ready_and_retries(self):
        self.assertIn('private var flight: Task<Void, Error>?', POLICY)
        self.assertIn('if let flight {', POLICY)
        self.assertLess(POLICY.index('try await task.value'), POLICY.index('ready = true'))
        self.assertIn('guard RootfsManager.shared.applyDefaultMountOverlay()', POLICY)
        self.assertIn('ready = false\n            flight = nil\n            throw error', POLICY)
        self.assertLess(POLICY.index('didResetWhileBooted'), POLICY.index('if ready { return }'))
        self.assertIn('try await MainActor.run', POLICY)
        self.assertIn('RootfsOperationGate.shared.begin()', POLICY)

    def test_rootfs_validation_and_overlay_are_not_bypassed(self):
        install = swift_block(ROOTFS, 'func installIfNeeded()')
        self.assertEqual(install.count('= isInstalled'), 1)
        self.assertIn('guard !installed else', install)
        self.assertIn('try unzipFile', install)
        self.assertIn('func applyDefaultMountOverlay() -> Bool', ROOTFS)
        self.assertIn('if !parentsOK || !fileOK { completed = false }', ROOTFS)
        self.assertIn('return sqlite3_step(updateStmt) == SQLITE_DONE', ROOTFS)

    def test_signposts_measure_real_boundaries(self):
        app = read('MinisApp.swift')
        self.assertIn('AmorePerformanceTrace.beginColdLaunch()', app)
        self.assertIn('AmorePerformanceTrace.endColdLaunch()', app)
        for label in ['ColdLaunchToContent', 'FirstTool', 'RootfsInstall', 'NativeKernelBoot', 'KernelReady']:
            self.assertIn('name: "' + label + '"', POLICY)
        self.assertIn('AmorePerformanceTrace.beginFirstTool()', CONCURRENT)
        self.assertIn('AmorePerformanceTrace.endFirstTool(id)', CONCURRENT)

    def test_hide_output_is_opt_in_and_ui_only(self):
        self.assertIn('static let key = "amore.workflow.hideOutput"', WORKFLOW)
        self.assertIn('UserDefaults.standard.bool(forKey: key)', WORKFLOW)
        for forbidden in ['messages.remove', 'agentHistory.', 'ChatStore.', 'memory_write', 'setValue(', '.frame(height: 0)']:
            self.assertNotIn(forbidden, WORKFLOW)
        self.assertIn('AmoreWorkflowOutput.foldedRuns(in: blocks)', FOLDS)
        self.assertIn('expandedToolGroups.contains(run.key)', SNAPSHOT)
        bindings = read('Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+Bindings.swift')
        self.assertIn('publisher(for: .amoreWorkflowOutputDidChange)', bindings)

    def test_failed_pending_user_and_final_are_not_hidden(self):
        inputs = ['thinking', 'success', 'failed', 'pending', 'approval',
                  'user', 'final', 'thinking', 'success', 'final']
        self.assertEqual(ranges(inputs), [(0, 1), (7, 8)])
        self.assertEqual(ranges([]), [])
        self.assertEqual(ranges(['final']), [])
        self.assertEqual(ranges(['thinking']), [(0, 0)])

    def test_hiding_never_changes_history_or_audit(self):
        history = [{'role': 'user', 'text': 'test'}, {'role': 'assistant',
                   'blocks': ['thinking', 'success', 'approval', 'failed', 'final']}]
        before = copy.deepcopy(history)
        ranges(history[1]['blocks'])
        self.assertEqual(history, before)
        self.assertIn('ranges(ToolFoldPlanner.inputs(for: blocks))', WORKFLOW)
        # Each range is a reversible presentation; members remain in source.
        self.assertIn('memberIds: members.map(\\.id)', WORKFLOW)

    def test_node_success_depends_on_real_result_and_marker(self):
        self.assertIn('Runtime ready: node, npm and npx verified; AOJIT status is separate.', NODE)
        for item in ['guard executionOK, exitCode == 0', 'contains("AMORE_NODE_ONLINE_READY")',
                     'node --version', 'npm --version', 'npx --version', 'result.error == .none']:
            self.assertIn(item, NODE)
        self.assertLess(NODE.index('guard executionOK'), NODE.index('isReady = true'))


def run_swift_pure_tests():
    swift = shutil.which('swift')
    if not swift:
        print('SKIP real Swift compile/run: Swift toolchain not installed; Python cases are behaviour mirrors.', flush=True)
        return
    planner = read('Agent/MessageList/ToolFoldPlanner.swift').split('// END ToolFoldPlanner')[0]
    policy = swift_block(POLICY, 'enum AmoreToolPolicy')
    function = swift_block(WORKFLOW, 'static func ranges')
    harness = '''
func omit(_ text: String, _ prior: Int = 0, _ attachment: Bool = false,
          _ approval: Bool = false, _ helper: Bool = false, _ resume: Bool = false) -> Bool {
    AmoreToolPolicy.omitsTools(text: text, priorMessageCount: prior,
        hasAttachments: attachment, hasPendingApproval: approval,
        isHelper: helper, isResuming: resume)
}
precondition(omit("你好！"))
precondition(omit(" Hello! "))
for text in ["继续", "continue", "好的", "hello, check my device", "读取电量", "实时新闻"] {
    precondition(!omit(text))
}
precondition(!omit("hello", 2))
precondition(!omit("hello", 0, true))
precondition(!omit("hello", 0, false, true))
precondition(!omit("hello", 0, false, false, true))
precondition(!omit("hello", 0, false, false, false, true))
let input: [ToolFoldPlanner.Input] = [.thinking, .tool(.succeeded), .tool(.failed),
    .tool(.unfinished), .barrier, .text(isEmpty: false), .thinking,
    .note, .tool(.succeeded), .text(isEmpty: false)]
let before = input
precondition(WorkflowTest.ranges(input) == [0...1, 6...8])
precondition(input == before)
precondition(WorkflowTest.ranges([]).isEmpty)
precondition(WorkflowTest.ranges([.text(isEmpty: false)]).isEmpty)
print("PASS real Swift pure policy / workflow ranges")
'''
    source = 'import Foundation\n' + policy + '\n' + planner + '\nenum WorkflowTest {\n' + function + '\n}\n' + harness
    with tempfile.TemporaryDirectory(prefix='amore136-policy-') as temp:
        script = Path(temp) / 'main.swift'
        script.write_text(source)
        subprocess.run([swift, str(script)], check=True, timeout=120)

if __name__ == '__main__':
    result = unittest.main(exit=False)
    if not result.result.wasSuccessful(): raise SystemExit(1)
    run_swift_pure_tests()
    print('PASS offline source contracts; NOT an Xcode build or device acceptance.')
