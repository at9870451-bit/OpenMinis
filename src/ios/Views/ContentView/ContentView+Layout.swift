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
            .contentShape(Rectangle())
            .simultaneousGesture(historyDrawerGesture)

            if showHistoryDrawer {
                historyDrawer
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.22), value: showHistoryDrawer)
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

            VStack(spacing: 0) {
                HStack {
                    Text("Chats")
                        .font(.title2.weight(.bold))
                    Spacer()
                    Button {
                        withAnimation { showHistoryDrawer = false }
                        startHomeChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)

                List {
                    ForEach(sessions) { session in
                        Button {
                            withAnimation { showHistoryDrawer = false }
                            homeSessionId = session.id
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title?.isEmpty == false ? session.title! : "New Chat")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(session.updatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(homeSessionId == session.id
                                           ? Color.primary.opacity(0.08)
                                           : Color.clear)
                    }
                }
                .listStyle(.plain)

                Divider()
                Button {
                    withAnimation { showHistoryDrawer = false }
                    activeToolSheet = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: min(UIScreen.main.bounds.width * 0.84, 340))
            .background(.regularMaterial)
            .ignoresSafeArea(edges: .bottom)
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
