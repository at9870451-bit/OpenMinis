import SwiftUI

extension Notification.Name {
    /// Settings destinations without a SettingsDeepLinkTarget case. The root
    /// settings router consumes `object as? String` or userInfo["destination"].
    static let amoreOpenSidebarDestination = Notification.Name("amoreOpenSidebarDestination")
}

/// Presentation preferences only. Chat/session data continues to live solely
/// in ChatStore. Raw values are stable persistence IDs, never localized text.
enum AmoreSidebarShortcut: String, CaseIterable, Identifiable {
    case tools, subAgents, skills, memory, rootfs, localBot, soul
    case providers, modelGroups, usage, developerConnection, homeShortcuts, appearance
    case terminal, pluginMarketplace, contextCompression, mcpIntegrations, environments
    case storage, sharedFolders, mountedFolders, cloudSync, backupRestore
    case permissions, biometricProtection, logs, background, about, privacyPolicy, feedback

    enum Destination {
        case runtime(RuntimePage)
        case settings(SettingsDeepLinkTarget)
        case terminal
        case settingsNotification(String)
    }

    var id: String { rawValue }

    // Preserve all six legacy drawer entries; keep personalization reachable
    // now that the old account confirmation menu is replaced by direct Settings.
    static let defaults: [Self] = [.tools, .subAgents, .skills, .memory, .rootfs, .localBot, .soul]

    var isAvailable: Bool {
        switch self {
        // Keep the persisted IDs and decoder lossless for older preferences,
        // but retired footer actions cannot appear in the drawer/candidates.
        case .privacyPolicy, .feedback: return false
        case .cloudSync:
            if #available(iOS 17.0, *) { return true }
            return false
        case .biometricProtection: return BiometricAuth.isAvailable
        default: return true
        }
    }

    var destination: Destination {
        switch self {
        case .tools: return .runtime(.tools)
        case .subAgents: return .runtime(.subAgents)
        case .skills: return .runtime(.skills)
        case .memory: return .runtime(.memory)
        case .rootfs: return .runtime(.rootfs)
        case .localBot: return .runtime(.localBot)
        case .soul: return .runtime(.soul)
        case .providers: return .settings(.providers)
        case .modelGroups: return .settings(.modelGroups)
        case .usage: return .settings(.usage)
        case .developerConnection: return .settings(.developerConnection)
        case .appearance: return .settings(.appearance)
        case .mcpIntegrations: return .settings(.mcpIntegrations)
        case .environments: return .settings(.environments)
        case .storage: return .settings(.storage)
        case .sharedFolders: return .settings(.sharedFolders)
        case .mountedFolders: return .settings(.mountedFolders)
        case .permissions: return .settings(.permissions)
        case .logs: return .settings(.logs)
        case .background: return .settings(.background)
        case .about: return .settings(.about)
        case .terminal: return .terminal
        case .contextCompression: return .settingsNotification("context-compression")
        case .homeShortcuts: return .settingsNotification("home-shortcuts")
        case .pluginMarketplace: return .settingsNotification("plugin-marketplace")
        case .cloudSync: return .settingsNotification("icloud-sync")
        case .backupRestore: return .settingsNotification("backup-restore")
        case .biometricProtection: return .settingsNotification("biometric-protection")
        case .privacyPolicy: return .settingsNotification("privacy-policy")
        case .feedback: return .settingsNotification("feedback")
        }
    }

    init(runtimePage: RuntimePage) {
        switch runtimePage {
        case .tools: self = .tools
        case .subAgents: self = .subAgents
        case .skills: self = .skills
        case .memory: self = .memory
        case .rootfs: self = .rootfs
        case .localBot: self = .localBot
        case .soul: self = .soul
        }
    }

    var title: String {
        switch self {
        case .tools: return AppLocalized("Agent Tools")
        case .subAgents: return AppLocalized("Sub Agents")
        case .skills: return AppLocalized("Skills")
        case .memory: return AppLocalized("Memory")
        case .rootfs: return AppLocalized("Rootfs")
        case .localBot: return AppLocalized("SnowLuma + QQBot")
        case .soul: return AppLocalized("Personalize Amore")
        case .providers: return AppLocalized("Manage Providers")
        case .modelGroups: return AppLocalized("Model Groups")
        case .usage: return AppLocalized("Token Usage")
        case .developerConnection: return AppLocalized("Connect developer tools")
        case .homeShortcuts: return AppLocalized("Home shortcuts")
        case .appearance: return AppLocalized("Appearance")
        case .terminal: return AppLocalized("Terminal")
        case .pluginMarketplace: return AppLocalized("Plugin Marketplace")
        case .contextCompression: return AppLocalized("Context Compression")
        case .mcpIntegrations: return AppLocalized("MCP Integrations")
        case .environments: return AppLocalized("Environment Variables")
        case .storage: return AppLocalized("Storage")
        case .sharedFolders: return AppLocalized("Shared Folders")
        case .mountedFolders: return AppLocalized("Mount External Folders")
        case .cloudSync: return AppLocalized("iCloud Sync")
        case .backupRestore: return AppLocalized("Backup & Restore")
        case .permissions: return AppLocalized("Permissions")
        case .biometricProtection:
            return AppLocalized("\(BiometricAuth.biometryDisplayName) Protection")
        case .logs: return AppLocalized("Logs")
        case .background: return AppLocalized("Background")
        case .about: return AmoreSidebarText.about
        case .privacyPolicy: return AppLocalized("Privacy Policy")
        case .feedback: return AppLocalized("Feedback")
        }
    }

    var symbol: String {
        switch self {
        case .tools: return "wrench.and.screwdriver"
        case .subAgents: return "person.2"
        case .skills: return "puzzlepiece.extension"
        case .memory: return "brain.head.profile"
        case .rootfs: return "externaldrive"
        case .localBot: return "qrcode.viewfinder"
        case .soul: return "sparkles"
        case .providers: return "key"
        case .modelGroups: return "square.stack.3d.up"
        case .usage: return "chart.line.uptrend.xyaxis"
        case .developerConnection: return "point.3.connected.trianglepath.dotted"
        case .homeShortcuts: return "rectangle.3.group.bubble.left"
        case .appearance: return "paintbrush"
        case .terminal: return "terminal"
        case .pluginMarketplace: return "shippingbox"
        case .contextCompression: return "arrow.down.right.and.arrow.up.left"
        case .mcpIntegrations: return "puzzlepiece"
        case .environments: return "text.and.command.macwindow"
        case .storage: return "archivebox"
        case .sharedFolders: return "folder.badge.person.crop"
        case .mountedFolders: return "externaldrive.badge.plus"
        case .cloudSync: return "icloud"
        case .backupRestore: return "arrow.triangle.2.circlepath"
        case .permissions: return "lock.shield"
        case .biometricProtection: return BiometricAuth.biometryIconName
        case .logs: return "doc.text"
        case .background: return "moon"
        case .about: return "info.circle"
        case .privacyPolicy: return "hand.raised"
        case .feedback: return "bubble.left.and.bubble.right"
        }
    }
}

/// Versioned, ordered preference IDs. An explicit [] means no shortcuts, not
/// "reset to defaults". Unknown/duplicate IDs are ignored; corrupt JSON gets
/// the legacy-compatible defaults without touching any session data.
enum AmoreSidebarShortcutPreferences {
    static let storageKey = "amore.sidebar.shortcuts.v1"
    static let defaultValue = encode(AmoreSidebarShortcut.defaults)

    static func decode(_ raw: String) -> [AmoreSidebarShortcut] {
        guard let data = raw.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return AmoreSidebarShortcut.defaults
        }
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return AmoreSidebarShortcut(rawValue: id)
        }
    }

    static func encode(_ shortcuts: [AmoreSidebarShortcut]) -> String {
        guard let data = try? JSONEncoder().encode(shortcuts.map(\.rawValue)),
              let value = String(data: data, encoding: .utf8) else { return "[]" }
        return value
    }
}

/// Owns its editor/persistence state so ContentView needs no extra stored state.
/// A flat stack intentionally replaces the old disclosure + adaptive grid.
struct AmoreSidebarShortcuts: View {
    let interactionEnabled: Bool
    let open: (AmoreSidebarShortcut) -> Void
    @AppStorage(AmoreSidebarShortcutPreferences.storageKey)
    private var selection = AmoreSidebarShortcutPreferences.defaultValue
    @State private var showingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AmoreSidebarShortcutPreferences.decode(selection).filter { $0.isAvailable }) { shortcut in
                Button { open(shortcut) } label: {
                    DrawerShortcutLabel(title: shortcut.title, symbol: shortcut.symbol, accent: .primary)
                }
                .buttonStyle(ChatHistoryButtonStyle())
                .disabled(!interactionEnabled)
                .accessibilityLabel(shortcut.title)
                .accessibilityIdentifier("amore.sidebar.shortcut.\(shortcut.id)")
            }
            Button { showingEditor = true } label: {
                DrawerShortcutLabel(title: AmoreSidebarText.edit, symbol: "slider.horizontal.3", accent: .secondary)
            }
            .buttonStyle(ChatHistoryButtonStyle())
            .disabled(!interactionEnabled)
            .accessibilityHint(AmoreSidebarText.editHint)
            .accessibilityIdentifier("amore.sidebar.editShortcuts")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .sheet(isPresented: $showingEditor) {
            AmoreSidebarShortcutEditor(selection: $selection)
                .appFontScale()
        }
    }
}

/// Draft changes commit together with Done. Cancel/swipe-down leave the saved
/// sidebar unchanged. All selection/reorder/delete controls are at least 44pt.
struct AmoreSidebarShortcutEditor: View {
    @Binding private var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [AmoreSidebarShortcut]
    @State private var search = ""
    @State private var reordering = false

    init(selection: Binding<String>) {
        _selection = selection
        // Only the two deliberately retired footer IDs are hidden here;
        // do not drop platform-dependent choices or rewrite saved data on open.
        _draft = State(initialValue: AmoreSidebarShortcutPreferences.decode(selection.wrappedValue)
            .filter { $0 != .privacyPolicy && $0 != .feedback })
    }

    private var available: [AmoreSidebarShortcut] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return AmoreSidebarShortcut.allCases.filter {
            $0.isAvailable && !draft.contains($0) &&
                (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(draft) { shortcut in
                        selectedRow(shortcut)
                    }
                    .onMove { source, destination in
                        draft.move(fromOffsets: source, toOffset: destination)
                    }
                    .onDelete { offsets in draft.remove(atOffsets: offsets) }
                    if draft.isEmpty {
                        Text(AmoreSidebarText.empty)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    if !draft.isEmpty {
                        Button {
                            reordering.toggle()
                        } label: {
                            Label(reordering ? AmoreSidebarText.finishReorder : AmoreSidebarText.reorder,
                                  systemImage: "arrow.up.arrow.down")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("amore.sidebar.reorderShortcuts")
                    }
                } header: {
                    Text(AmoreSidebarText.selected)
                } footer: {
                    Text(AmoreSidebarText.reorderHint)
                }
                Section {
                    ForEach(available) { shortcut in
                        Button {
                            draft.append(shortcut)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: shortcut.symbol)
                                    .frame(width: 24)
                                    .accessibilityHidden(true)
                                Text(shortcut.title)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "plus.circle")
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(shortcut.title)
                        .accessibilityHint(AmoreSidebarText.add)
                        .accessibilityIdentifier("amore.sidebar.add.\(shortcut.id)")
                        .moveDisabled(true)
                        .deleteDisabled(true)
                    }
                    if available.isEmpty {
                        Text(AmoreSidebarText.noAvailable)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                } header: {
                    Text(AmoreSidebarText.available)
                } footer: {
                    Text(AmoreSidebarText.selectionHint)
                }
                Section {
                    Button {
                        draft = AmoreSidebarShortcut.defaults
                        reordering = false
                    } label: {
                        Text(AmoreSidebarText.restore)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
            .environment(\.editMode, .constant(reordering ? .active : .inactive))
            .searchable(text: $search, prompt: AmoreSidebarText.search)
            .navigationTitle(AmoreSidebarText.edit)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Done")) {
                        selection = AmoreSidebarShortcutPreferences.encode(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("amore.sidebar.saveShortcuts")
                }
            }
        }
    }

    private func selectedRow(_ shortcut: AmoreSidebarShortcut) -> some View {
        HStack(spacing: 12) {
            Image(systemName: shortcut.symbol)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(shortcut.title)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !reordering {
                Button(role: .destructive) {
                    draft.removeAll { $0 == shortcut }
                } label: {
                    Image(systemName: "minus.circle")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(AmoreSidebarText.remove): \(shortcut.title)")
                .accessibilityIdentifier("amore.sidebar.remove.\(shortcut.id)")
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shortcut.title)
        .accessibilityValue(AmoreSidebarText.selected)
        .accessibilityActions {
            if let index = draft.firstIndex(of: shortcut), index > 0 {
                Button(AmoreSidebarText.moveUp) { move(shortcut, by: -1) }
            }
            if let index = draft.firstIndex(of: shortcut), index + 1 < draft.count {
                Button(AmoreSidebarText.moveDown) { move(shortcut, by: 1) }
            }
            Button(AmoreSidebarText.remove) { draft.removeAll { $0 == shortcut } }
        }
    }

    private func move(_ shortcut: AmoreSidebarShortcut, by offset: Int) {
        guard let source = draft.firstIndex(of: shortcut),
              draft.indices.contains(source + offset) else { return }
        draft.swapAt(source, source + offset)
    }
}

/// New sidebar-only strings follow the app's language override, without editing
/// the shared settings agent's catalogs. Existing feature titles use AppLocalized.
enum AmoreSidebarText {
    private static func text(_ english: StaticString, _ simplified: String, _ traditional: String) -> String {
        let language = AppBundle.current.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
        guard language.hasPrefix("zh") else { return AppLocalized(english) }
        return language.contains("Hant") || language.contains("TW") || language.contains("HK")
            ? traditional : simplified
    }

    static var newConversation: String { text("New Conversation", "新会话", "新會話") }
    static var newConversationShort: String { text("New Chat", "新会话", "新會話") }
    static var about: String { text("About Amore", "关于 Amore", "關於 Amore") }
    static var edit: String { text("Edit / Choose Shortcuts", "修改/选择快捷功能", "修改/選擇快捷功能") }
    static var editHint: String { text("Choose, remove and reorder sidebar shortcuts", "选择、删除并排序侧栏快捷入口", "選擇、刪除並排序側欄快捷入口") }
    static var selected: String { text("Selected Shortcuts", "已选快捷功能", "已選快捷功能") }
    static var available: String { text("Add from Settings", "从设置选择添加", "從設定選擇加入") }
    static var empty: String { text("No shortcuts selected. Choose any settings below.", "尚未选择快捷功能，可从下方多选添加。", "尚未選擇快捷功能，可從下方多選加入。") }
    static var reorder: String { text("Reorder Shortcuts", "调整排列顺序", "調整排列順序") }
    static var finishReorder: String { text("Finish Reordering", "完成排序", "完成排序") }
    static var reorderHint: String { text("Drag to reorder, swipe to delete, or use VoiceOver actions. Tap Done to save.", "可拖动排序、左滑删除，或使用 VoiceOver 操作。点“完成”后保存。", "可拖動排序、向左滑動刪除，或使用 VoiceOver 操作。點「完成」後儲存。") }
    static var selectionHint: String { text("Select multiple features to add. Removing a shortcut never disables that feature in Settings.", "可连续选择多个功能。移除快捷入口不会停用设置中的原功能。", "可連續選擇多個功能。移除快捷入口不會停用設定中的原功能。") }
    static var noAvailable: String { text("No matching features to add", "没有可添加的匹配功能", "沒有可加入的符合功能") }
    static var add: String { text("Add to sidebar", "添加到侧栏", "加入側欄") }
    static var remove: String { text("Remove shortcut", "移除快捷入口", "移除快捷入口") }
    static var moveUp: String { text("Move up", "向上移动", "向上移動") }
    static var moveDown: String { text("Move down", "向下移动", "向下移動") }
    static var restore: String { text("Restore Default Shortcuts", "恢复默认快捷功能", "還原預設快捷功能") }
    static var search: String { text("Search settings features", "搜索设置功能", "搜尋設定功能") }
}
