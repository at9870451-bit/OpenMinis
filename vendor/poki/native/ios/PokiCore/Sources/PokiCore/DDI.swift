import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The developer disk image the launcher mounts (its `ddi_dir`), downloaded once into the app's
/// container from the doronz88/DeveloperDiskImage mirror, the files pymobiledevice3 uses. Every
/// payload is checked against the SHA-384 digest its BuildManifest.plist declares. Apple's files are
/// downloaded at run time, never shipped in the app.
///
/// There are two images. iOS 26.4 and later install a Cryptex1 cryptex through cryptexd; earlier
/// iOS has no such install and mounts the personalized image through the image mounter. The
/// launcher picks the same way (`ddi::method_for`), so the directory holds the one this iOS takes.
public enum DeveloperDiskImage {
    public enum Kind: String, Sendable, CaseIterable {
        case cryptex, personalized

        /// The image an iOS version takes: a cryptex from 26.4 on, the personalized image before.
        public static func forSystem(major: Int, minor: Int) -> Kind {
            major > 26 || (major == 26 && minor >= 4) ? .cryptex : .personalized
        }

        /// The image this device takes. Off iOS (tests, tools) it is the cryptex.
        public static var current: Kind {
            #if os(iOS)
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return forSystem(major: version.majorVersion, minor: version.minorVersion)
            #else
            return .cryptex
            #endif
        }

        public var mirror: URL {
            let name = self == .cryptex ? "Xcode_iOS_DDI_Cryptex" : "Xcode_iOS_DDI_Personalized"
            return URL(string: "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/\(name)")!
        }

        public var files: [String] {
            let shared = ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
            return self == .cryptex ? shared + Kind.cryptexOnlyFiles : shared
        }

        /// What only a cryptex has. Their absence is how the launcher tells the two apart when the
        /// phone did not say its iOS version.
        static let cryptexOnlyFiles = ["Image.dmg.cryptex_info", "Image.dmg.root_hash"]

        var payloadKeys: [String] {
            self == .cryptex
                ? ["Cryptex1,GenericDmg", "Cryptex1,GenericTrustCache", "Cryptex1,CryptexInfoPlist", "Cryptex1,GenericVolume"]
                : ["PersonalizedDMG", "LoadableTrustCache"]
        }
    }

    public static let mirror = Kind.cryptex.mirror
    public static let files = Kind.cryptex.files
    static let payloadKeys = Kind.cryptex.payloadKeys

    public struct Problem: Error, CustomStringConvertible { public let description: String }

    /// The build of a verified image in `dir`; throws when anything is missing or does not match.
    @discardableResult
    public static func verify(_ dir: URL, kind: Kind = .current) throws -> String {
        // A cryptex left from before an iOS downgrade, or seeded by a computer: the personalized
        // image never has these files, and the launcher reads their presence.
        if kind == .personalized, Kind.cryptexOnlyFiles.contains(where: { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
            throw Problem(description: "the image here is a cryptex, and this iOS takes the personalized image")
        }
        let payloadKeys = kind.payloadKeys
        let manifestURL = dir.appendingPathComponent("BuildManifest.plist")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Problem(description: "BuildManifest.plist is missing or unreadable")
        }
        let identities = manifest["BuildIdentities"] as? [[String: Any]] ?? []
        let candidates = identities.compactMap { $0["Manifest"] as? [String: Any] }.filter { entries in payloadKeys.allSatisfy { entries[$0] != nil } }
        guard !candidates.isEmpty else {
            throw Problem(description: "BuildManifest.plist has no \(kind == .cryptex ? "Cryptex1" : "personalized image") build identity")
        }
        // The cryptex manifest is checked by its first identity, as before. The personalized
        // manifest lists the same file names with different digests for different chips, so the
        // files are good when they match any one identity whole.
        var first: Problem?
        var hashes: [String: Data] = [:]
        for entries in kind == .cryptex ? Array(candidates.prefix(1)) : candidates {
            do {
                try check(entries, keys: payloadKeys, in: dir, hashes: &hashes)
                return manifest["ProductBuildVersion"] as? String ?? "unknown"
            } catch let problem as Problem {
                if first == nil { first = problem }
                // A missing or unusable file fails for every identity alike.
                if !problem.description.hasSuffix("digest") { throw problem }
            }
        }
        throw first ?? Problem(description: "the image matches no build identity")
    }

    /// Checks one build identity's payloads in `dir`. `hashes` keeps each file's SHA-384 between identities.
    private static func check(_ entries: [String: Any], keys: [String], in dir: URL, hashes: inout [String: Data]) throws {
        for key in keys {
            let entry = entries[key] as? [String: Any]
            guard let path = (entry?["Info"] as? [String: Any])?["Path"] as? String, !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  let digest = entry?["Digest"] as? Data else {
                throw Problem(description: "BuildManifest.plist gives no usable path or digest for \(key)")
            }
            #if canImport(CryptoKit)
            if hashes[path] == nil {
                guard let bytes = try? Data(contentsOf: dir.appendingPathComponent(path)) else { throw Problem(description: "\(path) is missing") }
                hashes[path] = Data(SHA384.hash(data: bytes))
            }
            guard hashes[path] == digest else { throw Problem(description: "\(path) does not match its SHA-384 digest") }
            #else
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) else { throw Problem(description: "\(path) is missing") }
            _ = digest
            #endif
        }
    }

    /// Makes sure `dir` holds a verified image, downloading it when it does not. Files land in a
    /// sibling directory first and move into place only after every digest matches.
    public static func ensure(in dir: URL, kind: Kind = .current, from base: URL? = nil, transport: HTTPTransport = URLSessionTransport(), progress: @Sendable (String) -> Void = { _ in }) async throws -> String {
        if let build = try? verify(dir, kind: kind) { return build }
        let base = base ?? kind.mirror
        let files = kind.files
        let fm = FileManager.default
        let partial = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".partial")
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            for name in files {
                progress("Downloading \(name)…")
                let (status, body) = try await transport.send(method: "GET", url: base.appendingPathComponent(name), body: nil, timeout: 120)
                guard status == 200 else { throw Problem(description: "downloading \(name) failed with HTTP \(status)") }
                try body.write(to: partial.appendingPathComponent(name))
            }
            let build = try verify(partial, kind: kind)
            try? fm.removeItem(at: dir)
            try fm.moveItem(at: partial, to: dir)
            return build
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }
}
