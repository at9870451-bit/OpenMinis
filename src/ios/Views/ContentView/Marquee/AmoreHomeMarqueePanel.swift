import SwiftUI

/// The real Amore home suggestion surface. It uses the ported two-direction
/// marquee, while actions are mapped to Amore routes instead of Poki services.
@MainActor
struct AmoreHomeMarqueePanel: View {
    let items: [AmoreHomeShortcut]
    let revision: Int
    let active: Bool
    let onAction: (AmoreHomeShortcut.Action) -> Void
    var writing = false
    var onManage: () -> Void = {}
    var onEdit: (AmoreHomeShortcut) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var heldID: String?

    private var rows: [[AmoreHomeShortcut]] { AmoreHomeShortcutPolicy.rows(items) }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                Button(action: onManage) {
                    Label(AppLocalized("Manage shortcuts"), systemImage: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundStyle(PokiTheme.secondaryText)
                }
                .accessibilityIdentifier("home.shortcuts.manage")
            }
            .padding(.horizontal, 20)
            if items.isEmpty {
                Text(AppLocalized("All shortcuts are hidden. Manage shortcuts to add or restore them."))
                    .font(.footnote)
                    .foregroundStyle(PokiTheme.secondaryText)
                    .padding(.horizontal, 24)
            } else {
                row(rows[0], speed: 20, start: 64)
                if !rows[1].isEmpty { row(rows[1], speed: -18, start: 0) }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onDisappear { heldID = nil }
    }

    @ViewBuilder private func row(_ values: [AmoreHomeShortcut], speed: Double, start: CGFloat) -> some View {
        AmoreMarquee(speed: speed,
                     revision: "\(revision)-\(speed)-\(values.map(\.id).joined(separator: ","))",
                     spacing: 8,
                     start: start,
                     edgeFade: 18,
                     running: !reduceMotion && !lowPower && !writing,
                     active: active,
                     loops: !voiceOver,
                     stopped: heldID != nil) {
            ForEach(values) { item in
                Button {
                    onAction(item.action)
                } label: {
                    HStack(spacing: 7) {
                        AmoreShortcutAppIcon(item: item, size: 22)
                        Text(item.title).lineLimit(1)
                    }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PokiTheme.blueText)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                        .background(PokiTheme.blueSoft, in: Capsule())
                        .overlay(Capsule().stroke(PokiTheme.blueLine, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.shortcut.\(item.id)")
                .accessibilityHint(Text(item.action.kind == .prompt
                    ? AppLocalized("Fills the message field without sending")
                    : AppLocalized("Opens an Amore page or link")))
                .contextMenu {
                    Button { onEdit(item) } label: {
                        Label(AppLocalized("Edit"), systemImage: "pencil")
                    }
                    Button {
                        AmoreHomeShortcutStore.shared.setHidden(true, id: item.id)
                    } label: {
                        Label(AppLocalized("Hide shortcut"), systemImage: "eye.slash")
                    }
                    Button(role: .destructive) {
                        AmoreHomeShortcutStore.shared.remove(id: item.id)
                    } label: {
                        Label(AppLocalized("Delete"), systemImage: "trash")
                    }
                    Button(action: onManage) {
                        Label(AppLocalized("Manage shortcuts"), systemImage: "slider.horizontal.3")
                    }
                } preview: {
                    Label(item.title, systemImage: item.symbol)
                        .padding()
                        .onAppear { heldID = item.id }
                        .onDisappear { heldID = nil }
                }
            }
        }
        .frame(height: 44)
    }
}
