import XCTest

/// Runs in the existing Amore134NavigationUITests target. This is an isolated
/// fixture around the UNMODIFIED AmoreTransparentDrawer, not the real chat VM,
/// persistent history, ContentView integration, or an end-to-end application test.
@MainActor
final class Amore139DrawerUITests: XCTestCase {
    private let app = XCUIApplication()
    private let initialDraft = "draft retained"

    func testHistoryTapSelectsRowClosesAndRetainsEditableDraft() {
        defer { app.terminate() }
        launch()
        let typed = initialDraft + "139"
        appendDraft("139", expected: typed)
        openHistory()
        tap("transparent.history.1")
        assertClosed()
        assertState(selected: "1", draft: typed)

        openHistory()
        XCTAssertEqual(app.buttons["transparent.history.1"].value as? String, "selected")
        XCTAssertEqual(app.buttons["transparent.history.0"].value as? String, "unselected")
        tap("transparent.close")
        assertClosed()
        // Real input after the close proves that retained text is still editable.
        appendDraft("ok", expected: typed + "ok")
        assertState(selected: "1", draft: typed + "ok")
    }

    func testManualCloseAndRightStripDoNotTapThroughToOriginalChatAction() {
        defer { app.terminate() }
        launch()
        tap("transparent.chatAction")
        assertState(taps: 1)
        // Cache the ORIGINAL chat's geometry while it is accessible. Never query
        // its hidden frame or require its TextField to be hittable under history.
        let originalActionFrame = app.buttons["transparent.chatAction"].frame
        openHistory()
        tap("transparent.close")
        assertClosed()
        assertState(taps: 1)

        openHistory()
        // The transparent dismiss surface is deliberately AX-hidden (no invisible
        // VoiceOver button). Derive its exposed strip from independent geometry.
        let width = app.frame.width
        let drawerWidth = max(1, min(width - max(72, (width * 0.22).rounded()), 420))
        let x = app.frame.maxX - 16
        XCTAssertGreaterThan(x, app.frame.minX + drawerWidth)
        XCTAssertTrue(originalActionFrame.contains(CGPoint(x: x, y: originalActionFrame.midY)),
                      "Must tap directly OVER the original chat action")
        let point = coordinate(x: x, y: originalActionFrame.midY)
        point.tap() // XCUITest injects a physical strip tap, not an onClose call.
        assertClosed()
        assertState(taps: 1)
        // Positive control: the identical coordinate now reaches the real button.
        point.tap()
        assertState(taps: 2)
    }

    func testRepeatedOpenCloseAndOuterHorizontalDragKeepOneChatLifetime() {
        defer { app.terminate() }
        launch()
        let typed = initialDraft + "repeat"
        appendDraft("repeat", expected: typed)
        for iteration in 1...3 {
            XCTContext.runActivity(named: "Real open/close cycle \(iteration)") { _ in
                openHistory()
                tap("transparent.close")
                assertClosed()
                assertState(draft: typed)
            }
        }
        openHistory()
        let start = coordinate(x: app.frame.maxX - 16,
                               y: app.frame.minY + app.frame.height * 0.45)
        let end = start.withOffset(CGVector(dx: -app.frame.width * 0.65, dy: 0))
        // The production helper owns no swipe. The probe intentionally mirrors
        // ContentView's OUTER simultaneousGesture (16pt/global/1.5x horizontal,
        // left-only closing, predicted-end > 0.55); it does not invent swipe-open.
        start.press(forDuration: 0.05, thenDragTo: end)
        assertClosed()
        assertState(draft: typed)
        appendDraft("ok", expected: typed + "ok")
        assertState(draft: typed + "ok")
    }

    func testTransparentHistoryScreenshotsWithForcedLightAndDarkSwiftUISchemes() {
        defer { app.terminate() }
        for theme in ["light", "dark"] {
            launch(theme: theme)
            openHistory()
            let scheme = app.staticTexts["transparent.scheme"]
            expect(scheme, key: "label", equals: "theme=\(theme)")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Amore139-live-transparent-history-\(theme)"
            attachment.lifetime = .keepAlways
            add(attachment)
            tap("transparent.close")
            assertClosed()
            assertState()
            app.terminate()
        }
    }

    private func launch(theme: String = "light") {
        continueAfterFailure = false
        // Probe consumes this flag and calls preferredColorScheme itself.
        // Deliberately do NOT rely on -AppleInterfaceStyle for theme coverage.
        app.launchArguments = ["-amore139-drawer-probe", "-amore139-theme", theme,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        hittable(app.buttons["transparent.open"])
        assertClosed()
        assertState()
    }

    private func openHistory() {
        tap("transparent.open") // Real History button -> unchanged helper pane.
        hittable(app.buttons["transparent.close"])
        hittable(app.buttons["transparent.history.0"])
        XCTAssertTrue(app.scrollViews["transparent.history"].exists)
        // XCTest may enumerate mounted UIKit descendants in its global query.
        // Verify a real drawer control remains available rather than treating
        // `.exists` as proof that a covered UIKit input was removed from AX.
        XCTAssertTrue(app.buttons["transparent.history.0"].isHittable)
    }

    private func assertClosed() {
        hittable(app.buttons["transparent.open"])
        let close = app.buttons["transparent.close"]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 4), .completed)
        hittable(app.textFields["transparent.draft"])
    }

    private func assertState(selected: String = "none", draft: String? = nil, taps: Int = 0) {
        let expected = "selected=\(selected);draft=\(draft ?? initialDraft);taps=\(taps);mounts=1"
        expect(app.staticTexts["transparent.state"], key: "label", equals: expected)
        expect(app.textFields["transparent.draft"], key: "value", equals: draft ?? initialDraft)
    }

    private func appendDraft(_ suffix: String, expected: String) {
        let field = app.textFields["transparent.draft"]
        hittable(field) // Called only BEFORE opening or AFTER closing history.
        // Tap the trailing empty area so an existing value receives input at end.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(suffix)
        expect(field, key: "value", equals: expected)
    }

    private func coordinate(x: CGFloat, y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x - app.frame.minX, dy: y - app.frame.minY))
    }

    private func tap(_ identifier: String) {
        let button = app.buttons[identifier]
        hittable(button)
        button.tap()
    }

    private func hittable(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        let result = XCTWaiter.wait(for: [ready], timeout: 3)
        if result != .completed {
            let state = app.staticTexts["transparent.rootState"].label
            XCTFail("Expected hittable identifier: \(element.identifier); probe=\(state)")
        }
    }

    private func expect(_ element: XCUIElement, key: String, equals value: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "%K == %@", key, value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 3), .completed,
                       "Expected \(element.identifier).\(key) = \(value)")
    }
}
