import SwiftUI

struct AmorePluginImportConfirmation: View {
    let selection: AmorePendingPluginImport
    let onInstall: () -> Void
    let onCancel: () -> Void
    @State private var accepted = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(selection.manifest.name, systemImage: "shippingbox.fill")
                        .font(.headline).foregroundStyle(PokiTheme.primaryText)
                    Text(selection.manifest.id + " · " + selection.manifest.version)
                        .font(.caption).foregroundStyle(PokiTheme.secondaryText)
                    Text(selection.manifest.description).font(.callout)
                }.listRowBackground(PokiTheme.surface)
                Section {
                    Label(AppLocalized("Local package · signature not verified"), systemImage: "exclamationmark.shield")
                        .foregroundStyle(PokiTheme.danger)
                    Text(AppLocalized("Install only plugins from authors you trust. Installation does not enable or execute the plugin."))
                        .font(.footnote).foregroundStyle(PokiTheme.secondaryText)
                }.listRowBackground(PokiTheme.surface)
                Section(AppLocalized("Permissions")) {
                    if selection.manifest.permissions.isEmpty {
                        Label(AppLocalized("No additional permissions"), systemImage: "checkmark.shield")
                    }
                    ForEach(selection.manifest.permissions, id: \.self) { permission in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(permission).font(.callout.monospaced())
                            Text(explanation(permission)).font(.footnote).foregroundStyle(PokiTheme.secondaryText)
                        }
                    }
                    Toggle(AppLocalized("I understand and approve these permissions"), isOn: $accepted)
                        .tint(PokiTheme.tagText)
                }.listRowBackground(PokiTheme.surface)
            }
            .pokiScreen()
            .pokiScreen()
            .navigationTitle(AppLocalized("Install plugin"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Install"), action: onInstall).disabled(!accepted)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func explanation(_ permission: String) -> String {
        if permission.hasPrefix("network:") {
            return AppLocalized("Connects only to the declared HTTPS host.")
        }
        switch permission {
        case "storage": return AppLocalized("Stores data in this plugin’s private local folder.")
        case "secrets": return AppLocalized("Reads secrets you explicitly configure for this plugin.")
        case "notify": return AppLocalized("Requests permission to show local notifications.")
        default: return permission
        }
    }
}
