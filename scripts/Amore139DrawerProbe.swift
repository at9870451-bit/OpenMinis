import SwiftUI

/// Inert transcript/history only; the drawer itself is the unmodified production
/// AmoreTransparentDrawer. No user records, chat VM, context or persistence.
struct Amore139DrawerProbe: View {
    @State private var open = false
    @State private var selected = "none"
    @State private var transcriptTaps = 0
    @State private var dragProgress: CGFloat?
    @State private var closeStart: CGFloat?
    @GestureState private var gestureActive = false
    @StateObject private var mounts = Amore139MountTracker()
    private let dark: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-amore139-theme"), index + 1 < arguments.count {
            dark = arguments[index + 1] == "dark"
        } else {
            dark = false
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = PokiDrawerMetrics.travel(for: geometry.size.width)
            AmoreTransparentDrawer(size: geometry.size, drawerWidth: width,
                progress: dragProgress ?? (open ? 1 : 0), presentationActive: open,
                reduceMotion: false, onClose: { snap(open: false) }) {
                // Never conditional, duplicated or keyed by open/selection/theme.
                Amore139ProbeChat(selected: selected, taps: transcriptTaps, mounts: mounts,
                    onOpen: { snap(open: true) }, onAction: { transcriptTaps += 1 })
            } sidebar: {
                VStack(spacing: 0) {
                    HStack {
                        Text("Recent chats").font(.headline)
                        Spacer()
                        Button { snap(open: false) } label: {
                            Image(systemName: "sidebar.left").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Close history")
                        .accessibilityIdentifier("transparent.close")
                    }.padding(.horizontal, 16)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(0..<35, id: \.self) { index in
                                Button("Conversation \(index)") {
                                    selected = String(index)
                                    snap(open: false)
                                }
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .accessibilityIdentifier("transparent.history.\(index)")
                                .accessibilityValue(selected == String(index) ? "selected" : "unselected")
                            }
                        }.padding(.horizontal, 16)
                    }.accessibilityIdentifier("transparent.history")
                    Amore139SchemeReadout()
                    Text("TEST HISTORY — no user records").font(.caption2).padding(8)
                }
                .foregroundStyle(Color.primary)
                .allowsHitTesting(open && dragProgress == nil)
            }
            // Production ContentView+Layout installs this OUTSIDE the helper:
            // minimumDistance 16, global coordinates, horizontal dominance 1.5,
            // left-only start, live progress and predicted-end threshold 0.55.
            // This isolated host mirrors only closing, NOT production's separate
            // UIKit EdgeSwipeCatcher opening gesture or the whole application.
            .simultaneousGesture(
                DragGesture(minimumDistance: 16, coordinateSpace: .global)
                    .updating($gestureActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard open || closeStart != nil else { return }
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                        if closeStart == nil {
                            guard value.translation.width < 0 else { return }
                            closeStart = dragProgress ?? 1
                        }
                        dragProgress = min(1, max(0, (closeStart ?? 1) + value.translation.width / width))
                    }
                    .onEnded { value in
                        guard let start = closeStart else { return }
                        snap(open: start + value.predictedEndTranslation.width / width > 0.55)
                    },
                including: open ? .all : .subviews
            )
            .onChange(of: gestureActive) { active in
                if !active, closeStart != nil { snap(open: open) }
            }
        }
        // A launch argument actually forces SwiftUI's scheme; AppleInterfaceStyle
        // alone would be defeated by this probe's preferredColorScheme.
        .preferredColorScheme(dark ? .dark : .light)
    }

    private func snap(open next: Bool) {
        closeStart = nil
        withAnimation(.interactiveSpring(response: 0.42, dampingFraction: 0.88)) {
            dragProgress = nil
            open = next
        }
    }
}

/// Cumulative unique chat lifetimes. Owned ABOVE the drawer, never reset on
/// closing. Repeated onAppear for one lifetime is not counted as a new mount.
private final class Amore139MountTracker: ObservableObject {
    @Published private(set) var count = 0
    private var seen = Set<UUID>()
    func record(_ id: UUID) {
        if seen.insert(id).inserted { count += 1 }
    }
}

private final class Amore139ChatLifetime: ObservableObject {
    let id = UUID()
}

private struct Amore139SchemeReadout: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text("theme=\(scheme == .dark ? "dark" : "light")")
            .font(.caption2).accessibilityIdentifier("transparent.scheme")
    }
}

private struct Amore139ProbeChat: View {
    let selected: String
    let taps: Int
    @ObservedObject var mounts: Amore139MountTracker
    let onOpen: () -> Void
    let onAction: () -> Void
    @StateObject private var lifetime = Amore139ChatLifetime()
    @State private var draft = "draft retained"
    @FocusState private var draftFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            scheme == .dark ? Color(red: 0.04, green: 0.06, blue: 0.10) : Color.white
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("History") {
                        // Like production snapDrawer, resign input before opening.
                        draftFocused = false
                        onOpen()
                    }
                    .accessibilityIdentifier("transparent.open")
                    Spacer()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("LIVE CONVERSATION — fixture transcript").font(.headline)
                        Text("User: keep the conversation visible.")
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.cyan.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
                        Text("Assistant: This is the same mounted message tree behind the transparent history pane.")
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.24), in: RoundedRectangle(cornerRadius: 18))
                        ForEach(0..<3, id: \.self) { index in
                            Text("Visible message \(index) — conversation remains here")
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(index.isMultiple(of: 2) ? Color.blue.opacity(0.12) : Color.purple.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.accessibilityIdentifier("transparent.transcript")
                TextField("Draft", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($draftFocused)
                    .accessibilityIdentifier("transparent.draft")
                Button(action: onAction) {
                    Text("Transcript action").frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.cyan.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("transparent.chatAction")
                .padding(.horizontal, -8) // x = app.maxX - 16 is inside the real button.
                Text("selected=\(selected);draft=\(draft);taps=\(taps);mounts=\(mounts.count)")
                    .font(.caption2).accessibilityIdentifier("transparent.state")
            }.padding(16)
        }
        .foregroundStyle(Color.primary)
        .onAppear { mounts.record(lifetime.id) }
    }
}
