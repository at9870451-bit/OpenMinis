import PokiCore
import SwiftUI

// Settings (ESP-469; before it Poki's profile, ESP-326 board "09 Poki") opens from the bottom of the
// conversations. It replaced the earlier details screen and its "More Settings" layer. Every part of Poki a
// person looks for by name is a row of its own on this page (Connection, Models, Dictation & Mute,
// Approvals, Agents, Memory, Archived Conversations, Signing & Updates, Notifications, Appearance, Language), and
// what only a few need is on one page, Advanced, by where it came from. Nothing has two ways in: the
// approval method is changed on Poki's card in the chat only. The rows are PokiSettingsKit's.

/// Settings: Poki on top, as a group of rows like the groups under it (the owner, 2026-11-13: not a
/// card of its own): the bear and its name, where Poki stands, and the Activity Log. Then any problem
/// that keeps Poki from working, and the parts of Poki in three groups of rows.
struct PokiDetailsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @Environment(\.dismiss) private var dismiss
    var openSetup: () -> Void
    /// Opens a run in the chat (from the Activity Log).
    var openSession: (String) -> Void = { _ in }
    @Binding var path: NavigationPath
    /// Bumped when the chosen model changes, so the Models row's value redraws (ModelKeys is not observable).
    @State private var modelVersion = 0

    private var isSample: Bool { UserDefaults.standard.bool(forKey: "pokiDetailsSample") }
    private static let lastRow = "details.lastRow"

    var body: some View {
        let power = isSample ? PowerTile.pause : PowerTile.card(model: model)
        let status = isSample ? PokiStatus(.ready) : PokiStatusCopy.card(PokiStatus.current(model: model, chat: chat), power: power)
        NavigationStack(path: $path) {
            ScrollViewReader { scroll in
            List {
                Section {
                    // The first two rows only show: Connection's Automation switch turns Poki on and pauses it.
                    PokiNameRow(mood: status.mood)
                    SettingsRow(title: "Status", symbol: "dot.radiowaves.left.and.right", value: PokiStatusCopy.word(status), dot: status.mood.dot)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("details.status")
                    NavigationLink(value: DetailsRoute.history) {
                        SettingsRow(title: "Activity Log", symbol: "clock")
                    }
                    .accessibilityIdentifier("details.activity")
                }

                if !isSample {
                    let issues = Issue.current(model)
                    if !issues.isEmpty {
                        Section {
                            ForEach(issues) { issue in
                                DetailsIssueRow(issue: issue, openSetup: { path.append(DetailsRoute.connection) })
                            }
                        }
                        .accessibilityIdentifier("details.issues")
                    }
                }

                // What Poki works with.
                Section {
                    NavigationLink(value: DetailsRoute.connection) {
                        SettingsRow(title: "Connection", symbol: "iphone.gen3", value: connectionValue,
                                    valueIsAction: !isSample && !model.setupReadyForUse)
                    }
                    .accessibilityIdentifier("details.hands")
                    NavigationLink(value: DetailsRoute.model) {
                        SettingsRow(title: "Models", symbol: "sparkles", value: brainValue, valueIsAction: !hasModel)
                            .id(modelVersion)
                    }
                    .accessibilityIdentifier("details.accountsAndModels")
                    // Named for what is on it: the dictation button and Poki's voice. Live voice starts in the chat.
                    NavigationLink(value: DetailsRoute.voice) {
                        SettingsRow(title: "Dictation & Mute", symbol: "mic")
                    }
                    .accessibilityIdentifier("details.voice")
                    // What always asks, what each method does and the sensitivity. The method in use shows
                    // here; it is changed on Poki's card in the chat.
                    NavigationLink(value: DetailsRoute.approvals) {
                        SettingsRow(title: "Approvals", symbol: "checkmark.shield", value: model.approvalMode.title)
                    }
                    .accessibilityIdentifier("moreSettings.approvals")
                }

                // Who else uses it, and what it keeps.
                Section {
                    NavigationLink(value: DetailsRoute.agents) {
                        SettingsRow(title: "Agents", symbol: "chevron.left.forwardslash.chevron.right", value: agentsValue)
                    }
                    .accessibilityIdentifier("moreSettings.agentsAndRelay")
                    NavigationLink(value: SettingsRoute.memory) {
                        SettingsRow(title: "Memory", symbol: "bookmark", value: "\(isSample ? 10 : RoutineStore.shared.routines.count)")
                    }
                    .accessibilityIdentifier("moreSettings.memory")
                    NavigationLink(value: DetailsRoute.conversations) {
                        SettingsRow(title: "Archived Conversations", symbol: "archivebox", value: isSample ? "3" : archivedValue)
                    }
                    .accessibilityIdentifier("details.searchConversations")
                }

                // The app itself.
                Section {
                    // Embedded Amore has its own signed release/update channel.
                    Button {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        SettingsRow(title: "Notifications", symbol: "bell.badge", accessory: .leaves)
                    }
                    .accessibilityIdentifier("moreSettings.notifications")
                    NavigationLink(value: DetailsRoute.appearance) {
                        SettingsRow(title: "Appearance", symbol: "circle.lefthalf.filled", value: AppLocalization.text(appearance.title))
                    }
                    .accessibilityIdentifier("details.appearance")
                    NavigationLink(value: DetailsRoute.interfaceSize) {
                        SettingsRow(title: "Interface Size", symbol: "textformat.size")
                    }
                    .accessibilityIdentifier("general.interfaceSize")
                    NavigationLink(value: DetailsRoute.language) {
                        SettingsRow(title: "Language", symbol: "globe", value: LanguageSettingsView.selectionTitle)
                    }
                    .accessibilityIdentifier("details.language")
                    NavigationLink(value: DetailsRoute.advanced) {
                        SettingsRow(title: "Advanced", symbol: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("details.health")
                    .id(Self.lastRow)
                } footer: {
                    Text(verbatim: "Poki \(model.signer.installedVersion) (\(model.signer.installedBuild))")
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .settingsPage()
            // `-pokiSettingsEnd YES` opens the page at its end, for the build's screenshot of the rows
            // below the first screen.
            .task {
                guard UserDefaults.standard.bool(forKey: "pokiSettingsEnd") else { return }
                try? await Task.sleep(for: .seconds(0.6))
                scroll.scrollTo(Self.lastRow, anchor: .center)
            }
            }
            .navigationTitle(AppLocalization.text("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("details.done")
                }
            }
            // Every page under Settings takes the same ground and the same round icons.
            .navigationDestination(for: DetailsRoute.self) { route in
                Group { switch route {
                case .model:
                    ModelSettingsView()
                case .voiceKey:
                    ModelSettingsView(opensVoiceKey: true)
                case .history:
                    ActionLogView(openSession: { id in dismiss(); openSession(id) })
                case .conversations:
                    ConversationsSettingsView(openSession: { id in dismiss(); openSession(id) })
                case .voice:
                    VoiceView(embedded: true)
                case .connection:
                    ConnectionView()
                case .advanced:
                    AdvancedSettingsView()
                case .agents:
                    AgentsAndRelayView(path: $path)
                case .updates:
                    Text("Self-updating is disabled in the embedded Amore module. Install signed Amore updates through your existing signing method.")
                        .navigationTitle("Amore")
                case .approvals:
                    ApprovalsSettingsView()
                case .appearance:
                    AppearanceView()
                case .interfaceSize:
                    InterfaceSizeSettingsView()
                case .language:
                    LanguageSettingsView()
                } }
                .settingsPage()
            }
            .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0).settingsPage() }
            .navigationDestination(for: SettingsRoute.self) { route in
                SettingsDestination(route: route, push: { path.append($0) }, pop: { if !path.isEmpty { path.removeLast() } })
                    .settingsPage()
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in modelVersion += 1 }
            .sheet(isPresented: Bindable(model.signer).needsCodeSheet) { VerificationCodeSheet() }
        }
    }

    private var hasModel: Bool { isSample || ModelKeys.hasUsableKey }
    private var brainValue: String {
        if isSample { return "GPT-6.1 Terra" }
        return hasModel ? ModelKeys.selectedModelName : AppLocalization.text(LocalizedStringResource("Add Model"))
    }

    /// Setup first, then whether Poki is on.
    private var connectionValue: String {
        if isSample { return AppLocalization.text(LocalizedStringResource("On")) }
        if !model.setupReadyForUse {
            return AppLocalization.text(LocalizedStringResource("Finish Setup"))
        }
        if !model.sessionOn { return AppLocalization.text(LocalizedStringResource("Off")) }
        return model.ownerPaused ? AppLocalization.text(LocalizedStringResource("Paused")) : AppLocalization.text(LocalizedStringResource("On"))
    }

    private var agentsValue: String {
        if isSample { return AppLocalization.text(LocalizedStringResource("\(2) Connected")) }
        if model.relayAddress == nil || !model.relayEnabled { return AppLocalization.text(LocalizedStringResource("Off")) }
        if model.relayStatus.isOffline { return Health.relay(model).word }
        let count = model.identity.secrets.count
        return count == 0 ? AppLocalization.text(LocalizedStringResource("None yet")) : AppLocalization.text(LocalizedStringResource("\(count) Connected"))
    }

    private var archivedValue: String? {
        let count = SessionStore.shared.archivedSessions.count
        return count == 0 ? nil : "\(count)"
    }

    private var updateWaits: Bool { !isSample && (model.signer.updateNotReady || model.signer.next?.kind == "update") }
    /// The version is the page's last line, so the row only speaks up when an update waits.
    private var updatesValue: String? { updateWaits ? AppLocalization.text(LocalizedStringResource("Update Available")) : nil }

    @AppStorage(Appearance.key) private var appearanceChoice = Appearance.automatic.rawValue
    private var appearance: Appearance { Appearance(rawValue: appearanceChoice) ?? .automatic }
}

enum DetailsRoute: Hashable {
    case model, history, conversations, voice, connection, advanced, agents, updates, approvals, appearance, language, interfaceSize
    /// Models, with the OpenAI key's form open (or Live Voice, when the key is there but turned off):
    /// where Talk with Poki without a key leads.
    case voiceKey
}

/// Settings > Archived Conversations: the archived conversations, each one line as in the drawer, to open, bring
/// back or delete; and a search through every conversation, archived or not.
private struct ConversationsSettingsView: View {
    var openSession: (String) -> Void
    @State private var query = ""
    private var store: SessionStore { SessionStore.shared }

    private var matches: [SavedSession] {
        let words = query.trimmingCharacters(in: .whitespaces)
        return store.ordered.filter { session in
            [session.name, session.title, session.lastLine, session.client ?? ""].contains { $0.localizedCaseInsensitiveContains(words) }
        }
    }

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                let archived = store.archivedSessions
                Section {
                    ForEach(archived) { session in
                        Button { openSession(session.id) } label: {
                            ConversationTitle(session: session)
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) { store.delete(session.id) }
                            Button("Unarchive", systemImage: "tray.and.arrow.up") { store.unarchive(session.id) }.tint(Tint.blue)
                        }
                        .contextMenu {
                            Button("Unarchive", systemImage: "tray.and.arrow.up") { store.unarchive(session.id) }
                            Button("Delete", systemImage: "trash", role: .destructive) { store.delete(session.id) }
                        }
                        .accessibilityIdentifier("archived.row")
                    }
                } header: {
                    Text("Archived Conversations").textCase(nil)
                }
                if archived.isEmpty {
                    ContentUnavailableView("No Archived Conversations", systemImage: "archivebox",
                                           description: Text("Conversations you archive appear here."))
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(matches) { session in
                    Button { openSession(session.id) } label: {
                        HStack(spacing: 12) {
                            SessionAvatar(session: session, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: session.name).foregroundStyle(Color(.label))
                                Text(verbatim: session.lastLine).font(.subheadline)
                                    .foregroundStyle(Color(.secondaryLabel)).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .navigationTitle(AppLocalization.text("Archived Conversations"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Search"))
    }
}

/// The first row of Settings: the bear's face where the rows under it have their icon, and Poki's name.
private struct PokiNameRow: View {
    var mood: PokiMood
    @ScaledMetric(relativeTo: .body) private var face = SettingsRowMetrics.iconSize
    @ScaledMetric(relativeTo: .body) private var iconSpacing = SettingsRowMetrics.iconSpacing

    var body: some View {
        HStack(spacing: min(18, iconSpacing)) {
            Group {
                if let image = PokiMood.cutout(mood, small: true) {
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                }
            }
            .frame(width: min(SettingsRowMetrics.maximumIconSize, face), height: min(SettingsRowMetrics.maximumIconSize, face))
            .background(mood == .paused ? Tint.night : Tint.portrait, in: .circle)
            .clipShape(.circle)
            .overlay(Circle().strokeBorder(Tint.ring, lineWidth: 1))
            .padding(.vertical, SettingsRowMetrics.iconLineInset)
            .accessibilityHidden(true)
            Text(verbatim: "Amore").font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
        }
        .animation(.easeInOut(duration: 0.3), value: mood)
    }
}

/// A plain button that dims while pressed, for tiles that draw their own surface.
struct PressedDimStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: Connection

/// Connection: whether Poki may act on this iPhone and each thing the phone needs for it (the setup
/// items, each opening its own page), with the guide that walks through them and the first run.
struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    var stopHost: () -> Void = {}
    @State private var guiding = false

    private var on: Bool { model.sessionOn && !model.ownerPaused }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { on }, set: set)) {
                    SettingsRow(title: "Automation", symbol: "hand.tap")
                }
                .accessibilityIdentifier("hands.on")
                if model.passcodeConfirmationPending {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter Your Passcode Next").font(.headline)
                        Text(AppModel.passcodeHeadsUpMessage).font(.subheadline)
                    }
                    Button("Continue") { model.continueAfterPasscodeHeadsUp() }
                    Button("Cancel", role: .cancel) { model.cancelPasscodeHeadsUp() }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    // Paused is not a lock: an agent's request, or a task you send, starts Poki again.
                    if model.passcodeConfirmationPending {
                        Text(AppModel.passcodeConfirmationMessage)
                    } else {
                        Text(model.sessionStarting ? "Poki is turning on."
                             : on ? "Poki can tap, type, and scroll on this iPhone."
                             : model.sessionOn ? "Poki is paused. It resumes automatically upon a new task or agent request."
                             : "Poki is off. Agents can’t reach this iPhone.")
                    }
                    // Why turning on failed, under the switch that was turned on (not only on Poki's
                    // page). Poki's own sentences are localized; PokiCore's stay as they came.
                    if let failure = model.developerToolsFailure {
                        Text(failure).foregroundStyle(.red)
                    } else if !on, !model.sessionStarting, let problem = model.problem {
                        Text(verbatim: AppLocalization.bundle.localizedString(forKey: problem, value: problem, table: nil))
                            .foregroundStyle(.red)
                    } else if !on, !model.sessionStarting, case .downloaded = model.diskImage.state {
                        Text(DiskImageStore.unavailableMessage).foregroundStyle(.orange)
                    }
                }
            }

            Section {
                ForEach(SetupStep.shown) { step in
                    let done = model.stepReadyForUse(step)
                    NavigationLink(value: step) {
                        SettingsRow(title: step.rowTitle, symbol: step.symbol, value: done ? nil : AppLocalization.text(LocalizedStringResource("Turn On")),
                                    warns: !done, accessory: done ? .done : nil)
                    }
                }
                Button { guiding = true } label: {
                    SettingsRow(title: model.setupReadyForUse ? "Set Up Again" : "Continue Setup", symbol: "checklist")
                }
                .accessibilityIdentifier("moreSettings.setup")
                // Model setup belongs to Amore settings.
            } header: {
                SettingsHeader("This iPhone")
            } footer: {
                Text("Poki uses Apple’s developer tools on this iPhone. Keep all of these on.")
            }
        }
        .navigationTitle(AppLocalization.text("Connection"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.loopback.resume(); model.diskImage.notice() }
        .sheet(isPresented: $guiding) {
            SetupGuide(start: SetupStep.shown.first { !model.stepReadyForUse($0) })
        }
    }

    private func set(_ on: Bool) {
        if !on {
            stopHost()
            model.pauseByOwner()
        } else if model.sessionOn {
            model.wakeRunner()
        } else {
            model.startSession()
        }
    }
}

// MARK: Advanced

/// Advanced, the one page of it: what only a few need, by the page it came from. Connection's automation
/// banner or runner, Voice's bridge on a Mac, Memory's run log for the maintainers, and the tools under
/// the hood (diagnostics, the log, testing options).
struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var runLog: URL?

    var body: some View {
        @Bindable var model = model
        let voice = model.voice
        List {
            // Main's Runner section. The in-process path has no its helper to start or stop (ESP-152).
            if model.automationPath == .runner {
                Section {
                    LabeledContent("Runner", value: Health.runner(model).word)
                    Picker("Stop When Idle For", selection: $model.idleStopSeconds) {
                        ForEach(SettingsHome.idleChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    if model.runnerPaused {
                        Button("Start Now") { model.wakeRunner() }
                    } else {
                        Button("Stop Runner", role: .destructive) { model.pauseRunner() }.disabled(!model.approvals.isEmpty)
                    }
                } header: {
                    SettingsHeader("Connection")
                } footer: {
                    Text("iOS shows the automation banner only while the runner is active. Poki starts it when needed and stops it when idle. Don’t close its helper while an agent is working.")
                }
            }

            // Shown as Voice's own Advanced was: with a bridge set, an answer timed, or no OpenAI key.
            if voice.lastTurnMS != nil || voice.bridge != nil || VoiceDirect.apiKey == nil {
                Section {
                    VoiceAdvancedRows()
                } header: {
                    SettingsHeader("Voice")
                }
            }

            Section {
                if let runLog {
                    ShareLink(item: runLog) { SettingsRow(title: "Share Run Log for Maintainers", symbol: "square.and.arrow.up") }
                }
            } header: {
                SettingsHeader("Memory")
            } footer: {
                Text("The run log lists each routine run, where it stopped and how long it took, with no typed text. It helps the Poki maintainers make routines more reliable.")
            }

            Section {
                NavigationLink(value: SettingsRoute.diagnostics) {
                    SettingsRow(title: "Diagnostics", symbol: "stethoscope")
                }
                .accessibilityIdentifier("moreSettings.diagnostics")

                NavigationLink(value: SettingsRoute.log) {
                    SettingsRow(title: "Log", symbol: "doc.text")
                }
                .accessibilityIdentifier("moreSettings.log")

                NavigationLink { TestingOptionsView().settingsPage() } label: {
                    SettingsRow(title: "Testing Options", symbol: "testtube.2")
                }
                .accessibilityIdentifier("moreSettings.testingOptions")
            } header: {
                SettingsHeader("Debugging")
            }
        }
        .navigationTitle(AppLocalization.text("Advanced"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // The run log is written to tmp for the share sheet, as Memory did it.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("poki-agent-debug.json")
            if (try? RoutineStore.shared.debugBundle().write(to: file, options: .atomic)) != nil { runLog = file }
        }
    }
}

// MARK: Appearance

/// The app's light or dark look, or the iPhone's own (`PokiApp` applies it to every window).
enum Appearance: String, CaseIterable, Identifiable {
    case automatic = "", light, dark
    static let key = "amore.appearance"

    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var style: UIUserInterfaceStyle {
        switch self {
        case .automatic: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    @MainActor
    func select(reduceMotion: Bool, updatePreference: () -> Void) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .filter { $0.isKeyWindow && !$0.isHidden }
        let transitions = reduceMotion ? [] : windows.compactMap { AppearanceFade(window: $0) }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, updatePreference)
        UIView.performWithoutAnimation {
            for window in windows {
                window.overrideUserInterfaceStyle = style
                window.layoutIfNeeded()
            }
        }
        transitions.forEach { $0.start() }
    }
}

@MainActor
private final class AppearanceFade: UIView {
    // Keep the outgoing frame opaque until SwiftUI has rendered the new list selection and UIKit
    // has presented the new traits. Layout alone does not commit a frame to the display.
    private var framesUntilReveal = 3

    init?(window: UIWindow) {
        guard let snapshot = window.snapshotView(afterScreenUpdates: false) else { return nil }
        super.init(frame: window.bounds)
        for case let previous as AppearanceFade in window.subviews { previous.removeFromSuperview() }
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        snapshot.frame = bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(snapshot)
        window.addSubview(self)
    }

    required init?(coder: NSCoder) { nil }

    func start() {
        CADisplayLink(target: self, selector: #selector(reveal(_:))).add(to: .main, forMode: .common)
    }

    @objc private func reveal(_ link: CADisplayLink) {
        guard superview != nil else { link.invalidate(); return }
        framesUntilReveal -= 1
        guard framesUntilReveal == 0 else { return }
        link.invalidate()
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.alpha = 0
        } completion: { _ in
            self.removeFromSuperview()
        }
    }
}

/// Settings › Appearance: Automatic, Light or Dark.
struct AppearanceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Appearance.key) private var choice = Appearance.automatic.rawValue

    var body: some View {
        List {
            Section {
                ForEach(Appearance.allCases) { option in
                    Button {
                        guard choice != option.rawValue else { return }
                        option.select(reduceMotion: reduceMotion) { choice = option.rawValue }
                    } label: {
                        HStack {
                            Text(verbatim: AppLocalization.text(option.title)).foregroundStyle(Color(.label))
                            Spacer()
                            // Keep the same view and layout when the selection moves. A list row
                            // can animate an inserted symbol independently of the window's fade.
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(option.rawValue == choice ? Tint.blueText : Color.clear)
                                .transaction {
                                    $0.animation = nil
                                    $0.disablesAnimations = true
                                }
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option.rawValue == choice ? .isSelected : [])
                    .accessibilityIdentifier("appearance.\(option == .automatic ? "automatic" : option.rawValue)")
                }
            } footer: {
                Text("Automatic follows the iPhone’s appearance setting.")
            }
        }
        .navigationTitle(AppLocalization.text("Appearance"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Language: the effective iOS app language or one of Poki’s bundled translations.
private struct LanguageSettingsView: View {
    @Bindable private var localization = AppLocalization.shared

    static var selectionTitle: String { title(for: AppLocalization.shared.preference) }

    private static func title(for language: String) -> String {
        if language == AppLocalization.system { return AppLocalization.text("Follow System") }
        return Locale(identifier: language).localizedString(forIdentifier: language) ?? language
    }

    var body: some View {
        List {
            Section {
                ForEach([AppLocalization.system] + AppLocalization.languages, id: \.self) { language in
                    let selected = localization.preference == language
                    Button { localization.preference = language } label: {
                        HStack {
                            Text(verbatim: Self.title(for: language)).foregroundStyle(Color(.label))
                            Spacer()
                            if selected {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Tint.blueText)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("language.\(language)")
                }
            }
        }
        .navigationTitle(AppLocalization.text("Language"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Approvals (ESP-469 board "03 审批"): what always needs you, how Poki asks before a sensitive step, and
/// how much your chat model may approve by itself. The way of asking is chosen here and on Poki's card (the
/// same setting); the chat's Approvals are off line links here to turn them back on. The sensitivity's
/// four levels are segments in their own order, least asking first.
struct ApprovalsSettingsView: View {
    @Environment(AppModel.self) private var model
    /// The way of asking says itself in one line; Learn More opens the whole of it.
    @State private var more = false

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "lock.fill").foregroundStyle(Tint.amberInk).accessibilityHidden(true)
                    Text("Payments, deletions and actions in Wallet always need your confirmation.")
                        .font(.subheadline.weight(.medium)).foregroundStyle(Tint.amberInk)
                }
                .padding(.vertical, 4)
                .listRowBackground(Tint.amberSoft)
            }

            Section {
                Picker("Approval Method", selection: $model.approvalMode) {
                    ForEach(ApprovalClassifier.Mode.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("approvals.mode.picker")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    switch model.approvalMode {
                    case .reply: Text("Poki asks in the chat and proceeds after you reply.")
                    case .confirm: Text("Tap Allow or Don’t Allow in the Live Activity, a notification, or Poki.")
                    case .off: Text("Optional steps run automatically without asking.")
                    }
                    if more {
                        switch model.approvalMode {
                        case .reply: Text("With Message Reply, Poki asks you in the chat and your yes lets the step through. Away from Poki you can answer from the notification. Outside agents have no chat, so their steps ask with Allow and Don’t Allow.")
                        case .confirm: Text("With Confirmation, you tap Allow or Don’t Allow on the Live Activity, in a notification, or here in Poki.")
                        case .off: Text("Optional steps continue without asking. Payments, deletions and actions in Wallet still need your confirmation.")
                        }
                        Text("Sensitive steps are paying, deleting, sending a message, placing a call, typing a password and anything in Wallet.")
                        Text("Changes apply right away, starting from Poki’s next step.")
                    } else {
                        Button("Learn More") { withAnimation(.snappy) { more = true } }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Tint.blueText)
                            .buttonStyle(.borderless)
                            .padding(.top, 2)
                            .accessibilityIdentifier("approvals.learnMore")
                    }
                }
            }
            .accessibilityIdentifier("approvals.mode")

            if model.approvalMode != .off {
                Section {
                    Picker("Sensitivity", selection: $model.classifierLevel) {
                        ForEach(ApprovalClassifier.Level.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .accessibilityIdentifier("approvals.sensitivity")
                } header: {
                    Text("Sensitivity").textCase(nil)
                } footer: {
                    switch model.classifierLevel {
                    case .permissive: Text("Permissive. Your chat model approves a step in Poki’s own chat unless it clearly has nothing to do with what you asked, or you said no.")
                    case .balanced: Text("Balanced. Your chat model approves a step in Poki’s own chat when it directly serves what you asked for. You are asked about the rest.")
                    case .strict: Text("Strict. Your chat model approves a step in Poki’s own chat only when you asked for that exact action. You are asked about the rest.")
                    case .everything: Text("Ask All. Nothing is approved automatically. Each request needs your answer.")
                    }
                }
            }
        }
        .navigationTitle(AppLocalization.text("Approvals"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Agents: the MCP relay outside agents come through (its switch and address), then the agents that control
/// this iPhone through Poki (list, add, revoke, each one's QR code and address).
struct AgentsAndRelayView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath

    private var relayLine: String {
        if model.relayAddress == nil { return AppLocalization.text(LocalizedStringResource("Set an address first")) }
        if !model.relayEnabled { return AppLocalization.text(LocalizedStringResource("Off, agents can’t reach this iPhone")) }
        if !model.sessionOn { return AppLocalization.text(LocalizedStringResource("Waiting for Poki, turn Poki on and agents can connect")) }
        return Health.relay(model).word
    }

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                Toggle(isOn: Binding(get: { model.relayEnabled && model.relayAddress != nil }, set: { model.setRelayEnabled($0) })) {
                    SettingsLabel {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MCP Relay")
                            Text(relayLine)
                                .font(.footnote.weight(.regular)).foregroundStyle(Color(.secondaryLabel))
                        }
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(model.relayAddress == nil || !model.sessionOn)

                NavigationLink(value: SettingsRoute.relay) {
                    LabeledContent {
                        Text(model.relayAddress.map { $0.origin.host() ?? $0.origin.absoluteString } ?? AppLocalization.text(LocalizedStringResource("Not Set")))
                            .foregroundStyle(model.relayAddress == nil ? Color.orange : Color.secondary)
                    } label: {
                        SettingsLabel("Address", systemImage: "network")
                    }
                }
            } header: {
                SettingsHeader("MCP Relay")
            } footer: {
                Text("The relay forwards agents’ requests to this iPhone while Poki is open or in the background. It stores nothing.")
            }

            Section {
                ForEach(model.identity.secrets) { secret in
                    let last = SessionStore.shared.sessions(for: secret, among: model.identity.secrets).first
                    NavigationLink(value: SettingsRoute.connector(secret)) {
                        LabeledContent {
                            Text(last.map { ChatTime.row($0.updated) } ?? AppLocalization.text(LocalizedStringResource("Not Used Yet")))
                        } label: {
                            // An agent's own badge is its picture; only the generic symbol takes the round ground.
                            if let client = secret.agent ?? last?.client {
                                HStack(spacing: 12) {
                                    AgentBadge(name: client, size: 30)
                                    Text(verbatim: secret.name)
                                }
                            } else {
                                SettingsLabel { Text(verbatim: secret.name) } icon: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                            }
                        }
                    }
                    .swipeActions { Button("Revoke", role: .destructive) { model.revoke(secret) } }
                    // 752's Agents and Relay had it too: a long press revokes.
                    .contextMenu { Button("Revoke Access", systemImage: "xmark.circle", role: .destructive) { model.revoke(secret) } }
                }
                Button(action: add) {
                    SettingsLabel { Text("Add Agent") } icon: { Image(systemName: "plus") }
                }
                .disabled(model.relayAddress == nil)
            } header: {
                SettingsHeader("Agents")
            } footer: {
                Text(model.relayAddress == nil
                     ? "Set your relay first. Each agent gets its own MCP address on it."
                     : "Each agent gets its own MCP address. Add it as a remote MCP server in Claude, Codex or any MCP client. It takes the agent’s name and icon when the agent first connects, unless you renamed it. Swipe to revoke.")
            }
        }
        .navigationTitle(AppLocalization.text("Agents"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        guard model.relayAddress != nil else { return }
        let secret = model.addConnector(name: "")
        path.append(SettingsRoute.connector(secret))
    }
}

extension SetupStep {
    /// Short row title on Connection's list of what this iPhone needs.
    var rowTitle: LocalizedStringKey {
        switch self {
        case .developerMode: "Developer Mode"
        case .loopback: "Local Connection"
        case .pairing: "Pair This iPhone"
        case .automation: "UI Automation"
        case .background: "Stay On in Background"
        case .runner: "its helper"
        }
    }
}

// MARK: Rows

/// A white group with 12 pt corners on the grouped grey (the boards' rows).
struct GroupCard: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity).background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    func groupCard() -> some View { modifier(GroupCard()) }
    /// The 0.5 pt separator under a row, from the leading edge of the text.
    func rowDivider(_ show: Bool = true, leading: CGFloat = 16) -> some View {
        overlay(alignment: .bottom) {
            if show { ChatColor.separator.frame(height: 0.5).padding(.leading, leading) }
        }
    }
}

struct GroupedSection<Content: View>: View {
    var title: LocalizedStringKey
    var footer: LocalizedStringKey?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(Color(.secondaryLabel)).padding(.horizontal, 16)
            VStack(spacing: 0) { content }.groupCard()
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(Color(.secondaryLabel)).padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct Chevron: View {
    var body: some View { Text(verbatim: "›").font(.body.weight(.semibold)).foregroundStyle(Color(.tertiaryLabel)) }
}

private struct DetailsIssueRow: View {
    @Environment(AppModel.self) private var model
    var issue: Issue
    var openSetup: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.multicolor)
            Text(issue.text)
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryLabel))
            if let button = issue.button {
                Button(button) { issue.act(model, openSetup: openSetup) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Site.blue)
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The first tile on Poki's details: main's Pause and Resume pair, and Turn On while Poki is off.
/// Standing by (right after Turn On, or after the idle minute) is Resume, as on main.
enum PowerTile: Equatable {
    case pause, resume, turnOn

    @MainActor init(model: AppModel, running: Bool) {
        if model.sessionOn && !model.runnerPaused || running { self = .pause }
        else if model.sessionOn { self = .resume }
        else { self = .turnOn }
    }
}

/// The provider's letter on its coloured tile.
struct ProviderTile: View {
    var provider: ModelProvider
    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 29
    private let baseSize: CGFloat

    init(provider: ModelProvider, size: CGFloat = 29) {
        self.provider = provider
        baseSize = size
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    private var size: CGFloat { min(baseSize * 1.5, max(baseSize * 0.9, scaledSize)) }

    var body: some View {
        Group {
            if let logo = provider.logo {
                Image(logo).renderingMode(.template).resizable().scaledToFit().padding(size * 0.2)
            } else {
                Image(systemName: "server.rack").font(.system(size: size * 0.45, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(Color(hex: provider.tile), in: .circle)
        .accessibilityHidden(true)
    }
}

extension ModelProvider {
    /// The provider's own logo in the asset catalog (Poki/ProviderIcons).
    var logo: String? {
        switch self {
        case .anthropic: "Provider-anthropic"
        case .openai, .chatgpt: "Provider-openai"
        case .gemini: "Provider-googlegemini"
        case .deepseek: "Provider-deepseek"
        case .openrouter: "Provider-openrouter"
        case .custom: nil
        }
    }
}
