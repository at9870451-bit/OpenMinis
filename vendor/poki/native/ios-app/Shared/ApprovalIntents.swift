// Allow and Deny on the Live Activity. The bridge and the two LiveActivityIntents are ported from
// AgentApprovalIntents.swift in Clarklevis1995/dsh-mobile (commit ebe19764,
// DeepSeekHarnessMobile/LiveActivity/AgentApprovalIntents.swift), MIT License, Copyright (c) 2026
// Chaofan Li. Poki keys a decision by its approval id alone and keeps an App Group mailbox for an
// intent that runs outside the app. See THIRD_PARTY_NOTICES.md.
import AppIntents
import Foundation

struct ApprovalDecision: Hashable, Sendable {
    let approvalID: String
    let approved: Bool
    /// Allow this step and turn asking off (Don’t Ask Again).
    var stopAsking = false
}

/// A LiveActivityIntent runs in the app's process, so the button hands its decision straight to
/// AppModel through this bridge, which holds no state of its own. In the widget's process, or before
/// AppModel installed itself, the bridge has no handler and the decision goes to the mailbox.
@MainActor
enum ApprovalIntentBridge {
    typealias Handler = @MainActor @Sendable (ApprovalDecision) -> Bool

    private static var handler: Handler?

    static func install(_ handler: @escaping Handler) {
        self.handler = handler
    }

    static func submit(_ decision: ApprovalDecision) {
        if handler?(decision) != true { ApprovalMailbox.post(decision) }
    }
}

/// PokiCore sends no input at all while an approval is pending, so the automation cannot press this
/// button itself. Allow asks for Face ID or the passcode first. None of the approval intents opens
/// Poki (`openAppWhenRun` is false): the owner stays in the app the agent is working in, and the
/// next step lands there.
struct ApproveActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Allow action"
    static let description = IntentDescription("Lets the agent do the step that is waiting for you.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Approval") var approvalID: String

    init() {}
    init(approvalID: String) { self.approvalID = approvalID }

    @MainActor
    func perform() async throws -> some IntentResult {
        ApprovalIntentBridge.submit(ApprovalDecision(approvalID: approvalID, approved: true))
        return .result()
    }
}

/// Don’t Ask Again: lets this step through and turns approvals off, so it allows more than Allow does
/// and asks for Face ID or the passcode the same way.
struct StopAskingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Allow and stop asking"
    static let description = IntentDescription("Lets the agent do the step that is waiting for you and turns approvals off.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Approval") var approvalID: String

    init() {}
    init(approvalID: String) { self.approvalID = approvalID }

    @MainActor
    func perform() async throws -> some IntentResult {
        ApprovalIntentBridge.submit(ApprovalDecision(approvalID: approvalID, approved: true, stopAsking: true))
        return .result()
    }
}

/// Deny needs no authentication: refusing a step is always safe, like Stop.
struct DenyActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny action"
    static let description = IntentDescription("Refuses the step that is waiting for you.")
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Approval") var approvalID: String

    init() {}
    init(approvalID: String) { self.approvalID = approvalID }

    @MainActor
    func perform() async throws -> some IntentResult {
        ApprovalIntentBridge.submit(ApprovalDecision(approvalID: approvalID, approved: false))
        return .result()
    }
}

/// Stop runner on the Live Activity: stops the runner (and with it iOS's automation banner) until an
/// agent's next request. No authentication: stopping is always safe.
struct StopRunnerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop runner"
    static let openAppWhenRun = false
    static let isDiscoverable = false
    init() {}
    func perform() async throws -> some IntentResult {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(ApprovalMailbox.stopRunner as CFString), nil, nil, true)
        return .result()
    }
}

/// Done on the Live Activity's "your turn" card: the person finished what the agent could not do
/// (a passcode, a verification, a payment). The app passes it on to PokiCore, which tells the agent.
/// No authentication: it only says "continue".
struct HandoffDoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Continue"
    static let isDiscoverable = false

    @Parameter(title: "Handoff") var handoffID: String

    init() {}
    init(handoffID: String) { self.handoffID = handoffID }

    func perform() async throws -> some IntentResult {
        SharedContainer.defaults.set(handoffID, forKey: ApprovalMailbox.handoffKey)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(ApprovalMailbox.handoffDone as CFString), nil, nil, true)
        return .result()
    }
}

/// Swallows a tap on the Live Activity's plain areas. iOS opens the activity's app on any tap that no
/// control takes; this intent, laid under every surface (see TapShield), takes it instead and does
/// nothing, so the agent's run is never interrupted by Poki coming to the front. Poki's own buttons
/// sit above it and still work.
struct NoTapIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Nothing"
    static let isDiscoverable = false
    init() {}
    func perform() async throws -> some IntentResult { .result() }
}

/// Decisions in flight between an intent that ran outside the app and the app: written to the App
/// Group and announced with a Darwin notification.
enum ApprovalMailbox {
    static let notification = SharedContainer.appGroup + ".approval"
    static let stopRunner = SharedContainer.appGroup + ".stop-runner"
    static let handoffDone = SharedContainer.appGroup + ".handoff-done"
    static let handoffKey = "handoff.done"

    /// The id of the handoff the person marked done, once.
    static func drainHandoffDone() -> String? {
        let id = SharedContainer.defaults.string(forKey: handoffKey)
        SharedContainer.defaults.removeObject(forKey: handoffKey)
        return id
    }
    private static let key = "approval.decisions"
    /// The ids among them answered with Don’t Ask Again.
    private static let stopKey = "approval.decisions.stop"

    static func post(_ decision: ApprovalDecision) {
        var decisions = SharedContainer.defaults.dictionary(forKey: key) as? [String: Bool] ?? [:]
        decisions[decision.approvalID] = decision.approved
        SharedContainer.defaults.set(decisions, forKey: key)
        if decision.stopAsking {
            let stopping = SharedContainer.defaults.stringArray(forKey: stopKey) ?? []
            SharedContainer.defaults.set(stopping + [decision.approvalID], forKey: stopKey)
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(notification as CFString), nil, nil, true)
    }

    /// Takes every decision posted so far, once.
    static func drain() -> [ApprovalDecision] {
        let decisions = SharedContainer.defaults.dictionary(forKey: key) as? [String: Bool] ?? [:]
        let stopping = Set(SharedContainer.defaults.stringArray(forKey: stopKey) ?? [])
        SharedContainer.defaults.removeObject(forKey: key)
        SharedContainer.defaults.removeObject(forKey: stopKey)
        return decisions.map { ApprovalDecision(approvalID: $0.key, approved: $0.value, stopAsking: stopping.contains($0.key)) }
    }
}
