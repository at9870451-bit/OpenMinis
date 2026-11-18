import XCTest

/// Runtime tests for the production-extracted SetupStepLink and SetupStep type.
/// The parent modifier retains the exact typed navigationDestination statement;
/// only its device-service destination payload is replaced by a labelled probe.
/// These tests do NOT exercise the full ConnectionView, DDI or device permissions.
@MainActor
final class Amore134NavigationUITests: XCTestCase {
    private let app = XCUIApplication()

    func testDefaultLaunchRemainsComponentUnitTestHost() {
        continueAfterFailure = false
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(app.staticTexts["amore134.defaultHost"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["amore134.navigation.root"].exists)
        XCTAssertFalse(app.buttons["setup.step.runner"].exists)
    }

    func testAllOriginalSetupStepRawValuesNavigateAndNativeBackRestoresParent() {
        continueAfterFailure = false
        defer { app.terminate() }
        launchNavigationProbe()
        // Independent expectation: intentional rawValue/order changes must be reviewed.
        // The host itself iterates the exact production enum's allCases, not this list.
        let originalRawValues = [
            "runner", "developerMode", "loopback", "pairing", "automation", "background"
        ]
        let stepButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "setup.step."))
        XCTAssertEqual(stepButtons.count, originalRawValues.count, "Every original case must be exposed")
        XCTAssertEqual(Set(stepButtons.allElementsBoundByIndex.map(\.identifier)),
                       Set(originalRawValues.map { "setup.step.\($0)" }))

        for rawValue in originalRawValues {
            XCTContext.runActivity(named: "Tap original SetupStepLink -> \(rawValue) -> native Back") { _ in
                openStep(rawValue)
                attachScreen("SetupStep-\(rawValue)-navigation-probe")
                nativeBackToParent(from: rawValue)
            }
        }
    }

    func testSameSetupStepCanBeTappedAgainAfterNativeBack() {
        continueAfterFailure = false
        defer { app.terminate() }
        launchNavigationProbe()
        for visit in 1...2 {
            XCTContext.runActivity(named: "Repeat developerMode navigation \(visit)") { _ in
                openStep("developerMode")
                nativeBackToParent(from: "developerMode")
            }
        }
    }

    private func launchNavigationProbe() {
        app.launchArguments = ["-amore134-navigation-probe", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["amore134.navigation.root"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Connection Probe"].exists)
        assertStackDepth(0)
    }

    private func openStep(_ rawValue: String) {
        let link = app.buttons["setup.step.\(rawValue)"]
        XCTAssertTrue(link.waitForExistence(timeout: 5), "Missing production SetupStepLink for \(rawValue)")
        XCTAssertTrue(link.isEnabled, "The extracted SetupStepLink must be enabled in this probe")
        XCTAssertTrue(link.isHittable, "The original link must actually be tappable")
        // XCUITest injects a real tap. No programmatic NavigationPath append or static substitute.
        link.tap()
        let destination = app.staticTexts["amore134.navigation.destination.\(rawValue)"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5), "Same-type parent destination must be registered")
        XCTAssertEqual(destination.label, "navigation probe for SetupStep \(rawValue)")
        XCTAssertEqual(app.staticTexts["amore134.navigation.rawValue"].label, rawValue)
        XCTAssertTrue(app.navigationBars["SetupStep Probe"].exists)
        assertStackDepth(1)
    }

    private func nativeBackToParent(from rawValue: String) {
        // No test-only dismiss or reset button: exercise UIKit/SwiftUI's native Back.
        let bar = app.navigationBars["SetupStep Probe"]
        let back = bar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.staticTexts["amore134.navigation.root"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Connection Probe"].exists)
        assertStackDepth(0)
        let destination = app.staticTexts["amore134.navigation.destination.\(rawValue)"]
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: destination)
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 5), .completed)
        let originalLink = app.buttons["setup.step.\(rawValue)"]
        XCTAssertTrue(originalLink.isEnabled)
        XCTAssertTrue(originalLink.isHittable, "Back must restore a usable original row")
    }

    private func assertStackDepth(_ expected: Int) {
        let depth = app.staticTexts["amore134.navigation.pathDepth"]
        XCTAssertTrue(depth.waitForExistence(timeout: 5))
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Parent stack depth: \(expected)"), object: depth)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed,
                       "The owning NavigationStack must push/pop exactly one typed route")
    }

    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
