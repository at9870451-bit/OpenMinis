// The Live Activity's shared data. Phase layout and the terminal flag follow AgentActivityAttributes.swift
// from Clarklevis1995/dsh-mobile (commit ebe19764, DeepSeekHarnessMobile/LiveActivity/AgentActivityAttributes.swift),
// MIT License, Copyright (c) 2026 Chaofan Li. See THIRD_PARTY_NOTICES.md.
import ActivityKit
import Foundation

/// The Live Activity's data, shared by the app (which starts and updates it) and the widget extension
/// (which draws it). ActivityKit caps the payload at 4 KB, so the screenshot thumbnail is not in it:
/// the app writes it to the App Group container and the state carries only its version.
struct PokiActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// `done` is set by ActivityController itself when the agent has been quiet for a while after a
        /// run of steps; `deciding` by AppModel the moment Allow or Deny is tapped on the Live Activity,
        /// until PokiCore has the answer. `handoff`: the agent cannot act on this screen (a passcode, a
        /// verification, a payment) and the person has to; the agent keeps polling meanwhile. See `Handoff`.
        enum Phase: String, Codable, Hashable {
            case idle, working, approval, deciding, pairing, setup, problem, done, handoff

            /// The phases a person has to answer: a step from the agent never replaces them.
            var holdsApproval: Bool { self == .approval || self == .deciding }
        }
        /// Live voice session state when Poki's voice mode is active.
        enum Voice: String, Codable, Hashable {
            case listening, thinking, speaking
        }
        /// Refreshes an existing activity when the shared UI language changes; older states decode nil.
        var uiLanguage: String? = nil
        var phase: Phase
        /// What the agent is doing, in a few words ("Tap “Send”"), or the phase's line, in English: the
        /// face words it in the system's language (ActivityWords).
        var headline: String
        /// The status word in place of the phase's own ("Runner Stopped").
        var label: String?
        /// The app in front.
        var app: String?
        /// The outside agent driving the phone ("Claude Code"), nil for Poki's own chat.
        var caller: String?
        /// Bumped whenever a new thumbnail is written to the App Group container.
        var thumbnailVersion: Int
        /// A pending approval, if any. Its buttons are App Intents; see ApprovalIntents.swift.
        var approval: PendingApproval?
        /// While `deciding`: true for Allow, false for Deny.
        var decision: Bool?
        /// What the person has to do themselves, while phase is `handoff`.
        var handoff: Handoff?
        /// The pairing PIN while on-device pairing is waiting for it.
        var pin: String?
        /// The runner is stopped while no agent uses the phone (no automation banner); the next
        /// request starts it again.
        var runnerPaused = false
        /// During setup: which step the person is on ("2/6").
        var guide: Guide?
        /// Live voice conversation state, when active.
        var voice: Voice? = nil
        /// When the agent's current run of steps began.
        var since: Date?
        /// Actions taken in the current run, and how many of them did not go through. Kept by
        /// ActivityController. What the Live Activity shows as the step is `progress` (ActivityFace).
        var stepCount = 0
        var failedCount = 0
        /// The plan's steps (from 1) under which an action did not go through: their segments draw red.
        /// Optional so a state saved before this field still decodes. Kept by ActivityController.
        var failedSteps: [Int]? = nil
        /// The step before the one under way, in English like `headline`: the expanded island shows
        /// it ticked under the current one. Kept by ActivityController.
        var previous: String?
        /// When the run finished (phase `done`), so the summary shows a fixed duration.
        var endedAt: Date?
        /// A short-lived event ("Started", "Now in WeChat", "Allowed") shown as the status word for a few
        /// seconds. ActivityController clears it.
        var event: Event?

        /// The plan the chat's model published: the Live Activity then counts the plan's steps, as the
        /// chat's plan bubble does, not the single taps under them.
        var plan: Plan?
    }
    /// report_plan's plan, in the model's own words: the Live Activity says the step under way as the
    /// plan words it ("Open the chat with Mom"), not the tap under it.
    struct Plan: Codable, Hashable {
        var steps: [String]
        /// The step under way, from 1.
        var current: Int
        /// The task in a few words ("Text Mom"), from report_plan's `title`.
        var title: String? = nil
        /// Who the task's message goes to ("Mom"), from report_plan's `to`.
        var to: String? = nil

        var total: Int { steps.count }
    }
    struct Event: Codable, Hashable {
        enum Kind: String, Codable, Hashable { case started, app, finished, approved, denied, expired, problem, paired, code, handoff, resumed }
        var kind: Kind
        var text: String
    }
    /// The agent (or the runner's launch) handed a screen to the person. `kind` picks the words and
    /// the symbol; `text` is the agent's own one-line note of what is needed, if any. The person taps
    /// Done on the Live Activity when finished (HandoffDoneIntent), which the app passes on to PokiCore.
    struct Handoff: Codable, Hashable {
        enum Kind: String, Codable, Hashable { case runnerPasscode, automationPasscode, passcode, password, verification, payment, other }
        var id: String
        var kind: Kind
        var text: String?
        var app: String?
        var since: Date
    }
    struct Guide: Codable, Hashable {
        var number: Int
        var count: Int
        var title: String
    }
    var deviceName: String
}

struct PendingApproval: Codable, Hashable {
    var id: String
    var app: String
    var summary: String
    /// Why it needs the owner, from PokiCore's rules: `sending a message ("send")`, `a payment ("pay")`.
    var reason: String
    var expires: Date

    /// PokiCore's word on whether turning asking off (Never Ask) would stop every step this approval
    /// covers from asking; nil from a state saved before it existed. Not the reason's wording: a tap in a
    /// chat app on a screen not read yet reads as sending, and stops, while a payment, a deletion, Wallet
    /// and a tap after a launch do not.
    var stopsWhenOff: Bool? = nil

    /// The card offers Don’t Ask Again.
    var offersStopAsking: Bool { stopsWhenOff == true }

    /// The approval as one short question, the same on every card, the island, the Lock Screen and
    /// the notification. It comes from the kind the rules saw in PokiCore's reason, never from the
    /// agent's words ("Allow payment?").
    var question: String {
        // Several sensitive actions in one batch: the first one's kind, as PokiCore asks from it.
        var reason = self.reason
        if let first = reason.range(of: #"^multiple sensitive actions: action \d+: "#, options: .regularExpression) {
            reason = String(reason[first.upperBound...])
        }
        if reason.hasPrefix("a payment") { return String(activity: "Allow payment?") }
        if reason.hasPrefix("deleting") { return String(activity: "Allow deletion?") }
        if reason.hasPrefix("sending") { return String(activity: "Allow sending a message?") }
        if reason.hasPrefix("a call") { return String(activity: "Allow a call?") }
        if reason.hasPrefix("typing into a password") { return String(activity: "Allow typing a password?") }
        if reason.hasPrefix("input in") { return String(activity: "Allow a step in a protected app?") }
        return String(activity: "Allow this step?")
    }
}

enum SharedContainer {
    static let appGroup = "com.openAmroe.app.original-poki"
    static var url: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let directory = base?.appendingPathComponent("AmorePoki/Shared", isDirectory: true)
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory
    }
    static var thumbnailURL: URL? { url?.appendingPathComponent("activity-thumbnail.jpg") }
    static var defaults: UserDefaults { .standard }
}
