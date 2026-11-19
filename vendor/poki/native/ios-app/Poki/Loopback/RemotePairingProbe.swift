import Foundation

/// This probe stops BEFORE pair-verify. It never opens a tunnel, reads a pairing
/// record, changes trust or proves that automation is authorised.
struct RemotePairingProbeResult: Decodable, Equatable, Sendable {
    let host: String
    let port: UInt16
    let tcpConnected: Bool
    let handshakeOK: Bool
    let stage: String
    let detail: String
    let elapsedMS: Int

    enum CodingKeys: String, CodingKey {
        case host, port, stage, detail
        case tcpConnected = "tcp_connected", handshakeOK = "handshake_ok", elapsedMS = "elapsed_ms"
    }
    var summary: String {
        let result = handshakeOK ? "Remote Pairing 握手响应正常（尚未验证配对密钥）"
            : tcpConnected ? "TCP 已接通，但 Remote Pairing 握手未完成"
            : "TCP 未接通"
        return "\(host):\(port) · \(result) · \(elapsedMS) ms" + (detail.isEmpty ? "" : "\n\(detail)")
    }

    @MainActor
    static func check(port: UInt16, timeout: TimeInterval = 3) async -> Self {
        do {
            return try await SignerBridge.decode(Self.self, ["op": "pairing_probe",
                "device_address": "10.7.0.1", "port": Int(port),
                "timeout_ms": Int(min(6, max(0.5, timeout)) * 1000)])
        } catch {
            // Native bridge/config errors cannot certify a network connection.
            return Self(host: "10.7.0.1", port: port, tcpConnected: false,
                        handshakeOK: false, stage: "bridge", detail: error.localizedDescription, elapsedMS: 0)
        }
    }
}
