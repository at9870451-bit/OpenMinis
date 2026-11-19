import XCTest

final class Amore138ComposerUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(); app.launchArguments += ["-amore138-composer-probe"]
        app.launch()
        XCTAssertTrue(app.textFields["probe.composer.text"].waitForExistence(timeout: 10))
    }
    private func button(_ label: String) -> XCUIElement { app.buttons.matching(NSPredicate(format:"label == %@",label)).firstMatch }
    private func assertLast(_ value: String) {
        let element=app.staticTexts["probe.lastAction"]
        expectation(for: NSPredicate(format:"label == %@",value),evaluatedWith: element)
        waitForExpectations(timeout: 3)
    }
    func testEmptyCallsTypedInputSendsAndAttachmentSends() {
        let call=app.buttons["composer.voiceCall"]
        XCTAssertTrue(call.waitForExistence(timeout: 4));XCTAssertGreaterThanOrEqual(call.frame.width,44)
        call.tap(); assertLast("call")
        app.buttons["probe.fill"].tap()
        let send=button("Send");XCTAssertTrue(send.waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["composer.voiceCall"].exists)
        send.tap();assertLast("send")
        app.buttons["probe.clear"].tap();XCTAssertTrue(call.waitForExistence(timeout: 4))
        app.buttons["probe.attachment"].tap();XCTAssertFalse(call.exists)
        send.tap();assertLast("send")
        let image=XCTAttachment(screenshot:app.screenshot());image.name="Amore138-Shared-Composer-Send";image.lifetime = .keepAlways;add(image)
    }
    func testBusyStopsAndDraftQueuesWithoutCall() {
        app.buttons["probe.busy"].tap()
        let stop=button("Stop generating");XCTAssertTrue(stop.waitForExistence(timeout: 4));XCTAssertFalse(app.buttons["composer.voiceCall"].exists)
        stop.tap();assertLast("stop")
        app.buttons["probe.busy"].tap();app.buttons["probe.fill"].tap()
        let enqueue=button("Add to queue");XCTAssertTrue(enqueue.waitForExistence(timeout: 4))
        enqueue.tap();assertLast("queue")
    }
    func testDictationAndBackgroundChildNeverLoseSendStop() {
        app.buttons["probe.dictation"].tap();XCTAssertTrue(button("Send").waitForExistence(timeout:4))
        XCTAssertFalse(app.buttons["composer.voiceCall"].exists)
        app.buttons["probe.dictation"].tap()
        app.buttons["probe.child"].tap()
        XCTAssertTrue(button("Stop sub agents").waitForExistence(timeout:4));XCTAssertFalse(app.buttons["composer.voiceCall"].exists)
        button("Stop sub agents").tap();assertLast("stop")
    }
}
