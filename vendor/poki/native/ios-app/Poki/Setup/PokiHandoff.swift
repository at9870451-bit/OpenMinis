import CryptoKit
import Foundation

/// What Poki and the installer on the Mac (`bin/install-iphone.mjs`) tell each other through Poki's
/// container, Documents/PokiSetup/, which Poki Setup or Xcode's devicectl reach over USB:
/// - `poki-hello.json` (`poki.hello/1`), written by Poki whenever it runs: its version (a new one is
///   the installer's sign that Poki is open), the public half of a key this phone made for a model
///   key, the key it last took, and whether the local connection answers, with one sentence for the
///   person when it does not. Nothing in it is secret.
/// - `model-key.json` (`poki.model-key/1`), written by the installer: a model key sealed to that public
///   key (`ModelKeySeal`). Poki takes it once, deletes it and makes a new key pair.
enum PokiHandoff {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("AmorePokiSetup", isDirectory: true)
    }
    static var helloFile: URL { folder.appendingPathComponent("amore-poki-hello.json") }
    static var sealedKeyFile: URL { folder.appendingPathComponent("model-key.json") }

    private static let keyAccount = "handoff.model-key"
    private static let importedKey = "handoff.imported"

    /// The phone's key for a sealed model key: in the Secure Enclave, which never lets it out, where
    /// there is one; a software key kept in this device's Keychain on a simulator.
    struct PhoneKey {
        let publicKey: P256.KeyAgreement.PublicKey
        let agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret
    }

    static func phoneKey() -> PhoneKey? {
        if let stored = try? Keychain.read(keyAccount), let kind = stored.first {
            let body = stored.dropFirst()
            if kind == 1, let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: body) {
                return PhoneKey(publicKey: key.publicKey) { try key.sharedSecretFromKeyAgreement(with: $0) }
            }
            if kind == 0, let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: body) {
                return PhoneKey(publicKey: key.publicKey) { try key.sharedSecretFromKeyAgreement(with: $0) }
            }
        }
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey() {
            try? Keychain.write(Data([1]) + key.dataRepresentation, account: keyAccount)
            return PhoneKey(publicKey: key.publicKey) { try key.sharedSecretFromKeyAgreement(with: $0) }
        }
        let key = P256.KeyAgreement.PrivateKey()
        try? Keychain.write(Data([0]) + key.rawRepresentation, account: keyAccount)
        return PhoneKey(publicKey: key.publicKey) { try key.sharedSecretFromKeyAgreement(with: $0) }
    }

    struct Imported: Codable, Equatable { let key_id: String; let provider: String; let at: String }

    /// Takes a sealed model key the installer left, once: saves it as that provider's key, makes it the
    /// chat's provider, deletes the file and the key pair. A file that does not open is deleted too
    /// (the installer seals again for the next key). Returns what happened, for the log; never the key.
    static func takeSealedKey(bundleID: String = Bundle.main.bundleIdentifier ?? "") -> String? {
        let file = sealedKeyFile
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        guard let key = phoneKey() else { return "a sealed model key came, but this phone has no key to open it" }
        let id = ModelKeySeal.keyID(key.publicKey)
        do {
            let opened = try ModelKeySeal.open(data, publicKey: key.publicKey, bundleID: bundleID, agree: key.agree)
            guard let provider = ModelProvider(rawValue: opened.provider), provider.wired, !provider.signsIn else { return "a sealed key for \(opened.provider), which Poki cannot use, was dropped" }
            try ModelKeys.save(opened.secret, for: provider)
            ModelKeys.selectedProvider = provider
            Keychain.delete(keyAccount)
            let imported = Imported(key_id: id, provider: provider.rawValue, at: ISO8601DateFormatter().string(from: Date()))
            UserDefaults.standard.set(try? JSONEncoder().encode(imported), forKey: importedKey)
            return "took the \(provider.rawValue) key Poki Setup sealed to this phone"
        } catch {
            return "a sealed model key did not open (\(error)); it was dropped"
        }
    }

    static var imported: Imported? {
        UserDefaults.standard.data(forKey: importedKey).flatMap { try? JSONDecoder().decode(Imported.self, from: $0) }
    }

    nonisolated(unsafe) private static var lastWritten: Data?

    /// Writes the hello when what it says changed (and on the first call of each launch).
    static func writeHello(loopbackWorking: Bool, loopbackSay: String?) {
        guard let key = phoneKey() else { return }
        let info = Bundle.main.infoDictionary
        let offer: [String: String] = ["kem": ModelKeySeal.kem, "public_key": key.publicKey.x963Representation.base64URL, "key_id": ModelKeySeal.keyID(key.publicKey)]
        var loopback: [String: Any] = ["working": loopbackWorking]
        if !loopbackWorking { loopback["say"] = loopbackSay ?? "" }
        var hello: [String: Any] = ["schema": "poki.hello/1", "model_key": offer, "loopback": loopback]
        hello["version"] = info?["CFBundleShortVersionString"] as? String ?? "?"
        hello["build"] = info?["CFBundleVersion"] as? String ?? "?"
        if let update = PokiUpdateInfo.read(app: .main, channelFile: AppFiles.support.appendingPathComponent("signer/state/channel.json"), requestFile: folder.appendingPathComponent("update-request.json")) {
            hello["update"] = update
        }
        if let imported, let data = try? JSONEncoder().encode(imported), let object = try? JSONSerialization.jsonObject(with: data) { hello["imported"] = object }
        guard let content = try? JSONSerialization.data(withJSONObject: hello, options: [.sortedKeys]), content != lastWritten else { return }
        hello["at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: hello, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if (try? data.write(to: helloFile, options: .atomic)) != nil { lastWritten = content }
    }

    /// Tests: back to a phone that never talked to the installer.
    static func forget() {
        Keychain.delete(keyAccount)
        UserDefaults.standard.removeObject(forKey: importedKey)
        lastWritten = nil
        try? FileManager.default.removeItem(at: helloFile)
        try? FileManager.default.removeItem(at: sealedKeyFile)
    }
}
