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

/// One date bucket in the sidebar. A struct (not a tuple) so it can live in
/// `@State` and be compared cheaply by SwiftUI.
struct DrawerSessionGroup: Identifiable, Equatable {
    let label: String
    let sessions: [ChatSession]
    var id: String { label }
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
        case .done:               return .green
        case .failed, .timeout:   return PokiTheme.danger
        case .cancelled:          return PokiTheme.secondaryText
        case .pending:            return .orange
        }
    }
}

extension ContentView {
    /// Chat tab, kept mounted across tab switches so a conversation is never
    /// torn down and reloaded just because the user looked at Memory.
    @ViewBuilder
    var chatStack: some View {
            NavigationStack {
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
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            startHomeChat()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel(Text("New Chat"))
                    }
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
            let radius = min(1, progress / 0.15) * max(34, max(geometry.safeAreaInsets.top, geometry.safeAreaInsets.bottom))
            ZStack(alignment: .leading) {
                PokiTheme.sidebar.ignoresSafeArea()
                historyDrawer
                    .frame(width: drawerWidth, height: geometry.size.height)
                    .offset(x: drawerReduceMotion ? 0 : -24 * (1 - progress))
                    .opacity(drawerReduceMotion ? progress : (progress > 0 ? 0.55 + 0.45 * progress : 0))
                    .allowsHitTesting(showHistoryDrawer && !drawerIsSliding)
                    .accessibilityHidden(!showHistoryDrawer)
                    .zIndex(drawerReduceMotion ? 2 : 0)

                chatStack
                    .accessibilityHidden(showHistoryDrawer)
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
                    .overlay {
                        if drawerPresentationActive {
                            PokiConversationCover(progress: progress) { snapDrawer(open: false) }
                                .ignoresSafeArea()
                        }
                    }
                    .overlay {
                        if drawerPresentationActive && !drawerReduceMotion {
                            PokiConversationCorners(radius: radius)
                                .fill(PokiTheme.sidebar, style: FillStyle(eoFill: true))
                                .ignoresSafeArea().allowsHitTesting(false)
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(PokiTheme.divider, lineWidth: 0.5)
                                .ignoresSafeArea().allowsHitTesting(false)
                        }
                    }
                    .background {
                        if drawerPresentationActive && !drawerReduceMotion {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(PokiTheme.background)
                                .shadow(color: .black.opacity(drawerColorScheme == .dark ? 0.22 : 0.07),
                                        radius: 20, x: -2, y: 0)
                                .ignoresSafeArea()
                        }
                    }
                    .offset(x: drawerReduceMotion ? 0 : drawerWidth * progress)
                    .zIndex(1)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 16, coordinateSpace: .global)
                    .updating($drawerGestureActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard showHistoryDrawer || drawerCloseStart != nil else { return }
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                        if drawerCloseStart == nil { drawerCloseStart = drawerProgress }
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
        }
        .sheet(item: $runtimePage) { page in
            NavigationStack {
                runtimeDestination(page)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { runtimePage = nil }
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

    // MARK: - Poki-inspired solid history drawer

    @ViewBuilder
    private var historyDrawer: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Button { showDrawerAccountMenu = true } label: {
                        HStack(spacing: 10) {
                            Image("AmoreLogo")
                                .resizable().scaledToFit()
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text("Amore")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(PokiTheme.primaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(AppLocalized("Account")))
                    .confirmationDialog(AppLocalized("Account"), isPresented: $showDrawerAccountMenu, titleVisibility: .visible) {
                        Button(AppLocalized("Personalize Amore")) {
                            snapDrawer(open: false)
                            runtimePage = .soul
                        }
                        Button(AppLocalized("Settings")) {
                            snapDrawer(open: false)
                            activeToolSheet = .settings
                        }
                        Button(AppLocalized("Cancel"), role: .cancel) { }
                    }
                    Spacer()
                    Button {
                        showDrawerSearch.toggle()
                        if !showDrawerSearch { drawerSearch = "" }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(PokiTheme.sidebarInk)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(AppLocalized("Search chats")))
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 12)

                if showDrawerSearch {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(PokiTheme.secondaryText)
                        TextField("Search chats", text: $drawerSearch)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .foregroundStyle(PokiTheme.primaryText)
                            .tint(PokiTheme.tagText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(PokiTheme.surface)
                    )
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
                }

                // Runtime shortcuts remain above the history, like ChatGPT's utility entries.
                VStack(spacing: 1) {
                    drawerNavRow(.tools)
                    drawerNavRow(.subAgents)
                    drawerNavRow(.skills)
                    drawerNavRow(.memory)
                    drawerNavRow(.rootfs)
                    localBotNavRow
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

                Rectangle()
                    .fill(PokiTheme.divider)
                    .frame(height: 0.5)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                HStack {
                    Text(showArchivedDrawerSessions ? "Archived" : "Recent")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PokiTheme.secondaryText)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showArchivedDrawerSessions.toggle()
                        }
                    } label: {
                        Image(systemName: showArchivedDrawerSessions ? "bubble.left.and.bubble.right" : "archivebox")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(PokiTheme.secondaryText)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(DrawerIconButtonStyle())
                    .accessibilityLabel(showArchivedDrawerSessions ? "Show recent chats" : "Show archived chats")
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 2)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        let groups = drawerGroups
                        if groups.isEmpty && filteredDrawerSessions.isEmpty {
                            Text(showArchivedDrawerSessions ? "No archived chats" : AppLocalized("No conversations yet"))
                                .font(.system(size: 14))
                                .foregroundStyle(PokiTheme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.top, 14)
                        } else {
                            ForEach(groups, id: \.label) { group in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LocalizedStringKey(group.label))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(PokiTheme.sidebarHeading)
                                        .padding(.horizontal, 20)
                                        .padding(.top, 6)
                                    ForEach(group.sessions) { session in
                                        drawerSessionRow(session)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)

                Rectangle()
                    .fill(PokiTheme.divider)
                    .frame(height: 0.5)
                    .padding(.horizontal, 18)

                HStack(spacing: 12) {
                    Button {
                        guard !drawerIsSliding else { return }
                        startHomeChat()
                        snapDrawer(open: false)
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            Label(AppLocalized("New Conversation"), systemImage: "square.and.pencil")
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 16)
                                .frame(height: 48)
                            Image(systemName: "square.and.pencil")
                                .font(.body.weight(.semibold)).frame(width: 48, height: 48)
                        }
                        .foregroundStyle(.white)
                        .background(PokiTheme.blue, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button {
                        snapDrawer(open: false)
                        activeToolSheet = .settings
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(PokiTheme.sidebarInk)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(PokiTheme.blueSoft))
                            .overlay(Circle().strokeBorder(PokiTheme.divider, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(AppLocalized("Settings")))
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PokiTheme.sidebar.ignoresSafeArea())
            .onAppear { rebuildDrawerGroups() }
            .onChange(of: sessions) { _ in rebuildDrawerGroups() }
            .onChange(of: drawerSearch) { _ in rebuildDrawerGroups() }
            .onChange(of: showArchivedDrawerSessions) { _ in rebuildDrawerGroups() }
            .onChange(of: archivedDrawerSessionIDs) { _ in rebuildDrawerGroups() }
        }
    }

    // MARK: Drawer pieces

    private var filteredDrawerSessions: [ChatSession] {
        let archived = archivedDrawerSessionIDs
        let source = showArchivedDrawerSessions
            ? sessions.filter { archived.contains($0.id) }
            : sessions.filter { !archived.contains($0.id) }
        let query = drawerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(query)
                || ($0.lastMessage ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    /// Only called when the inputs actually change — never per drag frame.
    private func rebuildDrawerGroups() {
        drawerGroups = groupedDrawerSessions
    }

    private var groupedDrawerSessions: [DrawerSessionGroup] {
        let calendar = Calendar.current
        let now = Date()
        var pinned: [ChatSession] = []
        var today: [ChatSession] = []
        var yesterday: [ChatSession] = []
        var lastSevenDays: [ChatSession] = []
        var earlier: [ChatSession] = []
        for session in filteredDrawerSessions {
            if session.isPinned {
                pinned.append(session)
            } else if calendar.isDateInToday(session.updatedAt) {
                today.append(session)
            } else if calendar.isDateInYesterday(session.updatedAt) {
                yesterday.append(session)
            } else if session.updatedAt >= (calendar.date(byAdding: .day, value: -7, to: now) ?? now) {
                lastSevenDays.append(session)
            } else {
                earlier.append(session)
            }
        }
        return [DrawerSessionGroup(label: "Pinned", sessions: pinned),
                DrawerSessionGroup(label: "Today", sessions: today),
                DrawerSessionGroup(label: "Yesterday", sessions: yesterday),
                DrawerSessionGroup(label: "Last 7 Days", sessions: lastSevenDays),
                DrawerSessionGroup(label: "Earlier", sessions: earlier)]
            .filter { !$0.sessions.isEmpty }
    }

    @ViewBuilder
    private func drawerNavRow(_ page: RuntimePage) -> some View {
        let meta: (title: String, symbol: String) = {
            switch page {
            case .tools:     return (AppLocalized("Agent Tools"), "wrench.and.screwdriver")
            case .subAgents: return (AppLocalized("Sub Agents"), "person.2")
            case .skills:    return (AppLocalized("Skills"), "puzzlepiece.extension")
            case .memory:    return (AppLocalized("Memory"), "brain.head.profile")
            case .localBot:  return ("SnowLuma + QQBot", "antenna.radiowaves.left.and.right")
            case .soul:      return ("Personalize Amore", "sparkles")
            case .rootfs:    return (AppLocalized("Rootfs"), "externaldrive")
            }
        }()
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                showHistoryDrawer = false
            }
            runtimePage = page
        } label: {
            HStack(spacing: 14) {
                Image(systemName: meta.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(PokiTheme.primaryText)
                    .frame(width: 24, alignment: .center)
                Text(meta.title)
                    .font(.system(size: 16.5, weight: .regular))
                    .foregroundStyle(PokiTheme.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(DrawerRowButtonStyle())
    }

    private var localBotNavRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                showHistoryDrawer = false
            }
            runtimePage = .localBot
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(PokiTheme.primaryText)
                    .frame(width: 24, alignment: .center)
                Text("SnowLuma + QQBot")
                    .font(.system(size: 16.5, weight: .regular))
                    .foregroundStyle(PokiTheme.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(DrawerRowButtonStyle())
    }

    @ViewBuilder
    private func drawerSessionRow(_ session: ChatSession) -> some View {
        let selected = homeSessionId == session.id
        Button {
            guard !drawerIsSliding else { return }
            snapDrawer(open: false)
            homeSessionId = session.id
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title?.isEmpty == false ? (session.title ?? AppLocalized("New Chat")) : AppLocalized("New Chat"))
                        .font(.system(size: 15.5, weight: .regular))
                        .foregroundStyle(PokiTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(session.updatedAt, style: .relative)
                        .font(.system(size: 12))
                        .foregroundStyle(PokiTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? PokiTheme.selection : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(DrawerRowButtonStyle())
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

    private func startHomeChat() {
        homeSessionId = nil
        homeDraftId = "__new__" + UUID().uuidString
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
