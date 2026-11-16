import Foundation
import XCTest
@testable import AmorePluginArchive

final class ArchiveTests: XCTestCase {
    private var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures"))
    }
    func testDeflatedZIPCanBeImportedWithoutLinux() throws {
        let prepared = try PluginArchive.prepare(from: fixture("valid-deflated"))
        defer { PluginArchive.discard(prepared) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.pluginDirectory.appendingPathComponent("index.js").path))
        let manifest = try JSONSerialization.jsonObject(with: prepared.manifestData) as? [String: Any]
        XCTAssertEqual(manifest?["id"] as? String, "io.amore.echo")
    }
    func testStoredZIPAndWrappedGitHubRelease() throws {
        for name in ["valid-stored", "wrapped-release"] {
            let prepared = try PluginArchive.prepare(from: fixture(name))
            XCTAssertTrue(prepared.manifestData.count > 0)
            let workspace = prepared.workspace
            PluginArchive.discard(prepared)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        }
    }
    func testGenericFileExtensionStillAcceptsZIPContent() throws {
        let file = root.appendingPathExtension("download")
        try FileManager.default.copyItem(at: fixture("valid-deflated"), to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let prepared = try PluginArchive.prepare(from: file)
        defer { PluginArchive.discard(prepared) }
        XCTAssertFalse(prepared.manifestData.isEmpty)
    }
    func testEvansRepoZIPIsNotMisclassifiedByFolderPickerMode() throws {
        let folder = root
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let selected = folder.appendingPathComponent("evans-repo.zip")
        try FileManager.default.copyItem(at: fixture("wrapped-release"), to: selected)
        for folderHint in [false, true] {
            let prepared = try PluginArchive.prepare(from: selected, folder: folderHint)
            XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.pluginDirectory.appendingPathComponent("index.js").path))
            PluginArchive.discard(prepared)
        }
    }
    func testSelectedProviderAliasToZIPCanBeRead() throws {
        let folder = root
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let alias = folder.appendingPathComponent("evans-repo.zip")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture("valid-deflated"))
        let prepared = try PluginArchive.prepare(from: alias, folder: true)
        defer { PluginArchive.discard(prepared) }
        XCTAssertFalse(prepared.manifestData.isEmpty)
    }
    func testInvalidZIPReportsArchiveErrorNotUnsafeFilename() throws {
        let folder = root
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let selected = folder.appendingPathComponent("evans-repo.zip")
        try Data("not a zip".utf8).write(to: selected)
        XCTAssertThrowsError(try PluginArchive.prepare(from: selected, folder: true)) { error in
            guard case PluginArchiveError.invalid = error else {
                XCTFail("Wrong failure classification: \(error)")
                return
            }
        }
    }
    func testEvansMetadataReportsTheActualRequiredHost() throws {
        XCTAssertThrowsError(try PluginArchive.inspect(from: fixture("evans-dsh-metadata"))) { error in
            guard case PluginArchiveError.unsupportedPackage(let name, let runtime) = error else {
                return XCTFail("Expected incompatible host, got \(error)")
            }
            XCTAssertEqual(name, "dsh-purge")
            XCTAssertTrue(runtime.contains("Node.js"))
            XCTAssertTrue(runtime.contains("Cordis"))
        }
    }

    func testValidAmoreJSONCanUseAnyFilename() throws {
        for name in ["renamed-config", "named-package-config", "invalid-canonical-with-valid-config"] {
            let prepared = try PluginArchive.prepare(from: fixture(name))
            defer { PluginArchive.discard(prepared) }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.manifestData) as? [String: Any])
            XCTAssertEqual(object["id"] as? String, "io.amore.echo")
            XCTAssertFalse(prepared.configurationFileName.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.pluginDirectory.appendingPathComponent("index.js").path))
        }
    }

    func testMultipleValidJSONsRequireExplicitSelection() throws {
        let inspected = try PluginArchive.inspect(from: fixture("multiple-configs"))
        defer { PluginArchive.discard(inspected) }
        XCTAssertEqual(inspected.candidates.map(\.relativePath), ["first.json", "second.json"])
        let chosen = try XCTUnwrap(inspected.candidates.last)
        let prepared = try PluginArchive.prepare(inspected, configuration: chosen)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.manifestData) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "io.amore.alternative")
        XCTAssertEqual(prepared.configurationFileName, "second.json")
        XCTAssertThrowsError(try PluginArchive.prepare(from: fixture("multiple-configs"))) { error in
            guard case PluginArchiveError.multipleManifests = error else {
                return XCTFail("Must not silently select a JSON")
            }
        }
    }

    func testNpmMetadataIsNotSilentlyRewrittenIntoAmore() throws {
        XCTAssertThrowsError(try PluginArchive.prepare(from: fixture("npm-only"))) { error in
            guard case PluginArchiveError.unsupportedPackage(let name, let runtime) = error else {
                return XCTFail("Expected incompatible package diagnostic")
            }
            XCTAssertEqual(name, "tiny-node-package")
            XCTAssertTrue(runtime.contains("Node.js"))
        }
    }

    func testFolderIsDetectedWithoutFolderPickerHint() throws {
        let source = root
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("{}".utf8).write(to: source.appendingPathComponent("manifest.json"))
        let prepared = try PluginArchive.prepare(from: source, folder: false)
        defer { PluginArchive.discard(prepared) }
        XCTAssertEqual(prepared.manifestData, Data("{}".utf8))
    }
    func testFolderImport() throws {
        let source = root
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("{}".utf8).write(to: source.appendingPathComponent("manifest.json"))
        let prepared = try PluginArchive.prepare(from: source, folder: true)
        defer { PluginArchive.discard(prepared) }
        XCTAssertEqual(prepared.manifestData, Data("{}".utf8))
    }
    func testTraversalSymlinksAndDuplicatesAreRejected() throws {
        for name in ["traversal", "absolute", "symlink", "duplicate"] {
            XCTAssertThrowsError(try PluginArchive.prepare(from: fixture(name)), name)
        }
    }
    func testLimitsAndMissingManifest() throws {
        for name in ["too-many", "too-large", "missing-manifest", "two-manifests", "invalid"] {
            XCTAssertThrowsError(try PluginArchive.prepare(from: fixture(name)), name)
        }
    }
    func testDamagedAndEncryptedArchivesAreRejected() throws {
        for name in ["central-truncated", "valid-encrypted-flag"] {
            XCTAssertThrowsError(try PluginArchive.prepare(from: fixture(name)), name)
        }
    }
    func testHiddenFolderSymlinkIsRejected() throws {
        let folder = root
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(".escape"),
                                                   withDestinationURL: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try PluginArchive.prepare(from: folder, folder: true))
    }
    func testPathsCannotEscape() {
        for path in ["../outside", "/outside", "a/../../outside", "C:/outside", "a\\outside", "a\0outside"] {
            XCTAssertThrowsError(try PluginArchive.destination(path, under: root))
        }
    }
    func testExistingSymlinkCannotEscape() throws {
        let folder = root
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"),
                                                   withDestinationURL: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try PluginArchive.destination("escape/outside", under: folder))
    }
}
