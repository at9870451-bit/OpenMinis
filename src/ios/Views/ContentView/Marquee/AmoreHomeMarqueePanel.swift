import SwiftUI

/// The real Amore home suggestion surface. It uses the ported two-direction
/// marquee, while actions are mapped to Amore routes instead of Poki services.
@MainActor
struct AmoreHomeMarqueePanel: View {
    let items: [AmoreHomeShortcut]
    let revision: Int
    let active: Bool
    let onAction: (AmoreHomeShortcut.Action) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heldID: String?

    private var firstRow: [AmoreHomeShortcut] { Array(items.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)) }
    private var secondRow: [AmoreHomeShortcut] { Array(items.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)) }

    var body: some View {
        VStack(spacing: 8) {
            row(firstRow.isEmpty ? items : firstRow, speed: 20)
            row(secondRow.isEmpty ? items : secondRow, speed: -18)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func row(_ values: [AmoreHomeShortcut], speed: Double) -> some View {
        AmoreMarquee(speed: speed,
                     revision: "\(revision)-\(speed)-\(values.map(\.id).joined(separator: ","))",
                     spacing: 8,
                     edgeFade: 18,
                     running: !reduceMotion,
                     active: active,
                     stopped: heldID != nil) {
            ForEach(values) { item in
                Button {
                    onAction(item.action)
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PokiTheme.blueText)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                        .background(PokiTheme.blueSoft, in: Capsule())
                        .overlay(Capsule().stroke(PokiTheme.blueLine, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .scaleEffect(heldID == item.id ? 0.96 : 1)
                .animation(.easeOut(duration: 0.12), value: heldID)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                    heldID = item.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { heldID = nil }
                })
                .contextMenu {
                    Button(role: .destructive) {
                        AmoreHomeShortcutStore.shared.remove(id: item.id)
                    } label: {
                        Label(AppLocalized("Hide shortcut"), systemImage: "eye.slash")
                    }
                }
            }
        }
        .frame(height: 44)
    }
}
