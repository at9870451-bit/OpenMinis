import XCTest
@testable import PokiCore

final class SensitivityTests: XCTestCase {
    private let punctuatedActions = [
        "Tap to pay $12.00", "Tap to pay $1,200.00", "Please delete photo-2026-11-14",
        "Tap to pay 12.00元/次", "Please delete my photo-2026-11-14.jpg", "Please delete 照片-旅遊-備份",
        "Please delete 照片-旅遊-備份-2026.final.jpg",
    ]

    private func reason(_ label: String, type: String = "Button") -> String? {
        SensitivityRules().reason(
            touching: Element(type: type, label: label, value: nil, identifier: nil,
                              frame: Rect(x: 0, y: 0, width: 100, height: 44), depth: 1),
            typing: false, app: Foreground(bundleID: "com.apple.mobilemail", name: "Mail"),
            secureOnScreen: false)
    }

    func testLongActionButtonsStillRequireApproval() {
        for label in ["Complete purchase of 3 items", "Tap here to complete the payment",
                      "Open details and then pay", "Tap here to delete this photo permanently"] {
            XCTAssertNotNil(reason(label), label)
        }
    }

    func testTraditionalChineseActionsRequireApproval() {
        for label in ["購買", "訂閱", "轉賬", "轉帳", "刪除", "還原", "發送", "回覆", "發布", "撥打"] {
            XCTAssertNotNil(reason(label), label)
        }
    }

    func testDescriptiveRowsKeepTheirFalsePositiveGuards() {
        for (type, label) in [("Image", "Contact photo for Best Buy"),
                              ("Cell", "Best Buy, Your order has shipped, Yesterday")] {
            XCTAssertNil(reason(label, type: type), label)
        }
        for label in ["Display & Brightness", "PayPal", "buy1", "1pay", "repayment"] {
            XCTAssertNil(reason(label), label)
        }
    }

    /// A mix of a message and a money move must be reported as the payment. The app is a messaging one, so
    /// if `reason` consulted sending before payments this label would come back as a sent message instead.
    func testAPaymentIsReportedInsteadOfASentMessageWhenBothAreInTheLabel() {
        let why = reason("Please send money to Sam and reply afterwards")
        XCTAssertNotNil(why)
        XCTAssertTrue((why ?? "").contains("a payment"), "expected a payment, got \(why ?? "nil")")
    }

    func testLaterWholeWordMatchIsNotHiddenByAnEarlierSubstring() {
        XCTAssertNotNil(reason("Buying help: buy this item now"))
        XCTAssertNotNil(reason("Display details, then pay for this order"))
    }

    func testShortActionsWithAmountsAndDatedNamesRequireApproval() {
        for label in punctuatedActions {
            for type in ["Text", "Other", "Cell", "Link", "StaticText", "Image", "TextField", "Unknown"] {
                XCTAssertNotNil(reason(label, type: type), label)
            }
        }
    }

    func testHyphenatedRowsKeepTheBasesApprovalProtection() {
        for label in ["Tap-here-to-see-this-payment-receipt", "Tap-here-to-see-the-buy-receipt"] {
            XCTAssertNotNil(reason(label, type: "Cell"), label)
        }
    }

    func testStructuredNonButtonPaymentSendsNothingBeforeApproval() async {
        let wda = FakeWDA()
        wda.source([("Link", "Tap to pay $12.00")], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.approvalWait = 0 }
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("1 Link"), look.text)
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(result.text.contains("approval_required"), result.text)
        XCTAssertNotNil(core.pendingApproval)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testNumberedOCRActionSendsNothingBeforeApproval() async {
        for label in punctuatedActions {
            let (core, wda, host) = makeCore {
                $0.readTimeout = 0.5
                $0.approvalWait = 0
            }
            _ = await core.call("look", [:])
            host.texts.value = [RecognizedText(text: label,
                                              box: Rect(x: 0.25, y: 0.9, width: 0.5, height: 0.05))]
            wda.set("GET /source") { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return (200, ["value": .null])
            }
            let look = await core.call("look", [:])
            XCTAssertTrue(look.text.contains("1 Text"), look.text)
            XCTAssertTrue(look.text.contains(label), look.text)
            let tap = await core.call("do", ["actions": [["tap": 1]]])
            XCTAssertTrue(tap.text.contains("approval_required"), tap.text)
            XCTAssertNotNil(core.pendingApproval)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
        }
    }

    func testVoiceActionClearanceRequiresApproval() async {
        for label in punctuatedActions {
            let (core, _, _) = makeCore()
            let clearance = await core.clearTap(on: label, inApp: "example.shop",
                                               named: "Shop", waiting: 0.2)
            guard case .unanswered = clearance else {
                XCTFail("Expected a pending approval for \(label), got \(clearance)")
                continue
            }
            XCTAssertFalse(clearance.mayTap)
            XCTAssertNil(core.pendingApproval)
        }
    }

    func testLongPaymentButtonSendsNothingBeforeApproval() async {
        let wda = FakeWDA()
        wda.source([("Button", "Complete purchase of 3 items")], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.approvalWait = 0 }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(result.text.contains("approval_required"), result.text)
        XCTAssertNotNil(core.pendingApproval)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }
}
