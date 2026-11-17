import PokiCore
import SwiftUI

// The app's three tabs (the owner's layout, Nov 7 2026):
// - Poki: every session, with Poki's state and controls on top; the button at the bottom left starts a
//   new chat with Poki's own agent.
// - Agents: the agents that drive this iPhone (their MCP addresses and the relay), Poki's own agent
//   (accounts, models, voice, memory) and the Activity Log.
// - Setup: everything Poki needs, read live, each item fixed on its own page; advanced preferences and
//   debugging tools behind the button at the top right.

/// Agents › a page.
enum AgentsRoute: Hashable { case accounts, voice, activityLog, approvals }

/// Agents › Safety › Approvals: how Poki asks before a sensitive step, and how much it decides itself.
struct ApprovalsView: View {
    var body: some View {
        Form { ApprovalsSections() }
            .navigationTitle(AppLocalization.text("Approvals"))
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The two sections of Approvals, for the page above and for Poki › Approvals (ESP-340), which shows
/// them with what the phone does when a task ends.
struct ApprovalsSections: View {
    @Environment(AppModel.self) private var model

    private var levels: [ApprovalClassifier.Level] { ApprovalClassifier.Level.allCases }

    var body: some View {
        @Bindable var model = model
        // The slider's four stops are the four levels, least asking on the left.
        let stop = Binding<Double>(
            get: { Double(levels.firstIndex(of: model.classifierLevel) ?? 1) },
            set: { model.classifierLevel = levels[min(levels.count - 1, max(0, Int($0.rounded())))] })
        Group {
            Section {
                Picker(selection: $model.approvalMode) {
                    ForEach(ApprovalClassifier.Mode.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Ask Me", systemImage: "hand.raised")
                }
                .accessibilityIdentifier("approvals.mode")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sensitive steps are paying, deleting, sending a message, placing a call, typing a password and anything in Wallet.")
                    switch model.approvalMode {
                    case .reply: Text("With Message Reply, Poki asks you in the chat and your yes lets the step through. Away from Poki you can answer from the notification. Outside agents have no chat, so their steps ask with Allow and Don’t Allow.")
                    case .confirm: Text("With Confirmation, you tap Allow or Don’t Allow on the Live Activity, in a notification, or here in Poki.")
                    case .off: Text("Optional steps continue without asking. Payments, deletions and actions in Wallet still need your confirmation.")
                    }
                    Text("Payments, deletions and actions in Wallet always need your confirmation.")
                    Text("Changes apply right away, starting from Poki’s next step.")
                }
            }
            if model.approvalMode != .off {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Sensitivity", systemImage: "dial.medium")
                            Spacer()
                            Text(model.classifierLevel.title).foregroundStyle(.secondary)
                        }
                        Slider(value: stop, in: 0...Double(levels.count - 1), step: 1) {
                            Text("Sensitivity")
                        } minimumValueLabel: {
                            Image(systemName: "bolt").foregroundStyle(.secondary).accessibilityLabel(Text("Asks least"))
                        } maximumValueLabel: {
                            Image(systemName: "lock.shield").foregroundStyle(.secondary).accessibilityLabel(Text("Asks most"))
                        }
                        .sensoryFeedback(.selection, trigger: model.classifierLevel)
                        .accessibilityValue(Text(model.classifierLevel.title))
                        .accessibilityIdentifier("approvals.sensitivity")
                    }
                    .padding(.vertical, 4)
                } footer: {
                    switch model.classifierLevel {
                    case .permissive: Text("Permissive. Your chat model approves a step in Poki’s own chat unless it clearly has nothing to do with what you asked, or you said no.")
                    case .balanced: Text("Balanced. Your chat model approves a step in Poki’s own chat when it directly serves what you asked for. You are asked about the rest.")
                    case .strict: Text("Strict. Your chat model approves a step in Poki’s own chat only when you asked for that exact action. You are asked about the rest.")
                    case .everything: Text("Ask All. Nothing is approved automatically. Each request needs your answer.")
                    }
                }
            }
        }
    }
}

struct AgentsView: View {
    /// The line under MCP Relay: the address to set, Poki being off, or the relay's live state.
    private var relayLine: String {
        if model.relayAddress == nil { return AppLocalization.text(LocalizedStringResource("Set an address first")) }
        if !model.relayEnabled { return AppLocalization.text(LocalizedStringResource("Off, agents can’t reach this iPhone")) }
        if !model.sessionOn { return AppLocalization.text(LocalizedStringResource("Waiting for Poki, turn Poki on and agents can connect")) }
        return Health.relay(model).word
    }

    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath
    var openSession: (String) -> Void

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: AgentsRoute.accounts) {
                        LabeledContent {
                            Text(ModelKeys.hasUsableKey ? ModelKeys.selectedModelName : AppLocalization.text(LocalizedStringResource("Add an Account"))).foregroundStyle(ModelKeys.hasUsableKey ? Color.secondary : Color.orange)
                        } label: { Label("Accounts and Models", systemImage: "person.crop.circle") }
                    }
                    NavigationLink(value: AgentsRoute.voice) {
                        LabeledContent {
                            Text(VoiceDirect.apiKey != nil ? VoiceDirect.model : AppLocalization.text(LocalizedStringResource("Dictation Only")))
                        } label: { Label("Voice", systemImage: "waveform") }
                    }
                    NavigationLink(value: SettingsRoute.memory) {
                        LabeledContent {
                            Text("\(RoutineStore.shared.routines.count) routines")
                        } label: { Label("Memory", systemImage: "brain") }
                    }
                } header: {
                    Text("Poki Agent")
                } footer: {
                    Text("The model Poki’s chat and voice use on this iPhone. Memory holds the routines and notes every agent shares.")
                }

                Section {
                    ForEach(model.identity.secrets) { secret in
                        let last = SessionStore.shared.sessions(for: secret, among: model.identity.secrets).first
                        NavigationLink(value: SettingsRoute.connector(secret)) {
                            LabeledContent {
                                Text(last.map { ChatTime.row($0.updated) } ?? AppLocalization.text(LocalizedStringResource("Not Used Yet")))
                            } label: {
                                Label {
                                    Text(verbatim: secret.name)
                                } icon: {
                                    // The agent that connected through it (or used it last).
                                    if let client = secret.agent ?? last?.client {
                                        AgentBadge(name: client, size: 28)
                                    } else {
                                        Image(systemName: "point.3.connected.trianglepath.dotted")
                                    }
                                }
                            }
                        }
                        .swipeActions { Button("Revoke", role: .destructive) { model.revoke(secret) } }
                    }
                    // A new connector is "Connector N" until an agent connects through it (or you
                    // name it on its page).
                    Button(action: add) {
                        Label {
                            Text("Add Agent")
                        } icon: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                        }
                    }
                    .disabled(model.relayAddress == nil)
                } header: {
                    Text("External Agents")
                } footer: {
                    Text(model.relayAddress == nil
                         ? "Set your relay first. Each agent gets its own MCP address on it."
                         : "Each agent gets its own MCP address. Add it as a remote MCP server in Claude, Codex or any MCP client. It takes the agent’s name and icon when the agent first connects, unless you renamed it. Swipe to revoke.")
                }

                Section {
                    // On or off; it can't be turned on before an address is set, and is on once one is.
                    Toggle(isOn: Binding(get: { model.relayEnabled && model.relayAddress != nil }, set: { model.setRelayEnabled($0) })) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("MCP Relay")
                                Text(relayLine)
                                    .font(.footnote).foregroundStyle(Color(.secondaryLabel))
                            }
                        } icon: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                    }
                    // Poki stopped: the switch keeps the owner's choice but is greyed, since nothing
                    // connects until Poki is on; the line under it says so.
                    .disabled(model.relayAddress == nil || !model.sessionOn)
                    NavigationLink(value: SettingsRoute.relay) {
                        LabeledContent {
                            Text(model.relayAddress.map { $0.origin.host() ?? $0.origin.absoluteString } ?? AppLocalization.text(LocalizedStringResource("Not Set")))
                                .foregroundStyle(model.relayAddress == nil ? Color.orange : Color.secondary)
                        } label: {
                            Label("Address", systemImage: "network")
                        }
                    }
                } header: {
                    Text("MCP Relay")
                } footer: {
                    Text("The relay forwards agents’ requests to this iPhone while Poki is open or in the background. It stores nothing.")
                }

                Section {
                    NavigationLink(value: AgentsRoute.approvals) {
                        LabeledContent {
                            Text(model.approvalMode == .off ? AppLocalization.text(LocalizedStringResource("Off")) : model.classifierLevel.title)
                                .foregroundStyle(model.approvalMode == .off ? Color.orange : Color.secondary)
                        } label: { Label("Approvals", systemImage: "hand.raised") }
                    }
                    NavigationLink(value: AgentsRoute.activityLog) { Label("Activity Log", systemImage: "list.bullet.rectangle") }
                } header: {
                    Text("Safety")
                } footer: {
                    Text("When Poki asks you before a sensitive step, and the record of every action any agent ran on this iPhone.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(AppLocalization.text("Agents"))
            .navigationDestination(for: AgentsRoute.self) { route in
                switch route {
                case .accounts: ModelSettingsView()
                case .voice: VoiceView(embedded: true)
                case .activityLog: ActionLogView(openSession: openSession)
                case .approvals: ApprovalsView()
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                SettingsDestination(route: route, push: { path.append($0) }, pop: { if !path.isEmpty { path.removeLast() } })
            }
        }
    }

    private func add() {
        guard model.relayAddress != nil else { return }
        let secret = model.addConnector(name: "")
        path.append(SettingsRoute.connector(secret))
    }
}

/// Setup: the live checklist, with Advanced behind the top-right button.
struct SetupTab: View {
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            SetupChecklist()
                .navigationTitle(AppLocalization.text("Setup"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: SetupRoute.advanced) { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel(Text("Advanced"))
                    }
                }
                .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0) }
                .navigationDestination(for: SetupRoute.self) { _ in AdvancedView(push: { path.append($0) }) }
                .navigationDestination(for: SettingsRoute.self) { route in
                    SettingsDestination(route: route, push: { path.append($0) }, pop: { if !path.isEmpty { path.removeLast() } })
                }
        }
    }
}

enum SetupRoute: Hashable { case advanced }

/// Setup › Advanced: preferences and debugging tools.
struct AdvancedView: View {
    @Environment(AppModel.self) private var model
    var push: (SettingsRoute) -> Void

    var body: some View {
        Form {

            Section {
                Button("Notification Settings", systemImage: "bell.badge") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
            } header: { Text("Notifications") }
            Section {
                NavigationLink(value: SettingsRoute.diagnostics) { Label("Diagnostics", systemImage: "stethoscope") }
                NavigationLink(value: SettingsRoute.log) { Label("Log", systemImage: "doc.text") }
                NavigationLink { TestingOptionsView() } label: { Label("Testing Options", systemImage: "flask") }
            } header: {
                Text("Debugging")
            } footer: {
                Text("Diagnostics has connection checks and this iPhone’s addresses. Testing Options has switches being tried.")
            }
        }
        .navigationTitle(AppLocalization.text("Advanced"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
