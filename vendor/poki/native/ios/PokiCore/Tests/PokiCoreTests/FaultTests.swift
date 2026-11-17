import XCTest
@testable import PokiCore

/// The runner misbehaving in the ways a phone does, and text entry. Every call must answer in time
/// and say what was sent and what is on screen.
final class FaultTests: XCTestCase {
    func testAnUnreadableScreenDoesNotReportThePreviousApp() async {
        let (core, wda, _) = makeCore()
        wda.source([("Button", "New note")], app: "Notes")
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.mobilenotes", "name": "Notes"]]) }
        let events = LockedBox<[CoreEvent]>([])
        let observer = Task { for await event in core.events { events.update { $0.append(event) } } }
        defer { observer.cancel() }
        _ = await core.call("look", [:])
        let first = await eventually { events.value.contains { if case .toolFinished(_, _, let facts) = $0 { return facts.app == "Notes" }; return false } }
        XCTAssertTrue(first, "The first task read Notes")
        events.value = []
        for route in ["GET /source", "GET /screenshot", "GET /wda/activeAppInfo"] {
            wda.set(route) { _ in (500, ["value": ["error": "unknown error", "message": "read failed"]]) }
        }
        let answer = await core.call("look", [:])
        XCTAssertTrue(answer.isError, answer.text)
        let finished = await eventually { events.value.contains { if case .toolFinished = $0 { return true }; return false } }
        XCTAssertTrue(finished)
        guard case .toolFinished(_, _, let facts)? = events.value.last else { return XCTFail("Missing completion event") }
        XCTAssertNil(facts.app, "A failed read must not attribute the new task to Notes")
    }

    /// A focused field that keeps what /wda/keys and the paste menu put in it.
    final class Field: @unchecked Sendable {
        let frame: [Double]
        init(frame: [Double] = [16, 100, 358, 44]) { self.frame = frame }
        let value = LockedBox("")
        let clipboard = LockedBox<String?>("owner's clipboard")
        /// The keyboard is up (a field has the focus), as the tree shows it.
        let keyboard = LockedBox(true)
        let menuShown = LockedBox(false)
        /// The tree as the field's app shows it: the field with its value, the keyboard when up, and
        /// the Paste menu once it was opened.
        func tree() -> JSON {
            var children: [Node] = [Node("TextField", "Note", frame, value: value.value)]
            if menuShown.value { children.append(Node("MenuItem", "Paste", [150, 50, 80, 40])) }
            if keyboard.value { children.append(Node("Keyboard", nil, [0, 500, 390, 344], [Node("Button", "space", [100, 800, 190, 40])])) }
            func json(_ n: Node) -> JSON {
                ["type": .string("XCUIElementType\(n.type)"), "label": n.label.map(JSON.string) ?? .null, "value": n.value.map(JSON.string) ?? .null, "rect": ["x": .number(n.frame[0]), "y": .number(n.frame[1]), "width": .number(n.frame[2]), "height": .number(n.frame[3])], "children": .array(n.children.map(json))]
            }
            return ["type": "XCUIElementTypeApplication", "label": "Notes", "rect": ["x": 0, "y": 0, "width": 390, "height": 844], "children": .array(children.map(json))]
        }
        func install(_ wda: FakeWDA, menu: Bool = true) {
            wda.set("GET /source") { [self] _ in (200, ["value": tree()]) }
            wda.set("GET /element/active") { _ in (200, ["value": ["ELEMENT": "E1"]]) }
            wda.set("GET /element/E1/attribute/value") { [value] _ in (200, ["value": .string(value.value)]) }
            wda.set("GET /element/E1/attribute/placeholderValue") { _ in (200, ["value": .null]) }
            wda.set("GET /element/E1/rect") { _ in (200, ["value": ["x": 16, "y": 100, "width": 358, "height": 44]]) }
            wda.set("POST /wda/keys") { [value] body in
                for key in body?["value"]?.array ?? [] {
                    if key.string == "\u{8}" { value.update { if !$0.isEmpty { $0.removeLast() } } } else { value.update { $0 += key.string ?? "" } }
                }
                return (200, ["value": .null])
            }
            wda.set("POST /wda/getPasteboard") { [clipboard] _ in
                guard let text = clipboard.value else { return (500, ["value": ["error": "unknown error", "message": "pasteboard unavailable"]]) }
                return (200, ["value": .string(Data(text.utf8).base64EncodedString())])
            }
            wda.set("POST /wda/setPasteboard") { [clipboard] body in
                clipboard.value = body?["content"]?.string.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
                return (200, ["value": .null])
            }
            if menu {
                wda.set("POST /wda/touchAndHold") { [menuShown] _ in
                    menuShown.value = true
                    return (200, ["value": .null])
                }
            }
            wda.set("POST /wda/tap") { [value, clipboard] body in
                if body?["x"]?.double == 190, body?["y"]?.double == 70 { value.update { $0 += clipboard.value ?? "" } }
                return (200, ["value": .null])
            }
        }
    }

    func testMixedScriptTextIsTypedDirectlyAndReadBackExactly() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        _ = await core.call("look", [:])
        let text = "你好 Poki 2026，テスト 한글 ok"
        let result = await core.call("do", ["actions": [["type": .string(text)]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(field.value.value, text)
        XCTAssertTrue(result.text.contains("(typed); the field now reads \"\(text)\""), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/getPasteboard").count, 0, "typing never touches the clipboard")
    }

    /// The runner's /wda/keys, scripted per call: (typed before it answers, answer).
    private func keys(_ wda: FakeWDA, _ field: Field, _ script: [(typed: String, ok: Bool)]) {
        let call = LockedBox(0)
        wda.set("POST /wda/keys") { body in
            let n = call.value; call.update { $0 += 1 }
            let step = script[min(n, script.count - 1)]
            field.value.update { $0 += step.typed }
            if step.ok { return (200, ["value": .null]) }
            return (500, ["value": ["error": "unknown error", "message": .string("could not type \(body?["value"]?.array?.compactMap(\.string).joined() ?? "")")]])
        }
    }

    func testAFailedStepLogsItsErrorLineWithoutTheTypedText() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        keys(wda, field, [("", false)])
        let events = LockedBox<[CoreEvent]>([])
        Task { for await e in core.events { events.update { $0.append(e) } } }
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["type": "door code 4412"]]])
        let finished = await eventually { events.value.contains { if case .toolFinished(let a, _, _) = $0 { return a.name == "do" }; return false } }
        XCTAssertTrue(finished)
        guard case .toolFinished(_, _, let facts)? = events.value.last else { return XCTFail("\(events.value)") }
        XCTAssertTrue(facts.error?.hasPrefix("error: action 1") == true, "\(facts.error ?? "no error line")")
        XCTAssertFalse(facts.error?.contains("4412") ?? false, "the typed text stays out of the log")
    }

    func testATypeThatLandedButAnsweredWithAFailureCountsAsTyped() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        keys(wda, field, [("hello", false)])
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "hello"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(field.value.value, "hello")
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1, "typed once: the field already held the text")
        XCTAssertTrue(result.text.contains("the field now reads \"hello\""), result.text)
    }

    func testATypeThatDidNotLandIsSentAgainOnce() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        keys(wda, field, [("", false), ("hello", true)])
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "hello"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(field.value.value, "hello")
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 2)
    }

    func testAFailingTypeIsSentAgainOnlyOnce() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        keys(wda, field, [("", false)])
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "hello"]]])
        XCTAssertTrue(result.text.contains("\nerror: action 1"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 2)
    }

    func testAHalfTypedFieldIsNotTypedIntoAgain() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        keys(wda, field, [("hel", false), ("hello", true)])
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "hello"]]])
        XCTAssertTrue(result.text.contains("\nerror: action 1"), result.text)
        XCTAssertEqual(field.value.value, "hel", "a second try would have made it helhello")
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1)
        XCTAssertTrue(result.text.contains("the field holds \"hel\""), result.text)
    }

    /// What the real runner answers (WDA's wdValue, with an empty string turned into nil): an empty field
    /// reads as its placeholder, or null when it has none; the placeholder is also its own attribute.
    private func realRunnerValue(_ wda: FakeWDA, _ field: Field, placeholder: String?, placeholderFails: Bool = false) {
        wda.set("GET /element/E1/attribute/value") { _ in
            let held = field.value.value
            if !held.isEmpty { return (200, ["value": .string(held)]) }
            return (200, ["value": placeholder.map(JSON.string) ?? .null])
        }
        wda.set("GET /element/E1/attribute/placeholderValue") { _ in
            if placeholderFails { return (500, ["value": ["error": "unknown error", "message": "timed out"]]) }
            return (200, ["value": placeholder.map(JSON.string) ?? .null])
        }
    }

    /// Types `text` into the field and returns the answer and the error line the app log gets.
    private func typeAndLog(_ core: PokiCore, _ text: String) async -> (answer: ToolResult, logged: String?) {
        let events = LockedBox<[CoreEvent]>([])
        Task { for await e in core.events { events.update { $0.append(e) } } }
        _ = await core.call("look", [:])
        let answer = await core.call("do", ["actions": [["type": .string(text)]]])
        _ = await eventually { events.value.contains { if case .toolFinished(let a, _, _) = $0 { return a.name == "do" }; return false } }
        guard case .toolFinished(_, _, let facts)? = events.value.last else { return (answer, nil) }
        return (answer, facts.error)
    }

    func testAnEmptySearchFieldShowingItsPlaceholderIsTypedIntoAgain() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        realRunnerValue(wda, field, placeholder: "Search destinations")
        keys(wda, field, [("", false), ("hello", true)])
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "hello"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(field.value.value, "hello")
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 2, "the placeholder is not text: one more try")
    }

    func testAnEmptyFieldThatReadsNullIsTypedIntoAgain() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        realRunnerValue(wda, field, placeholder: nil)
        keys(wda, field, [("", false), ("hello", true)])
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "hello"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(field.value.value, "hello")
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 2)
    }

    func testAFailingTypeInAPlaceholderFieldIsNeverCalledHalfTyped() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        realRunnerValue(wda, field, placeholder: "Search destinations")
        keys(wda, field, [("", false)])
        let (answer, logged) = await typeAndLog(core, "hello")
        XCTAssertTrue(answer.text.contains("\nerror: action 1"), answer.text)
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 2)
        XCTAssertFalse(answer.text.contains("Search destinations"), "the placeholder is not what the field holds: \(answer.text)")
        XCTAssertTrue(logged?.contains("field empty") == true, logged ?? "no error line")
    }

    func testTheLogNamesAHalfTypedFieldButNeverItsContent() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        keys(wda, field, [("door code 44", false), ("door code 4412", true)])
        let (answer, logged) = await typeAndLog(core, "door code 4412")
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1, "half typed: not typed again")
        XCTAssertTrue(answer.text.contains("door code 44"), "the model is told what the field holds: \(answer.text)")
        XCTAssertTrue(logged?.contains("field has other text") == true, logged ?? "no error line")
        XCTAssertFalse(logged?.contains("door") ?? true, logged ?? "")
        XCTAssertFalse(logged?.contains("44") ?? true, logged ?? "")
    }

    func testTheLogNeverHoldsTheOwnersOwnTextFromTheField() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        field.value.value = "Dear Sam, my bank PIN is 9931"
        keys(wda, field, [("", false)])
        let (answer, logged) = await typeAndLog(core, " see you")
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1)
        XCTAssertTrue(answer.text.contains("bank PIN is 9931"), "the model is told what the field holds: \(answer.text)")
        XCTAssertTrue(logged?.contains("field has other text") == true, logged ?? "no error line")
        XCTAssertFalse(logged?.contains("Sam") ?? true, logged ?? "")
        XCTAssertFalse(logged?.contains("9931") ?? true, logged ?? "")
    }

    func testATextThatEqualsThePlaceholderIsNotTypedTwice() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        realRunnerValue(wda, field, placeholder: "三亚")
        keys(wda, field, [("三亚", false), ("三亚", true)])
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "三亚"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(field.value.value, "三亚", "the first try landed: a second would make 三亚三亚")
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1)
    }

    func testAPlaceholderThatStartsTheTextDoesNotMakeAHalfTypedFieldEmpty() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        realRunnerValue(wda, field, placeholder: "Search")
        keys(wda, field, [("Search", false), ("Search apps", true)])
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "Search apps"]]])
        XCTAssertTrue(result.text.contains("\nerror: action 1"), result.text)
        XCTAssertEqual(field.value.value, "Search", "a second try would make SearchSearch apps")
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1)
    }

    func testAPlaceholderThatContainsTheTextDoesNotCountAsTypedText() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        realRunnerValue(wda, field, placeholder: "Search destinations")
        keys(wda, field, [("", false), ("Search", true)])
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "Search"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(field.value.value, "Search", "the empty field only showed a longer placeholder: the text still has to go in")
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 2)
    }

    func testAFieldWhosePlaceholderCannotBeReadIsNotTypedIntoAgainAndSaysSo() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        realRunnerValue(wda, field, placeholder: "Search destinations", placeholderFails: true)
        keys(wda, field, [("", false), ("hello", true)])
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "hello"]]])
        XCTAssertTrue(result.text.contains("\nerror: action 1"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1)
        XCTAssertTrue(result.text.contains("placeholder could not be read"), result.text)
    }

    func testPasteIsTheBackupAndPutsTheOwnersClipboardBack() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "密码不是这个", "via": "paste"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(field.value.value, "密码不是这个")
        XCTAssertEqual(field.clipboard.value, "owner's clipboard", "the owner's clipboard is restored")
        XCTAssertTrue(result.text.contains("(pasted); the field now reads \"密码不是这个\""), result.text)
    }

    func testOffscreenPasteFieldIsRejectedBeforeClearingOrChangingTheClipboard() async {
        let (core, wda, _) = makeCore()
        let field = Field(frame: [400, 100, 20, 40])
        field.value.value = "old"
        field.install(wda)
        do {
            _ = try await core.computer.paste("new", clear: true, until: now() + 6)
            XCTFail("an off-screen field must be refused")
        } catch {
            XCTAssertTrue(String(describing: error).contains("not_hittable"))
        }
        XCTAssertEqual(field.value.value, "old")
        XCTAssertEqual(field.clipboard.value, "owner's clipboard")
        XCTAssertTrue(wda.bodies("POST /wda/keys").isEmpty)
        XCTAssertTrue(wda.bodies("POST /wda/setPasteboard").isEmpty)
        XCTAssertTrue(wda.bodies("POST /wda/touchAndHold").isEmpty)
    }

    func testAnUnreadableClipboardIsNeverOverwritten() async {
        let (core, wda, _) = makeCore()
        let field = Field()
        field.install(wda)
        field.clipboard.value = nil
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "hello", "via": "paste"]]])
        XCTAssertTrue(result.text.contains("the clipboard could not be read, so it was not used"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/setPasteboard").count, 0)
        XCTAssertEqual(field.value.value, "")
    }

    func testAMissingPasteMenuStillRestoresTheClipboard() async {
        let (core, wda, _) = makeCore { $0.actionCap = 4 }
        let field = Field()
        field.install(wda, menu: false)
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "hello", "via": "paste"]]])
        XCTAssertTrue(result.text.contains("showed no Paste item"), result.text)
        XCTAssertEqual(field.clipboard.value, "owner's clipboard")
    }

    func testClearingWithNothingFocusedKeepsTheSession() async {
        let (core, wda, _) = makeCore()
        wda.set("GET /element/active") { _ in (404, ["value": ["error": "no such element", "message": "No element has focus"]]) }
        _ = await core.call("look", [:])
        let sessions = wda.sent.filter { $0 == "POST /session" }.count
        let result = await core.call("do", ["actions": [["type": "hi", "clear": true]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.sent.filter { $0 == "POST /session" }.count, sessions, "no new session for a WebDriver 'no such element'")
    }

    func testWaitUntilSettledAsAWordWaitsForAStillScreen() async {
        let (core, _, _) = makeCore()
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["wait_until": "settled"]]])
        XCTAssertTrue(result.text.contains("wait_until: the screen held still after"), result.text)
    }

    func testALockedPhoneTakesNoInputAndLookSaysSo() async {
        let (core, wda, _) = makeCore()
        wda.set("GET /wda/locked") { _ in (200, ["value": true]) }
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("screen: locked"), look.text)
        let result = await core.call("do", ["actions": [["tap": [100, 100]]]])
        XCTAssertTrue(result.text.contains("screen: locked. Nothing was sent."), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0)
        let button = await core.call("do", ["actions": [["button": "home"]]])
        XCTAssertFalse(button.text.contains("Nothing was sent"), "buttons still work: \(button.text)")
    }

    func testARunnerRestartedMidCallGetsANewSessionAndTheTapGoesThrough() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        let first = LockedBox(true)
        wda.set("POST /wda/tap") { [first] _ in
            if first.value { first.value = false; return (404, ["value": ["error": "invalid session id", "message": "Session does not exist"]]) }
            return (200, ["value": .null])
        }
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 2)
        XCTAssertTrue(result.text.contains("(sent,"), result.text)
    }

    func testARunnerThatDiesMidDoStopsAndSaysWhatWasSent() async {
        let (core, wda, host) = makeCore()
        _ = await core.call("look", [:])
        let gone: FakeWDA.Route = { _ in throw TransportError.refused }
        wda.set("POST /wda/keys", gone)
        for key in ["GET /source", "GET /screenshot", "GET /wda/activeAppInfo"] { wda.set(key, gone) }
        let started = Date()
        let result = await core.call("do", ["actions": [["tap": 1], ["key": "return"], ["tap": 2]]])
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertTrue(result.text.contains("(sent,"), "the tap before it was sent: \(result.text)")
        XCTAssertTrue(result.text.contains("(not_sent"), result.text)
        XCTAssertTrue(result.text.contains("runner:"), "says what the runner is doing: \(result.text)")
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, "nothing after the failed action")
        XCTAssertGreaterThanOrEqual(host.restarts.value, 1)
    }

    func testAnAppSwitchMidGestureIsReportedAndTheReadStillComes() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        wda.set("POST /wda/pressAndDragWithVelocity") { [wda] _ in
            wda.source([("Button", "Open")], app: "Other app")
            return (500, ["value": ["error": "invalid element state", "message": "Cannot resolve the on-screen position of the drag gesture"]])
        }
        let result = await core.call("do", ["actions": [["swipe": "up"], ["tap": 1]]])
        XCTAssertTrue(result.text.contains("Cannot resolve the on-screen position"), result.text)
        XCTAssertTrue(result.text.contains("Button \"Open\""), "the read after it shows the new screen: \(result.text)")
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0)
    }

    func testAHugeTreeIsReadInTimeAndTheListIsCapped() async {
        let (core, wda, _) = makeCore()
        wda.source((0..<5000).map { ("StaticText", "Line \($0)") })
        let started = Date()
        let result = await core.call("look", [:])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(result.text.contains("StaticText \"Line 0\""), String(result.text.prefix(300)))
        XCTAssertFalse(result.text.contains("Line 4999"), "rows off the screen are not listed")
        XCTAssertLessThan(result.text.count, 20_000)
    }

    func testASlowRunnerNeverHoldsACallPastItsDeadline() async {
        let (core, wda, _) = makeCore { $0.toolDeadline = 4; $0.actionCap = 2; $0.readTimeout = 1 }
        for key in ["GET /source", "GET /screenshot", "POST /wda/tap"] {
            wda.set(key) { _ in try await Task.sleep(nanoseconds: 20_000_000_000); return (200, ["value": .null]) }
        }
        let started = Date()
        let result = await core.call("do", ["actions": [["tap": [10, 10]], ["tap": [20, 20]]]])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.5)
        XCTAssertTrue(result.text.contains("may have been delivered"), result.text)
    }

    func testAHangingSessionCreationDoesNotOutliveTheToolDeadline() async {
        let wda = FakeWDA()
        wda.set("POST /session") { _ in try await Task.sleep(nanoseconds: 60_000_000_000); return (200, ["value": ["sessionId": "s1"]]) }
        let (core, _, _) = makeCore(wda) { $0.toolDeadline = 4; $0.readTimeout = 1 }
        let started = Date()
        let result = await core.call("look", [:])
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertFalse(result.text.contains("what was sent is unknown"), "the call's own answer, not the backstop: \(result.text)")
    }

    func testConcurrentReadsOpenOneSession() async {
        let wda = FakeWDA()
        wda.set("POST /session") { _ in try await Task.sleep(nanoseconds: 200_000_000); return (200, ["value": ["sessionId": "s1"]]) }
        let (core, _, _) = makeCore(wda)
        _ = await core.call("look", [:])
        XCTAssertEqual(wda.sent.filter { $0 == "POST /session" }.count, 1, wda.sent.joined(separator: ", "))
    }

    /// WDA serves requests one at a time, so a slow read makes the next ones time out too. That runner
    /// is busy: it keeps its session and is not restarted while it still answers /status.
    func testABusyRunnerIsNotRestartedWhileItStillAnswersStatus() async throws {
        let (core, wda, host) = makeCore { $0.readTimeout = 0.3 }
        core.runner.probeTimeout = 0.5
        _ = await core.call("look", [:])
        let slow: FakeWDA.Route = { _ in try await Task.sleep(nanoseconds: 2_000_000_000); return (200, ["value": .null]) }
        for key in ["GET /source", "GET /screenshot", "GET /wda/activeAppInfo"] { wda.set(key, slow) }
        let sessions = wda.sent.filter { $0 == "POST /session" }.count
        _ = await core.call("look", [:])
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(host.restarts.value, 0, "a busy runner is left to finish")
        XCTAssertGreaterThanOrEqual(wda.sent.filter { $0 == "GET /status" }.count, 1, "it was asked whether it is there")
        wda.source([("Button", "General")])
        for key in ["GET /screenshot", "GET /wda/activeAppInfo"] { wda.set(key) { _ in (200, ["value": .null]) } }
        _ = await core.call("look", [:])
        XCTAssertFalse(wda.sent.contains("DELETE /session"), "slow reads keep the session; only an action that times out ends it")
        XCTAssertEqual(wda.sent.filter { $0 == "POST /session" }.count, sessions, "the same session serves the next look once the runner is through")
    }

    func testAWedgedRunnerThatAnswersNothingIsRestartedAfterTheProbe() async throws {
        let (core, wda, host) = makeCore { $0.readTimeout = 0.3 }
        core.runner.probeTimeout = 0.3
        _ = await core.call("look", [:])
        let stuck: FakeWDA.Route = { _ in try await Task.sleep(nanoseconds: 20_000_000_000); return (200, ["value": .null]) }
        for key in ["GET /source", "GET /screenshot", "GET /wda/activeAppInfo", "GET /status"] { wda.set(key, stuck) }
        _ = await core.call("look", [:])
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(host.restarts.value, 1, "no answer to /status either: the runner is started again")
    }

    /// Found on the simulator: WDA answers the Home button only outside a session.
    func testHomeIsPressedOutsideTheSession() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["button": "home"]]])
        XCTAssertFalse(result.text.contains("not_sent"), result.text)
        XCTAssertEqual(wda.sent.filter { $0 == "POST /wda/homescreen" }.count, 1, wda.sent.joined(separator: ", "))
    }

    /// Found on the simulator: with a keyboard up the tree can take longer than a read waits. The text
    /// in the picture is listed instead, numbered, and a number taps that text.
    func testWithoutATreeTheTextInThePictureIsListedAndTappable() async {
        let (core, wda, host) = makeCore { $0.readTimeout = 0.5 }
        _ = await core.call("look", [:])
        host.texts.value = [RecognizedText(text: "Continue", box: Rect(x: 0.25, y: 0.9, width: 0.5, height: 0.05))]
        wda.set("GET /source") { _ in try await Task.sleep(nanoseconds: 5_000_000_000); return (200, ["value": .null]) }
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("read from the picture because the element tree did not come in time"), look.text)
        XCTAssertTrue(look.text.contains("1 Text \"Continue\""), look.text)
        wda.source([("Button", "Continue")])
        let tap = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertFalse(tap.text.contains("not_sent"), tap.text)
        let body = wda.bodies("POST /wda/tap").last
        XCTAssertEqual(body?["x"]?.double, 195)
        XCTAssertEqual(body?["y"]?.double ?? 0, 0.925 * 844, accuracy: 0.5)
    }

    /// Found on the simulator: with no tree and nothing read from the picture, the answer listed no
    /// elements and did not say why. It now says whether the text reading found nothing, failed or ran out of time.
    func testWithoutATreeAnEmptyPictureReadIsSaidSo() async {
        let (core, wda, host) = makeCore { $0.readTimeout = 0.5 }
        _ = await core.call("look", [:])
        host.texts.value = []
        wda.set("GET /source") { _ in try await Task.sleep(nanoseconds: 5_000_000_000); return (200, ["value": .null]) }
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("no text found in the picture"), look.text)
        host.texts.value = nil
        let again = await core.call("look", [:])
        XCTAssertTrue(again.text.contains("text could not be read from the picture"), again.text)
    }

    /// Seen on the phone: a feed's tree took longer than a read, and the swipes and taps sent after it
    /// waited their turn behind it on WDA's main thread, so they landed long after the agent had
    /// reported them failed. Now a request this side gives up on ends the session: WDA answers what
    /// is queued behind it with "session does not exist" instead of running it, and an action sent
    /// while the runner is still finishing is answered not_sent and busy, so nothing runs late.
    /// A read that times out keeps the session (ending it would only put the next session open
    /// behind the same slow read: seen on the phone, every look in WeChat opened a session that
    /// queued behind the read before); an action is still answered busy, not queued to run late.
    func testAReadThatTimesOutKeepsTheSessionAndTheNextActionIsAnsweredBusyNotRunLate() async {
        let (core, wda, _) = makeCore { $0.readTimeout = 0.5; $0.actionCap = 1 }
        _ = await core.call("look", [:])
        wda.set("GET /source") { _ in try await Task.sleep(nanoseconds: 3_000_000_000); return (200, ["value": .null]) }
        wda.set("GET /wda/locked") { _ in try await Task.sleep(nanoseconds: 3_000_000_000); return (200, ["value": false]) }
        let slow = await core.call("look", [:])
        XCTAssertTrue(slow.text.contains("no element tree"), slow.text)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(wda.sent.contains("DELETE /session"), "a slow read keeps the session: \(wda.sent)")
        // The check whether the runner is free queues behind the slow read (the fake does not queue).
        wda.delay("GET /wda/activeAppInfo", 2)
        let tap = await core.call("do", ["actions": [["tap": [100, 120]]]])
        XCTAssertTrue(tap.text.hasPrefix("not_sent: the runner is still finishing an earlier GET /"), tap.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0, "nothing was queued to run late")
        XCTAssertEqual(wda.sent.filter { $0 == "POST /session" }.count, 1, "the one session stays: \(wda.sent)")
        try? await Task.sleep(nanoseconds: 2_800_000_000)
        wda.source([("Button", "General"), ("Button", "Privacy")])
        wda.set("GET /wda/locked") { _ in (200, ["value": false]) }
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.Preferences", "name": "Settings"]]) }
        let later = await core.call("do", ["actions": [["tap": [100, 120]]]])
        XCTAssertFalse(later.isError, later.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    /// An action that times out ends the session, so what was queued behind it does not run late.
    func testGivingUpOnAnActionEndsTheSession() async {
        let (core, wda, _) = makeCore { $0.actionCap = 1 }
        _ = await core.call("look", [:])
        wda.set("POST /wda/tap") { _ in try await Task.sleep(nanoseconds: 3_000_000_000); return (200, ["value": .null]) }
        let result = await core.call("do", ["actions": [["tap": [100, 120]], ["tap": [100, 160]]]])
        XCTAssertTrue(result.text.contains("may have been delivered"), result.text)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(wda.sent.contains("DELETE /session"), "\(wda.sent)")
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, "the second tap was not queued")
    }

    /// Stop part way through a do (the app's chat cancels the call): the actions after the one under
    /// way are never sent, and settle answers only once the runner is through with that one.
    func testACancelledDoSendsNothingMoreAndSettleWaitsForTheActionUnderWay() async throws {
        let (core, wda, _) = makeCore { $0.actionCap = 10 }
        _ = await core.call("look", [:])
        // The tap runs on until it is released, whatever this side does, and every request queued
        // behind it on the runner waits for it (the fake has no queue of its own).
        let held = LockedBox(true)
        wda.hold("POST /wda/tap", while: held)
        let call = Task { await core.call("do", ["actions": [["tap": [100, 120]], ["tap": [100, 160]], ["tap": [100, 200]]]]) }
        let sent = await eventually(3) { !wda.bodies("POST /wda/tap").isEmpty }
        XCTAssertTrue(sent)
        for route in ["POST /session", "GET /source", "GET /wda/activeAppInfo", "GET /wda/locked", "GET /wda/screen"] { wda.hold(route, while: held) }
        // Settle may be asked before the cancelled request has noted that the runner is busy with it.
        call.cancel()
        let settled = LockedBox<Bool?>(nil)
        let settling = Task { settled.value = await core.settle(timeout: 5) }
        _ = await call.value
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(settled.value, "settled while the tap was still running")
        held.value = false
        await settling.value
        XCTAssertEqual(settled.value, true)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, "the taps after the stop were sent: \(wda.sent)")
    }

    /// WDA's XML tree lists the same elements as its JSON one, without the custom actions it fetches
    /// for every JSON element.
    func testTheXMLTreeReadsLikeTheJSONOne() async {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <AppiumAUT>
          <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="Settings" label="Settings" x="0" y="0" width="390" height="844">
            <XCUIElementTypeWindow type="XCUIElementTypeWindow" x="0" y="0" width="390" height="844">
              <XCUIElementTypeButton type="XCUIElementTypeButton" name="General" label="General &amp; more" x="16" y="100" width="358" height="44"/>
              <XCUIElementTypeSearchField type="XCUIElementTypeSearchField" name="Search" label="Search" value="Wi-Fi" x="16" y="153" width="370" height="37"/>
              <XCUIElementTypeOther type="XCUIElementTypeOther" x="0" y="0" width="0" height="0"/>
            </XCUIElementTypeWindow>
          </XCUIElementTypeApplication>
        </AppiumAUT>
        """
        let parsed = flattenXML(Data(xml.utf8))
        XCTAssertEqual(parsed?.root.label, "Settings")
        XCTAssertEqual(parsed?.elements.map(\.type), ["Window", "Button", "SearchField"])
        XCTAssertEqual(parsed?.elements[1].label, "General & more")
        XCTAssertEqual(parsed?.elements[2].value, "Wi-Fi")
        XCTAssertEqual(parsed?.elements[1].frame, Rect(x: 16, y: 100, width: 358, height: 44))
        XCTAssertEqual(parsed?.elements[0].depth, 1)
        XCTAssertTrue(parsed!.elements[0].contains(parsed!.elements[1]))
        XCTAssertNil(flattenXML(Data("not xml".utf8)))

        let (core, wda, _) = makeCore { $0.treeFormat = "xml" }
        wda.set("GET /source") { _ in (200, ["value": .string(xml)]) }
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("Button \"General & more\" [16,100,358,44]"), look.text)
        XCTAssertTrue(look.text.contains("SearchField \"Search = Wi-Fi\""), look.text)
        XCTAssertTrue(wda.log.contains { $0.path.hasSuffix("/source") }, wda.sent.joined(separator: ", "))
    }

    /// Seen on the phone: launching Photos hit the 6 s action time, since XCTest's launch ends a
    /// running app and starts it again with a handshake that takes seconds. A plain launch now
    /// activates the app (to the front as it is, or started), and a launch gets 9 s.
    func testLaunchActivatesARunningAppAndGetsItsOwnTime() async {
        let (core, wda, _) = makeCore { $0.actionCap = 1 }
        _ = await core.call("look", [:])
        wda.set("POST /wda/apps/activate") { _ in try await Task.sleep(nanoseconds: 1_500_000_000); return (200, ["value": .null]) }
        let result = await core.call("do", ["actions": [["launch": "com.apple.mobileslideshow"]]])
        XCTAssertTrue(result.text.contains("launch com.apple.mobileslideshow (sent"), result.text)
        XCTAssertTrue(wda.sent.contains("POST /wda/apps/activate"), wda.sent.joined(separator: ", "))
        XCTAssertFalse(wda.sent.contains("POST /wda/apps/launch"))
        let fresh = await core.call("do", ["actions": [["launch": ["bundle": "com.apple.mobileslideshow", "fresh": true]]]])
        XCTAssertTrue(fresh.text.contains("(fresh) (sent"), fresh.text)
        XCTAssertTrue(wda.sent.contains("POST /wda/apps/terminate"))
        XCTAssertTrue(wda.sent.contains("POST /wda/apps/launch"))
    }

    /// Seen on the phone: the last selection tap was batched with the Delete, so the whole batch waited
    /// for approval and the Delete, once approved, would have missed a photo. The plain actions before
    /// the first that needs approval go first, and the answer says which to send again.
    func testTheSafePartOfABatchGoesBeforeApprovalIsAsked() async {
        let (core, wda, _) = makeCore()
        wda.source([("Button", "Photo"), ("Button", "Delete")], app: "Photos")
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1], ["tap": 2]]])
        XCTAssertTrue(result.isError, "the requested batch stopped before the approval-gated action")
        XCTAssertTrue(result.text.contains("tap \"Photo\" (sent"), result.text)
        XCTAssertTrue(result.text.contains("not_sent from action 2: approval_required"), result.text)
        XCTAssertTrue(result.text.contains("Actions 1 to 1 were sent"), result.text)
        XCTAssertTrue(result.text.contains("send action 2 again, on their own"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        XCTAssertEqual(core.pendingApproval?.summary, "Tap “Delete”")
        core.resolveApproval(id: core.pendingApproval!.id, approved: true)
        let again = await core.call("do", ["actions": [["tap": 2]]])
        XCTAssertFalse(again.isError, again.text)
        XCTAssertTrue(again.text.contains("approved on the phone"), again.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 2)
    }

    /// Found on the simulator: reads took 2.5 s, longer than a read inside wait_until was allowed, so
    /// "settled" never saw two reads. Each read now gets the runner's time, and settled a second read.
    func testWaitUntilSettledWorksWhenEachReadIsSlow() async {
        let (core, wda, _) = makeCore { $0.readTimeout = 1.5; $0.toolDeadline = 8 }
        _ = await core.call("look", [:])
        let rows: [JSON] = [["type": "XCUIElementTypeButton", "label": "General", "rect": ["x": 16, "y": 100, "width": 358, "height": 44]]]
        let root: JSON = ["type": "XCUIElementTypeApplication", "label": "Settings", "rect": ["x": 0, "y": 0, "width": 390, "height": 844], "children": .array(rows)]
        wda.set("GET /source") { _ in try await Task.sleep(nanoseconds: 900_000_000); return (200, ["value": root]) }
        let result = await core.call("do", ["actions": [["wait_until": ["settled": true, "ms": 500]]]])
        XCTAssertTrue(result.text.contains("wait_until: the screen held still after"), result.text)
    }

    /// The soak on CI (call 101): a look after a timed-out read wanted smaller limits, and setting
    /// them opened a session, which hung; the look waited 3 s on it past its read and answered from
    /// the backstop. The limits go with the next open instead; a look never waits on an open for them.
    func testALookNeverWaitsOnASessionOpenForTheSnapshotLimits() async {
        let (core, wda, _) = makeCore { $0.readTimeout = 1; $0.toolDeadline = 4 }
        _ = await core.call("look", [:])
        wda.delay("GET /source", 2.5)
        let slow = await core.call("look", [:])
        XCTAssertTrue(slow.text.contains("no element tree"), slow.text)
        wda.source([("Button", "General"), ("Button", "Privacy")])
        core.runner.forgetSession()
        wda.delay("POST /session", 10)
        let started = Date()
        let look = await core.call("look", [:])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, look.text)
        XCTAssertTrue(look.text.contains("1 Button"), look.text)
        XCTAssertFalse(look.text.hasPrefix("error:"), look.text)
    }

    /// The gym's 1,507-element grid: the button after the grid was element 1506, past the 1,000
    /// lines full=true lists, so the agent could not tap it by number. A cut listing says what was
    /// left out by type, and scroll_to's answer gives the found element's number.
    func testACutListingSaysWhatWasLeftOutAndScrollToGivesTheNumber() async {
        let (core, wda, _) = makeCore { $0.toolDeadline = 20 }
        let cells = (0..<1_100).map { i in Node("Cell", "Tile \(i)", [Double(i % 10) * 39, 100 + Double(i / 10) * 0.6, 39, 1]) }
        wda.tree([Node("Other", "Grid", [0, 100, 390, 660], cells), Node("Button", "Found", [165, 774, 72, 35])], app: "Gym")
        let look = await core.call("look", ["full": true])
        XCTAssertTrue(look.text.contains("more not listed (Cell "), look.text)
        XCTAssertTrue(look.text.contains("scroll_to with an element's text finds it and gives its number"), look.text)
        XCTAssertFalse(look.text.contains("Button \"Found\""), "the button is past the listing limit: \(look.text.suffix(300))")
        let scroll = await core.call("do", ["actions": [["scroll_to": "Found"]]])
        XCTAssertTrue(scroll.text.contains("0 swipes, found at [165,774,72,35]"), scroll.text)
        guard let line = scroll.text.split(separator: "\n").first(where: { $0.hasPrefix("found by scroll_to:") }) else { return XCTFail(scroll.text) }
        XCTAssertTrue(line.contains("Button \"Found\" [165,774,72,35] (tap "), String(line))
        let number = Int(line.split(separator: " ")[3]) ?? 0
        XCTAssertGreaterThan(number, 1000, String(line))
        let tap = await core.call("do", ["actions": [["tap": .number(Double(number))]]])
        XCTAssertTrue(tap.text.contains("did: tap tap \"Found\" (sent,"), tap.text)
    }

    /// The gym's 300 rows: a swipe sent right after a wait for a busy runner did not move the list
    /// (the app's main loop was serving the snapshot), the next read matched the one before, and
    /// scroll_to declared the end at row 180. Now the end takes two unmoved swipes in a row, each
    /// sent to a free runner; one after a wait does not count.
    func testScrollToDeclaresTheEndOnlyAfterTwoConfirmedUnmovedSwipes() async {
        let (core, wda, _) = makeCore { $0.toolDeadline = 20 }
        _ = await core.call("look", [:])
        wda.source((0..<10).map { ("Cell", "Row \($0)") })
        let result = await core.call("do", ["actions": [["scroll_to": "Nope"]]])
        XCTAssertTrue(result.text.contains("3 swipes, \"Nope\" not found: the list stopped moving"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/pressAndDragWithVelocity").count, 3)
    }

    /// CI simulator (ios-core run 52): a type was refused while the runner was busy, that call's
    /// read failed, and the type sent again with the same number was refused as stale. When nothing
    /// newer was read, the numbers of the read before stand.
    func testTheNumbersStandWhenNothingNewerWasRead() async {
        let (core, wda, _) = makeCore { $0.readTimeout = 0.5; $0.toolDeadline = 4 }
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("1 Button"), look.text)
        wda.delay("GET /source", 5)
        wda.delay("GET /screenshot", 5)
        let failed = await core.call("look", [:])
        XCTAssertTrue(failed.text.contains("the elements of the read before keep their numbers (nothing newer was read)"), failed.text)
        wda.source([("Button", "General"), ("Button", "Privacy")])
        wda.set("GET /screenshot") { _ in (200, ["value": .string(Data("png".utf8).base64EncodedString())]) }
        let tap = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertFalse(tap.text.contains("is not in the latest read"), tap.text)
        XCTAssertTrue(tap.text.contains("did: tap tap \"General\" (sent,"), tap.text)
    }

    /// CI simulator (ios-core run 48): a read took 4.5 s, two did not fit the action's 6 s, and the
    /// wait ran out of its time as "unknown". The read before the call, when fresh, is the first
    /// sample; a wait never runs out as unknown (it sends nothing).
    func testWaitUntilSettledTakesTheFreshReadBeforeItAndNeverEndsUnknown() async {
        let (core, wda, _) = makeCore { $0.readTimeout = 1.5; $0.toolDeadline = 8; $0.actionCap = 3 }
        wda.delay("GET /source", 1.2)
        _ = await core.call("look", [:])
        let started = Date()
        let result = await core.call("do", ["actions": [["wait_until": "settled"]]])
        XCTAssertTrue(result.text.contains("wait_until: the screen held still after"), result.text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "one read, matched against the look before")

        // The screen changed since the read before, and only one slow read fits: the wait says so, and nothing is unknown.
        wda.source([("Button", "Other"), ("Button", "Screen")])
        wda.delay("GET /source", 1.6)
        let changed = await core.call("do", ["actions": [["wait_until": ["settled": true, "ms": 2000]]]])
        XCTAssertTrue(changed.text.contains("wait_until: not seen within") && changed.text.contains("(1 reads)"), changed.text)
        XCTAssertFalse(changed.text.contains("unknown"), changed.text)
    }
}

/// The owner's Mail test on the phone (Nov 6 2026, 10:34 pm ET): a launch sent while the runner was
/// starting had its action time used up before it went; a batch of three plain actions had 6 s for
/// all of them; "Contact photo for Best Buy" was taken for a payment; taps near the top of the screen
/// landed on Poki's Live Activity in the Dynamic Island and opened Poki, where the next taps went.
final class MailTestTests: XCTestCase {
    func testTheRunnersStartIsNotTheActionsTime() async {
        let host = FakeHost()
        host.state.value = .starting("launching")
        let (core, wda, _) = makeCore(host: host) { $0.actionCap = 1; $0.toolDeadline = 5; $0.readTimeout = 1; $0.runnerWait = 4 }
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); host.state.value = .running }
        let result = await core.call("do", ["actions": [["launch": "com.apple.mobilemail"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("launch com.apple.mobilemail (sent"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 1)
    }

    func testEachActionHasItsOwnTime() async {
        let (core, wda, _) = makeCore { $0.actionCap = 0.6; $0.toolDeadline = 6; $0.readTimeout = 1 }
        for key in ["POST /wda/pressButton", "POST /wda/tap", "POST /wda/dragfromtoforduration"] {
            wda.set(key) { _ in try await Task.sleep(nanoseconds: 400_000_000); return (200, ["value": .null]) }
        }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["button": "home"], ["tap": [100, 300]], ["drag": ["from": 1, "to": 2]]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text.components(separatedBy: "(sent, ").count - 1, 3, result.text)
    }

    func testANameInALongerLabelIsNotAPayment() {
        let rules = SensitivityRules()
        let mail = Foreground(bundleID: "com.apple.mobilemail", name: "Mail")
        func reason(_ type: String, _ label: String) -> String? {
            rules.reason(touching: Element(type: type, label: label, value: nil, identifier: nil, frame: Rect(x: 0, y: 0, width: 40, height: 40), depth: 1), typing: false, app: mail, secureOnScreen: false)
        }
        XCTAssertNil(reason("Image", "Contact photo for Best Buy"))
        XCTAssertNil(reason("Cell", "Best Buy, Your order has shipped, Yesterday, Thanks for buying from us"))
        XCTAssertNil(reason("Cell", "PayPal, Receipt for your payment to Chase, Today"))
        XCTAssertEqual(reason("Button", "Buy now"), "a payment (\"buy\")")
        XCTAssertEqual(reason("Button", "Pay $12.00"), "a payment (\"pay\")")
        XCTAssertEqual(reason("Button", "Confirm and pay"), "a payment (\"pay\")")
        XCTAssertEqual(reason("Button", "Delete Message"), "deleting (\"delete\")")
        XCTAssertEqual(reason("Button", "Send"), "sending a message (\"send\")")
        XCTAssertNil(reason("Cell", "Re: Please send the files when you have them, John, Monday"))
    }

    func testTheDynamicIslandIsNeverListed() async {
        let (core, wda, _) = makeCore()
        wda.tree([
            Node("Other", "Working", [150, 12, 90, 36]),
            Node("Other", "Poki", [120, 8, 150, 44]),
            Node("StaticText", "9:41", [30, 20, 50, 20]),
            Node("NavigationBar", "Mailboxes", [0, 62, 390, 44], [Node("Button", "Back", [8, 66, 60, 36]), Node("Button", "Edit", [330, 66, 50, 36])]),
            Node("Cell", "All Inboxes, 257 unread messages", [0, 110, 390, 44]),
        ], app: "Mail")
        let result = await core.call("look", [:])
        XCTAssertFalse(result.text.contains("Working"), result.text)
        XCTAssertFalse(result.text.contains("\"Poki\""), result.text)
        XCTAssertTrue(result.text.contains("Button \"Back\""), result.text)
        XCTAssertTrue(result.text.contains("All Inboxes"), result.text)
        XCTAssertTrue(result.text.contains("9:41"), "the status bar at the sides stays")
    }

    func testATapThatOpensPokiBringsTheAppBack() async {
        let (core, wda, _) = makeCore()
        wda.tree([Node("NavigationBar", "Mailboxes", [0, 62, 390, 44], [Node("Button", "Back", [8, 66, 60, 36])]), Node("Cell", "All Inboxes", [0, 110, 390, 44])], app: "Mail")
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.mobilemail", "name": "Mail"]]) }
        _ = await core.call("look", [:])
        // The tap lands on the Live Activity: Poki comes to the front.
        wda.set("POST /wda/tap") { [wda] _ in
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "nz.zheha.poki", "name": "Poki"]]) }
            return (200, ["value": .null])
        }
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.mobilemail", "name": "Mail"]]) }
            return (200, ["value": .null])
        }
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(result.text.hasPrefix("app: Mail"), result.text)
        XCTAssertTrue(result.text.contains("note: Poki was in front after the actions"), result.text)
        XCTAssertTrue(result.text.contains("Mail was brought back"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").first?["bundleId"]?.string, "com.apple.mobilemail")
        // Working in Poki on purpose is left alone.
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "nz.zheha.poki", "name": "Poki"]]) }
        _ = await core.call("look", [:])
        let inPoki = await core.call("do", ["actions": [["tap": [100, 300]]]])
        XCTAssertFalse(inPoki.text.contains("brought back"), inPoki.text)
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 1)
    }
}

/// The owner's JD and WeChat test on the phone (Nov 7 2026, 12:21 to 12:45 am ET).
final class ShopTestTests: XCTestCase {
    /// The owner's own clipboard went into a shop's search box: iOS asked the owner to allow the
    /// paste, and the owner's clipboard had been put back before they answered.
    func testPasteKeepsTheTextOnTheClipboardUntilItLandsAndChecksItFirst() async {
        let (core, wda, _) = makeCore { $0.actionCap = 4 }
        let field = FaultTests.Field()
        field.install(wda, menu: true)
        // The Paste tap inserts nothing (the owner is being asked): the field stays empty.
        wda.set("POST /wda/tap") { _ in (200, ["value": .null]) }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "83K12S", "via": "paste"]]])
        XCTAssertTrue(result.text.contains("iOS may be asking the owner to allow the paste"), result.text)
        XCTAssertEqual(field.clipboard.value, "83K12S", "the text stays on the clipboard for the owner's answer")
        // The text lands (the owner allowed it): the owner's clipboard goes back.
        field.value.value = "83K12S"
        let restored = await eventually(4) { field.clipboard.value == "owner's clipboard" }
        XCTAssertTrue(restored, "\(String(describing: field.clipboard.value))")
    }

    func testPasteIsRefusedWhenTheClipboardCannotBeSet() async {
        let (core, wda, _) = makeCore()
        let field = FaultTests.Field()
        field.install(wda, menu: true)
        wda.set("POST /wda/setPasteboard") { _ in (200, ["value": .null]) } // the write does not take
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "83K12S", "via": "paste"]]])
        XCTAssertTrue(result.text.contains("the clipboard could not be set to the text"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/touchAndHold").count, 0, "no menu was opened")
        XCTAssertEqual(field.clipboard.value, "owner's clipboard")
    }

    /// The tree showed the inside of a chat while the picture still showed the list.
    func testThePictureIsTakenAgainWhenTheTreeCameLater() async {
        let (core, wda, _) = makeCore { $0.readTimeout = 3 }
        wda.delay("GET /source", 0.9)
        let result = await core.call("look", [:])
        XCTAssertEqual(wda.sent.filter { $0 == "GET /screenshot" }.count, 2, "\(wda.sent)")
        XCTAssertTrue(result.text.contains("the picture was taken again after the tree"), result.text)
    }

    func testTheHomeScreenIsNamedAndANewScreenSaysItsNumbersStartAgain() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.springboard", "name": ""]]) }
        wda.source([("Icon", "Mail"), ("Icon", "Photos"), ("Icon", "Settings")], app: "")
        let home = await core.call("do", ["actions": [["button": "home"]]])
        XCTAssertTrue(home.text.hasPrefix("app: Home screen (SpringBoard"), home.text)
        XCTAssertTrue(home.text.contains("a new screen: numbered from 1 again"), home.text)
    }

    func testATapOnAnElementThatFillsTheScreenSaysSo() async {
        let (core, wda, _) = makeCore()
        wda.tree([Node("Toolbar", "工具栏", [0, 0, 390, 844], [Node("Button", "加购", [300, 780, 80, 44])])], app: "京东")
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(result.text.contains("this element fills the screen, so the tap went to its centre at [195, 422]"), result.text)
    }
}

/// The owner's rule for the gym (Nov 7 2026): while the runner is up and a screenshot works, every
/// answer carries the screen and something to go on; no error answer halts the model.
final class GymTests: XCTestCase {
    func testAFailedActionRetainsItsErrorAndScreenRead() async {
        let (core, wda, _) = makeCore { $0.actionCap = 1 }
        _ = await core.call("look", [:])
        wda.set("POST /wda/tap") { _ in (500, ["value": ["error": "unknown error", "message": "tap failed"]]) }
        let result = await core.call("do", ["actions": [["tap": [100, 120]], ["tap": [100, 160]]]])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("error: action 1 was not sent"), result.text)
        XCTAssertTrue(result.text.contains("elements"), result.text)
        XCTAssertNotNil(result.jpeg)
    }

    func testABusyRunnerAnswersWithThePicture() async {
        let (core, wda, _) = makeCore { $0.readTimeout = 0.5; $0.actionCap = 1 }
        _ = await core.call("look", [:])
        wda.delay("GET /source", 3)
        wda.delay("GET /wda/locked", 3)
        _ = await core.call("look", [:])
        wda.delay("GET /wda/activeAppInfo", 2)
        let tap = await core.call("do", ["actions": [["tap": [100, 120]]]])
        XCTAssertTrue(tap.text.hasPrefix("not_sent: the runner is still finishing"), tap.text)
        XCTAssertNotNil(tap.jpeg, "the screenshot is served apart from the queue")
        XCTAssertFalse(tap.isError)
    }

    func testTypingWaitsForAFieldToBeFocusedAndSaysWhenNoneWas() async {
        let (core, wda, _) = makeCore()
        let field = FaultTests.Field()
        field.install(wda)
        // The keyboard comes up 0.5 s after the tap (a late-focus field).
        field.keyboard.value = false
        wda.set("POST /wda/tap") { [keyboard = field.keyboard] _ in
            Task { try? await Task.sleep(nanoseconds: 500_000_000); keyboard.value = true }
            return (200, ["value": .null])
        }
        _ = await core.call("look", [:])
        let typed = await core.call("do", ["actions": [["type": "abc", "ref": 1]]])
        XCTAssertTrue(typed.text.contains("the field now reads \"abc\""), typed.text)
        XCTAssertFalse(typed.text.contains("no field was focused"), typed.text)
        XCTAssertFalse(wda.sent.contains("GET /element/active"), "focus is read from the tree, never asked of the runner")
        field.keyboard.value = false
        wda.set("POST /wda/tap") { _ in (200, ["value": .null]) }
        // No keyboard and the keys went nowhere: the note stands.
        wda.set("POST /wda/keys") { _ in (200, ["value": .null]) }
        let none = await core.call("do", ["actions": [["type": "xyz"]]])
        XCTAssertTrue(none.text.contains("no field was focused when the text went"), none.text)
    }

    func testClearIsCheckedAndDoneAgainWhenSomethingIsLeft() async {
        let (core, wda, _) = makeCore()
        let field = FaultTests.Field()
        field.install(wda)
        field.value.value = "old text"
        // The deletes remove nothing (the cursor sits at the start); the element clear works.
        wda.set("POST /wda/keys") { [value = field.value] body in
            for key in body?["value"]?.array ?? [] where key.string != "\u{8}" { value.update { $0 += key.string ?? "" } }
            return (200, ["value": .null])
        }
        _ = await core.call("look", [:])
        let typed = await core.call("do", ["actions": [["type": "new", "clear": true]]])
        XCTAssertTrue(typed.text.contains("clear: the field still held \"old textnew\" after 8 deletes, so 11 more deletes and the text were sent again"), typed.text)
        XCTAssertTrue(typed.text.contains("the field now reads \"old textnewnew\""), typed.text)
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 2)
    }

    func testBackTapsTheTopLeftButtonOrSwipesFromTheEdge() async {
        let (core, wda, _) = makeCore()
        wda.tree([Node("NavigationBar", "General", [0, 44, 390, 44], [Node("Button", "Settings", [8, 50, 80, 32]), Node("StaticText", "General", [160, 50, 70, 32])]), Node("Cell", "About", [16, 100, 358, 44])], app: "Settings")
        _ = await core.call("look", [:])
        let back = await core.call("do", ["actions": [["back": true]]])
        XCTAssertTrue(back.text.contains("back: tapped the top-left button \"Settings\" at [48, 66]"), back.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        wda.tree([Node("Cell", "A chat", [16, 100, 358, 44])], app: "WeChat")
        _ = await core.call("look", [:])
        let swipe = await core.call("do", ["actions": [["back": true]]])
        XCTAssertTrue(swipe.text.contains("back: no back button was listed in the top left, so an edge swipe from the left was sent"), swipe.text)
        let drag = wda.bodies("POST /wda/dragfromtoforduration").last ?? wda.bodies("POST /wda/pressAndDragWithVelocity").last
        XCTAssertEqual(drag?["fromX"]?.double, 2)
    }

    func testTheSameElementTwiceIsListedOnce() async {
        let (core, wda, _) = makeCore()
        wda.tree([Node("Button", "Twin", [100, 300, 100, 44]), Node("Button", "Twin", [100, 300, 100, 44]), Node("Button", "Other", [100, 400, 100, 44])], app: "Gym")
        let look = await core.call("look", [:])
        XCTAssertEqual(look.text.components(separatedBy: "\"Twin\"").count - 1, 1, look.text)
        XCTAssertTrue(look.text.contains("elements (2)"), look.text)
    }

    /// A snapshot the runner refuses at once (the app's main loop was busy for the moment) is asked
    /// for again within the read's time; the model gets a tree, not a picture-only read.
    func testARefusedTreeIsAskedForAgainWithinTheRead() async {
        let (core, wda, _) = makeCore { $0.readTimeout = 3 }
        let tries = LockedBox(0)
        let good = LockedBox<FakeWDA.Route?>(nil)
        wda.source([("Button", "General")])
        wda.set("GET /source") { body in
            let n = tries.update { $0 += 1; return $0 }
            if n == 1 { return (500, ["value": ["error": "unknown error", "message": "The application with process identifier 42 did not confirm its main run loop is responsive within 2.0 second(s)"]]) }
            return (200, ["value": ["type": "XCUIElementTypeApplication", "label": "Settings", "rect": ["x": 0, "y": 0, "width": 390, "height": 844], "children": [["type": "XCUIElementTypeButton", "label": "General", "rect": ["x": 16, "y": 100, "width": 358, "height": 44]]]]])
        }
        _ = good
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("the element tree came on the second try"), look.text)
        XCTAssertTrue(look.text.contains("\"General\""), look.text)
        XCTAssertEqual(tries.value, 2)
    }

    /// A step handed to the owner: the Live Activity gets the event, inputs are held (with the
    /// picture), looks work, Done or a take-back ends it and the next answer says so once.
    func testAHandoffHoldsInputsUntilTheOwnerIsDone() async {
        let (core, wda, _) = makeCore()
        let events = LockedBox<[CoreEvent]>([])
        Task { for await e in core.events { events.update { $0.append(e) } } }
        _ = await core.call("look", [:])
        let handed = await core.call("do", ["actions": [["handoff": ["kind": "password", "text": "Enter your Apple ID password"]]]])
        XCTAssertFalse(handed.isError, handed.text)
        XCTAssertTrue(handed.text.contains("handed to the owner (password): \"Enter your Apple ID password\""), handed.text)
        XCTAssertTrue(handed.text.contains("handoff: waiting (password) since"), handed.text)
        var id: String?
        let asked = await eventually { events.value.contains { if case .handoffRequested(let i, "password", "Enter your Apple ID password", _) = $0 { id = i; return true }; return false } }
        XCTAssertTrue(asked, "\(events.value)")
        let held = await core.call("do", ["actions": [["tap": [100, 120]]]])
        XCTAssertTrue(held.text.hasPrefix("not_sent: a step is handed to the owner (password"), held.text)
        XCTAssertNotNil(held.jpeg)
        XCTAssertFalse(held.isError)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0)
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("handoff: waiting (password)"), look.text)
        let status = await core.call("status", [:])
        XCTAssertTrue(status.text.contains("handoff: waiting (password) since"), status.text)
        let waited = await core.call("do", ["actions": [["wait_until": ["handoff_done": true, "ms": 400]]]])
        XCTAssertTrue(waited.text.contains("the owner is not done yet"), waited.text)
        core.handoffDone(id: id ?? "")
        let ended = await eventually { events.value.contains(.handoffEnded(id: id ?? "", how: "done")) }
        XCTAssertTrue(ended)
        let after = await core.call("do", ["actions": [["tap": [100, 120]]]])
        XCTAssertTrue(after.text.contains("handoff: done at"), after.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        let later = await core.call("look", [:])
        XCTAssertFalse(later.text.contains("handoff:"), "reported once: \(later.text)")
        // A take-back.
        let second = await core.call("do", ["actions": [["handoff": "Check out yourself"]]])
        XCTAssertTrue(second.text.contains("handed to the owner (other)"), second.text)
        let back = await core.call("do", ["actions": [["handoff": false]]])
        XCTAssertTrue(back.text.contains("handoff: taken back (other"), back.text)
        let taken = await eventually { events.value.contains { if case .handoffEnded(_, "takenBack") = $0 { return true }; return false } }
        XCTAssertTrue(taken)
    }

    func testAStartingRunnerIsNotAnErrorAnswer() async {
        let (core, _, host) = makeCore { $0.runnerWait = 0.3; $0.readTimeout = 0.5 }
        host.state.value = .starting("the phone is asking the owner for the passcode")
        let look = await core.call("look", [:])
        XCTAssertFalse(look.isError, look.text)
        XCTAssertTrue(look.text.contains("runner: starting (the phone is asking the owner for the passcode)"), look.text)
        XCTAssertTrue(look.text.contains("call look or status again every few seconds"), look.text)
    }

    func testABusyGateAnswersWithThePicture() async {
        let (core, wda, _) = makeCore { $0.busyWait = 0.2 }
        _ = await core.call("look", [:])
        wda.delay("GET /source", 1.5)
        async let slow = core.call("look", [:])
        try? await Task.sleep(nanoseconds: 200_000_000)
        let busy = await core.call("look", [:])
        XCTAssertTrue(busy.text.hasPrefix("busy: another call is still running"), busy.text)
        XCTAssertNotNil(busy.jpeg)
        XCTAssertFalse(busy.isError)
        _ = await slow
    }

    func testATapOnAContainerNamesTheElementsInsideIt() async {
        let (core, wda, _) = makeCore()
        wda.tree([Node("Alert", "Gym alert", [20, 300, 350, 200], [Node("StaticText", "An alert on top of the screen.", [40, 320, 310, 40]), Node("Button", "Cancel", [40, 440, 150, 44]), Node("Button", "OK", [200, 440, 150, 44])])], app: "Gym")
        let look = await core.call("look", [:])
        guard let n = look.text.split(separator: "\n").first(where: { $0.contains("Alert") })?.trimmingCharacters(in: .whitespaces).split(separator: " ").first.flatMap({ Int($0) }) else { return XCTFail(look.text) }
        let tap = await core.call("do", ["actions": [["tap": .number(Double(n))]]])
        XCTAssertTrue(tap.text.contains("this element is a Alert, a container; the elements inside it are"), tap.text)
        XCTAssertTrue(tap.text.contains("\"Cancel\"") && tap.text.contains("\"OK\"") && tap.text.contains("tap one of those"), tap.text)
    }

    /// The gym's dense screen hung the app's main loop: WDA's queue held one GET /wda/activeAppInfo
    /// for over a minute while its status answered, so nothing restarted it. Now a stall older than
    /// `wedgedAfter` with a queued probe unanswered restarts the runner, and the next call says so.
    func testAWedgedRunnerIsRestartedAndTheNextCallSaysWhy() async {
        let (core, wda, host) = makeCore { $0.readTimeout = 0.5; $0.actionCap = 1 }
        core.runner.wedgedAfter = 0.6
        _ = await core.call("look", [:])
        // Every queued request waits behind the hung one (the fake has no queue of its own).
        for route in ["GET /source", "GET /wda/activeAppInfo", "GET /screenshot", "POST /appium/settings", "POST /session"] { wda.delay(route, 30) }
        _ = await core.call("look", [:])
        let stuck = await core.call("look", [:])
        XCTAssertTrue(stuck.text.contains("still finishing an earlier") && stuck.text.contains("restarted on its own if it is not through"), stuck.text)
        XCTAssertNotNil(core.runner.busyWith)
        // 0.6 s stall + a 3 s probe that is not answered: the runner is restarted (within 8 s; a
        // loaded CI runner is slower, and the stuck look above answers at once now).
        for _ in 0..<80 where host.restarts.value == 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(host.restarts.value, 1, "the wedged runner was restarted")
        XCTAssertNil(core.runner.busyWith, "the stall went with the old runner")
        XCTAssertTrue(core.runner.lastRestart.value?.contains("wedged on ") ?? false, core.runner.lastRestart.value ?? "nil")
        // The new runner answers; the first call says what happened, once.
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.Preferences", "name": "Settings"]]) }
        wda.set("GET /screenshot") { _ in (200, ["value": .string(Data("png".utf8).base64EncodedString())]) }
        wda.set("POST /appium/settings") { _ in (200, ["value": .null]) }
        wda.set("POST /session") { _ in (200, ["value": ["sessionId": "s2"]]) }
        wda.source([("Button", "General"), ("Button", "Privacy")])
        let after = await core.call("look", [:])
        XCTAssertTrue(after.text.hasPrefix("runner: the runner wedged on "), after.text)
        XCTAssertTrue(after.text.contains("this is the new runner"), after.text)
        XCTAssertFalse(after.isError)
        let again = await core.call("look", [:])
        XCTAssertFalse(again.text.contains("wedged"), "reported once: \(again.text)")
    }

    /// A stall is bookkeeping about one runner process: a refused connection, or a runner the app
    /// is seen restarting, clears it (seen in the gym: the first do after a restart still waited on
    /// the old runner's request).
    func testAStallDoesNotOutliveTheRunner() async {
        let (core, wda, host) = makeCore { $0.readTimeout = 0.5; $0.actionCap = 1 }
        core.runner.wedgedAfter = 60
        _ = await core.call("look", [:])
        wda.delay("GET /source", 30)
        _ = await core.call("look", [:])
        XCTAssertNotNil(core.runner.busyWith)
        wda.set("GET /status") { _ in throw TransportError.refused }
        _ = try? await core.runner.raw("GET", "/status", timeout: 1)
        XCTAssertNil(core.runner.busyWith, "refused: the process is gone")

        wda.set("GET /status") { _ in (200, ["value": ["ready": true]]) }
        _ = await core.call("look", [:])
        XCTAssertNotNil(core.runner.busyWith)
        host.state.value = .starting("relaunching")
        Task { try? await Task.sleep(nanoseconds: 300_000_000); host.state.value = .running }
        wda.source([("Button", "General")])
        let after = await core.call("look", [:])
        XCTAssertNil(core.runner.busyWith, "a restart seen clears it: \(after.text)")
        XCTAssertTrue(after.text.contains("General"), after.text)
    }

    /// 200 rows outran the action's time: the scroll stops in time and says how far it got and that
    /// calling it again goes on, instead of "may have been delivered".
    func testAScrollThatOutrunsTheActionsTimeSaysHowFarItGot() async {
        let (core, wda, _) = makeCore { $0.actionCap = 3 }
        _ = await core.call("look", [:])
        let swipes = LockedBox(0)
        wda.set("POST /wda/pressAndDragWithVelocity") { [wda] _ in
            try await Task.sleep(nanoseconds: 700_000_000)
            let n = swipes.update { $0 += 1; return $0 }
            wda.source((0..<10).map { ("Cell", "Row \(n * 10 + $0)") })
            return (200, ["value": .null])
        }
        let result = await core.call("do", ["actions": [["scroll_to": ["text": "Row 250", "max_swipes": 12]]]])
        XCTAssertFalse(result.text.contains("may have been delivered"), result.text)
        XCTAssertTrue(result.text.contains("\"Row 250\" not seen yet; the action's time ran out"), result.text)
        XCTAssertTrue(result.text.contains("call scroll_to again to go on"), result.text)
        XCTAssertTrue(result.text.contains("(sent,"), result.text)
        XCTAssertFalse(result.isError)
    }

    /// A host with its own way to the screen (the launcher's tunnel) gives the picture when the
    /// runner cannot, so a hung app never blinds the model.
    func testTheHostsOwnScreenshotIsUsedWhenTheRunnerGivesNone() async {
        let host = FakeHost()
        host.ownScreenshot.value = Data("own-png".utf8)
        let (core, wda, _) = makeCore(host: host) { $0.readTimeout = 0.5 }
        _ = await core.call("look", [:])
        wda.delay("GET /screenshot", 30)
        let look = await core.call("look", [:])
        XCTAssertEqual(look.jpeg, Data("jpeg:7".utf8), look.text)
        XCTAssertTrue(look.text.contains("screenshot: taken apart from the runner"), look.text)
        XCTAssertFalse(look.isError)
    }

    /// The gym's 1,500-cell screen: the full-depth tree timed out at 4 s twice and the look answered
    /// nothing; now the read goes on at half depth within the same call.
    func testATimedOutTreeIsReadAgainShallowerWithinTheCall() async {
        let (core, wda, _) = makeCore { $0.toolDeadline = 14; $0.readTimeout = 1 }
        _ = await core.call("look", [:])
        let shallow = LockedBox(false)
        wda.set("POST /appium/settings") { body in
            if body?["settings"]?["snapshotMaxChildren"]?.double == 150 { shallow.value = true }
            return (200, ["value": .null])
        }
        let root: JSON = ["type": "XCUIElementTypeApplication", "label": "Settings", "rect": ["x": 0, "y": 0, "width": 390, "height": 844], "children": .array([
            ["type": "XCUIElementTypeCell", "label": "Row 1", "rect": ["x": 16, "y": 100, "width": 358, "height": 44]],
        ])]
        wda.set("GET /source") { _ in
            if shallow.value { return (200, ["value": root]) }
            try await Task.sleep(nanoseconds: 2_500_000_000)
            return (200, ["value": root])
        }
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("Row 1"), look.text)
        XCTAssertTrue(look.text.contains("so it was read again with at most 150 children per element within this call; only the first 150 children of each element are listed"), look.text)
        XCTAssertFalse(look.isError)
    }

    /// A WKWebView whose page is not in the tree is listed all the same, as [collapsed], with the
    /// picture's text inside it in every look.
    func testAWebViewWithNothingInTheTreeIsListedWithThePicturesText() async {
        let host = FakeHost()
        host.texts.value = [RecognizedText(text: "A web page", box: Rect(x: 0.1, y: 0.2, width: 0.5, height: 0.04)), RecognizedText(text: "Open", box: Rect(x: 0.1, y: 0.3, width: 0.2, height: 0.04))]
        let (core, wda, _) = makeCore(host: host)
        wda.tree([
            Node("NavigationBar", "Page", [0, 60, 390, 44], [Node("StaticText", "Page", [150, 70, 90, 20])]),
            Node("WebView", nil, [0, 104, 390, 740]),
        ], app: "Gym")
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("WebView \"web page (its parts are not in the tree yet: read again in a second)\" [0,104,390,740] [collapsed]"), look.text)
        XCTAssertTrue(look.text.contains("\"A web page\"") && look.text.contains("\"Open\""), look.text)
        XCTAssertTrue(look.text.contains("(read from the picture)"), look.text)
    }

    /// The gym's 300-row list: two swipes fit the 6 s an action had. scroll_to now has 12 s, and
    /// still reads after every swipe (a blind swipe can carry the target past the screen).
    func testScrollToHasTwelveSecondsAndReadsAfterEverySwipe() async {
        let (core, wda, _) = makeCore { $0.actionCap = 3; $0.toolDeadline = 20 }
        _ = await core.call("look", [:])
        let swipes = LockedBox(0)
        wda.set("POST /wda/pressAndDragWithVelocity") { [wda] _ in
            let n = swipes.update { $0 += 1; return $0 }
            wda.source((0..<10).map { ("Cell", "Row \(n * 10 + $0)") })
            return (200, ["value": .null])
        }
        wda.delay("POST /wda/pressAndDragWithVelocity", 1.0)
        let started = Date()
        let result = await core.call("do", ["actions": [["scroll_to": "Row 45"]]])
        XCTAssertTrue(result.text.contains("scroll_to \"Row 45\": 4 swipes, found at [16,320,358,44]"), result.text)
        XCTAssertTrue(result.text.contains("found by scroll_to:") && result.text.contains("Cell \"Row 45\" [16,320,358,44] (tap "), result.text)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 3.5, "four 1 s swipes outlast the 3 s action cap: scroll_to has 12 s")
        XCTAssertTrue(wda.bodies("POST /wda/pressAndDragWithVelocity").allSatisfy { $0["holdDuration"]?.double == 0.25 }, "a drag with a slow tail before the lift")
    }

    /// 300 rows in the gym: a swipe sent while the runner was still serving the read after the last
    /// one queued behind it, timed out, and the whole scroll came back unknown. Now the runner is
    /// waited for, and a swipe it did not confirm ends the scroll with its progress.
    func testScrollToNeverEndsUnknownWhenTheRunnerFallsBehind() async {
        let (core, wda, _) = makeCore { $0.actionCap = 3; $0.toolDeadline = 20; $0.readTimeout = 0.5 }
        _ = await core.call("look", [:])
        let swipes = LockedBox(0)
        wda.set("POST /wda/pressAndDragWithVelocity") { [wda] _ in
            let n = swipes.update { $0 += 1; return $0 }
            if n == 2 { try await Task.sleep(nanoseconds: 9_000_000_000) }
            wda.source((0..<10).map { ("Cell", "Row \(n * 10 + $0)") })
            return (200, ["value": .null])
        }
        let result = await core.call("do", ["actions": [["scroll_to": "Row 250"]]])
        XCTAssertFalse(result.text.contains("unknown"), result.text)
        XCTAssertTrue(result.text.contains("1 swipes, \"Row 250\" not seen yet; the runner did not confirm the last swipe in time"), result.text)
        XCTAssertTrue(result.text.contains("(sent,"), result.text)

        // A read the runner is still serving: the next scroll_to waits for it, and says so when it is not through.
        wda.set("POST /wda/pressAndDragWithVelocity") { _ in (200, ["value": .null]) }
        wda.delay("GET /source", 6)
        wda.delay("GET /wda/activeAppInfo", 6)
        _ = await core.call("look", [:])
        let again = await core.call("do", ["actions": [["scroll_to": "Row 250"]]])
        XCTAssertTrue(again.text.contains("not_sent") || again.text.contains("still finishing"), again.text)
    }

    /// The gym's 300 rows again: seven scroll_to calls each swiped once, their reads after the swipe
    /// never came, and row 250 was scrolled past unseen before the eighth call read rows 260-264,
    /// so the scroll ran to the end and said not found. Now a swipe no read has shown is read
    /// before anything is swiped again, in this call or the next, so a target cannot pass between
    /// two reads however late they come.
    func testScrollToReadsAnUnreadSwipeBeforeItSwipesAgain() async {
        let (core, wda, _) = makeCore { $0.toolDeadline = 20; $0.readTimeout = 0.5 }
        let slow = LockedBox(false), swipes = LockedBox(0), rows = LockedBox(0)
        @Sendable func page(_ n: Int) -> JSON {
            let children: [JSON] = (0..<10).map { i in
                ["type": "XCUIElementTypeCell", "label": .string("Row \(n * 10 + i)"), "rect": ["x": 16, "y": .number(Double(100 + i * 44)), "width": 358, "height": 44]]
            }
            return ["value": ["type": "XCUIElementTypeApplication", "label": "Settings", "rect": ["x": 0, "y": 0, "width": 390, "height": 844], "children": .array(children)]]
        }
        wda.set("GET /source") { _ in
            if slow.value { try await Task.sleep(nanoseconds: 5_000_000_000) }
            return (200, page(rows.value))
        }
        wda.set("POST /wda/pressAndDragWithVelocity") { _ in
            rows.value = swipes.update { $0 += 1; return $0 }
            return (200, ["value": .null])
        }
        _ = await core.call("look", [:])
        slow.value = true
        let first = await core.call("do", ["actions": [["scroll_to": "Row 60"]]])
        XCTAssertEqual(swipes.value, 1, first.text)
        XCTAssertTrue(first.text.contains("1 swipes, \"Row 60\" not seen yet; the read after the last swipe did not come; nothing is swiped again until it has"), first.text)
        XCTAssertTrue(first.text.contains("keep their numbers"), first.text)
        // Still slow: the next call reads first and, with no read, swipes nothing.
        let second = await core.call("do", ["actions": [["scroll_to": "Row 60"]]])
        XCTAssertEqual(swipes.value, 1, "no swipe on top of an unread one: \(second.text)")
        XCTAssertTrue(second.text.contains("0 swipes, \"Row 60\" not seen yet; the r"), second.text)
        XCTAssertFalse(second.text.contains("(unknown"), second.text)
        // Reads come again: the unread swipe's rows (10-19) are read before the swipes go on.
        slow.value = false
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let third = await core.call("do", ["actions": [["scroll_to": "Row 60"]]])
        XCTAssertEqual(swipes.value, 6, third.text)
        XCTAssertTrue(third.text.contains("5 swipes, found at [16,100,358,44]"), third.text)
        XCTAssertTrue(third.text.contains("found by scroll_to:") && third.text.contains("Cell \"Row 60\""), third.text)
        XCTAssertTrue(wda.sent.firstIndex(of: "GET /source").map { _ in true } ?? false)
    }

    /// The gym's 300-row list under a flick: three swipes went from item 104 to 184 (26 rows a swipe
    /// on a 15-row screen), so item 150 was never on screen between two reads. scroll_to now drags
    /// with a rest (the list stops under the finger), and when a read shares nothing with the read
    /// before, a short drag back follows before the scroll goes on.
    func testScrollToDragsBackWhenTheListMovedMoreThanAScreen() async {
        let (core, wda, _) = makeCore { $0.toolDeadline = 20 }
        let offset = LockedBox(0)
        let drags = LockedBox<[(Double, Double, Double, Double)]>([])
        func show() { wda.source((0..<10).map { ("Cell", "Row \(offset.value + $0)") }) }
        wda.set("POST /wda/pressAndDragWithVelocity") { body in
            let from = body?["fromY"]?.double ?? 0, to = body?["toY"]?.double ?? 0
            drags.update { $0.append((body?["fromX"]?.double ?? 0, from, body?["toX"]?.double ?? 0, to)) }
            // A finger going up moves the list 26 rows (momentum); the short one back, 7.
            offset.update { $0 += to < from ? 26 : -7 }
            show()
            return (200, ["value": .null])
        }
        show()
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["scroll_to": "Row 20"]]])
        XCTAssertTrue(result.text.contains("2 swipes, found at"), result.text)
        XCTAssertTrue(result.text.contains("the list moved more than a screen after 1 swipe, so a short drag back followed each"), result.text)
        XCTAssertTrue(result.text.contains("found by scroll_to:") && result.text.contains("\"Row 20\""), result.text)
        let sent = drags.value
        XCTAssertEqual(sent.count, 2)
        XCTAssertLessThan(sent[0].3, sent[0].1, "the first drag goes up")
        XCTAssertGreaterThan(sent[1].3, sent[1].1, "the corrective drag goes down")
        XCTAssertLessThan(abs(sent[1].3 - sent[1].1), abs(sent[0].3 - sent[0].1), "the drag back is the shorter")
        let bodies = wda.bodies("POST /wda/pressAndDragWithVelocity")
        XCTAssertEqual(bodies.first?["holdDuration"]?.double, 0.25, "a drag with a slow tail before the lift, not a flick")
        XCTAssertGreaterThan(abs((bodies.first?["toY"]?.double ?? 0) - (bodies.first?["fromY"]?.double ?? 0)), 500, "a long drag (72 % of the list's area), not 60 %")
    }

    /// Settings' search field: the keyboard came after the focus wait, and the text had landed, but
    /// the answer said it may have gone nowhere. The note stands only when the text did not read back.
    func testAFocusNoteIsDroppedWhenTheTextReadBack() async {
        let (core, wda, _) = makeCore()
        let field = FaultTests.Field()
        field.keyboard.value = false
        field.install(wda)
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "hello", "ref": 1]]])
        XCTAssertTrue(result.text.contains("the field now reads \"hello\""), result.text)
        XCTAssertFalse(result.text.contains("may have gone nowhere"), result.text)
    }

    /// Settings replaces its search field in search mode: the old number is gone and a new field is
    /// listed. The read after the type names the field's new number.
    func testTheReadAfterATypeNamesTheReplacedField() async {
        let (core, wda, _) = makeCore()
        wda.tree([Node("SearchField", "Search", [16, 64, 306, 37]), Node("Button", "General", [20, 322, 362, 44])], app: "Settings")
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("1 SearchField \"Search\""), look.text)
        wda.set("POST /wda/keys") { [wda] _ in
            wda.tree([Node("Keyboard", nil, [0, 500, 390, 344]), Node("SearchField", "Search", [16, 64, 306, 37], value: "Wi-Fi 网络"), Node("Button", "Cancel", [333, 66, 53, 31]), Node("Button", "General", [20, 322, 362, 44])], app: "Settings")
            return (200, ["value": .null])
        }
        let result = await core.call("do", ["actions": [["type": "Wi-Fi 网络", "ref": 1]]])
        XCTAssertTrue(result.text.contains("the field now reads \"Wi-Fi 网络\""), result.text)
        guard let line = result.text.split(separator: "\n").first(where: { $0.hasPrefix("the field typed into is now element ") }) else { return XCTFail(result.text) }
        XCTAssertTrue(line.contains("(1 is gone: the app replaced the field)"), String(line))
    }

    /// Photos' Library button ran past the bottom of the screen: the tap went to the screen's very
    /// edge, the point of it nearest its centre. Now the centre of its visible part is tapped.
    func testAnElementCutByTheScreenIsTappedAtTheCentreOfItsVisiblePart() async {
        let (core, wda, _) = makeCore()
        wda.tree([Node("Button", "Library", [0, 700, 390, 600])], app: "Photos")
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])
        let body = wda.bodies("POST /wda/tap").last
        XCTAssertEqual(body?["x"]?.double, 195, result.text)
        XCTAssertEqual(body?["y"]?.double, 772, result.text)
        XCTAssertTrue(result.text.contains("its centre is off the screen, so the centre of its visible part was tapped"), result.text)
    }

    /// Gym: a call measured 25.5 s at the driver against a took: line of 9.2 s. The MCP now
    /// accounts for its own time around the tool: here a look that waited for a do to finish.
    func testTheMCPAccountsForTheTimeAroundTheTool() async {
        let (core, wda, _) = makeCore { $0.busyWait = 6 }
        wda.tree([Node("StaticText", "Hello", [20, 100, 200, 40])], app: "Notes")
        _ = await core.call("look", [:])
        async let first = core.call("do", ["actions": [["wait_until": ["text": "Never", "ms": 3000]]]])
        await sleep(seconds: 0.3)
        let second = await core.call("look", [:])
        _ = await first
        XCTAssertTrue(second.text.contains("at the MCP: "), second.text)
        XCTAssertTrue(second.text.contains("s waiting for the call before to finish"), second.text)
        XCTAssertFalse(second.text.contains("busy: another call"), second.text)
    }

    /// Gym: "example.com" + the Go key never navigated in Safari (3/3), "https://example.com/" did.
    func testATypeOfABareHostIntoSafarisAddressFieldSaysToAddTheScheme() async {
        let (core, wda, _) = makeCore()
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.mobilesafari", "name": "Safari"]]) }
        let field = FaultTests.Field()
        field.install(wda)
        _ = await core.call("look", [:])
        let bare = await core.call("do", ["actions": [["type": "example.com", "ref": 1]]])
        XCTAssertTrue(bare.text.contains("a bare host in Safari's address field: the Go key did not open it in tests, so type it with its scheme (\"https://example.com\")"), bare.text)
        let full = await core.call("do", ["actions": [["type": "https://example.com/", "ref": 1, "clear": true]]])
        XCTAssertFalse(full.text.contains("a bare host"), full.text)
    }

    /// Gym: a scroll's drag started on Safari's address capsule and opened the tab overview; four
    /// more swipes then "stopped moving". The drag now starts above anything wide at the bottom,
    /// and a swipe whose read shows another screen ends the scroll and says so.
    func testScrollToStartsAboveTheBottomChromeAndStopsWhenASwipeChangedTheScreen() async {
        let (core, wda, _) = makeCore()
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.mobilesafari", "name": "Safari"]]) }
        let page: [Node] = [
            Node("WebView", nil, [0, 100, 390, 744], (0..<6).map { Node("StaticText", "Paragraph \($0)", [20, Double(120 + $0 * 90), 350, 60]) }),
            Node("Image", "capsule_with_toolbar_shadow", [-30, 689, 462, 163]),
            Node("Other", "CapsuleNavigationBar", [28, 748, 346, 45], [Node("Button", "Tabs", [320, 752, 40, 40])]),
            Node("Button", "Back", [20, 800, 40, 40]), Node("Button", "Share", [180, 800, 40, 40]), Node("Button", "Bookmarks", [260, 800, 40, 40]),
        ]
        let overview: [Node] = [Node("TextView", "TabOverview", [0, 60, 390, 700]), Node("Button", "Example Domain", [67, 62, 268, 401]), Node("Button", "Close", [320, 70, 40, 40]), Node("Button", "Done", [330, 790, 50, 40]), Node("Button", "New Tab", [170, 790, 50, 40])]
        wda.tree(page, app: "Safari")
        let drags = LockedBox<[(Double, Double)]>([])
        wda.set("POST /wda/pressAndDragWithVelocity") { body in
            drags.update { $0.append((body?["fromY"]?.double ?? 0, body?["toY"]?.double ?? 0)) }
            wda.tree(overview, app: "Safari")
            return (200, ["value": .null])
        }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["scroll_to": "Learn more"]]])
        XCTAssertEqual(drags.value.count, 1, result.text)
        XCTAssertLessThan(drags.value.first?.0 ?? 999, 689, "the drag starts above the capsule's shadow: \(result.text)")
        XCTAssertGreaterThan(drags.value.first?.0 ?? 0, 400, "and still low in the page: \(result.text)")
        XCTAssertTrue(result.text.contains("1 swipes, \"Learn more\" not found: the last swipe changed the screen (it shows TextView \"TabOverview\", Button \"Example Domain\", Button \"Close\"): the list is gone, so the scroll stopped"), result.text)
        XCTAssertFalse(result.text.contains("stopped moving"), result.text)
    }

    /// The in-process path moved a whole screen on a 72 % drag (gym: 2x slower scroll_to, a drag back
    /// after every swipe). Every scroll_to answer now says how far the list moved on each swipe, from
    /// the rows the reads share, so the path's drag can be measured without a probe.
    func testScrollToSaysHowFarEachSwipeMovedTheList() async {
        let (core, wda, _) = makeCore()
        let shift = LockedBox(0.0)
        @Sendable func rows() -> [Node] { [Node("Table", nil, [0, 100, 390, 744], (0..<60).map { Node("Cell", "Row \($0)", [16, Double(100 + $0 * 44) - shift.value, 358, 44]) })] }
        wda.tree(rows(), app: "Gym")
        wda.set("POST /wda/pressAndDragWithVelocity") { _ in
            shift.update { $0 += 400 }
            wda.tree(rows(), app: "Gym")
            return (200, ["value": .null])
        }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["scroll_to": "Row 30"]]])
        XCTAssertTrue(result.text.contains("2 swipes, found at"), result.text)
        XCTAssertTrue(result.text.contains("(the list moved 400, 400 pt on the swipes)"), result.text)
        XCTAssertFalse(result.text.contains("more than a screen"), result.text)
        let drag = wda.bodies("POST /wda/pressAndDragWithVelocity").first
        XCTAssertEqual(drag?["w3c"]?.bool, true, "the scroll's drag goes as W3C actions with a slow tail: \(String(describing: drag))")
    }

    /// The gym's list on WebDriverAgent: a 482 pt drag moved the list 762 pt (17 rows for 15 on
    /// screen), and the title and the status line inside the area made every read share something,
    /// so the overshoot was never seen and the movement read 0. Now the still elements are chrome:
    /// the overshoot is caught, a short drag back follows, and the figure is the rows' shift.
    func testStillChromeInsideTheListAreaDoesNotHideAnOvershoot() async {
        let (core, wda, _) = makeCore()
        let shift = LockedBox(0.0)
        @Sendable func screen() -> [Node] {
            [Node("NavigationBar", "_TtGC7SwiftUI32NavigationStackHosting", [0, 56, 390, 45], [Node("Button", "Menu", [16, 64, 51, 29])]),
             Node("StaticText", "Gym: list", [156, 108, 90, 27]),
             Node("Table", nil, [0, 134, 390, 675], (0..<300).map { Node("Button", "Row \($0 + 1)", [20, Double(169 + $0 * 44) - shift.value, 362, 45]) }),
             Node("Other", "Vertical scroll bar, 20 pages", [369, 134, 30, 675]),
             Node("StaticText", "state: ready", [0, 808, 390, 66])]
        }
        wda.tree(screen(), app: "Gym")
        wda.set("POST /wda/pressAndDragWithVelocity") { body in
            let up = (body?["fromY"]?.double ?? 0) > (body?["toY"]?.double ?? 0)
            shift.update { $0 += up ? 762 : -300 }
            wda.tree(screen(), app: "Gym")
            return (200, ["value": .null])
        }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["scroll_to": ["text": "Row 250", "max_swipes": 2]]]])
        XCTAssertTrue(result.text.contains("the list moved more than a screen after 1 swipe, so a short drag back followed each"), result.text)
        XCTAssertTrue(result.text.contains("(the list moved a screen or more, -300 pt on the swipes)"), result.text)
    }

    /// In-process, the snapshot under an alert holds the alert alone (its accessibility is modal; the
    /// gym's look listed three elements and nothing of the app), where WebDriverAgent lists the
    /// screen behind too. The read says so, so the model does not take the app for gone.
    func testALookAtAnAlertAloneSaysTheScreenBehindItIsNotListed() async {
        let (core, wda, _) = makeCore()
        wda.tree([Node("Alert", nil, [20, 300, 350, 200], [Node("StaticText", "Just a moment", [40, 320, 310, 40]), Node("Button", "Not now", [40, 440, 150, 44]), Node("Button", "OK", [200, 440, 150, 44])])], app: "Gym")
        let alone = await core.call("look", [:])
        XCTAssertTrue(alone.text.contains("note: the tree lists the alert only, not the screen behind it (it is still there, under the picture's dimming): answer or dismiss it to list the screen again"), alone.text)
        wda.tree([Node("Table", nil, [0, 100, 390, 700], (0..<10).map { Node("Cell", "Row \($0)", [16, Double(100 + $0 * 44), 358, 44]) }), Node("Alert", nil, [20, 300, 350, 200], [Node("StaticText", "Just a moment", [40, 320, 310, 40]), Node("Button", "Not now", [40, 440, 150, 44])])], app: "Gym")
        let behind = await core.call("look", [:])
        XCTAssertFalse(behind.text.contains("lists the alert only"), behind.text)
    }

    /// Photos' home: the Library grid is one Button of 402x586 with the photos nowhere in the tree
    /// (the gym's raw XML), so its centre is one photo among many. The line says so.
    func testAnElementCoveringTheScreenAloneSaysItsPartsAreNotInTheTree() async {
        let (core, wda, _) = makeCore()
        wda.tree([Node("Button", "Library", [0, 0, 390, 586]), Node("Button", "Albums", [0, 600, 390, 60]), Node("Button", "Search", [300, 800, 80, 40])], app: "Photos")
        let result = await core.call("look", [:])
        XCTAssertTrue(result.text.contains("1 Button \"Library\" [0,0,390,586] (one element covering 69 % of the screen with no parts in the tree: tap a point on the picture, not its number)"), result.text)
        XCTAssertFalse(result.text.contains("\"Albums\" [0,600,390,60] (one element"), result.text)
    }

    /// Photos' What's New sheet: back (an edge swipe) did nothing. The answer now says a sheet is up
    /// and names its buttons.
    func testBackOnASheetSaysWhatDismissesIt() async {
        let (core, wda, _) = makeCore()
        wda.tree([Node("Sheet", nil, [0, 200, 390, 644], [Node("StaticText", "What's New", [40, 240, 310, 40]), Node("Button", "Continue", [40, 760, 310, 50])])], app: "Photos")
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["back": true]]])
        XCTAssertTrue(result.text.contains("a sheet is up (its buttons: "), result.text)
        XCTAssertTrue(result.text.contains("\"Continue\"): back does not dismiss sheets, tap one of its buttons or drag it down"), result.text)
    }

    /// Notes is not on the CI simulator: the launch answered with the system's whole error dump.
    /// Now one line.
    func testALaunchOfAnAppThatIsNotInstalledIsOneLine() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        let dump = "Error Domain=FBSOpenApplicationServiceErrorDomain Code=1 \"The request to open \"com.apple.mobilenotes\" failed.\" UserInfo={BSErrorCodeDescription=RequestDenied, NSUnderlyingError=0x600000c8 {Error Domain=FBSOpenApplicationErrorDomain Code=4 \"Application \"com.apple.mobilenotes\" is unknown to FrontBoard.\" UserInfo={BSErrorCodeDescription=InvalidRequest}}, NSLocalizedFailureReason=Application \"com.apple.mobilenotes\" is unknown to FrontBoard., NSLocalizedDescription=The request to open \"com.apple.mobilenotes\" failed.}"
        wda.set("POST /wda/apps/activate") { _ in (500, ["value": ["error": "unknown error", "message": .string(dump)]]) }
        let result = await core.call("do", ["actions": [["launch": "com.apple.mobilenotes"]]])
        XCTAssertTrue(result.text.contains("launch com.apple.mobilenotes: no app with that bundle id is installed on this device"), result.text)
        XCTAssertFalse(result.text.contains("FBSOpen"), result.text)
        XCTAssertTrue(result.text.contains("not sent") || result.text.contains("not_sent"), result.text)
    }

    /// Photos launched from Safari: the read after the launch (and the look after it) gave Safari's
    /// whole tree under Photos' picture. The read is now made again, in the same call, until the
    /// launched app is in front.
    func testTheReadAfterALaunchIsMadeAgainUntilTheLaunchedAppIsInFront() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        let launched = LockedBox(false), readsAfter = LockedBox(0)
        wda.set("POST /wda/apps/activate") { _ in launched.value = true; return (200, ["value": .null]) }
        wda.set("GET /wda/activeAppInfo") { _ in
            guard launched.value else { return (200, ["value": ["bundleId": "com.apple.mobilesafari", "name": "Safari"]]) }
            let n = readsAfter.update { $0 += 1; return $0 }
            if n <= 2 { return (200, ["value": ["bundleId": "com.apple.mobilesafari", "name": "Safari"]]) }
            return (200, ["value": ["bundleId": "com.apple.mobileslideshow", "name": "Photos"]])
        }
        let result = await core.call("do", ["actions": [["launch": "com.apple.mobileslideshow"]]])
        XCTAssertTrue(result.text.hasPrefix("app: Photos"), result.text)
        XCTAssertTrue(result.text.contains("the screen was read again (2): com.apple.mobileslideshow was not in front yet"), result.text)
        XCTAssertFalse(result.isError)
    }

    /// A wait_until asked for 8000 ms and got 6000 (the action cap); the call then took 30 s with
    /// nothing in the answer to account for it. The wait gets the time it asks for, and a long call
    /// says where its time went.
    func testWaitUntilGetsTheTimeItAsksForAndALongCallAccountsForItsTime() async {
        let (core, _, _) = makeCore { $0.toolDeadline = 20 }
        _ = await core.call("look", [:])
        let started = Date()
        let result = await core.call("do", ["actions": [["wait_until": ["text": "Never there", "ms": 8000]]]])
        XCTAssertTrue(result.text.contains("not seen within 8000 ms"), result.text)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 7.5)
        XCTAssertTrue(result.text.contains("took: ") && result.text.contains(" s actions, "), result.text)
    }

    /// Three calls during a 32 s restart had no picture at all (the runner gone, simctl over 10 s).
    /// The picture of the read before, marked with its age, stands in.
    func testThePictureOfTheReadBeforeStandsInWhenNoneComes() async {
        let (core, wda, _) = makeCore { $0.readTimeout = 0.5; $0.toolDeadline = 6 }
        let first = await core.call("look", [:])
        XCTAssertNotNil(first.jpeg)
        wda.delay("GET /screenshot", 30)
        wda.delay("GET /source", 30)
        wda.delay("GET /wda/activeAppInfo", 30)
        let blind = await core.call("look", [:])
        XCTAssertNotNil(blind.jpeg, blind.text)
        XCTAssertTrue(blind.text.contains("the screenshot is the one of the read before, ") && blind.text.contains(" s old (no newer one came)"), blind.text)
    }

    /// Photos' notification-permission alert sat over the launched app: the read after the launch
    /// said Home screen and the agent took a wrong turn. The answer now names the alert instead of
    /// reading again for the app.
    func testALaunchUnderASystemAlertNamesTheAlert() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.springboard", "name": "SpringBoard"]]) }
            wda.tree([Node("Alert", nil, [20, 300, 350, 200], [Node("StaticText", "\"Photos\" Would Like to Send You Notifications", [40, 320, 310, 40]), Node("Button", "Don't Allow", [40, 440, 150, 44]), Node("Button", "Allow", [200, 440, 150, 44])])], app: "SpringBoard")
            return (200, ["value": .null])
        }
        let result = await core.call("do", ["actions": [["launch": "com.apple.mobileslideshow"]]])
        XCTAssertTrue(result.text.contains("a system alert is in front (\"\"Photos\" Would Like to Send You Notifications\": Don't Allow, Allow); the launched app is behind it: answer the alert first"), result.text)
        XCTAssertFalse(result.text.contains("read again (2)"), result.text)
    }

    /// A scroll under an alert "stopped moving" (true: the alert took the drags); the answer names it.
    func testAScrollUnderAnAlertNamesIt() async {
        let (core, wda, _) = makeCore()
        wda.tree([Node("Table", nil, [0, 100, 390, 700], (0..<10).map { Node("Cell", "Row \($0)", [16, Double(100 + $0 * 44), 358, 44]) }), Node("Alert", nil, [20, 300, 350, 200], [Node("StaticText", "Just a moment", [40, 320, 310, 40]), Node("Button", "Not now", [40, 440, 150, 44])])], app: "Gym")
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["scroll_to": "Row 99"]]])
        XCTAssertTrue(result.text.contains("not found: the list stopped moving (its end, or the text is not in it); an alert is over the list (\"Just a moment\": Not now): answer it first"), result.text)
    }

    /// Safari's address bar: {key: "return"} as a key event left the suggestions up once. With a
    /// keyboard up, return is a tap on its own Go/Return key; without one, the key event, and the
    /// answer says which.
    func testReturnIsTheKeyboardsOwnKeyWhenOneIsUp() async {
        let (core, wda, _) = makeCore()
        wda.tree([Node("TextField", "Address", [16, 64, 306, 37], value: "example.com"), Node("Keyboard", nil, [0, 500, 390, 344], [Node("Button", "space", [100, 800, 190, 40]), Node("Button", "Go", [300, 800, 80, 40])])], app: "Safari")
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["key": "return"]]])
        XCTAssertTrue(result.text.contains("key return: tapped the keyboard's \"Go\" key at [340, 820]"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").last?["y"]?.double, 820)
        XCTAssertTrue(wda.bodies("POST /wda/keys").isEmpty)
        wda.tree([Node("TextField", "Address", [16, 64, 306, 37], value: "example.com")], app: "Safari")
        let event = await core.call("do", ["actions": [["key": "return"]]])
        XCTAssertTrue(event.text.contains("key return (sent as a key event; no keyboard key was listed to tap)"), event.text)
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1)
    }

    /// Gym: a type gave up on a busy runner after 3 s with 7 s of its action left (the runner was
    /// serving this side's own leftover read from the look before) and cost a round trip. The wait
    /// is now the action's remaining time less what the keys need.
    func testTypingWaitsAsLongAsTheActionAllowsForABusyRunner() async {
        let (core, wda, _) = makeCore { $0.actionCap = 3; $0.toolDeadline = 20; $0.readTimeout = 0.5 }
        let field = FaultTests.Field()
        field.keyboard.value = false
        field.install(wda)
        _ = await core.call("look", [:])
        wda.delay("GET /source", 5)
        wda.delay("GET /wda/activeAppInfo", 5)
        let started = Date()
        let result = await core.call("do", ["actions": [["type": "hello", "ref": 1]]])
        XCTAssertFalse(result.text.contains("nothing was typed"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1, "the keys went once the runner was through: \(result.text)")
        XCTAssertEqual(field.value.value, "hello")
        XCTAssertLessThan(Date().timeIntervalSince(started), 16, result.text)
    }

    /// CI simulator, the keyboard's first use: the runner stood still for seconds, the focus reads
    /// were given up on, and the keys sent behind them came back unknown (typed or not, the model
    /// cannot tell). Now a busy runner is waited for, and when it is not through nothing is typed.
    func testTypingWaitsForABusyRunnerAndSendsNothingWhenItIsNotThrough() async {
        let (core, wda, _) = makeCore { $0.actionCap = 3; $0.toolDeadline = 20; $0.readTimeout = 0.5 }
        let field = FaultTests.Field()
        field.keyboard.value = false
        field.install(wda)
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("1 TextField \"Note\""), look.text)
        wda.delay("GET /source", 12)
        wda.delay("GET /wda/activeAppInfo", 12)
        let result = await core.call("do", ["actions": [["type": "hello", "ref": 1]]])
        XCTAssertTrue(result.text.contains("nothing was typed: the runner is still finishing an earlier"), result.text)
        XCTAssertTrue(result.text.contains("was not sent"), result.text)
        XCTAssertFalse(result.text.contains("(unknown"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/keys").isEmpty, "no keys went to a busy runner")
        XCTAssertEqual(field.value.value, "")
    }
}
