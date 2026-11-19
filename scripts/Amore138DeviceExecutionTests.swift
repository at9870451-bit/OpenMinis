// TEST FIXTURE ONLY. Amore138DeviceRegression.swift inserts three unmodified
// AppModel members here. Native frameworks/launcher/core below are inert fakes;
// passing these tests is not evidence of real-device pairing or automation.
import Foundation

enum PokiCore {
    struct ToolAnswer: Sendable {
        let text: String
        let jpeg: Data?
        let isError: Bool
    }
}
enum AutomationPath { case inProcess, runner }
enum InProcessSession: Equatable { case idle, opening, open, closing(reopen: Bool) }
struct RunnerStatus {
    var state: String
    var isRunning: Bool { state == "running" }
}
struct AppLocalization { static func text(_ text: String) -> String { text } }
enum InProcessWDA { static let automationDeclined = false }
@MainActor final class UIApplication {
    enum State { case active }
    static let shared = UIApplication()
    var applicationState = State.active
}
final class FakeLog { func add(_ category: String, _ message: String) {} }
final class FakeHost {
    var paused = false
    func setPaused(_ value: Bool) { paused = value }
}
struct FakeActivityState {
    var runnerPaused = false
    enum Phase { case working }
    var phase = Phase.working
    var headline = ""
    var since: Date?
}
final class FakeActivity {
    func update(_ body: (inout FakeActivityState) -> Void) { var state = FakeActivityState(); body(&state) }
}
@MainActor final class FakeCore {
    var calls = 0
    var whileCalling: (() -> Void)?
    func callTool(_ name: String, arguments: String, localSession: String?, expectedApps: Set<String>? = nil) async -> PokiCore.ToolAnswer {
        calls += 1
        whileCalling?()
        await Task.yield()
        return PokiCore.ToolAnswer(text: "fixture result", jpeg: nil, isError: false)
    }
}

@MainActor final class ExecutionHarness {
    let core = FakeCore(), host = FakeHost(), log = FakeLog(), activity = FakeActivity()
    static let passcodeConfirmationMessage = "Explicit Continue is required"
    static let onSimulator = false
    enum IdlePolicy { case pauseAutomation }
    let idleSessionPolicy = IdlePolicy.pauseAutomation
    var automationPath = AutomationPath.inProcess
    var inProcessSession = InProcessSession.idle
    var sessionOn = true, sessionStarting = false, runnerPaused = false, ownerPaused = false
    var runner = RunnerStatus(state: "running")
    var sessionStartTask: Task<Void, Never>?
    var passcodeConfirmationPending = false, probeDriven = false
    var amoreExecutionGeneration = 0, amoreDeviceCallsInFlight = 0
    var chatTaskActive = false, amorePreparationInProgress = false
    var inProcessWarming = false, inFront = true, endingTasks = 0
    var stepUnderWay: String?, problem: String?
    var approvals: [String] = []
    var lastAgentActivity = Date.distantPast, lastStepAt = Date.distantPast
    var starts = 0, opens = 0, closes = 0, needsConsent = false
    func startSession() { starts += 1; sessionOn = true; runnerPaused = true; runner.state = "standby" }
    func launchRunner() { runner.state = "running"; warmInProcess("fake launcher completed") }
    func warmInProcess(_ why: String) {
        guard inProcessSession == .opening else { return }
        if needsConsent { passcodeConfirmationPending = true; return }
        opens += 1; inProcessSession = .open
    }
    func closeInProcess(_ why: String, keepingSession: Bool) { closes += 1; inProcessSession = .idle }
    func standBy(reason: String?, keepingDone: Bool) { runnerPaused = true }
    // APPMODEL_MEMBERS
}

func expect(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), "FAIL: \(label)")
    print("PASS: \(label)")
}

@main struct Amore138DeviceExecutionTests {
    @MainActor static func main() async {
        var lease = AmoreDeviceTaskLease()
        expect(lease.claim(nil) == .began, "anonymous first tool begins a task")
        expect(lease.claim(nil) == .continued, "anonymous second tool continues")
        expect(lease.claim("B") == .busy, "anonymous task excludes another conversation")
        expect(!lease.release("B"), "wrong owner cannot finish")
        expect(lease.release(nil), "anonymous task can finish")
        expect(lease.claim("A") == .began, "new owner can begin after finish")
        lease.reset(); expect(!lease.occupied, "pause clears occupancy")

        let cold = ExecutionHarness(); cold.sessionOn = false
        _ = await cold.runTool("look", arguments: "{}")
        expect(cold.starts == 1 && cold.opens == 1 && cold.core.calls == 1, "cold look starts and wakes once")

        let warmed = ExecutionHarness() // DDI ready, actual session still idle
        warmed.core.whileCalling = {
            expect(warmed.inProcessSession == .open, "prewarmed first look requests the real open")
            warmed.closeBecausePokiOpened()
        }
        _ = await warmed.runTool("look", arguments: "{}")
        expect(warmed.opens == 1 && warmed.closes == 0, "foreground callback cannot close in-flight look")
        expect(warmed.amoreDeviceCallsInFlight == 0, "in-flight lease releases after result")
        warmed.chatTaskActive = true; warmed.closeBecausePokiOpened()
        expect(warmed.closes == 0, "foreground between tools keeps the active task")
        warmed.chatTaskActive = false; warmed.amorePreparationInProgress = true; warmed.closeBecausePokiOpened()
        expect(warmed.closes == 0, "foreground preserves explicit preparation")
        warmed.amorePreparationInProgress = false; warmed.closeBecausePokiOpened()
        expect(warmed.closes == 1, "idle foreground still closes automation")

        let status = ExecutionHarness(); status.sessionOn = false
        _ = await status.runTool("status", arguments: "{}")
        expect(status.starts == 0 && status.opens == 0, "status never starts or wakes")
        let consent = ExecutionHarness(); consent.needsConsent = true
        let denied = await consent.runTool("do", arguments: "{}")
        expect(denied.isError && denied.text.contains("not_sent") && consent.core.calls == 0, "new OS consent cannot be bypassed")
        let stopped = ExecutionHarness(); stopped.sessionOn = false; stopped.sessionStarting = true
        stopped.sessionStartTask = Task { @MainActor in
            await Task.yield(); stopped.amoreExecutionGeneration += 1; stopped.sessionOn = true
        }
        let cancelled = await stopped.runTool("do", arguments: "{}")
        expect(cancelled.isError && stopped.core.calls == 0 && stopped.opens == 0, "stop during session wait cannot send or wake")

        func classify(_ ready: Bool, _ verified: Bool) -> AmoreDeviceStatus.State {
            AmoreDeviceStatus.classify(pairingPresent: true, pairingRejected: false, developerMode: true,
                sessionOn: true, runnerRunning: true, inProcessOpen: false, inProcess: false,
                channelWorking: true, preparing: false, automationReady: ready, pairingVerified: verified)
        }
        expect(classify(false, false) != .currentDevice, "hello alone is not connected")
        expect(classify(true, false) != .currentDevice, "runner without authenticated verification is not connected")
        expect(classify(true, true) == .currentDevice, "real ready plus full verification permits ready status")
        let safe = AmoreDeviceDiagnostic.safe("runner failed: handshake; fix: keep existing pairing\nAuthorization: Bearer fixtureTOKEN\nHostID=fixture-secret\npairing_file=/fixture/record.mobiledevicepairing\n" + String(repeating: "a", count: 64))
        expect(safe.contains("runner failed: handshake") && safe.contains("fix:"), "diagnostics retain operational cause and fix")
        expect(!safe.contains("fixtureTOKEN") && !safe.contains("fixture-secret") && !safe.contains("/fixture/record") && !safe.contains(String(repeating: "a", count: 64)), "diagnostics redact credentials and record paths")
        print("PASS: injected production-member regression; NOT a real-device test")
    }
}
