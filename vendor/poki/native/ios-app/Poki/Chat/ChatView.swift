import AVFoundation
import PhotosUI
import SwiftUI

/// The chat is the app. Before your first message it is the home page: the fog-blue ground, Poki's
/// picture at the top, one line of greeting and what you could ask. Your first message turns it into
/// the conversation: the ground sinks away and your words rise out of the message field. The top bar
/// stays where it is through all of it: the conversations on the left, Poki in the middle, a new
/// conversation on the right. An approval or a hand-over shows as a card above the message field,
/// where iOS hides the Dynamic Island while Poki is in front.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    var sharedDraft: Binding<String>? = nil
    /// Opens Poki's card: under Poki's picture over the greeting on the home page (the bottom of the
    /// picture, in global points), under the top bar in the chat (nil).
    var openDetails: (_ under: CGFloat?) -> Void
    var openVoice: () -> Void
    var openSetup: () -> Void
    var openSetupStep: (SetupStep) -> Void = { _ in }
    var openModel: () -> Void
    /// Opens where the OpenAI key for Talk with Poki goes: the key's form, or Live Voice when it is off.
    var openVoiceKey: () -> Void = {}
    /// Opens the conversations (the drawer on iPhone); nil where the list is always beside the chat.
    var openThreads: (() -> Void)? = nil
    /// Opens External Agents, from the home page's hint.
    var openAgents: () -> Void = {}
    /// Opens Updates, from the home page's hint.
    var openUpdates: () -> Void = {}
    var sessionStore: SessionStore = .shared
    var shortcutStore: HomeShortcutStore = .shared

    private var voice: VoiceModel { model.voice }
    /// The taps on Poki's picture, for the bear to answer.
    @State private var pokes = 0
    /// Where Poki's picture over the greeting ends, for the card to open under it.
    @State private var homeBottom: CGFloat?
    /// How far Poki's picture rises from the home page into the top bar.
    @State private var flightRise: CGFloat = 0

    /// A tap on Poki, on the home page or in the chat: the bear says hi and Poki's card opens.
    private func tapPoki() {
        pokes += 1
        openDetails(isGreeting ? homeBottom : nil)
    }
    /// The message field has the keyboard.
    @State private var writing = false
    @State private var standaloneDraft = ""
    private var draft: Binding<String> { sharedDraft ?? $standaloneDraft }
    /// Taps on New Conversation on the home page, for the message field (`ComposerInputView.restarts`).
    @State private var restarts = 0
    /// The page's height, for how far your first words rise.
    @State private var pageHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var sampleScene: String? { UserDefaults.standard.string(forKey: "pokiChat") }

    /// No message of yours yet: the page is the bear and what you could ask, not a transcript.
    private var isGreeting: Bool {
        guard !chat.running, !voice.isOn, voice.lines.isEmpty else { return false }
        return !chat.entries.contains(where: Self.isContent)
    }

    /// Anything but the time and Poki's own opening lines.
    private static func isContent(_ entry: ChatEntry) -> Bool {
        switch entry.kind {
        case .time, .poki: false
        default: true
        }
    }

    /// The conversation without the greeting's lines, which the home page said itself.
    private var shown: [ChatEntry] {
        guard let first = chat.entries.firstIndex(where: Self.isContent) else { return [] }
        return chat.entries.enumerated().compactMap { i, entry in
            if i < first, case .poki = entry.kind { return nil }
            return entry
        }
    }

    /// The task is under way; the screenshots' sample scenes stand still in that state.
    private var live: Bool { busy || sampleScene == "setupHint" }

    /// Poki is at work (or the sample scene shows it at work): the message field offers Stop.
    private var busy: Bool {
        chat.running || ["working", "approval", "handoff"].contains(sampleScene ?? "")
    }

    /// A newer Poki is on the channel, or downloaded and ready to install: its version, for the home
    /// page's hint. `-pokiUpdate <version>` shows the hint for the screenshots.
    private var update: String? {
        if let sample = UserDefaults.standard.string(forKey: "pokiUpdate") { return sample }
        guard sampleScene == nil else { return nil }
        if model.signer.updateNotReady, let latest = model.signer.latest { return latest.version }
        if let next = model.signer.next, next.kind == "update" { return next.version }
        return nil
    }

    /// `-pokiChat backdrop`: the home page's ground alone, to lay beside the design's rendering of it.
    private var bare: Bool { sampleScene == "backdrop" }

    /// What the core last saw of the screen, for the live task's card. A sample scene and the demo
    /// have no phone behind them: they show a drawn stand-in.
    private var shot: Image? {
        if sampleScene != nil { return SampleShot.image(dark: scheme == .dark) }
        return model.lastShot.map { Image(uiImage: $0) }
    }

    var body: some View {
        let status = PokiStatus.current(model: model, chat: chat)
        let home = isGreeting
        ZStack {
            ChatTranscript(entries: shown, typing: chat.awaitingModel, canRetry: chat.canRetry, retry: chat.retry, session: chat.sessionID,
                           live: live, waiting: !model.approvals.isEmpty || sampleScene == "approval" || chat.demoAsk != nil,
                           handedOver: model.handoffText != nil || sampleScene == "handoff",
                           plan: chat.planSteps, app: sampleScene == nil ? chat.taskApp : ChatModel.Sample.app(sampleScene),
                           shot: shot, rise: reduceMotion || !(sampleScene == nil || sampleScene == "demo") ? nil : rise) {
                if !home, let hint = currentSetupHint {
                    SetupHintLine(hint: hint, openSetupStep: openSetupStep, openSetup: openSetup, openModel: openModel)
                }
                LiveVoiceTranscript(voice: voice)
            }
            // The home page stays in the tree while the conversation is in front, neither seen nor
            // touched, so a new conversation brings it back on the same animation.
            HomePage(home: home, writing: writing, rise: flightRise, sessionStore: sessionStore, shortcutStore: shortcutStore,
                     pick: { model.prepareForTask(); chat.setDraftActivity(true); draft.wrappedValue = $0; writing = true }) {
                if home, let update { UpdatePill(version: update, open: openUpdates) }
                if home, let hint = homeHint {
                    SetupHintLine(hint: hint, openSetupStep: openSetupStep, openSetup: openSetup, openModel: openModel,
                                  openAgents: openAgents, openUpdates: openUpdates)
                }
            }
            .allowsHitTesting(home)
            .accessibilityHidden(!home)
        }
        .opacity(bare ? 0 : 1)
        // The conversation passes under the top bar's floating controls through the system's soft
        // scroll edge (`topBar`), with no line under them.
        .topBar {
            if !bare {
                ChatTopBar(status: status, home: home, busy: busy, openThreads: openThreads,
                           newConversation: { if home { restarts += 1 } else { chat.newConversation() } }, openDetails: tapPoki)
            }
        }
        .bottomBar(softEdge: true) {
            if !bare { VStack(spacing: 8) {
                asks
                if chat.waitingForSplitView {
                    Label(ActivityWords.local("Waiting for Split View"), systemImage: "rectangle.split.2x1")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ComposerInputView(input: draft, focused: $writing, running: busy, progress: progress, restarts: restarts,
                                  send: { chat.send($0, attachments: $1) }, stop: chat.stop, openVoice: openVoice, openVoiceKey: openVoiceKey,
                                  noticeHeight: max(120, pageHeight * 0.6))
            }
            .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 10)
            .frame(maxWidth: 720) }
        }
        .background { HomeBackdrop(home: home, working: busy, frozen: bare) }
        .overlayPreferenceValue(PicturePlaceKey.self) { anchors in
            GeometryReader { proxy in
                if !bare {
                    PokiFlight(status: status, home: home, writing: writing, places: anchors.mapValues { proxy[$0] }, pokes: pokes,
                               tap: tapPoki, landed: { homeBottom = $0 }, travel: { flightRise = $0 })
                }
            }
        }
        // While you talk with Poki: its light along the bottom edge, over the page, following the talk.
        .overlay {
            ZStack {
                if let talk = voice.talkState, !talk.isFailed {
                    TalkEdgeGlow(strength: talk.glow).transition(.opacity)
                }
            }
            .animation(TalkMotion.glow, value: voice.talkState)
        }
        // The bear says hi as a talk begins.
        .onChange(of: voice.isOn) { _, on in if on { pokes += 1 } }
        .onChange(of: writing) { _, focused in if focused { model.prepareForTask() } }
        .onChange(of: draft.wrappedValue) { _, text in
            chat.setDraftActivity(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { pageHeight = $0 }
        .animation(.snappy, value: voice.isOn)
        .animation(.snappy, value: model.approvals.first?.id)
        .animation(.snappy, value: model.handoffText)
        .animation(.snappy, value: chat.demoAsk?.id)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: chat.running) { was, now in
            if was, !now, endedWell { DoneLinger.shared.celebrate() }
        }
        .onChange(of: MessageFieldAsk.shared.pending, initial: true) { if MessageFieldAsk.shared.take() { writing = true } }
    }

    /// How far your first words rise: from the message field to their place under the top bar.
    private var rise: CGFloat { max(120, pageHeight - 240) }

    // MARK: What waits for you

    /// The step waiting for your answer, or the hand-over, above the message field.
    @ViewBuilder private var asks: some View {
        if sampleScene == "approval" {
            let sample = ChatModel.Sample.approval
            ApprovalAskCard(title: sample.question, expires: sample.expires, answer: { _ in }, stopAsking: {})
        } else if sampleScene == "handoff" {
            TurnCard(text: Self.local(AppModel.handoffWording(.passcode)), done: {})
        } else if let ask = chat.demoAsk {
            ApprovalAskCard(title: ChatModel.Sample.demoApproval.question, expires: ask.expires, answer: chat.answerDemo)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let approval = model.approvals.first {
            ApprovalAskCard(title: approval.question, expires: approval.expires,
                            answer: { approved in model.resolve(approval, approved: approved) },
                            stopAsking: approval.offersStopAsking ? { model.stopAsking(approval) } : nil)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if model.passcodeHint {
            Label(Self.local(AppModel.handoffWording(.automationPasscode)), systemImage: "lock")
                .font(.callout).padding(12)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("session.passcode")
        } else if model.preparingPhone {
            HStack(spacing: 8) {
                ProgressView()
                Text("Preparing")
            }
            .font(.callout).padding(8)
            .accessibilityIdentifier("session.preparing")
        } else if let text = model.handoffText {
            TurnCard(text: Self.local(text), done: model.handoffDoneInApp)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The app's own hand-over wordings in the phone's language; the model's own words as they are.
    private static func local(_ text: String) -> String {
        AppLocalization.bundle.localizedString(forKey: text, value: text, table: nil)
    }

    /// How far the task is, for the ring around Stop: the finished steps out of the model's plan, or
    /// out of the steps so far when it published none.
    private var progress: Double? {
        guard busy else { return nil }
        for entry in chat.entries.reversed() {
            switch entry.kind {
            case .plan(let steps):
                let total = max(chat.planSteps?.count ?? 0, steps.count)
                return total > 0 ? Double(steps.filter { $0.state == .done }.count) / Double(total) : nil
            case .you, .request: return nil
            default: continue
            }
        }
        return nil
    }

    /// The task that just ended went through: its last steps hold no failure and it did not end on a problem.
    private var endedWell: Bool {
        for entry in chat.entries.reversed() {
            switch entry.kind {
            case .note(.problem): return false
            case .plan(let steps): return !steps.contains { $0.state == .failed }
            case .you, .request: return false
            default: continue
            }
        }
        return false
    }

    /// When a setup step or model account keeps Poki from acting, the chat shows one grey line and a
    /// link straight to that item (ESP-174 board "C1 Chat setup hint").
    private var currentSetupHint: SetupIssueHint? {
        if sampleScene == "setupHint" {
            return SetupIssueHint(
                message: AppLocalization.text(LocalizedStringResource("Amore can’t tap Send yet: UI Automation is off.")),
                link: AppLocalization.text(LocalizedStringResource("Turn On UI Automation ›")),
                target: .step(.automation)
            )
        }
        guard sampleScene == nil else { return nil }
        return SetupIssueHint.first(model: model)
    }

    private var homeHint: SetupIssueHint? {
        sampleScene == nil ? SetupIssueHint.homeLine(model: model) : currentSetupHint
    }
}

extension View {
    /// The message field's place on the bottom edge: a safe-area bar on iOS 26 (the conversation fades
    /// under it, as under the system's bars), an inset before it.
    @ViewBuilder func bottomBar<Bar: View>(softEdge: Bool = false, @ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0) { GlassEffectContainer(spacing: 8) { bar() } }
                .scrollEdgeEffectStyle(softEdge ? .soft : .automatic, for: .bottom)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { bar() }
        }
    }

    /// A page's own top bar (the chat's, the conversations'): a safe-area bar on iOS 26, so what
    /// scrolls passes under it through the system's soft scroll edge, as under the system's bars; an
    /// inset before it. The bar draws no ground of its own: a ground would cover the edge effect and
    /// leave a hard line where it ends.
    @ViewBuilder func topBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0) { bar() }.softTopEdge()
        } else {
            safeAreaInset(edge: .top, spacing: 0) { bar() }
        }
    }

    /// The one place the top scroll edge's style is set, for every scroll view under this view: the
    /// system's soft edge, a blur that thins out from the bar down, on iOS 26 and later. `automatic`
    /// leaves the style to the system, which may draw the hard edge, a nearly opaque band with a
    /// straight line under it (Apple's `ScrollEdgeEffectStyle`). Nothing before iOS 26.
    @ViewBuilder func softTopEdge() -> some View {
        if #available(iOS 26.0, *) { scrollEdgeEffectStyle(.soft, for: .top) } else { self }
    }

    /// Marks the bear Poki's profile zooms out of.
    @ViewBuilder func profileSource(_ namespace: Namespace.ID?, id: String = "poki") -> some View {
        if let namespace { matchedTransitionSource(id: id, in: namespace) } else { self }
    }
}

/// A setup or account issue surfaced inline in the chat, with a direct link to the exact item.
struct SetupIssueHint: Equatable {
    enum Target: Equatable {
        case step(SetupStep)
        case model
        case setup
        /// Agents and Relay (Home only).
        case agents
        /// Health › Updates, where the renewed build installs (Home only).
        case updates
    }
    var message: String
    var link: String
    var target: Target

    /// Runner or pairing failure from the launcher (#78 failure codes: `unreachable` "Can't Reach iPhone",
    /// `handshake`, `pairing`, `developer_mode`, `no_cryptexd`, `runner_blocked`, `runner`, `loopback`).
    @MainActor static func runnerIssue(model: AppModel) -> SetupIssueHint? {
        if let trouble = model.pairingTrouble {
            return SetupIssueHint(
                message: AppLocalization.text(LocalizedStringResource("The phone no longer accepts Poki’s pairing (\(trouble)). Pair again in Setup, it takes a minute.")),
                link: AppLocalization.text(LocalizedStringResource("Pair This iPhone ›")),
                target: .step(.pairing)
            )
        }
        let runner = model.runner
        if runner.state == "failed" || model.servicesSilent {
            let code = runner.code ?? (model.servicesSilent ? "handshake" : nil)
            let headline = AppModel.problemText(code: code, fix: runner.fix ?? "Can’t Reach iPhone")
            let localizedHeadline = AppLocalization.bundle.localizedString(forKey: headline, value: headline, table: "LiveActivity")
            let rawFix = runner.fix ?? ""
            let detail = rawFix.isEmpty
                ? localizedHeadline
                : AppLocalization.bundle.localizedString(forKey: rawFix, value: rawFix, table: nil)
            let message = detail.contains(localizedHeadline) ? detail : "\(localizedHeadline): \(detail)"
            switch code {
            case "unreachable", "handshake", "loopback":
                return SetupIssueHint(
                    message: message,
                    link: AppLocalization.text(LocalizedStringResource("Turn On Local Connection ›")),
                    target: .step(.loopback)
                )
            case "pairing":
                return SetupIssueHint(
                    message: message,
                    link: AppLocalization.text(LocalizedStringResource("Pair This iPhone ›")),
                    target: .step(.pairing)
                )
            case "developer_mode", "no_cryptexd":
                return SetupIssueHint(
                    message: message,
                    link: AppLocalization.text(LocalizedStringResource("Turn On Developer Mode ›")),
                    target: .step(.developerMode)
                )
            case "runner_blocked":
                return SetupIssueHint(
                    message: message,
                    link: AppLocalization.text(LocalizedStringResource("Turn On UI Automation ›")),
                    target: .step(.automation)
                )
            case "runner":
                return SetupIssueHint(
                    message: message,
                    link: AppLocalization.text(LocalizedStringResource("Install its helper ›")),
                    target: .step(.runner)
                )
            default:
                return SetupIssueHint(
                    message: message,
                    link: AppLocalization.text(LocalizedStringResource("Open Setup ›")),
                    target: .setup
                )
            }
        }
        return nil
    }

    /// Steps count as `AppModel.stepReadyForUse` shows them, so a configured loopback check in flight
    /// or an active local session does not flash an off hint.
    @MainActor static func first(model: AppModel) -> SetupIssueHint? {
        if let runnerHint = runnerIssue(model: model) {
            return runnerHint
        }
        if let localHint = localSessionIssue(model: model) {
            return localHint
        }
        if !model.setupReadyForUse {
            for step in SetupStep.shown where !model.stepReadyForUse(step) {
                switch step {
                case .runner:
                    return SetupIssueHint(
                        message: AppLocalization.text(LocalizedStringResource("Amore can’t act yet: its helper isn’t installed.")),
                        link: AppLocalization.text(LocalizedStringResource("Install its helper ›")),
                        target: .step(.runner)
                    )
                case .developerMode:
                    return SetupIssueHint(
                        message: AppLocalization.text(LocalizedStringResource("Amore can’t act yet: Developer Mode is off.")),
                        link: AppLocalization.text(LocalizedStringResource("Turn On Developer Mode ›")),
                        target: .step(.developerMode)
                    )
                case .loopback:
                    return SetupIssueHint(
                        message: AppLocalization.text(LocalizedStringResource("Amore can’t connect yet: Local Connection is off.")),
                        link: AppLocalization.text(LocalizedStringResource("Turn On Local Connection ›")),
                        target: .step(.loopback)
                    )
                case .pairing:
                    return SetupIssueHint(
                        message: AppLocalization.text(LocalizedStringResource("Amore can’t act yet: this iPhone isn’t paired.")),
                        link: AppLocalization.text(LocalizedStringResource("Pair This iPhone ›")),
                        target: .step(.pairing)
                    )
                case .automation:
                    return SetupIssueHint(
                        message: AppLocalization.text(LocalizedStringResource("Amore can’t tap Send yet: UI Automation is off.")),
                        link: AppLocalization.text(LocalizedStringResource("Turn On UI Automation ›")),
                        target: .step(.automation)
                    )
                case .background:
                    return SetupIssueHint(
                        message: AppLocalization.text(LocalizedStringResource("Amore can’t stay on in the background yet.")),
                        link: AppLocalization.text(LocalizedStringResource("Turn On Background ›")),
                        target: .step(.background)
                    )
                }
            }
        }
        if !ModelKeys.hasUsableKey {
            return SetupIssueHint(
                message: AppLocalization.text(LocalizedStringResource("Amore needs a model account before it can reply.")),
                link: AppLocalization.text(LocalizedStringResource("Add an Account ›")),
                target: .model
            )
        }
        return nil
    }

    /// Poki's own session did not open on the mounted image (ESP-448).
    @MainActor static func localSessionIssue(model: AppModel) -> SetupIssueHint? {
        model.localSessionTrouble.map { SetupIssueHint(message: $0.text, link: AppLocalization.text(LocalizedStringResource("Open Setup ›")), target: .setup) }
    }
}

extension SetupIssueHint {
    /// The home page's line. In the last two days of signing it says Poki stops opening (main's home
    /// warning, ESP-222): after what keeps the current task from running, ahead of open setup steps.
    @MainActor static func homeLine(model: AppModel) -> SetupIssueHint? {
        if let now = runnerIssue(model: model) ?? localSessionIssue(model: model) { return now }
        if let warning = ExpiryWarning(expiry: model.signer.expiry) {
            return SetupIssueHint(message: AppLocalization.text(LocalizedStringResource("Amore’s signing ends soon")) + "\n" + warning.message,
                                  link: AppLocalization.text(LocalizedStringResource("Open Updates ›")), target: .updates)
        }
        return first(model: model) ?? relayIssue(model: model)
    }

    /// The conversations drawer's reminder row (ESP-321): what main's two tab dots said, one problem at
    /// a time, in the home line's order. A runner or pairing failure, then the last two days of signing,
    /// then an open setup step (Setup's dot), then no chat account, then the relay offline (the Agents
    /// dot). The chat doesn't show the relay: it needs no relay to reply.
    @MainActor static func home(model: AppModel) -> SetupIssueHint? {
        homeLine(model: model)
    }

    /// The relay is offline, so agents can't reach this iPhone (main's Agents dot and its "Relay
    /// offline" row). Not shown while the relay is off or connecting.
    @MainActor static func relayIssue(model: AppModel) -> SetupIssueHint? {
        guard model.relayStatus.isOffline else { return nil }
        return SetupIssueHint(
            message: AppLocalization.text(LocalizedStringResource("MCP Relay is offline: agents can’t reach this iPhone.")),
            link: AppLocalization.text(LocalizedStringResource("Agents ›")),
            target: .agents
        )
    }
}

/// One grey line and a blue direct link under the bubbles (ESP-174 board "C1 Chat setup hint").
struct SetupHintLine: View {
    var hint: SetupIssueHint
    var openSetupStep: (SetupStep) -> Void
    var openSetup: () -> Void
    var openModel: () -> Void
    var openAgents: () -> Void = {}
    var openUpdates: () -> Void = {}
    var sessionStore: SessionStore = .shared
    var shortcutStore: HomeShortcutStore = .shared

    var body: some View {
        VStack(spacing: 2) {
            Text(verbatim: hint.message)
                .font(.footnote)
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
            Button {
                switch hint.target {
                case .step(let step): openSetupStep(step)
                case .model: openModel()
                case .setup: openSetup()
                case .agents: openAgents()
                case .updates: openUpdates()
                }
            } label: {
                Text(verbatim: hint.link)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Tint.blueText)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.setupHintLink")
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }
}

/// The bubbles of one conversation: an in-app chat, a hand-off from an outside agent, or an outside
/// agent's own steps (grey lines). Used by the chat and by a saved session.
/// Brings a row that has just been written up from `distance` below its place: your first words,
/// rising out of the message field into their bubble (spring: response 0.45, damping 0.85, from
/// 40 ms). A row that was already there when the page opened just stands in its place.
private struct RiseIn: ViewModifier {
    var distance: CGFloat
    @State private var up: Bool

    init(distance: CGFloat?, born: Date) {
        self.distance = distance ?? 0
        _up = State(initialValue: distance == nil || Date().timeIntervalSince(born) > 1)
    }

    func body(content: Content) -> some View {
        content
            .opacity(up ? 1 : 0)
            .animation(HomeMotion.paced(.easeOut(duration: 0.12).delay(0.04)), value: up)
            .offset(y: up ? 0 : distance)
            .animation(HomeMotion.paced(.spring(response: 0.45, dampingFraction: 0.85).delay(0.04)), value: up)
            .onAppear { up = true }
    }
}

struct ChatTranscript<Footer: View>: View {
    var entries: [ChatEntry]
    var typing = false
    var canRetry = false
    var retry: () -> Void = {}
    /// The run these entries belong to, for the details of its steps (the Activity Log's session).
    var session: String? = nil
    /// The conversation's task is under way: its last plan is the live task card.
    var live = false
    /// A step of it waits for your answer, or the phone is handed back to you.
    var waiting = false
    var handedOver = false
    /// The live task's whole plan, when the model published it, and the app it is in.
    var plan: [String]? = nil
    var app: String? = nil
    /// What the core last saw of the screen, for the live task's card.
    var shot: Image? = nil
    /// The task's name and who asked, for a task no message in this conversation asked for (an outside
    /// agent's own steps).
    var taskTitle: String? = nil
    var taskAsker: String? = nil
    /// How far your first words rise out of the message field when they open the conversation
    /// (the chat only); nil where a first message just appears.
    var rise: CGFloat? = nil
    @ViewBuilder var footer: () -> Footer

    /// Your first message is all there is: its bubble rises from the message field, and Poki's dots
    /// wait until the page has changed (600 ms, ESP-376).
    private var opening: Bool { rise != nil && entries.count <= 2 }

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var follow = ChatFollow.newest

    /// Your newest message: when it changes you have just sent one.
    private var lastSent: UUID? {
        entries.last { if case .you = $0.kind { true } else { false } }?.id
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                Spacer(minLength: 0)
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                    row(entry, at: i).id(entry.id)
                }
                if typing {
                    HStack { TypingBubble(); Spacer(minLength: .messageInsetPadding) }
                        .padding(.top, 10)
                        .transition(opening ? .opacity.animation(HomeMotion.paced(.easeOut(duration: 0.15).delay(0.56)))
                                            : .opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
                }
                if canRetry {
                    Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).tint(Color(.label))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4).padding(.bottom, 6)
                }
                footer()
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .animation(PlanMotion.enter, value: entries)
            .animation(.easeOut(duration: 0.2), value: typing)
        }
        // Opens at the newest message; a short chat starts under the top bar, as the boards draw it
        // (ESP-376). A frame fixed to the screen's height here cut off everything above it.
        .scrollPosition($position)
        // No vertical scroll bar: dragging the drawer open and back moves the whole chat, and the bar
        // the drag's vertical part showed could stay on the screen as a grey line over the messages.
        // The newest button below brings you back down.
        .scrollIndicators(.hidden, axes: .vertical)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.top, for: .alignment)
        // At the newest message, every reply, step, card and keyboard keeps it in view; read back and
        // nothing moves under you (ESP-468). The bottom anchor alone did neither: a new conversation,
        // still shorter than the screen, stayed at its top while the keyboard and the approval card
        // covered its task card, and a reader further up was dragged down by every reply.
        .defaultScrollAnchor(follow == .reading ? nil : .bottom, for: .sizeChanges)
        .onScrollGeometryChange(for: ChatFollow.Frame.self, of: ChatFollow.Frame.init) { old, new in
            let next = follow.after(old, new)
            follow = next.follow
            if next.scroll { position.scrollTo(edge: .bottom) }
        }
        // Your finger stops the chat on its way down to the newest: from there on you are reading.
        .onScrollPhaseChange { _, phase, context in
            if phase == .interacting, follow == .reaching, !ChatFollow.Frame(context.geometry).atEnd { follow = .reading }
        }
        .onChange(of: lastSent) { _, sent in
            if sent != nil { toNewest(animated: false) }
        }
        // Under the bars the system's soft scroll edge takes the messages (`softTopEdge`). No mask of
        // our own here: one made the messages vanish in a short straight ramp above the bar, which
        // read as a hard edge, and left the system's effect nothing to blur.
        .overlay(alignment: .bottom) {
            if follow == .reading {
                NewestButton { toNewest(animated: true) }
                    .padding(.bottom, 10)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: follow)
        .scrollDismissesKeyboard(.interactively)
    }

    private func toNewest(animated: Bool) {
        follow = .reaching
        if animated {
            withAnimation(.snappy(duration: 0.35)) { position.scrollTo(edge: .bottom) }
        } else {
            position.scrollTo(edge: .bottom)
        }
    }

    @ViewBuilder private func row(_ entry: ChatEntry, at i: Int) -> some View {
        switch entry.kind {
        case .time(let date):
            Text(ChatTime.header(date))
                .font(.caption).foregroundStyle(Color(.secondaryLabel))
                .padding(.bottom, 6).frame(maxWidth: .infinity)
        case .you(let text, let delivered):
            let last = isLast(i, poki: false)
            VStack(alignment: .trailing, spacing: 4) {
                if let pictures = entry.attachments {
                    HStack(spacing: 6) {
                        ForEach(Array(pictures.enumerated()), id: \.offset) { _, data in AttachmentThumb(data: data, side: 96) }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("^[\(pictures.count) attachment](inflect: true)"))
                }
                if let documents = entry.textDocuments {
                    ForEach(Array(documents.enumerated()), id: \.offset) { _, document in
                        ChatTextDocumentChip(document: document)
                    }
                }
                if !text.isEmpty { MessageBubble(direction: .outgoing, text: text, tail: last) }
                if last, delivered {
                    Text("Delivered").font(.caption2.weight(.medium)).foregroundStyle(Color(.secondaryLabel))
                        .padding(.horizontal, 4).padding(.bottom, 8)
                        .transition(.opacity)
                }
            }
            .padding(.top, startsRun(i) ? 10 : 0)
            // Your first words rise out of the message field on their own spring. Not as a transition:
            // the list's spring for new rows took a transition over and threw the bubble 40 points
            // past its place.
            .modifier(RiseIn(distance: i <= 1 ? rise : nil, born: entry.at))
            .transition(rise != nil && i <= 1 ? .identity : .move(edge: .bottom).combined(with: .opacity))
        case .request(let text, let from):
            // A guest's request: who asked and how above it, and the ink bubble that sets it apart from
            // your grey one. Every request comes through ask_poki, an MCP tool.
            VStack(alignment: .trailing, spacing: 5) {
                if startsRun(i) || i == 0 {
                    Text("\(from) asked over MCP").font(.caption2.weight(.medium)).foregroundStyle(Color(.secondaryLabel)).padding(.trailing, 4)
                }
                MessageBubble(direction: .guest, text: text, tail: isLast(i, poki: false))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, startsRun(i) ? 10 : 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .poki(let text):
            MessageBubble(direction: .incoming, text: text, tail: isLast(i, poki: true))
                .padding(.top, startsRun(i) ? 10 : 0)
                .transition(PlanMotion.stepTransition)
        case .plan(let steps):
            let ask = asking(at: i)
            let current = live && isLastPlan(i)
            TaskCard(title: entry.title ?? ask.title, steps: steps,
                     state: TaskCardState(steps: steps, live: current, waiting: waiting, handedOver: handedOver),
                     upcoming: current ? Array((plan ?? []).dropFirst(steps.count)) : [],
                     planned: !current || plan != nil,
                     asker: ask.from, app: current ? app : entry.app, usedBrowser: ChatEntry.taskUsedBrowser(in: entries, at: i), started: entry.at, shot: current ? shot : nil,
                     ended: current ? nil : entry.ended, plannedTotal: entry.total)
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 26, style: .continuous))

                .padding(.vertical, 6)
                .transition(PlanMotion.stepTransition)
        case .note(.approval(let approval)):
            HStack {
                ApprovalNoteCard(note: approval)
                    .contentShape(.contextMenuPreview, .rect(cornerRadius: 16, style: .continuous))

                Spacer(minLength: .messageInsetPadding)
            }
            .padding(.vertical, 4)
            .transition(PlanMotion.stepTransition)
        case .note(.problem(let text)):
            // Trouble is something Poki says, in its own bubble (board 05), not a grey status line.
            MessageBubble(direction: .incoming, text: text, tail: true)
                .padding(.top, 6)
                .transition(PlanMotion.stepTransition)
        case .note(let note):
            NoteLine(note: note)
        case .step(let text, let ok):
            StepLine(text: text, ok: ok)
        case .browser(let visit):
            BrowserCard(id: entry.id, visit: visit)
                .padding(.top, 6)
                .transition(PlanMotion.stepTransition)
        }
    }

    /// What was asked for the task entry `i` belongs to, and by which outside agent (nil when you asked).
    private func asking(at i: Int) -> (title: String, from: String?) {
        for entry in entries[...i].reversed() {
            switch entry.kind {
            case .you(let text, _): return (text, nil)
            case .request(let text, let from): return (text, from)
            default: continue
            }
        }
        return (taskTitle ?? AppLocalization.text(LocalizedStringResource("Task")), taskAsker)
    }

    /// No plan follows entry `i`: it is the task under way, if one is.
    private func isLastPlan(_ i: Int) -> Bool {
        !entries[(i + 1)...].contains { if case .plan = $0.kind { true } else { false } }
    }

    /// The last bubble from that side in the conversation has the small corner (the boards).
    private func isLast(_ i: Int, poki: Bool) -> Bool {
        !entries[(i + 1)...].contains { entry in
            switch entry.kind {
            case .poki, .plan: poki
            case .you, .request: !poki
            default: false
            }
        }
    }

    /// A bubble after the other side's (or the time) leaves 10 pt more.
    private func startsRun(_ i: Int) -> Bool {
        guard i > 0 else { return false }
        let mine = entries[i].isPoki
        for entry in entries[..<i].reversed() {
            switch entry.kind {
            case .note: continue
            case .time, .step: return true
            default: return entry.isPoki != mine
            }
        }
        return false
    }
}

/// Whether the conversation keeps its newest message in view, is on its way down to it, or you are
/// reading further up.
enum ChatFollow: Equatable {
    case newest, reaching, reading

    /// What of the scroll view's geometry decides it. The container is the part between the top bar
    /// and the message field (with the keyboard and any card over it); the insets are those bars.
    struct Frame: Equatable {
        var offset: CGFloat
        var top: CGFloat
        var content: CGFloat
        var visible: CGFloat

        init(_ geometry: ScrollGeometry) {
            offset = geometry.contentOffset.y
            top = geometry.contentInsets.top
            content = geometry.contentSize.height
            visible = geometry.containerSize.height
        }

        /// The end of the conversation is within a few points of the message field.
        var atEnd: Bool { offset + top + visible >= content - 24 }
    }

    /// After the geometry changed. What grew or shrank (a reply, a card, the keyboard) brings the newest
    /// back into view unless you are reading; a scroll that leaves the end is yours, unless the chat
    /// itself is on its way down.
    func after(_ old: Frame, _ new: Frame) -> (follow: ChatFollow, scroll: Bool) {
        if new.atEnd { return (.newest, false) }
        let resized = old.content != new.content || old.visible != new.visible
        switch self {
        case .reading: return (.reading, false)
        case .reaching: return (.reaching, resized)
        case .newest: return resized ? (.reaching, true) : (.reading, false)
        }
    }
}

/// Back to the newest message, over the bottom of a conversation you have scrolled up in.
private struct NewestButton: View {
    var action: () -> Void
    var controlSize = CompactControlMetrics(base: 44, maximum: 52)

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(Color(.label))
                .frame(width: controlSize.side, height: controlSize.side)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassSurface(in: Circle(), interactive: true)
        .accessibilityLabel(Text("Newest Messages", tableName: "Chat"))
        .accessibilityIdentifier("chat.latest")
        .accessibilityShowsLargeContentViewer {
            Label { Text("Newest Messages", tableName: "Chat") } icon: { Image(systemName: "arrow.down") }
        }
    }
}

extension ChatTranscript where Footer == EmptyView {
    init(entries: [ChatEntry]) { self.init(entries: entries, footer: { EmptyView() }) }
}

/// "Today 9:41 AM", "Yesterday 6:02 PM", "Monday 8:15 AM", "Oct 3, 8:15 AM", as Messages writes them.
enum ChatTime {
    static func header(_ date: Date) -> AttributedString {
        let calendar = Calendar.current
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocalization.locale))
        let day: String
        if calendar.isDateInToday(date) { day = AppLocalization.text(LocalizedStringResource("Today")) }
        else if calendar.isDateInYesterday(date) { day = AppLocalization.text(LocalizedStringResource("Yesterday")) }
        else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day, days < 7 {
            day = date.formatted(.dateTime.weekday(.wide).locale(AppLocalization.locale))
        } else {
            day = date.formatted(.dateTime.month(.abbreviated).day().locale(AppLocalization.locale))
        }
        var bold = AttributedString(day)
        bold.font = .caption.weight(.semibold)
        return bold + AttributedString(" \(time)")
    }

    /// The Sessions list's right-hand time: "9:41 AM", "Yesterday", "Monday", "10/3/26".
    static func row(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocalization.locale)) }
        if calendar.isDateInYesterday(date) { return AppLocalization.text(LocalizedStringResource("Yesterday")) }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide).locale(AppLocalization.locale))
        }
        return date.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(AppLocalization.locale))
    }
}

/// Three dots that rise in turn: the model is working on its answer.
struct TypingBubble: View {
    @Environment(\.coveredByDrawer) private var covered
    /// Dot i's height in 0...1 at time t. Typed step by step: as one expression inside the view
    /// builder it can exceed the type checker's time limit on a busy CI runner.
    static func phase(_ t: Double, _ i: Int) -> Double {
        let angle: Double = t * 2 * Double.pi / 1.2 - Double(i) * 0.9
        let wave: Double = sin(angle)
        return (wave + 1) / 2
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: covered)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    let phase = TypingBubble.phase(t, i)
                    Circle().fill(ChatColor.secondary.opacity(0.4 + 0.5 * phase)).frame(width: 8, height: 8).offset(y: -3 * phase)
                }
            }
            .padding(.vertical, 19).padding(.horizontal, 20)
        }
        .pokiBubble(tail: true)
        .accessibilityLabel(Text("Amore is typing"))
    }
}

/// The mark in front of a status line. Steps, approvals and the plan all draw the same tick and cross.
enum StatusGlyph: Equatable {
    case ok, failed, working, warning, island, none

    @ViewBuilder var view: some View {
        switch self {
        case .ok: Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(Tint.green)
        case .failed: Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(Tint.red)
        case .working: ProgressView().controlSize(.mini)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Tint.amber)
        // The Dynamic Island, small.
        case .island: Capsule().fill(Color(hex: 0x1C1C1E)).frame(width: 22, height: 8)
        case .none: EmptyView()
        }
    }
}

/// One status line of the conversation: a mark and grey words that wrap, on the bubbles' leading edge.
/// A notice (an approval or a problem) sits on a grey card; a step is bare, so a run of them reads as a list.
struct StatusLine: View {
    var glyph: StatusGlyph
    var text: String
    var card = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                if glyph != .none { glyph.view.frame(minWidth: 14) }
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote).foregroundStyle(Color(.secondaryLabel))
            .multilineTextAlignment(.leading)
            .padding(.vertical, card ? 8 : 2).padding(.horizontal, card ? 12 : 2)
            .background { if card { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)) } }
            Spacer(minLength: card ? .messageInsetPadding : 16)
        }
        .padding(.vertical, card ? 4 : 0)
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
}

/// An outside agent's own step: one grey line, ticked when it went through.
private struct StepLine: View {
    var text: String
    var ok: Bool?
    var body: some View {
        StatusLine(glyph: ok == true ? .ok : ok == false ? .failed : .working, text: ActivityWords.label(text))
    }
}

// MARK: Header

// MessageListHeader is from GetStream/swiftui-iMessage-clone (commit df114b4,
// iMessageClone/MessageList/View/Header/MessageListHeader.swift, by Stefan Blos; the repository has no
// licence file). Changed: Poki's picture at the board's 56 pt instead of 20, the 12 pt name with its
// chevron, no video button, and a view of its own instead of a toolbar item.
struct MessageListHeader: View {
    var backSize = CompactControlMetrics(base: 44, maximum: 52)
    var dark: Bool
    /// The model answering, under the name (the chat); nil on the voice page.
    var subtitle: String? = nil
    var title: String = "Poki"
    var back: (() -> Void)? = nil
    var openDetails: () -> Void

    var body: some View {
        Button(action: openDetails) {
            VStack(spacing: 4) {
                PokiAvatar(size: 56)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: title)
                        .font(.system(size: 12))
                        .foregroundStyle(dark ? Color.white : Color(.label))
                    Image(systemName: "chevron.right")
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.semibold)
                        .frame(width: 5, height: 8)
                        .foregroundStyle(dark ? Color.white.opacity(0.7) : ChatColor.secondary)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle).font(.system(size: 11)).foregroundStyle(ChatColor.secondary).lineLimit(1)
                }
            }
            .padding(.top, 2).padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title), details"))
        .accessibilityIdentifier("chat.header.details")
        .overlay(alignment: .topLeading) {
            if let back, UserDefaults.standard.string(forKey: "pokiChat") == nil, UserDefaults.standard.string(forKey: "pokiVoiceSample") == nil {
                Button(action: back) {
                    Image(systemName: "chevron.backward")
                        .font(.title3.weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(dark ? .white : Site.blue)
                        .frame(width: backSize.side, height: backSize.side).contentShape(.rect)
                }
                .buttonStyle(.plain).padding(.leading, 6)
                .accessibilityLabel(Text("Sessions"))
                .accessibilityShowsLargeContentViewer {
                    Label("Sessions", systemImage: "chevron.backward")
                }
            }
        }
        .background {
            if !dark {
                Rectangle().fill(.bar).ignoresSafeArea(edges: .top)
                    .overlay(alignment: .bottom) { Color(hex: 0xC6C6C8).opacity(0.75).frame(height: 0.75) }
            }
        }
    }
}

// MARK: Notes

/// A notice about an approval or a problem, on a grey card under the steps.
private struct NoteLine: View {
    var note: ChatNote
    var body: some View {
        StatusLine(glyph: glyph, text: text, card: true)
    }

    private var glyph: StatusGlyph {
        switch note {
        case .waiting: .island
        case .approved, .modelApproved: .ok
        case .approval(let note): note.state == .allowed ? StatusGlyph.ok : note.state == .asking ? StatusGlyph.working : StatusGlyph.failed
        case .declined, .modelDeclined: .failed
        case .expired, .problem: .warning
        case .modelChecking: .working
        }
    }

    private var text: String {
        switch note {
        case .waiting: AppLocalization.text(LocalizedStringResource("Waiting for your approval"))
        case .approved(let at): AppLocalization.text(LocalizedStringResource("Approved, \(at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocalization.locale)))"))
        case .declined: AppLocalization.text(LocalizedStringResource("Not approved, so Poki skipped that step"))
        case .expired: AppLocalization.text(LocalizedStringResource("The approval ran out, so Poki skipped that step"))
        case .problem(let text): text
        case .approval(let note): ActivityWords.label(note.summary)
        case .modelChecking: AppLocalization.text(LocalizedStringResource("The model is checking this step"))
        case .modelApproved(let why): why.isEmpty ? AppLocalization.text(LocalizedStringResource("Approved by model")) : AppLocalization.text(LocalizedStringResource("Approved by model, \(why)"))
        case .modelDeclined(let why):
            why.isEmpty ? AppLocalization.text(LocalizedStringResource("Not approved by model. Say yes in the chat to allow it."))
                : AppLocalization.text(LocalizedStringResource("Not approved by model, \(why). Say yes in the chat to allow it."))
        }
    }
}

/// An approval in the conversation: what was asked, why it needed an answer, and who answered what.
struct ApprovalNoteCard: View {
    var note: ApprovalNote

    private var title: String {
        switch (note.state, note.byModel) {
        case (.asking, true): AppLocalization.text(LocalizedStringResource("Checking This Step"))
        case (.asking, false): AppLocalization.text(LocalizedStringResource("Waiting for Your Approval"))
        case (.allowed, true): AppLocalization.text(LocalizedStringResource("Approved Automatically"))
        case (.allowed, false): AppLocalization.text(LocalizedStringResource("You Approved"))
        case (.refused, true): AppLocalization.text(LocalizedStringResource("Not Approved"))
        case (.refused, false): AppLocalization.text(LocalizedStringResource("You Did Not Approve"))
        case (.expired, _): AppLocalization.text(LocalizedStringResource("Approval Ran Out"))
        }
    }

    private var symbol: String {
        switch note.state {
        case .asking: "shield.lefthalf.filled"
        case .allowed: "checkmark.shield.fill"
        case .refused: "xmark.shield.fill"
        case .expired: "exclamationmark.shield.fill"
        }
    }

    private var tint: Color {
        switch note.state {
        case .asking: note.byModel ? Tint.blueText : Tint.amberInk
        case .allowed: Tint.greenInk
        case .refused: Tint.redInk
        case .expired: Tint.amberInk
        }
    }

    /// "Messages · sending a message": the app and PokiCore's reason, without its quoted word.
    private var context: String {
        let why = ActivityWords.reason(note.why)
        let app = note.app.contains("(") ? nil : AppName.display(note.app)
        return [app, why.isEmpty ? nil : why].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Text(verbatim: title).font(.footnote.weight(.semibold)).foregroundStyle(tint)
                Spacer(minLength: 4)
                if note.state == .asking, note.byModel {
                    ProgressView().controlSize(.mini)
                } else if let at = note.answered {
                    Text(at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocalization.locale))).font(.caption2).foregroundStyle(Color(.secondaryLabel))
                }
            }
            Text(verbatim: ActivityWords.label(note.summary)).font(.subheadline).foregroundStyle(Color(.label))
                .fixedSize(horizontal: false, vertical: true)
            if !context.isEmpty {
                Text(verbatim: context).font(.caption).foregroundStyle(Color(.secondaryLabel))
            }
            if !note.reason.isEmpty {
                Text(verbatim: AppLocalization.bundle.localizedString(forKey: note.reason, value: note.reason, table: nil)).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if note.state == .refused, note.reply {
                Text("Say yes in the chat to allow it.").font(.caption).foregroundStyle(Color(.secondaryLabel))
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Chat and Voice

enum RootPage: Hashable { case chat, voice }

/// CHAT and VOICE under the page, like Photo and Video in Camera: the page's own word sits in the middle.
struct ModeLabels: View {
    var page: RootPage
    var dark: Bool
    var select: ((RootPage) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                label("CHAT", .chat)
                label("VOICE", .voice)
            }
            // The board's 66 and 62 pt: the page's word in the middle.
            .padding(.leading, page == .chat ? 66 : 0).padding(.trailing, page == .voice ? 62 : 0)
            .padding(.top, 6).padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func label(_ title: LocalizedStringKey, _ target: RootPage) -> some View {
        Button { select?(target) } label: {
            Text(title).font(.system(size: 13, weight: .semibold)).tracking(13 * 0.06)
                .foregroundStyle(color(target))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(page == target ? .isSelected : [])
    }

    private func color(_ target: RootPage) -> Color {
        if dark { return page == target ? .white : .white.opacity(0.55) }
        return page == target ? Site.blue : ChatColor.secondary
    }
}

// MARK: Composer

// ComposerInputView started from GetStream/swiftui-iMessage-clone (commit df114b4,
// iMessageClone/MessageList/View/Composer/ComposerInputView.swift, by Stefan Blos; no licence file in
// the repository), with the plus button in front from exyte/Chat (commit f382a14,
// Sources/ExyteChat/Views/InputView/InputView.swift, Copyright (c) 2019 exyte, MIT License). Now one
// row on one sheet of glass: the plus menu, the
// message, the microphone when Settings › Voice shows it, and one button that talks, sends or stops;
// the photos and PDFs picked for the message stand over it.
struct ComposerInputView: View {
    @Environment(AppModel.self) private var model
    /// The message being written; the greeting's suggestions fill it.
    @Binding var input: String
    /// The message field has the keyboard; the home page's suggestions set it.
    @Binding var focused: Bool
    var running: Bool
    /// How far the running task is, 0 to 1, for the ring around Stop; nil when unknown.
    var progress: Double? = nil
    /// Goes up with each tap on New Conversation on the home page: a message under way (words or
    /// pictures) is cleared and the keyboard goes down, as the page first was; an empty field takes
    /// the keyboard.
    var restarts = 0
    var send: (String, [ChatAttachment]) -> Void
    var stop: () -> Void
    /// Starts the live voice conversation.
    var openVoice: () -> Void
    /// Settings, where the OpenAI key that Talk with Amore needs is added (or Live Voice turned on).
    var openVoiceKey: () -> Void = {}
    /// Leave conversation context above a long voice notice; its content remains scrollable.
    var noticeHeight: CGFloat = 360
    @State private var voiceContentHeight: CGFloat = 0
    @State private var dictation = FieldDictation()
    /// Talk with Poki was asked for with no voice key: the field says so, in its own place.
    @State private var needsKey = false
    /// When the talk on now began, for its time in the field.
    @State private var talkStarted: Date?
    @State private var sent: (text: String, at: Date)?
    @State private var sends = 0
    /// Settings › Voice: the microphone for dictation beside the main button. On unless you turn it off.
    @AppStorage(FieldDictation.buttonKey) private var dictationButton = FieldDictation.buttonShown
    /// Photos and PDFs for the next message, and the three ways to add them.
    @State private var attachments: [ChatAttachment] = []
    @State private var choosingPhotos = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @State private var choosingFiles = false
    /// A file Poki can't read, said for a moment over the message field.
    @State private var problem: String?
    @State private var fieldScroll = CapsuleScroll()
    /// A swipe down that started on a message scrolled away from its first line: it scrolls the message.
    @State private var swipeScrolls: Bool?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var scaledButtonDiameter = 44.0
    @ScaledMetric(relativeTo: .body) private var scaledControlInset = 6.0
    @ScaledMetric(relativeTo: .body) private var scaledControlSpacing = 8.0
    @ScaledMetric(relativeTo: .body) private var fieldHeight = 112.0

    private var buttonDiameter: CGFloat { min(56, max(36, scaledButtonDiameter)) }
    private var buttonHitSide: CGFloat { max(44, buttonDiameter) }
    private var controlInset: CGFloat { min(8, max(4, scaledControlInset)) }
    private var controlSpacing: CGFloat { min(12, max(6, scaledControlSpacing)) }
    private var cornerRadius: CGFloat {
        let radius = (buttonHitSide + 2 * controlInset) / 2
        return expanded ? min(24, radius) : radius
    }
    private var expanded: Bool { typeSize >= .xxxLarge }

    private var voice: VoiceModel { model.voice }
    private var hasText: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Something to send: words, or pictures on their own.
    private var canSend: Bool { hasText || !attachments.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = problem ?? (dictation.on ? nil : dictation.problem) {
                Text(problem).font(.footnote).foregroundStyle(Tint.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                    .transition(.opacity)
            }
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments) { item in
                    withAnimation(.snappy) { attachments.removeAll { $0.id == item.id } }
                }
            }
            // One row on one glass sheet (ESP-376): plus, the message, and the one button that talks,
            // sends or stops. The buttons inside are plain fills: no glass on glass.
            Group {
                if voice.talkState != nil || needsKey {
                    ScrollView {
                        Group {
                            if let talk = voice.talkState {
                                TalkBar(state: talk, since: talkStarted, muted: voice.muted, toggleMute: { voice.muted.toggle() },
                                        interrupt: voice.stopTalking, end: voice.stop,
                                        retry: { voice.dismissProblem(); openVoice() }, dismiss: voice.dismissProblem)
                            } else {
                                VoiceKeyNotice(addKey: { needsKey = false; openVoiceKey() }, close: { needsKey = false })
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { voiceContentHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(voiceContentHeight, noticeHeight))
                    .transition(.blurReplace)
                } else {
                    ComposerLayout(expansion: expanded ? 1 : 0, spacing: controlSpacing) {
                        plus
                        // An app's name in the message shows as its capsule (ESP-377); the text itself stays plain.
                        CapsuleField(text: $input, focused: $focused, maxLines: 6, maxHeight: min(200, fieldHeight), scroll: fieldScroll,
                                     onSwipe: { up in if up { focused = true } else if focused { focused = false } }, onSubmit: submit)
                            .overlay(alignment: .topLeading) {
                                if input.isEmpty {
                                    Text(dictation.on ? "Listening…" : attachments.isEmpty ? "Message Poki" : "Add a message")
                                        .foregroundStyle(Tint.homePlaceholder).lineLimit(1)
                                        .padding(.top, 6).allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                            .padding(.horizontal, expanded ? 8 : 0)
                            .accessibilitySortPriority(1)
                        HStack(spacing: 4) {
                            if dictation.on { dictating } else if dictationButton, !running { microphone }
                            mainButton
                        }
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                    .simultaneousGesture(swipe)
                    .transition(.blurReplace)
                }
            }
            .padding(controlInset)
            .contentShape(.rect)
            .onTapGesture { if voice.talkState == nil, !needsKey { focused = true } }
            .glassSurface(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), fallback: .bar)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: expanded)
        }
        .animation(.snappy, value: dictation.on)
        .animation(TalkMotion.enter, value: voice.talkState != nil)
        .animation(TalkMotion.enter, value: needsKey)
        .onChange(of: voice.isOn, initial: true) { _, on in talkStarted = on ? Date() : nil }
        // Talk with Poki with no voice key, from the field's button, a link or Poki's profile: what it is
        // missing. The keyboard goes down: the field it belongs to is not on screen.
        .onChange(of: voice.keyAsked, initial: true) { _, asked in
            guard asked else { return }
            voice.keyAsked = false
            focused = false
            needsKey = true
        }
        // The talk's bar stands where the field was: the keyboard goes down with the field.
        .onChange(of: voice.talkState != nil) { _, talking in if talking { focused = false; needsKey = false } }
        // A suggestion picked or a task starting puts the key's message away.
        .onChange(of: input) { _, text in if !text.isEmpty, !dictation.on { needsKey = false } }
        // The keyboard asked for (a suggestion, New Conversation) while the talk's bar stands in the
        // field's place has no field to go to; over the key's message it brings the field back.
        .onChange(of: focused) { _, now in
            guard now else { return }
            if voice.talkState != nil { focused = false } else { needsKey = false }
        }
        .onChange(of: running) { _, now in if now { needsKey = false } }
        .animation(.snappy, value: running)
        .animation(.snappy, value: attachments)
        .animation(.snappy, value: problem)
        .onChange(of: dictation.text) { _, text in if dictation.on { input = dictation.base + text } }
        // A keyboard that was still composing (autocorrect, Pinyin) can commit its text after Send has
        // emptied the field, which put the sent message back: for a moment after Send, that is undone.
        .onChange(of: input) { _, text in
            if let sent, text == sent.text, Date().timeIntervalSince(sent.at) < 1 { input = "" }
        }
        .onDisappear { dictation.stop(model) }
        .sensoryFeedback(.impact(weight: .light), trigger: sends)
        .task(id: problem) {
            guard problem != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { problem = nil }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $picked, maxSelectionCount: Self.most - attachments.count, matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await addPhotos(items) }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: AttachmentReader.fileTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { add { try AttachmentReader.file(url) } }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                takingPhoto = false
                if let image { add { try AttachmentReader.photo(image) } }
            }
            .ignoresSafeArea()
        }
        .onChange(of: restarts) {
            if !input.isEmpty || !attachments.isEmpty {
                input = ""
                withAnimation(.snappy) { attachments = [] }
                focused = false
            } else {
                focused = true
            }
        }
        #if DEBUG && targetEnvironment(simulator)
        .onAppear { if let item = TestAttachment.take() { attachments.append(item) } }
        // Screenshots of talking, from a simulator's development build: `-pokiTalk needs-key` (Talk with
        // Poki without a key), `add-key` (where its Add Key leads), `talk` (a talk under way; with
        // `-pokiTalkRehearsal 1` it runs TalkRehearsal's turn) and `ended` (that talk, ended by End).
        .task {
            guard let shot = UserDefaults.standard.string(forKey: "pokiTalk") else { return }
            try? await Task.sleep(for: .seconds(1))
            switch shot {
            case "needs-key": needsKey = true
            case "add-key": openVoiceKey()
            case "talk":
                openVoice()
                // `-pokiTalkHold <state>`: once the rehearsal has brought the talk there, it stays.
                guard let hold = TalkRehearsal.hold else { break }
                for _ in 0..<600 where voice.talkState != hold { try? await Task.sleep(for: .milliseconds(50)) }
                voice.staged = hold
                // The screenshot script waits for this line.
                FileHandle.standardError.write(Data("POKI-TALK held\n".utf8))
            case "ended":
                openVoice()
                try? await Task.sleep(for: .seconds(9))
                voice.stop()
            default: break
            }
        }
        #endif
    }

    /// A swipe up on the message field brings the keyboard, a swipe down puts it away on the home
    /// page and in the chat. Only a mostly upright drag of some length counts,
    /// so a tap on plus or Send stays a tap and a sideways drag does nothing. It lives on the field
    /// alone, so the conversation above scrolls as before; a swipe down on a long message scrolled
    /// away from its first line scrolls it back instead.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { _ in if swipeScrolls == nil { swipeScrolls = fieldScroll.scrolledDown } }
            .onEnded { drag in
                let scrolled = swipeScrolls ?? false
                swipeScrolls = nil
                let (dx, dy) = (drag.translation.width, drag.predictedEndTranslation.height)
                guard abs(drag.translation.height) > abs(dx) * 1.5 else { return }
                if dy < -36, !focused { focused = true }
                if dy > 36, focused, !scrolled { focused = false }
            }
    }

    /// While dictation listens: the way to stop it. The words appear in the field; nothing is sent
    /// until you tap Send.
    private var dictating: some View {
        Button { dictation.stop(model) } label: {
            Image(systemName: "mic.fill")
                .font(.body.weight(.medium)).foregroundStyle(Tint.red)
                .symbolEffect(.pulse, isActive: true)
                .frame(width: buttonHitSide, height: buttonHitSide).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Stop Dictation"))
        .accessibilityShowsLargeContentViewer {
            Label("Stop Dictation", systemImage: "mic.fill")
        }
    }

    /// Settings › Voice turned it on: dictation into the field. The words appear in the field; nothing
    /// is sent until you tap Send.
    private var microphone: some View {
        Button { dictation.start(model, after: input) } label: {
            Image(systemName: "mic")
                .font(.body.weight(.medium)).foregroundStyle(Color(.label))
                .frame(width: buttonHitSide, height: buttonHitSide).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(voice.isOn)
        .accessibilityLabel(Text("Dictate"))
        .accessibilityIdentifier("composer.dictate")
        .accessibilityShowsLargeContentViewer {
            Label("Dictate", systemImage: "mic")
        }
    }

    // MARK: The plus menu

    /// At most this many photos and PDFs go with one message.
    private static let most = 6

    /// Plus: what you add to the message you are writing (board 定稿 04), photos from the library, a
    /// photo from the camera, or a picture or PDF from Files. Everything else is on Poki's card at the
    /// top and in Settings.
    private var plus: some View {
        Menu {
            Button("Photos", systemImage: "photo") { choosingPhotos = true }
                .accessibilityIdentifier("composer.photos")
            Button("Take Photo", systemImage: "camera") { takingPhoto = true }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                .accessibilityIdentifier("composer.camera")
            Button("Files", systemImage: "folder") { choosingFiles = true }
                .accessibilityIdentifier("composer.files")
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.medium)).dynamicTypeSize(...DynamicTypeSize.xxxLarge).foregroundStyle(Color(.label))
                .frame(width: buttonDiameter, height: buttonDiameter)
                .background(Color(.label).opacity(scheme == .dark ? 0.16 : 0.12), in: .circle)
                .frame(width: buttonHitSide, height: buttonHitSide)
                .contentShape(.interaction, Rectangle())
        }
        // Photos first, as on the board, though the menu opens upward from the button.
        .menuOrder(.fixed)
        .disabled(attachments.count >= Self.most)
        .accessibilityLabel(Text("Add Photos or Files"))
        .accessibilityIdentifier("composer.plus")
        .accessibilityShowsLargeContentViewer {
            Label("Add Photos or Files", systemImage: "plus")
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                problem = AppLocalization.text(LocalizedStringResource("Couldn’t read this file."))
                continue
            }
            add { try AttachmentReader.photo(data) }
        }
    }

    /// One more photo or PDF, up to the limit; a file Poki can't read says so.
    private func add(_ read: () throws -> ChatAttachment) {
        guard attachments.count < Self.most else { return }
        do {
            let item = try read()
            withAnimation(.snappy) { attachments.append(item) }
        } catch AttachmentReader.Failure.tooLarge {
            problem = AppLocalization.text(LocalizedStringResource("Text files must be 100 KB or smaller."))
        } catch AttachmentReader.Failure.invalidUTF8 {
            problem = AppLocalization.text(LocalizedStringResource("This text file must use UTF-8 encoding."))
        } catch AttachmentReader.Failure.unsupported {
            problem = AppLocalization.text(LocalizedStringResource("Only images, PDFs, JSON, Markdown, and plain text files can be added."))
        } catch {
            problem = AppLocalization.text(LocalizedStringResource("Couldn’t read this file."))
        }
    }

    /// One button: talk when the field is empty, send when it has words, stop while a task runs. Poki's
    /// blue while it is yours to press for Poki; ink while it stops a task, with the task's progress
    /// as a ring around it.
    private var mainButton: some View {
        Button {
            // On an empty field: Talk with Poki at once. Dictation has its own
            // button beside this one. Without a voice key `openVoice` has the field say so.
            if running { stop() } else if canSend { submit() } else { dictation.stop(model); openVoice() }
        } label: {
            Image(systemName: running ? "stop.fill" : canSend ? "arrow.up" : "waveform")
                .font(.body.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(running ? Tint.onSolid : .white)
                .frame(width: buttonDiameter, height: buttonDiameter)
                .background(running ? Tint.solid : Tint.blue, in: .circle)
                .overlay {
                    if running {
                        // How far the task is; a short arc from the start, so it reads as a ring.
                        Circle().trim(from: 0, to: max(0.06, min(progress ?? 0.06, 1)))
                            .stroke(Tint.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(1.5)
                            .animation(.easeInOut(duration: 0.4), value: progress)
                    }
                }
                .frame(width: buttonHitSide, height: buttonHitSide)
                .contentShape(.interaction, Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(running ? "Stop" : canSend ? "Send" : "Talk with Poki"))
        .accessibilityIdentifier("composer.main")
        .accessibilityShowsLargeContentViewer {
            Label(running ? "Stop" : canSend ? "Send" : "Talk with Poki",
                  systemImage: running ? "stop.fill" : canSend ? "arrow.up" : "waveform")
        }
        .contextMenu {
            if !running, hasText {
                Button("New Line", systemImage: "return") {
                    input.append("\n")
                    focused = true
                }
            }
        }
    }

    private func submit() {
        guard !running, canSend else { return }
        dictation.cancel(model)
        let text = input
        send(text, attachments)
        withAnimation(.snappy) { attachments = [] }
        sends += 1
        sent = (text, Date())
        input = ""
        // Once more after the keyboard has settled, for a commit that arrives in pieces.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if input == text { input = "" }
        }
    }
}

/// Dictation into the message field (Apple's speech recognition, on the device when it can), separate
/// from the live conversation: it only writes words, it never sends them.
@MainActor
@Observable
final class FieldDictation {
    /// The setting (Settings › Voice) that shows the microphone beside Send.
    nonisolated static let buttonKey = "pokiDictationButton"
    /// Shown unless turned off: the field's main button starts a talk with Poki,
    /// so the microphone is the one way to dictate.
    nonisolated static let buttonShown = true
    /// Set once the first launch of the version with this setting has decided it (see `keepButtonForUpgrade`).
    nonisolated static let buttonSettledKey = "pokiDictationButton.settled"

    /// Earlier versions always showed the microphone, and the setting defaults to hidden, so a person
    /// updating from one would lose it. The first launch with the setting turns it on for someone who
    /// used the app before; a fresh install keeps the default (hidden). "Used before" is any trace an earlier
    /// version left (`EarlierVersion`). Once only, so a person who turns it off later keeps it off, and one
    /// who installed fresh and used the app for a while is not mistaken for an upgrade. Call it before
    /// anything reads the setting.
    nonisolated static func keepButtonForUpgrade(defaults: UserDefaults = .standard, sessionsFolder: URL = SessionStore.defaultFolder) {
        guard !defaults.bool(forKey: buttonSettledKey) else { return }
        defer { defaults.set(true, forKey: buttonSettledKey) }
        guard defaults.object(forKey: buttonKey) == nil else { return }
        if EarlierVersion.leftTraces(defaults: defaults, sessionsFolder: sessionsFolder) {
            defaults.set(true, forKey: buttonKey)
        }
    }
    private(set) var on = false
    private(set) var text = ""
    private(set) var base = ""
    private(set) var problem: String?
    private var engine: Dictation?
    /// Between the tap and the microphone being on (the permission question can sit in between).
    private var starting = false

    func start(_ model: AppModel, after current: String) {
        guard !on, !starting else { return }
        model.prepareForTask()
        starting = true
        problem = nil
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        base = trimmed.isEmpty ? "" : trimmed + " "
        text = ""
        Task {
            guard await Dictation.allowed() else {
                starting = false
                problem = AppLocalization.text(LocalizedStringResource("Amore needs the microphone and speech recognition. Allow them in Settings › Poki."))
                return
            }
            guard starting else { return }
            starting = false
            let engine = Dictation()
            engine.onHeard = { [weak self] heard in self?.text = heard }
            model.background.pauseAudio()
            do {
                try engine.listen()
                self.engine = engine
                on = true
            } catch {
                model.background.resumeAudio()
                problem = error.localizedDescription
            }
        }
    }

    /// Send was tapped: dictation ends, also one that was still asking for the microphone.
    func cancel(_ model: AppModel) {
        starting = false
        stop(model)
    }

    func stop(_ model: AppModel) {
        guard on, let engine else { return }
        on = false
        self.engine = nil
        Task {
            _ = await engine.finish()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            model.background.resumeAudio()
        }
    }
}

// MARK: Live voice

/// What was said in the live conversation, as bubbles under the chat: your words (grey while Poki is
/// still hearing them), Poki's answers, and its steps as grey lines.
struct LiveVoiceTranscript: View {
    var voice: VoiceModel
    @Environment(\.colorScheme) private var scheme
    /// Words still being heard are lighter than words said. On the light page a bubble much lighter
    /// than that all but disappears into the ground.
    private var hearing: Double { scheme == .dark ? 0.6 : 0.85 }

    var body: some View {
        if voice.isOn || !voice.lines.isEmpty {
            let lines = voice.lines
            VStack(spacing: 4) {
                Label(voice.isOn ? LocalizedStringKey("Talk with Poki") : LocalizedStringKey("Voice conversation"), systemImage: "waveform")
                    .font(.caption.weight(.medium)).foregroundStyle(ChatColor.secondary)
                    .padding(.top, 12).padding(.bottom, 4).frame(maxWidth: .infinity)
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                    let pending = i == lines.count - 1 && line.role == .you && voice.phase == .hearing
                    switch line.role {
                    case .you:
                        MessageBubble(direction: .outgoing, text: line.text, tail: true).opacity(pending ? hearing : 1)
                    case .poki:
                        MessageBubble(direction: .incoming, text: line.text, tail: true)
                    case .tool, .note:
                        StatusLine(glyph: .none, text: line.text)
                    }
                }
                if voice.phase == .hearing, lines.last?.role != .you {
                    MessageBubble(direction: .outgoing, text: AppLocalization.text(LocalizedStringResource("Listening…")), tail: true).opacity(hearing)
                }
            }
            .animation(PlanMotion.enter, value: voice.lines)
        }
    }
}
