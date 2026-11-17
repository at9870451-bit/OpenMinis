import CryptoKit
import Foundation

/// A model key the installer on the Mac sealed to a key this phone made (`poki.model-key/1`, written
/// by `src/install/model-key.mjs`): ephemeral P-256 ECDH, HKDF-SHA256, AES-256-GCM. The additional data
/// binds the schema, the phone key's id, the provider, Poki's bundle id and an expiry, so the file
/// opens only in this Poki, for that provider, before it expires. Only CryptoKit and Foundation, so
/// the same file builds on a Mac for the installer's interop test.
enum ModelKeySeal {
    static let schema = "poki.model-key/1"
    static let kem = "P256-HKDF-SHA256-AES256GCM"

    struct Envelope: Codable {
        let schema: String
        let key_id: String
        let provider: String
        let bundle_id: String
        let expires_at: String
        let epk: String
        let nonce: String
        let ct: String
    }

    enum Failure: Error, Equatable { case notSealedKey, otherApp, otherKey, expired, broken }

    /// The id the hello file names a public key by: the first 16 hex digits of its SHA-256.
    static func keyID(_ publicKey: P256.KeyAgreement.PublicKey) -> String {
        SHA256.hash(data: publicKey.x963Representation).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// The provider and the key. `agree` is the phone's private key (Secure Enclave or software).
    static func open(_ data: Data, publicKey: P256.KeyAgreement.PublicKey, bundleID: String, now: Date = Date(),
                     agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> (provider: String, secret: String) {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data), env.schema == schema else { throw Failure.notSealedKey }
        guard env.bundle_id == bundleID else { throw Failure.otherApp }
        guard env.key_id == keyID(publicKey) else { throw Failure.otherKey }
        guard let expires = withFraction.date(from: env.expires_at) ?? ISO8601DateFormatter().date(from: env.expires_at) else { throw Failure.broken }
        guard expires > now else { throw Failure.expired }
        guard let epkBytes = base64URL(env.epk), let nonceBytes = base64URL(env.nonce), let body = base64URL(env.ct), body.count > 16,
              let epk = try? P256.KeyAgreement.PublicKey(x963Representation: epkBytes) else { throw Failure.broken }
        let salt = epkBytes + publicKey.x963Representation
        let key = try agree(epk).hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(schema.utf8), outputByteCount: 32)
        let aad = Data([env.schema, env.key_id, env.provider, env.bundle_id, env.expires_at].joined(separator: "\n").utf8)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceBytes), ciphertext: body.dropLast(16), tag: body.suffix(16))
            let plain = try AES.GCM.open(box, using: key, authenticating: aad)
            struct Payload: Decodable { let secret: String }
            let secret = try JSONDecoder().decode(Payload.self, from: plain).secret
            return (env.provider, secret)
        } catch { throw Failure.broken }
    }

    /// The installer writes `expires_at` with milliseconds (JavaScript's toISOString).
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func base64URL(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
