import SwiftUI

/// Reusable by SettingsSheet (inside its NavigationStack) and the blank-chat sheet.
/// Observes the same store the live marquee does; hiding never deletes an item.
@MainActor
struct AmoreHomeShortcutManager: View {
    @ObservedObject private var store = AmoreHomeShortcutStore.shared
    @State private var editing: EditRequest?
    @State private var confirmRestore = false

    private struct EditRequest: Identifiable {
        var item: AmoreHomeShortcut
        var isNew: Bool
        var id: String { item.id }
    }

    var body: some View {
        List {
            Section {
                ForEach(store.items) { item in
                    HStack(spacing: 12) {
                        Button {
                            editing = EditRequest(item: item, isNew: false)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.symbol)
                                    .foregroundStyle(PokiTheme.blueText)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).foregroundStyle(PokiTheme.primaryText)
                                    Text(item.action.kind == .prompt ? item.action.value : pageDescription(item))
                                        .font(.footnote)
                                        .foregroundStyle(PokiTheme.secondaryText)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text(AppLocalized("Edit shortcut")))
                        Button {
                            store.setHidden(!item.hidden, id: item.id)
                        } label: {
                            Image(systemName: item.hidden ? "eye.slash" : "eye")
                                .foregroundStyle(item.hidden ? PokiTheme.secondaryText : PokiTheme.green)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(item.hidden ? AppLocalized("Show shortcut") : AppLocalized("Hide shortcut")))
                        .accessibilityValue(Text(item.hidden ? AppLocalized("Hidden") : AppLocalized("Visible")))
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.remove(id: item.id) } label: {
                            Label(AppLocalized("Delete"), systemImage: "trash")
                        }
                        Button { editing = EditRequest(item: item, isNew: false) } label: {
                            Label(AppLocalized("Edit"), systemImage: "pencil")
                        }
                    }
                }
                if store.items.isEmpty {
                    Text(AppLocalized("No shortcuts. Add one or restore the defaults."))
                        .foregroundStyle(PokiTheme.secondaryText)
                }
            } header: {
                Text(AppLocalized("Home shortcuts"))
            } footer: {
                Text(AppLocalized("Tap to edit. Prompts fill the existing message field without sending. Hidden shortcuts stay here until you show or delete them."))
            }
            Section {
                Button {
                    editing = EditRequest(item: .init(id: "custom-" + UUID().uuidString,
                        appName: "Amore", title: "", symbol: "sparkles",
                        action: .init(kind: .prompt, value: "")), isNew: true)
                } label: {
                    Label(AppLocalized("Add shortcut"), systemImage: "plus.circle")
                }
                Button { confirmRestore = true } label: {
                    Label(AppLocalized("Restore default shortcuts"), systemImage: "arrow.counterclockwise")
                }
            }
        }
        .pokiScreen()
        .navigationTitle(AppLocalized("Home shortcuts"))
        .sheet(item: $editing) { request in
            NavigationStack {
                AmoreHomeShortcutEditor(item: request.item, isNew: request.isNew)
            }
        }
        .confirmationDialog(AppLocalized("Restore default shortcuts?"), isPresented: $confirmRestore) {
            Button(AppLocalized("Restore defaults")) { store.restoreDefaults() }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalized("Default edits, deletions and visibility will be reset. Custom shortcuts are kept."))
        }
    }

    private func pageDescription(_ item: AmoreHomeShortcut) -> String {
        item.action.kind == .page ? AmoreShortcutRoutes.canonicalPage(item.action.value) : item.action.value
    }
}

@MainActor
struct AmoreHomeShortcutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AmoreHomeShortcutStore.shared
    @State private var item: AmoreHomeShortcut
    @State private var errorMessage: String?
    let isNew: Bool

    init(item: AmoreHomeShortcut, isNew: Bool) {
        _item = State(initialValue: item)
        self.isNew = isNew
    }

    var body: some View {
        Form {
            Section {
                TextField(AppLocalized("Button title"), text: $item.title)
                TextField(AppLocalized("SF Symbol name"), text: $item.symbol)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker(AppLocalized("Action"), selection: $item.action.kind) {
                    Text(AppLocalized("Prompt")).tag(AmoreHomeShortcut.Kind.prompt)
                    Text(AppLocalized("Amore page")).tag(AmoreHomeShortcut.Kind.page)
                    Text(AppLocalized("HTTPS link")).tag(AmoreHomeShortcut.Kind.link)
                }
            }
            Section {
                if item.action.kind == .page {
                    Picker(AppLocalized("Page"), selection: $item.action.value) {
                        ForEach(AmoreShortcutRoutes.pages, id: \.self) { page in
                            Text(page == "shortcuts" ? AppLocalized("Home shortcuts") : page).tag(page)
                        }
                    }
                } else {
                    TextField(item.action.kind == .prompt ? AppLocalized("Prompt") : "https://example.com",
                              text: $item.action.value, axis: .vertical)
                        .lineLimit(4...12)
                        .textInputAutocapitalization(item.action.kind == .link ? .never : .sentences)
                        .autocorrectionDisabled(item.action.kind == .link)
                }
            } footer: {
                Text(AppLocalized("Titles can contain up to 100 characters; actions up to 8000. Only supported Amore pages and HTTPS links are accepted. Nothing is sent automatically."))
            }
        }
        .navigationTitle(isNew ? AppLocalized("Add shortcut") : AppLocalized("Edit shortcut"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalized("Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalized("Save")) { save() }
                    .disabled(!AmoreShortcutRanking.valid(item))
            }
        }
        .onChange(of: item.action.kind) { kind in
            switch kind {
            case .page: item.action.value = "home"
            case .link: item.action.value = "https://"
            case .prompt: item.action.value = ""
            }
        }
        .alert(AppLocalized("Unable to save shortcut"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(AppLocalized("OK"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        do {
            item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            item.symbol = item.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
            item.edited = true
            if isNew { try store.add(item) } else { try store.update(item) }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
