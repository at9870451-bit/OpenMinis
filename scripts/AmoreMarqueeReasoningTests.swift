import XCTest
import Foundation
@testable import PokiComponents

@MainActor
final class AmoreMarqueeReasoningTests: XCTestCase {
    func testBlankChatGateNeverCoversMessagesOrDrafts() {
        func show(_ messages: Int = 0, _ input: String = "", _ files: Int = 0,
                  _ pastes: Int = 0, _ videos: Int = 0, _ loading: Bool = false,
                  _ processing: Bool = false, _ editing: Bool = false) -> Bool {
            AmoreHomeShortcutPolicy.shouldShow(messageCount: messages, input: input,
                attachmentCount: files, pastedTextCount: pastes, loadingVideoCount: videos,
                isLoading: loading, isProcessing: processing, isEditing: editing)
        }
        XCTAssertTrue(show())
        XCTAssertTrue(show(0, " \n"))
        XCTAssertFalse(show(1))
        XCTAssertFalse(show(0, "draft"))
        XCTAssertFalse(show(0, "", 1))
        XCTAssertFalse(show(0, "", 0, 1))
        XCTAssertFalse(show(0, "", 0, 0, 1))
        XCTAssertFalse(show(0, "", 0, 0, 0, true))
        XCTAssertFalse(show(0, "", 0, 0, 0, false, true))
        XCTAssertFalse(show(0, "", 0, 0, 0, false, false, true))
    }

    func testCatalogsHaveUniqueIDsValidActionsAndBalancedRows() {
        for chinese in [false, true] {
            let items = AmoreHomeShortcutCatalog.items(chinese: chinese)
            XCTAssertEqual(items.count, 34)
            XCTAssertEqual(Set(items.map(\.id)).count, items.count)
            XCTAssertTrue(items.allSatisfy(AmoreShortcutRanking.valid))
            let rows = AmoreHomeShortcutPolicy.rows(items)
            XCTAssertEqual(rows.map(\.count), [17, 17])
            XCTAssertEqual(rows.flatMap { $0 }, items)
            for item in items where item.action.kind == .page && item.action.value != "shortcuts" {
                XCTAssertNotNil(AmoreShortcutRoutes.settingsURL(for: item.action.value))
            }
        }
        XCTAssertEqual(AmoreHomeShortcutPolicy.rows([]).map(\.count), [0, 0])
        XCTAssertEqual(AmoreHomeShortcutPolicy.rows(Array(AmoreHomeShortcutCatalog.items.prefix(1))).map(\.count), [1, 0])
        XCTAssertEqual(AmoreShortcutRoutes.settingsURL(for: "rootfs")?.absoluteString, "minis://settings/rootfs")
        XCTAssertEqual(AmoreShortcutRoutes.settingsURL(for: "developer")?.absoluteString, "minis://settings/developer-connection")
        XCTAssertNil(AmoreShortcutRoutes.settingsURL(for: "plugins"))
        XCTAssertNil(AmoreShortcutRoutes.settingsURL(for: "shortcuts")) // local sheet, not a fake URL
    }

    func testActionValidationRejectsUnsafeLinksAndUnknownPages() {
        XCTAssertFalse(AmoreShortcutRanking.validAction(.init(kind: .link, value: "http://example.com")))
        XCTAssertFalse(AmoreShortcutRanking.validAction(.init(kind: .link, value: "https://name:secret@example.com")))
        XCTAssertFalse(AmoreShortcutRanking.validAction(.init(kind: .link, value: "javascript:alert(1)")))
        XCTAssertFalse(AmoreShortcutRanking.validAction(.init(kind: .page, value: "views/rootfs")))
        XCTAssertFalse(AmoreShortcutRanking.validAction(.init(kind: .prompt, value: " \n")))
        XCTAssertFalse(AmoreShortcutRanking.validAction(.init(kind: .prompt, value: String(repeating: "a", count: 8001))))
        XCTAssertTrue(AmoreShortcutRanking.validAction(.init(kind: .link, value: "https://example.com/path?q=a")))
    }

    func testUpgradeKeepsHiddenEditedAndDeletedDefaultChoices() {
        let defaults = AmoreHomeShortcutCatalog.items(chinese: false)
        var hidden = defaults[0]; hidden.hidden = true
        var edited = defaults[1]; edited.title = "My title"; edited.edited = true
        let upgraded = AmoreHomeShortcutPolicy.upgrade([hidden, edited, edited], defaults: defaults,
            previousDefaultIDs: ["new-task", "summarize", "settings", "rootfs"])
        XCTAssertTrue(upgraded.first { $0.id == "new-task" }!.hidden)
        XCTAssertEqual(upgraded.first { $0.id == "summarize" }!.title, "My title")
        XCTAssertNil(upgraded.first { $0.id == "rootfs" })
        XCTAssertNil(upgraded.first { $0.id == "settings" })
        XCTAssertEqual(Set(upgraded.map(\.id)).count, upgraded.count)
        XCTAssertNotNil(upgraded.first { $0.id == "translate" })
    }

    func testStoreRoundTripEditHideDeleteRestoreAndEmptyStayEmpty() throws {
        let suite = "amore.shortcuts.tests." + UUID().uuidString
        let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        let store = AmoreHomeShortcutStore(storage: storage)
        var item = AmoreHomeShortcut(id: "custom-test", appName: "Amore", title: "Test",
            symbol: "sparkles", action: .init(kind: .prompt, value: "Draft only"))
        try store.add(item)
        XCTAssertThrowsError(try store.add(item))
        store.setHidden(true, id: item.id)
        item.title = "Edited"; try store.update(item)
        XCTAssertTrue(store.items.first { $0.id == item.id }!.hidden)
        XCTAssertTrue(store.items.first { $0.id == item.id }!.edited)
        let reloaded = AmoreHomeShortcutStore(storage: storage)
        XCTAssertEqual(reloaded.items, store.items)
        XCTAssertFalse(reloaded.visibleItems.contains { $0.id == item.id })
        reloaded.setHidden(false, id: item.id)
        XCTAssertTrue(reloaded.visibleItems.contains { $0.id == item.id })
        reloaded.remove(id: "new-task")
        reloaded.restoreDefaults()
        XCTAssertTrue(reloaded.items.contains { $0.id == item.id })
        XCTAssertTrue(reloaded.items.contains { $0.id == "new-task" })
        for value in reloaded.items { reloaded.remove(id: value.id) }
        XCTAssertTrue(AmoreHomeShortcutStore(storage: storage).items.isEmpty)
    }

    func testClockEasingBothDirectionsWrappingHoldAndResume() {
        for speed in [20.0, -18.0] {
            var clock = AmoreMarqueeClock()
            clock.advance(to: 1, period: 100, speed: speed, running: true, touching: false, scale: 3)
            clock.advance(to: 1.1, period: 100, speed: speed, running: true, touching: false, scale: 3)
            XCTAssertEqual(clock.velocity, speed * 0.3, accuracy: 0.000001)
            for frame in 1...1800 {
                clock.advance(to: 1.1 + Double(frame) / 60, period: 100, speed: speed,
                    running: true, touching: false, scale: 3)
                XCTAssertGreaterThanOrEqual(clock.drift, 0)
                XCTAssertLessThan(clock.drift, 100)
            }
            XCTAssertEqual(clock.velocity, speed, accuracy: 0.01)
            let before = clock.drift
            clock.hold()
            clock.advance(to: 32, period: 100, speed: speed, running: true, touching: false, scale: 3)
            XCTAssertEqual(clock.velocity, 0)
            clock.advance(to: 33.9, period: 100, speed: speed, running: true, touching: false, scale: 3)
            XCTAssertEqual(clock.velocity, 0)
            XCTAssertEqual(clock.drift, before, accuracy: 0.17) // at-rest pixel rounding
            clock.advance(to: 34.1, period: 100, speed: speed, running: true, touching: false, scale: 3)
            XCTAssertGreaterThan(abs(clock.velocity), 0)
            for frame in 1...200 {
                clock.advance(to: 34.1 + Double(frame) / 60, period: 100, speed: speed,
                    running: false, touching: false, scale: 3)
            }
            XCTAssertEqual(clock.velocity, 0)
        }
    }
}
