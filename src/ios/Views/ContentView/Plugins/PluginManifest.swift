import Foundation

// MARK: - Plugins (manifest v1)

/// Manifest model for the plugin system. Only three kinds exist: a JS sandbox,
/// a remote MCP server, and a declarative prompt template — never native code,
/// which App Store 2.5.2 forbids.
struct AmorePluginManifest: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case js, mcp, prompt }

    struct Tool: Codable, Sendable {
        let name: String
        let description: String
    }

    struct Server: Codable, Sendable {
        let url: URL
        let auth: String
    }

    struct Template: Codable, Sendable {
        let name: String
        let prompt: String
    }

    let schemaVersion: Int
    let id: String
    let name: String
    let version: String
    let minHostVersion: String
    let type: Kind
    let entry: String?
    let description: String
    let permissions: [String]
    let tools: [Tool]
    let server: Server?
    let templates: [Template]?
}

/// Validation applied before anything is installed or enabled.
enum AmorePluginValidation {
    static let fixedPermissions: Set<String> = ["storage", "secrets", "notify"]

    static func validate(_ manifest: AmorePluginManifest,
                         hostVersion: String = "1.26.0") throws -> [String] {
        guard manifest.schemaVersion == 1 else {
            throw NSError(domain: "AmorePlugin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unsupported schemaVersion"])
        }
        guard matches(manifest.id, "^[a-z0-9]+(\\.[a-z0-9][a-z0-9-]*)+$") else {
            throw NSError(domain: "AmorePlugin", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "id must be a reverse-domain name"])
        }
        guard matches(manifest.version, "^(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)(-[0-9A-Za-z]+(?:[0-9A-Za-z.-]*))?(\\+[0-9A-Za-z.-]+)?$") else {
            throw NSError(domain: "AmorePlugin", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "version must be semver"])
        }

        for tool in manifest.tools {
            guard tool.name.count <= 64, matches(tool.name, "^[a-z_]{1,64}$") else {
                throw NSError(domain: "AmorePlugin", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "tool name \(tool.name) is invalid"])
            }
        }

        for permission in manifest.permissions {
            guard isAllowed(permission) else {
                throw NSError(domain: "AmorePlugin", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "permission \(permission) is not allowed"])
            }
        }

        switch manifest.type {
        case .js:
            guard let entry = manifest.entry, entry.hasSuffix(".js"),
                  !entry.contains(".."), !entry.hasPrefix("/") else {
                throw NSError(domain: "AmorePlugin", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "js plugin needs a relative .js entry"])
            }
        case .mcp:
            guard manifest.server != nil else {
                throw NSError(domain: "AmorePlugin", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "mcp plugin needs a server block"])
            }
        case .prompt:
            guard let templates = manifest.templates, !templates.isEmpty else {
                throw NSError(domain: "AmorePlugin", code: 8,
                              userInfo: [NSLocalizedDescriptionKey: "prompt plugin needs templates"])
            }
        }
        return manifest.permissions
    }

    static func isAllowed(_ permission: String) -> Bool {
        if fixedPermissions.contains(permission) { return true }
        guard permission.hasPrefix("network:") else { return false }
        let host = String(permission.dropFirst("network:".count))
        guard !host.isEmpty, !host.contains("/"), !host.contains(":"), !host.contains("*") else { return false }
        return matches(host, "^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$")
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}

/// Reads `Documents/minis/plugins/<id>/manifest.json`. Discovery only — nothing
/// here executes plugin code; the sandbox is a separate, later step.
struct AmoreInstalledPlugins {
    struct Entry: Sendable {
        let manifest: AmorePluginManifest
        let directory: URL
    }

    static func rootDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("minis/plugins", isDirectory: true)
    }

    static func installed() -> [Entry] {
        guard let root = rootDirectory(),
              let folders = try? FileManager.default.contentsOfDirectory(at: root,
                                                                         includingPropertiesForKeys: nil,
                                                                         options: [.skipsHiddenFiles])
        else { return [] }

        return folders.compactMap { folder -> Entry? in
            let manifestURL = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(AmorePluginManifest.self, from: data),
                  (try? AmorePluginValidation.validate(manifest)) != nil
            else { return nil }
            return Entry(manifest: manifest, directory: folder)
        }
        .sorted { $0.manifest.name < $1.manifest.name }
    }
}
