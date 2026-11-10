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
        ZStack(alignment: .leading) {
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
                // System screen-edge pan: works over the UIKit message list.
                EdgeSwipeCatcher {
                    withAnimation(.easeOut(duration: 0.22)) {
                        showHistoryDrawer = true
                    }
                }
                .allowsHitTesting(false)
            }

            if showHistoryDrawer {
                historyDrawer
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.22), value: showHistoryDrawer)
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

    // MARK: - ChatGPT-style history drawer

    private var historyDrawerGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                if !showHistoryDrawer,
                   value.startLocation.x < 28,
                   value.translation.width > 60 {
                    withAnimation { showHistoryDrawer = true }
                } else if showHistoryDrawer, value.translation.width < -60 {
                    withAnimation { showHistoryDrawer = false }
                }
            }
    }

    @ViewBuilder
    private var historyDrawer: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { showHistoryDrawer = false } }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Button {
                        withAnimation(.easeOut(duration: 0.22)) {
                            showHistoryDrawer = false
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text("Close"))
                    Text(soulName.first?.isEmpty == false ? soulName : "Minis")
                        .font(.system(size: 34, weight: .bold))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        withAnimation { showHistoryDrawer = false }
                        activeToolSheet = .settings
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text("Settings"))
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 18)

                Divider().padding(.horizontal, 24)

                // Agent Runtime shortcuts, one tap from the drawer.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach([RuntimePage.tools, .subAgents, .skills, .memory]) { page in
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showHistoryDrawer = false
                            }
                            runtimePage = page
                        } label: {
                            runtimeRow(page)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)

                Divider().padding(.horizontal, 24)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sessions) { session in
                            Button {
                                withAnimation { showHistoryDrawer = false }
                                homeSessionId = session.id
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title?.isEmpty == false ? session.title! : "New Chat")
                                            .font(.system(size: 16, weight: .regular))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(session.updatedAt, style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 11)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .background(
                                    homeSessionId == session.id
                                    ? Color.primary.opacity(0.08)
                                    : Color.clear
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        if sessions.isEmpty {
                            Text("No conversations yet")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 24)
                                .padding(.top, 16)
                        }
                    }
                    .padding(.top, 8)
                }

                Divider().padding(.horizontal, 24)

                // ChatGPT-style bottom action pill.
                Button {
                    withAnimation { showHistoryDrawer = false }
                    startHomeChat()
                } label: {
                    Label("Chat", systemImage: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 13)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 26)
            }
            .frame(width: UIScreen.main.bounds.width)
            .frame(maxHeight: .infinity)

            .background(Color(UIColor.systemBackground))
            .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private func runtimeRow(_ page: RuntimePage) -> some View {
        let (title, symbol, tint): (String, String, Color) = {
            switch page {
            case .tools:     return ("Agent Tools", "wrench.and.screwdriver.fill", .indigo)
            case .subAgents: return ("Sub Agents", HelperAccent.glyph, HelperAccent.color)
            case .skills:    return ("Skills", "puzzlepiece.extension", .blue)
            case .memory:    return ("Memory", "brain.head.profile", .purple)
            }
        }()
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(tint, in: Circle())
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
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
