//
//  ContentView+Layout.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  ContentView, layout: `splitLayout` (NavigationSplitView for iPad / wide
//  windows), `stackLayout` (NavigationStack for iPhone / narrow windows) and
//  the split view's `detailView`. `body` picks one by width.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

/// Date buckets hold IDs; the snapshot resolves sessions only for visible rows.
struct DrawerSessionGroup: Identifiable {
    let id: String
    let label: String
    let sessionIDs: [String]
}


private let shareLog = AppLogger(category: "Share")
private let draftLog = AppLogger(category: "DraftSession")

/// Local execution history. Reads `AgentJobRegistry` directly — these are the
/// same jobs the agent loop and the scheduler create, not placeholder rows.
struct TasksCenterView: View {
    @ObservedObject private var registry = AgentJobRegistry.shared

    private var jobs: [AgentJob] {
        registry.jobs.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            if jobs.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AppLocalized("No tasks yet"))
                            .font(.headline)
                        Text(AppLocalized("Sub-agent runs and scheduled jobs show up here as soon as they start."))
                            .font(.footnote)
                            .foregroundStyle(PokiTheme.secondaryText)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Section(AppLocalized("Recent runs")) {
                    ForEach(jobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.title)
                                .font(.body)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text(job.state.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(stateColor(job.state))
                                if job.firedCount > 0 {
                                    Text("· \(job.firedCount)x")
                                        .font(.caption)
                                        .foregroundStyle(PokiTheme.secondaryText)
                                }
                                if let next = job.nextFireAt {
                                    Text("· \(next.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(PokiTheme.secondaryText)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PokiTheme.background)
        .pokiScreen()
        .navigationTitle(AppLocalized("Tasks"))
    }

    private func stateColor(_ state: AgentJobState) -> Color {
        switch state {
        case .running:            return PokiTheme.tagText
        case .done:               return PokiTheme.green
        case .failed, .timeout:   return PokiTheme.danger
        case .cancelled:          return PokiTheme.secondaryText
        case .pending:            return PokiTheme.amber
        }
    }
}

extension ContentView {
    /// Chat tab, kept mounted across tab switches so a conversation is never
    /// torn down and reloaded just because the user looked at Memory.
    @ViewBuilder
    var chatStack: some View {
            NavigationStack(path: $navigationPath) {
                Group {
                    if let id = homeSessionId {
                        AIChatView(sessionId: id)
                            .id(id)
                    } else {
                        AIChatView(sessionId: nil, draftId: homeDraftId)
                            .id(homeDraftId)
                    }
                }
                .navigationDestination(for: String.self) { id in
                    AIChatView(sessionId: Self.isNewSessionId(id) ? nil : id,
                               draftId: Self.isNewSessionId(id) ? id : nil,
                               initialGroupId: Self.extractGroupId(from: id))
                        .id(id)
                }

            }
    }

    /// Tab roots under the drawer. Chat stays in the hierarchy (opacity 0 when
    /// inactive) so its scroll position and stream survive a tab switch.
    @ViewBuilder
    // MARK: - Split Layout (iPad / wide window)

    var splitLayout: some View {
        // [T-ios-gh29-font-scale-split-column] App-base font scale for the iPad
        // split view. `appFontScale()` is environment-based (`.dynamicTypeSize`),
        // and SwiftUI environment does NOT bridge across NavigationSplitView's
        // per-column UIHostingController boundaries — applying it on the
        // container (the previous GH#29 fix) left the column contents unscaled,
        // which is why the font slider still didn't take effect on iPad/Mac.
        // Apply it INSIDE each column instead so the modifier lands on the
        // hosting boundary's inner side and reaches the content. The earlier
        // session-switch / tap lag is a separate issue (ChatSession Array `==`
        // in SwiftUI's transaction flush; an A/B test confirmed the font
        // injection is not its cause), so per-column injection is safe here.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sessionList(useNavigationLinks: false)
                .appFontScale()
        } detail: {
            detailView
                .appFontScale()
        }
    }

    // MARK: - Stack Layout (iPhone / narrow window)

    var stackLayout: some View {
        GeometryReader { geometry in
            let drawerWidth = PokiDrawerMetrics.travel(for: geometry.size.width)
            let progress = min(1, max(0, drawerProgress))
            ZStack(alignment: .leading) {
                PokiTheme.sidebar.ignoresSafeArea()
                historyDrawer
                    .frame(width: drawerWidth, height: geometry.size.height)
                    .opacity(drawerReduceMotion ? progress : 1)
                    .allowsHitTesting(showHistoryDrawer && !drawerIsSliding)
                    .accessibilityHidden(!showHistoryDrawer)
                    .zIndex(drawerReduceMotion ? 2 : 0)

                PokiDrawerConversationPanel(
                    containerSize: geometry.size,
                    safeAreaInsets: geometry.safeAreaInsets,
                    drawerWidth: drawerWidth,
                    progress: progress,
                    presentationActive: drawerPresentationActive,
                    reduceMotion: drawerReduceMotion,
                    onClose: { snapDrawer(open: false) }
                ) {
                    chatStack
                        .background {
                            EdgeSwipeCatcher(enabled: !showHistoryDrawer && runtimePage == nil && activeToolSheet == nil,
                                onProgress: { fraction in
                                    drawerCleanupTask?.cancel()
                                    drawerPresentationActive = true
                                    drawerIsSliding = true
                                    drawerDragProgress = fraction
                                }, onEnd: { fraction, velocity in
                                    drawerIsSliding = false
                                    let projected = fraction + velocity / max(1, drawerWidth) / 6
                                    snapDrawer(open: projected > 0.45)
                                })
                                .allowsHitTesting(false)
                        }
                }
                .zIndex(1)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 16, coordinateSpace: .global)
                    .updating($drawerGestureActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard showHistoryDrawer || drawerCloseStart != nil else { return }
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                        if drawerCloseStart == nil {
                            guard value.translation.width < 0 else { return }
                            drawerCloseStart = drawerProgress
                        }
                        drawerIsSliding = true
                        let fraction = (drawerCloseStart ?? 1) + value.translation.width / drawerWidth
                        drawerDragProgress = min(1, max(0, fraction))
                    }
                    .onEnded { value in
                        guard let start = drawerCloseStart else { return }
                        drawerCloseStart = nil
                        drawerIsSliding = false
                        let projected = start + value.predictedEndTranslation.width / drawerWidth
                        snapDrawer(open: projected > 0.55)
                    },
                including: showHistoryDrawer ? .all : .subviews
            )
            .onChange(of: drawerGestureActive) { active in
                if !active, drawerCloseStart != nil { snapDrawer(open: showHistoryDrawer) }
            }
            .background(PokiTheme.sidebar.ignoresSafeArea())
            .accessibilityAction(.escape) {
                if showHistoryDrawer { snapDrawer(open: false) }
            }
        }
        .sheet(item: $runtimePage) { page in
            NavigationStack {
                runtimeDestination(page)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(AppLocalized("Done")) { runtimePage = nil }
                        }
                    }
            }
        }
    }
    /// Live drawer position: follows the finger while dragging, otherwise
    /// snaps to 0 (closed) or 1 (open).
    var drawerProgress: CGFloat {
        drawerDragProgress ?? (showHistoryDrawer ? 1 : 0)
    }

    func snapDrawer(open: Bool) {
        drawerCleanupTask?.cancel()
        drawerSearchFocused = false
        if open {
            drawerPresentationActive = true
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        drawerCloseStart = nil
        drawerIsSliding = false
        withAnimation(drawerReduceMotion ? .easeOut(duration: 0.22)
                      : .interactiveSpring(response: 0.42, dampingFraction: 0.88)) {
            drawerDragProgress = nil
            showHistoryDrawer = open
        }
        if !open {
            drawerCleanupTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard !Task.isCancelled, !showHistoryDrawer, drawerDragProgress == nil else { return }
                drawerPresentationActive = false
            }
        }
    }

    // MARK: - ChatGPT-style solid history drawer

    private var historyDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            drawerHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    AmoreSidebarShortcuts(interactionEnabled: !drawerIsSliding) { shortcut in
                        openDrawerShortcut(shortcut)
                    }

                    drawerHistoryHeading
                    if drawerHistory.groups.isEmpty {
                        Text(drawerHistory.isSearching ? AppLocalized("No results") :
                             (showArchivedDrawerSessions ? AppLocalized("No archived chats") : AppLocalized("No conversations yet")))
                            .font(.subheadline)
                            .foregroundStyle(PokiTheme.sidebarHeading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                    }
                    ForEach(drawerHistory.groups) { group in
                        Text(group.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PokiTheme.sidebarHeading)
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.sessionIDs, id: \.self) { id in
                            if let session = drawerHistory.sessionsByID[id] {
                                drawerSessionRow(session)
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            drawerAccountFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(PokiTheme.sidebarInk)
        .tint(PokiTheme.sidebarInk)
        .background(PokiTheme.sidebar.ignoresSafeArea())
        .onAppear { rebuildDrawerGroups() }
        .onChange(of: DrawerSessionSource(sessions: sessions)) { _ in rebuildDrawerGroups() }
        .onChange(of: drawerSearch) { _ in rebuildDrawerGroups() }
        .onChange(of: showArchivedDrawerSessions) { _ in rebuildDrawerGroups() }
        .onChange(of: archivedDrawerSessionIDs) { _ in rebuildDrawerGroups() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in rebuildDrawerGroups() }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in rebuildDrawerGroups() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in rebuildDrawerGroups() }
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            let name = SoulStore.cachedMetadata.name
            soulName = name.isEmpty ? AppLocalized("Account") : name
        }
    }

    private var drawerHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(PokiTheme.sidebarHeading)
                        .accessibilityHidden(true)
                    TextField(AppLocalized("Search chats"), text: $drawerSearch,
                              prompt: Text(AppLocalized("Search chats")).foregroundStyle(PokiTheme.sidebarHeading))
                        .font(.body)
                        .textFieldStyle(.plain)
                        .focused($drawerSearchFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .onSubmit { drawerSearchFocused = false }
                        .accessibilityLabel(AppLocalized("Search chats"))
                    if !drawerSearch.isEmpty {
                        Button { drawerSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(PokiTheme.sidebarHeading)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppLocalized("Clear search"))
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, drawerSearch.isEmpty ? 12 : 0)
                .frame(minHeight: 44)
                .background(PokiTheme.sidebarControl, in: RoundedRectangle(cornerRadius: 12))
                Button { snapDrawer(open: false) } label: {
                    Image(systemName: "sidebar.left")
                        .font(.body)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(ChatHistoryButtonStyle())
                .accessibilityLabel(AppLocalized("Close conversations"))
            }
        }
        .foregroundStyle(PokiTheme.sidebarInk)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var drawerHistoryHeading: some View {
        HStack {
            Text(showArchivedDrawerSessions ? AppLocalized("Archived") : AppLocalized("Recent"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PokiTheme.sidebarHeading)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button { showArchivedDrawerSessions.toggle() } label: {
                Image(systemName: showArchivedDrawerSessions ? "bubble.left.and.bubble.right" : "archivebox")
                    .font(.subheadline)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(ChatHistoryButtonStyle())
            .accessibilityLabel(showArchivedDrawerSessions ? AppLocalized("Show recent chats") : AppLocalized("Show archived chats"))
        }
        .foregroundStyle(PokiTheme.sidebarHeading)
        .padding(.leading, 20)
        .padding(.trailing, 12)
    }

    /// Kept outside ScrollView: the primary action and Settings never scroll
    /// away with history. No account menu, duplicate top action, or bottom Tab.
    private var drawerAccountFooter: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                guard !drawerIsSliding else { return }
                drawerSearchFocused = false
                startHomeChat()
                snapDrawer(open: false)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.body.weight(.semibold))
                    Text(AmoreSidebarText.newConversationShort)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                    .padding(.horizontal, 14)
                    .frame(width: 132, height: 52)
                    .amoreDrawerFooterGlass(in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AmoreSidebarText.newConversation)
            .accessibilityIdentifier("amore.sidebar.newConversation")

            Spacer(minLength: 8)

            Button {
                guard !drawerIsSliding else { return }
                drawerSearchFocused = false
                snapDrawer(open: false)
                DeepLinkCoordinator.shared.pendingSettingsTarget = .home
                activeToolSheet = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3.weight(.medium))
                    .frame(width: 52, height: 52)
                    .amoreDrawerFooterGlass(in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalized("Settings"))
            .accessibilityIdentifier("amore.sidebar.settings")
        }
        .disabled(drawerIsSliding)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(PokiTheme.sidebar)
    }

    // MARK: Drawer cache (event-driven, never evaluated by a drag frame)

    private func rebuildDrawerGroups() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let query = drawerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        var buckets = Array(repeating: [String](), count: 5)
        var byID: [String: ChatSession] = [:]
        byID.reserveCapacity(sessions.count)
        for session in sessions {
            guard archivedDrawerSessionIDs.contains(session.id) == showArchivedDrawerSessions else { continue }
            if !query.isEmpty,
               !(session.title ?? "").localizedCaseInsensitiveContains(query),
               !(session.lastMessage ?? "").localizedCaseInsensitiveContains(query) { continue }
            let bucket: Int
            if session.isPinned { bucket = 0 }
            else if session.updatedAt >= today { bucket = 1 }
            else if session.updatedAt >= yesterday { bucket = 2 }
            else if session.updatedAt >= week { bucket = 3 }
            else { bucket = 4 }
            buckets[bucket].append(session.id)
            byID[session.id] = session
        }
        let headings = [AppLocalized("Pinned"), AppLocalized("Today"), AppLocalized("Yesterday"),
                        AppLocalized("Last 7 Days"), AppLocalized("Earlier")]
        let ids = ["pinned", "today", "yesterday", "week", "earlier"]
        let groups = buckets.indices.compactMap { index -> DrawerSessionGroup? in
            guard !buckets[index].isEmpty else { return nil }
            return DrawerSessionGroup(id: ids[index], label: headings[index], sessionIDs: buckets[index])
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drawerHistory = DrawerHistorySnapshot(groups: groups, sessionsByID: byID, isSearching: !query.isEmpty)
        }
    }

    // MARK: Drawer pieces

    private func drawerNavRow(_ page: RuntimePage) -> some View {
        let shortcut = AmoreSidebarShortcut(runtimePage: page)
        return Button {
            openDrawerShortcut(shortcut)
        } label: {
            DrawerShortcutLabel(title: shortcut.title, symbol: shortcut.symbol, accent: .primary)
        }
        .buttonStyle(ChatHistoryButtonStyle())
        .accessibilityLabel(shortcut.title)
    }

    private var localBotNavRow: some View { drawerNavRow(.localBot) }

    /// Reuse real runtime destinations and the in-process settings coordinator.
    /// Missing coordinator cases go through the shared settings-router contract,
    /// never UIApplication.open(minis://...) or a placeholder action.
    private func openDrawerShortcut(_ shortcut: AmoreSidebarShortcut) {
        guard !drawerIsSliding, shortcut.isAvailable else { return }
        drawerSearchFocused = false
        snapDrawer(open: false)
        switch shortcut.destination {
        case .runtime(let page):
            runtimePage = page
        case .settings(let target):
            DeepLinkCoordinator.shared.pendingSettingsTarget = target
            activeToolSheet = .settings
        case .terminal:
            showTerminal = true
        case .settingsNotification(let destination):
            AmoreSettingsShortcutRouter.shared.open(destination)
            activeToolSheet = .settings
            NotificationCenter.default.post(
                name: .amoreOpenSidebarDestination,
                object: destination,
                userInfo: ["destination": destination]
            )
        }
    }

    @ViewBuilder
    private func drawerSessionRow(_ session: ChatSession) -> some View {
        let selected = homeSessionId == session.id
        Button {
            guard !drawerIsSliding else { return }
            snapDrawer(open: false)
            navigationPath = NavigationPath()
            currentStackSessionId = nil
            homeSessionId = session.id
        } label: {
            ChatHistorySessionLabel(
                title: session.title?.isEmpty == false ? (session.title ?? AppLocalized("New Chat")) : AppLocalized("New Chat"),
                selected: selected
            )
        }
        .buttonStyle(ChatHistoryButtonStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .padding(.horizontal, 8)
        .contextMenu {
            SessionContextMenu(
                key: MenuKey(sid: session.id, pinned: session.isPinned, title: session.title, filed: session.isFiled, archived: showArchivedDrawerSessions),
                actions: menuActions
            )
            .equatable()
        }
    }

    @ViewBuilder
    private func runtimeDestination(_ page: RuntimePage) -> some View {
        switch page {
        case .tools:     ToolsSettingsView()
        case .subAgents: HelperSettingsView()
        case .skills:    SkillsManagementView()
        case .memory:    MemoryManagementView()
        case .localBot:  LocalBotDeploymentView(showTerminal: $showTerminal, localBotCommand: $localBotCommand)
        case .soul:      SoulSettingsView()
        case .rootfs:    RootfsManagementView()
        }
    }

    func startHomeChat() {
        homeSessionId = nil
        homeDraftId = "__new__" + UUID().uuidString
        navigationPath = NavigationPath()
        currentStackSessionId = nil
        snapDrawer(open: false)
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        if let id = selectedSessionId {
            // Draft sessions always pass nil — the VM creates a real session internally
            // on first send. The .id() ensures each draft gets its own View lifecycle.
            let isDraft = Self.isNewSessionId(id)
            let effectiveId: String? = isDraft ? nil : id
            AIChatView(sessionId: effectiveId, draftId: isDraft ? id : nil, initialGroupId: Self.extractGroupId(from: id))
                .id(id)
                .onAppear {
                    draftLog.info("🔑DRAFT detailView APPEAR id=\(id) effectiveId=\(effectiveId ?? "nil") isDraft=\(isDraft)")
                }
                .onDisappear {
                    draftLog.info("🔑DRAFT detailView DISAPPEAR id=\(id)")
                }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 48))
                    .foregroundStyle(PokiTheme.secondaryText)
                Text("No Conversation Selected")
                    .font(.title3.bold())
                Text("Select a conversation or start a new one")
                    .font(.subheadline)
                    .foregroundStyle(PokiTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pokiScreen()
        }
    }
}
