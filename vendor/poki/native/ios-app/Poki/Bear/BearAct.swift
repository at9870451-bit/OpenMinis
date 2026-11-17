import RealityKit
import simd

/// What the three-dimensional bear plays for Poki's state, with its own joints and the faces the model
/// has (the closed eyes' arcs, the open mouth, the sparkles, the raised paw of its wave), on top of what
/// it does by itself (`BearIdle`). The model and its look are unchanged; each state means what its flat
/// picture means.
enum BearAct: Equatable {
    /// Standing by itself, looking about and doing its small things.
    case ready
    /// A paw up by its chin, its head tilted, looking up.
    case thinking
    /// Its head down over its paws, which tap away under its chin.
    case working
    /// A paw up, asking for an Allow.
    case asking
    /// The phone is yours for a step: it turns its head away and shuts its eyes, not looking.
    case waiting
    /// A task is done: it is pleased for a moment, then stands by itself again.
    case done
    /// A task went wrong: it is sad for a moment, then stands by itself again.
    case failed
    /// Off: asleep, its head on one side, its eyes shut.
    case paused
    /// Poki cannot reach the phone: a paw up beside its head, rubbing there, looking up, puzzled.
    case lost
    /// A paw up beside its ear, its head tilted, nodding now and then.
    case listening
    /// Its mouth moving as it talks.
    case speaking
    /// Set-up: it waves, its mouth open, the sparkles out.
    case hello
}

extension PokiMood {
    /// The bear's act for this state.
    var act: BearAct? {
        switch self {
        case .ready: .ready
        case .thinking: .thinking
        case .onYourPhone, .checking: .working
        case .needsYou: .asking
        case .yourTurn: .waiting
        case .done: .done
        case .tripped: .failed
        case .paused: .paused
        case .cantReach: .lost
        case .listening: .listening
        case .speaking: .speaking
        case .hello: .hello
        }
    }

    /// The faces the three-dimensional bear plays: all of them.
    var modelled: Bool { act != nil }
}

/// How the bear stands for an act, and what moves while it holds it, laid on top of the standing pose.
enum BearStance {
    /// The pose it holds. Done and gone wrong react once (`BearReaction`) and then stand as when ready.
    static func pose(_ act: BearAct) -> BearIdle.Pose {
        var p = BearIdle.Pose()
        switch act {
        case .ready, .done, .failed:
            break
        case .thinking:
            p.headPitch = -0.08; p.headRoll = 0.1
            p.gaze = [0.005, 0.007]
            // The paw comes in toward the chin as far as it stays in front of the cheek.
            p.raise = 0.55; p.bend = 0.3; p.reach = 0.6
        case .working:
            p.headPitch = 0.14
            p.gaze = [0, -0.006]
            p.work = 1
        case .asking:
            p.headRoll = 0.08
            p.gaze = [0.003, 0.004]
            p.raise = 0.9
        case .waiting:
            p.headYaw = 0.35; p.headPitch = 0.1
            // The head is turned and lowered onto the left paw, which goes down from under it.
            p.lower = [0.1, 0]
            p.shut = 1
        case .paused:
            p.headPitch = 0.18; p.headRoll = 0.22
            // The head hangs onto the right paw, which goes down from under it.
            p.lower = [0, 0.5]
            p.shoulders = -0.1
            p.shut = 1
        case .lost:
            p.headPitch = -0.1; p.headRoll = -0.1
            p.gaze = [-0.004, 0.008]
            // The paw is beside the head, where the rubbing does not take it into the head.
            p.raise = 0.9; p.reach = 0.5
        case .listening:
            // Tilted further toward the paw, the head came down on it.
            p.headRoll = -0.04
            p.gaze = [-0.004, 0.002]
            p.raise = 0.8; p.reach = 0.3
        case .speaking:
            p.headPitch = -0.05
            p.mouth = 1
        case .hello:
            p.raise = 1
            p.mouth = 1
            p.sparkles = 1
        }
        return p
    }

    /// What moves while it holds the act, `t` seconds into it.
    static func motion(_ act: BearAct, at t: TimeInterval) -> BearIdle.Pose {
        var p = BearIdle.Pose()
        switch act {
        case .ready, .done, .failed, .waiting:
            break
        case .thinking:
            // A slow tilt of the head, one way and the other.
            p.headRoll = 0.04 * Float(sin(t * 1.9))
        case .working:
            // The paws tap, and the head nods a little with them.
            p.tap = Float(sin(t * 2 * .pi * 2.5))
            p.headPitch = 0.02 * Float(sin(t * 2 * .pi * 1.25))
        case .asking:
            // The raised paw waves a little.
            p.raise = 0.1 * Float(sin(t * 2 * .pi * 1.2))
        case .paused:
            // Asleep: a slow nod with each long breath.
            p.headPitch = 0.03 * Float(sin(t * 2 * .pi / 4))
        case .lost:
            // The paw rubs beside the head, twice a second.
            p.bend = 0.12 * Float(sin(t * 2 * .pi * 2))
        case .listening:
            // A small nod every few seconds.
            let x = t.truncatingRemainder(dividingBy: 3.5)
            p.headPitch = x < 0.6 ? 0.06 * Float(sin(x / 0.6 * .pi)) : 0
        case .speaking:
            p.mouth = BearTalk.open(at: t) - 1
            p.headPitch = 0.02 * Float(sin(t * 7))
        case .hello:
            p.raise = 0.15 * Float(sin(t * 2 * .pi * 1.5)) - 0.15
        }
        return p
    }
}

/// The way from one act's stance to the next: about half a second, easing in and out, from wherever
/// the bear was, so a state that changes again on the way does not jump.
struct BearStanceChange {
    static let length: TimeInterval = 0.45
    private(set) var act: BearAct
    private var previous: BearAct
    private var since: TimeInterval
    /// The stance the change set out from: where the last change had got to when this one began.
    private var from = BearIdle.Pose()

    init(_ act: BearAct, at now: TimeInterval) {
        self.act = act
        previous = act
        since = now - Self.length
    }

    mutating func go(to next: BearAct, at now: TimeInterval) {
        guard next != act else { return }
        from = pose(at: now)
        previous = act
        act = next
        since = now
    }

    /// How far the change is, from 0 (where it set out) to 1 (the new stance).
    func progress(at now: TimeInterval) -> Float { BearIdle.ease(Float((now - since) / Self.length)) }

    func changing(at now: TimeInterval) -> Bool { now - since < Self.length }

    /// The stance at `now`, with what moves in it.
    func pose(at now: TimeInterval) -> BearIdle.Pose {
        let w = progress(at: now)
        let target = BearStance.pose(act) + BearStance.motion(act, at: now - since)
        if w >= 1 { return target }
        return from * (1 - w) + target * w
    }
}

/// How far the mouth is open as the bear talks, against open: syllables of uneven length and size, from
/// two slow waves that never line up.
enum BearTalk {
    static func open(at t: TimeInterval) -> Float {
        let a = abs(sin(t * 9.3)), b = 0.5 + 0.5 * sin(t * 2.3 + 0.7)
        return Float(0.3 + 0.7 * a * (0.55 + 0.45 * b))
    }
}

/// A reaction played once when the state changes, from wherever the bear is, and back to standing:
/// pleased when a task is done (its arms go up, its eyes smile as in a blink, its mouth opens, the
/// sparkles come out and it gives two little bounces), sad when one went wrong (as its flat picture: a
/// paw up beside its cheek, rubbing there, the head tilted and lowered, the eyes drooping and looking
/// down). It comes in over a third of a second and goes over half a second, so a change of state is
/// never a jump.
struct BearReaction: Equatable {
    enum Kind: Equatable { case joy, sorrow }
    let kind: Kind
    let start: TimeInterval

    static let rise: TimeInterval = 0.35, fall: TimeInterval = 0.5
    var hold: TimeInterval { kind == .joy ? 1.0 : 1.4 }
    var length: TimeInterval { Self.rise + hold + Self.fall }
    var end: TimeInterval { start + length }

    init?(_ act: BearAct, at now: TimeInterval) {
        switch act {
        case .done: kind = .joy
        case .failed: kind = .sorrow
        default: return nil
        }
        start = now
    }

    /// How far into it the bear is, from 0 (standing) to 1 (the reaction at its full).
    func weight(at t: TimeInterval) -> Float {
        let x = t - start
        if x <= 0 || x >= length { return 0 }
        if x < Self.rise { return BearIdle.ease(Float(x / Self.rise)) }
        if x < Self.rise + hold { return 1 }
        return 1 - BearIdle.ease(Float((x - Self.rise - hold) / Self.fall))
    }

    /// The pose laid on top of the standing one.
    func pose(at t: TimeInterval) -> BearIdle.Pose {
        let w = weight(at: t)
        var p = BearIdle.Pose()
        guard w > 0 else { return p }
        // Time into the hold, for what moves along while it is held.
        let held = max(t - start - Self.rise, 0)
        switch kind {
        case .joy:
            p.arms = 0.75 * w
            p.smile = BearIdle.ease((w - 0.3) / 0.5)
            p.headPitch = -0.1 * w
            let hop = held < 0.8 ? Float(abs(sin(2.5 * .pi * held))) : 0
            p.bodyLift = 0.03 * hop * w
            p.shoulders = 0.12 * hop * w
            p.mouth = w
            p.sparkles = w
        case .sorrow:
            p.headPitch = 0.12 * w
            p.headRoll = 0.1 * w
            p.shoulders = -0.1 * w
            p.gaze = SIMD2(0, -0.006) * w
            p.scratch = w
            // The other paw goes down a little from under the lowered head.
            p.lower = [0.04 * w, 0]
            // The paw rubs beside the cheek, three times a second, while it is held.
            p.rub = held < hold ? Float(sin(2 * .pi * 3 * held)) : 0
        }
        return p
    }
}
