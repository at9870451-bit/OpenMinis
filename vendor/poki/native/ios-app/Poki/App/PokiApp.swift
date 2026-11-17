import PokiCore
import SwiftUI
/// The chat is the app (ESP-326): it opens on Poki's conversation. The conversations slide in from the
/// leading edge in narrow windows and stand beside the chat when both columns fit. An outside agent's
/// session, the voice page and a setup step push over the chat. Poki's profile opens from the bear.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @Environment(\.scenePhase) private var scenePhase
    var sessionStore: SessionStore = .shared
    var shortcutStore: HomeShortcutStore = .shared
    @State private var showsSidebar = false
    // Both navigation layouts share the composer while the window changes size.
    @State private var draft = UserDefaults.standard.string(forKey: "pokiDraft") ?? ""

    private static let sidebarWidth: CGFloat = 375
    private static let minimumChatWidth: CGFloat = 375

    /// What is pushed over the chat in a narrow window.
    @State private var home = NavigationPath()
    /// The right-hand column when both columns fit.
    @State private var wide: HomeRoute = .chat
    @State private var threadsOpen = false
    @State private var detailsOpen = false
    /// Poki's card under its picture: the model, the way of asking, Pause or Resume.
    @State private var statusOpen = false
    /// Where the card opens: under Poki's picture on the home page (global points), or under the top bar.
    @State private var cardUnder: CGFloat?
    @State private var detailsPath = NavigationPath()
    /// The first run is up, over everything (`FirstRunGuide`).
    @State private var welcoming = false
    /// A setup step a link opened while the first run is up: it opens there.
    @State private var welcomeLink: SetupStep?
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(AppInterfaceSize.defaultsKey) private var interfaceSize = AppInterfaceSize.system
    @AppStorage("amore.appearance") private var appearance = Appearance.automatic.rawValue
    @Namespace private var profile

    enum HomeRoute: Hashable { case chat, session(String), voice, setup }

    private func show(_ route: HomeRoute) {
        if threadsOpen { withAnimation(ThreadsDrawerMotion.settle) { threadsOpen = false } }
        wide = route
        home = route == .chat ? NavigationPath() : NavigationPath([route])
    }

    private func openDetails(_ items: [any Hashable] = []) {
        var next = NavigationPath()
        for item in items { next.append(item) }
        detailsPath = next
        detailsOpen = true
    }

    private var sessions: some View {
        SessionsView(
            openChat: { show(.chat) },
            openSession: { show(.session($0)) },
            sessionStore: sessionStore
        )
    }

    /// Opens where a setup hint's problem is fixed. A setup step pushes over the chat on iPhone (the
    /// drawer closes to show it); beside the list (iPad) the chat has no stack of its own to push on,
    /// so the step opens in the profile. Everything else opens in the profile.
    private func fix(_ target: SetupIssueHint.Target, split: Bool) {
        switch target {
        case .step(let step):
            if split {
                openDetails([DetailsRoute.connection, step])
            } else {
                if threadsOpen { withAnimation(ThreadsDrawerMotion.settle) { threadsOpen = false } }
                home.append(step)
            }
        case .setup: openDetails([DetailsRoute.connection])
        case .model: openDetails([DetailsRoute.model])
        case .agents: openDetails([DetailsRoute.agents])
        case .updates: openDetails([DetailsRoute.updates])
        }
    }

    private func chatPage(split: Bool) -> some View {
        ChatView(
            sharedDraft: $draft,
            openDetails: { under in
                cardUnder = under
                statusOpen = true
            },
            openVoice: openLiveVoice,
            openSetup: { fix(.setup, split: split) },
            openSetupStep: { fix(.step($0), split: split) },
            openModel: { fix(.model, split: split) },
            openVoiceKey: { openDetails([DetailsRoute.voiceKey]) },
            openThreads: split ? nil : { withAnimation(ThreadsDrawerMotion.settle) { threadsOpen = true } },
            openAgents: { fix(.agents, split: split) },
            openUpdates: { fix(.updates, split: split) },
            sessionStore: sessionStore,
            shortcutStore: shortcutStore
        )
        // The bear stops drawing where it is out of sight: behind the open drawer or the profile over the
        // chat. Poki's card opens beside the picture and leaves it in sight.
        .environment(\.bearCovered, threadsOpen || welcoming || (detailsOpen && !showsSidebar))
    }

    @ViewBuilder private func destination(_ route: HomeRoute, split: Bool) -> some View {
        switch route {
        case .chat:
            chatPage(split: split)
        case .voice:
            // The voice page keeps its own header and blue ground (not redrawn in ESP-340's first batch).
            VoicePage(
                back: split ? nil : { show(.chat) },
                openDetails: {
                    cardUnder = nil
                    statusOpen = true
                },
                openModel: { openDetails([DetailsRoute.model]) },
                select: { target in if target == .chat { show(.chat) } }
            )
            .background(Site.blue.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        case .session(let id):
            SessionView(id: id, back: { show(.chat) })
        case .setup:
            SetupChecklist().toolbar(.visible, for: .navigationBar)
        }
    }

    @ViewBuilder private var mainNavigation: some View {
        if showsSidebar {
            // Two plain stacks side by side, not a NavigationSplitView: its sidebar is a floating panel
            // on iOS 26, set in from the top edge. The left stack is the iPhone's drawer as it is.
            HStack(spacing: 0) {
                NavigationStack { sessions }
                    .frame(width: Self.sidebarWidth)
                Divider().ignoresSafeArea()
                NavigationStack {
                    destination(wide, split: true).id(wide)
                        .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0).toolbar(.visible, for: .navigationBar) }
                }
            }
        } else {
            NavigationStack(path: $home) {
                chatPage(split: false)
                    .navigationDestination(for: HomeRoute.self) { destination($0, split: false) }
                    .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0).toolbar(.visible, for: .navigationBar) }
            }
            .threadsDrawer(isOpen: $threadsOpen, enabled: home.isEmpty) { sessions }
        }
    }

    /// The navigation and Poki's profile, apart from `body`: together with its alerts and handlers the one
    /// expression was more than the compiler would type-check in its time limit (main #145).
    private var navigation: some View {
        mainNavigation
            // Every page's top scroll edge is the system's soft one: the chat, the conversations, and
            // the pages pushed over them under the system's bar.
            .softTopEdge()
            // Settings opens from the bottom of the conversations.
            .environment(\.openPokiSettings, { openDetails() })
            .environment(\.pokiDetailsOpen, detailsOpen)
            .pokiStatusCard(isPresented: $statusOpen, under: cardUnder, leading: showsSidebar ? Self.sidebarWidth + 1 : 0, openModel: { openDetails([DetailsRoute.model]) })
            // Settings covers the whole screen on iPhone (ESP-469: nothing of the chat shows around it), with
            // its Close button; beside the list on iPad it stays a sheet at a page's width (ESP-376).
            .fullScreenCover(isPresented: Binding(get: { detailsOpen && !showsSidebar }, set: { detailsOpen = $0 })) {
                profilePage
            }
            .sheet(isPresented: Binding(get: { detailsOpen && showsSidebar }, set: { detailsOpen = $0 })) {
                profilePage.presentationSizing(.page).presentationDragIndicator(.visible)
            }
            .onChange(of: PokiEntry.shared.pending, initial: true) { takeEntry() }
            .onChange(of: scenePhase) { takeEntry() }
    }

    private var profilePage: some View {
        PokiDetailsView(
            openSetup: {
                var next = NavigationPath()
                next.append(DetailsRoute.connection)
                detailsPath = next
            },
            openSession: { id in
                detailsOpen = false
                openRun(id)
            },
            path: $detailsPath
        )
        // Presented on its own, so it says the edge's style itself rather than counting on the
        // presenting page's.
        .softTopEdge()
        .modifier(AutomationNotices())
    }

    var body: some View {
        Group {
            if let message = model.signer.installMessage {
                UpdateFinishView(message: message, needsReopen: model.signer.needsReopen)
            } else {
                navigation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tint.page.ignoresSafeArea())
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.size.width >= Self.sidebarWidth + 1 + Self.minimumChatWidth
        } action: { showsSidebar = $0 }
        .fullScreenCover(isPresented: $welcoming) { FirstRunGuide(link: $welcomeLink, done: { welcoming = false }) }
        .task { InProcessProbe.shared.startFromLaunchArguments(model: model) }
        .alert(model.connectionAsk.map { AppLocalization.text(LocalizedStringResource("Allow \($0.client) to connect?")) } ?? "",
               isPresented: Binding(get: { model.connectionAsk != nil }, set: { if !$0 { model.answerConnection(false) } }),
               presenting: model.connectionAsk) { _ in
            Button("Don’t Allow", role: .cancel) { model.answerConnection(false) }
            Button("Allow") { model.answerConnection(true) }
        } message: { ask in
            Text("\(ask.client) is signing in through \(ask.connector) with callback destination \(ask.callback). Allow it only if you are connecting it yourself right now. It could then see your screen and act on this iPhone.")
        }
        .alert("Poki Will Close to Finish the Update", isPresented: Binding(get: { model.signer.finishNotice }, set: { if !$0 { model.signer.finishNoticeAnswered() } })) {
            Button("OK") { model.signer.finishNoticeAnswered() }
        } message: {
            Text("The update is almost in. Poki will close to finish it. Open Poki again afterwards.")
        }
        .modifier(AutomationNotices(enabled: !detailsOpen))
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.becameActive(); AskPoki.refresh(); Task { await model.verifyPairing() } } else if phase == .background { model.wentToBackground() }
        }
        // A tap on the Live Activity opens the screen its state is about (ActivityFace.link): the chat,
        // the setup step, or the Activity Log for a problem; `poki://voice` brings the chat to the front.
        .onOpenURL { url in open(link: url) }
        // On the window, not the view: sheets and full-screen covers take it too, and Automatic hands back to iOS.
        .onChange(of: appearance, initial: true) { _, value in
            let style = (Appearance(rawValue: value) ?? .automatic).style
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows where window.overrideUserInterfaceStyle != style {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
        .task(id: interfaceSize) {
            // Apply outside the current layout pass. Coalesce events within roughly one frame,
            // while the preview and the rest of the window inherit the same native category.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows { AppInterfaceSize.apply(interfaceSize, to: window) }
            }
        }
        .task(id: typeSize) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows { AppInterfaceSize.updateNavigationFonts(in: window) }
            }
        }
        .onAppear(perform: openLaunchScreen)
        .task {
            #if DEBUG
            // Development builds: `-pokiVoiceLink "poki://voice?…"` at launch starts a silent test run.
            if let link = UserDefaults.standard.string(forKey: "pokiVoiceLink"), let url = URL(string: link), url.host() == "voice" {
                show(.chat)
                model.voice.openAtLaunch(url)
            }
            #endif
        }
    }

    private func open(link url: URL) {
        AppLog.shared.add("app", "opened by link poki://\(url.host() ?? "")")
        // Pairing is not interrupted: it stays on the pairing step, where the PIN is.
        guard !model.pairingUnderWay else { return }
        // During the first run a pairing file or a setup link opens its step there; nothing else moves.
        if welcoming {
            if let step = model.open(link: url) { welcomeLink = step }
            return
        }
        // A pairing file or a setup link (from Poki Setup on a computer, AirDrop or Files) opens
        // setup at that step, where the result is shown.
        if let step = model.open(link: url) {
            detailsOpen = false
            threadsOpen = false
            if showsSidebar { openDetails([DetailsRoute.connection, step]) } else { home = NavigationPath([step]) }
        } else if url.host() == "setup", !url.absoluteString.contains("relay=") {
            openDetails([DetailsRoute.connection])
        } else if url.host() == "log" {
            openDetails([DetailsRoute.history])
        } else if url.host() == "approvals" {
            openDetails([DetailsRoute.approvals])
        } else if url.host() == "voice" {
            detailsOpen = false
            model.voice.open(url)
            show(.chat)
            // A link never turns on the microphone: it brings the chat to the front, where the message
            // field's button starts a talk, and says what Talk with Poki is missing when it has no key.
            if !model.voice.isOn, !model.voice.canTalkLive { model.voice.keyAsked = true }
        } else {
            detailsOpen = false
            show(.chat)
        }
    }

    /// Talk with Poki: a live conversation starts in the chat, which stays in front (pull request #250's
    /// way). Without a live voice (no OpenAI key, no voice bridge) the message field says so, with the
    /// way to the key in Settings.
    private func openLiveVoice() {
        show(.chat)
        guard model.voice.canTalkLive else { model.voice.keyAsked = true; return }
        if !model.voice.isOn {
            ApprovalNotice.requestPermission()
            model.prepareForTask()
            Task { await model.voice.start() }
        }
    }

    /// The Action Button, Control Center, Shortcuts or Spotlight (PokiEntry), once Poki is in front. A task
    /// under way is shown, not interrupted: Talk starts only when Poki is free. Pairing stays on its step,
    /// and the first run stays up: its record is asked, not `welcoming`, because at a cold launch the
    /// request can be here before the cover is.
    private func takeEntry() {
        guard scenePhase == .active, let request = PokiEntry.shared.take(), !model.pairingUnderWay, !FirstRun.isDue() else { return }
        detailsOpen = false
        statusOpen = false
        if let handoff = AskPoki.liveSessionID { show(.session(handoff)); return }
        show(.chat)
        guard request == .talk, !chat.running, !model.voice.isOn else { return }
        // Without a live voice (no OpenAI key, no voice bridge) Talk opens the message field instead.
        if model.voice.canTalkLive { openLiveVoice() } else { MessageFieldAsk.shared.ask() }
    }

    /// A run from the Activity Log: Poki's own chat or an outside agent's session.
    private func openRun(_ id: String) {
        if let session = SessionStore.shared.session(id), session.kind == .poki {
            if session.id != chat.sessionID { chat.restore(session) }
            show(.chat)
        } else {
            show(.session(id))
        }
    }

    /// `-pokiScreen setup` (connect, debug, activity, details, model, voice…) opens that screen at launch,
    /// for the build's screenshots; `-pokiSetupStep 3` opens setup at that step. The names are the ones
    /// the build's scripts already pass; each opens where that screen lives now.
    private func openLaunchScreen() {
        let defaults = UserDefaults.standard
        if let address = defaults.string(forKey: "pokiVoiceBridge") { _ = model.voice.setBridge(address) }
        // `-pokiHome sessions|paused` (the old home's samples): the conversations, open.
        if defaults.string(forKey: "pokiHome") != nil, defaults.string(forKey: "pokiChat") == nil { threadsOpen = true }
        if FirstRun.isDue() { welcoming = true }
        switch defaults.string(forKey: "pokiScreen") {
        case "chat":
            show(.chat)
        case "home", "threads":
            threadsOpen = true
        case "voice":
            show(.voice)
        case "session":
            if let first = SessionStore.shared.ordered.first(where: { $0.kind == .agent || $0.kind == .handoff }) {
                show(.session(first.id))
            }
        case "setup":
            let step = defaults.integer(forKey: "pokiSetupStep")
            if step > 0 {
                let target = SetupStep.shown[min(step, SetupStep.shown.count) - 1]
                openDetails([DetailsRoute.connection, target])
            } else {
                openDetails([DetailsRoute.connection])
            }
        case "moreSettings", "details", "status":
            // More Settings is gone: its rows are on Poki's profile, by what they are about.
            openDetails()
        case "statusCard":
            cardUnder = nil
            statusOpen = true
        case "hands", "connection":
            openDetails([DetailsRoute.connection])
        case "rules", "approvals":
            openDetails([DetailsRoute.approvals])
        case "health", "advanced":
            openDetails([DetailsRoute.advanced])
        case "connect", "settings", "agents":
            openDetails([DetailsRoute.agents])
        case "debug":
            openDetails([DetailsRoute.advanced, SettingsRoute.diagnostics])
        case "activity":
            openDetails([DetailsRoute.advanced, SettingsRoute.diagnostics, SettingsRoute.activityPreview])
        case "connector":
            if let first = model.identity.secrets.first {
                openDetails([DetailsRoute.agents, SettingsRoute.connector(first)])
            } else {
                openDetails([DetailsRoute.agents])
            }
        case "model":
            openDetails([DetailsRoute.model])
        case "memory":
            openDetails([SettingsRoute.memory])
        case "interfaceSize":
            openDetails([DetailsRoute.interfaceSize])
        case "appearance":
            openDetails([DetailsRoute.appearance])
        case "language":
            openDetails([DetailsRoute.language])
        case "voiceSettings":
            openDetails([DetailsRoute.voice])
        case "conversations":
            openDetails([DetailsRoute.conversations])
        case "updates":
            openDetails([DetailsRoute.updates])
        case "steps":
            openDetails([DetailsRoute.history])
        default: break
        }
    }
}

private struct AutomationNotices: ViewModifier {
    @Environment(AppModel.self) private var model
    var enabled = true

    func body(content: Content) -> some View {
        content
        .alert("Poki Restarts to Turn On", isPresented: Binding(get: { enabled && model.relaunchNotice }, set: { if enabled && !$0 { model.relaunchNotice = false } })) {
            Button("Cancel", role: .cancel) { model.relaunchNotice = false }
            Button("Continue") { model.continueRelaunch() }
        } message: {
            Text("Poki closes by itself so agents can see the screen again. Open Poki again afterwards, from the notification or the Home Screen. It turns on when it opens.")
        }
        .alert("Enter Your Passcode Next", isPresented: Binding(get: { enabled && model.passcodeHeadsUp }, set: { if enabled && !$0 { model.passcodeHeadsUp = false } })) {
            Button("Cancel", role: .cancel) { model.cancelPasscodeHeadsUp() }
            Button("Continue") { model.continueAfterPasscodeHeadsUp() }
        } message: {
            Text(AppModel.passcodeHeadsUpMessage)
        }
    }
}
