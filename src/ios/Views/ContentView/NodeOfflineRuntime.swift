import Foundation
import CryptoKit

struct NodeOfflineBundleManifest: Decodable, Sendable {
    struct Package: Decodable, Sendable {
        let name: String
        let version: String
        let architecture: String
        let filename: String
        let bytes: Int64
        let sha256: String
    }
    let schemaVersion: Int
    let alpineBranch: String
    let architecture: String
    let nodeVersion: String
    let npmVersion: String
    let packages: [Package]
}

/// Installs only the official signed runtime shipped inside the App. No URLs
/// are fetched here and no user plugin or install hook is evaluated.
actor NodeOfflineRuntime {
    static let shared = NodeOfflineRuntime()
    private var installing = false

    func install() async throws -> String {
        guard !installing else { throw Self.failure(AppLocalized("Another Node installation is running.")) }
        guard ISHKernel.shared.isBooted else {
            throw Self.failure(AppLocalized("The Shell Container is not running yet. Open the terminal once, then try again."))
        }
        installing = true
        defer { installing = false }
        return try await Task.detached(priority: .userInitiated) {
            guard let bundle = Bundle.main.url(forResource: "NodeRuntime", withExtension: nil) else {
                throw Self.failure(AppLocalized("Bundled Node runtime is missing. Reinstall this version of Amore."))
            }
            let manifest = try Self.validate(bundle)
            let stage = "/var/cache/amore-node-runtime/" + UUID().uuidString.lowercased()
            // RootfsManager.stageFiles registers these App-owned files in fakefs.
            // Nothing touches /usr/bin until the guest-side verified apk transaction.
            try RootfsManager.shared.stageFiles(from: bundle, toLinuxDir: stage)
            let command = "sh '\(stage)/install.sh' '\(stage)' 2>&1; status=$?; rm -rf '\(stage)'; exit $status"
            let result = ISHShellExecutor.executeCommandSync(command, timeout: 900, lineCallback: nil)
            let log = result.output + (result.errorOutput.isEmpty ? "" : "\n" + result.errorOutput)
            guard result.error == .none else {
                throw Self.failure(AppLocalized("Offline Node installer could not finish.") + "\n" + String(log.suffix(2400)))
            }
            guard result.exitCode == 0, log.contains("AMORE_NODE_OFFLINE_READY") else {
                throw Self.failure(AppLocalized("Offline Node installation failed.") + "\n" + String(log.suffix(2400)))
            }
            return "Node.js \(manifest.nodeVersion) · npm \(manifest.npmVersion)\n" + String(log.suffix(1600))
        }.value
    }

    private static func validate(_ directory: URL) throws -> NodeOfflineBundleManifest {
        let manifest = try JSONDecoder().decode(NodeOfflineBundleManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.schemaVersion == 1, manifest.architecture == "aarch64", manifest.alpineBranch == "3.21",
              !manifest.packages.isEmpty, manifest.packages.count <= 64 else {
            throw failure(AppLocalized("Bundled Node runtime metadata is invalid."))
        }
        for package in manifest.packages {
            guard package.filename == (package.filename as NSString).lastPathComponent,
                  package.filename.hasSuffix(".apk"), !package.filename.contains(".."),
                  package.architecture == "aarch64", package.bytes > 0 else {
                throw failure(AppLocalized("Bundled Node runtime metadata is invalid."))
            }
            let file = directory.appendingPathComponent(package.filename)
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? 0) == package.bytes else {
                throw failure(AppLocalized("Bundled Node package is missing or damaged.") + " " + package.filename)
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == package.sha256.lowercased() else {
                throw failure(AppLocalized("Bundled Node checksum failed.") + " " + package.filename)
            }
        }
        return manifest
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Amore.NodeRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
