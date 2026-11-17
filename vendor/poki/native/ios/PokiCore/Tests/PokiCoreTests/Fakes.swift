import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PokiCore

/// A WebDriverAgent stand-in: routes answer per method and path (the session part removed).
final class FakeWDA: HTTPTransport, @unchecked Sendable {
    typealias Route = @Sendable (_ body: JSON?) async throws -> (Int, JSON)
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private(set) var log: [(method: String, path: String, body: JSON?)] = []

    let usesDynamicScreenSize: Bool
    let supportsPaneSelection: Bool

    init(dynamicSize: Bool = false, paneSelection: Bool = false) {
        usesDynamicScreenSize = dynamicSize
        supportsPaneSelection = paneSelection
        set("POST /session") { _ in (200, ["value": ["sessionId": "s1"]]) }
        set("GET /status") { _ in (200, ["value": ["ready": true]]) }
        set("DELETE /session") { _ in (200, ["value": .null]) }
        set("GET /wda/screen") { _ in (200, ["value": ["screenSize": ["width": 390, "height": 844]]]) }
        set("GET /screenshot") { _ in (200, ["value": .string(Data("png".utf8).base64EncodedString())]) }
        set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.Preferences", "name": "Settings"]]) }
        source([("Button", "General"), ("Button", "Privacy")])
        for path in ["POST /wda/tap", "POST /wda/keys", "POST /wda/dragfromtoforduration", "POST /wda/touchAndHold", "POST /wda/apps/launch", "POST /wda/apps/activate", "POST /wda/apps/terminate", "POST /wda/homescreen", "POST /wda/lock", "POST /wda/pressButton", "POST /actions", "POST /wda/pressAndDragWithVelocity", "POST /appium/settings"] {
            set(path) { _ in (200, ["value": .null]) }
        }
    }

    /// The screen as a tree: (type, label, [x, y, w, h], children).
    func tree(_ nodes: [Node], app: String = "X") {
        func json(_ n: Node) -> JSON {
            ["type": .string("XCUIElementType\(n.type)"), "label": n.label.map(JSON.string) ?? .null, "value": n.value.map(JSON.string) ?? .null, "rect": ["x": .number(n.frame[0]), "y": .number(n.frame[1]), "width": .number(n.frame[2]), "height": .number(n.frame[3])], "children": .array(n.children.map(json))]
        }
        let root: JSON = ["type": "XCUIElementTypeApplication", "label": .string(app), "rect": ["x": 0, "y": 0, "width": 390, "height": 844], "children": .array(nodes.map(json))]
        set("GET /source") { _ in (200, ["value": root]) }
    }

    static let sessionlessOnly: Set<String> = ["POST /wda/homescreen"]

    func set(_ key: String, _ route: @escaping Route) { lock.lock(); routes[key] = route; lock.unlock() }
    /// The route answers as before, after a wait.
    func delay(_ key: String, _ seconds: Double) {
        lock.lock(); let inner = routes[key]; lock.unlock()
        set(key) { body in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let inner else { return (404, ["value": ["error": "unknown command"]]) }
            return try await inner(body)
        }
    }

    /// The route answers as before once `held` is false, and keeps waiting when its caller gives up
    /// (a runner serving a request goes on with it).
    func hold(_ key: String, while held: LockedBox<Bool>) {
        lock.lock(); let inner = routes[key]; lock.unlock()
        set(key) { body in
            await Task.detached { while held.value { usleep(10_000) } }.value
            guard let inner else { return (404, ["value": ["error": "unknown command"]]) }
            return try await inner(body)
        }
    }

    /// The screen as rows of (type, label), 44 points apart.
    func source(_ rows: [(String, String)], app: String = "Settings") {
        let children: [JSON] = rows.enumerated().map { index, row in
            ["type": .string("XCUIElementType\(row.0)"), "label": .string(row.1), "rect": ["x": 16, "y": .number(Double(100 + index * 44)), "width": 358, "height": 44]]
        }
        let root: JSON = ["type": "XCUIElementTypeApplication", "label": .string(app), "rect": ["x": 0, "y": 0, "width": 390, "height": 844], "children": .array(children)]
        set("GET /source") { _ in (200, ["value": root]) }
    }

    private func record(_ method: String, _ path: String, _ body: JSON?, _ key: String) -> Route? {
        lock.lock(); defer { lock.unlock() }
        log.append((method, path, body))
        return routes[key]
    }

    var sent: [String] { lock.lock(); defer { lock.unlock() }; return log.map { "\($0.method) \($0.path)" } }
    func bodies(_ key: String) -> [JSON] { lock.lock(); defer { lock.unlock() }; return log.filter { "\($0.method) \($0.path)" == key }.compactMap(\.body) }

    func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data) {
        let inSession = url.path.hasPrefix("/session/")
        var path = url.path.replacingOccurrences(of: #"^/session/[^/]+"#, with: "", options: .regularExpression)
        if path.isEmpty { path = "/session" }
        var key = "\(method) \(path)"
        // As in WDA 16.15.3 (FBCustomCommands.m): the Home button has no route inside a session.
        if inSession, Self.sessionlessOnly.contains(key) {
            let missing: JSON = ["value": ["error": "unknown command", "message": .string("Unhandled endpoint: \(url.path)")]]
            _ = record(method, url.path, nil, "")
            return (404, missing.data())
        }
        var parsed = body.flatMap { try? JSON.parse($0) }
        // scroll_to's drag goes as W3C actions (one finger, a slow tail): the tests hook the press-drag
        // route and read fromY/toY from it, so a one-finger drag is answered there with that shape.
        // Only scroll_to's own finger ("f1"); shaped touches (Humanize's "finger1") stay /actions.
        if key == "POST /actions", let sources = parsed?["actions"]?.array, sources.count == 1, sources[0]["id"]?.string == "f1", let steps = sources[0]["actions"]?.array {
            let moves = steps.filter { $0["type"]?.string == "pointerMove" }
            if moves.count >= 2, let first = moves.first, let last = moves.last {
                // The slow tail before the lift stands where the press-drag's hold stood.
                parsed = ["fromX": first["x"] ?? 0, "fromY": first["y"] ?? 0, "toX": last["x"] ?? 0, "toY": last["y"] ?? 0, "holdDuration": .number((last["duration"]?.double ?? 0) / 1000), "w3c": true]
                key = "POST /wda/pressAndDragWithVelocity"; path = "/wda/pressAndDragWithVelocity"
            }
        }
        let route = record(method, path, parsed, key)
        guard let route else { let missing: JSON = ["value": ["error": "unknown command", "message": .string("no route \(key)")]]; return (404, missing.data()) }
        let (status, json) = try await route(parsed)
        return (status, json.data())
    }
}

private func block() { Thread.sleep(forTimeInterval: 0.05) }

/// Never answers, and ignores cancellation: the worst runner there is.
func hang() async -> Never {
    while true { block(); await Task.yield() }
}

struct FakeKey: RelayKey {
    var publicKey = Data((0..<32).map { UInt8($0) })
    func sign(_ message: Data) throws -> Data { Data(message.reversed()) }
}

struct Node {
    var type: String
    var label: String?
    var frame: [Double]
    var children: [Node] = []
    var value: String?
    init(_ type: String, _ label: String?, _ frame: [Double], _ children: [Node] = [], value: String? = nil) {
        self.type = type
        self.label = label
        self.frame = frame
        self.children = children
        self.value = value
    }
}

final class FakeHost: CoreHost, @unchecked Sendable {
    let state = LockedBox<RunnerState>(.running)
    let restarts = LockedBox(0)
    let texts = LockedBox<[RecognizedText]?>(nil)
    let widths = LockedBox<[Int]>([])
    let warmUps = LockedBox(0)
    func warmUp() { warmUps.update { $0 += 1 } }
    func recognizeText(inPNG png: Data) async -> [RecognizedText]? { texts.value }
    func signingKey() throws -> RelayKey { FakeKey() }
    func accessHashes() -> [String] { ["abc123"] }
    func jpeg(fromPNG png: Data, width: Int, quality: Double) throws -> Data { widths.update { $0.append(width) }; return Data("jpeg:\(png.count)".utf8) }
    func runnerState() -> RunnerState { state.value }
    func restartRunner() { restarts.update { $0 += 1 } }
    let ownScreenshot = LockedBox<Data?>(nil)
    func screenshotWithoutRunner() async -> Data? { ownScreenshot.value }
}

/// One end of a fake WebSocket; the test plays the relay on the other end.
final class FakeSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiting: CheckedContinuation<String, Error>?
    private(set) var outbox: [String] = []
    private(set) var closed = false

    func push(_ text: String) {
        lock.lock()
        if let w = waiting { waiting = nil; lock.unlock(); w.resume(returning: text); return }
        inbox.append(text)
        lock.unlock()
    }
    /// Sent after the close: a real socket refuses it, and the test lists it.
    private(set) var late: [String] = []
    func send(_ text: String) async throws {
        lock.lock()
        if closed { late.append(text); lock.unlock(); throw RelayFailure("closed") }
        outbox.append(text)
        lock.unlock()
    }
    var sentLate: [String] { lock.lock(); defer { lock.unlock() }; return late }
    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if closed { lock.unlock(); c.resume(throwing: RelayFailure("closed")); return }
            if !inbox.isEmpty { let t = inbox.removeFirst(); lock.unlock(); c.resume(returning: t); return }
            waiting = c
            lock.unlock()
        }
    }
    func close(code: Int, reason: String) {
        lock.lock()
        closed = true
        let w = waiting
        waiting = nil
        lock.unlock()
        w?.resume(throwing: RelayFailure("closed"))
    }
    var sent: [String] { lock.lock(); defer { lock.unlock() }; return outbox }
}

final class FakeSockets: WebSocketFactory, @unchecked Sendable {
    let sockets = LockedBox<[FakeSocket]>([])
    let urls = LockedBox<[URL]>([])
    func connect(to url: URL) async throws -> WebSocketConnection {
        let s = FakeSocket()
        sockets.update { $0.append(s) }
        urls.update { $0.append(url) }
        return s
    }
}

func eventually(_ seconds: Double = 2, _ condition: () -> Bool) async -> Bool {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until { if condition() { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
    return condition()
}

let testRelay = RelayAddress("https://relay.example.com")!

func makeCore(_ wda: FakeWDA = FakeWDA(), host: FakeHost = FakeHost(), configure: (inout CoreConfig) -> Void = { _ in }) -> (PokiCore, FakeWDA, FakeHost) {
    // The fake speaks JSON. Touches go unshaped (the legacy endpoints, exact points and times) so the
    // tests can assert on them; HumanizeTests turn shaping on.
    var config = CoreConfig(approvalWait: 0.3, toolDeadline: 6, actionCap: 3, readTimeout: 1, busyWait: 0.2, treeFormat: "json", humanize: false)
    configure(&config)
    return (PokiCore(config: config, host: host, transport: wda), wda, host)
}

/// A chat app's conversation (a stand-in for WeChat, ESP-465): the messages as static texts, the
/// message field (a TextView with no label, its value what is typed) above the keyboard, whose own
/// return key is "发送". The send key sends what the field holds (a new last message, the field
/// emptied) unless `sends` is off. With `drafts` on, the send key keeps the text as a draft instead:
/// the app goes back to its list of chats, where the chat's row reads "[草稿]" and the text.
final class ChatApp: @unchecked Sendable {
    static let bundle = "com.tencent.xin"
    let messages = LockedBox(["在吗", "明天见"])
    let field = LockedBox("")
    let sends = LockedBox(true)
    let drafts = LockedBox(false)
    /// An element the app draws beside the last message, such as a failed send's retry button or a
    /// sending spinner.
    let mark = LockedBox<Node?>(nil)
    let draft = LockedBox<String?>(nil)
    static let sendKey: [Double] = [300, 800, 80, 40]

    func tree() -> JSON {
        var nodes: [Node]
        if let draft = draft.value {
            nodes = [Node("NavigationBar", "微信", [0, 50, 390, 44]), Node("SearchField", "搜索", [10, 100, 370, 36], value: ""),
                     Node("StaticText", "朋友", [70, 150, 200, 24]), Node("StaticText", "[草稿] \(draft)", [70, 176, 260, 20])]
        } else {
            nodes = [Node("NavigationBar", "朋友", [0, 50, 390, 44])]
            for (i, m) in messages.value.enumerated() { nodes.append(Node("StaticText", m, [60, Double(120 + i * 50), 270, 40])) }
            if var mark = mark.value {
                mark.frame = [20, Double(120 + (messages.value.count - 1) * 50 + 8), 24, 24]
                nodes.append(mark)
            }
            nodes.append(Node("TextView", nil, [50, 450, 280, 36], value: field.value))
            nodes.append(Node("Keyboard", nil, [0, 500, 390, 344], [Node("Key", "空格", [100, 800, 190, 40]), Node("Button", "发送", Self.sendKey)]))
        }
        func json(_ n: Node) -> JSON {
            ["type": .string("XCUIElementType\(n.type)"), "label": n.label.map(JSON.string) ?? .null, "value": n.value.map(JSON.string) ?? .null, "rect": ["x": .number(n.frame[0]), "y": .number(n.frame[1]), "width": .number(n.frame[2]), "height": .number(n.frame[3])], "children": .array(n.children.map(json))]
        }
        return ["type": "XCUIElementTypeApplication", "label": "微信", "rect": ["x": 0, "y": 0, "width": 390, "height": 844], "children": .array(nodes.map(json))]
    }

    func send() {
        guard sends.value, !field.value.isEmpty else { return }
        let text = field.value
        if drafts.value { draft.value = text } else { messages.update { $0.append(text) } }
        field.value = ""
    }

    func install(_ wda: FakeWDA) {
        wda.set("GET /source") { [self] _ in (200, ["value": tree()]) }
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": .string(Self.bundle), "name": "微信"]]) }
        wda.set("POST /wda/keys") { [self] body in
            for key in body?["value"]?.array ?? [] {
                if key.string == "\n" { send() } else { field.update { $0 += key.string ?? "" } }
            }
            return (200, ["value": .null])
        }
        wda.set("POST /wda/tap") { [self] body in
            let (x, y) = (body?["x"]?.double ?? 0, body?["y"]?.double ?? 0)
            let k = Self.sendKey
            if x >= k[0], x <= k[0] + k[2], y >= k[1], y <= k[1] + k[3] { send() }
            return (200, ["value": .null])
        }
    }
}
