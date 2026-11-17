import XCTest
@testable import PokiCore

/// ESP-465: sending a message in a chat app, as the owner's phone log showed it (build 800, where
/// Approvals were off, so nothing here waits for the owner).
final class ChatSendTests: XCTestCase {
    func number(of type: String, in text: String) -> Int? {
        for line in text.split(separator: "\n") where line.contains(type) {
            let digits = line.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
            if let n = Int(digits) { return n }
        }
        return nil
    }

    /// The model tapped the message field between typing and Return (3 of 6 sends in the log). A
    /// routine saved from that task replayed the tap every time; it is now left out of the routine.
    func testARoutineLeavesOutATapOnTheFieldBetweenTypingAndReturn() async {
        let store = RoutineStore(url: nil)
        let chat = ChatApp()
        let wda = FakeWDA()
        chat.install(wda)
        let (core, _, _) = makeCore(wda) { $0.memory = store; $0.sensitive.enabled = false }
        _ = await core.call("look", [:])
        // The empty field has no name and is not listed: the model taps where it is, then types.
        let typed = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"]]])
        guard let again = number(of: "TextView", in: typed.text) else { return XCTFail(typed.text) }
        _ = await core.call("do", ["actions": [["tap": .number(Double(again))], ["key": "return"]]])
        XCTAssertEqual(chat.messages.value.last, "收到")
        _ = await core.call("routines", ["action": "save", "name": "reply", "description": "reply in the chat"])
        let steps = store.routine(named: "reply")?.steps ?? []
        XCTAssertEqual(steps.count, 3, "the tap that focused the field, the type and the Return, without the second tap: \(steps.map { $0.action.serialized() })")
        XCTAssertNotNil(steps[1].action["type"])
        XCTAssertEqual(steps.last?.action["key"]?.string, "return")
    }

    /// A tap on the field before anything was typed focuses it, and stays in the routine.
    func testATapOnTheFieldBeforeTypingStays() async {
        let store = RoutineStore(url: nil)
        let chat = ChatApp()
        let wda = FakeWDA()
        chat.install(wda)
        let (core, _, _) = makeCore(wda) { $0.memory = store; $0.sensitive.enabled = false }
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"], ["key": "return"]]])
        _ = await core.call("routines", ["action": "save", "name": "reply", "description": "reply in the chat"])
        XCTAssertEqual(store.routine(named: "reply")?.steps.count, 3)
    }

    /// Typing into one field, then a tap on another field of the same kind and Return there: that tap
    /// moves the focus, so the routine keeps it.
    func testATapOnAnotherFieldOfTheSameKindStays() async {
        let store = RoutineStore(url: nil)
        let wda = FakeWDA()
        wda.tree([Node("StaticText", "表单", [20, 100, 200, 30]), Node("TextField", "姓名", [20, 200, 350, 40], value: ""), Node("TextField", "电话", [20, 300, 350, 40], value: "")], app: "表单")
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.example.form", "name": "表单"]]) }
        let (core, _, _) = makeCore(wda) { $0.memory = store; $0.sensitive.enabled = false }
        let looked = await core.call("look", [:])
        guard let name = number(of: "姓名", in: looked.text), let phone = number(of: "电话", in: looked.text) else { return XCTFail(looked.text) }
        _ = await core.call("do", ["actions": [["tap": .number(Double(name))], ["type": "张三"]]])
        _ = await core.call("do", ["actions": [["tap": .number(Double(phone))], ["key": "return"]]])
        _ = await core.call("routines", ["action": "save", "name": "form", "description": "fill the form"])
        let steps = store.routine(named: "form")?.steps ?? []
        XCTAssertEqual(steps.count, 4, "\(steps.map { $0.action.serialized() })")
        XCTAssertEqual(steps[2].target?.label, "电话")
    }

    func chat(_ app: ChatApp = ChatApp()) -> (PokiCore, ChatApp) {
        let wda = FakeWDA()
        app.install(wda)
        let (core, _, _) = makeCore(wda) { $0.sensitive.enabled = false }
        return (core, app)
    }

    /// After Return the model looked again, or spent a turn, to see whether the message went (the gap
    /// from Return to done was 14 to 26 s in the log). The Return answer says what its own read shows
    /// and what to look for next; it does not say sent.
    func testTheReturnAnswerSaysWhatTheReadShows() async {
        let (core, app) = chat()
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"]]])
        let sent = await core.call("do", ["actions": [["key": "return"]]])
        XCTAssertEqual(app.messages.value.last, "收到")
        XCTAssertTrue(sent.text.contains("send check: not confirmed: the message field is empty and the last message on screen now reads \"收到\""), sent.text)
        XCTAssertTrue(sent.text.contains("a failure or sending mark beside that message"), sent.text)
    }

    func testTypeAndReturnInOneCallAreCheckedToo() async {
        let (core, _) = chat()
        _ = await core.call("look", [:])
        let sent = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"], ["key": "return"]]])
        XCTAssertTrue(sent.text.contains("send check: not confirmed: the message field is empty and the last message on screen now reads \"收到\""), sent.text)
    }

    /// The send key did nothing: the text is still in the field, and the answer says the send is not
    /// confirmed, so the model looks before it reports.
    func testAReturnThatSentNothingIsNotConfirmed() async {
        let app = ChatApp()
        app.sends.value = false
        let (core, _) = chat(app)
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"]]])
        let tried = await core.call("do", ["actions": [["key": "return"]]])
        XCTAssertTrue(tried.text.contains("send check: not confirmed"), tried.text)
        XCTAssertTrue(tried.text.contains("the message field still holds the text"), tried.text)
    }

    /// The field emptied but the last message is another one: not confirmed either.
    func testAnEmptiedFieldWithAnotherLastMessageIsNotConfirmed() async {
        let app = ChatApp()
        let (core, _) = chat(app)
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"]]])
        app.sends.value = false
        app.field.value = ""
        let tried = await core.call("do", ["actions": [["key": "return"]]])
        XCTAssertTrue(tried.text.contains("send check: not confirmed"), tried.text)
        XCTAssertTrue(tried.text.contains("the last message on screen reads \"明天见\""), tried.text)
    }

    /// A message that failed (a retry button beside it, as WeChat shows a failed send) or is still
    /// sending (a spinner beside it) reads the same as a sent one in the field and the last message,
    /// so the Return answer never says it went.
    func testAFailedOrSendingMessageIsNotCalledSent() async {
        for mark in [Node("Button", "重新发送", []), Node("ActivityIndicator", nil, [])] {
            let app = ChatApp()
            let (core, _) = chat(app)
            _ = await core.call("look", [:])
            _ = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"]]])
            app.mark.value = mark
            let tried = await core.call("do", ["actions": [["key": "return"]]])
            XCTAssertEqual(app.messages.value.last, "收到")
            XCTAssertFalse(tried.text.contains("send check: sent"), "\(mark.type): \(tried.text)")
            XCTAssertTrue(tried.text.contains("send check: not confirmed"), "\(mark.type): \(tried.text)")
        }
    }

    /// Return kept the text as a draft: the field is empty, the app is back in its list of chats, and
    /// the chat's row shows the text after "[草稿]".
    func testATextKeptAsADraftIsNotCalledSent() async {
        let app = ChatApp()
        app.drafts.value = true
        let (core, _) = chat(app)
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"]]])
        let tried = await core.call("do", ["actions": [["key": "return"]]])
        XCTAssertEqual(app.messages.value, ["在吗", "明天见"])
        XCTAssertTrue(tried.text.contains("send check: not confirmed: no message was read above the message field"), tried.text)
    }

    /// The field emptied without a send, and the last message happens to read the same words as the
    /// one typed (sent earlier): not confirmed, since that message was there before Return.
    func testTheSameWordsAlreadyOnScreenAreNotASend() async {
        let app = ChatApp()
        app.messages.value = ["在吗", "收到"]
        let (core, _) = chat(app)
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"]]])
        app.sends.value = false
        app.field.value = ""
        let tried = await core.call("do", ["actions": [["key": "return"]]])
        XCTAssertTrue(tried.text.contains("send check: not confirmed"), tried.text)
    }
}
