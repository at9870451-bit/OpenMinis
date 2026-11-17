import Foundation
import CoreFoundation

/// A configuration candidate discovered by its JSON contract, not its filename.
public struct PluginConfigurationCandidate: Identifiable, Equatable, Sendable {
    public let relativePath: String
    public let name: String
    public let version: String
    public let kind: String
    public var id: String { relativePath }
}

/// Owns one private extraction workspace until a configuration is selected.
public struct InspectedPluginArchive: Sendable {
    public let workspace: URL
    public let contentsDirectory: URL
    public let candidates: [PluginConfigurationCandidate]
}

/// Detects Amore configurations without executing JavaScript, npm or shell scripts.
enum PluginConfigurationDiscovery {
    static let maximumJSONBytes = 256 * 1024

    static func candidates(in root: URL) throws -> [PluginConfigurationCandidate] {
        let fm = FileManager.default
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = canonicalRoot.pathComponents
        var enumerationError: Error?
        guard let walker = fm.enumerator(at: canonicalRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw PluginArchiveError.missingManifest
        }
        var matches: [PluginConfigurationCandidate] = []
        var canonical: [String] = []
        var foreignPackages: [(name: String, runtime: String)] = []
        for case let file as URL in walker {
            try Task.checkCancellation()
            if file.pathComponents.contains("__MACOSX") { continue }
            guard file.pathExtension.lowercased() == "json" else { continue }
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true else { continue }
            let components = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard components.count > rootComponents.count,
                  Array(components.prefix(rootComponents.count)) == rootComponents else {
                throw PluginArchiveError.unsafePath(file.lastPathComponent)
            }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            if file.lastPathComponent.lowercased() == "manifest.json" { canonical.append(relative) }
            guard (info.fileSize ?? 0) <= maximumJSONBytes else {
                if file.lastPathComponent.lowercased() == "manifest.json" { throw PluginArchiveError.tooLarge }
                continue
            }
            let data = try Data(contentsOf: file)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let candidate = candidate(object, relativePath: relative) {
                matches.append(candidate)
            } else if file.lastPathComponent.lowercased() == "package.json",
                      let foreign = foreignPackage(object) {
                foreignPackages.append(foreign)
            }
        }
        if let enumerationError { throw enumerationError }
        if !matches.isEmpty { return matches.sorted { $0.relativePath < $1.relativePath } }
        // A named manifest may be malformed; pass it to the app's full validator
        // so the user sees the missing/invalid field rather than a filename error.
        if !canonical.isEmpty {
            return canonical.sorted().map {
                PluginConfigurationCandidate(relativePath: $0, name: "manifest.json", version: "", kind: "")
            }
        }
        if let package = foreignPackages.first {
            throw PluginArchiveError.unsupportedPackage(name: package.name, runtime: package.runtime)
        }
        throw PluginArchiveError.missingManifest
    }

    private static func candidate(_ object: [String: Any], relativePath: String) -> PluginConfigurationCandidate? {
        guard let schema = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(),
              let id = object["id"] as? String, !id.isEmpty,
              let name = object["name"] as? String, !name.isEmpty,
              let version = object["version"] as? String, !version.isEmpty,
              let kind = object["type"] as? String, ["js", "mcp", "prompt"].contains(kind),
              object["minHostVersion"] is String,
              object["description"] is String,
              object["permissions"] is [String], object["tools"] is [[String: Any]] else { return nil }
        switch kind {
        case "js": guard object["entry"] is String else { return nil }
        case "mcp": guard object["server"] is [String: Any] else { return nil }
        case "prompt": guard object["templates"] is [[String: Any]] else { return nil }
        default: return nil
        }
        return PluginConfigurationCandidate(relativePath: relativePath, name: name, version: version, kind: kind)
    }

    private static func foreignPackage(_ object: [String: Any]) -> (name: String, runtime: String)? {
        guard let name = object["name"] as? String else { return nil }
        let peers = object["peerDependencies"] as? [String: Any] ?? [:]
        let dependencies = object["dependencies"] as? [String: Any] ?? [:]
        if object["dsh"] != nil || peers["@deepseek-ai/cordis"] != nil
            || dependencies["@deepseek-ai/cordis"] != nil || name == "dsh-purge" {
            return (name, "DeepSeek Harness / Node.js / Cordis")
        }
        if object["main"] != nil || object["exports"] != nil || object["engines"] != nil || object["bin"] != nil {
            return (name, "Node.js / npm")
        }
        return nil
    }
}
