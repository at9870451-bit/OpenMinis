import ActivityKit
import SwiftUI

/// The Live Activity in every phase, drawn with the widget's own views at the system's sizes (Lock
/// Screen 371 x up to 160, expanded island 371 wide, compact island, minimal island, top banner), so it
/// can be checked without a session. Debug > Live Activity.
///
/// For the build's screenshots: `-pokiScreen activity -pokiActivityState approval` shows one phase on
/// its own, and `-pokiActivityDemo approval` also starts a real Live Activity in that phase and sends
/// it an alert, so the simulator draws the real Lock Screen and Dynamic Island.
struct ActivityPreview: View {
    @State private var only = UserDefaults.standard.string(forKey: "pokiActivityState")
    private let demo = UserDefaults.standard.string(forKey: "pokiActivityDemo")

    init() {
        if Thumbnail.previewImage == nil { Thumbnail.previewImage = Self.sampleScreen() }
        AppIconFile.preview = { AppIconStore.shared.icon($0) }
    }

    var body: some View {
        let samples = Self.makeSamples()
        Group {
            if let only, let state = samples.first(where: { $0.0 == only })?.1 {
                VStack(alignment: .center, spacing: 24) {
                    LockScreenFrame(state: state)
                    IslandExpandedFrame(state: state)
                    IslandCompactFrame(state: state)
                    TopBannerFrame(state: state)
                }
                .padding(.top, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(white: 0.94).ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
            } else {
                // A list of the Live Activity's states; each row starts the real one on this iPhone, which iOS
                // draws on the Lock Screen and in the Dynamic Island.
                List {
                    Section {
                        ForEach(samples, id: \.0) { name, state in
                            Button { Task.detached { await DemoActivity.run(state) } } label: {
                                LabeledContent {
                                    Image(systemName: "play.circle.fill").foregroundStyle(.blue).imageScale(.large)
                                } label: {
                                    Label { Text(verbatim: Self.title(name)) } icon: { Image(systemName: state.face.symbol) }
                                }
                            }
                            .foregroundStyle(Color(.label))
                        }
                    } footer: {
                        Text("Starts that Live Activity on this iPhone. Lock the phone or go to the Home Screen to see it. The next one replaces it.")
                    }
                    Section {
                        Button(role: .destructive) {
                            Task.detached { for old in Activity<PokiActivityAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) } }
                        } label: {
                            // The symbol in red with its title, not the list's tint (main #143).
                            Label("End Live Activity", systemImage: "stop.circle").foregroundStyle(.red)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(AppLocalization.text("Live Activity"))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: Self.stateChangedNotification)) { _ in
            if let next = UserDefaults.standard.string(forKey: "pokiActivityState") {
                only = next
            }
        }
        .task {
            Self.registerPreviewObserver()
            if let demo, let state = Self.makeSamples().first(where: { $0.0 == demo })?.1 {
                // Detached: going to the background must not cancel the demo's wait for its alert.
                Task.detached { await DemoActivity.run(state) }
            }
        }
    }

    private static let stateChangedNotification = Notification.Name("PokiActivityPreviewStateChanged")
    @MainActor private static var observerRegistered = false
    @MainActor private static func registerPreviewObserver() {
        guard !observerRegistered else { return }
        observerRegistered = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0x5052), { _, _, _, _, _ in
            Task { @MainActor in
                NotificationCenter.default.post(name: ActivityPreview.stateChangedNotification, object: nil)
            }
        }, "nz.zheha.poki.preview-state" as CFString, nil, .deliverImmediately)
    }

    private static func title(_ name: String) -> String {
        switch name {
        case "start": AppLocalization.text(LocalizedStringResource("Task Started"))
        case "working": AppLocalization.text(LocalizedStringResource("Working"))
        case "step": AppLocalization.text(LocalizedStringResource("Next Step"))
        case "approval": AppLocalization.text(LocalizedStringResource("Approval"))
        case "deciding": AppLocalization.text(LocalizedStringResource("Approved"))
        case "yourturn": AppLocalization.text(LocalizedStringResource("Your Turn"))
        case "passcode": AppLocalization.text(LocalizedStringResource("Passcode"))
        case "done": AppLocalization.text(LocalizedStringResource("Done"))
        case "plan": AppLocalization.text(LocalizedStringResource("Chat Plan"))
        case "plannext": "\(AppLocalization.text(LocalizedStringResource("Chat Plan"))) › \(AppLocalization.text(LocalizedStringResource("Next Step")))"
        case "plandone": AppLocalization.text(LocalizedStringResource("Chat Plan Done"))
        case "ready": AppLocalization.text(LocalizedStringResource("Ready"))
        case "waking": AppLocalization.text(LocalizedStringResource("Waking"))
        case "idle": AppLocalization.text(LocalizedStringResource("Runner Asleep"))
        case "problem": AppLocalization.text(LocalizedStringResource("Problem"))
        case "pairing": AppLocalization.text(LocalizedStringResource("Pairing"))
        case "code": AppLocalization.text(LocalizedStringResource("Pairing Code"))
        case "setup": AppLocalization.text(LocalizedStringResource("Setup"))
        case "voice": AppLocalization.text(LocalizedStringResource("Voice"))
        case "voiceworking": "\(AppLocalization.text(LocalizedStringResource("Voice"))) › \(AppLocalization.text(LocalizedStringResource("Working")))"
        case "voiceapproval": "\(AppLocalization.text(LocalizedStringResource("Voice"))) › \(AppLocalization.text(LocalizedStringResource("Approval")))"
        default: name.capitalized
        }
    }

    /// Sample states, one per thing the Live Activity can show.
    static var samples: [(String, PokiState)] { makeSamples() }

    static func makeSamples() -> [(String, PokiState)] {
        let now = Date()
        let messages = AppLocalization.text(LocalizedStringResource("Messages"))
        var start = PokiState(phase: .working, headline: "Open WeChat", thumbnailVersion: 0)
        start.since = now.addingTimeInterval(-3)
        start.event = .init(kind: .started, text: "Started")

        var working = PokiState(phase: .working, headline: AppLocalization.text(LocalizedStringResource("Tap “Send”")), thumbnailVersion: 1)
        working.app = messages
        working.since = now.addingTimeInterval(-42)
        working.stepCount = 6; working.failedCount = 1
        working.previous = "Type “On my way”"

        var step = working
        step.event = .init(kind: .app, text: "Now in Messages")
        step.headline = "Tap “Search”, then type “Mom”"
        step.stepCount = 7
        step.caller = "Claude Code"

        var approval = PokiState(phase: .approval, headline: "Allow this step?", thumbnailVersion: 1)
        approval.app = messages
        // What PokiCore asks for when the agent taps Send in Messages.
        approval.approval = PendingApproval(id: "a", app: messages, summary: AppLocalization.text(LocalizedStringResource("Tap “Send”")), reason: ChatModel.Sample.reason, expires: now.addingTimeInterval(25))
        approval.since = now.addingTimeInterval(-61)
        approval.stepCount = 4

        var deciding = approval
        deciding.phase = .deciding; deciding.decision = true

        var yourTurn = PokiState(phase: .handoff, headline: "Your turn", thumbnailVersion: 1)
        yourTurn.app = "Amazon"
        yourTurn.since = now.addingTimeInterval(-95)
        yourTurn.stepCount = 9
        yourTurn.handoff = .init(id: "h1", kind: .payment, text: "Confirm the $42.10 order with Face ID", app: "Amazon", since: now.addingTimeInterval(-20))
        var passcode = PokiState(phase: .handoff, headline: "Your turn", thumbnailVersion: 0)
        passcode.handoff = .init(id: "h2", kind: AutomationPath.current == .inProcess ? .automationPasscode : .runnerPasscode, text: nil, app: nil, since: now.addingTimeInterval(-6))

        var done = PokiState(phase: .done, headline: "Finished", thumbnailVersion: 1)
        done.app = "Messages"
        done.since = now.addingTimeInterval(-84); done.endedAt = now
        done.stepCount = 12; done.failedCount = 1

        // A two-step task from Poki's own chat says the step under way in the plan's words, not the tap
        // (ESP-467), and never how many steps there are.
        let steps = [AppLocalization.text(LocalizedStringResource("Open Messages")), AppLocalization.text(LocalizedStringResource("Open the chat with Mom"))]
        var plan = working
        plan.headline = "Tap “Messages”"
        plan.previous = nil
        plan.plan = .init(steps: steps, current: 1, title: AppLocalization.text(LocalizedStringResource("Text Mom")), to: AppLocalization.text(LocalizedStringResource("Mom")))
        var planNext = plan
        planNext.headline = "Tap “Send”"
        planNext.previous = "Tap “Messages”"
        planNext.stepCount = 7
        planNext.plan?.current = 2
        planNext.failedSteps = [1]
        var planDone = done
        planDone.plan = .init(steps: steps, current: 2, title: AppLocalization.text("Text Mom"))

        var ready = PokiState(phase: .idle, headline: "Waiting for agent", thumbnailVersion: 0)
        var idle = PokiState(phase: .idle, headline: "Runner asleep", thumbnailVersion: 0)
        idle.runnerPaused = true
        ready.runnerPaused = false

        let title = AppModel.problemText(code: "loopback", fix: "Turn on the loopback in your proxy app: the Poki module in Surge or Loon.")
        var problem = PokiState(phase: .problem, headline: title, thumbnailVersion: 0)
        problem.label = "Runner Stopped"
        problem.stepCount = 6

        let pairWait = PokiState(phase: .pairing, headline: "Pair in Settings", thumbnailVersion: 0)
        var pairCode = PokiState(phase: .pairing, headline: "Pairing code", thumbnailVersion: 0)
        pairCode.pin = "482913"

        var setup = PokiState(phase: .setup, headline: "Setting up Poki", thumbnailVersion: 0)
        setup.guide = .init(number: 2, count: 6, title: SetupStep.developerMode.activityTitle)

        // The runner on its way up: one main line, the stage under it.
        let waking = PokiState(phase: .idle, headline: "Checking pairing", thumbnailVersion: 0)

        var voice = PokiState(phase: .idle, headline: "Listening", thumbnailVersion: 0)
        voice.voice = .listening
        // A step of the talk has Poki in another app: Stop for the step, End for the talk.
        var voiceWorking = working
        voiceWorking.voice = .thinking
        // An approval during a talk keeps the card and the island to itself.
        var voiceApproval = approval
        voiceApproval.voice = .listening

        let all = [("start", start), ("working", working), ("step", step), ("approval", approval), ("deciding", deciding), ("yourturn", yourTurn), ("passcode", passcode), ("done", done),
                   ("plan", plan), ("plannext", planNext), ("plandone", planDone),
                   ("ready", ready), ("waking", waking), ("idle", idle), ("problem", problem), ("pairing", pairWait), ("code", pairCode), ("setup", setup), ("voice", voice),
                   ("voiceworking", voiceWorking), ("voiceapproval", voiceApproval)]
        // `-pokiActivityCaller "Claude Code"`: every sample as an outside agent's, to see where its badge goes.
        guard let caller = UserDefaults.standard.string(forKey: "pokiActivityCaller") else { return all }
        return all.map { name, state in var state = state; state.caller = caller; return (name, state) }
    }

    /// A stand-in screenshot (a chat screen) for the thumbnail, drawn here so the preview needs no files.
    @MainActor static func sampleScreen() -> UIImage? {
        let blue = Color(red: 0x0A / 255, green: 0x7C / 255, blue: 1)
        let grey = Color(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xEA / 255)
        let view = VStack(alignment: .leading, spacing: 12) {
            Capsule().fill(.gray.opacity(0.35)).frame(width: 70, height: 10)
            ForEach(0..<4) { i in
                HStack {
                    if i % 2 == 1 { Spacer() }
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(i % 2 == 1 ? blue : grey)
                        .frame(width: i % 2 == 1 ? 108 : 114, height: 28)
                    if i % 2 == 0 { Spacer() }
                }
            }
            Spacer()
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(red: 0xC7 / 255, green: 0xC7 / 255, blue: 0xCC / 255), lineWidth: 2)
                .frame(height: 30)
        }
        .padding(14).frame(width: 196, height: 426).background(.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage
    }
}

/// The Lock Screen presentation as iOS lays it out: 371 points wide, the card's corner and tint.
private struct LockScreenFrame: View {
    var state: PokiState
    var body: some View {
        let card = RoundedRectangle(cornerRadius: ActivityMetrics.lockCorner, style: .continuous)
        LockScreenCard(face: state.face).dynamicTypeSize(...ActivityMetrics.largestType)
            .frame(maxWidth: 371)
            .background(ActivityTheme.current.lockBackground ?? Color(.secondarySystemGroupedBackground), in: card)
            .containerShape(card)
            .clipShape(card)
    }
}

/// Non-Dynamic Island models (iPhone SE and older): the same Live Activity card slides down from the top as a banner.
private struct TopBannerFrame: View {
    var state: PokiState
    var body: some View {
        let card = RoundedRectangle(cornerRadius: ActivityMetrics.lockCorner, style: .continuous)
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "9:41").font(.system(size: 14, weight: .semibold))
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "cellularbars")
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                }
                .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 6)

            LockScreenCard(face: state.face).dynamicTypeSize(...ActivityMetrics.largestType)
                .frame(maxWidth: 371)
                .background(ActivityTheme.current.lockBackground ?? Site.boardBlue, in: card)
                .containerShape(card)
                .clipShape(card)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .padding(.horizontal, 11)
                .padding(.bottom, 11)
        }
        .frame(width: 393)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 35, style: .continuous))
    }
}

/// The expanded island, regions placed the way iOS does on a 402-point iPhone: 374 wide, leading and
/// trailing against the top edge at their own height, the bottom region under a row of 36.67, and the
/// content cut to the outline drawn in by `ActivityMetrics.islandClip`. An earlier frame here had no
/// such cut and a centred top row, and passed a layout the real island then clipped.
private struct IslandExpandedFrame: View {
    var state: PokiState
    var body: some View {
        let face = state.face
        let shape = RoundedRectangle(cornerRadius: ActivityMetrics.islandCorner, style: .continuous)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                IslandLeading(face: face).dynamicTypeSize(...ActivityMetrics.largestType)
                Spacer(minLength: 120)
                IslandTrailing(face: face).dynamicTypeSize(...ActivityMetrics.largestType)
            }
            .frame(height: ActivityMetrics.systemCameraRow, alignment: .top)
            IslandBottom(face: face).dynamicTypeSize(...ActivityMetrics.largestType)
        }
        .frame(width: 374)
        .clipShape(RoundedRectangle(cornerRadius: ActivityMetrics.islandClipCorner).inset(by: ActivityMetrics.islandClip))
        .background(.black, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(ActivityTheme.current.outline, lineWidth: 1) }
        .overlay(alignment: .top) {
            Capsule()
                .fill(Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255))
                .overlay(alignment: .trailing) {
                    Circle()
                        .fill(Color(red: 0x1E / 255, green: 0x26 / 255, blue: 0x33 / 255))
                        .frame(width: 10, height: 10)
                        .padding(.trailing, 12)
                }
                .frame(width: 125, height: 36)
                .padding(.top, 1)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The compact island: the bear's block, the camera, the words, and the minimal circle beside it.
private struct IslandCompactFrame: View {
    var state: PokiState
    /// `-pokiActivityClip YES`: the line the system cuts at, dashed red, to compare with the design.
    private let clip = UserDefaults.standard.bool(forKey: "pokiActivityClip")
    var body: some View {
        let face = state.face
        let inset = ActivityMetrics.compactClip
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                CompactLeading(face: face).dynamicTypeSize(...ActivityMetrics.largestType)
                Spacer(minLength: 0).frame(width: 125.33)
                CompactTrailing(face: face).dynamicTypeSize(...ActivityMetrics.largestType).frame(minWidth: 44, alignment: .trailing).padding(.trailing, 7)
            }
            .frame(height: ActivityMetrics.compactHeight)
            .background(.black, in: .capsule)
            .clipShape(.capsule)
            .overlay { Capsule().strokeBorder(ActivityTheme.current.outline, lineWidth: 1) }
            .overlay { if clip { Capsule().inset(by: inset).stroke(.red, style: StrokeStyle(lineWidth: 0.75, dash: [2, 2])) } }
            MinimalView(face: face).dynamicTypeSize(...ActivityMetrics.largestType)
                .background(.black, in: .circle)
                .overlay { Circle().strokeBorder(ActivityTheme.current.outline, lineWidth: 1) }
                .overlay { if clip { Circle().inset(by: inset).stroke(.red, style: StrokeStyle(lineWidth: 0.75, dash: [2, 2])) } }
            // Short of room (the phone on its side, a second Live Activity): each block in a 28-point circle.
            HStack(spacing: 4) {
                CompactLeading(face: face).dynamicTypeSize(...ActivityMetrics.largestType)
                CompactTrailing(face: face).dynamicTypeSize(...ActivityMetrics.largestType)
            }
            .environment(\.narrowIslandPreview, true)
            .padding(.horizontal, 4)
            .frame(height: ActivityMetrics.compactHeight)
            .background(.black, in: .capsule)
            .overlay { Capsule().strokeBorder(ActivityTheme.current.outline, lineWidth: 1) }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// A real Live Activity in one sample phase, for the simulator screenshots.
@MainActor
enum DemoActivity {
    static func run(_ sample: PokiState) async {
        for old in Activity<PokiActivityAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) }
        if let url = SharedContainer.thumbnailURL, let jpeg = ActivityPreview.sampleScreen()?.jpegData(compressionQuality: 0.7) {
            try? jpeg.write(to: url, options: .atomic)
        }
        var state = sample
        // Times relative to now, so countdowns are live in the screenshots: elapsed starts at 0:00 and
        // an approval has two minutes, which also shows any clock difference between app and widget.
        let now = Date()
        if state.since != nil { state.since = now }
        if let end = state.endedAt, let since = sample.since { state.endedAt = now; state.since = now.addingTimeInterval(-end.timeIntervalSince(since)) }
        if var approval = state.approval {
            approval.expires = now.addingTimeInterval(120); state.approval = approval
        }
        // Poki keeps running in the background while it is on; the demo asks for time to send its alert.
        let task = UIApplication.shared.beginBackgroundTask(withName: "activity demo")
        defer { UIApplication.shared.endBackgroundTask(task) }
        guard let activity = try? Activity.request(attributes: PokiActivityAttributes(deviceName: "iPhone"), content: .init(state: state, staleDate: nil), pushType: nil) else {
            AppLog.shared.add("activity", "demo did not start")
            return
        }
        // Each `notifyutil -p nz.zheha.poki.demo-alert` from the build sends an alert, so the
        // screenshot is taken right after it (simulator screenshots take seconds; fixed delays miss it).
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0x5051), { _, _, _, _, _ in
            Task { @MainActor in await DemoActivity.alert() }
        }, "nz.zheha.poki.demo-alert" as CFString, nil, .deliverImmediately)
        current = (activity, state)
        try? await Task.sleep(for: .seconds(28))
    }

    private static var current: (Activity<PokiActivityAttributes>, PokiState)?

    static func alert() async {
        guard let (activity, state) = current else { return }
        await activity.update(.init(state: state, staleDate: nil, relevanceScore: 100),
                              alertConfiguration: AlertConfiguration(title: "Poki", body: "\(state.headline)", sound: .default))
        AppLog.shared.add("activity", "demo alert sent")
    }
}
