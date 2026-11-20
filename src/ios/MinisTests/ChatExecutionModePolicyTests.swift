import Foundation
import XCTest
@testable import Minis

final class ChatExecutionModePolicyTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ChatExecutionModePolicyTests.\(UUID().uuidString)")!
        return defaults
    }

    func testExistingSessionsStayAgentAndDifferentSessionsAreIsolated() {
        let defaults = isolatedDefaults()
        let a = UUID().uuidString, b = UUID().uuidString
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: a, draftId: nil, defaults: defaults), .agent)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: b, draftId: nil, defaults: defaults), .agent)
        XCTAssertEqual(ChatExecutionModePolicy.requestChange(to: .pureChat, sessionId: a, draftId: nil,
                                                              isBusy: false, defaults: defaults,
                                                              gateInstalled: true), .changed)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: a, draftId: nil, defaults: defaults), .pureChat)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: b, draftId: nil, defaults: defaults), .agent)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: a, draftId: nil, defaults: defaults), .pureChat,
                       "closing/reopening the view must restore that conversation's mode")
    }

    func testExitRestoresAllOriginalAgentToolsWithoutChangingOtherChats() {
        let defaults = isolatedDefaults()
        let a = UUID().uuidString, b = UUID().uuidString
        let tools = ["shell_execute", "browser_use", "device_control", "memory_get", "subagent_task"]
        XCTAssertEqual(ChatExecutionModePolicy.requestChange(to: .pureChat, sessionId: a, draftId: nil,
                                                              isBusy: false, defaults: defaults,
                                                              gateInstalled: true), .changed)
        XCTAssertTrue(ChatExecutionModePolicy.advertisedTools(tools, mode: .pureChat).isEmpty)
        for name in tools + ["future_tool", "unknown_mcp_function"] {
            XCTAssertFalse(ChatExecutionModePolicy.permitsTool(named: name, mode: .pureChat), name)
        }
        XCTAssertEqual(ChatExecutionModePolicy.requestChange(to: .agent, sessionId: a, draftId: nil,
                                                              isBusy: false, defaults: defaults), .changed)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: a, draftId: nil, defaults: defaults), .agent)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: b, draftId: nil, defaults: defaults), .agent)
        XCTAssertEqual(ChatExecutionModePolicy.advertisedTools(tools, mode: .agent), tools)
        XCTAssertTrue(tools.allSatisfy { ChatExecutionModePolicy.permitsTool(named: $0, mode: .agent) })
    }

    func testAmorePureChatModeCoreAPITracksSameSessionAndRestoresAgent() {
        let defaults = isolatedDefaults()
        let a = UUID().uuidString, b = UUID().uuidString
        XCTAssertFalse(AmorePureChatMode.isEnabled(sessionID: a, draftID: nil, defaults: defaults))
        XCTAssertEqual(AmorePureChatMode.setEnabled(true, sessionID: a, draftID: nil,
                                                   defaults: defaults, gateInstalled: true), .changed)
        XCTAssertTrue(AmorePureChatMode.isEnabled(sessionID: a, draftID: nil, defaults: defaults))
        XCTAssertFalse(AmorePureChatMode.isEnabled(sessionID: b, draftID: nil, defaults: defaults))
        XCTAssertEqual(AmorePureChatMode.setEnabled(false, sessionID: a, draftID: nil,
                                                   defaults: defaults), .changed)
        XCTAssertFalse(AmorePureChatMode.isEnabled(sessionID: a, draftID: nil, defaults: defaults))
    }

    func testBusyTurnRejectsBothDirectionsWithoutStoppingOrOverwritingMode() {
        let defaults = isolatedDefaults(), sid = UUID().uuidString
        XCTAssertEqual(ChatExecutionModePolicy.requestChange(to: .pureChat, sessionId: sid, draftId: nil,
                                                              isBusy: true, defaults: defaults,
                                                              gateInstalled: true), .busy)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: sid, draftId: nil, defaults: defaults), .agent)
        XCTAssertEqual(ChatExecutionModePolicy.requestChange(to: .pureChat, sessionId: sid, draftId: nil,
                                                              isBusy: false, defaults: defaults,
                                                              gateInstalled: true), .changed)
        XCTAssertEqual(ChatExecutionModePolicy.requestChange(to: .agent, sessionId: sid, draftId: nil,
                                                              isBusy: true, defaults: defaults), .busy)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: sid, draftId: nil, defaults: defaults), .pureChat)
    }

    func testDraftMigratesOnceOnFirstSendAndNextDraftRemainsAgent() {
        let defaults = isolatedDefaults()
        let draft = "__new__\(UUID().uuidString)", nextDraft = "__new__\(UUID().uuidString)"
        let real = UUID().uuidString
        XCTAssertEqual(ChatExecutionModePolicy.requestChange(to: .pureChat, sessionId: nil, draftId: draft,
                                                              isBusy: false, defaults: defaults,
                                                              gateInstalled: true), .changed)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: real, draftId: draft, defaults: defaults), .pureChat)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: real, draftId: draft, defaults: defaults), .pureChat)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: real, draftId: nil, defaults: defaults), .pureChat)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: nil, draftId: nextDraft, defaults: defaults), .agent)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: nil, draftId: draft, defaults: defaults), .agent,
                       "a migrated draft must not leak its old override")
    }

    func testGateMissingFailsClosedOnEntryAndMalformedStoredValueDoesNotEnableTools() {
        let defaults = isolatedDefaults(), sid = UUID().uuidString
        XCTAssertEqual(ChatExecutionModePolicy.requestChange(to: .pureChat, sessionId: sid, draftId: nil,
                                                              isBusy: false, defaults: defaults,
                                                              gateInstalled: false), .gateNotInstalled)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: sid, draftId: nil, defaults: defaults), .agent)
        defaults.set("unexpected-mode", forKey: "chat.executionMode.v1.\(sid)")
        let mode = ChatExecutionModePolicy.mode(sessionId: sid, draftId: nil, defaults: defaults)
        XCTAssertEqual(mode, .pureChat)
        XCTAssertFalse(ChatExecutionModePolicy.permitsTool(named: "device_control", mode: mode))
        XCTAssertEqual(ChatExecutionModePolicy.requestChange(to: .agent, sessionId: sid, draftId: nil,
                                                              isBusy: false, defaults: defaults), .changed)
        XCTAssertEqual(ChatExecutionModePolicy.mode(sessionId: sid, draftId: nil, defaults: defaults), .agent)
    }
}
