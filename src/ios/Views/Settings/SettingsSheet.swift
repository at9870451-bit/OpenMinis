//
//  SettingsSheet.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  The settings screen presented from the home toolbar: its navigation
//  destinations and the top-level list linking to every settings page.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI
import SafariServices
import AmoreDeviceKit

// MARK: - Settings Sheet

private enum SettingsDestination: Hashable {
    case providers
    case providerDetail(instanceId: String)
    case modelGroups
    case modelGroupDetail(groupId: String)
    case usage
    case skills
    // [T-ios-assistant-header-open-soul]
    case soul
    // [T-tools-master-switch]
    case tools
    case memory
    case contextCompression
    case storage
    case mountedFolders
    case sharedFolders
    case logs
    case appearance
    case background
    case about
    case permissions
    case environments
    // [T-mcp-oauth-deeplink]
    case mcpIntegrations
    case mcpServerDetail(serverId: String)
    case developerConnection
    case homeShortcuts
    // Local shortcuts use these routes without changing the shared deep-link enum.
    case subAgents
    case rootfs
    case terminal
    case plugins
    case cloudSync
    case backupRestore
    case biometricProtection
}

struct SettingsSheet: View {
    @Binding var showTerminal: Bool
    /// When shown as a bottom-tab page instead of a sheet, hide the Done
    /// button — there is nothing to dismiss.
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    @ObservedObject private var sidebarRouter = AmoreSettingsShortcutRouter.shared
    @State private var navPath = NavigationPath()
    @State private var showFeedbackDialog = false
    @State private var showPrivacyPolicy = false

    var body: some View {
        NavigationStack(path: $navPath) {
            // Destinations belong to this eager stack child, never to a lazy List row.
            VStack(spacing: 0) {
            List {
                Section {
                    NavigationLink {
                        ProviderInstancesView()
                    } label: {
                        if #available(iOS 26, *) {
                            Label { Text("Manage Providers") } icon: { SettingsFeatureIcon(symbol: "key.circle.fill", feature: .providers) }
                        } else {
                            Label { Text("Manage Providers") } icon: { SettingsFeatureIcon(symbol: "lock.circle.fill", feature: .providers) }
                        }
                    }

                    NavigationLink {
                        ModelGroupsView()
                    } label: {
                        Label { Text("Model Groups") } icon: { SettingsFeatureIcon(symbol: "gearshape.circle.fill", feature: .modelGroups) }
                    }

                    NavigationLink {
                        UsageStatsView()
                    } label: {
                        Label { Text("Token Usage") } icon: { SettingsFeatureIcon(symbol: "chart.line.uptrend.xyaxis.circle.fill", feature: .usage) }
                    }
                } header: {
                    Text("LLM Providers")
                } footer: {
                    Text("Configure which models the agent uses, manage API keys & OAuth for each provider, and create model groups for fallback or load balancing.")
                }

                Section("Appearance") {
                    NavigationLink(value: SettingsDestination.developerConnection) {
                        Label { Text(AppLocalized("Connect developer tools")) } icon: { SettingsFeatureIcon(symbol: "point.3.connected.trianglepath.dotted", feature: .developerConnection) }
                    }
                    .accessibilityIdentifier("settings.developerConnection")
                    NavigationLink(value: SettingsDestination.homeShortcuts) {
                        Label { Text(AppLocalized("Home shortcuts")) } icon: { SettingsFeatureIcon(symbol: "rectangle.3.group.bubble.left.fill", feature: .homeShortcuts) }
                    }
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        Label {
                            Text("Appearance")
                        } icon: {
                            SettingsFeatureIcon(symbol: "paintbrush.fill", feature: .appearance)
                        }
                    }
                }

                Section("Agent Runtime") {
                    // [T-tools-granular-switches] First row: per-tool switches.
                    NavigationLink {
                        ToolsSettingsView()
                    } label: {
                        Label {
                            Text(AppLocalized("Agent Tools"))
                        } icon: {
                            SettingsFeatureIcon(symbol: "wrench.and.screwdriver.fill", feature: .tools)
                        }
                    }
                    // [T-sub-agents-v1] Directly under Agent Tools: the two pages
                    // are the tool surface (which tools exist) and the delegation
                    // surface (who runs a delegated task), so they read as a pair.
                    NavigationLink {
                        HelperSettingsView()
                    } label: {
                        Label {
                            Text(AppLocalized("Sub Agents"))
                        } icon: {
                            SettingsFeatureIcon(symbol: HelperAccent.glyph, feature: .subAgents)
                        }
                    }
                    NavigationLink {
                        SkillsManagementView()
                    } label: {
                        Label {
                            Text("Skills")
                        } icon: {
                            SettingsFeatureIcon(symbol: "puzzlepiece.extension", feature: .skills)
                        }
                    }
                    NavigationLink {
                        SoulSettingsView()
                    } label: {
                        Label {
                            Text("Soul")
                        } icon: {
                            SettingsFeatureIcon(symbol: "sparkles", feature: .soul)
                        }
                    }
                    NavigationLink {
                        RootfsManagementView()
                    } label: {
                        Label { Text(AppLocalized("Rootfs")) } icon: { SettingsFeatureIcon(symbol: "externaldrive", feature: .rootfs) }
                    }
                    NavigationLink {
                        ISHTerminalView()
                    } label: {
                        Label { Text(AppLocalized("Terminal")) } icon: { SettingsFeatureIcon(symbol: "terminal", feature: .terminal) }
                    }
                    NavigationLink {
                        AmoreMarketplaceView()
                    } label: {
                        Label { Text(AppLocalized("Plugin Marketplace")) } icon: { SettingsFeatureIcon(symbol: "shippingbox", feature: .plugins) }
                    }
                    NavigationLink {
                        MemoryManagementView()
                    } label: {
                        Label {
                            Text("Memory")
                        } icon: {
                            SettingsFeatureIcon(symbol: "brain.head.profile", feature: .memory)
                        }
                    }
                    NavigationLink {
                        ContextCompressionSettingsView()
                    } label: {
                        Label {
                            Text(AppLocalized("Context Compression"))
                        } icon: {
                            SettingsFeatureIcon(symbol: "arrow.down.right.and.arrow.up.left", feature: .contextCompression)
                        }
                    }
                    NavigationLink {
                        MCPIntegrationsView()
                    } label: {
                        Label {
                            Text("MCP Integrations")
                        } icon: {
                            SettingsFeatureIcon(symbol: "square.stack.3d.up", feature: .mcp)
                        }
                    }
                    NavigationLink {
                        EnvironmentVariablesView()
                    } label: {
                        Label {
                            Text("Environment Variables")
                        } icon: {
                            SettingsFeatureIcon(symbol: "terminal", feature: .environments)
                        }
                    }
                }

                Section("Storage") {
                    NavigationLink {
                        StorageManagementView()
                    } label: {
                        Label {
                            Text("Storage")
                        } icon: {
                            SettingsFeatureIcon(symbol: "archivebox", feature: .storage)
                        }
                    }
                    NavigationLink {
                        SharedFoldersSettingsView()
                    } label: {
                        Label {
                            Text("Shared Folders")
                        } icon: {
                            SettingsFeatureIcon(symbol: "folder.fill.badge.person.crop", feature: .sharedFolders)
                        }
                    }
                    NavigationLink {
                        MountedFoldersSettingsView()
                    } label: {
                        Label {
                            Text("Mount External Folders")
                        } icon: {
                            SettingsFeatureIcon(symbol: "externaldrive.badge.plus", feature: .mountedFolders)
                        }
                    }
                    if #available(iOS 17.0, *) {
                        NavigationLink {
                            // v2 is the default sync engine; legacy v1
                            // settings page is unreachable from here.
                            CloudSyncSettingsV2View()
                        } label: {
                            Label {
                                Text("iCloud Sync")
                            } icon: {
                                SettingsFeatureIcon(symbol: "icloud", feature: .iCloud)
                            }
                        }
                    }
                    NavigationLink {
                        BackupAndRestoreView()
                    } label: {
                        Label {
                            // Not just "Backup": this screen is both halves of
                            // the feature, and on a new device restore is the
                            // only one the user is looking for.
                            Text("Backup & Restore")
                        } icon: {
                            // arrow.triangle.2.circlepath reads as a round trip
                            // rather than a one-way export.
                            SettingsFeatureIcon(symbol: "arrow.triangle.2.circlepath", feature: .backup)
                        }
                    }
                }

                Section("Permissions") {
                    NavigationLink {
                        OffloadPermissionSettingsView()
                    } label: {
                        Label {
                            Text("Permissions")
                        } icon: {
                            SettingsFeatureIcon(symbol: "lock.shield", feature: .permissions)
                        }
                    }
                    if BiometricAuth.isAvailable {
                        NavigationLink {
                            FaceIDProtectionSettingsView()
                        } label: {
                            Label {
                                Text("\(BiometricAuth.biometryDisplayName) Protection")
                            } icon: {
                                SettingsFeatureIcon(symbol: BiometricAuth.biometryIconName, feature: .biometric)
                            }
                        }
                    }
                }

                Section("Logs") {
                    NavigationLink {
                        LogManagementView()
                    } label: {
                        Label {
                            Text("Logs")
                        } icon: {
                            SettingsFeatureIcon(symbol: "doc.text", feature: .logs)
                        }
                    }
                }

                Section("About") {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label {
                            Text("About Minis")
                        } icon: {
                            SettingsFeatureIcon(symbol: "info", feature: .about)
                        }
                    }
                    Button { showPrivacyPolicy = true } label: {
                        Label {
                            Text("Privacy Policy")
                        } icon: {
                            SettingsFeatureIcon(symbol: "hand.raised", feature: .privacy)
                        }
                    }
                    Button {
                        showFeedbackDialog = true
                    } label: {
                        Label {
                            Text("Feedback")
                        } icon: {
                            SettingsFeatureIcon(symbol: "bubble.left.and.bubble.right.fill", feature: .feedback)
                        }
                    }
                    .foregroundStyle(PokiTheme.primaryText)
                }

            }
            }
            .amoreDeviceSetupDestinations()
            .pokiScreen()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .navigationDestination(for: SettingsDestination.self) { dest in
                switch dest {
                case .providers:
                    ProviderInstancesView()
                case .providerDetail(let id):
                    ProviderInstanceDetailView(instanceId: id)
                case .modelGroups:
                    ModelGroupsView()
                case .modelGroupDetail(let id):
                    ModelGroupDetailView(groupId: id)
                case .usage:
                    UsageStatsView()
                case .skills:
                    SkillsManagementView()
                case .soul:
                    SoulSettingsView()
                case .tools:
                    ToolsSettingsView()
                case .memory:
                    MemoryManagementView()
                case .contextCompression:
                    ContextCompressionSettingsView()
                case .storage:
                    StorageManagementView()
                case .mountedFolders:
                    MountedFoldersSettingsView()
                case .sharedFolders:
                    SharedFoldersSettingsView()
                case .logs:
                    // Pull a one-shot tab hint from the deep link router
                    // (e.g. `?tab=config-audit`). LogManagementView clears
                    // its local state independently; the published value
                    // here is consumed once and reset to nil.
                    LogManagementView(initialTab: deepLink.pendingLogsTab ?? "logs")
                        .onAppear { deepLink.pendingLogsTab = nil }
                case .appearance:
                    AppearanceSettingsView()
                case .background:
                    EnhancedBackgroundSettingsView()
                case .about:
                    AboutView()
                case .environments:
                    EnvironmentVariablesView()
                case .permissions:
                    OffloadPermissionSettingsView()
                // [T-mcp-oauth-deeplink] Detail = the list view told to open
                // the server's edit sheet on appear; a deleted/unknown server
                // just lands on the list (no crash, sensible fallback).
                case .mcpIntegrations:
                    MCPIntegrationsView()
                case .mcpServerDetail(let serverId):
                    MCPIntegrationsView(initialEditServerId: serverId)
                case .developerConnection:
                    DeveloperConnectionView()
                case .homeShortcuts:
                    HomeShortcutsSettingsView()
                case .subAgents:
                    HelperSettingsView()
                case .rootfs:
                    RootfsManagementView()
                case .terminal:
                    ISHTerminalView()
                case .plugins:
                    AmoreMarketplaceView()
                case .cloudSync:
                    if #available(iOS 17.0, *) { CloudSyncSettingsV2View() }
                case .backupRestore:
                    BackupAndRestoreView()
                case .biometricProtection:
                    if BiometricAuth.isAvailable { FaceIDProtectionSettingsView() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .amoreOpenSidebarDestination)) { _ in
                // The host stores before posting. An onChange/onAppear may have
                // already consumed it: never navigate twice for the same event.
                if let payload = sidebarRouter.consume() { applySidebarDestination(payload) }
            }
            .onChange(of: sidebarRouter.pending) { _ in
                if let payload = sidebarRouter.consume() { applySidebarDestination(payload) }
            }
            .onAppear {
                applyPendingDeepLink()
                if let payload = sidebarRouter.consume() { applySidebarDestination(payload) }
                // Legacy flags — kept so older call sites keep working.
                if deepLink.showEnvironmentVariables {
                    navPath.append(SettingsDestination.environments)
                    deepLink.showEnvironmentVariables = false
                }
                if deepLink.showPermissions {
                    navPath.append(SettingsDestination.permissions)
                    deepLink.showPermissions = false
                }
                // Restore the user's location after a language-change rebuild.
                // AppearanceSettingsView's language picker writes this flag
                // right before flipping `appLanguage`, knowing the root
                // `.id(appLanguage)` will tear the whole tree down. ContentView
                // re-opens the sheet on re-mount; here we push back to the
                // destination so the user lands where they were, now rendered
                // in the new language.
                if let dest = UserDefaults.standard.string(forKey: "pendingSettingsReopen") {
                    UserDefaults.standard.removeObject(forKey: "pendingSettingsReopen")
                    switch dest {
                    case "appearance":
                        navPath.append(SettingsDestination.appearance)
                    default:
                        break
                    }
                }
            }
            .onChange(of: deepLink.pendingSettingsTarget) { _ in
                applyPendingDeepLink()
            }
        }
        .appFontScale()
        // The sidebar can request Feedback before the lazy last row exists.
        .confirmationDialog("Feedback", isPresented: $showFeedbackDialog, titleVisibility: .visible) {
            Button("Report a Bug (GitHub)") {
                if let url = Self.makeBugReportURL() { UIApplication.shared.open(url) }
            }
            Button("Feedback (Telegram)") {
                if let url = URL(string: "https://t.me/+2NzhOJuzRyI1YmM1") { UIApplication.shared.open(url) }
            }
            Button("Feedback (Email)") {
                if let url = Self.makeFeedbackEmailURL() { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            SettingsPrivacyBrowser(url: URL(string: "https://openminis.github.io/privacy-policy.html")!)
                .ignoresSafeArea()
        }
    }

    /// Contract for `amoreOpenSidebarDestination`. The host calls
    /// AmoreSettingsShortcutRouter.shared.open(payload) before presentation;
    /// onAppear/onChange/onReceive all consume that same replayable slot.
    static let supportedShortcutDestinations: Set<String> = [
        "home-shortcuts", "marquee", "context-compression", "plugin-marketplace",
        "icloud-sync", "backup-restore", "biometric-protection", "privacy-policy", "feedback",
        "developer-connection", "connection", "sub-agents", "rootfs", "terminal"
    ]

    func applySidebarDestination(_ route: String) {
        let destination: SettingsDestination
        switch route {
        case "home-shortcuts", "marquee": destination = .homeShortcuts
        case "context-compression": destination = .contextCompression
        case "plugin-marketplace": destination = .plugins
        case "icloud-sync":
            guard #available(iOS 17.0, *) else { return }
            destination = .cloudSync
        case "backup-restore": destination = .backupRestore
        case "biometric-protection":
            guard BiometricAuth.isAvailable else { return }
            destination = .biometricProtection
        case "developer-connection", "connection": destination = .developerConnection
        case "sub-agents": destination = .subAgents
        case "rootfs": destination = .rootfs
        case "terminal": destination = .terminal
        case "privacy-policy":
            showPrivacyPolicy = true
            return
        case "feedback":
            navPath = NavigationPath()
            showFeedbackDialog = true
            return
        default: return
        }
        navPath = NavigationPath()
        navPath.append(destination)
    }

    /// Translate `DeepLinkCoordinator.pendingSettingsTarget` into a
    /// NavigationStack push and clear the pending value. Called from
    /// `onAppear` (cold-start deep link) and `onChange` (deep link
    /// arriving while the sheet is already open).
    ///
    /// `.environments` keeps its existing prefill semantics — the
    /// environments view consumes `pendingEnvVarCreate` separately on
    /// appear, so we only have to navigate here.
    private func applyPendingDeepLink() {
        guard let target = deepLink.pendingSettingsTarget else { return }
        // Reset path so deep links are predictable: a deep link always
        // lands on the requested destination as the only stack entry,
        // not on top of whatever the user was browsing earlier.
        navPath = NavigationPath()
        switch target {
        case .home:
            break // already at Settings root
        case .providers:
            navPath.append(SettingsDestination.providers)
        case .providerDetail(let id):
            navPath.append(SettingsDestination.providers)
            navPath.append(SettingsDestination.providerDetail(instanceId: id))
        case .modelGroups:
            navPath.append(SettingsDestination.modelGroups)
        case .modelGroupDetail(let id):
            navPath.append(SettingsDestination.modelGroups)
            navPath.append(SettingsDestination.modelGroupDetail(groupId: id))
        case .usage:
            navPath.append(SettingsDestination.usage)
        case .skills:
            navPath.append(SettingsDestination.skills)
        case .soul:
            navPath.append(SettingsDestination.soul)
        case .tools:
            navPath.append(SettingsDestination.tools)
        case .memory:
            navPath.append(SettingsDestination.memory)
        case .storage:
            navPath.append(SettingsDestination.storage)
        case .mountedFolders:
            navPath.append(SettingsDestination.mountedFolders)
        case .sharedFolders:
            navPath.append(SettingsDestination.sharedFolders)
        case .logs:
            navPath.append(SettingsDestination.logs)
        case .appearance:
            navPath.append(SettingsDestination.appearance)
        case .background:
            navPath.append(SettingsDestination.background)
        case .about:
            navPath.append(SettingsDestination.about)
        case .permissions:
            navPath.append(SettingsDestination.permissions)
        case .environments:
            navPath.append(SettingsDestination.environments)
        case .developerConnection:
            navPath.append(SettingsDestination.developerConnection)
        case .mcpIntegrations:
            navPath.append(SettingsDestination.mcpIntegrations)
        case .mcpServerDetail(let id):
            navPath.append(SettingsDestination.mcpServerDetail(serverId: id))
        }
        deepLink.pendingSettingsTarget = nil
    }

    /// Compose the feedback mailto URL with a prefilled body that includes
    /// app version, iOS version, and a machine identifier, plus a prompt
    /// asking the user to attach a screenshot manually (mailto:// can't
    /// auto-attach). Using URLComponents so the subject and body go through
    /// proper URL encoding without hand-rolling addingPercentEncoding calls.
    fileprivate static func makeFeedbackEmailURL() -> URL? {
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let iosVersion = UIDevice.current.systemVersion
        let device = machineIdentifier()

        let body = """
        Please describe your feedback:


        ---
        App Version: \(appVersion) (\(build))
        iOS Version: \(iosVersion)
        Device: \(device)

        Screenshot (optional): Please attach a screenshot if relevant.
        """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "dev@openminis.app"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Minis Feedback"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    /// Build the GitHub Issue URL with a bilingual bug-report template
    /// pre-filled with platform / OS / app / device info. SwiftUI `Link`
    /// hands the URL to UIApplication.shared.open, which routes to Safari.
    fileprivate static func makeBugReportURL() -> URL? {
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let iosVersion = UIDevice.current.systemVersion
        let device = machineIdentifier()

        let body = """
        ## 📝 Problem Summary

        <!-- Briefly describe the issue you encountered -->


        ## 📱 Basic Information

        | Field | Value |
        |-------|-------|
        | Platform | iOS |
        | OS Version | iOS \(iosVersion) |
        | Minis Version | \(appVersion) (build \(build)) |
        | Device Model | \(device) |

        ## 🔁 Steps to Reproduce

        1.
        2.
        3.

        ## ❌ Error Details

        ```
        paste error here
        ```

        ## ✅ Expected Behavior



        ## 🗂️ Additional Information

        """

        var components = URLComponents(string: "https://github.com/OpenMinis/OpenMinis/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.md"),
            URLQueryItem(name: "title", value: "[Bug] "),
            URLQueryItem(name: "body", value: body),
        ]
        return components?.url
    }

    /// Returns the hardware model identifier, e.g. "iPhone16,2".
    /// `UIDevice.current.model` returns the generic "iPhone" / "iPad" and
    /// isn't useful in a bug report, so we fall back to utsname.
    private static func machineIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        let id = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return id.isEmpty ? UIDevice.current.model : id
    }
}

/// Settings privacy opens in-app and returns to the same settings stack.
private struct SettingsPrivacyBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

// MARK: - Context Compression Settings

struct ContextCompressionSettingsView: View {
    @AppStorage(ContextCompressionSettings.autoCompactKey)
    private var autoCompact = true
    @AppStorage(ContextCompressionSettings.keepRecentIterationsKey)
    private var keepRecent = ContextCompressionSettings.defaultKeepRecentIterations

    var body: some View {
        List {
            Section {
                Toggle(isOn: $autoCompact) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppLocalized("Auto-compress long chats"))
                            Text(AppLocalized("Summarise older turns before the model runs out of context"))
                                .font(.footnote)
                                .foregroundStyle(PokiTheme.secondaryText)
                        }
                    } icon: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                }
            } footer: {
                Text(AppLocalized("When a conversation approaches the model's context window, Amore replaces older turns with a rolling summary and keeps the last few turns verbatim. Turning this off keeps full history; if the window still fills up, old tool output may be collapsed rather than summarised."))
            }

            Section {
                Stepper(value: $keepRecent, in: 1...10) {
                    HStack {
                        Text(AppLocalized("Keep recent turns"))
                        Spacer()
                        Text("\(keepRecent)")
                            .foregroundStyle(PokiTheme.secondaryText)
                            .monospacedDigit()
                    }
                }
                .disabled(!autoCompact)
            } header: {
                Text(AppLocalized("Detail"))
            } footer: {
                Text(AppLocalized("How many of the newest turns survive compaction verbatim. When the context is critically tight, Amore always keeps at least one turn regardless of this setting."))
            }

            Section {
                thresholdRow("Under 32K", "Manual only")
                thresholdRow("32K – 64K", "Offload at 10K left")
                thresholdRow("64K – 128K", "Compress at 10K left")
                thresholdRow("128K and up", "Compress at 20K left")
                thresholdRow("User-capped group", "Compress at 85%")
            } header: {
                Text(AppLocalized("How thresholds work"))
            } footer: {
                Text(AppLocalized("Thresholds follow the active model's context window. Smaller windows keep more headroom because the summary itself has to fit."))
            }

            Section {
                Button(AppLocalized("Restore Defaults")) {
                    autoCompact = true
                    keepRecent = ContextCompressionSettings.defaultKeepRecentIterations
                }
            } footer: {
                Text(AppLocalized("You can still compress a conversation by hand: long-press a message and choose “Compact Above”."))
            }
        }
        .navigationTitle(AppLocalized("Context Compression"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Both sides go through AppLocalized: `LabeledContent(_:value:)` treats the
    /// value as a plain String, so a literal there would never be translated.
    private func thresholdRow(_ label: StaticString, _ value: StaticString) -> some View {
        HStack {
            Text(AppLocalized(label))
            Spacer()
            Text(AppLocalized(value))
                .foregroundStyle(PokiTheme.secondaryText)
        }
    }
}

#Preview {
    ContentView()
}
// MARK: - Plugin Marketplace (GitHub-backed, real network)

/// Discovers community plugins through the public GitHub Search API.
/// No fake entries: when the call fails or the rate limit is hit, the UI says so.
struct AmoreMarketplaceItem: Identifiable, Decodable, Sendable {
    struct Owner: Decodable, Sendable { let login: String }
    let id: Int
    let name: String
    let fullName: String
    let htmlURL: String
    let description: String?
    let stars: Int
    let owner: Owner

    enum CodingKeys: String, CodingKey {
        case id, name, description, owner
        case fullName = "full_name"
        case htmlURL = "html_url"
        case stars = "stargazers_count"
    }
}

@MainActor
final class AmoreMarketplaceStore: ObservableObject {
    enum Phase { case idle, loading, loaded, failed(String) }

    @Published var phase: Phase = .idle
    @Published var items: [AmoreMarketplaceItem] = []
    @Published var isRateLimited = false

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func load() async {
        guard case .loading = phase else { phase = .loading; return await fetch() }
    }

    func reload() async {
        phase = .loading
        await fetch()
    }

    private func fetch() async {
        // topic:amore-plugin is the registry-wide discovery convention.
        var comps = URLComponents(string: "https://api.github.com/search/repositories")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: "topic:amore-plugin"),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "30"),
        ]
        guard let url = comps?.url else {
            phase = .failed(AppLocalized("Invalid marketplace URL"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Amore-iOS", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                phase = .failed(AppLocalized("No response from GitHub"))
                return
            }
            if http.statusCode == 403 || http.statusCode == 429 {
                isRateLimited = true
                let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "?"
                phase = .failed("GitHub rate limit reached (reset \(reset))")
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                phase = .failed("GitHub returned \(http.statusCode)")
                return
            }
            struct Envelope: Decodable { let items: [AmoreMarketplaceItem] }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            items = envelope.items
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

struct AmoreMarketplaceView: View {
    @StateObject private var store = AmoreMarketplaceStore()
    @StateObject private var importer = AmorePluginImportStore()
    @State private var pickerMode: AmorePluginPickerMode?
    @State private var recordToDelete: AmoreInstalledPlugin?
    @State private var queuedSelection: URL?
    @State private var queuedFolder = false

    var body: some View {
        List {
            Section {
                Button {
                    pickerMode = .archive
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.zipper").font(.title2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppLocalized("Import ZIP plugin")).font(.headline)
                            Text(AppLocalized("Choose a ZIP from Files or iCloud Drive"))
                                .font(.caption).opacity(0.8)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                    }
                    .foregroundStyle(PokiTheme.primaryButtonText)
                    .padding(.vertical, 12).padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PokiTheme.primaryButton, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .disabled(importer.isWorking)
                Button {
                    pickerMode = .folder
                } label: {
                    Label(AppLocalized("Import plugin folder"), systemImage: "folder.badge.plus")
                        .foregroundStyle(PokiTheme.primaryText)
                }
                .disabled(importer.isWorking)
                .listRowBackground(PokiTheme.surface)
                if importer.isWorking {
                    HStack(spacing: 10) {
                        ProgressView().tint(PokiTheme.tagText)
                        Text(importer.phaseText).font(.callout).foregroundStyle(PokiTheme.secondaryText)
                    }.listRowBackground(PokiTheme.surface)
                }
            } header: {
                Text(AppLocalized("Local plugins"))
            } footer: {
                Text(AppLocalized("ZIP import works without starting Terminal or downloading a Linux image. Maximum 10 MB and 500 files."))
                Text(AppLocalized("Amore scans JSON configuration files in the package. Compatible Amore JSON can have any filename; Node.js and Cordis packages need a port."))
            }

            Section(AppLocalized("Installed plugins")) {
                if importer.installed.isEmpty {
                    Label(AppLocalized("No installed plugins"), systemImage: "shippingbox")
                        .foregroundStyle(PokiTheme.secondaryText)
                }
                ForEach(importer.installed, id: \.id) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: "shippingbox.fill").foregroundStyle(PokiTheme.tagText)
                            Text(record.id).font(.callout.weight(.medium)).lineLimit(2)
                            Spacer()
                            Text(record.version).font(.caption.monospaced()).foregroundStyle(PokiTheme.secondaryText)
                        }
                        Text(record.enabled ? AppLocalized("Enabled") : AppLocalized("Installed · disabled"))
                            .font(.caption).foregroundStyle(PokiTheme.secondaryText)
                        Button(role: .destructive) { recordToDelete = record } label: {
                            Label(AppLocalized("Uninstall"), systemImage: "trash")
                                .font(.caption).foregroundStyle(PokiTheme.danger)
                        }.buttonStyle(.borderless)
                    }
                }
            }.listRowBackground(PokiTheme.surface)

            Section {
                switch store.phase {
                case .idle, .loading:
                    HStack { ProgressView(); Text(AppLocalized("Searching GitHub…")) }
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(PokiTheme.secondaryText)
                    Button(AppLocalized("Retry")) { Task { await store.reload() } }
                case .loaded:
                    if store.items.isEmpty {
                        Label(AppLocalized("No plugins yet"), systemImage: "magnifyingglass")
                            .foregroundStyle(PokiTheme.secondaryText)
                    }
                    ForEach(store.items) { item in
                        if let url = URL(string: item.htmlURL) {
                            Link(destination: url) {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(item.name).font(.body.weight(.medium)).foregroundStyle(PokiTheme.primaryText)
                                        Text(AppLocalized("Unverified")).font(.caption2.weight(.medium))
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .background(PokiTheme.tagBackground, in: Capsule())
                                            .foregroundStyle(PokiTheme.tagText)
                                    }
                                    Text(item.fullName).font(.caption).foregroundStyle(PokiTheme.secondaryText)
                                    if let description = item.description, !description.isEmpty {
                                        Text(description).font(.caption).foregroundStyle(PokiTheme.secondaryText).lineLimit(3)
                                    }
                                    Text("★ \(item.stars)").font(.caption2).foregroundStyle(PokiTheme.secondaryText)
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
            } header: {
                Text(AppLocalized("Community plugins"))
            } footer: {
                Text(AppLocalized("These repositories are not reviewed by Amore. Install only what you can audit."))
            }.listRowBackground(PokiTheme.surface)
        }
        .pokiScreen()
        .navigationTitle(AppLocalized("Plugin Marketplace"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pickerMode, onDismiss: {
            if let selected = queuedSelection {
                queuedSelection = nil
                importer.selected(selected, folder: queuedFolder)
            }
        }) { mode in
            AmorePluginDocumentPicker(folder: mode == .folder, onSelection: { result in
                switch result {
                case .success(let url):
                    queuedSelection = url
                    queuedFolder = mode == .folder
                case .failure(let error): importer.pickerFailed(error)
                }
                pickerMode = nil
            }, onCancel: {
                queuedSelection = nil
                pickerMode = nil
            })
            .id(mode.id)
        }
        .sheet(item: $importer.configurations, onDismiss: { importer.configurationDismissed() }) { selection in
            AmorePluginConfigurationPicker(selection: selection,
                onChoose: { importer.chooseConfiguration($0) },
                onCancel: { importer.cancelConfiguration() })
        }
        .sheet(item: $importer.pending, onDismiss: { importer.confirmationDismissed() }) { selection in
            AmorePluginImportConfirmation(selection: selection,
                onInstall: { importer.confirm() }, onCancel: { importer.cancel() })
        }
        .alert(importer.failed ? AppLocalized("Install failed") : AppLocalized("Installed"),
               isPresented: Binding(get: { importer.resultMessage != nil },
                                    set: { if !$0 { importer.resultMessage = nil } })) {
            Button(AppLocalized("OK")) { importer.resultMessage = nil }
        } message: { Text(importer.resultMessage ?? "") }
        .confirmationDialog(AppLocalized("Uninstall plugin?"),
            isPresented: Binding(get: { recordToDelete != nil }, set: { if !$0 { recordToDelete = nil } }),
            titleVisibility: .visible) {
                Button(AppLocalized("Uninstall"), role: .destructive) {
                    if let record = recordToDelete { importer.uninstall(record) }
                    recordToDelete = nil
                }
                Button(AppLocalized("Cancel"), role: .cancel) { recordToDelete = nil }
            }
        .refreshable { await store.reload(); await importer.refreshInstalled() }
        .task { await importer.refreshInstalled(); await store.load() }
    }
}

struct DeveloperConnectionView: View {
    var body: some View {
        // Connection owns one List, including the opt-in; no Form/List nesting.
        AmoreDeviceConnectionPage()
            .navigationTitle(AppLocalized("Connection"))
            .navigationBarTitleDisplayMode(.inline)
    }
}


struct HomeShortcutsSettingsView: View {
    var body: some View {
        AmoreHomeShortcutManager()
            .navigationTitle(AppLocalized("Home shortcuts"))
    }
}
