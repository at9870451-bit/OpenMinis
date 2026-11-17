//
//  SessionsView.swift
//  Poki
//
//  The conversations list began as GetStream/swiftui-iMessage-clone's channel list (commit df114b4,
//  iMessageClone/ChannelList, by Stefan Blos; the repository has no licence file). For ESP-326 it is a
//  system List: the rows, their swipe actions and their separators are the system's own.
//

import SwiftUI
import UIKit

/// The conversations, in the drawer under the chat (iPhone) and beside it (iPad): Poki's name on
/// top, then one line per conversation, the newest first, and floating over the list the button for a
/// new conversation and the way into Settings.
struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    var openChat: () -> Void
    var openSession: (String) -> Void
    @State private var renaming: SavedSession?
    @State private var newName = ""
    @Environment(\.inThreadsDrawer) private var inDrawer
    @Environment(\.drawerSliding) private var sliding
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var headerIcon = 32.0
    var controlSize = CompactControlMetrics()
    var sessionStore: SessionStore = .shared

    private var store: SessionStore { sessionStore }
    private var sampleHome: String? { UserDefaults.standard.string(forKey: "pokiHome") }

    var body: some View {
        let groups = grouped
        List {
            ForEach(groups, id: \.day) { group in
                if groups.count > 1 { heading(group.day) }
                ForEach(group.sessions) { session in
                    row(session)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            if groups.isEmpty { empty }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        // No scroll bar: the drawer's list lies under the chat, and a drag that slid the drawer and
        // scrolled the list left its bar showing on the chat.
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .background(Tint.sidebar.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .alert("Rename Session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let session = renaming { store.rename(session.id, to: newName) }
                renaming = nil
            }
        }
    }

    private var header: some View {
        let iconSide = min(44, headerIcon)
        return HStack(spacing: 10) {
            // The app's icon, small, rounded in the system's proportion for app icons.
            Image("PokiIcon", bundle: PokiPortResources.bundle).resizable().scaledToFit().frame(width: iconSide, height: iconSide)
                .clipShape(RoundedRectangle(cornerRadius: iconSide * 0.225, style: .continuous))
                .accessibilityHidden(true)
            Text(verbatim: "Poki").font(Prominent.font(size: 28, relativeTo: .title, .bold)).foregroundStyle(Color(.label))
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.horizontal, 32).padding(.top, 8).padding(.bottom, 12)
        .background(Tint.sidebar)
    }

    /// A new conversation in the leading corner, and Settings in the trailing one.
    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                guard !sliding else { return }
                if !chat.running { chat.newConversation() }
                openChat()
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label("New Conversation", systemImage: "square.and.pencil")
                        .labelStyle(PillLabelStyle())
                        .fixedSize()
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .frame(minHeight: controlSize.side)
                    Image(systemName: "square.and.pencil")
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(width: controlSize.side, height: controlSize.side)
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            // Poki's blue, the send button's own.
            .glassSurface(in: Capsule(), tint: Tint.blue, interactive: true)
            .opacity(chat.running ? 0.5 : 1)
            .disabled(chat.running)
            .accessibilityLabel(Text("New Conversation"))
            .accessibilityIdentifier("threads.newChat")
            .accessibilityShowsLargeContentViewer {
                Label("New Conversation", systemImage: "square.and.pencil")
            }
            Spacer(minLength: 0)
            SettingsEntryButton()
                .fixedSize()
        }
        .glassGroup(spacing: 8)
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4)
        .background {
            // Keep large text and status marks from showing through the floating controls.
            if typeSize.isAccessibilitySize { Tint.sidebar.ignoresSafeArea(edges: .bottom) }
        }
    }

    private func heading(_ day: Day) -> some View {
        Text(day.title).font(.footnote.weight(.medium)).foregroundStyle(Tint.sidebarHeading)
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 6)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)
    }

    /// The conversation on screen in the chat, marked as the selected row.
    private func current(_ session: SavedSession) -> Bool {
        session.kind == .poki && session.id == chat.sessionID && sampleHome == nil
    }

    /// The row's own ground, the drawer's colour (the selected row's soft blue over it): a long press
    /// lifts a clean card, not the row's words over a grey shadow.
    private func ground(_ session: SavedSession) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Tint.sidebar)
            .overlay { if current(session) { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Tint.sidebarSelected) } }
    }

    /// The app it worked in: for the chat's own task under way, the app it is in now.
    private func app(_ session: SavedSession) -> String? {
        if session.live, session.id == chat.sessionID, let now = chat.taskApp, !now.isEmpty { return now }
        return session.app
    }


    /// What its last run ended in, when that was not well: failed or stopped. Nothing for a conversation
    /// still running, one that finished, or one that has not run.
    private func lastRunProblem(_ session: SavedSession) -> SavedSession.Outcome? {
        guard !session.live, let outcome = session.outcome, outcome != .done else { return nil }
        return outcome
    }

    /// One conversation: its app's small icon and its name, an amber dot at the end while a step waits for
    /// you, or else a quiet mark when its last run failed or was stopped. Your turn comes first: it is the
    /// one thing in the list to act on.
    private func row(_ session: SavedSession) -> some View {
        let needs = needsYou(session)
        let trouble = needs ? nil : lastRunProblem(session)
        let app = app(session)
        return Button { open(session) } label: {
            HStack(spacing: 12) {
                ConversationTitle(session: session, app: app)
                Spacer(minLength: 8)
                if needs { Circle().fill(Tint.amber).frame(width: 8, height: 8).accessibilityHidden(true) }
                else if let trouble {
                    Image(systemName: trouble == .failed ? "exclamationmark.circle.fill" : "pause.circle.fill")
                        .font(.subheadline).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(trouble == .failed ? Tint.red : Color.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 48)
            .background(ground(session))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // A long press lifts the row's own rounded shape, not the list's whole width, so the lifted row
        // and its menu stay inside the drawer rather than over the chat beside it.
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        // The icon says which app the conversation worked in; VoiceOver says its name, as the iPhone names it.
        .accessibilityValue(Text(verbatim: [AppName.display(app), needs ? AppLocalization.text(LocalizedStringResource("Needs your attention")) : nil,
                                                         trouble.map { $0 == .failed ? AppLocalization.text(LocalizedStringResource("Failed")) : AppLocalization.text(LocalizedStringResource("Stopped")) }]
            .compactMap { $0 }.joined(separator: ", ")))
        // In the drawer a sideways drag closes it, so Rename, Archive and Delete are only in the menu there.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !inDrawer {
                if !session.live, sampleHome == nil {
                    Button("Delete", systemImage: "trash", role: .destructive) { store.delete(session.id) }
                }
                if !session.live, sampleHome == nil {
                    Button("Archive", systemImage: "archivebox") { store.archive(session.id) }.tint(Tint.blue)
                }
                Button("Rename", systemImage: "pencil") { startRename(session) }
            }
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { startRename(session) }
            if !session.live, sampleHome == nil {
                Button("Archive", systemImage: "archivebox") { store.archive(session.id) }
                Button("Delete", systemImage: "trash", role: .destructive) { store.delete(session.id) }
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView("No Conversations Yet", systemImage: "bubble.left.and.bubble.right")
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private var shown: [SavedSession] {
        if sampleHome == "paused" { return [] }
        return sampleHome == "sessions" ? Self.sampleSessions : store.listed
    }

    /// When a conversation last moved, for the faint headings between the days.
    enum Day: CaseIterable {
        case today, yesterday, earlier

        var title: String {
            switch self {
            case .today: AppLocalization.text(LocalizedStringResource("Today"))
            case .yesterday: AppLocalization.text(LocalizedStringResource("Yesterday"))
            case .earlier: AppLocalization.text(LocalizedStringResource("Earlier"))
            }
        }

        static func of(_ session: SavedSession) -> Day {
            let calendar = Calendar.current
            if session.live || calendar.isDateInToday(session.updated) { return .today }
            return calendar.isDateInYesterday(session.updated) ? .yesterday : .earlier
        }
    }

    /// The conversations by day, each day keeping the store's order.
    private var grouped: [(day: Day, sessions: [SavedSession])] {
        let all = shown
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        var today: [SavedSession] = []
        var yesterday: [SavedSession] = []
        var earlier: [SavedSession] = []
        for session in all {
            if session.live || session.updated >= todayStart {
                today.append(session)
            } else if session.updated >= yesterdayStart {
                yesterday.append(session)
            } else {
                earlier.append(session)
            }
        }
        return [(.today, today), (.yesterday, yesterday), (.earlier, earlier)].compactMap { $0.1.isEmpty ? nil : $0 }
    }

    /// Held by a step that waits for the owner: its own last plan says so, or it is the conversation
    /// the waiting approval or hand-over belongs to.
    private func needsYou(_ session: SavedSession) -> Bool {
        if session.needsYou { return true }
        guard session.live, session.id == chat.sessionID || session.id == store.activeSessionID else { return false }
        return !model.approvals.isEmpty || model.handoffText != nil
    }
    private static var sampleSessions: [SavedSession] {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86400)
        return [
            SavedSession(
                id: "sample-1",
                kind: .handoff,
                client: "Claude Code",
                title: "Claude → Poki",
                started: now,
                updated: now,
                live: true,
                outcome: nil,
                entries: [ChatEntry(.poki(AppLocalization.text(LocalizedStringResource("Needs your OK: send “On my way” to Mom")))), ChatEntry(.note(.waiting))],
                calls: [],
                customName: "Claude → Poki"
            ),
            SavedSession(
                id: "sample-2",
                kind: .poki,
                client: nil,
                title: AppLocalization.text(LocalizedStringResource("What iOS version is this?")),
                started: now,
                updated: now,
                live: false,
                outcome: .done,
                entries: [ChatEntry(.poki(AppLocalization.text(LocalizedStringResource("It’s iOS 27.3. Want me to check for an update?"))))],
                calls: []
            ),
            SavedSession(
                id: "sample-3",
                kind: .agent,
                client: "Codex",
                title: "Codex",
                started: now,
                updated: now,
                live: false,
                outcome: .done,
                entries: [ChatEntry(.poki(AppLocalization.text(LocalizedStringResource("Opened Photos and tapped “Albums”. Done in 3 steps."))))],
                calls: [],
                customName: "Codex"
            ),
            SavedSession(
                id: "sample-4",
                kind: .poki,
                client: nil,
                title: AppLocalization.text(LocalizedStringResource("Order oat milk again")),
                started: yesterday,
                updated: yesterday,
                live: false,
                outcome: .done,
                entries: [ChatEntry(.poki(AppLocalization.text(LocalizedStringResource("Ran your routine: same order as last week, $4.99."))))],
                calls: []
            ),
            SavedSession(
                id: "sample-5",
                kind: .agent,
                client: "Claude Code",
                title: "Claude Code",
                started: yesterday,
                updated: yesterday,
                live: false,
                outcome: .done,
                entries: [ChatEntry(.poki(AppLocalization.text(LocalizedStringResource("Your turn, enter your Apple Account password"))))],
                calls: [],
                customName: "Claude Code"
            ),
        ]
    }


    private func startRename(_ session: SavedSession) {
        newName = session.name
        renaming = session
    }

    private func open(_ session: SavedSession) {
        guard !sliding else { return }
        if session.kind == .poki {
            if session.id != chat.sessionID, sampleHome == nil { chat.restore(session) }
            openChat()
        } else {
            openSession(session.id)
        }
    }
}

/// A label in a pill: the icon and the title side by side, a little apart.
private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.icon; configuration.title }
    }
}

extension SavedSession {
    /// Live, and its task is held by a step that waits for the owner's answer.
    var needsYou: Bool {
        guard live else { return false }
        for entry in entries.reversed() {
            switch entry.kind {
            case .plan(let steps): return steps.contains { $0.state == .waiting }
            case .note(.waiting): return true
            case .note(.approval(let note)): return note.state == .asking && !note.byModel
            case .you, .request: return false
            default: continue
            }
        }
        return false
    }
}

extension View {
    /// The line under the title (iOS 26's navigation subtitle); nothing before iOS 26.
    @ViewBuilder func sessionSubtitle(_ text: String) -> some View {
        if #available(iOS 26.0, *), !text.isEmpty { navigationSubtitle(Text(verbatim: text)) } else { self }
    }
}

/// A conversation as the lists show it (the drawer, Settings > Conversations): the small icon of the app
/// it worked in, only once the icon is at hand so a row without one starts where the others' names do,
/// then its name, a step larger than the body, as a list of names only reads well.
struct ConversationTitle: View {
    var session: SavedSession
    /// The app it worked in, when the row knows better than what is saved (a task under way).
    var app: String? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var nameSize: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var iconSize = 22.0

    var body: some View {
        let app = app ?? session.app
        HStack(spacing: 12) {
            if let app, AppIconStore.shared.icon(app, dark: scheme == .dark) != nil { AppIconView(app: app, size: min(34, iconSize)) }
            Text(verbatim: session.name).font(.system(size: nameSize)).foregroundStyle(Color(.label))
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
        }
        .task(id: app) { if let app { await AppIconStore.shared.load(app) } }
    }
}

/// What a row shows on its leading side: the icon of the app the conversation worked in, with the
/// outside agent's badge on its corner for an agent's session or hand-off. Without an app icon, an
/// agent's badge, or for a chat with Poki the one placeholder tile.
struct SessionAvatar: View {
    var session: SavedSession
    /// The app it worked in, when the row knows better than what is saved (a task under way).
    var app: String? = nil
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let app = app ?? session.app
        let agent = session.kind == .agent || session.kind == .handoff
        // An agent's session shows the app only once its icon is at hand; a chat with Poki shows the
        // placeholder while the icon is fetched.
        let icon = app.flatMap { name in agent ? (AppIconStore.shared.icon(name, dark: scheme == .dark) != nil ? name : nil) : name }
        ZStack(alignment: .bottomTrailing) {
            if let icon {
                AppIconView(app: icon, size: size)
            } else if agent {
                AgentBadge(name: session.client ?? "", size: size)
            } else {
                tile(session.kind == .voice ? "waveform" : "bubble.left")
            }
            if agent, icon != nil {
                // Whose session it is, on the app's corner.
                AgentBadge(name: session.client ?? "", size: size * 0.46, edge: true).offset(x: 4, y: 4)
            } else if session.kind == .handoff {
                PokiAvatar(size: size * 0.46)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.13, style: .continuous).strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                    .offset(x: 4, y: 4)
            }
        }
        .frame(width: size, height: size)
        .task(id: app) { if let app { await AppIconStore.shared.load(app) } }
        .accessibilityHidden(true)
    }

    /// The placeholder: the same icon shape as an app's, on the system's quiet fill.
    private func tile(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(Color(.secondaryLabel))
            .frame(width: size, height: size)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// An outside agent's badge: its provider's logo, or its initials (see `CallerBadge`). In dark mode a
/// dark badge (OpenAI's is black) turns light, so it never is a black disc on a dark panel.
struct AgentBadge: View {
    var name: String
    var size: CGFloat
    /// On another icon's corner: a ring in the page's colour sets it apart from the icon.
    var edge = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        CallerBadge(name: name, size: size, lifted: scheme == .dark)
            .overlay(Circle().strokeBorder(edge ? Color(.systemBackground) : Tint.ring, lineWidth: edge ? 1.5 : 1))
            .accessibilityHidden(true)
    }
}

/// The boards' guest thread (02b) for the screenshots (`-pokiHome sessions`, the first row): an
/// outside agent borrowing Poki's hands, at step 2 of 3. Nothing runs.
private enum GuestSample {
    static var isOn: Bool { UserDefaults.standard.string(forKey: "pokiHome") != nil }
    static var plan: [String] { [AppLocalization.text(LocalizedStringResource("Open TestFlight")), AppLocalization.text(LocalizedStringResource("Find Poki")), AppLocalization.text(LocalizedStringResource("Tap Update"))] }
    static let entries: [ChatEntry] = {
        var steps = ChatEntry(.plan([PlanStep(plan[0], state: .done), PlanStep(plan[1])]))
        steps.at = Date().addingTimeInterval(-42)
        steps.title = AppLocalization.text(LocalizedStringResource("Install the newest build"))
        return [ChatEntry(.request(AppLocalization.text(LocalizedStringResource("Open TestFlight and install the newest Poki build.")), from: "Claude Code")), steps]
    }()
}

/// An outside agent's session or hand-off as a conversation: the agent's own steps as grey lines, its
/// request and Poki's answer as bubbles. Live while the session runs.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    var id: String
    var back: () -> Void

    @State private var renaming = false
    @State private var newName = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let session = SessionStore.shared.session(id)
        let running = AskPoki.live(id)
        let sample = GuestSample.isOn && id == "sample-1"
        let live = sample || (running?.running ?? (session?.live ?? false))
        // The live task's card shows what Poki last saw of the screen, as in the chat.
        let shot: Image? = sample ? SampleShot.image(dark: scheme == .dark) : live ? model.lastShot.map { Image(uiImage: $0) } : nil
        ChatTranscript(entries: sample ? GuestSample.entries : (running?.entries ?? session?.entries) ?? [],
                       typing: running?.awaitingModel ?? false, canRetry: false, retry: {}, session: id,
                       live: live, waiting: live && !model.approvals.isEmpty, handedOver: live && model.handoffText != nil,
                       plan: sample ? GuestSample.plan : running?.planSteps, app: sample ? "TestFlight" : running.map(\.taskApp) ?? model.currentApp, shot: shot) { EmptyView() }
        // The step that waits for you and Stop sit on the bottom edge, so the conversation scrolls under
        // them and the bars keep their scroll-edge behaviour (as in the chat).
        .bottomBar {
            let asking = session?.live == true && (!model.approvals.isEmpty || model.handoffText != nil)
            if asking || running != nil || sample {
                VStack(spacing: 8) {
                    if session?.live == true, let approval = model.approvals.first {
                        ApprovalAskCard(title: approval.question, expires: approval.expires,
                                        answer: { approved in model.resolve(approval, approved: approved) })
                    } else if session?.live == true, let text = model.handoffText {
                        TurnCard(text: AppLocalization.bundle.localizedString(forKey: text, value: text, table: nil), done: model.handoffDoneInApp)
                    }
                    if running != nil || sample {
                        // Said where Stop is, and only there: the words promise what the button does.
                        Text("A guest is borrowing Poki’s hands. You can tap Stop anytime.")
                            .font(.footnote).foregroundStyle(Color(.secondaryLabel)).multilineTextAlignment(.center)
                        Button("Stop Poki", systemImage: "stop.fill") { AskPoki.live(id)?.stop() }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(Tint.red)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: 720)
            }
        }
        // The chat's own page colour, so Poki's white bubbles stand on it as they do there.
        .background(Tint.page.ignoresSafeArea())
        // The session's name is the title; its menu renames it (the system title menu).
        .navigationTitle(Text(verbatim: session?.name ?? (sample ? "Claude Code" : "")))
        .navigationBarTitleDisplayMode(.inline)
        .sessionSubtitle(caption(session))
        .toolbarTitleMenu {
            Button("Rename", systemImage: "pencil") { newName = session?.name ?? ""; renaming = true }
        }
        .alert("Rename Session", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { SessionStore.shared.rename(id, to: newName) }
        }
    }

    private func caption(_ session: SavedSession?) -> String {
        guard let session else { return "" }
        switch session.kind {
        case .agent: return AppLocalization.text(LocalizedStringResource("Over MCP, \(ChatTime.row(session.started))"))
        case .handoff: return AppLocalization.text(LocalizedStringResource("Handed to Poki, \(ChatTime.row(session.started))"))
        case .voice: return AppLocalization.text(LocalizedStringResource("Voice, \(ChatTime.row(session.started))"))
        case .poki: return ""
        }
    }
}
