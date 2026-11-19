import Foundation
import XCTest
@testable import AmoreToolStream

final class Amore138ToolStreamTests: XCTestCase {
    private struct ExecutableCall {
        let id: String
        let name: String
        let args: [String: Any]
    }
    private struct Outcome {
        var calls: [ExecutableCall] = []
        var starts: [String] = []
        var inputs: [String] = []
        var reasons: [String] = []
        var reasoning: [String] = []
        var thinking = ""
        var text = ""
        var activity = 0
        var usages: [LLMUsage] = []
        var models: [String] = []
        var terminalOrder: [String] = []
        var error: Error?
        // This is an execution-boundary spy, NOT a real tool or device API.
        // Production dispatch eligibility begins only at toolCallComplete.
    }
    private struct InjectedDisconnect: Error {}

    private func sse(_ event: [String: Any], space: Bool = true) -> String {
        let data = try! JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        return "data:" + (space ? " " : "") + String(decoding: data, as: UTF8.self)
    }
    private func chunk(_ delta: [String: Any] = [:], finish: String? = nil,
                       model: String? = nil) -> String {
        var choice: [String: Any] = ["delta": delta]
        if let finish { choice["finish_reason"] = finish }
        var event: [String: Any] = ["choices": [choice]]
        if let model { event["model"] = model }
        return sse(event)
    }
    private func delta(index: Int = 0, id: String? = nil, name: String? = nil,
                       args: String? = nil) -> [String: Any] {
        var fn: [String: Any] = [:]
        if let name { fn["name"] = name }
        if let args { fn["arguments"] = args }
        var tool: [String: Any] = ["index": index, "type": "function", "function": fn]
        if let id { tool["id"] = id }
        return tool
    }
    private func tool(_ args: String?, index: Int = 0, id: String = "call_fixture",
                      name: String = "device_control", finish: String? = nil) -> String {
        chunk(["tool_calls": [delta(index: index, id: id, name: name, args: args)]], finish: finish)
    }
    private func collect(_ lines: [String], failure: Error? = nil,
                         level: ThinkingLevel = .on,
                         field: String? = nil) async -> Outcome {
        let input = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish(throwing: failure)
        }
        let host = ChatCompletionsStreamHost(model: HostModel(interleavedReasoningField: field))
        var out = Outcome()
        do {
            for try await event in host.stream(input, thinkingLevel: level) {
                switch event {
                case .contentBlockStart(.toolUse(let id, let name)):
                    out.starts.append("\(id):\(name)")
                case .toolInputDelta(_, let accumulated): out.inputs.append(accumulated)
                case .toolCallComplete(let id, let name, let args, _):
                    out.calls.append(ExecutableCall(id: id, name: name, args: args))
                    out.terminalOrder.append("call:\(id)")
                case .done(let reason):
                    out.reasons.append(String(describing: reason))
                    out.terminalOrder.append("done:\(reason)")
                case .reasoningContent(let content): out.reasoning.append(content)
                case .thinkingDelta(let text): out.thinking += text
                case .textDelta(let text): out.text += text
                case .streamActivity: out.activity += 1
                case .usage(let usage): out.usages.append(usage)
                case .responseModel(let model): out.models.append(model)
                default: break
                }
            }
        } catch { out.error = error }
        return out
    }
    private func assertNotExecuted(_ out: Outcome, _ detail: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(out.calls.isEmpty, "\(detail): no executable event", file: file, line: line)
        XCTAssertTrue(out.reasons.isEmpty, "\(detail): no success/done", file: file, line: line)
        XCTAssertNotNil(out.error, "\(detail): explicit stream error required", file: file, line: line)
    }

    func testNormalToolCallsFinishFlushesOnceBeforeDone() async {
        let out = await collect([
            tool("{\"action\":"),
            chunk(["tool_calls": [delta(args: "\"status\"}")]]),
            chunk(finish: "tool_calls"), "data: [DONE]"
        ])
        XCTAssertNil(out.error)
        XCTAssertEqual(out.starts, ["call_fixture:device_control"])
        XCTAssertEqual(out.calls.count, 1)
        XCTAssertEqual(out.calls.first?.args["action"] as? String, "status")
        XCTAssertEqual(out.inputs.last, "{\"action\":\"status\"}")
        XCTAssertEqual(out.reasons, ["toolUse"])
        XCTAssertEqual(out.terminalOrder, ["call:call_fixture", "done:toolUse"])
    }
    func testStopWithToolsStillMeansToolUse() async {
        let out = await collect([tool("{\"action\":\"status\"}"), chunk(finish: "stop"), "data: [DONE]"])
        XCTAssertNil(out.error)
        XCTAssertEqual(out.calls.count, 1)
        XCTAssertEqual(out.reasons, ["toolUse"])
    }
    func testDoneWithoutFinishCommitsCompleteJSONExactlyOnce() async {
        let out = await collect([
            tool("{\"action\":\"status\"}"), "data:[DONE]", "data: [DONE]"
        ])
        XCTAssertNil(out.error)
        XCTAssertEqual(out.calls.count, 1)
        XCTAssertEqual(out.reasons, ["toolUse"])
        XCTAssertEqual(out.terminalOrder, ["call:call_fixture", "done:toolUse"])
    }
    func testExplicitFinishThenEOFKeepsAuthorizedCommit() async {
        let out = await collect([tool("{}"), chunk(finish: "tool_calls")])
        XCTAssertNil(out.error)
        XCTAssertEqual(out.calls.count, 1)
        XCTAssertEqual(out.terminalOrder, ["call:call_fixture", "done:toolUse"])
    }
    func testRepeatedFinishAndPostTerminalDeltasCannotReopenTools() async {
        let out = await collect([
            tool("{}"), chunk(finish: "tool_calls"), chunk(finish: "stop"),
            tool("{\"action\":\"do\"}", id: "late_call"), "data: [DONE]"
        ])
        XCTAssertNil(out.error)
        XCTAssertEqual(out.starts.count, 1)
        XCTAssertEqual(out.calls.map(\.id), ["call_fixture"])
        XCTAssertEqual(out.reasons, ["toolUse"])
    }
    func testEmptyFinishReasonDoesNotCommitEarly() async {
        let out = await collect([
            tool("{\"action\":", finish: ""),
            chunk(["tool_calls": [delta(args: "\"status\"}")]], finish: ""),
            "data: [DONE]"
        ])
        XCTAssertNil(out.error)
        XCTAssertEqual(out.calls.count, 1)
        XCTAssertEqual(out.calls.first?.args["action"] as? String, "status")
        XCTAssertEqual(out.reasons, ["toolUse"])
    }
    func testLiteralEmptyObjectAllowedButMissingBlankAndNullRejected() async {
        let good = await collect([tool(" \n {} \t"), "data: [DONE]"])
        XCTAssertNil(good.error)
        XCTAssertEqual(good.calls.count, 1)
        XCTAssertTrue(good.calls.first?.args.isEmpty == true)
        for args in [nil, "", " \n\t ", "null"] as [String?] {
            let out = await collect([tool(args), "data: [DONE]"])
            assertNotExecuted(out, "missing/blank/non-object: \(args ?? "<absent>")")
            XCTAssertTrue(out.error?.localizedDescription.contains("not executed") == true)
        }
    }
    func testTruncatedInvalidAndNonObjectJSONFailAtBothExplicitTerminals() async {
        let bad = ["{", "{\"action\":\"do\"", "{\"action\":}", "[]", "[{}]",
                   "\"do\"", "true", "12", "{} trailing", "{}{}"]
        for args in bad {
            for terminal in [["data: [DONE]"], [chunk(finish: "tool_calls"), "data: [DONE]"]] {
                let out = await collect([tool(args)] + terminal)
                assertNotExecuted(out, args)
            }
        }
    }
    func testOneBadParallelCallPreventsEntireBatchFromExecuting() async {
        let out = await collect([
            tool("{\"action\":\"do\"}", index: 0, id: "valid"),
            tool("{\"action\":", index: 1, id: "truncated"), "data: [DONE]"
        ])
        assertNotExecuted(out, "atomic validation of ALL calls")
    }
    func testAbruptEOFNeverDispatchesEvenSyntacticallyCompleteDo() async {
        for args in ["{\"action\":\"do\",\"operation\":\"fixture-no-side-effect\"}", "{\"action\":", "{}"] {
            let out = await collect([tool(args)])
            assertNotExecuted(out, "EOF: \(args)")
            XCTAssertTrue(out.error?.localizedDescription.contains("before finish_reason or [DONE]") == true)
        }
    }
    func testThrownDisconnectAndCancellationNeverDispatch() async {
        let disconnected = await collect([tool("{\"action\":\"do\"}")], failure: InjectedDisconnect())
        assertNotExecuted(disconnected, "thrown transport failure")
        let cancelled = await collect([tool("{\"action\":\"do\"}")], failure: CancellationError())
        assertNotExecuted(cancelled, "cancelled transport")
        guard let error = cancelled.error as? LLMError, case .cancelled = error else {
            return XCTFail("Production mapError must retain cancellation")
        }
    }
    func testParallelCallsCompleteInIndexOrderWithOriginalArguments() async {
        let out = await collect([
            tool("{\"n\":2}", index: 2, id: "two"),
            tool("{\"n\":0}", index: 0, id: "zero"),
            tool("{\"n\":1}", index: 1, id: "one"), chunk(finish: "tool_calls"), "data: [DONE]"
        ])
        XCTAssertNil(out.error)
        XCTAssertEqual(out.calls.map(\.id), ["zero", "one", "two"])
        XCTAssertEqual(out.calls.map { $0.args["n"] as? Int }, [0, 1, 2])
    }
    func testEmptyIdentityDeltasNeverResetDeepSeekArguments() async {
        let out = await collect([
            tool("{\"action\":"),
            chunk(["tool_calls": [delta(id: "", name: "", args: "\"status\"}")]]),
            chunk(finish: "tool_calls"), "data: [DONE]"
        ])
        XCTAssertNil(out.error)
        XCTAssertEqual(out.starts.count, 1)
        XCTAssertEqual(out.calls.count, 1)
        XCTAssertEqual(out.calls.first?.args["action"] as? String, "status")
    }
    func testSplitIdentityAndRepeatedSameIdentityDoNotLoseArguments() async {
        let out = await collect([
            chunk(["tool_calls": [delta(id: "split", args: "{\"action\":")]]),
            chunk(["tool_calls": [delta(name: "device_control", args: "\"sta")]]),
            chunk(["tool_calls": [delta(id: "split", name: "device_control", args: "tus\"}")]]),
            "data: [DONE]"
        ])
        XCTAssertNil(out.error)
        XCTAssertEqual(out.starts, ["split:device_control"])
        XCTAssertEqual(out.calls.first?.args["action"] as? String, "status")
        XCTAssertEqual(out.calls.count, 1)
    }
    func testMissingIdentityIndexWrongArgumentTypeAndConflictsFailClosed() async {
        let wrongType: [String: Any] = ["index": 0, "id": "bad", "function": [
            "name": "device_control", "arguments": ["action": "do"]]]
        let noIndex: [String: Any] = ["id": "bad", "function": [
            "name": "device_control", "arguments": "{}"]]
        let fixtures = [
            [chunk(["tool_calls": [delta(args: "{}")]])],
            [chunk(["tool_calls": [noIndex]])],
            [chunk(["tool_calls": [wrongType]])],
            [tool("{"), tool("{}", id: "different")],
            [tool("{"), tool("{}", name: "different")],
            [tool("{}", index: 0, id: "same"), tool("{}", index: 1, id: "same")]
        ]
        for fixture in fixtures {
            assertNotExecuted(await collect(fixture + ["data: [DONE]"]), "ambiguous tool delta")
        }
    }
    func testTextOnlyStopDoneMissingFinishAndPlainEOFRetainBehavior() async {
        for terminal in [[chunk(finish: "stop"), "data: [DONE]"], ["data: [DONE]"], []] {
            let out = await collect([chunk(["content": "hello"]) ] + terminal)
            XCTAssertNil(out.error)
            XCTAssertEqual(out.text, "hello")
            XCTAssertTrue(out.calls.isEmpty)
            XCTAssertEqual(out.reasons, terminal.isEmpty ? [] : ["endTurn"])
        }
    }
    func testLengthRefusalAndToolCallsStopReasonAreNotOverwrittenByDone() async {
        for (finish, expected) in [("length", "maxTokens"), ("content_filter", "refusal"),
                                   ("tool_calls", "toolUse"), ("stop", "endTurn")] {
            let out = await collect([chunk(finish: finish), "data: [DONE]", "data: [DONE]"])
            XCTAssertNil(out.error)
            XCTAssertEqual(out.reasons, [expected])
            XCTAssertTrue(out.calls.isEmpty)
        }
    }
    func testCompleteToolsKeepExistingLengthAndRefusalReasonMapping() async {
        for (finish, expected) in [("length", "maxTokens"), ("content_filter", "refusal")] {
            let out = await collect([tool("{}"), chunk(finish: finish), "data: [DONE]"])
            XCTAssertNil(out.error)
            XCTAssertEqual(out.calls.count, 1, "Preserve existing explicit-finish behavior for valid tools")
            XCTAssertEqual(out.reasons, [expected])
        }
        let bad = await collect([tool("{\"action\":"), chunk(finish: "length"), "data: [DONE]"])
        assertNotExecuted(bad, "length never repairs truncated JSON")
    }
    func testUsageAfterFinishStillDeliveredAndCacheTokensNotDoubleCounted() async {
        let usage = sse(["choices": [], "usage": ["prompt_tokens": 100, "completion_tokens": 7,
            "prompt_tokens_details": ["cached_tokens": 40, "cache_creation_input_tokens": 3]]])
        let out = await collect([tool("{}"), chunk(finish: "stop"), usage, "data: [DONE]"])
        XCTAssertNil(out.error)
        XCTAssertEqual(out.reasons, ["toolUse"])
        XCTAssertEqual(out.usages.count, 1)
        XCTAssertEqual(out.usages.first?.inputTokens, 60)
        XCTAssertEqual(out.usages.first?.cacheReadInputTokens, 40)
        XCTAssertEqual(out.usages.first?.cacheCreationInputTokens, 3)
        XCTAssertEqual(out.usages.first?.outputTokens, 7)
    }
    func testReasoningFieldsAndThinkPrefixSurviveDoneFallbackWithoutDuplicates() async {
        let out = await collect([
            chunk(["reasoning_content": "a"]), chunk(["reasoning": "b"]),
            chunk(["reasoning_text": "c"], model: "fixture-model"),
            chunk(["content": "<think>d</think> visible  "]),
            tool("{\"action\":\"status\"}"), "data: [DONE]"
        ])
        XCTAssertNil(out.error)
        XCTAssertEqual(out.thinking, "abcd")
        XCTAssertEqual(out.reasoning, ["abcd"])
        XCTAssertEqual(out.text, "visible")
        XCTAssertEqual(out.models, ["fixture-model"])
        XCTAssertEqual(out.calls.count, 1)
        let normal = await collect([
            chunk(["reasoning_content": "r"]), tool("{}"), chunk(finish: "tool_calls"), "data: [DONE]"
        ])
        XCTAssertEqual(normal.reasoning, ["r"], "finish + DONE must not duplicate final reasoning")
    }
    func testEmptyReasoningAndHiddenReasoningActivityArePreserved() async {
        let empty = await collect([chunk(["reasoning_content": ""]), chunk(finish: "stop"), "data: [DONE]"])
        XCTAssertNil(empty.error)
        XCTAssertEqual(empty.reasoning, [""])
        let hidden = await collect([chunk(["reasoning_content": "private fixture"]), "data: [DONE]"], level: .off)
        XCTAssertNil(hidden.error)
        XCTAssertEqual(hidden.thinking, "")
        XCTAssertEqual(hidden.reasoning, ["private fixture"])
        XCTAssertGreaterThan(hidden.activity, 0)
    }
    func testReducerDuplicateTerminalsAndEOFDoNotResubmit() throws {
        var reducer = AmoreToolCallCompletion()
        _ = try reducer.accumulate(delta(id: "once", name: "device_control", args: "{}"))
        XCTAssertNil(try reducer.complete(at: .finishReason("")))
        let completion = try XCTUnwrap(reducer.complete(at: .done))
        XCTAssertEqual(completion.calls.count, 1)
        XCTAssertEqual(String(describing: completion.reason), "toolUse")
        XCTAssertNil(try reducer.complete(at: .done))
        XCTAssertNil(try reducer.complete(at: .finishReason("tool_calls")))
        XCTAssertTrue(try reducer.accumulate(delta(id: "late", name: "device_control", args: "{}")).isEmpty)
        XCTAssertNoThrow(try reducer.endOfStream())
    }
    func testReducerFailureIsSealedAndCannotBeRetriedAsSuccess() throws {
        var reducer = AmoreToolCallCompletion()
        _ = try reducer.accumulate(delta(id: "cut", name: "device_control", args: "{\"action\":\"do\"}"))
        XCTAssertThrowsError(try reducer.endOfStream())
        XCTAssertTrue(reducer.isTerminal)
        XCTAssertNil(try reducer.complete(at: .done))
        XCTAssertNil(try reducer.complete(at: .finishReason("tool_calls")))
    }
}
