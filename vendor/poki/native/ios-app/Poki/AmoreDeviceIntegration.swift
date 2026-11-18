import SwiftUI
import UIKit
import PokiCore

/// Device connectivity only. Amore owns the sole conversation store, providers,
/// speech state and agent loop. No upstream ChatModel or RootView is created.
@MainActor
public enum AmoreDeviceServices {
    private static var retained: AppModel?
    private static var hostModelAvailable: () -> Bool = { false }
    private static var stopHostAgent: (String?) -> Void = { _ in }
    private static var activeSession: () -> String? = { nil }
    private static var approvalObservers: [(String?) -> Void] = []
    private static var taskOwner: String?
    static var model: AppModel {
        if let retained { return retained }
        AppLocalization.publish()
        let value = AppModel()
        value.hostLocalAgentAvailable = { hostModelAvailable() }
        retained = value
        value.addShellObserver { event in
            switch event {
            case .approvalRequested, .approvalEnded:
                Task { @MainActor in
                    await Task.yield()
                    for observer in approvalObservers { observer(value.approvals.first?.id) }
                }
            default: break
            }
        }
        return value
    }
    public static func configure(modelAvailable: @escaping () -> Bool,
                                 activeSessionID: @escaping () -> String?,
                                 stopAgent: @escaping (String?) -> Void) {
        hostModelAvailable = modelAvailable
        activeSession = activeSessionID
        stopHostAgent = stopAgent
    }
    public static func observeApprovals(_ observer: @escaping (String?) -> Void) {
        approvalObservers.append(observer)
    }
    public static var pendingApprovalID: String? { retained?.approvals.first?.id }
    public static func resolveApproval(id: String, approved: Bool) {
        guard let approval = retained?.approvals.first(where: { $0.id == id }), approval.expires > Date() else { return }
        retained?.resolve(approval, approved: approved)
    }
    public static func approvalText(id: String) -> String? { retained?.approvals.first(where: { $0.id == id })?.summary }
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "amore.deviceControl.enabled")
    }
    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "amore.deviceControl.enabled")
        if !enabled { pauseAutomation() }
    }
    public static func finishTask(sessionID: String?) {
        guard let taskOwner, taskOwner == sessionID else { return }
        retained?.finishTask()
        self.taskOwner = nil
    }
    public static func cancelTask(sessionID: String?) {
        guard let taskOwner, taskOwner == sessionID else { return }
        retained?.pauseByOwner()
        self.taskOwner = nil
    }
    public static func pauseAutomation() {
        let owner = taskOwner
        taskOwner = nil
        stopHostAgent(owner)
        retained?.pauseByOwner()
    }
    public static var toolCatalogJSON: String { PokiCore.toolCatalogJSON }
    public static var toolInstructions: String { PokiCore.toolInstructions }
    public struct Answer: Sendable {
        public let text: String
        public let jpeg: Data?
        public let isError: Bool
        public let waitingForOwner: Bool
    }
    public static func execute(_ name: String, arguments: String, sessionID: String?) async -> Answer {
        guard isEnabled else {
            return Answer(text: "Device control is disabled. Enable it in Amore Settings > Connection.", jpeg: nil, isError: true, waitingForOwner: false)
        }
        guard ["look", "do", "status"].contains(name) else {
            return Answer(text: "Unsupported device tool.", jpeg: nil, isError: true, waitingForOwner: false)
        }
        let session = sessionID ?? activeSession()
        if name != "status", let taskOwner, taskOwner != session {
            return Answer(text: "The device is busy with another Amore conversation. Wait for that task or stop it first.", jpeg: nil, isError: true, waitingForOwner: false)
        }
        if name != "status", taskOwner != session {
            taskOwner = session
            model.chatTaskBegan()
        }
        let result = await model.runTool(name, arguments: arguments, localSession: session)
        return Answer(text: result.text, jpeg: result.jpeg, isError: result.isError, waitingForOwner: result.waitingForOwner)
    }
    public static func handleSetupLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "poki" || url.scheme?.lowercased() == "amore" else { return false }
        guard ["setup", "pair", "pairing", "connection", "approvals"].contains(url.host?.lowercased() ?? "") else { return false }
        _ = model.open(link: url)
        return true
    }
    public static func becameActive() {
        guard let retained else { return }
        retained.becameActive()
    }
    public static func wentToBackground() { retained?.wentToBackground() }
    public static func importPairing(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, url.pathExtension.lowercased() == "mobiledevicepairing" else {
            throw NSError(domain: "AmoreDevice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a mobiledevicepairing file."])
        }
        let data = try Data(contentsOf: url)
        guard data.count > 32, data.count < 2 * 1024 * 1024 else {
            throw NSError(domain: "AmoreDevice", code: 2, userInfo: [NSLocalizedDescriptionKey: "The pairing file is empty or too large."])
        }
        try model.importPairingFile(data, how: "imported in Amore")
        // Import is not trust verification and never turns automation on.
    }
}

/// The original Connection/Setup implementation is a normal page in the
/// Amore NavigationStack, not a second UIHostingController or navigation root.
@MainActor
public struct AmoreDeviceConnectionPage: View {
    @AppStorage("amore.deviceControl.enabled") private var enabled = false

    public init() {}
    public var body: some View {
        // The opt-in is a section of Connection's single native List. It gates
        // device tools, not access to setup, and never marks any setup step done.
        ConnectionView(stopHost: AmoreDeviceServices.pauseAutomation,
                       agentControl: Binding(get: { enabled }, set: {
                           enabled = $0
                           AmoreDeviceServices.setEnabled($0)
                       }))
            .environment(AmoreDeviceServices.model)
    }
}

public extension View {
    /// Attach to the eager root content *inside* the host NavigationStack, not
    /// to a pushed ConnectionView/List. Keeps the route's exact module identity
    /// private while registering the original SetupStep type at the real owner.
    @MainActor
    func amoreDeviceSetupDestinations() -> some View {
        navigationDestination(for: SetupStep.self) { step in
            SetupStepPage(step: step)
                .environment(AmoreDeviceServices.model)
                .settingsPage()
        }
    }
}

// Asset lookup stays in the single Amore app bundle after static linking.
enum PokiPortResources { static let bundle = Bundle.main }
