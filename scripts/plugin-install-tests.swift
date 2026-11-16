import Foundation
import XCTest
import AmorePluginArchive
@testable import InstallerUnderTest

final class InstallerTests: XCTestCase {
    func testZIPToInstalledJSON() async throws {
        let zip = try XCTUnwrap(Bundle.module.url(forResource: "echo", withExtension: "zip"))
        let prepared = try PluginArchive.prepare(from: zip)
        defer { PluginArchive.discard(prepared) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AmorePluginInstaller(rootDirectory: root.appendingPathComponent("Plugins"))
        let record = try await installer.installPrepared(prepared, approvedPermissions: [])
        XCTAssertEqual(record.id, "io.amore.echo")
        XCTAssertFalse(record.enabled)
        let all = try await installer.installedPlugins()
        XCTAssertEqual(all, [record])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Plugins/io.amore.echo/1.0.0/index.js").path))
        let data = try Data(contentsOf: root.appendingPathComponent("installed.json"))
        XCTAssertEqual(try JSONDecoder().decode([AmoreInstalledPlugin].self, from: data), [record])
        try await installer.uninstall(id: record.id)
        let remaining = try await installer.installedPlugins()
        XCTAssertEqual(remaining.count, 0)
    }

    func testCorruptRegistryIsNotOverwritten() async throws {
        let zip = try XCTUnwrap(Bundle.module.url(forResource: "echo", withExtension: "zip"))
        let prepared = try PluginArchive.prepare(from: zip)
        defer { PluginArchive.discard(prepared) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let damaged = Data("corrupt registry".utf8)
        try damaged.write(to: root.appendingPathComponent("installed.json"))
        let installer = AmorePluginInstaller(rootDirectory: root.appendingPathComponent("Plugins"))
        do {
            _ = try await installer.installPrepared(prepared, approvedPermissions: [])
            XCTFail("Damaged registry must stop installation")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("installed.json")), damaged)
    }

    func testSameVersionReinstallLeavesValidRecord() async throws {
        let zip = try XCTUnwrap(Bundle.module.url(forResource: "echo", withExtension: "zip"))
        let prepared = try PluginArchive.prepare(from: zip)
        defer { PluginArchive.discard(prepared) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AmorePluginInstaller(rootDirectory: root.appendingPathComponent("Plugins"))
        _ = try await installer.installPrepared(prepared, approvedPermissions: [])
        let latest = try await installer.installPrepared(prepared, approvedPermissions: [])
        let all = try await installer.installedPlugins()
        XCTAssertEqual(all, [latest])
        let marker = root.appendingPathComponent("Plugins/io.amore.echo/.install-transaction.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
