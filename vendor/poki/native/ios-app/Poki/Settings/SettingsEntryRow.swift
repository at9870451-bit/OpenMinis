import PokiCore
import SwiftUI

// Settings opens from the conversations: a round button in the trailing corner of their foot, beside
// the new-conversation button (and from Poki's status card). Where it opens is the app's (PokiApp).

extension EnvironmentValues {
    /// Opens Settings (Poki's profile sheet). Nil where nothing has set it: then the entry is not shown.
    @Entry var openPokiSettings: (() -> Void)? = nil
}

/// Settings as a round glass button, with an amber dot while something there needs you (no model
/// yet, setup not finished, an update waiting, the relay offline).
struct SettingsEntryButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openPokiSettings) private var open
    @Environment(\.drawerSliding) private var sliding

    var controlSize = CompactControlMetrics()

    private var needsYou: Bool {
        !ModelKeys.hasUsableKey || !model.setupReadyForUse || model.signer.updateNotReady || model.signer.next?.kind == "update" || model.relayStatus.isOffline
    }

    var body: some View {
        if let open {
            Button { if !sliding { open() } } label: {
                // The dot inside the label, so the glass draws it rather than covering it.
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(Tint.sidebarInk)
                        .frame(width: controlSize.side, height: controlSize.side)
                    if needsYou {
                        Circle().fill(Tint.amber).frame(width: 9, height: 9).offset(x: -8, y: 8)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassSurface(in: Circle(), interactive: true)
            .accessibilityLabel(Text("Settings"))
            .accessibilityValue(needsYou ? Text("Needs your attention") : Text(verbatim: ""))
            .accessibilityIdentifier("threads.settings")
            .accessibilityShowsLargeContentViewer {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}
