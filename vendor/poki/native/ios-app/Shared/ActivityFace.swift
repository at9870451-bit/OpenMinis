import Foundation

typealias PokiState = PokiActivityAttributes.ContentState

/// Which bear the Live Activity draws (ESP-344): no round avatar any more, the bear itself stands on
/// the island's black or the card's blue and says the state by its pose. The pictures are square;
/// where the head and hand sit in each is the design's own measurement (`MEC` in its source).
enum ActivityBear: String, Hashable {
    case phone, needs, turn, done, tripped, ready, paused, thinking, checking

    var image: String { "ActivityBear-\(rawValue)" }

    /// The middle of the smallest circle round the head and a raised hand, as shares of the side.
    var middle: (x: CGFloat, y: CGFloat) {
        switch self {
        case .phone: (0.4805, 0.3922)
        case .needs: (0.4828, 0.4945)
        case .turn: (0.4656, 0.5225)
        case .done: (0.4672, 0.4727)
        case .tripped: (0.4467, 0.4841)
        case .ready: (0.4919, 0.4572)
        case .paused: (0.4906, 0.5556)
        case .thinking: (0.489, 0.4526)
        case .checking: (0.4669, 0.5192)
        }
    }

    /// Where the picture's top-left corner stands in the compact island's left block, the picture
    /// 27.2 points a side (`ActivityMetrics.compactBear`), so the whole bear, ears and outline, stays
    /// inside the 4.33 points the system cuts off the island's edge. Measured per pose in ESP-503's
    /// design (the island 36.67 tall, 393-point class): each pose's head sits elsewhere in its square.
    /// The design has no thinking bear; it stands where the ready one does.
    var compactOrigin: CGPoint {
        switch self {
        case .phone: CGPoint(x: 17.43, y: 3.84)
        case .needs: CGPoint(x: 17.73, y: 2.44)
        case .turn: CGPoint(x: 17.73, y: 2.23)
        case .done: CGPoint(x: 17.73, y: 2.94)
        case .tripped: CGPoint(x: 18.43, y: 2.54)
        case .ready, .thinking: CGPoint(x: 17.03, y: 3.34)
        case .paused: CGPoint(x: 16.83, y: 2.74)
        case .checking: CGPoint(x: 17.13, y: 3.64)
        }
    }

    /// The same in a circle 28 points across, the picture 22.6 a side (`ActivityMetrics.circleBear`):
    /// the circle where the island is short of room, and the minimal circle's visible part.
    var circleOrigin: CGPoint {
        switch self {
        case .phone: CGPoint(x: 3.29, y: 1.96)
        case .needs: CGPoint(x: 3.54, y: 0.79)
        case .turn: CGPoint(x: 3.54, y: 0.63)
        case .done: CGPoint(x: 3.54, y: 1.21)
        case .tripped: CGPoint(x: 4.12, y: 0.88)
        case .ready, .thinking: CGPoint(x: 2.95, y: 1.54)
        case .paused: CGPoint(x: 2.79, y: 1.04)
        case .checking: CGPoint(x: 3.04, y: 1.79)
        }
    }
}

/// What the Live Activity shows for a state, worked out once per phase. The Lock Screen, the expanded
/// island, the compact island and the minimal circle all draw this, so a phase's words and colours
/// live in one table (`PokiState.face`) instead of a switch in every view. Layout, words and colours
/// follow ESP-344's final design (定稿规格): black, white and grey, and Poki's blue as the one accent.
struct ActivityFace: Hashable {
    enum Meta: Hashable {
        case none
        /// A short count or location ("2 of 6", "Settings").
        case text(String)
        /// The time left on an approval, counted down by the system.
        case countdown(Date)
        /// A time of day ("9:41 AM").
        case clock(Date)
        /// How long the run has taken, or how long the agent has waited, counted up by the system.
        case elapsed(Date)
        /// A small symbol: the tick of a finished run, the mark of a problem.
        case symbol(String, ActivityTone)
    }
    enum Compact: Hashable {
        /// The icon of the app the run is in, which the app wrote to the App Group container
        /// (`AppIconFile`); the run's time where there is no icon.
        case app(String, since: Date?)
        /// How long the run has taken, counted up by the system.
        case elapsed(Date)
        /// Words and the setup checklist's fixed count ("2/6", "Stalled").
        case text(String, ActivityTone)
        /// The pairing code, tabular digits.
        case code(String)
        /// Poki waits for your answer: a word saying so ("Allow?") over the time left (ESP-467). The
        /// island opens by itself when the approval comes and folds back after a few seconds; folded,
        /// it still says what it waits for.
        case asking(String, Date)
        case countdown(Date)
        case symbol(String, ActivityTone)
    }
    enum Bottom: Hashable {
        case none
        /// The run under way, never how far it has come: an agent's count of steps changes as it goes.
        /// `line`: once the run is in an app or has a plan, one line that says work goes on, without
        /// segments. Stop beside it.
        case progress(line: Bool, stop: Bool)
        case approval(id: String)
        /// The answer is on its way to PokiCore.
        case deciding(String)
        /// "Continue" for a screen the agent handed to the person.
        case handoff(id: String)
        /// Open Poki to fix a stopped runner or pairing error.
        case openPoki
        /// The setup steps: done, the current one, the rest.
        case segments(number: Int, count: Int)
    }
    enum Thumbnail: Hashable { case none, large, small }
    /// What the compact island's right side shows while Poki works: the icon of the app the run is in
    /// (`.icon`, which falls back to the time where the app is not known), or always the run's time
    /// (`.time`). The design has both; until one is chosen, this line picks it.
    enum WorkingTrailing { case icon, time }
    static let workingTrailing = WorkingTrailing.icon
    /// How tall the expanded island and the Lock Screen card are, and how large the bear in them.
    enum Size: Hashable { case low, working, asking, tall }

    /// SF Symbol used for the in-app debug preview list icon.
    var symbol: String = "sparkles"
    var bear: ActivityBear
    var size: Size
    /// The small line over the title, in the accent colour: the app a run is in, the setup checklist's step.
    var kicker: String? = nil
    /// Beside it for a few seconds, quieter: a fresh event ("Started", "Allowed", "Carrying on").
    var event: String? = nil
    var eventTone: ActivityTone = .accent
    /// The top-right value.
    var meta: Meta
    /// The Lock Screen card's value where it differs (a finished run shows when it ended).
    var lockMeta: Meta? = nil
    /// The main title line.
    var content: String
    /// The title is a pairing code in large digits.
    var contentIsCode = false
    /// The secondary line under the title.
    var subtitle: String? = nil
    var subtitleLines = 1
    var bottom: Bottom
    /// The card has a Don’t Ask Again row under Allow and Don’t Allow.
    var offersStopAsking = false
    /// The latest screenshot on the right of the Lock Screen card.
    var thumbnail: Thumbnail = .none
    var compact: Compact
    /// The screen a tap opens.
    var link: URL = ActivityLink.chat
    /// While the agent may be acting (a run, an approval, a hand-off), a tap on the expanded island
    /// that misses its controls does nothing instead of opening Poki (`TapShield`): the expanded
    /// island lies over the top of the app being worked in, so the agent's taps there, and the owner's
    /// near misses of Allow and Don't Allow, brought Poki to the front in the middle of the task.
    var shieldsTaps = false
    /// The app has not updated the activity for longer than it should have: what it shows may be old.
    var stale = false
    /// Who is calling: the outside agent whose badge sits beside the meta value.
    var caller: String?
    /// A talk with Poki is on: the card and the island carry End, which ends the talk (EndTalkIntent).
    var endsTalk = false
    /// A talk with Poki is on: the expanded island draws the brand band along its lower edge.
    var talkGlow = false
}

/// Where a tap on the Live Activity goes, handled by RootView's onOpenURL.
enum ActivityLink {
    /// The chat that runs the agent (also approvals and handoffs, which the chat shows).
    static let chat = URL(string: "poki://chat")!
    /// The Activity Log, where a problem's details are.
    static let log = URL(string: "poki://log")!
    static func setup(_ step: String? = nil) -> URL {
        URL(string: step.map { "poki://setup?step=\($0)" } ?? "poki://setup")!
    }
}

extension PokiActivityAttributes.Event {
    var tone: ActivityTone {
        switch kind {
        case .started, .app, .code, .resumed: .accent
        case .handoff: .approval
        case .finished, .approved, .paired: .done
        case .denied, .expired: .quiet
        case .problem: .problem
        }
    }
}

extension PokiState {
    var hasThumbnail: Bool { thumbnailVersion > 0 }

    /// Nothing to say: no work, nobody needed, no talk with Poki. Where something else already says
    /// Poki is on, the Live Activity steps aside then.
    var isQuiet: Bool { phase == .idle && voice == nil }

    /// Where and how long a finished run took: "Done in Messages, took 1:24". Never a count of steps,
    /// which an agent changes as it goes.
    var runSummary: String? {
        let place = AppName.display(app)
        let time = since.flatMap { since in endedAt.map { Duration.seconds(max(0, $0.timeIntervalSince(since))).formatted(.time(pattern: .minuteSecond)) } }
        switch (place, time) {
        case let (place?, time?): return String(activity: "Finished in \(place), took \(time)")
        case let (nil, time?): return String(activity: "Took \(time)")
        case let (place?, nil): return String(activity: "Finished in \(place)")
        default: return nil
        }
    }

    /// What a finished run did: the plan's title, else Poki's own line.
    var doneTitle: String { plan?.title?.nonBlank ?? StatusWord.done.text }

    /// The plan's step under way, from 1.
    private var planNumber: Int? {
        guard let plan, plan.total > 0 else { return nil }
        return min(max(plan.current, 1), plan.total)
    }

    /// What the run is doing, worded so a glance at the island says which part of the task this is
    /// (ESP-467): the plan's step under way in the model's words, else the task's name, else a line of
    /// Poki's own ("Thinking"). Never the action under it ("Tap “Send”"): on its own that says nothing
    /// about the task. nil when none of these is known.
    var doing: String? {
        if headline == "Waiting for Split View" { return String(activity: "Waiting for Split View") }
        if let words = taskWords { return words }
        if let to = plan?.to?.nonBlank { return String(activity: "Poki’s messaging \(to)") }
        return ActivityWords.statusLines.contains(headline) ? ActivityWords.local(headline) : nil
    }

    /// The task's own words: the plan's step under way, else the task's name.
    private var taskWords: String? {
        guard let plan else { return nil }
        return planNumber.flatMap(planStep) ?? plan.title?.nonBlank
    }

    /// The plan's step `number`, from 1, in the model's words.
    private func planStep(_ number: Int) -> String? {
        guard let plan, plan.steps.indices.contains(number - 1) else { return nil }
        return plan.steps[number - 1].nonBlank
    }

    /// The compact island's right side while Poki works (`ActivityFace.workingTrailing`): the app's
    /// icon, or the run's time where the app is not known.
    private func workingCompact(app: String?) -> ActivityFace.Compact {
        if ActivityFace.workingTrailing == .icon, let app { return .app(app, since: since) }
        if let since { return .elapsed(since) }
        return .symbol("hand.tap.fill", .accent)
    }

    var face: ActivityFace { face(stale: false) }

    /// The face for the widget: `stale` when ActivityKit says the content is past its stale date.
    func face(stale: Bool) -> ActivityFace {
        var face = baseFace
        face.caller = caller
        // During a talk the card and the island carry End, while Poki listens, speaks or works on a step
        // of the talk. Anything that needs the person (an approval, a hand-off) or tells of a problem
        // keeps them to itself.
        face.endsTalk = voice != nil && (phase == .idle || phase == .working) && !stale
        face.talkGlow = voice != nil && !stale
        face.shieldsTaps = !stale && [.working, .approval, .deciding, .handoff].contains(phase)
        // A fresh event ("Started", "Allowed") shows beside the app's name for a few seconds. An app
        // switch is the app's name itself, already there.
        if let event, !phase.holdsApproval, event.kind != .app {
            face.event = ActivityWords.local(event.text)
            face.eventTone = event.tone
        }
        if stale, phase == .working || phase == .handoff {
            // The app stopped updating (closed, or iOS suspended it): say so, and drop the action,
            // which needs the app.
            face.symbol = "clock.badge.exclamationmark"
            face.bear = .paused
            face.kicker = nil
            face.event = String(activity: "Not updating")
            face.eventTone = .quiet
            face.meta = .none
            face.bottom = .none
            face.compact = .text(String(activity: "Stalled"), .quiet)
            face.stale = true
        }
        return face
    }

    private var baseFace: ActivityFace {
        switch phase {
        case .working:
            let inApp = app.flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 }
            let name = AppName.display(inApp) ?? (voice != nil ? String(activity: "Voice") : nil)
            return ActivityFace(
                symbol: voice != nil ? "waveform" : "hand.tap.fill",
                bear: .phone, size: .working,
                kicker: name,
                meta: since.map { ActivityFace.Meta.elapsed($0) } ?? ActivityFace.Meta.none,
                content: doing ?? StatusWord.running.text,
                bottom: .progress(line: name != nil || plan != nil, stop: true),
                thumbnail: hasThumbnail ? .large : .none,
                compact: workingCompact(app: inApp))
        case .approval, .deciding:
            guard let approval else { return quietFace }
            let question = approval.question
            if phase == .deciding {
                let allowed = decision == true
                return ActivityFace(
                    symbol: allowed ? "checkmark.circle.fill" : "xmark.circle.fill",
                    bear: allowed ? .phone : .needs, size: .asking,
                    meta: .none,
                    content: question,
                    bottom: .deciding(allowed ? String(activity: "Continuing") : String(activity: "Telling the agent")),
                    offersStopAsking: approval.offersStopAsking,
                    thumbnail: hasThumbnail ? .small : .none,
                    compact: .symbol(allowed ? "checkmark" : "xmark", allowed ? .accent : .quiet))
            }
            return ActivityFace(
                symbol: "hand.raised.fill",
                bear: .needs, size: .asking,
                meta: .countdown(approval.expires),
                content: question,
                bottom: .approval(id: approval.id),
                offersStopAsking: approval.offersStopAsking,
                thumbnail: hasThumbnail ? .small : .none,
                compact: .asking(String(activity: "Allow?"), approval.expires))
        case .done:
            return ActivityFace(
                symbol: "checkmark.circle.fill",
                bear: .done, size: .low,
                meta: .symbol("checkmark", .accent), lockMeta: ActivityFace.Meta.none,
                content: doneTitle,
                subtitle: runSummary,
                bottom: .none,
                thumbnail: hasThumbnail ? .large : .none,
                compact: .symbol("checkmark", .accent))
        case .problem:
            let (problemTitle, problemSubtitle) = Self.problemPresentation(for: headline)
            return ActivityFace(
                symbol: "exclamationmark.triangle.fill",
                bear: .tripped, size: .tall,
                meta: .symbol("exclamationmark.circle.fill", .problem), lockMeta: ActivityFace.Meta.none,
                content: problemTitle,
                subtitle: problemSubtitle, subtitleLines: 2,
                bottom: .openPoki,
                compact: .symbol("exclamationmark.circle.fill", .problem),
                link: label == "Pairing Failed" ? ActivityLink.setup("pairing") : ActivityLink.log)
        case .pairing:
            if let pin {
                return ActivityFace(
                    symbol: "link",
                    bear: .checking, size: .asking,
                    meta: .text(String(activity: "Settings")),
                    content: pin.count == 6 ? "\(pin.prefix(3)) \(pin.suffix(3))" : pin, contentIsCode: true,
                    subtitle: String(activity: "Tap Pair with Poki, then enter this code."), subtitleLines: 2,
                    bottom: .none,
                    compact: .code(pin),
                    link: ActivityLink.setup("pairing"))
            }
            return ActivityFace(
                symbol: "link",
                bear: .checking, size: .working,
                meta: .text(String(activity: "Settings")),
                content: String(activity: "Pair in Settings"),
                subtitle: String(activity: "Open Pair with Poki there. The code shows up here."), subtitleLines: 2,
                bottom: .none,
                compact: .symbol("link", .accent),
                link: ActivityLink.setup("pairing"))
        case .setup:
            guard let guide else { return quietFace }
            let (setupTitle, setupSubtitle) = Self.setupPresentation(for: guide.title)
            return ActivityFace(
                symbol: "checklist",
                bear: .checking, size: .asking,
                kicker: String(activity: "Step \(guide.number) of \(guide.count)"),
                meta: .none,
                content: setupTitle,
                subtitle: setupSubtitle, subtitleLines: 2,
                bottom: .segments(number: guide.number, count: guide.count),
                compact: .text("\(guide.number)/\(guide.count)", .plain),
                link: ActivityLink.setup())
        case .handoff:
            guard let handoff else { return quietFace }
            return ActivityFace(
                symbol: handoff.symbol,
                bear: .turn, size: .tall,
                meta: .elapsed(handoff.since),
                content: handoff.line,
                subtitle: handoff.detail, subtitleLines: 2,
                bottom: .handoff(id: handoff.id),
                compact: .symbol("hand.tap.fill", .accent))
        case .idle:
            if let voice {
                let (line, hint, bear): (String, String, ActivityBear) = switch voice {
                case .listening: (StatusWord.listening.text, String(activity: "Talk with Poki"), .ready)
                case .thinking: (StatusWord.thinking.text, String(activity: "Working out the next step."), .thinking)
                case .speaking: (StatusWord.speaking.text, String(activity: "Talk with Poki"), .ready)
                }
                return ActivityFace(
                    symbol: "waveform",
                    bear: bear, size: .working,
                    meta: .none,
                    content: line,
                    subtitle: hint,
                    bottom: .none,
                    compact: .symbol("waveform", .accent))
            }
            return quietFace
        }
    }

    /// The runner's start-up stages (`RunnerStatus.title`). Each says the same main line, Starting,
    /// and names its stage in the small line under it (ESP-467).
    static let wakingStages: Set<String> = ["Connecting", "Checking pairing", "Opening tunnel", "Preparing", "Starting"]

    /// Ready (the runner is up), Idle (it sleeps until an agent asks), and the runner on its way up.
    private var quietFace: ActivityFace {
        let (title, subtitle): (String, String) =
            if Self.wakingStages.contains(headline) {
                (StatusWord.starting.text, ActivityWords.local(headline))
            } else if headline == "Needs loopback" {
                (StatusWord.disconnected.text, ActivityWords.local(headline))
            } else {
                (ActivityWords.local(headline), runnerPaused
                    ? String(activity: "The runner wakes when an agent asks.")
                    : String(activity: "Runner on. Waiting for the agent."))
            }
        // Standing by looks ready: it takes the next request by itself.
        return ActivityFace(
            symbol: "checkmark",
            bear: .ready, size: .low,
            meta: .none,
            content: title,
            subtitle: subtitle,
            bottom: .none,
            compact: .symbol("checkmark", .accent))
    }

    /// Maps `ContentState.headline` for `.problem` to an actionable title and explanatory subtitle
    /// matching ESP-139 final board 02.
    private static func problemPresentation(for headline: String) -> (String, String) {
        switch headline {
        case "Loopback Off", "Turn On Loopback", "Can’t Reach iPhone":
            return (String(activity: "Turn On Loopback"), String(activity: "In your proxy app, or connect LocalDevVPN."))
        case "No Internet", "Connect to the Internet":
            return (String(activity: "Connect to the Internet"), String(activity: "Poki needs it once after each restart, then tries again."))
        case "Disk Image Outdated", "Update the Disk Image":
            return (String(activity: "Update the Disk Image"), String(activity: "Open Poki's setup to download the latest one."))
        case "Fetching Disk Image", "Downloading the Disk Image":
            return (String(activity: "Downloading the Disk Image"), String(activity: "Poki downloads it again by itself."))
        case "Pairing Refused", "Pair Again":
            return (String(activity: "Pair Again"), String(activity: "In Poki's setup."))
        case "Loopback or Pairing":
            return (String(activity: "Turn On Loopback"), String(activity: "In your proxy app, or pair again in Poki's setup."))
        case "Developer Mode Off", "Check Developer Mode", "Turn On Developer Mode":
            return (String(activity: "Turn On Developer Mode"), String(activity: "Privacy & Security › Developer Mode, then restart."))
        case "Poki Runner Missing", "Poki Runner Didn’t Start", "Install Poki Runner":
            return (String(activity: "Install Poki Runner"), String(activity: "With the same signing tool and Apple ID as Poki."))
        case "Update iOS":
            return (String(activity: "Update iOS"), String(activity: "This feature requires a newer version of iOS."))
        default:
            return (ActivityWords.local(headline), String(activity: "Open Poki to fix it."))
        }
    }

    /// Maps `Guide.title` for `.setup` to an actionable title and two-line Settings path subtitle
    /// matching ESP-139 final board 02.
    private static func setupPresentation(for title: String) -> (String, String?) {
        switch title {
        case "Poki Runner", "Install Poki Runner":
            return (String(activity: "Install Poki Runner"), String(activity: "General › VPN & Device Management. Trust Poki Runner's developer."))
        case "Developer Mode", "Turn On Developer Mode":
            return (String(activity: "Turn On Developer Mode"), String(activity: "Privacy & Security › Developer Mode. Restart, then tap Turn On."))
        case "Loopback", "Turn On Loopback":
            return (String(activity: "Turn On Loopback"), String(activity: "In your proxy app, or connect LocalDevVPN. Then come back to Poki."))
        case "Pairing", "Pair This iPhone":
            return (String(activity: "Pair This iPhone"), String(activity: "Privacy & Security › Developer Mode › Pair with Poki."))
        case "UI Automation", "Allow UI Automation":
            return (String(activity: "Allow UI Automation"), String(activity: "Developer › Enable UI Automation."))
        case "Background", "Let Poki Stay On":
            return (String(activity: "Let Poki Stay On"), String(activity: "Allow location While Using the App, and keep Live Activities on."))
        default:
            return (ActivityWords.local(title), nil)
        }
    }
}

extension PokiActivityAttributes.Handoff {
    /// What the person has to do, in the agent's place.
    var title: String {
        switch kind {
        case .runnerPasscode: String(activity: "Enter your passcode to start the runner")
        case .automationPasscode: String(activity: "Enter your passcode to allow automation")
        case .passcode: String(activity: "Enter your passcode")
        case .password: String(activity: "Fill in your password")
        case .verification: String(activity: "Pass the verification yourself")
        case .payment: String(activity: "Finish the payment yourself")
        case .other: String(activity: "Do this step yourself")
        }
    }
    /// The content line: a fixed short line per kind.
    var line: String {
        switch kind {
        case .runnerPasscode: String(activity: "Passcode for the runner")
        case .automationPasscode: String(activity: "Passcode for automation")
        default: title
        }
    }
    /// The agent's own note, or what happens next (the subtitle and the alert's second line).
    var detail: String {
        if let text, !text.isEmpty { return text }
        switch kind {
        case .runnerPasscode: return String(activity: "iOS asks for it once after a restart. The agent waits.")
        case .automationPasscode: return String(activity: "iOS asks after Poki restarts or 8 hours later. The agent waits.")
        case .payment: return String(activity: "The agent does not pay for you. It waits, then carries on.")
        default: return String(activity: "The agent can't act on this screen. It waits for you.")
        }
    }
    var symbol: String {
        switch kind {
        case .runnerPasscode, .automationPasscode, .passcode: "lock.fill"
        case .password: "key.fill"
        case .verification: "checkmark.shield.fill"
        case .payment: "creditcard.fill"
        case .other: "person.fill"
        }
    }
}

private extension String {
    var nonBlank: String? {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
