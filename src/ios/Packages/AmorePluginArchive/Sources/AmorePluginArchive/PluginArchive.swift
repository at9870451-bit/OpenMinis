import Foundation
import ZIPFoundation

/// Failure returned before plugin code is installed or executed.
public enum PluginArchiveError: LocalizedError, Sendable {
    case invalid(String)
    case unsafePath(String)
    case tooLarge
    case tooManyFiles
    case missingManifest
    case multipleManifests
    case checksum(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return "ZIP: \(message)"
        case .unsafePath(let path): return "Unsafe plugin path: \(path)"
        case .tooLarge: return "Plugin package exceeds the 10 MB limit."
        case .tooManyFiles: return "Plugin package exceeds the 500 file limit."
        case .missingManifest: return "No manifest.json found. Select a plugin ZIP, not a source-only archive."
        case .multipleManifests: return "The package contains multiple plugins. Import one plugin at a time."
        case .checksum(let path): return "ZIP checksum failed: \(path)"
        }
    }
}

/// Immutable handoff from the I/O worker to the app's permission confirmation.
public struct PreparedPluginArchive: Sendable {
    public let workspace: URL
    public let pluginDirectory: URL
    public let manifestData: Data
}

/// ZIP/folder importer; never boots a Linux guest and never runs plugin code.
public enum PluginArchive {
    public static let maximumBytes = 10 * 1024 * 1024
    public static let maximumEntries = 500

    /// Copies a security-scoped selection to private staging and validates all paths.
    /// Call from an actor or a detached task, never a View's synchronous callback.
    public static func prepare(from selected: URL, folder: Bool = false) throws -> PreparedPluginArchive {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("amore-plugin-import-" + UUID().uuidString)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let scoped = selected.startAccessingSecurityScopedResource()
        defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
        do {
            let snapshot = workspace.appendingPathComponent("selection")
            try coordinatedCopy(selected, to: snapshot, folder: folder)
            let values = try snapshot.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isFolder = values.isDirectory == true
            if !isFolder {
                let archiveSize = values.fileSize ?? 0
                guard archiveSize <= maximumBytes else { throw PluginArchiveError.tooLarge }
                let handle = try FileHandle(forReadingFrom: snapshot)
                let signature = try handle.read(upToCount: 4) ?? Data()
                try? handle.close()
                guard signature.starts(with: Data([0x50, 0x4b])),
                      signature.count == 4,
                      (signature[2] == 0x03 && signature[3] == 0x04
                       || signature[2] == 0x05 && signature[3] == 0x06
                       || signature[2] == 0x07 && signature[3] == 0x08) else {
                    throw PluginArchiveError.invalid("Selected file is not a ZIP archive")
                }
            }
            let output = workspace.appendingPathComponent("contents", isDirectory: true)
            if isFolder {
                try validateDirectory(snapshot)
                try fm.moveItem(at: snapshot, to: output)
            } else {
                try extract(snapshot, to: output)
            }
            let plugin = try locateManifest(in: output)
            try validateDirectory(plugin)
            let manifest = plugin.appendingPathComponent("manifest.json")
            let size = try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 256 * 1024 else { throw PluginArchiveError.tooLarge }
            return PreparedPluginArchive(workspace: workspace, pluginDirectory: plugin,
                                         manifestData: try Data(contentsOf: manifest))
        } catch {
            try? fm.removeItem(at: workspace)
            throw error
        }
    }

    /// Removes only the unique staging directory owned by this operation.
    public static func discard(_ prepared: PreparedPluginArchive) {
        try? FileManager.default.removeItem(at: prepared.workspace)
    }

    /// Validates every entry before writing, then checks each decoded CRC32.
    public static func extract(_ url: URL, to root: URL) throws {
        let expectedCount = try ZIPPreflight.validate(url)
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw PluginArchiveError.invalid(error.localizedDescription) }
        var count = 0
        var total: UInt64 = 0
        var paths = Set<String>()
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            guard count <= maximumEntries else { throw PluginArchiveError.tooManyFiles }
            let target = try destination(entry.path, under: root)
            guard paths.insert(target.path.lowercased()).inserted else {
                throw PluginArchiveError.invalid("Duplicate entry: " + entry.path)
            }
            guard entry.type != .symlink else { throw PluginArchiveError.unsafePath(entry.path) }
            total += UInt64(entry.uncompressedSize)
            guard total <= UInt64(maximumBytes) else { throw PluginArchiveError.tooLarge }
        }
        guard count == expectedCount else {
            throw PluginArchiveError.invalid("Incomplete ZIP entry iteration")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            var writtenTotal = 0
            var extractedCount = 0
            for entry in archive {
                try Task.checkCancellation()
                extractedCount += 1
                guard extractedCount <= expectedCount else {
                    throw PluginArchiveError.invalid("Unexpected ZIP entry")
                }
                let target = try destination(entry.path, under: root)
                if entry.type == .directory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: target.path, contents: nil) else {
                    throw PluginArchiveError.invalid("Cannot write " + entry.path)
                }
                let sink = try FileHandle(forWritingTo: target)
                defer { try? sink.close() }
                var entryBytes = 0
                let crc = try archive.extract(entry, bufferSize: 64 * 1024) { chunk in
                    try Task.checkCancellation()
                    entryBytes += chunk.count
                    writtenTotal += chunk.count
                    guard writtenTotal <= maximumBytes,
                          entryBytes <= Int(entry.uncompressedSize) else { throw PluginArchiveError.tooLarge }
                    try sink.write(contentsOf: chunk)
                }
                guard crc == entry.checksum, entryBytes == Int(entry.uncompressedSize) else {
                    throw PluginArchiveError.checksum(entry.path)
                }
            }
            guard extractedCount == expectedCount else {
                throw PluginArchiveError.invalid("Incomplete ZIP extraction")
            }
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    /// Lexical and canonical containment check, also used by the regression tests.
    public static func destination(_ path: String, under root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.contains("\0"), !path.contains(":") else {
            throw PluginArchiveError.unsafePath(path)
        }
        let parts = path.split(separator: "/")
        guard !parts.contains(".."), !parts.isEmpty else { throw PluginArchiveError.unsafePath(path) }
        let target = root.standardizedFileURL.appendingPathComponent(path).standardizedFileURL
        let canonicalRoot = canonicalPathIncludingMissingTail(root)
        let canonicalTarget = canonicalPathIncludingMissingTail(target)
        guard canonicalTarget.path.hasPrefix(canonicalRoot.path + "/") else {
            throw PluginArchiveError.unsafePath(path)
        }
        return target
    }

    /// `resolvingSymlinksInPath()` does not resolve an absent leaf. Resolve the
    /// deepest existing ancestor, then append the missing components back.
    private static func canonicalPathIncludingMissingTail(_ url: URL) -> URL {
        var probe = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            tail.insert(probe.lastPathComponent, at: 0)
            probe = parent
        }
        return tail.reduce(probe.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
    }

    /// Selection mode is only a picker hint. File Provider metadata and stale
    /// SwiftUI presentation state must never classify an ordinary ZIP as a folder.
    private static func coordinatedCopy(_ source: URL, to target: URL, folder: Bool = false) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                let fm = FileManager.default
                let resolved = readable.standardizedFileURL.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                if isDirectory.boolValue {
                    try validateDirectory(resolved)
                } else {
                    let values = try resolved.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true else {
                        throw PluginArchiveError.invalid("Choose a ZIP file or a plugin folder")
                    }
                    guard (values.fileSize ?? 0) <= maximumBytes else { throw PluginArchiveError.tooLarge }
                }
                try fm.copyItem(at: resolved, to: target)
                if isDirectory.boolValue { try validateDirectory(target) }
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    private static func locateManifest(in root: URL) throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: []) else {
            throw PluginArchiveError.missingManifest
        }
        for case let file as URL in walker {
            if file.pathComponents.contains("__MACOSX") { continue }
            if file.lastPathComponent == "manifest.json",
               try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                candidates.append(file.deletingLastPathComponent())
            }
        }
        guard !candidates.isEmpty else { throw PluginArchiveError.missingManifest }
        guard candidates.count == 1, let only = candidates.first else { throw PluginArchiveError.multipleManifests }
        return only
    }

    private static func validateDirectory(_ root: URL) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        let rootInfo = try root.resourceValues(forKeys: keys)
        guard rootInfo.isDirectory == true, rootInfo.isSymbolicLink != true else {
            throw PluginArchiveError.unsafePath(root.lastPathComponent)
        }
        var enumerationError: Error?
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [],
                errorHandler: { _, error in enumerationError = error; return false }) else {
            throw PluginArchiveError.missingManifest
        }
        var count = 0
        var bytes = 0
        for case let file as URL in walker {
            try Task.checkCancellation()
            count += 1
            guard count <= maximumEntries else { throw PluginArchiveError.tooManyFiles }
            let info = try file.resourceValues(forKeys: keys)
            guard info.isSymbolicLink != true,
                  info.isRegularFile == true || info.isDirectory == true else {
                throw PluginArchiveError.unsafePath(file.lastPathComponent)
            }
            if info.isRegularFile == true { bytes += info.fileSize ?? 0 }
            guard bytes <= maximumBytes else { throw PluginArchiveError.tooLarge }
        }
        if let enumerationError { throw enumerationError }
    }
}
