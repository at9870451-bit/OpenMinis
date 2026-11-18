import SwiftUI

/// Amore-owned equivalent of Poki's Connection page. It exposes only Amore
/// services: MCP integrations, Rootfs/Node runtime, and the terminal. It never
/// claims to start Poki Runner or a DeepSeek Harness relay.
struct DeveloperConnectionView: View {
    @ObservedObject private var mcp = MCPStore.shared
    @State private var showTerminal = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    MCPIntegrationsView()
                } label: {
                    Label {
                        Text(AppLocalized("MCP integrations"))
                    } icon: {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(PokiTheme.blueText)
                    }
                }
                NavigationLink {
                    RootfsManagementView()
                } label: {
                    Label(AppLocalized("Runtime environment"), systemImage: "shippingbox")
                }
            } header: {
                Text(AppLocalized("Amore connection"))
            } footer: {
                Text(AppLocalized("This page connects Amore services only. It does not enable Poki Runner, DeepSeek Harness, Cordis, or external automation without an Amore-compatible adapter."))
            }
            Section {
                Button {
                    showTerminal = true
                } label: {
                    Label(AppLocalized("Open Amore terminal"), systemImage: "terminal")
                }
            }
        }
        .pokiScreen()
        .navigationTitle(AppLocalized("Connect developer tools"))
        .sheet(isPresented: $showTerminal) {
            NavigationStack {
                ISHTerminalView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(AppLocalized("Done")) { showTerminal = false }
                        }
                    }
            }
        }
    }
}
