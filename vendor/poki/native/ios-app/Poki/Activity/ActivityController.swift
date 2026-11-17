// The sending path is ported from two Live Activity managers: the latest-wins coalescing worker, the
// ordered operation tail and the update policy from AgentLiveActivityManager.swift in
// Clarklevis1995/dsh-mobile (commit ebe19764, DeepSeekHarnessMobile/LiveActivity/), MIT License,
// Copyright (c) 2026 Chaofan Li; the token bucket from ios/IPhoneAgent/App/LiveActivity.swift in
// onehumanbeing/esp32-iphone-agent (commit cc966294), MIT License, Copyright (c) 2026 Henry Yuan.
// See THIRD_PARTY_NOTICES.md.
import ActivityKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Runs the one Live Activity: started when a session starts, updated from PokiCore's events, ended
/// when the session stops or Poki closes.
///
/// AppModel only describes the state (`update`, `record`); this class decides what deserves a pop-up.
/// It compares each new state with the last one and, for the moments that matter, sends the update with
/// an `AlertConfiguration`, which lights the screen, expands the Dynamic Island and plays a sound:
///
/// - approval asked (always, never throttled): the screen lights even when locked;
/// - a run finishes (quiet for `finishAfter`), a problem, a pairing code, paired.
///
/// Never while the runner may be sending input: an alert expands the Dynamic Island over the top
/// of the screen, and on the owner's phone the agent's next tap (Back, a list's first row) landed
/// on the expanded island and opened Poki. So steps, the start of a run and app switches only
/// change the compact island and the Lock Screen (the event tag); they never expand it.
///
/// Sending: a state that needs the person (an approval, its answer, a problem, a pairing code, the
/// end of a run) goes out at once, in order. Plain progress waits 700 ms for the next one and only
/// the newest goes out, within a budget of two at once and then one a second, so a fast agent never
/// queues minutes of old steps behind the island.
@MainActor
final class ActivityController {
    private var activity: Activity<PokiActivityAttributes>?
    private(set) var state = PokiState(phase: .idle, headline: "Waiting for agent", thumbnailVersion: 0)
    private(set) var lastError: String?

    /// After this long without a new step, a run of steps counts as finished.
    var finishAfter: Duration = .seconds(15)
    /// How long the finished run stays before the activity folds back to Ready.
    var foldAfter: Duration = .seconds(30)

    /// How long an event tag stays on the Live Activity.
    private let eventLifetime: Duration = .seconds(6)
    /// Start, app switch and finish pop-ups are spaced this far apart.
    private let alertSpacing: TimeInterval = 6
    /// Plain progress waits this long for a newer state before it is sent.
    private static let coalescing: Duration = .milliseconds(700)

    private var lastAlert = Date.distantPast
    private var budget = UpdateBudget()
    private var plainWaiting = false
    private var worker: Task<Void, Never>?
    private var tail: Task<Void, Never>?
    private var finishTimer: Task<Void, Never>?
    private var chatOwnsCompletion = false
    private var foldTimer: Task<Void, Never>?
    /// Halfway to an approval's deadline the island is popped open once more (ESP-467).
    private var approvalReminder: Task<Void, Never>?
    private var eventTimer: Task<Void, Never>?
    private var inStep = false
    private var runAnnounced = false
    /// The plan on the activity belongs to a run that has finished: a new run starts without it.
    private var planFinished = false
    /// What this run's updates did, logged when it finishes: on the owner's phone the island kept a
    /// run's first step while the run went on (ESP-328, not seen on a simulator).
    private var tally = Tally()
    private struct Tally { var sent = 0, answered = 0, reported = 0, withoutActivity = 0, longestWait = 0.0 }
    /// The phase and step iOS last reported holding for the activity.
    private var held: (phase: PokiState.Phase, step: Int)?
    private static let runPhases: Set<PokiState.Phase> = [.working, .approval, .deciding, .handoff]
    private var justRecorded = false

    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// True where something else already says Poki is on while nothing happens (iOS 26's continued
    /// processing task has its own Lock Screen and island UI): then there is no idle Live Activity.
    /// It starts when work begins or Poki needs the person, and goes when the run has folded.
    var hidesWhenIdle: () -> Bool = { false }
    /// Poki is in front: iOS starts a Live Activity only then.
    var canStart: () -> Bool = { true }
    /// The device name `start` was last asked with: the activity is wanted, shown or not.
    private var wanted: String?
    /// Wanted but not shown because nothing is happening: not a fault.
    var waitsForWork: Bool { activity == nil && wanted != nil && state.isQuiet && hidesWhenIdle() }

    var isRunning: Bool { activity != nil }

    /// The sensor housing's smallest safe-area inset, in points of the screen's native size. iOS has no
    /// call that says whether the phone has a Dynamic Island, so this reads the window's top inset (59
    /// to 68 on the island phones) against the notch phones' (47 to 50). A phone this cannot read
    /// counts as having none, which keeps the banner.
    private static let dynamicIslandMinInset: CGFloat = 51

    private static func hasDynamicIsland() -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            let zoom = scene.screen.scale > 0 ? max(1, scene.screen.nativeScale / scene.screen.scale) : 1
            let visible = scene.windows.filter { !$0.isHidden }
            if let window = visible.first(where: \.isKeyWindow) ?? visible.first {
                let insets = window.safeAreaInsets
                let sensorInset = max(insets.top, max(insets.left, insets.right)) * zoom
                if sensorInset > 0 { return sensorInset >= dynamicIslandMinInset }
            }
            if let statusHeight = scene.statusBarManager?.statusBarFrame.height, statusHeight > 0 {
                return statusHeight * zoom >= dynamicIslandMinInset
            }
        }
        return false
    }

    /// Ends every Live Activity of Poki's: at launch, the ones a crashed or closed earlier run left
    /// behind (only this process updates its activity, so one it did not start is out of date); when
    /// Poki closes, its own, since nothing would update it after that. Detached, because Poki holds
    /// the main thread while it closes.
    nonisolated static func endAll() {
        let activities = Activity<PokiActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        Task.detached { for old in activities { await old.end(nil, dismissalPolicy: .immediate) } }
    }

    /// Starts the Live Activity if it is not running. iOS only allows this while Poki is in front, so
    /// it is called when the person taps something (Start, Start pairing, a setup step), never later
    /// from the background.
    func start(deviceName: String) {
        wanted = deviceName
        guard activity == nil else { return }
        // Keep it wanted for the next foreground update, without asking ActivityKit to start from
        // the background. Direct callers and update-driven restarts share the same restriction.
        guard canStart() else { return }
        if state.isQuiet, hidesWhenIdle() { lastError = nil; return }
        guard enabled else { lastError = "Live Activities are off for Poki (Settings > Poki > Live Activities)."; return }
        // A Live Activity left from an earlier run of the app is replaced.
        for old in Activity<PokiActivityAttributes>.activities { Task { await old.end(nil, dismissalPolicy: .immediate) } }
        do {
            let started = try Activity.request(attributes: PokiActivityAttributes(deviceName: deviceName), content: content(), pushType: nil)
            activity = started
            budget = UpdateBudget()
            lastError = nil
            Task { [weak self] in
                for await content in started.contentUpdates {
                    await MainActor.run { self?.tally.reported += 1; self?.held = (content.state.phase, content.state.stepCount) }
                }
            }
            // Dismissed by the person (swiped away) or ended by iOS: start again next time.
            Task { [weak self] in
                for await state in started.activityStateUpdates where state == .dismissed || state == .ended {
                    await MainActor.run { if self?.activity?.id == started.id { self?.activity = nil } }
                }
            }
        } catch { lastError = AppLocalization.text(LocalizedStringResource("The Live Activity did not start. \(error.localizedDescription)")) }
    }

    /// Counts a finished step for the step line and the run's summary.
    func record(step text: String, ok: Bool) {
        update { state in
            state.stepCount += 1
            if !ok {
                state.failedCount += 1
                // Under a plan, the step it went wrong in turns red.
                if let step = state.plan?.current, !(state.failedSteps ?? []).contains(step) { state.failedSteps = (state.failedSteps ?? []) + [step] }
            }
            // Only a step that went through is shown ticked under the next one.
            state.previous = ok ? String(text.prefix(80)) : nil
        }
        justRecorded = true
    }

    /// Ends the Live Activity at once, after the updates already on their way, so nothing is left on
    /// the Lock Screen or in the island.
    @discardableResult
    func end(dismissalPolicy: ActivityUIDismissalPolicy? = nil) -> Task<Void, Never>? {
        wanted = nil
        chatOwnsCompletion = false
        finishTimer?.cancel(); foldTimer?.cancel(); eventTimer?.cancel()
        if Self.runPhases.contains(state.phase) { logRun("cut off by ending the Live Activity") }
        worker?.cancel(); worker = nil; plainWaiting = false
        guard let activity else { return tail }
        self.activity = nil
        // A finished run or a problem stays on the Lock Screen with its final content for a while (HIG:
        // end at once, keep the outcome readable); anything else goes at once.
        let final: ActivityContent<PokiState>? = state.phase == .done || state.phase == .problem
            ? ActivityContent(state: state, staleDate: nil, relevanceScore: 0) : nil
        let policy = dismissalPolicy ?? (final == nil ? .immediate : .after(.now.addingTimeInterval(15 * 60)))
        state.guide = nil; state.pin = nil; state.since = nil; state.event = nil; state.previous = nil
        state.stepCount = 0; state.failedCount = 0; state.failedSteps = nil; state.endedAt = nil; state.decision = nil; state.plan = nil
        let previous = tail
        tail = Task { await previous?.value; await activity.end(final, dismissalPolicy: policy) }
        return tail
    }

    /// Takes the activity off the screen but keeps it wanted: the next work brings it back.
    private func hide() {
        worker?.cancel(); worker = nil; plainWaiting = false
        guard let activity else { return }
        self.activity = nil
        let previous = tail
        tail = Task { await previous?.value; await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Language is a presentation update, never an activity transition or a new automation session.
    func languageChanged() {
        state.uiLanguage = AppLocalization.language
        send(alert: nil, critical: true)
    }

    func update(_ change: (inout PokiState) -> Void) {
        let old = state
        change(&state)
        ActivityUpdatePolicy.settle(&state, over: old)
        let alert = transition(from: old)
        if state.phase == .working, let app = state.app { keepIcon(app) }
        // No idle activity where iOS's background task stands in: it comes with the work and goes with it.
        if activity == nil, let wanted, !state.isQuiet, canStart() {
            start(deviceName: wanted)
        } else if activity != nil, state.isQuiet, hidesWhenIdle() {
            hide()
        }
        // Something needs the person and there is no Live Activity to pop up: a banner instead (an
        // approval and a pairing code have their own).
        if let banner = attention, activity == nil {
            AttentionNotice.post(title: banner.title, body: banner.body)
        }
        attention = nil
        if state.handoff == nil, state.phase != .problem, old.handoff != nil || old.phase == .problem { AttentionNotice.clear() }
        send(alert: alert, critical: Self.isCritical(state, after: old))
    }
    /// The hand-off or problem this change pops up for (`update` posts a banner when no activity runs).
    private var attention: (title: String, body: String)?

    /// Puts the icon of the app the run is in where the widget reads it, before the update that shows
    /// it goes out. An icon only the App Store has is fetched for the next update; none is sent for it.
    private func keepIcon(_ app: String) {
        guard let url = AppIconFile.url(app), !FileManager.default.fileExists(atPath: url.path) else { return }
        if let icon = AppIconStore.shared.icon(app) {
            AppIconFile.write(icon, for: app)
        } else {
            Task { await AppIconStore.shared.load(app) }
        }
    }

    /// Writes a thumbnail, at most about 160 points wide, to the App Group container for the widget.
    func setThumbnail(_ jpeg: Data?) {
        guard let jpeg, let url = SharedContainer.thumbnailURL, let small = Self.shrink(jpeg, maxPixels: 260) else { return }
        try? small.write(to: url, options: .atomic)
        update { $0.thumbnailVersion += 1 }
    }

    // MARK: Transitions

    /// Fills in what the app does not track (run counters, the event tag) and returns the pop-up this
    /// change deserves, if any.
    private func transition(from old: PokiState) -> AlertConfiguration? {
        var alert: AlertConfiguration?
        let now = Date()
        // A problem's own word goes with it.
        if state.phase != .problem { state.label = nil }

        // The chat publishes its plan just before its first step, so a plan set since the last run
        // finished is the next run's.
        if state.plan != nil, state.plan != old.plan { planFinished = false }
        // The red steps belong to their plan.
        if state.plan?.steps != old.plan?.steps { state.failedSteps = nil }
        // A new run of steps: from anything that is not already a run.
        let runPhases = Self.runPhases
        if state.phase == .working, !runPhases.contains(old.phase) {
            state.stepCount = 0; state.failedCount = 0; state.failedSteps = nil; state.endedAt = nil; state.previous = nil
            // The app belongs to its run: a run that never reads the screen must not finish in the last run's app.
            if state.app == old.app { state.app = nil }
            tally = Tally()
            if planFinished { state.plan = nil; planFinished = false }
            AppLog.shared.add("activity", "run started from \(old.phase.rawValue)\(activity == nil ? " with no Live Activity" : "")")
            if state.since == nil { state.since = now }
            // The runner's start and the agent's first step are one start.
            if !runAnnounced {
                runAnnounced = true
                setEvent(.started, "Started")
            }
        }
        if state.phase == .done || state.phase == .idle && state.runnerPaused || state.phase == .pairing || state.phase == .setup {
            runAnnounced = false
        }
        if runPhases.contains(old.phase), !runPhases.contains(state.phase) { logRun("left for \(state.phase.rawValue)") }
        if state.phase != .done { foldTimer?.cancel() }
        // Into another app mid-run.
        if runPhases.contains(state.phase), let app = state.app, let before = old.app, app != before {
            setEvent(.app, app)
            // No pop-up: the runner is in the middle of acting.
        }
        // Your turn: the agent handed the screen to the person. Pops up and lights the screen; the
        // runner sends nothing while it waits, so the expanded island is safe. The run goes on after.
        if let handoff = state.handoff, handoff.id != old.handoff?.id {
            setEvent(.handoff, "Your turn")
            alert = critical(handoff.title, handoff.detail)
            attention = (handoff.title, handoff.detail)
        }
        if state.handoff == nil, old.handoff != nil, state.phase == .working {
            setEvent(.resumed, "Resumed")
        }
        // Approval: always pops up and lights the screen.
        if let approval = state.approval, approval.id != old.approval?.id {
            alert = critical(approval.question, "")
            remindHalfway(approval)
        }
        if state.approval == nil, let was = old.approval {
            state.decision = nil
            let approved = state.headline == "Continuing"
            let expired = !approved && was.expires <= now.addingTimeInterval(0.5)
            setEvent(approved ? .approved : expired ? .expired : .denied, approved ? "Allowed" : expired ? "Timed out" : "Denied")
        }
        if state.phase == .problem, old.phase != .problem {
            setEvent(.problem, state.label ?? "Problem")
            alert = critical(StatusWord.error.text, ActivityWords.local(state.headline))
            attention = (StatusWord.error.text, ActivityWords.local(state.headline))
        }
        if let pin = state.pin, pin != old.pin {
            setEvent(.code, "Code ready")
            alert = critical(String(activity: "Pairing code \(pin)"), String(activity: "Type it on the Pair with Poki screen in Settings"))
        }
        if old.phase == .pairing, state.phase == .idle, state.headline == "Paired" {
            setEvent(.paired, "Pairing complete")
            alert = critical(String(activity: "Poki’s paired"), String(activity: "This iPhone is ready for Poki"))
        }

        // A step began (AppModel sets the headline to the step's words): shown, never popped up.
        if state.phase == .working, old.phase == .working, state.headline != old.headline, state.stepCount == old.stepCount {
            if justRecorded { justRecorded = false } else { inStep = true }
        }
        if state.stepCount != old.stepCount { inStep = false }
        // The finish timer: re-armed by every change during a run; never fires in the middle of a step.
        if !chatOwnsCompletion, state.phase == .working, state.approval == nil, state.handoff == nil, state.stepCount > 0 { armFinish() } else { finishTimer?.cancel() }
        return alert
    }

    /// Updates that change what the person must do or know go out at once, ahead of plain progress.
    private static func isCritical(_ state: PokiState, after old: PokiState) -> Bool {
        state.phase != old.phase || state.approval?.id != old.approval?.id || state.decision != old.decision || state.pin != old.pin
    }

    /// iOS shows an alert's expanded island for a few seconds only. Halfway to the deadline, while the
    /// same approval still waits, the update carries the alert once more: one reminder, never a loop.
    /// The runner sends no input while an approval waits, so the expanded island is safe.
    private func remindHalfway(_ approval: PendingApproval) {
        approvalReminder?.cancel()
        let half = approval.expires.timeIntervalSinceNow / 2
        guard half > 5 else { return }
        approvalReminder = Task { [weak self] in
            try? await Task.sleep(for: .seconds(half))
            guard !Task.isCancelled, let self, self.state.phase == .approval, self.state.approval?.id == approval.id else { return }
            AppLog.shared.add("activity", "approval \(approval.id) reminded halfway")
            self.send(alert: self.critical(approval.question, ""), critical: true)
        }
    }

    private func armFinish() {
        finishTimer?.cancel()
        let count = state.stepCount
        finishTimer = Task { [weak self, finishAfter] in
            try? await Task.sleep(for: finishAfter)
            guard !Task.isCancelled else { return }
            self?.finishRun(ifCount: count)
        }
    }

    /// The local chat can be waiting for its model after a phone step has finished.
    func setChatOwnsCompletion(_ ownsCompletion: Bool) {
        chatOwnsCompletion = ownsCompletion
        if ownsCompletion { finishTimer?.cancel() }
    }

    func endStoppedRun() {
        update { state in
            state.phase = .idle
            state.headline = "Waiting for agent"
            state.plan = nil
            state.since = nil
        }
        end(dismissalPolicy: .immediate)
    }

    /// The chat's task ended: the run is finished now, not after the quiet wait. `alert` false when
    /// the chat tells the owner itself (its reply notification). True when the finish pop-up went to a
    /// Dynamic Island, so no banner is needed on top of it.
    @discardableResult
    func finishNow(alert: Bool) -> Bool {
        finishTimer?.cancel()
        guard state.phase == .working, state.approval == nil, state.handoff == nil else {
            if Self.runPhases.contains(state.phase) { AppLog.shared.add("activity", "the run was not marked finished: the activity shows \(state.phase.rawValue)") }
            return false
        }
        inStep = false
        return finish(alert: alert)
    }

    private func finishRun(ifCount count: Int) {
        guard !chatOwnsCompletion, state.phase == .working, state.approval == nil, !inStep, state.stepCount == count, count > 0 else { return }
        finish(alert: true)
    }

    /// True when the finish pop-up went to a Dynamic Island, which already tells the owner the run is over.
    @discardableResult
    private func finish(alert: Bool) -> Bool {
        state.phase = .done
        planFinished = true
        logRun("finished")
        runAnnounced = false
        state.endedAt = Date()
        state.previous = nil
        state.headline = "Finished"
        setEvent(.finished, "Run finished")
        let summary = state.runSummary ?? state.doneTitle
        let popUp = alert ? ordinary(StatusWord.done.text, summary) : nil
        send(alert: popUp, critical: true)
        armFold()
        return popUp != nil && isRunning && Self.hasDynamicIsland()
    }

    /// What a run's updates did, once iOS has had time to take the last one.
    private func logRun(_ how: String) {
        let steps = state.stepCount
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            let t = self.tally, held = self.held.map { "\($0.phase.rawValue) step \($0.step)" } ?? "nothing reported"
            AppLog.shared.add("activity", "run \(how) at step \(steps): \(t.sent) updates sent, \(t.answered) answered, iOS reported \(t.reported) and holds \(held); \(t.withoutActivity) with no Live Activity; longest wait for the update budget \(String(format: "%.1f", t.longestWait)) s; \(self.activity.map { "\($0.activityState)" } ?? "no activity"), \(Activity<PokiActivityAttributes>.activities.count) Poki activities")
        }
    }

    /// The finished run stays a while, then the activity folds back to Ready: no old run is left
    /// on the Lock Screen.
    private func armFold() {
        foldTimer?.cancel()
        foldTimer = Task { [weak self, foldAfter] in
            try? await Task.sleep(for: foldAfter)
            guard !Task.isCancelled, let self, self.state.phase == .done else { return }
            self.update { state in
                state.phase = .idle
                state.headline = "Waiting for agent"
                state.previous = nil; state.stepCount = 0; state.failedCount = 0; state.failedSteps = nil
                state.since = nil; state.endedAt = nil; state.event = nil; state.plan = nil
            }
        }
    }

    private func setEvent(_ kind: PokiActivityAttributes.Event.Kind, _ text: String) {
        state.event = .init(kind: kind, text: text)
        eventTimer?.cancel()
        let shown = state.event
        eventTimer = Task { [weak self, eventLifetime] in
            try? await Task.sleep(for: eventLifetime)
            guard !Task.isCancelled, let self, self.state.event == shown else { return }
            self.state.event = nil
            self.send(alert: nil, critical: false)
        }
    }

    private func ordinary(_ title: String, _ body: String) -> AlertConfiguration? {
        let now = Date()
        guard now.timeIntervalSince(lastAlert) >= alertSpacing else { return nil }
        lastAlert = now
        return AlertConfiguration(title: "\(title)", body: "\(body)", sound: .default)
    }

    private func critical(_ title: String, _ body: String) -> AlertConfiguration {
        lastAlert = Date()
        return AlertConfiguration(title: "\(title)", body: "\(body)", sound: .default)
    }

    // MARK: Sending

    private func send(alert: AlertConfiguration?, critical: Bool) {
        guard activity != nil else { tally.withoutActivity += 1; return }
        if critical || alert != nil {
            // Ahead of any plain progress still waiting, which this state replaces.
            plainWaiting = false
            worker?.cancel(); worker = nil
            budget.spend(at: Self.now())
            enqueue(content(), alert: alert)
            return
        }
        plainWaiting = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            try? await Task.sleep(for: ActivityController.coalescing)
            guard let self, !Task.isCancelled else { return }
            let wait = self.budget.wait(at: Self.now())
            self.tally.longestWait = max(self.tally.longestWait, wait)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self.worker = nil
            guard self.plainWaiting else { return }
            self.plainWaiting = false
            self.budget.spend(at: Self.now())
            // The newest state, read now: everything since the first wait goes out as one update.
            self.enqueue(self.content(), alert: nil)
        }
    }

    /// Updates go out one after another, so an alert is never overtaken by an older update.
    private func enqueue(_ content: ActivityContent<PokiState>, alert: AlertConfiguration?) {
        guard let activity else { return }
        let previous = tail
        tally.sent += 1
        let queued = Date()
        tail = Task {
            await previous?.value
            let began = Date()
            if let alert { await activity.update(content, alertConfiguration: alert) } else { await activity.update(content) }
            self.tally.answered += 1
            let seconds = Date().timeIntervalSince(began)
            if alert != nil {
                // For the Activity Log: iOS opens the island for an alert, but not while Poki itself is in
                // front, and late if the update waited behind others.
                let state = switch UIApplication.shared.applicationState { case .active: "active"; case .inactive: "inactive"; default: "background" }
                AppLog.shared.add("activity", "alert sent with \(content.state.phase.rawValue) \(String(format: "%.1f", Date().timeIntervalSince(queued))) s after it was queued; \(activity.activityState); Poki \(state)")
            }
            guard seconds > 2 else { return }
            AppLog.shared.add("activity", "the update to \(content.state.phase.rawValue) step \(content.state.stepCount) took \(String(format: "%.1f", seconds)) s; \(activity.activityState)")
        }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// ActivityKit refuses a state over 4 KB. Ours is far smaller, but long texts from an agent are cut
    /// so an update is never lost to size.
    private func trimToFit() {
        func size() -> Int { (try? JSONEncoder().encode(state).count) ?? 0 }
        guard size() > 3_500 else { return }
        state.headline = String(state.headline.prefix(80))
        state.previous = nil
        if let steps = state.plan?.steps { state.plan?.steps = steps.map { String($0.prefix(30)) } }
        if var approval = state.approval {
            approval.summary = String(approval.summary.prefix(80)); approval.reason = String(approval.reason.prefix(60))
            state.approval = approval
        }
    }

    private func content() -> ActivityContent<PokiState> {
        trimToFit()
        // Approvals are urgent; everything else is not. An approval goes stale when it expires.
        // An approval goes stale when it expires. A run goes stale when no update has come for ten
        // minutes (Poki was closed or suspended), and then says it is not updating.
        let stale = state.approval?.expires ?? (state.phase == .working ? Date.now.addingTimeInterval(600) : nil)
        return ActivityContent(state: state, staleDate: stale, relevanceScore: state.approval == nil && state.handoff == nil ? 50 : 100)
    }

    private static func shrink(_ data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

/// A step from the agent never replaces an approval that is still waiting or being answered: the
/// phase stays until the approval itself ends. (dsh-mobile's AgentLiveActivityUpdatePolicy.)
enum ActivityUpdatePolicy {
    static func settle(_ incoming: inout PokiState, over current: PokiState) {
        guard current.phase.holdsApproval, incoming.phase == .working,
              let approval = incoming.approval, approval.id == current.approval?.id else { return }
        incoming.phase = current.phase
        incoming.decision = current.decision
    }
}

/// The update budget, a token bucket: two updates at once, then one a second. Critical updates
/// spend from it without waiting, so the plain ones after them wait their turn.
/// (esp32-iphone-agent's LiveActivityController rate limit.)
struct UpdateBudget {
    static let perSecond = 1.0
    static let burst = 2.0
    private var tokens = burst
    private var refilled: TimeInterval?

    /// Seconds from `now` until the next update may go out; 0 when one may go now.
    mutating func wait(at now: TimeInterval) -> TimeInterval {
        refill(at: now)
        return tokens >= 1 ? 0 : (1 - tokens) / Self.perSecond
    }

    mutating func spend(at now: TimeInterval) {
        refill(at: now)
        tokens = max(0, tokens - 1)
    }

    private mutating func refill(at now: TimeInterval) {
        if let refilled { tokens = min(Self.burst, tokens + (now - refilled) * Self.perSecond) }
        refilled = now
    }
}
