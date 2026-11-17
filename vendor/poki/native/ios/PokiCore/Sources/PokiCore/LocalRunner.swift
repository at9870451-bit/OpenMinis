import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The runner's requests answered in this process (the app's InProcessWDA): WebDriverAgent's routes,
/// served the way WebDriverAgent serves them, so PokiCore's `Runner` (its deadlines, its one session,
/// its retry on a lost session) works unchanged. `serve` answers one request; this type decides when
/// it runs: one at a time on one queue, as WDA serves its requests on one thread, and screenshots
/// beside that queue, as WDA does.
///
/// Unlike WDA, a request never holds the queue past the moment its caller gives up on it (its timeout
/// and half a second, as `Runner` waits). Seen on the phone (ESP-464): a chat app did not answer for
/// 38 s, the read that asked it held the queue all that time, and the watchdog restarted the session,
/// which brought nothing back. The request goes on on its own thread and is *held*: the phone's
/// testmanagerd serves one request at a time (its log: nothing else of Poki's was taken while that
/// snapshot waited 37 s), so until the held one is through, anything that needs testmanagerd is
/// answered at once, not sent, rather than waiting behind it and landing after the agent was told it
/// failed. What needs only this process (the screen size, the clipboard, settings) is answered as usual.
public final class LocalRunner: HTTPTransport, @unchecked Sendable {
    /// One request, with the session and element ids taken out of its path: "/session/<id>/wda/tap"
    /// is "POST /wda/tap" for session <id>; "/element/<id>/rect" is "GET /element/rect".
    public struct Request: Sendable {
        public var key: String
        public var session: String?
        public var element: String?
        public var body: JSON?
        /// An earlier request is held: a screenshot then takes the picture and nothing more (no
        /// lookup of the app in front, which would wait behind the held request).
        public var whileHeld = false
    }
    public typealias Serve = @Sendable (Request) -> (status: Int, body: Data)
    /// The phone side's own request it gave up on and testmanagerd still serves (PKInProcess's
    /// accessibility requests have deadlines of their own): what it asked and how long ago.
    public typealias Unanswered = @Sendable () -> (what: String, seconds: Double)?

    private let serve: Serve
    private let unanswered: Unanswered
    private struct Lanes {
        /// The request the queue is serving now and when it began (`now()`).
        var inFlight: (key: String, since: Double)?
        /// A request whose caller gave up while it was still running, on each lane.
        var held: (key: String, since: Double)?
        var heldPicture: (key: String, since: Double)?
    }
    private let state = LockedBox(Lanes())
    private let queue = DispatchQueue(label: "poki.inprocess.wda", qos: .userInitiated)
    /// Screenshots are answered beside the queue, as WDA does.
    private let pictures = DispatchQueue(label: "poki.inprocess.screenshot", qos: .userInitiated)
    /// testmanagerd itself waits 60 s for one request's work to complete. The phone side's own unanswered
    /// request counts for that long. A request held on the queue counts until it is through: its age
    /// reaches `Runner`'s watchdog through /status, which restarts the runner past this time, and the
    /// new session (POST /session) then lets requests through again.
    var heldFor: Double = 60
    /// A request on the queue is held. Answers given meanwhile (refusals, and what this process answers
    /// alone, such as the lock state every look asks) are not the queue being through with it, as an
    /// answer from WDA's one queue would be: `Runner` keeps its stall, and with it its watchdog.
    public var holdsARequest: Bool { state.value.held != nil }
    /// Requests answered in this process alone, never through testmanagerd: served while a request is held.
    static let local: Set<String> = ["GET /wda/screen", "GET /wda/locked", "POST /appium/settings", "POST /session", "DELETE /session",
                                     "POST /wda/getPasteboard", "POST /wda/setPasteboard",
                                     "GET /element/attribute/value", "GET /element/attribute/placeholderValue", "GET /element/rect"]

    public init(serve: @escaping Serve, unanswered: @escaping Unanswered = { nil }) {
        self.serve = serve
        self.unanswered = unanswered
    }

    static func request(method: String, path: String, body: Data?) -> Request {
        var parts = path.split(separator: "/").map(String.init)
        var session: String?
        if parts.first == "session", parts.count >= 2 { session = parts[1]; parts.removeFirst(2) }
        var element: String?
        if parts.first == "element", parts.count >= 3 { element = parts[1]; parts.remove(at: 1) }
        let short = parts.isEmpty ? "/session" : "/" + parts.joined(separator: "/")
        return Request(key: "\(method) \(short)", session: session, element: element, body: body.flatMap { try? JSON.parse($0) })
    }

    /// What holds testmanagerd for this process, the longest first: a request held on the queue, or
    /// the phone side's own unanswered one (until `heldFor`).
    private func holding(_ s: Lanes, at t: Double) -> (what: String, seconds: Double)? {
        var found: [(what: String, seconds: Double)] = []
        if let h = s.held { found.append((h.key, t - h.since)) }
        if let u = unanswered(), u.seconds < heldFor { found.append((u.what, u.seconds)) }
        return found.max { $0.seconds < $1.seconds }
    }

    /// GET /status, answered at once beside the queue (WDA answers it apart too), with what the queue is
    /// busy with: `Runner`'s watchdog leaves a busy queue to finish instead of restarting it.
    private func status() -> (status: Int, body: Data) {
        let t = now()
        let s = state.value
        var busy: [(what: String, seconds: Double)] = []
        if let f = s.inFlight { busy.append((f.key, t - f.since)) }
        if let h = holding(s, at: t) { busy.append(h) }
        var value: JSON = ["ready": true, "message": "in-process"]
        if let oldest = busy.max(by: { $0.seconds < $1.seconds }), case .object(var o) = value {
            o["busy"] = ["request": .string(oldest.what), "seconds": .number((oldest.seconds * 10).rounded() / 10)]
            value = .object(o)
        }
        return (200, (["value": value] as JSON).data())
    }

    private static func refused(_ message: String) -> (status: Int, body: Data) {
        (500, (["value": ["error": "unknown error", "message": .string(message)]] as JSON).data())
    }

    public func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data) {
        var request = Self.request(method: method, path: url.path, body: body)
        let key = request.key
        if key == "GET /status" { return status() }
        let picture = key == "GET /screenshot"
        let lane = picture ? pictures : queue
        let asked = now()
        // The moment the caller gives up (Runner waits for its timeout and half a second).
        let givesUp = asked + timeout + 0.5
        return try await withCheckedThrowingContinuation { continuation in
            lane.async { [self] in
                let began = now()
                // Its caller gave up while it waited its turn: nobody would read the answer, and an
                // action would land after the agent was told it failed.
                guard began < givesUp else { continuation.resume(throwing: TransportError.timedOut); return }
                // A new session after the watchdog's restart: a request held past testmanagerd's own
                // limit is not waited for any longer.
                if key == "POST /session" {
                    state.update { s in
                        if let h = s.held, began - h.since >= heldFor {
                            NSLog("%@", "PokiInProcess: a new session; \(h.key), unanswered for \(Int(began - h.since)) s, is no longer waited for")
                            s.held = nil
                        }
                    }
                }
                let s = state.value
                if picture, let h = s.heldPicture, began - h.since < heldFor {
                    continuation.resume(returning: Self.refused("no screenshot: an earlier one has been under way for \(Int((began - h.since).rounded())) s"))
                    return
                }
                let holder = holding(s, at: began)
                if !picture, !Self.local.contains(key), let holder {
                    continuation.resume(returning: Self.refused("not sent: the app in front has not answered \(holder.what) for \(Int(holder.seconds.rounded())) s (its main thread is busy), and the phone serves one such request at a time; nothing is read or touched until it answers, so nothing lands late"))
                    return
                }
                request.whileHeld = holder != nil
                if !picture { state.update { $0.inFlight = (key, began) } }
                let done = DispatchSemaphore(value: 0)
                let out = LockedBox<(status: Int, body: Data)?>(nil)
                DispatchQueue.global(qos: .userInitiated).async { [request] in
                    let answer = self.serve(request)
                    out.value = answer
                    // Through after its caller gave up: no longer held.
                    self.state.update { s in
                        if picture { if s.heldPicture?.since == began { s.heldPicture = nil } } else if s.held?.since == began { s.held = nil }
                    }
                    if now() > givesUp { NSLog("%@", "PokiInProcess: \(key) answered after \(Int(((now() - began) * 1000).rounded())) ms, after its caller gave up") }
                    done.signal()
                }
                let inTime = done.wait(timeout: .now() + max(0, givesUp - now())) == .success
                let held: Bool = state.update { s in
                    if !picture, s.inFlight?.since == began { s.inFlight = nil }
                    guard !inTime, out.value == nil else { return false }
                    if picture { s.heldPicture = (key, began) } else { s.held = (key, began) }
                    return true
                }
                // One line per request in the system log (PokiInProcess), with its wait in the queue and
                // its own time, so a slow call can be traced to the request that took it.
                let waited = Int(((began - asked) * 1000).rounded()), took = Int(((now() - began) * 1000).rounded())
                if held {
                    NSLog("%@", "PokiInProcess: \(key) not through when its caller gave up (\(took) ms); held, nothing that needs testmanagerd is sent until it is through")
                    continuation.resume(throwing: TransportError.timedOut)
                    return
                }
                if waited > 5 || took > 5 { NSLog("%@", "PokiInProcess timing: \(key) \(took) ms\(waited > 5 ? " (queued \(waited) ms)" : "")") }
                continuation.resume(returning: out.value ?? Self.refused("no answer"))
            }
        }
    }
}
