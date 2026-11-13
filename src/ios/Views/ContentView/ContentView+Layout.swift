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

private let shareLog = AppLogger(category: "Share")
private let draftLog = AppLogger(category: "DraftSession")

extension ContentView {
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
        let drawerWidth = UIScreen.main.bounds.width * 0.88
        let p = min(1, max(0, drawerProgress))

        return ZStack(alignment: .leading) {
            // Conversation panel: recedes behind the drawer as it opens,
            // shrinking and shifting right so the glass panel reads as a
            // foreground layer with real depth.
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
            .background {
                EdgeSwipeCatcher(
                    onProgress: { fraction in
                        drawerDragProgress = fraction
                    },
                    onEnd: { fraction, velocity in
                        snapDrawer(open: fraction > 0.5 || velocity > 500)
                    }
                )
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24 * p, style: .continuous))
            .scaleEffect(1 - 0.06 * p, anchor: .center)
            // A small shift (not a full drawer-width one) keeps the page's
            // trailing rounded corner on screen, which is what reads as depth.
            .offset(x: drawerWidth * 0.14 * p)
            .overlay(Color.black.opacity(0.18 * p))
            .shadow(color: Color.black.opacity(0.22 * p), radius: 22, x: 6, y: 0)
            .zIndex(0)

            // Close catcher: tap/drag anywhere on the conversation closes the
            // drawer. Drawn under the panel so drawer controls stay tappable.
            if p > 0.001 {
                Color.white.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { snapDrawer(open: false) }
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { value in
                                let fraction = 1 + value.translation.width / drawerWidth
                                drawerDragProgress = min(1, max(0, fraction))
                            }
                            .onEnded { value in
                                let projected = 1 + value.predictedEndTranslation.width / drawerWidth
                                snapDrawer(open: projected > 0.5)
                            }
                    )
                    .zIndex(1)
            }

            // Drawer panel on TOP: glass material blurs the conversation behind
            // it, giving a true floating surface rather than flat overlay.
            historyDrawer
                .frame(width: drawerWidth)
                .frame(maxHeight: .infinity)
                // Parked off-screen when closed; slides in with the gesture.
                .offset(x: -drawerWidth * (1 - p))
                .zIndex(2)
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: drawerProgress)
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
        drawerDragProgress = nil
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            showHistoryDrawer = open
        }
    }

    // MARK: - ChatGPT-style history drawer

    @ViewBuilder
    private var historyDrawer: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                // ChatGPT-style header: brand mark, compose, and search.
                HStack(alignment: .center, spacing: 10) {
                    HStack(spacing: 9) {
                        Image("AmoreLogo")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                            }
                        Text("Amore")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(AmoreTheme.textPrimary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button {
                        snapDrawer(open: false)
                        startHomeChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(AmoreTheme.textPrimary)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.05)))
                    }
                    .buttonStyle(DrawerIconButtonStyle())
                    .accessibilityLabel(Text("New Chat"))
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showDrawerSearch.toggle()
                            if !showDrawerSearch { drawerSearch = "" }
                        }
                        if showDrawerSearch { drawerSearchFocused = true }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AmoreTheme.textPrimary)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.05)))
                    }
                    .buttonStyle(DrawerIconButtonStyle())
                    .accessibilityLabel(Text("Search"))
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

                if showDrawerSearch {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AmoreTheme.textSecondary)
                        TextField("Search chats", text: $drawerSearch)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .foregroundStyle(AmoreTheme.textPrimary)
                            .tint(AmoreTheme.accent)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.04))
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
                    localBotNavRow
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

                Rectangle()
                    .fill(AmoreTheme.separator)
                    .frame(height: 0.5)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                HStack {
                    Text(showArchivedDrawerSessions ? "Archived" : "Recent")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AmoreTheme.textSecondary)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showArchivedDrawerSessions.toggle()
                        }
                    } label: {
                        Image(systemName: showArchivedDrawerSessions ? "bubble.left.and.bubble.right" : "archivebox")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AmoreTheme.textSecondary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(DrawerIconButtonStyle())
                    .accessibilityLabel(showArchivedDrawerSessions ? "Show recent chats" : "Show archived chats")
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 2)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        let groups = groupedDrawerSessions
                        if groups.isEmpty {
                            Text(showArchivedDrawerSessions ? "No archived chats" : AppLocalized("No conversations yet"))
                                .font(.system(size: 14))
                                .foregroundStyle(AmoreTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.top, 14)
                        } else {
                            ForEach(groups, id: \.label) { group in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.label)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(AmoreTheme.textSecondary)
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

                Rectangle()
                    .fill(AmoreTheme.separator)
                    .frame(height: 0.5)
                    .padding(.horizontal, 18)

                // Fixed account/profile area; independent of the history scroll.
                HStack(spacing: 10) {
                    Button {
                        showDrawerAccountMenu = true
                    } label: {
                        HStack(spacing: 10) {
                            Group {
                                if SoulStore.cachedMetadata.iconIsImage,
                                   let image = SoulIconImage.decode(SoulStore.cachedMetadata.icon) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Text(SoulStore.cachedMetadata.displayIcon)
                                        .font(.system(size: 20))
                                }
                            }
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(AmoreTheme.secondaryBackground))
                            .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(soulName.isEmpty ? "Amore" : soulName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AmoreTheme.textPrimary)
                                    .lineLimit(1)
                                Text("Personal account")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AmoreTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DrawerRowButtonStyle())
                    .confirmationDialog("Account", isPresented: $showDrawerAccountMenu, titleVisibility: .visible) {
                        Button("Settings") {
                            snapDrawer(open: false)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { activeToolSheet = .settings }
                        }
                        Button("Personalize Amore") {
                            snapDrawer(open: false)
                            runtimePage = .soul
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Personal account · Free")
                    }
                    Button {
                        snapDrawer(open: false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { activeToolSheet = .settings }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(AmoreTheme.textPrimary)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.05)))
                    }
                    .buttonStyle(DrawerIconButtonStyle())
                    .accessibilityLabel(Text("Settings"))
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .background {
                // Real frosted glass: the material does the blurring, the tint
                // stays light enough that content behind shows through. A heavy
                // white fill (0.82) used to flatten it into a solid panel.
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    AmoreTheme.glassFill(0.55)
                }
                .ignoresSafeArea(edges: .vertical)
            }
            // Rounded only on the trailing edge: the panel slides out from the
            // screen edge, so the leading corners must stay square.
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 24,
                    topTrailingRadius: 24,
                    style: .continuous
                )
            )
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 24,
                    topTrailingRadius: 24,
                    style: .continuous
                )
                .strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.18), radius: 22, x: 8, y: 0)
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

    private var groupedDrawerSessions: [(label: String, sessions: [ChatSession])] {
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
        return [("Pinned", pinned), ("Today", today), ("Yesterday", yesterday), ("Last 7 Days", lastSevenDays), ("Earlier", earlier)]
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
                    .foregroundStyle(AmoreTheme.textPrimary)
                    .frame(width: 24, alignment: .center)
                Text(meta.title)
                    .font(.system(size: 16.5, weight: .regular))
                    .foregroundStyle(AmoreTheme.textPrimary)
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
                    .foregroundStyle(AmoreTheme.textPrimary)
                    .frame(width: 24, alignment: .center)
                Text("SnowLuma + QQBot")
                    .font(.system(size: 16.5, weight: .regular))
                    .foregroundStyle(AmoreTheme.textPrimary)
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
            withAnimation(.easeOut(duration: 0.2)) {
                showHistoryDrawer = false
            }
            homeSessionId = session.id
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title?.isEmpty == false ? session.title! : "New Chat")
                        .font(.system(size: 15.5, weight: .regular))
                        .foregroundStyle(AmoreTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(session.updatedAt, style: .relative)
                        .font(.system(size: 12))
                        .foregroundStyle(AmoreTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.08) : Color.clear)
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
                    .foregroundStyle(.secondary)
                Text("No Conversation Selected")
                    .font(.title3.bold())
                Text("Select a conversation or start a new one")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
