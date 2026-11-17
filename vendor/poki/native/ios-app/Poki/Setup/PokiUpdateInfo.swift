import CryptoKit
import Foundation

enum PokiUpdateInfo {
    static func read(app: Bundle, channelFile: URL, requestFile: URL) -> [String: Any]? {
        guard let info = app.infoDictionary,
              let bundleID = app.bundleIdentifier,
              let group = info["PokiAppGroup"] as? String,
              let url = app.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = try? Data(contentsOf: url),
              let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let dict = (try? PropertyListSerialization.propertyList(from: profile.subdata(in: start.lowerBound..<end.upperBound), format: nil)) as? [String: Any],
              let teams = dict["TeamIdentifier"] as? [String], teams.count == 1,
              let certificates = dict["DeveloperCertificates"] as? [Data], certificates.count == 1,
              let entitlements = dict["Entitlements"] as? [String: Any],
              entitlements["application-identifier"] as? String == "\(teams[0]).\(bundleID)",
              let groups = entitlements["com.apple.security.application-groups"] as? [String], groups.contains(group)
        else { return nil }
        var extensions: [String] = []
        if let plugins = app.builtInPlugInsURL, FileManager.default.fileExists(atPath: plugins.path) {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return nil }
            for url in urls where url.pathExtension == "appex" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
                extensions.append(id)
            }
        }
        var channel = "stable"
        if FileManager.default.fileExists(atPath: channelFile.path) {
            guard let data = try? Data(contentsOf: channelFile),
                  let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let value = saved["channel"] as? String,
                  ["stable", "beta", "alpha", "pre-alpha"].contains(value) else { return nil }
            channel = value
        }
        let data = try? Data(contentsOf: requestFile)
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return [
            "schema": "poki.update/1", "nonce": object?["nonce"] as? String ?? "",
            "version": info["CFBundleShortVersionString"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "", "channel": channel,
            "team": teams[0], "bundle_id": bundleID, "app_group": group,
            "certificate_sha256": SHA256.hash(data: certificates[0]).map { String(format: "%02x", $0) }.joined(),
            "extensions": extensions.sorted(),
        ]
    }

}
