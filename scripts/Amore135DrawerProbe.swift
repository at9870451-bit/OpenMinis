import SwiftUI

// Test-only store: production footer assignment targets this inert object.
// No real Settings router, account, session database or device service exists.
enum Amore135SettingsTarget: String { case home }
final class DeepLinkCoordinator: ObservableObject {
    static let shared = DeepLinkCoordinator()
    @Published var pendingSettingsTarget: Amore135SettingsTarget?
}
enum Amore135ToolSheet: String { case settings }

struct Amore135DrawerProbe: View {
    let drawerIsSliding = false
    @FocusState var drawerSearchFocused: Bool
    @State var drawerSearch = ""
    @State var activeToolSheet: Amore135ToolSheet?
    @State private var homeCount = 0
    @State private var shortcut = "none"
    @ObservedObject private var links = DeepLinkCoordinator.shared

    // Footer/header compile against these host stubs, not ContentView services.
    func snapDrawer(open: Bool) {} // Intentionally no-op: keep footer visible for geometry assertions.
    func startHomeChat() { homeCount += 1 }

    var body: some View {
        VStack(spacing: 0) {
            Text("TEST DRAWER — production header / shortcuts / footer, synthetic history")
                .font(.caption2).accessibilityIdentifier("amore135.drawer.root")
            Text("new=\(homeCount);sheet=\(activeToolSheet?.rawValue ?? "none");target=\(links.pendingSettingsTarget?.rawValue ?? "none");shortcut=\(shortcut)")
                .font(.caption2).accessibilityIdentifier("amore135.drawer.state")
            VStack(alignment: .leading, spacing: 0) {
                drawerHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        AmoreSidebarShortcuts(interactionEnabled: !drawerIsSliding) { item in shortcut = item.rawValue }
                        ForEach(0..<35, id: \.self) { index in
                            Text("Synthetic conversation \(index)")
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .padding(.horizontal, 20)
                        }
                    }.padding(.bottom, 16)
                }
                .accessibilityIdentifier("amore135.drawer.history")
                drawerAccountFooter
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(PokiTheme.sidebarInk).tint(PokiTheme.sidebarInk)
            .background(PokiTheme.sidebar.ignoresSafeArea())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PokiTheme.sidebar.ignoresSafeArea())
    }
}
// drawerHeader / drawerAccountFooter are extracted unchanged into an extension
// at build time. This probe is NOT the whole production historyDrawer/App.
