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
        let drawerWidth = UIScreen.main.bounds.width * 0.78
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
            .clipShape(RoundedRectangle(cornerRadius: 28 * p, style: .continuous))
            .scaleEffect(1 - 0.10 * p, anchor: .center)
            .offset(x: drawerWidth * p)
            .overlay(Color.black.opacity(0.22 * p))
            .shadow(color: Color.black.opacity(0.35 * p), radius: 26, x: -14, y: 0)
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
                // MARK: Header
                HStack(alignment: .center, spacing: 12) {
                    Text("Amore")
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showDrawerSearch.toggle()
                            if !showDrawerSearch { drawerSearch = "" }
                            if showDrawerSearch { drawerSearchFocused = true }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(DrawerIconButtonStyle())
                    .accessibilityLabel(Text("Search"))
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 14)

                if showDrawerSearch {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                        TextField("Search chats", text: $drawerSearch)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .tint(.white)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
                }

                // MARK: Runtime navigation
                VStack(spacing: 1) {
                    drawerNavRow(.tools)
                    drawerNavRow(.subAgents)
                    drawerNavRow(.skills)
                    drawerNavRow(.memory)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

                // MARK: Hairline
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 0.5)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)

                // MARK: Recent chats
                Text(AppLocalized("Recent"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 22)
                    .padding(.bottom, 4)

                ScrollView {
                    LazyVStack(spacing: 1) {
                        let visible = filteredDrawerSessions
                        if visible.isEmpty {
                            Text(AppLocalized("No conversations yet"))
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22)
                                .padding(.top, 14)
                        } else {
                            ForEach(visible) { session in
                                drawerSessionRow(session)
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }

                // MARK: Fixed bottom bar
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showHistoryDrawer = false
                        }
                        startHomeChat()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 15, weight: .semibold))
                            Text(AppLocalized("Chat"))
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 46)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(red: 0.04, green: 0.52, blue: 1.0))
                        )
                    }
                    .buttonStyle(DrawerPillButtonStyle())

                    Spacer(minLength: 0)

                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showHistoryDrawer = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            activeToolSheet = .settings
                        }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(DrawerIconButtonStyle())
                    .accessibilityLabel(Text("Settings"))
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .background(Color.black)
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .background {
                // Frosted glass, so the drawer reads as a separate, slightly
                // lifted surface next to the opaque conversation card.
                // IMPORTANT: only vertical safe-area bleed. `.ignoresSafeArea()`
                // without edges also stretched the panel across the full screen
                // width, which made the drawer look like a global overlay.
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Color.black.opacity(0.45)
                }
                .ignoresSafeArea(edges: .vertical)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Drawer pieces

    private var filteredDrawerSessions: [ChatSession] {
        let query = drawerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(query)
                || ($0.lastMessage ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private func drawerNavRow(_ page: RuntimePage) -> some View {
        let meta: (title: String, symbol: String) = {
            switch page {
            case .tools:     return (AppLocalized("Agent Tools"), "wrench.and.screwdriver")
            case .subAgents: return (AppLocalized("Sub Agents"), "person.2")
            case .skills:    return (AppLocalized("Skills"), "puzzlepiece.extension")
            case .memory:    return (AppLocalized("Memory"), "brain.head.profile")
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
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 24, alignment: .center)
                Text(meta.title)
                    .font(.system(size: 16.5, weight: .regular))
                    .foregroundStyle(.white)
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
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(session.updatedAt, style: .relative)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
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
            Button(role: .destructive) {
                withAnimation(.easeOut(duration: 0.2)) {
                    showHistoryDrawer = false
                }
                sessionToDelete = session
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func runtimeDestination(_ page: RuntimePage) -> some View {
        switch page {
        case .tools:     ToolsSettingsView()
        case .subAgents: HelperSettingsView()
        case .skills:    SkillsManagementView()
        case .memory:    MemoryManagementView()
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
