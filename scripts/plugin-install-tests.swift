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

    func testRenamedJSONIsInstalledAndCanonicalManifestCanBeLoaded() async throws {
        let zip = try XCTUnwrap(Bundle.module.url(forResource: "renamed-config", withExtension: "zip"))
        let prepared = try PluginArchive.prepare(from: zip)
        defer { PluginArchive.discard(prepared) }
        XCTAssertEqual(prepared.configurationFileName, "configuration.json")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AmorePluginInstaller(rootDirectory: root.appendingPathComponent("Plugins"))
        let record = try await installer.installPrepared(prepared, approvedPermissions: [])
        XCTAssertEqual(record.configurationFileName, "configuration.json")
        let installed = root.appendingPathComponent("Plugins/io.amore.echo/1.0.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("configuration.json").path))
        let json = try Data(contentsOf: installed.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(AmorePluginManifest.self, from: json)
        XCTAssertEqual(manifest.id, record.id)
        XCTAssertEqual(manifest.entry, "index.js")
        let records = try await installer.installedPlugins()
        XCTAssertEqual(records.first?.configurationFileName, "configuration.json")
    }

    @MainActor
    func testJSONConfigurationEntryLoadsInActualJavaScriptCoreHost() async throws {
        let zip = try XCTUnwrap(Bundle.module.url(forResource: "renamed-config", withExtension: "zip"))
        let prepared = try PluginArchive.prepare(from: zip)
        defer { PluginArchive.discard(prepared) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AmorePluginInstaller(rootDirectory: root.appendingPathComponent("Plugins"))
        let record = try await installer.installPrepared(prepared, approvedPermissions: [])
        let base = root.appendingPathComponent("Plugins/io.amore.echo/1.0.0")
        let manifest = try JSONDecoder().decode(AmorePluginManifest.self,
            from: Data(contentsOf: base.appendingPathComponent("manifest.json")))
        let entry = try XCTUnwrap(manifest.entry)
        let source = try String(contentsOf: PluginArchive.destination(entry, under: base), encoding: .utf8)
        let host = AmoreJSPluginHost(pluginID: record.id, permissions: record.permissions)
        XCTAssertEqual(try host.load(source: source), ["echo"])
        let output = try host.call(tool: "echo", argumentsJSON: "{\"text\":\"JSON entry works\"}")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
        XCTAssertEqual(object["text"], "JSON entry works")
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
