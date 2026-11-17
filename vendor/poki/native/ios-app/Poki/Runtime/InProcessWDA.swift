import PokiNative
import os
import Foundation
import PokiCore
import UIKit

/// Which side carries out PokiCore's actions: Poki Runner (WebDriverAgent on port 8100) or Poki's own
/// process (`InProcessWDA`). Read once per launch (`-automationPath runner` chooses Poki Runner), so
/// setup, Home and the transport always agree.
enum AutomationPath: String, CaseIterable, Identifiable {
    case runner
    case inProcess = "in-process"
    var id: String { rawValue }
    static let current: AutomationPath = UserDefaults.standard.string(forKey: "automationPath").flatMap(AutomationPath.init(rawValue:)) ?? .inProcess
}

/// Poki's own automation session as AppModel drives it: `PKInProcess`, or a fake in tests.
protocol InProcessAutomation: AnyObject, Sendable {
    /// Opens the session and Automation Mode, or reuses an open one. Keys: ok, code, detail,
    /// generation, reused, seconds. Blocks: call it off the main thread.
    func prepare() -> [String: Any]
    /// Ends the session. Keys: closed, generation, seconds.
    func close() -> [String: Any]
    /// Automation Mode off with the session kept. Keys: paused, how, selectors.
    func pauseAutomation() -> [String: Any]
    /// Seconds iOS has been asked to allow automation in the open under way; 0 while no open is there.
    func authorizationWaitSeconds() -> Double
}

extension InProcessAutomation {
    func authorizationWaitSeconds() -> Double { 0 }
}

/// Thread-safe: its session state is behind locks, and every call blocks on its own.
extension PKInProcess: InProcessAutomation, @unchecked Sendable {}

/// Poki's own automation session, once the launcher has mounted the disk image (ESP-152).
enum InProcessSession: Equatable {
    case idle
    case closing(reopen: Bool)
    case opening
    case open
    /// prepare answered no: its code and detail.
    case failed(code: String, detail: String)
    /// iOS is asking the owner for the passcode before it allows automation.
    case waitingForPasscode
    /// iOS asked for the passcode and nobody entered it before it gave up (about a minute).
    case passcodeMissed

    /// What PokiCore reads while the launcher runs. A failure is answered at once, with its fix.
    var agentState: RunnerState {
        switch self {
        case .idle: return .starting("ready for a phone task; the automation session is not open")
        case .closing: return .starting("finishing the previous automation session")
        case .open: return .running
        case .opening: return .starting("opening the in-process session; it takes a few seconds the first time")
        case .waitingForPasscode:
            return .starting("waiting for the owner to enter the iPhone passcode on the phone: iOS asks for it before it allows automation, after Poki restarts and 8 hours after the last time. Only the owner can do this; the Live Activity asks them. Call again in about 10 s")
        case .passcodeMissed:
            return .failed("the owner did not enter the iPhone passcode when iOS asked for it to allow automation (cancelled, or a minute passed). Nothing was sent, and Poki does not ask again by itself: the owner turns Poki off and on to be asked again",
                           fix: "Turn Poki off and on, then enter the iPhone passcode when iOS asks for it to allow automation")
        case .failed(let code, let detail):
            if code == "session_unreadable" {
                return .failed("the automation session opened but could not read the screen (\(detail)). Nothing was sent, and that session was closed; the next call opens a new one",
                               fix: "Try the step again. If it keeps failing, turn Poki off and on")
            }
            return .failed("the in-process session could not be opened (\(code)\(detail.isEmpty ? "" : ": \(detail)")); Poki tries again on the next call",
                           fix: "Open Poki and, if iOS asks, enter the passcode to allow automation")
        }
    }
}

/// The WebDriverAgent requests PokiCore sends, answered in Poki's own process by `PKInProcess`: no
/// runner app, no HTTP, no port. Each request is one table entry, answered in WDA's JSON shape, so
/// PokiCore's `Runner` (its deadlines, its one session, its retry on a lost session) works unchanged.
///
/// The session id carries the daemon session's generation. A request for an older generation is
/// refused as WDA refuses an unknown session, so an action meant for a session that ended is never
/// sent; `Runner` opens a new session and sends it there once.
final class InProcessWDA: HTTPTransport, @unchecked Sendable {
    private typealias Route = (_ body: JSON?, _ element: String?) throws -> JSON
    private let native = PKInProcess.shared()
    /// When each request runs: one action or read at a time, screenshots beside them (PokiCore).
    private var lanes: LocalRunner!
    let usesDynamicScreenSize = true
    let supportsPaneSelection = true
    private let readGeometry = OSAllocatedUnfairLock<(display: PKDisplayGeometry, pane: CGRect)?>(initialState: nil)
    private var routes: [String: Route] = [:]
    /// The focused field from the latest `/element/active`, for the value and frame asked right after.
    private var focused: [AnyHashable: Any]?
    /// PokiCore's snapshotMaxDepth and snapshotMaxChildren (POST /appium/settings): a read that took
    /// too long is followed by a smaller one, in-process as on WebDriverAgent. 0: unbounded.
    private var maxDepth = 0, maxChildren = 0

    /// When an open may bring up iOS's passcode screen. It does only before the first automation
    /// of a boot, so until then: one open at a time (two at once each showed a screen), never from
    /// the background (the screen then could not be closed), and none after the owner cancelled one,
    /// until they turn Poki on again.
    struct OpenGate {
        var declined = false
        var inFront = true
        var startedThisBoot = false
        var opening = false
    }
    static let gate = OSAllocatedUnfairLock(initialState: OpenGate())
    static var automationDeclined: Bool { gate.withLock { $0.declined } }

    /// prepare through the gate: an answer in prepare's shape when it may not run now.
    static func openThroughGate(_ prepare: () -> [String: Any]) -> [String: Any] {
        let refusal: String? = gate.withLock { g in
            if g.startedThisBoot { return nil }
            if g.declined { return "passcode_declined" }
            if !g.inFront { return "open_poki_first" }
            if g.opening { return "open_under_way" }
            g.opening = true
            return nil
        }
        if let refusal {
            let detail = refusal == "passcode_declined" ? "the owner cancelled iOS's passcode screen for automation; Poki asks again when they turn it on"
                : refusal == "open_poki_first" ? "iOS asks for the passcode before the first automation since the iPhone restarted; that happens with Poki open, so the owner opens Poki first"
                : "an open is already asking for the passcode"
            return ["ok": false, "code": refusal, "detail": detail, "seconds": 0.0]
        }
        let result = prepare()
        gate.withLock { g in
            g.opening = false
            if result["ok"] as? Bool == true { g.startedThisBoot = true }
        }
        return result
    }

    init() {
        routes = [
            "POST /session": { [unowned self] _, _ in
                // The owner cancelled iOS's passcode screen: no new open (and no new screen) until they
                // turn Poki on again.
                let prepared = Self.openThroughGate { self.native.prepare() }
                guard prepared["ok"] as? Bool == true else {
                    throw Refusal("session not created", "the automation session could not be opened: \(prepared["code"] ?? "unknown") \(prepared["detail"] ?? "")")
                }
                return ["sessionId": .string("inprocess-\(self.native.generation())")]
            },
            "DELETE /session": { _, _ in .null },
            "POST /poki/pane": { [unowned self] body, _ in
                guard let side = body?["side"]?.string, ["left", "right", "auto"].contains(side) else {
                    throw Refusal("invalid argument", "pane must be left, right, or auto")
                }
                var reason: NSString?
                guard let pane = self.native.selectPane(side, code: &reason) else {
                    throw Refusal("invalid argument", reason.map { $0 as String } ?? "Split View unavailable")
                }
                self.readGeometry.withLock { $0 = nil }
                self.focused = nil
                if side == "auto" { return .null }
                return ["bundleId": .string(pane["bundleId"] as? String ?? ""),
                        "otherBundleId": .string(pane["otherBundleId"] as? String ?? ""),
                        "identity": .string(pane["identity"] as? String ?? ""),
                        "x": .number(pane["x"] as? Double ?? 0), "y": .number(pane["y"] as? Double ?? 0)]
            },
            "POST /poki/workspace-drag": { [unowned self] body, _ in
                let fingers = try Self.fingers(body)
                let other = self.native.otherWorkspacePane
                guard self.native.hasSelectedPane, !other.isNull, fingers.count == 1 else {
                    throw Refusal("invalid argument", "a Split View drag needs two confirmed panes and one continuous finger")
                }
                return try self.touch(fingers, into: other)
            },
            "POST /poki/workspace-launcher": { [unowned self] body, _ in
                let labels = body?["labels"]?.array?.compactMap(\.string) ?? []
                guard !self.native.hasSelectedPane, let menu = body?["menu"]?.bool, !labels.isEmpty else {
                    throw Refusal("invalid argument", "workspace setup requires a system launcher target")
                }
                guard let outcome = self.native.openWorkspaceLauncherItem(labels, menu: menu) else { return .bool(false) }
                _ = try self.answer(outcome)
                return .bool(true)
            },
            "POST /appium/settings": { [unowned self] body, _ in
                let settings = body?["settings"]
                if let depth = settings?["snapshotMaxDepth"]?.double { self.maxDepth = depth >= 50 ? 0 : max(1, Int(depth)) }
                if let children = settings?["snapshotMaxChildren"]?.double { self.maxChildren = children >= 10_000 ? 0 : max(1, Int(children)) }
                return .null
            },
            // Beside another app, the front app's part of the screen is the screen the agent sees (viewport).
            "GET /wda/screen": { [unowned self] _, _ in
                let geometry = self.native.displayGeometry()
                let viewport = self.native.viewport
                let size = viewport.isNull ? geometry.bounds.size : viewport.size
                self.readGeometry.withLock { $0 = (geometry, viewport) }
                return ["screenSize": ["width": .number(size.width), "height": .number(size.height)]]
            },
            "GET /wda/locked": { [unowned self] _, _ in .bool(self.native.screenLocked()) },
            "GET /wda/activeAppInfo": { [unowned self] _, _ in
                let app = self.native.frontApp()
                return ["bundleId": .string(app["bundleId"] as? String ?? ""), "name": .string(app["name"] as? String ?? ""), "pid": .number(Double(app["pid"] as? Int ?? 0))]
            },
            "GET /source": { [unowned self] _, _ in
                var code: NSString?
                guard let xml = self.native.sourceXML(nil, maxDepth: self.maxDepth, maxChildren: self.maxChildren, code: &code) else { throw Refusal("unknown error", "no element tree: \(code ?? "unknown")") }
                let readAt = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in AppLog.shared.add("session-timing", String(format: "screen_read_succeeded uptime=%.6f", readAt)) }
                return .string(xml)
            },
            "GET /element/active": { [unowned self] _, _ in
                var code: NSString?
                var focus: NSDictionary?
                guard self.native.sourceXML(&focus, maxDepth: self.maxDepth, maxChildren: self.maxChildren, code: &code) != nil else { throw Refusal("unknown error", "no element tree: \(code ?? "unknown")") }
                guard let focus else { throw Refusal("no such element", "no element has the keyboard focus") }
                self.focused = focus as? [AnyHashable: Any]
                return ["ELEMENT": "focused"]
            },
            "GET /element/attribute/value": { [unowned self] _, id in
                guard id == "focused", let value = self.focused?["value"] as? String else { throw Refusal("no such element", "the element is gone") }
                return .string(value)
            },
            // null when the field has no placeholder; refused when the snapshot did not say, which a
            // failed type reads as "placeholder unreadable" and does not type again (ESP-160).
            "GET /element/attribute/placeholderValue": { [unowned self] _, id in
                guard id == "focused", let f = self.focused else { throw Refusal("no such element", "the element is gone") }
                switch f["placeholderValue"] {
                case let text as String: return .string(text)
                case is NSNull: return .null
                default: throw Refusal("unknown error", "the field's placeholder was not in the snapshot")
                }
            },
            "GET /element/rect": { [unowned self] _, id in
                guard id == "focused", let f = self.focused else { throw Refusal("no such element", "the element is gone") }
                return ["x": .number(f["x"] as? Double ?? 0), "y": .number(f["y"] as? Double ?? 0), "width": .number(f["width"] as? Double ?? 0), "height": .number(f["height"] as? Double ?? 0)]
            },
            "POST /wda/tap": { [unowned self] body, _ in
                let p = try Self.point(body, "x", "y")
                return try self.touch([[(p, 0), (p, 0.05)]])
            },
            "POST /wda/touchAndHold": { [unowned self] body, _ in
                let p = try Self.point(body, "x", "y")
                return try self.touch([[(p, 0), (p, max(0.1, body?["duration"]?.double ?? 1))]])
            },
            "POST /wda/pressAndDragWithVelocity": { [unowned self] body, _ in
                let from = try Self.point(body, "fromX", "fromY"), to = try Self.point(body, "toX", "toY")
                let press = max(0, body?["pressDuration"]?.double ?? 0), hold = max(0, body?["holdDuration"]?.double ?? 0)
                let distance = hypot(to.x - from.x, to.y - from.y)
                let moving = max(0.05, distance / max(1, body?["velocity"]?.double ?? 1000))
                // The hold at the end is a real touch sample, one point short of the end and then the
                // end itself, so the scroll view sees a finger that stopped before it lifted and the
                // list stays where it is (the gym: a 72 % drag moved a whole screen in-process, a
                // flick, where the same drag on WebDriverAgent moved 72 %).
                guard hold > 0, distance > 2 else { return try self.touch([[(from, 0), (from, press), (to, press + moving), (to, press + moving + hold)]]) }
                let near = CGPoint(x: to.x - (to.x - from.x) / distance, y: to.y - (to.y - from.y) / distance)
                return try self.touch([[(from, 0), (from, press), (near, press + moving), (to, press + moving + hold)]])
            },
            "POST /wda/dragfromtoforduration": { [unowned self] body, _ in
                let from = try Self.point(body, "fromX", "fromY"), to = try Self.point(body, "toX", "toY")
                let press = max(0, body?["duration"]?.double ?? 0)
                return try self.touch([[(from, 0), (from, press), (to, press + 0.3)]])
            },
            "POST /actions": { [unowned self] body, _ in try self.touch(try Self.fingers(body)) },
            "POST /wda/keys": { [unowned self] body, _ in
                let text = (body?["value"]?.array ?? []).compactMap(\.string).joined()
                guard !text.isEmpty else { throw Refusal("invalid argument", "no keys given") }
                try self.refuseInPoki()
                // `frequency`: characters a second for this burst (PokiCore's Humanize types a word at
                // a time at an uneven pace); without one, the fixed 120 of before.
                let speed = UInt(max(1, min(240, body?["frequency"]?.int ?? 120)))
                return try self.answer(self.native.type(text, typingSpeed: speed, timeout: 3 + Double(text.count) / Double(speed) + 0.02 * Double(text.count)))
            },
            "POST /wda/homescreen": { [unowned self] _, _ in try self.done(self.native.press("home")) },
            "POST /wda/lock": { [unowned self] _, _ in try self.done(self.native.press("lock")) },
            "POST /wda/pressButton": { [unowned self] body, _ in try self.done(self.native.press(body?["name"]?.string ?? "")) },
            "POST /wda/apps/launch": { [unowned self] body, _ in try self.done(self.native.app(try Self.bundle(body), action: "launch")) },
            "POST /wda/apps/activate": { [unowned self] body, _ in try self.done(self.native.app(try Self.bundle(body), action: "activate")) },
            "POST /wda/apps/terminate": { [unowned self] body, _ in try self.done(self.native.app(try Self.bundle(body), action: "terminate")) },
            // The clipboard is Poki's own to read and write here; WDA's wire form is base64 text.
            // Empty only when it is: no text while it holds something (an image, or a paste the owner
            // did not allow), or while Poki is in the background and iOS may hide it, is unreadable.
            "POST /wda/getPasteboard": { _, _ in
                let (text, items, active) = DispatchQueue.main.sync {
                    (UIPasteboard.general.string, UIPasteboard.general.numberOfItems, UIApplication.shared.applicationState == .active)
                }
                guard let text = text ?? (items == 0 && active ? "" : nil) else {
                    throw Refusal("unable to read clipboard", items > 0 ? "the clipboard holds no text" : "the clipboard cannot be read while Poki is in the background")
                }
                return .string(Data(text.utf8).base64EncodedString())
            },
            "POST /wda/setPasteboard": { body, _ in
                guard let encoded = body?["content"]?.string, let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
                    throw Refusal("invalid argument", "content must be base64 text")
                }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.sync { UIPasteboard.general.string = text }
                return .null
            },
        ]
        // The phone side's own request it gave up on (a pid that has not answered), which testmanagerd
        // still serves: LocalRunner sends nothing that needs testmanagerd until it is through.
        lanes = LocalRunner(serve: { [unowned self] request in
            self.answer(request.key, session: request.session, element: request.element, body: request.body, route: self.routes[request.key], refreshViewport: !request.whileHeld)
        }, unanswered: { [unowned self] in
            guard let held = self.native.unanswered(), let seconds = held["seconds"] as? Double else { return nil }
            let pid = held["pid"] as? Int ?? 0
            return (pid < 0 ? "a lookup of the app in front" : pid == 0 ? "a request to the accessibility server" : "an accessibility request (pid \(pid))", seconds)
        })
    }

    private struct Refusal: Error {
        var code: String
        var message: String
        init(_ code: String, _ message: String) { self.code = code; self.message = message }
    }

    func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data) {
        try await lanes.send(method: method, url: url, body: body, timeout: timeout)
    }

    private func answer(_ key: String, session: String?, element: String?, body: JSON?, route: Route?, refreshViewport: Bool) -> (status: Int, body: Data) {
        func refused(_ status: Int, _ code: String, _ message: String) -> (Int, Data) {
            (status, (["value": ["error": .string(code), "message": .string(message)]] as JSON).data())
        }
        if let session, session != "inprocess-\(native.generation())", key != "DELETE /session" {
            return refused(404, "invalid session id", "the automation session \(session) has ended (now generation \(native.generation()))")
        }
        if native.hasSelectedPane, ["POST /wda/homescreen", "POST /wda/apps/launch", "POST /wda/apps/activate", "POST /wda/apps/terminate"].contains(key) {
            return refused(400, "invalid argument", "this would leave Split View; choose look {pane: \"auto\"} first to return to normal control")
        }
        do {
            if key == "GET /screenshot" {
                var code: NSString?
                guard let png = native.screenshot(&code, refreshViewport: refreshViewport) else { throw Refusal("unable to capture screen", "no screenshot: \(code ?? "unknown")") }
                return (200, (["value": .string(png.base64EncodedString())] as JSON).data())
            }
            guard let route else { return refused(404, "unknown command", "not answered in-process: \(key)") }
            return (200, (["value": try route(body, element)] as JSON).data())
        } catch let r as Refusal {
            return refused(r.code == "invalid session id" ? 404 : 500, r.code, r.message)
        } catch {
            return refused(500, "unknown error", "\(error)")
        }
    }

    /// The native outcome as WDA's answer: sent is done, not sent is refused, and an unknown outcome is
    /// a failed exchange (Runner reports it as possibly delivered, and never sends it again).
    private func answer(_ outcome: PKOutcome) throws -> JSON {
        switch outcome.delivery {
        case .sent: return .null
        case .notSent:
            if outcome.code == "native_session_invalidated" || outcome.code == "native_action_superseded" || outcome.code == "session_unreadable" {
                throw Refusal("invalid session id", "the automation session ended before the action was sent (\(outcome.code ?? ""))")
            }
            throw Refusal("unknown error", "not sent: \(outcome.code ?? "unknown")\(outcome.detail.map { " (\($0))" } ?? "")")
        case .unknown: throw TransportError.other("sent, no confirmation: \(outcome.code ?? "unknown")")
        @unknown default: throw TransportError.other("unknown outcome")
        }
    }

    private func done(_ failure: String?) throws -> JSON {
        guard let failure else { return .null }
        throw Refusal("unknown error", failure)
    }

    /// Nothing is tapped or typed in Poki itself, whoever asks and whatever they could tell of the
    /// screen: with Poki the app in front (not merely beside the driven app, where the other one is
    /// the front app), a touch or text is refused here, the last place before it would be sent.
    /// Opening an app and the Home button stay: they are how a task leaves Poki.
    private func refuseInPoki() throws {
        guard let own = Bundle.main.bundleIdentifier, native.frontApp()["bundleId"] as? String == own else { return }
        throw Refusal("unknown error", "not sent: Poki itself is in front, and nothing is tapped or typed in Poki. Open the task's app first (launch)")
    }

    private func touch(_ fingers: [[(CGPoint, Double)]], into other: CGRect? = nil) throws -> JSON {
        try refuseInPoki()
        // Points are in the viewport the agent saw (the driven app's part of the screen): moved back onto the screen.
        let geometry = native.displayGeometry()
        let viewport = native.viewport
        if let previous = readGeometry.withLock({ $0 }), previous.display.routesDisplay.boolValue || geometry.routesDisplay.boolValue {
            guard previous.display.bounds == geometry.bounds, previous.display.peer == geometry.peer,
                  previous.display.nativeSize == geometry.nativeSize,
                  previous.display.toFixed == geometry.toFixed, previous.display.orientation == geometry.orientation,
                  previous.display.orientationRevision == geometry.orientationRevision, previous.pane == viewport else {
                throw Refusal("invalid argument", "split_view_changed: look at the new pane before tapping")
            }
        }
        let shift = viewport.isNull ? CGPoint.zero : viewport.origin
        if !geometry.peer.isNull || native.hasSelectedPane {
            guard !viewport.isNull else { throw Refusal("invalid argument", "look at the target pane before tapping") }
            let local = CGRect(origin: .zero, size: viewport.size)
            if let other {
                guard let finger = fingers.first, let start = finger.first, let end = finger.last,
                      local.contains(start.0), other.offsetBy(dx: -shift.x, dy: -shift.y).contains(end.0),
                      fingers.allSatisfy({ $0.allSatisfy { geometry.bounds.offsetBy(dx: -shift.x, dy: -shift.y).contains($0.0) } }) else {
                    throw Refusal("invalid argument", "the drag must start in the selected pane and finish in the other pane")
                }
            } else if !fingers.allSatisfy({ $0.allSatisfy { local.contains($0.0) } }) {
                throw Refusal("invalid argument", "the gesture would leave the target pane; use points inside its screenshot")
            }
        }
        let paths = fingers.map { $0.map { PKTouchPoint.at(CGPoint(x: $0.0.x + shift.x, y: $0.0.y + shift.y), offset: $0.1) } }
        let longest = fingers.compactMap { $0.last?.1 }.max() ?? 0
        return try answer(native.touch(paths, timeout: longest + 3, geometry: geometry))
    }

    private static func point(_ body: JSON?, _ x: String, _ y: String) throws -> CGPoint {
        guard let px = body?[x]?.double, let py = body?[y]?.double else { throw Refusal("invalid argument", "\(x) and \(y) are needed") }
        return CGPoint(x: px, y: py)
    }

    private static func bundle(_ body: JSON?) throws -> String {
        guard let id = body?["bundleId"]?.string, !id.isEmpty else { throw Refusal("invalid argument", "bundleId is needed") }
        return id
    }

    /// W3C pointer actions (PokiCore's pinch): per finger, moves with durations in ms between a down
    /// and an up.
    private static func fingers(_ body: JSON?) throws -> [[(CGPoint, Double)]] {
        var out: [[(CGPoint, Double)]] = []
        for source in body?["actions"]?.array ?? [] where source["type"]?.string == "pointer" {
            var t = 0.0, at = CGPoint.zero, path: [(CGPoint, Double)] = [], down = false
            for step in source["actions"]?.array ?? [] {
                switch step["type"]?.string {
                case "pointerMove":
                    t += (step["duration"]?.double ?? 0) / 1000
                    at = CGPoint(x: step["x"]?.double ?? at.x, y: step["y"]?.double ?? at.y)
                    if down { path.append((at, t)) }
                case "pointerDown": down = true; path.append((at, t))
                case "pointerUp": down = false
                case "pause": t += (step["duration"]?.double ?? 0) / 1000; if down { path.append((at, t)) }
                default: break
                }
            }
            if !path.isEmpty { out.append(path) }
        }
        guard !out.isEmpty else { throw Refusal("invalid argument", "no pointer actions") }
        return out
    }
}
