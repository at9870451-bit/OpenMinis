import SwiftUI

/// Mounted only by the blank/empty-composer message-area gate. Own observation
/// is essential: reading `.shared.visibleItems` alone never subscribed the chat
/// to edits/visibility changes made in Settings or a context menu.
@MainActor
struct AmoreHomeMarqueeSource: View {
    @ObservedObject private var store = AmoreHomeShortcutStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.amoreDrawerProgress) private var drawerProgress
    let writing: Bool
    let setInput: (String) -> Void
    let openURL: (URL) -> Void
    @State private var showManager = false
    @State private var editing: AmoreHomeShortcut?

    var body: some View {
        AmoreHomeMarqueePanel(
            items: store.visibleItems,
            revision: store.revision,
            active: scenePhase == .active && drawerProgress < 0.001 && !showManager && editing == nil,
            onAction: perform,
            writing: writing,
            onManage: { showManager = true },
            onEdit: { editing = $0 }
        )
        .sheet(isPresented: $showManager) {
            NavigationStack {
                AmoreHomeShortcutManager()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(AppLocalized("Done")) { showManager = false }
                        }
                    }
            }
        }
        .sheet(item: $editing) { item in
            NavigationStack { AmoreHomeShortcutEditor(item: item, isNew: false) }
        }
    }

    private func perform(_ action: AmoreHomeShortcut.Action) {
        AmoreHomeActionRouter(
            setInput: setInput,
            openPage: { page in
                if page == "shortcuts" {
                    showManager = true
                } else if let url = AmoreShortcutRoutes.settingsURL(for: page) {
                    openURL(url)
                }
            },
            openLink: openURL
        ).perform(action)
    }
}
