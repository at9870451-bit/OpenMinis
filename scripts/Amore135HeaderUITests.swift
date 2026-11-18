import XCTest

/// Isolated component UI host, NOT full AIChatView/kernel/device integration.
/// The build extracts the complete production ChatTrailingMenuButton unchanged.
@MainActor
final class Amore135HeaderUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }
    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testOriginalMenuActionsAreVisibleAndInvokeOnlyTheirExactHostCallback() {
        launchHeader()
        // English source keys checked independently; production says Browse CHAT Files.
        let actions = [
            ("New Chat", "onNewChat"), ("Share Chat…", "onShare"),
            ("Search in Chat", "onSearchInChat"), ("Compact Messages", "onCompact"),
            ("Clear Chat", "onClearChat"), ("Force iCloud Sync", "onForceSync"),
            ("Force Pull Messages", "onForcePull"), ("Open Terminal", "onOpenTerminal"),
            ("Open Browser", "onOpenBrowser"), ("Browse Chat Files", "onBrowseFiles"),
            ("Skills in Session", "onSkills"), ("MCPs in Session", "onMCPs"),
            ("Memories in Session", "onMemories"), ("Token Usage", "onTokenUsage")
        ]
        for (index, pair) in actions.enumerated() {
            XCTContext.runActivity(named: "Real UIKit menu tap: \(pair.0)") { _ in
                openMenu()
                let item = visibleMenuItem(pair.0)
                XCTAssertTrue(item.isEnabled)
                XCTAssertTrue(item.isHittable, "Original menu action must actually be on screen")
                attach("Amore135-menu-\(pair.1)")
                item.tap()
                assertAction(pair.1, count: 1, total: index + 1)
            }
        }
    }

    func testMenuToggleReopensWithFreshStateAndSameActionDoesNotUseStaleClosures() {
        launchHeader(extra: ["-amore135-fast-switch"])
        for (index, expected) in [true, false].enumerated() {
            openMenu()
            visibleMenuItem("Speak Responses").tap()
            assertAction("setSpeakEnabled", count: index + 1, total: index + 1)
            assertToggle("speak=\(expected)")
        }
        openMenu()
        visibleMenuItem("Enhanced Cache").tap()
        assertAction("setEnhancedCache", count: 1, total: 3)
        assertToggle("cache=true")
        openMenu()
        visibleMenuItem("Enable Fast Mode").tap()
        assertAction("setSpeedTier", count: 1, total: 4)
        assertToggle("tier=fast")
        openMenu()
        visibleMenuItem("Enable Fast Mode").tap()
        assertAction("setSpeedTier", count: 2, total: 5)
        assertToggle("tier=standard")
    }

    func testSpeedAndKeepScreenOnSubmenusUseRealMenuActions() {
        launchHeader()
        openMenu()
        visibleMenuItem("Fast Mode").tap()
        visibleMenuItem("Ultrafast").tap()
        assertAction("setSpeedTier", count: 1, total: 1)
        assertToggle("tier=ultrafast")
        openMenu()
        visibleMenuItem("Keep Screen On").tap()
        visibleMenuItem("Use Screen Saver").tap()
        assertAction("setScreenSaverNow", count: 1, total: 2)
        assertToggle("saver=true")
        openMenu()
        visibleMenuItem("Keep Screen On").tap()
        visibleMenuItem("Keep Screen On", exactTitle: true).tap()
        assertAction("setKeepAwake", count: 1, total: 3)
        assertToggle("awake=true")
    }

    func testEmptyMessagesDisableOriginalChatActionsButTerminalStillWorks() {
        launchHeader(extra: ["-amore135-empty-messages"])
        openMenu()
        for label in ["Share Chat…", "Search in Chat", "Compact Messages", "Clear Chat"] {
            let item = visibleMenuItem(label, requireHittable: false)
            XCTAssertTrue(item.exists, label)
            XCTAssertFalse(item.isEnabled, "Disabled production gate lost: \(label)")
        }
        let terminal = visibleMenuItem("Open Terminal")
        XCTAssertTrue(terminal.isEnabled)
        terminal.tap()
        assertAction("onOpenTerminal", count: 1, total: 1)
    }

    func testTopRight44PointHitAreaIsNotCoveredByCenterAvatar() throws {
        launchHeader()
        let menu = menuButton
        let avatar = app.buttons["chat.header.details"]
        let threads = app.buttons["chat.threads"]
        XCTAssertTrue(menu.isHittable)
        XCTAssertTrue(avatar.isHittable)
        XCTAssertTrue(threads.isHittable)
        let metrics = app.staticTexts["amore135.header.hitRect"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "|UIButton"), object: metrics)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        let fields = metrics.label.split(separator: "|").map(String.init)
        XCTAssertEqual(fields.count, 6)
        let values = try fields.prefix(4).map { try XCTUnwrap(Double($0)) }
        let hit = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        XCTAssertEqual(fields[4], "true", "Production point(inside:) must accept 44pt edge points")
        XCTAssertGreaterThanOrEqual(hit.width, 44)
        XCTAssertGreaterThanOrEqual(hit.height, 44)
        // UIKit reports intrinsic glyph bounds; the effective hit rect is the
        // 44pt contract. Do not fake a bigger UIButton to satisfy accessibility.
        XCTAssertTrue(hit.contains(CGPoint(x: menu.frame.midX, y: menu.frame.midY)))
        XCTAssertGreaterThan(hit.midX, app.frame.midX)
        XCTAssertLessThan(hit.maxX, app.frame.maxX + 1)
        XCTAssertLessThan(hit.minY, app.frame.minY + 160)
        XCTAssertEqual(hit.midY, threads.frame.midY, accuracy: 8)
        XCTAssertEqual(avatar.frame.midX, app.frame.midX, accuracy: 4)
        XCTAssertLessThan(avatar.frame.maxX, hit.minX, "Centered model/portrait target overlaps menu")
        XCTAssertFalse(avatar.frame.intersects(hit))
        attach("Amore135-real-header-bounds")

        // Do not confuse UIButton intrinsic glyph size with its expanded touch box.
        // These are actual XCUITest coordinate taps, not direct callback invocation.
        let points = [CGPoint(x: hit.midX, y: hit.midY),
                      CGPoint(x: hit.minX + 1, y: hit.midY),
                      CGPoint(x: hit.maxX - 1, y: hit.midY),
                      CGPoint(x: hit.midX, y: hit.minY + 1),
                      CGPoint(x: hit.midX, y: hit.maxY - 1)]
        for (index, point) in points.enumerated() {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
            XCTAssertTrue(menuItem("New Chat").waitForExistence(timeout: 5), "44pt edge tap \(index) did not open real UIMenu")
            visibleMenuItem("Search in Chat").tap()
            assertAction("onSearchInChat", count: index + 1, total: index + 1)
        }
        avatar.tap()
        assertAction("openModel", count: 1, total: points.count + 1)
    }

    func testDrawerRealFooterRemainsBelowScrollAndRoutesToHostStateOnly() {
        for appearance in ["Light", "Dark"] {
            app.terminate()
            app.launchArguments = ["-amore135-drawer-probe", "-AppleLanguages", "(en)",
                                   "-AppleLocale", "en_US", "-AppleInterfaceStyle", appearance]
            app.launch()
            XCTAssertTrue(app.staticTexts["amore135.drawer.root"].waitForExistence(timeout: 10))
            let newChat = app.buttons["amore.sidebar.newConversation"]
            let settings = app.buttons["amore.sidebar.settings"]
            XCTAssertTrue(newChat.isHittable)
            XCTAssertTrue(settings.isHittable)
            XCTAssertGreaterThanOrEqual(newChat.frame.width, 132)
            XCTAssertGreaterThanOrEqual(newChat.frame.height, 52)
            XCTAssertGreaterThanOrEqual(settings.frame.width, 52)
            XCTAssertGreaterThanOrEqual(settings.frame.height, 52)
            XCTAssertLessThan(newChat.frame.maxX, settings.frame.minX)
            XCTAssertGreaterThan(newChat.frame.minY, app.frame.midY)
            let original = newChat.frame
            attach("Amore135-full-drawer-\(appearance)-top")
            let history = app.scrollViews["amore135.drawer.history"]
            XCTAssertTrue(history.exists)
            history.swipeUp()
            history.swipeUp()
            XCTAssertEqual(newChat.frame.minY, original.minY, accuracy: 1, "Footer must not live inside ScrollView")
            XCTAssertTrue(newChat.isHittable)
            XCTAssertTrue(settings.isHittable)
            attach("Amore135-full-drawer-\(appearance)-scrolled")
            newChat.tap()
            assertLabel("amore135.drawer.state", contains: "new=1;sheet=none;target=none")
            settings.tap()
            assertLabel("amore135.drawer.state", contains: "new=1;sheet=settings;target=home")
        }
    }

    private var menuButton: XCUIElement { app.buttons["amore.conversationOptions"] }

    private func launchHeader(extra: [String] = []) {
        app.launchArguments = ["-amore135-header-probe", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["amore135.header.root"].waitForExistence(timeout: 10))
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["amore135.header.lastAction"].label, "none")
    }

    private func openMenu() {
        XCTAssertTrue(menuButton.isHittable, "Real trailing UIButton must be reachable")
        menuButton.tap()
        XCTAssertTrue(menuItem("New Chat").waitForExistence(timeout: 5), "Tap must open a real UIKit menu, not a fake ellipsis image")
    }

    private func labelPredicate(_ label: String) -> NSPredicate {
        // UIKit combines a submenu's title and current-value subtitle in AX.
        // Accept only the exact title or its normal separator, not a broad
        // contains query that could tap a different action.
        NSPredicate(format: "(label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@) AND (elementType == %d OR elementType == %d)",
            label, label + ", ", label + "\n", XCUIElement.ElementType.button.rawValue,
            XCUIElement.ElementType.menuItem.rawValue)
    }

    private func menuItem(_ label: String) -> XCUIElement {
        // One live query survives async presentation and both UIKit AX roles.
        let predicate = labelPredicate(label)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func visibleMenuItem(_ label: String, requireHittable: Bool = true, exactTitle: Bool = false) -> XCUIElement {
        // Native menus may scroll on small phones. Do not assume all original actions
        // fit in one screenshot. Scroll only the presented menu, never the host state.
        for _ in 0..<6 {
            let predicate = exactTitle
                ? NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)", label, XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.menuItem.rawValue)
                : labelPredicate(label)
            let candidates = app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
            if let visible = candidates.first(where: { $0.isHittable }) { return visible }
            if !requireHittable, let visible = candidates.first(where: { $0.frame.intersects(app.frame) }) { return visible }
            let scroll = app.scrollViews.firstMatch
            if scroll.exists { scroll.swipeUp() }
            else {
                let anchor = menuItem("New Chat")
                let x = anchor.exists && anchor.frame.width > 0 ? anchor.frame.midX : app.frame.midX
                let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - app.frame.minX, dy: app.frame.height * 0.75))
                let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - app.frame.minX, dy: app.frame.height * 0.40))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        let debug = XCTAttachment(string: app.debugDescription)
        debug.name = "Amore135-menu-tree-" + label
        debug.lifetime = .keepAlways; add(debug)
        XCTFail("Original UIKit action not visible after menu scrolling: \(label)")
        return menuItem(label)
    }

    private func assertAction(_ action: String, count: Int, total: Int) {
        assertLabel("amore135.header.lastAction", equals: action)
        assertLabel("amore135.header.actionCount", equals: String(count))
        // Exact total catches accidentally invoking multiple/wrong callbacks.
        assertLabel("amore135.header.totalCount", equals: String(total))
    }
    private func assertToggle(_ fragment: String) { assertLabel("amore135.header.toggles", contains: fragment) }
    private func assertLabel(_ id: String, equals expected: String) {
        let item = app.staticTexts[id]
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed, "\(id) expected \(expected), got \(item.label)")
    }
    private func assertLabel(_ id: String, contains expected: String) {
        let item = app.staticTexts[id]
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", expected), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed, "\(id) missing \(expected)")
    }
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
