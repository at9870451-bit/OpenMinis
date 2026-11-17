import XCTest
import SwiftUI
@testable import Minis

final class OriginalPokiHostTests: XCTestCase {
    @MainActor func testFrameworkAvailabilityIsGuardedByOSAndEmbeddedResource() {
        if #available(iOS 18.0, *) {
            let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("Poki.framework/Poki")
            if url == nil || !FileManager.default.fileExists(atPath: url!.path) {
                XCTAssertFalse(OriginalPokiScreen.isAvailable)
            }
        } else {
            XCTAssertFalse(OriginalPokiScreen.isAvailable)
        }
    }

    @MainActor func testHostSelectionKeepsOriginalAmoreSessionAvailable() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(false, forKey: "amore.originalPokiChat")
        XCTAssertFalse(defaults.bool(forKey: "amore.originalPokiChat"))
        defaults.set(true, forKey: "amore.originalPokiChat")
        XCTAssertTrue(defaults.bool(forKey: "amore.originalPokiChat"))
    }

    func testAmoreRebrandReplacesReservedMascotWithoutRemovingOriginalPageTypes() throws {
        let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("vendor/poki/native/ios-app/Poki")
        let home = try String(contentsOf: vendor.appendingPathComponent("Chat/HomeView.swift"), encoding: .utf8)
        let connection = try String(contentsOf: vendor.appendingPathComponent("Chat/PokiDetailsView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("struct ChatTopBar"))
        XCTAssertTrue(home.contains("struct PokiHead"))
        XCTAssertTrue(home.contains("struct HomePage"))
        XCTAssertTrue(connection.contains("struct ConnectionView"))
        XCTAssertTrue(connection.contains("struct AdvancedSettingsView"))
        XCTAssertFalse(home.contains("PokiBear"))
    }
}
