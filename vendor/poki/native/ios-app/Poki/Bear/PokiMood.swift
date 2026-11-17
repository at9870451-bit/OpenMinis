import SwiftUI
import UIKit

// The bear's faces are the ESP-326 prototype's own images (原型/assets/poki/states-1024, drawn for Poki),
// scaled to 768 px (PokiBear-<face>.png, the hero and the greeting) and 192 px (PokiBearSmall-<face>.png,
// avatars). The names are ESP-338's `BearFace` cases, so the Live Activity's small faces and these can
// become one set once that branch lands.

/// The bear's face: one per state Poki can be in.
enum PokiMood: String, CaseIterable {
    case ready, thinking
    case onYourPhone = "on-your-phone"
    case checking
    case needsYou = "needs-you"
    case yourTurn = "your-turn"
    case done, tripped, paused
    case cantReach = "cant-reach"
    case listening, speaking, hello

    /// The status word for this face, from the one table of them (`StatusWord`, Shared, which the
    /// widget extension reads too). Standard product language with no subject: "Ready", "Paused".
    var word: String { status.text }

    var status: StatusWord {
        switch self {
        case .ready: .ready
        case .thinking: .thinking
        case .onYourPhone: .running
        case .checking: .checking
        // A step waits for the owner's Allow (an approval).
        case .needsYou: .needsApproval
        case .yourTurn: .needsYourAction
        case .done: .done
        case .tripped: .error
        // The owner's pause: it starts again when you or an agent asks.
        case .paused: .paused
        case .cantReach: .disconnected
        case .listening: .listening
        case .speaking: .speaking
        case .hello: .notSetUp
        }
    }

    /// Blue while it is Poki's own business; amber when it waits for you, green for done, red for a
    /// problem, grey asleep.
    var dot: Color {
        switch self {
        case .needsYou, .yourTurn: Tint.amber
        case .done: Tint.green
        case .tripped, .cantReach: Tint.red
        case .paused: Color(.tertiaryLabel)
        default: Tint.blue
        }
    }

    /// The image's own background: the bear sleeps on the night blue.
    var ground: Color { self == .paused ? Tint.night : Tint.blue }

    static func image(_ mood: PokiMood, small: Bool) -> UIImage? {
        UIImage(named: "\(small ? "PokiBearSmall" : "PokiBear")-\(mood.rawValue)")
    }

    /// The bear without its ground, for where it stands on the page itself: every face at 256 px, and
    /// at 768 px the five the home page shows. A stand-in keyed from the pictures above until the
    /// artwork comes with its own transparency (ESP-319).
    static func cutout(_ mood: PokiMood, small: Bool) -> UIImage? {
        if !small, let large = UIImage(named: "PokiBearCut-\(mood.rawValue)") { return large }
        return UIImage(named: "PokiBearCutSmall-\(mood.rawValue)")
    }
}

/// What the bear shows and says now.
struct PokiStatus: Equatable {
    var mood: PokiMood
    var word: String

    init(_ mood: PokiMood, word: String? = nil) {
        self.mood = mood
        self.word = word ?? mood.word
    }

    /// Read from what the app already knows, most pressing first: a live voice turn, a step waiting for
    /// your answer, a hand-over, a task under way, a problem, and at rest whether Poki is on.
    @MainActor static func current(model: AppModel, chat: ChatModel) -> PokiStatus {
        // The demo conversation (`-pokiChat demo`) has no phone behind it: its own script says what shows.
        if chat.isDemo {
            if chat.demoAsk != nil { return PokiStatus(.needsYou) }
            if chat.running { return PokiStatus(running(chat.entries)) }
            return PokiStatus(DoneLinger.shared.showing ? .done : .ready)
        }
        if let sample = sample() { return sample }
        if model.preparingPhone, model.approvals.isEmpty, model.handoffText == nil {
            return PokiStatus(.thinking, word: AppLocalization.text("Preparing"))
        }
        let voice = model.voice
        // During a talk the picture stays the three-dimensional bear, with the talk's word beside it: the
        // flat listening and speaking faces carry sound waves the model does not have.
        if voice.isOn, let talk = voice.talkState {
            switch talk {
            case .connecting, .failed: break
            case .thinking: return PokiStatus(.thinking)
            case .acting: return PokiStatus(.onYourPhone)
            case .listening, .hearing, .speaking, .interrupted: return PokiStatus(.ready, word: talk.word)
            }
        }
        if !model.approvals.isEmpty { return PokiStatus(.needsYou) }
        if model.handoffText != nil { return PokiStatus(.yourTurn) }
        if chat.running { return PokiStatus(running(chat.entries)) }
        // An outside agent has the phone (its own MCP session, or a task it handed to Poki).
        if model.currentCaller != nil { return PokiStatus(.onYourPhone) }
        if SetupIssueHint.runnerIssue(model: model) != nil { return PokiStatus(.cantReach) }
        if chat.canRetry { return PokiStatus(.tripped) }
        if DoneLinger.shared.showing { return PokiStatus(.done) }
        // Setup is open, unless only the loopback is missing and Poki can start without it (main's rule for Home).
        if !model.canStartTasks { return PokiStatus(.hello) }
        if !(model.sessionOn || model.wantsOn) { return PokiStatus(.paused, word: StatusWord.off.text) }
        // Standing by (after Turn On, after the idle minute, or after the owner's pause) is Ready: the
        // next task or agent request wakes it, and nothing is yours to do (the owner, 2026-11-13).
        return PokiStatus(.ready)
    }

    /// During a task: thinking until its first step shows, checking while the model weighs a sensitive
    /// step, on the phone for the rest. Not from `awaitingModel`, which flips at every step.
    private static func running(_ entries: [ChatEntry]) -> PokiMood {
        var acted = false
        for entry in entries.reversed() {
            switch entry.kind {
            case .you, .request: return acted ? .onYourPhone : .thinking
            case .note(.modelChecking): if !acted { return .checking }
            case .note(.approval(let note)): if !acted, note.state == .asking, note.byModel { return .checking }
            case .plan, .step: acted = true
            default: continue
            }
        }
        return acted ? .onYourPhone : .thinking
    }

    /// The boards' sample conversations (`-pokiChat`), for screenshots: the face their scene shows.
    private static func sample() -> PokiStatus? {
        guard let scene = UserDefaults.standard.string(forKey: "pokiChat") else { return nil }
        switch scene {
        case "empty", "rested": return PokiStatus(.ready)
        case "working": return PokiStatus(.onYourPhone)
        case "approval": return PokiStatus(.needsYou)
        case "handoff": return PokiStatus(.yourTurn)
        case "failed", "setupHint": return PokiStatus(.tripped)
        case "paused": return PokiStatus(.paused)
        default: return PokiStatus(.done)
        }
    }
}

/// A task that ended well keeps the bear happy for a moment (the prototype's 4.5 s), then it is ready again.
@MainActor
@Observable
final class DoneLinger {
    static let shared = DoneLinger()
    private(set) var showing = false
    private var task: Task<Void, Never>?

    func celebrate() {
        showing = true
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .seconds(4.5))
            if !Task.isCancelled { showing = false }
        }
    }
}

/// The bear's face, square, on its own blue. `small` takes the avatar set.
struct PokiBear: View {
    var mood: PokiMood
    var small = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            mood.ground
            if let image = PokiMood.image(mood, small: small) {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                    .id(mood)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.86).combined(with: .opacity))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.3, bounce: 0.55), value: mood)
        .accessibilityHidden(true)
    }
}

/// The bear as an avatar: its face on a rounded square with the app icon's corner (28 % of the side).
/// In dark, a hairline keeps the blue block's edge where a shadow would glow.
struct PokiAvatar: View {
    var size: CGFloat
    var mood: PokiMood = .ready

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        PokiBear(mood: mood, small: size <= 64)
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Tint.ring, lineWidth: 1))
    }
}

/// A dot and the status word: "● Ready".
struct PokiStatusLine: View {
    var status: PokiStatus
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(status.mood.dot).frame(width: 6, height: 6)
            Text(verbatim: status.word).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
