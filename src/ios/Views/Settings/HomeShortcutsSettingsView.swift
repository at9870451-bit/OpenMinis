import SwiftUI

struct HomeShortcutsSettingsView: View {
    @ObservedObject private var store = AmoreHomeShortcutStore.shared
    @State private var title = ""
    @State private var prompt = ""
    @State private var showingAdd = false

    var body: some View {
        List {
            Group {
            Section {
                ForEach(store.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol)
                            .foregroundStyle(PokiTheme.blueText)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).foregroundStyle(PokiTheme.primaryText)
                            Text(item.action.kind == .prompt ? AppLocalized("Prompt") : item.action.value)
                                .font(.footnote)
                                .foregroundStyle(PokiTheme.secondaryText)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button {
                            store.setVisible(item.hidden, id: item.id)
                        } label: {
                            Image(systemName: item.hidden ? "eye.slash" : "eye")
                                .foregroundStyle(item.hidden ? PokiTheme.secondaryText : PokiTheme.green)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button(role: .destructive) { store.remove(id: item.id) } label: {
                            Label(AppLocalized("Delete"), systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text(AppLocalized("Home shortcuts"))
            } footer: {
                Text(AppLocalized("These buttons fill the existing chat composer or open an Amore page. They do not send a message automatically."))
            }
            Section {
                Button {
                    showingAdd = true
                } label: {
                    Label(AppLocalized("Add shortcut"), systemImage: "plus.circle.fill")
                }
            }
            }
            .amoreSettingsGlassRows()
        }
        .amoreSettingsGlass()
        .navigationTitle(AppLocalized("Home shortcuts"))
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                Form {
                    TextField(AppLocalized("Button title"), text: $title)
                        .amoreSettingsGlassRows()
                    TextField(AppLocalized("Prompt"), text: $prompt, axis: .vertical)
                        .amoreSettingsGlassRows()
                }
                .amoreSettingsGlass()
                .navigationTitle(AppLocalized("Add shortcut"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(AppLocalized("Cancel")) { showingAdd = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppLocalized("Add")) {
                            let id = "custom-" + UUID().uuidString
                            let item = AmoreHomeShortcut(id: id, appName: "Amore", title: title, symbol: "sparkles", action: .init(kind: .prompt, value: prompt))
                            try? store.add(item)
                            title = ""; prompt = ""; showingAdd = false
                        }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}
