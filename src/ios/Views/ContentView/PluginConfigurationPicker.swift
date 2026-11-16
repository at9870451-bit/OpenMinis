import SwiftUI
import AmorePluginArchive

/// Ambiguous archives never auto-execute the first JSON or the npm package entry.
struct AmorePluginConfigurationPicker: View {
    let selection: AmorePluginConfigurationSelection
    let onChoose: (PluginConfigurationCandidate) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(AppLocalized("Choose which plugin configuration to install. JSON files are configuration, not executable code."))
                        .font(.footnote).foregroundStyle(PokiTheme.secondaryText)
                }.listRowBackground(PokiTheme.surface)
                ForEach(selection.inspected.candidates) { candidate in
                    Button { onChoose(candidate) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundStyle(PokiTheme.blueText)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.name).font(.headline).foregroundStyle(PokiTheme.primaryText)
                                Text(candidate.relativePath).font(.caption.monospaced())
                                    .foregroundStyle(PokiTheme.secondaryText)
                                if !candidate.version.isEmpty {
                                    Text(candidate.kind + " · " + candidate.version)
                                        .font(.caption).foregroundStyle(PokiTheme.secondaryText)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(PokiTheme.secondaryText)
                        }.padding(.vertical, 5)
                    }.listRowBackground(PokiTheme.surface)
                }
            }
            .pokiScreen()
            .navigationTitle(AppLocalized("Choose plugin JSON"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel"), action: onCancel)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
