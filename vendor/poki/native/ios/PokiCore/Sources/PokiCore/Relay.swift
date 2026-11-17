import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One WebSocket connection: text messages only (frames are JSON, the keepalive is "ping"/"pong").
public protocol WebSocketConnection: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close(code: Int, reason: String)
}

public protocol WebSocketFactory: Sendable {
    func connect(to url: URL) async throws -> WebSocketConnection
}

public final class URLSessionWebSocketFactory: WebSocketFactory {
    let session = URLSession(configuration: .ephemeral)
    public init() {}
    public func connect(to url: URL) async throws -> WebSocketConnection {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 8 << 20
        task.resume()
        return URLSessionSocket(task: task)
    }
}

final class URLSessionSocket: WebSocketConnection, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let s): return s
        case .data(let d): return String(decoding: d, as: UTF8.self)
        @unknown default: return ""
        }
    }
    func close(code: Int, reason: String) {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: Data(reason.utf8))
    }
}

/// The person's own relay, as they enter it: the origin of the Worker they deployed, such as
/// `https://poki-relay.you.workers.dev`. Poki has no default relay.
public struct RelayAddress: Sendable, Equatable {
    /// `scheme://host[:port]`, no path.
    public let origin: URL

    /// Accepts `host`, `https://host`, `https://host/` and `https://host/v1`; `http` only for a local
    /// relay such as `wrangler dev`. Anything else, such as another path, is nil.
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty, parts.query == nil, parts.fragment == nil, parts.user == nil,
              ["", "/", "/v1", "/v1/"].contains(parts.path) else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = parts.port
        guard let url = origin.url else { return nil }
        self.origin = url
    }

    /// Where the phone dials: `wss://host/v1` (`ws` for a local `http` relay).
    public var phoneURL: URL { URL(string: origin.absoluteString.replacingOccurrences(of: "http", with: "ws", options: .anchored) + "/v1")! }
    /// The base of each connector URL: `https://host/v1`.
    public var connectorBase: URL { origin.appendingPathComponent("v1") }
}

/// RFC 4648 base32, lowercase, no padding: the relay label of a public key.
public func base32(_ data: Data) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    var out = "", buffer = 0, bits = 0
    for byte in data {
        buffer = (buffer << 8) | Int(byte)
        bits += 8
        while bits >= 5 {
            out.append(alphabet[(buffer >> (bits - 5)) & 31])
            bits -= 5
        }
        buffer &= (1 << bits) - 1
    }
    if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
    return out
}

/// The phone's side of the relay (docs/ios-core.md, "Relay frames, v1"): dial out, prove the key,
/// answer each request exactly once, keep the connection alive, and dial again when it drops.
final class RelayClient: @unchecked Sendable {
    let baseURL: URL
    weak var host: CoreHost?
    let factory: WebSocketFactory
    let handler: @Sendable (RelayRequest) async -> RelayResponse
    let emit: @Sendable (RelayState) -> Void
    /// An answer that was ready after its connection had dropped: the handler finished, the relay
    /// had already failed the caller, and the answer would be lost (seen on the phone: a three-action
    /// do answered "what was sent is unknown" when the relay reset mid-call).
    var undelivered: (@Sendable (RelayRequest, RelayResponse) -> Void)?
    var appVersion = "1.0"
    var pingEvery = 25.0
    var silentLimit = 60.0
    var maxBackoff = 30.0

    private let state = LockedBox<(running: Bool, socket: WebSocketConnection?, lastHeard: Double, describe: String, maxBody: Int, requestTimeout: Double?, inflight: [String: Task<Void, Never>])>((false, nil, 0, "not started", 4 << 20, nil, [:]))
    private var loop: Task<Void, Never>?

    init(baseURL: URL, host: CoreHost, factory: WebSocketFactory, handler: @escaping @Sendable (RelayRequest) async -> RelayResponse, emit: @escaping @Sendable (RelayState) -> Void) {
        self.baseURL = baseURL
        self.host = host
        self.factory = factory
        self.handler = handler
        self.emit = emit
    }

    var stateDescription: String { state.value.describe }

    func label() throws -> String {
        guard let host else { throw RelayFailure("Poki is shutting down") }
        return base32(try host.signingKey().publicKey)
    }

    /// The MCP address for a connector secret.
    func connectorURL(secret: String) throws -> URL {
        let https = baseURL.absoluteString.replacingOccurrences(of: "wss://", with: "https://").replacingOccurrences(of: "ws://", with: "http://")
        return URL(string: "\(https)/\(try label())/\(secret)/mcp")!
    }

    func start() {
        state.update { $0.running = true }
        loop = Task { [weak self] in
            var attempt = 0
            while let self, self.state.value.running, !Task.isCancelled {
                self.set("connecting", .connecting)
                do {
                    try await self.session { attempt = 0 }
                } catch {
                    self.set("offline: \(error)", .offline("\(error)"))
                }
                guard self.state.value.running else { break }
                attempt += 1
                // 1, 2, 4 … 30 s, jittered, so phones do not dial again in step.
                let delay = min(self.maxBackoff, pow(2, Double(min(attempt - 1, 5))))
                await sleep(seconds: delay * Double.random(in: 0.7...1.3))
            }
        }
    }

    func stop() {
        let (socket, inflight) = state.update { s -> (WebSocketConnection?, [Task<Void, Never>]) in
            s.running = false
            let r = (s.socket, Array(s.inflight.values))
            s.socket = nil
            s.inflight = [:]
            return r
        }
        inflight.forEach { $0.cancel() }
        socket?.close(code: 1000, reason: "stopped")
        loop?.cancel()
        set("stopped", .offline("stopped"))
    }

    func sendAccess() {
        guard let socket = state.value.socket, let host else { return }
        let frame: JSON = ["t": "access", "access": .array(host.accessHashes().prefix(8).map(JSON.string))]
        Task { try? await socket.send(frame.serialized()) }
    }

    private func set(_ describe: String, _ s: RelayState) {
        state.update { $0.describe = describe }
        emit(s)
    }

    /// One connection, from dialing to its end.
    private func session(onReady: () -> Void) async throws {
        guard let host else { return }
        let key = try host.signingKey()
        let label = base32(key.publicKey)
        let url = URL(string: "\(baseURL.absoluteString)/\(label)/connect")!
        let socket = try await withDeadline(15, "connecting to the relay") { [factory] in try await factory.connect(to: url) }
        state.update { $0.socket = socket; $0.lastHeard = now() }
        defer {
            // The calls in flight go on to their end: what they did on the phone is reported through
            // `undelivered` with the next call, instead of being cut short with the connection.
            state.update { s in
                s.inflight = [:]
                if s.socket as AnyObject === socket as AnyObject { s.socket = nil }
            }
            socket.close(code: 1000, reason: "")
        }

        // Handshake: challenge, hello (signed), ready.
        let challenge = try JSON.parse(try await withDeadline(15, "the relay's challenge") { try await socket.receive() })
        guard challenge["t"]?.string == "challenge", let nonce = challenge["nonce"]?.string.flatMap({ Data(base64Encoded: $0) }) else {
            throw RelayFailure("the relay sent no challenge")
        }
        var signed = Data("poki-relay-v1:\(label):".utf8)
        signed.append(nonce)
        let hello: JSON = ["t": "hello", "v": 1, "key": .string(key.publicKey.base64EncodedString()), "sig": .string(try key.sign(signed).base64EncodedString()), "access": .array(host.accessHashes().prefix(8).map(JSON.string)), "app": .string(appVersion)]
        try await socket.send(hello.serialized())
        let ready = try JSON.parse(try await withDeadline(15, "the relay's ready") { try await socket.receive() })
        guard ready["t"]?.string == "ready" else { throw RelayFailure("the relay refused the phone: \(ready["reason"]?.string ?? ready.serialized())") }
        state.update {
            $0.maxBody = ready["max_body"]?.int ?? (4 << 20)
            $0.requestTimeout = ready["req_timeout_ms"]?.double.map { $0 / 1000 }
            $0.lastHeard = now()
        }
        onReady()
        set("ready as \(label)", .ready(url: "\(baseURL.absoluteString)/\(label)"))

        // Keepalive beside the reader; either ending ends the connection.
        let pinger = Task { [weak self] in
            while let self, !Task.isCancelled {
                await sleep(seconds: self.pingEvery)
                if now() - self.state.value.lastHeard > self.silentLimit { socket.close(code: 4408, reason: "no pong"); return }
                try? await socket.send("ping")
            }
        }
        defer { pinger.cancel() }
        while state.value.running {
            let text = try await socket.receive()
            state.update { $0.lastHeard = now() }
            if text == "pong" { continue }
            guard let frame = try? JSON.parse(text) else { continue }
            switch frame["t"]?.string {
            case "req":
                guard let id = frame["id"]?.string else { continue }
                var headers: [String: String] = [:]
                for (k, v) in frame["headers"]?.object ?? [:] { if let s = v.string { headers[k.lowercased()] = s } }
                // Which connector URL the request came through (the relay's sha256 of its secret). Set
                // only from the relay's own field, never from a header the caller sent.
                headers[PokiCore.connectorHeader] = frame["s"]?.string
                let answerBy = state.value.requestTimeout.map { now() + $0 }
                let request = RelayRequest(id: id, method: frame["method"]?.string ?? "POST", headers: headers, body: frame["body"]?.string ?? "", answerBy: answerBy)
                let task = Task { [weak self] in
                    guard let self else { return }
                    let response = await self.handler(request)
                    let stillWanted = self.state.update { $0.inflight.removeValue(forKey: id) != nil }
                    guard !Task.isCancelled else { return }
                    guard stillWanted else { self.undelivered?(request, response); return }
                    try? await socket.send(self.frame(for: response).serialized())
                }
                state.update { $0.inflight[id] = task }
            case "consent":
                // A sign-in from a client outside the relay's known list waits for the owner's OK.
                guard let id = frame["id"]?.string else { continue }
                let client = frame["client"]?.string ?? "An MCP client", callback = frame["callback"]?.string ?? "", connector = frame["s"]?.string ?? ""
                Task { [weak self] in
                    guard let self else { return }
                    let ok = await self.host?.approveConnection(client: client, callback: callback, connector: connector) ?? false
                    try? await socket.send((["t": "consent_res", "id": .string(id), "ok": .bool(ok)] as JSON).serialized())
                }
            case "cancel":
                if let id = frame["id"]?.string { state.update { $0.inflight.removeValue(forKey: id) }?.cancel() }
            case "ready":
                state.update {
                    $0.maxBody = frame["max_body"]?.int ?? $0.maxBody
                    $0.requestTimeout = frame["req_timeout_ms"]?.double.map { $0 / 1000 } ?? $0.requestTimeout
                }
            case "close":
                throw RelayFailure("the relay closed the connection: \(frame["reason"]?.string ?? "no reason")")
            default: continue
            }
        }
    }

    /// A response frame, never larger than the relay takes: an oversized body becomes a JSON-RPC error.
    func frame(for response: RelayResponse) -> JSON {
        let limit = state.value.maxBody - 1024
        var r = response
        if r.body.utf8.count > limit {
            r.status = 200
            r.headers["content-type"] = "application/json"
            r.body = (["jsonrpc": "2.0", "id": .null, "error": ["code": -32603, "message": "the answer was too large for the relay"]] as JSON).serialized()
        }
        return ["t": "res", "id": .string(r.id), "status": .number(Double(r.status)), "headers": .object(r.headers.mapValues(JSON.string)), "body": .string(r.body)]
    }
}

struct RelayFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
