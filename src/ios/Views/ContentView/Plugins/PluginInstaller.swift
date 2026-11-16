import Foundation
import AmorePluginArchive

// MARK: - Plugin installation (Ed25519 verified, installed.json)
//
// A plugin is a *directory* (imported through Files / share sheet). Installing
// never unzips anything inside the app, so there is no zip-slip surface at all.
// The directory is hashed deterministically, the digest is checked against the
// registry value, and the digest itself must carry a valid Ed25519 signature
// from the publisher key.

import CryptoKit

enum AmorePluginInstallError: LocalizedError {
    case notADirectory
    case missingManifest
    case unsupportedSchema(Int)
    case badIdentifier(String)
    case badVersion(String)
    case permissionNotAllowed(String)
    case digestMismatch
    case signatureInvalid
    case idMismatch(expected: String, found: String)
    case versionMismatch(expected: String, found: String)
    case toolNameInvalid(String)
    case alreadyInstalling
    case invalidArchive(String)

    var errorDescription: String? {
        switch self {
        case .notADirectory: return AppLocalized("Plugin package must be a folder")
        case .missingManifest: return AppLocalized("manifest.json is missing")
        case .unsupportedSchema(let v): return "\(AppLocalized("Unsupported schemaVersion")): \(v)"
        case .badIdentifier(let id): return "\(AppLocalized("Invalid plugin id")): \(id)"
        case .badVersion(let v): return "\(AppLocalized("Invalid version")): \(v)"
        case .permissionNotAllowed(let p): return "\(AppLocalized("Permission not allowed")): \(p)"
        case .digestMismatch: return AppLocalized("Package digest does not match the registry")
        case .signatureInvalid: return AppLocalized("Signature check failed")
        case .idMismatch(let e, let f): return "\(AppLocalized("Plugin id mismatch")): \(e) / \(f)"
        case .versionMismatch(let e, let f): return "\(AppLocalized("Version mismatch")): \(e) / \(f)"
        case .toolNameInvalid(let n): return "\(AppLocalized("Invalid tool name")): \(n)"
        case .alreadyInstalling: return AppLocalized("Another install is in progress")
        case .invalidArchive(let message): return AppLocalized("Invalid plugin package") + ": " + message
        }
    }
}

struct AmoreInstalledPlugin: Codable, Equatable, Sendable {
    var id: String
    var version: String
    var enabled: Bool
    var installedAt: Date
    var previousVersion: String?
    var permissions: [String]
}

actor AmorePluginInstaller {
    static let shared = AmorePluginInstaller()

    private let fm = FileManager.default
    private var isBusy = false
    private nonisolated let customRoot: URL?

    init(rootDirectory: URL? = nil) { customRoot = rootDirectory }

    private struct InstallJournal: Codable {
        let record: AmoreInstalledPlugin
        let stagingName: String
        let backupName: String
        let hadPrevious: Bool
    }

    nonisolated var pluginsRoot: URL {
        if let customRoot { return customRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Amore/Plugins", isDirectory: true)
    }

    private var installedFile: URL {
        pluginsRoot.deletingLastPathComponent().appendingPathComponent("installed.json")
    }

    // MARK: Read / write installed.json

    func installedPlugins() throws -> [AmoreInstalledPlugin] {
        try readInstalledStrict()
    }

    private func readInstalledRaw() throws -> [AmoreInstalledPlugin] {
        guard fm.fileExists(atPath: installedFile.path) else { return [] }
        return try JSONDecoder().decode([AmoreInstalledPlugin].self,
            from: Data(contentsOf: installedFile)).sorted { $0.id < $1.id }
    }

    private func readInstalledStrict() throws -> [AmoreInstalledPlugin] {
        let records = try readInstalledRaw()
        try recoverPendingInstalls(records: records)
        return records
    }

    /// A journal spans the directory rename and atomic registry pointer update.
    /// Recovery uses the exact newly installed record, not just the version.
    private func recoverPendingInstalls(records: [AmoreInstalledPlugin]) throws {
        guard fm.fileExists(atPath: pluginsRoot.path) else { return }
        for idRoot in try fm.contentsOfDirectory(at: pluginsRoot, includingPropertiesForKeys: nil) {
            let marker = idRoot.appendingPathComponent(".install-transaction.json")
            guard fm.fileExists(atPath: marker.path) else { continue }
            let journal = try JSONDecoder().decode(InstallJournal.self, from: Data(contentsOf: marker))
            guard journal.record.id == idRoot.lastPathComponent,
                  !journal.record.version.contains("/"), !journal.record.version.contains(".."),
                  journal.stagingName.hasPrefix(".install-"), !journal.stagingName.contains("/"),
                  journal.backupName.hasPrefix(".previous-"), !journal.backupName.contains("/") else {
                throw AmorePluginInstallError.invalidArchive("Invalid install recovery journal")
            }
            let target = idRoot.appendingPathComponent(journal.record.version)
            let staging = idRoot.appendingPathComponent(journal.stagingName)
            let backup = idRoot.appendingPathComponent(journal.backupName)
            if records.contains(journal.record) {
                guard fm.fileExists(atPath: target.path) else {
                    throw AmorePluginInstallError.invalidArchive("Installed plugin directory is missing")
                }
                try? fm.removeItem(at: backup)
            } else if journal.hadPrevious, fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: target)
                try fm.moveItem(at: backup, to: target)
            } else if !journal.hadPrevious {
                try? fm.removeItem(at: target)
            }
            try? fm.removeItem(at: staging)
            try fm.removeItem(at: marker)
        }
    }

    private func writeInstalled(_ list: [AmoreInstalledPlugin]) throws {
        let dir = installedFile.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(list)
        try data.write(to: installedFile, options: .atomic)
    }

    // MARK: Digest

    /// Deterministic digest over (relative path, file bytes) in sorted order,
    /// so the same tree always hashes the same on any machine.
    func digest(ofDirectory dir: URL) throws -> Data {
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw AmorePluginInstallError.notADirectory
        }
        var files: [String] = []
        for case let url as URL in walker {
            let rel = url.path.replacingOccurrences(of: dir.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if rel.isEmpty { continue }
            if rel.hasPrefix(".git") || rel.hasSuffix(".DS_Store") { continue }
            files.append(rel)
        }
        var hasher = SHA256()
        for rel in files.sorted() {
            hasher.update(data: Data(rel.utf8))
            let fileURL = dir.appendingPathComponent(rel)
            if let handle = try? FileHandle(forReadingFrom: fileURL) {
                defer { try? handle.close() }
                while autoreleasepool(invoking: { () -> Bool in
                    guard let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty else { return false }
                    hasher.update(data: chunk)
                    return true
                }) {}
            }
        }
        return Data(hasher.finalize())
    }

    func digestHex(ofDirectory dir: URL) throws -> String {
        try digest(ofDirectory: dir).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Signature

    /// Verifies an Ed25519 signature over the *raw digest bytes*.
    func verifyEd25519(signatureBase64: String, digest: Data, publicKeyBase64: String) -> Bool {
        guard let sigData = Data(base64Encoded: signatureBase64),
              let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(sigData, for: digest)
    }

    // MARK: Install

    @discardableResult
    func install(sourceDirectory: URL,
                 expectedID: String,
                 expectedVersion: String,
                 expectedDigestHex: String,
                 signatureBase64: String,
                 publicKeyBase64: String,
                 approvedPermissions: [String]) throws -> AmoreInstalledPlugin {
        guard !isBusy else { throw AmorePluginInstallError.alreadyInstalling }
        isBusy = true
        defer { isBusy = false }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            throw AmorePluginInstallError.notADirectory
        }

        let manifestURL = sourceDirectory.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw AmorePluginInstallError.missingManifest
        }
        guard let manifest = try? JSONDecoder().decode(AmorePluginManifest.self, from: manifestData) else {
            throw AmorePluginInstallError.missingManifest
        }
        guard manifest.schemaVersion == 1 else {
            throw AmorePluginInstallError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.id == expectedID else {
            throw AmorePluginInstallError.idMismatch(expected: expectedID, found: manifest.id)
        }
        guard manifest.version == expectedVersion else {
            throw AmorePluginInstallError.versionMismatch(expected: expectedVersion, found: manifest.version)
        }
        _ = try AmorePluginValidation.validate(manifest)
        for permission in manifest.permissions {
            guard AmorePluginValidation.isAllowed(permission) else {
                throw AmorePluginInstallError.permissionNotAllowed(permission)
            }
            guard approvedPermissions.contains(permission) else {
                throw AmorePluginInstallError.permissionNotAllowed(permission)
            }
        }

        let digest = try digest(ofDirectory: sourceDirectory)
        let actualHex = digest.map { String(format: "%02x", $0) }.joined()
        guard actualHex.caseInsensitiveCompare(expectedDigestHex) == .orderedSame else {
            throw AmorePluginInstallError.digestMismatch
        }
        guard verifyEd25519(signatureBase64: signatureBase64, digest: digest, publicKeyBase64: publicKeyBase64) else {
            throw AmorePluginInstallError.signatureInvalid
        }

        // Atomic move into Plugins/<id>/<version>, keeping the previous version.
        let idDir = pluginsRoot.appendingPathComponent(manifest.id, isDirectory: true)
        let target = idDir.appendingPathComponent(manifest.version, isDirectory: true)
        try fm.createDirectory(at: idDir, withIntermediateDirectories: true)

        var previous: String?
        if let existing = try readInstalledStrict().first(where: { $0.id == manifest.id }) {
            previous = existing.version
        }
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.copyItem(at: sourceDirectory, to: target)

        var list = try readInstalledStrict().filter { $0.id != manifest.id }
        let record = AmoreInstalledPlugin(id: manifest.id,
                                          version: manifest.version,
                                          enabled: false,
                                          installedAt: Date(),
                                          previousVersion: previous,
                                          permissions: manifest.permissions)
        list.append(record)
        try writeInstalled(list)
        return record
    }

    func setEnabled(_ enabled: Bool, id: String) throws {
        var list = try readInstalledStrict()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].enabled = enabled
        try writeInstalled(list)
    }

    /// Commits a previously staged, validated package only after permission consent.
    /// The actor owns all filesystem work and serialises installed.json updates.
    func installPrepared(_ prepared: PreparedPluginArchive,
                         approvedPermissions: [String]) throws -> AmoreInstalledPlugin {
        let manifest = try JSONDecoder().decode(AmorePluginManifest.self, from: prepared.manifestData)
        _ = try AmorePluginValidation.validate(manifest)
        guard Set(manifest.permissions).isSubset(of: Set(approvedPermissions)) else {
            throw AmorePluginInstallError.permissionNotAllowed("unapproved permission")
        }
        if manifest.type == .js, let entry = manifest.entry {
            let file = try PluginArchive.destination(entry, under: prepared.pluginDirectory)
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
                throw AmorePluginInstallError.invalidArchive("JavaScript entry file is missing: " + entry)
            }
        }
        let idRoot = pluginsRoot.appendingPathComponent(manifest.id, isDirectory: true)
        try fm.createDirectory(at: idRoot, withIntermediateDirectories: true)
        let target = idRoot.appendingPathComponent(manifest.version, isDirectory: true)
        let staging = idRoot.appendingPathComponent(".install-" + UUID().uuidString)
        let backup = idRoot.appendingPathComponent(".previous-" + UUID().uuidString)
        var movedOld = false
        var movedNew = false
        defer { try? fm.removeItem(at: staging) }
        let oldRecords = try readInstalledStrict()
        let existing = oldRecords.first { $0.id == manifest.id }
        let record = AmoreInstalledPlugin(id: manifest.id, version: manifest.version,
            enabled: false, installedAt: Date(),
            previousVersion: existing?.version == manifest.version ? existing?.previousVersion : existing?.version,
            permissions: manifest.permissions)
        let journal = InstallJournal(record: record, stagingName: staging.lastPathComponent,
            backupName: backup.lastPathComponent, hadPrevious: fm.fileExists(atPath: target.path))
        let marker = idRoot.appendingPathComponent(".install-transaction.json")
        do {
            try fm.copyItem(at: prepared.pluginDirectory, to: staging)
            try JSONEncoder().encode(journal).write(to: marker, options: .atomic)
            if fm.fileExists(atPath: target.path) {
                try fm.moveItem(at: target, to: backup)
                movedOld = true
            }
            try fm.moveItem(at: staging, to: target)
            movedNew = true
            var list = oldRecords.filter { $0.id != manifest.id }
            list.append(record)
            try writeInstalled(list)
            if movedOld { try? fm.removeItem(at: backup) }
            try? fm.removeItem(at: marker)
            return record
        } catch {
            if movedNew { try? fm.removeItem(at: target) }
            if movedOld { try? fm.moveItem(at: backup, to: target) }
            try? fm.removeItem(at: marker)
            throw error
        }
    }

    func uninstall(id: String) throws {
        let list = try readInstalledStrict().filter { $0.id != id }
        try writeInstalled(list)
        let idDir = pluginsRoot.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: idDir.path) {
            try fm.removeItem(at: idDir)
        }
    }
}

