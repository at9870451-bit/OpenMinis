import SwiftUI

@MainActor
final class NodeOfflineRuntimeStore: ObservableObject {
    static let shared = NodeOfflineRuntimeStore()
    @Published var isInstalling = false
    @Published var output: String?
    @Published var failed = false

    func install() {
        guard !isInstalling else { return }
        isInstalling = true
        output = nil
        failed = false
        Task {
            defer { isInstalling = false }
            do { output = try await NodeOfflineRuntime.shared.install() }
            catch { failed = true; output = error.localizedDescription }
        }
    }
}

/// Installing into the Linux guest is separate from AOJIT image matching and
/// from enabling untrusted plugins. Nothing is installed on App launch.
struct NodeOfflineRuntimeSection: View {
    @StateObject private var store = NodeOfflineRuntimeStore.shared
    @State private var confirmInstall = false

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(PokiTheme.skillTeal)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppLocalized("Bundled Node.js runtime")).font(.headline)
                    Text("Node.js 22.23.5 · npm 10.9.1")
                        .font(.caption.monospaced()).foregroundStyle(PokiTheme.secondaryText)
                    Text("Alpine 3.21 · aarch64 · musl")
                        .font(.caption.monospaced()).foregroundStyle(PokiTheme.secondaryText)
                }
            }
            if store.isInstalling {
                HStack(spacing: 10) {
                    ProgressView().tint(PokiTheme.blueText)
                    Text(AppLocalized("Verifying and installing bundled Node packages…"))
                }.font(.callout)
            } else {
                Button { confirmInstall = true } label: {
                    Label(AppLocalized("Install Node.js and npm offline"), systemImage: "square.and.arrow.down")
                }.tint(PokiTheme.blueText)
            }
            if let output = store.output {
                Text(output).font(.caption.monospaced())
                    .foregroundStyle(store.failed ? PokiTheme.danger : PokiTheme.secondaryText)
                    .textSelection(.enabled)
            }
        } header: {
            Text(AppLocalized("Offline JavaScript environment"))
        } footer: {
            Text(AppLocalized("The signed Node.js, npm and dependency packages are included in this App. No mirror download is needed. This does not install DeepSeek Harness or make Cordis plugins compatible."))
        }
        .listRowBackground(PokiTheme.surface)
        .confirmationDialog(AppLocalized("Install bundled Node.js and npm?"), isPresented: $confirmInstall,
                            titleVisibility: .visible) {
            Button(AppLocalized("Install offline")) { store.install() }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalized("Installs official signed Alpine packages into your Shell Container, including required dependency updates. It does not reset your rootfs or download anything. Start the terminal first. Node's runtime and AOJIT match status are checked separately."))
        }
    }
}
