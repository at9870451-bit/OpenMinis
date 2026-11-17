import Foundation
import XCTest
@testable import PokiCore

/// The phone as Poki's own process reaches it (LocalRunner's `serve`, standing in for PKInProcess).
/// testmanagerd takes one request at a time: in the system log of ESP-464, a snapshot of a chat app
/// that did not answer for 38 s held testmanagerd for 37 s, and no other request of Poki's (a front-app
/// lookup, a screenshot) was taken until it was through. An app that does not answer holds every
/// request that asks it, and with it everything behind.
final class Phone: @unchecked Sendable {
    private let daemon = NSLock()
    /// The app in front answers again at this time (`now()`); nil: it answers at once.
    let silentUntil = LockedBox<Double?>(nil)
    /// When each touch reached the screen.
    let touches = LockedBox<[Double]>([])

    /// One request through testmanagerd. `asksTheApp`: it waits for the app in front to answer.
    private func daemon<T>(asksTheApp: Bool, _ work: () -> T) -> T {
        daemon.lock(); defer { daemon.unlock() }
        if asksTheApp, let until = silentUntil.value { while now() < until { Thread.sleep(forTimeInterval: 0.02) } }
        return work()
    }

    func serve(_ request: LocalRunner.Request) -> (status: Int, body: Data) {
        func ok(_ value: JSON) -> (Int, Data) { (200, (["value": value] as JSON).data()) }
        switch request.key {
        case "GET /status": return ok(["ready": true, "message": "in-process"])
        case "POST /session": return ok(["sessionId": "inprocess-1"])
        case "DELETE /session", "POST /appium/settings": return ok(.null)
        case "GET /wda/screen": return ok(["screenSize": ["width": 390, "height": 844]])
        case "GET /wda/locked": return ok(false)
        case "GET /wda/activeAppInfo":
            return daemon(asksTheApp: true) { ok(["bundleId": "com.example.chat", "name": "Chat", "pid": 506]) }
        case "GET /source":
            return daemon(asksTheApp: true) {
                let rows: [JSON] = (0..<6).map { i in ["type": "XCUIElementTypeCell", "label": .string("Chat \(i)"), "rect": ["x": 0, "y": .number(Double(120 + i * 70)), "width": 390, "height": 70]] }
                return ok(["type": "XCUIElementTypeApplication", "label": "Chat", "rect": ["x": 0, "y": 0, "width": 390, "height": 844], "children": .array(rows)])
            }
        case "GET /screenshot": return daemon(asksTheApp: false) { ok(.string(Data("png".utf8).base64EncodedString())) }
        case "POST /wda/tap": return daemon(asksTheApp: false) { touches.update { $0.append(now()) }; return ok(.null) }
        default: return (404, (["value": ["error": "unknown command", "message": .string(request.key)]] as JSON).data())
        }
    }
}

final class LocalRunnerTests: XCTestCase {
    private func makeLocalCore(_ phone: Phone, heldFor: Double = 60, unanswered: @escaping LocalRunner.Unanswered = { nil }) -> (PokiCore, FakeHost) {
        let host = FakeHost()
        var config = CoreConfig(approvalWait: 0.3, toolDeadline: 6, actionCap: 2, readTimeout: 1, busyWait: 0.2, treeFormat: "json", humanize: false)
        config.sensitive.enabled = false
        let lanes = LocalRunner(serve: phone.serve, unanswered: unanswered)
        lanes.heldFor = heldFor
        return (PokiCore(config: config, host: host, transport: lanes), host)
    }

    /// Seen on the phone (ESP-464): the chat app in front did not answer for 38 s, and the read that
    /// asked it held Poki's one queue all that time. 19 s in, the watchdog took the session for wedged
    /// and restarted it, which brought nothing back (the app still did not answer) and dropped the
    /// smaller tree limits the reads had come down to. A queue that is only waiting on an app is not
    /// restarted.
    func testAnAppThatDoesNotAnswerDoesNotRestartTheSession() async throws {
        let phone = Phone()
        let (core, host) = makeLocalCore(phone)
        core.runner.wedgedAfter = 1
        _ = await core.call("look", [:])
        phone.silentUntil.value = now() + 8
        let began = now()
        _ = await core.call("look", [:])
        // The read's 1.5 s, and up to 3 s waiting for a smaller re-read, not the 8 s of the app.
        XCTAssertLessThan(now() - began, 5.5, "the look returns within its own bounds")
        try await Task.sleep(nanoseconds: 6_000_000_000)
        XCTAssertEqual(host.restarts.value, 0, "a queue waiting on an app that does not answer is not wedged")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let after = await core.call("look", [:])
        XCTAssertTrue(after.text.contains("Chat 0"), "the tree comes as soon as the app answers: \(after.text)")
    }

    /// While the app in front does not answer, a touch sent to testmanagerd waits behind the request
    /// that asked the app and reaches the screen when the app answers, long after the agent was told
    /// it was not sent (seen on the phone before: swipes and taps landing after the agent had reported
    /// them failed). Nothing is sent while an earlier request is still unanswered, so nothing lands late.
    func testNoTouchLandsAfterTheAgentWasToldItWasNotSent() async throws {
        let phone = Phone()
        let (core, _) = makeLocalCore(phone)
        core.runner.wedgedAfter = 1
        _ = await core.call("look", [:])
        let answers = now() + 16
        phone.silentUntil.value = answers
        _ = await core.call("look", [:])
        var replies: [String] = []
        var slowest = 0.0
        while now() < answers - 2 {
            let began = now()
            let tap = await core.call("do", ["actions": [["tap": [100, 300]]]])
            slowest = max(slowest, now() - began)
            replies.append(String(tap.text.prefix(120)))
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        // Each waits at most the action's cap (2 s here) for the earlier request, then says not sent
        // with a picture, which waits at most a read's time and half a second (1.5 s here) when testmanagerd is held too.
        XCTAssertLessThan(slowest, 4.5, "a tap refused while a request is held answers within the action's cap and one picture")
        try await Task.sleep(nanoseconds: UInt64((answers - now() + 1) * 1_000_000_000))
        XCTAssertEqual(phone.touches.value.count, 0, "no touch landed after its call had answered: \(replies)")
        let later = await core.call("do", ["actions": [["tap": [100, 300]]]])
        XCTAssertFalse(later.isError, later.text)
        XCTAssertEqual(phone.touches.value.count, 1, "once the app answers, a tap goes through: \(later.text)")
    }

    /// On the phone, Poki's own process gives up on an app that does not answer before the request's
    /// caller does (the front-app lookup after 2 s, a snapshot after 6 s), so the request answers and
    /// nothing is held on the queue; that process still says what it waits on. Nothing that needs
    /// testmanagerd is sent meanwhile, at once and without a touch landing later; once it is through,
    /// a tap goes through.
    func testWhatThePhoneSideStillWaitsOnKeepsTouchesBack() async throws {
        let phone = Phone()
        let since = LockedBox<Double?>(nil)
        let (core, _) = makeLocalCore(phone, unanswered: { since.value.map { ("a lookup of the app in front", now() - $0) } })
        _ = await core.call("look", [:])
        since.value = now()
        let began = now()
        let tap = await core.call("do", ["actions": [["tap": [100, 300]]]])
        XCTAssertLessThan(now() - began, 1.5, "refused at once: \(tap.text)")
        XCTAssertTrue(tap.text.contains("not sent") || tap.text.contains("not_sent"), tap.text)
        XCTAssertEqual(phone.touches.value.count, 0, "nothing reached the screen")
        since.value = nil
        let later = await core.call("do", ["actions": [["tap": [100, 300]]]])
        XCTAssertFalse(later.isError, later.text)
        XCTAssertEqual(phone.touches.value.count, 1, "once it is through, a tap goes through: \(later.text)")
    }

    /// What must not get looser: a request still not through past testmanagerd's own limit (60 s on the
    /// phone, 3 s here) is a wedged queue, and the runner is restarted, also while the agent keeps
    /// calling and each call is refused at once. The new session then lets requests through again.
    func testARequestHeldPastTheDaemonsLimitStillRestartsTheRunner() async throws {
        let phone = Phone()
        let (core, host) = makeLocalCore(phone, heldFor: 3)
        core.runner.wedgedAfter = 1
        core.runner.busyLimit = 3
        _ = await core.call("look", [:])
        phone.silentUntil.value = now() + 15
        let until = now() + 9
        while now() < until, host.restarts.value == 0 {
            _ = await core.call("look", [:])
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        XCTAssertGreaterThanOrEqual(host.restarts.value, 1, "a request held past the daemon's limit is a wedged runner")
    }

    /// A runner that says it is still serving a request (Poki's own process says so in its status) is
    /// busy, not wedged: it is left to finish. A runner that answers nothing is restarted as before,
    /// and so is one whose request has run past any deadline.
    func testARunnerThatSaysItIsBusyIsNotRestartedAndOneThatAnswersNothingIs() async throws {
        func held(waiting seconds: Double, status: @escaping FakeWDA.Route) async throws -> Int {
            let (core, wda, host) = makeCore { $0.readTimeout = 0.3 }
            core.runner.wedgedAfter = 0.5
            _ = await core.call("look", [:])
            let stuck: FakeWDA.Route = { _ in try await Task.sleep(nanoseconds: 20_000_000_000); return (200, ["value": .null]) }
            for key in ["GET /source", "GET /screenshot", "GET /wda/activeAppInfo"] { wda.set(key, stuck) }
            wda.set("GET /status", status)
            _ = await core.call("look", [:])
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return host.restarts.value
        }
        let busy = try await held(waiting: 6) { _ in (200, ["value": ["ready": true, "busy": ["request": "GET /source", "seconds": 3]]]) }
        XCTAssertEqual(busy, 0, "a runner serving a request is left to finish")
        let silent = try await held(waiting: 10) { _ in try await Task.sleep(nanoseconds: 20_000_000_000); return (200, ["value": .null]) }
        XCTAssertGreaterThanOrEqual(silent, 1, "a runner that answers nothing is restarted")
        let overdue = try await held(waiting: 6) { _ in (200, ["value": ["ready": true, "busy": ["request": "GET /source", "seconds": 400]]]) }
        XCTAssertGreaterThanOrEqual(overdue, 1, "a request held past any deadline is a wedged runner")
    }
}
