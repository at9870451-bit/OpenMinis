import CryptoKit
import Foundation
import PokiCore
import Security

/// The phone's relay identity (docs/ios-core.md, section 1): an Ed25519 key made once and kept in the
/// keychain, the label derived from it, and the connector secrets, one per MCP client, each revocable.
/// The relay never sees a secret, only its sha256.
struct ConnectorSecret: Codable, Identifiable, Hashable {
    var id: String { secret }
    var name: String
    var secret: String
    var created: Date
    /// The owner named it: an agent connecting later keeps that name.
    var named = false
    /// The first agent that connected through it ("Claude", "Cursor"): its name (unless the owner
    /// named it) and its icon.
    var agent: String?
    var hash: String { SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined() }

    init(name: String, secret: String, created: Date, named: Bool = false, agent: String? = nil) {
        self.name = name; self.secret = secret; self.created = created; self.named = named; self.agent = agent
    }

    // Connectors saved before these fields were added: a name other than "Connector N" was the owner's.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        secret = try c.decode(String.self, forKey: .secret)
        created = try c.decode(Date.self, forKey: .created)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        named = try c.decodeIfPresent(Bool.self, forKey: .named) ?? !Self.isDefault(name)
    }

    static func isDefault(_ name: String) -> Bool { name.range(of: #"^Connector \d+$"#, options: .regularExpression) != nil }
}

@MainActor
@Observable
final class RelayIdentity {
    private static let keyAccount = "relay.ed25519"
    private static let secretsAccount = "relay.secrets"

    private(set) var label = ""
    private(set) var secrets: [ConnectorSecret] = []
    private(set) var error: String?
    private var key: Curve25519.Signing.PrivateKey?

    init() { load() }

    var publicKey: Data? { key?.publicKey.rawRepresentation }
    var signingKey: Curve25519.Signing.PrivateKey? { key }
    var accessHashes: [String] { secrets.map(\.hash) }

    func url(for secret: ConnectorSecret, relay: RelayAddress) -> URL {
        relay.connectorBase.appendingPathComponent(label).appendingPathComponent(secret.secret).appendingPathComponent("mcp")
    }

    func sign(_ message: Data) throws -> Data {
        guard let key else { throw NSError(domain: "Poki", code: 1, userInfo: [NSLocalizedDescriptionKey: "no relay key"]) }
        return try key.signature(for: message)
    }

    func addSecret(name: String) -> ConnectorSecret {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let taken = Set(secrets.map(\.name))
        var next = 1
        while taken.contains("Connector \(next)") { next += 1 }
        let secret = ConnectorSecret(name: name.isEmpty ? "Connector \(next)" : name, secret: Data(bytes).base64URL, created: Date(), named: !name.isEmpty)
        secrets.append(secret)
        save()
        return secret
    }

    /// The owner's own name for it; an agent connecting later does not change it.
    func rename(_ secret: ConnectorSecret, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = secrets.firstIndex(where: { $0.secret == secret.secret }) else { return }
        secrets[i].name = name
        secrets[i].named = true
        save()
    }

    /// An agent connected through the connector with this hash: the first one gives it its icon, and
    /// its name unless the owner named it.
    func noteAgent(hash: String, client: String) {
        let client = client.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !client.isEmpty, let i = secrets.firstIndex(where: { $0.hash == hash }), secrets[i].agent == nil else { return }
        secrets[i].agent = client
        if !secrets[i].named {
            let taken = Set(secrets.enumerated().filter { $0.offset != i }.map(\.element.name))
            var name = client, n = 2
            while taken.contains(name) { name = "\(client) \(n)"; n += 1 }
            secrets[i].name = name
        }
        save()
    }

    func revoke(_ secret: ConnectorSecret) {
        secrets.removeAll { $0 == secret }
        save()
    }

    private func load() {
        do {
            if let raw = try Keychain.read(Self.keyAccount) {
                key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            } else {
                let made = Curve25519.Signing.PrivateKey()
                try Keychain.write(made.rawRepresentation, account: Self.keyAccount)
                key = made
            }
            if let data = try Keychain.read(Self.secretsAccount) { secrets = (try? JSONDecoder().decode([ConnectorSecret].self, from: data)) ?? [] }
            label = base32(key!.publicKey.rawRepresentation)
        } catch {
            self.error = "\(error)"
        }
    }

    private func save() {
        do { try Keychain.write(try JSONEncoder().encode(secrets), account: Self.secretsAccount) }
        catch { self.error = "\(error)" }
    }
}

enum Keychain {
    private static let service = "nz.zheha.poki"

    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return result as? Data
    }

    static func write(_ data: Data, account: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func delete(_ account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
    }
}

extension RelayAddress {
    /// The relay the person entered in Connect, kept across launches. Poki has no default relay.
    static var saved: RelayAddress? {
        get { UserDefaults.standard.string(forKey: "relayAddress").flatMap { RelayAddress($0) } }
        set { UserDefaults.standard.set(newValue?.origin.absoluteString, forKey: "relayAddress") }
    }
}

extension Data {
    /// base64url (RFC 4648 §5) without padding, as `base64URL` makes it.
    init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
