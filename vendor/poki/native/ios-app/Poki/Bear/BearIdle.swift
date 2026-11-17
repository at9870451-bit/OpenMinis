import RealityKit
import simd

/// What the bear does by itself while it stands there, so that it is alive without a tap: it breathes
/// (a breath every 3 to 4 seconds, each a little different), sways slowly, and every few seconds does
/// one small thing, a different one each time, taking turns: it looks somewhere (to one side, its head
/// tilted, or up), stretches with its arms up and its eyes smiling, gives two little bounces, or rocks
/// its head from side to side as if humming. The waits, the order, the sides and the sizes are drawn
/// at random, so it never runs as a loop. It moves the bear's own joints on top of the model's standing
/// pose: the body, the head, the shoulders, the arms and the eyes, never the whole model. Angles are in
/// radians and lengths in the model's metres.
struct BearIdle {
    struct Pose: Equatable {
        var bodyLift: Float = 0, bodyRoll: Float = 0, bodyYaw: Float = 0
        var headYaw: Float = 0, headPitch: Float = 0, headRoll: Float = 0
        var shoulders: Float = 0
        /// Where the pupils look, sideways and up.
        var gaze = SIMD2<Float>(0, 0)
        /// How far both arms are up, from 0 (down) to 1: a paw out beside each cheek.
        var arms: Float = 0
        /// How far the eyes have gone to the smile's arcs, from 0 (open) to 1 (smiling).
        var smile: Float = 0
        /// How far the right paw is up beside the cheek, from 0 to 1, and how it rubs there (-1 to 1).
        var scratch: Float = 0, rub: Float = 0
        /// The raised left paw bent in toward the head, and brought forward, from 0 to 1: with `raise`,
        /// at the chin, the ear or the top of the head.
        var bend: Float = 0, reach: Float = 0
        /// Both paws down and forward from where they rest, working, from 0 to 1, and their tapping
        /// (-1 to 1): one goes down as the other comes up.
        var work: Float = 0, tap: Float = 0
        /// How far the left paw is up, as at the top of the model's wave.
        var raise: Float = 0
        /// How far the resting paws are turned down, out of the way of a head that comes down on them:
        /// the left one and the right one, in radians.
        var lower = SIMD2<Float>(0, 0)
        /// How far the eyes are shut, as a line, from 0 (open) to 1.
        var shut: Float = 0
        /// How far the mouth is open (from a quarter on), and the sparkles out, from 0 to 1.
        var mouth: Float = 0, sparkles: Float = 0

        static func + (a: Pose, b: Pose) -> Pose {
            var p = Pose()
            p.bodyLift = a.bodyLift + b.bodyLift; p.bodyRoll = a.bodyRoll + b.bodyRoll; p.bodyYaw = a.bodyYaw + b.bodyYaw
            p.headYaw = a.headYaw + b.headYaw; p.headPitch = a.headPitch + b.headPitch; p.headRoll = a.headRoll + b.headRoll
            p.shoulders = a.shoulders + b.shoulders; p.gaze = a.gaze + b.gaze
            p.arms = a.arms + b.arms; p.smile = a.smile + b.smile
            p.scratch = a.scratch + b.scratch; p.rub = a.rub + b.rub
            p.bend = a.bend + b.bend; p.reach = a.reach + b.reach; p.work = a.work + b.work; p.tap = a.tap + b.tap
            p.raise = a.raise + b.raise; p.lower = a.lower + b.lower; p.shut = a.shut + b.shut; p.mouth = a.mouth + b.mouth; p.sparkles = a.sparkles + b.sparkles
            return p
        }

        static func * (a: Pose, w: Float) -> Pose {
            var p = Pose()
            p.bodyLift = a.bodyLift * w; p.bodyRoll = a.bodyRoll * w; p.bodyYaw = a.bodyYaw * w
            p.headYaw = a.headYaw * w; p.headPitch = a.headPitch * w; p.headRoll = a.headRoll * w
            p.shoulders = a.shoulders * w; p.gaze = a.gaze * w
            p.arms = a.arms * w; p.smile = a.smile * w
            p.scratch = a.scratch * w; p.rub = a.rub * w
            p.bend = a.bend * w; p.reach = a.reach * w; p.work = a.work * w; p.tap = a.tap * w
            p.raise = a.raise * w; p.lower = a.lower * w; p.shut = a.shut * w; p.mouth = a.mouth * w; p.sparkles = a.sparkles * w
            return p
        }
    }

    /// The small things it does, which take turns.
    enum Gesture: CaseIterable { case look, stretch, bounce, hum }

    /// One small thing: it goes into it, holds, and comes back. A look or a stretch has a pose it holds;
    /// a bounce or a hum moves all along.
    private struct Glance {
        var gesture: Gesture
        var start: TimeInterval, rise: TimeInterval, hold: TimeInterval, fall: TimeInterval
        var pose: Pose
        /// How far a hum rocks the head, and to which side first.
        var size: Float = 0
        /// When a hi cut it short: from then it goes back in 0.3 s.
        var stop: TimeInterval?
        var end: TimeInterval { min(start + rise + hold + fall, stop.map { $0 + 0.3 } ?? .infinity) }

        func weight(at t: TimeInterval) -> Float {
            let x = t - start
            if x <= 0 || t >= end { return 0 }
            let cut = stop.map { 1 - BearIdle.ease(Float((t - $0) / 0.3)) } ?? 1
            if x < rise { return BearIdle.ease(Float(x / rise)) * cut }
            if x < rise + hold { return cut }
            return (1 - BearIdle.ease(Float((x - rise - hold) / fall))) * cut
        }

        /// How far through it is, from 0 to 1.
        func progress(at t: TimeInterval) -> Double { min(max((t - start) / (rise + hold + fall), 0), 1) }

        /// Moving, not holding still: only a look holds still at its far end.
        func turning(at t: TimeInterval) -> Bool {
            guard t > start, t < end else { return false }
            if gesture != .look { return true }
            let x = t - start
            return x < rise || x >= rise + hold
        }
    }

    private var glance: Glance?
    /// While the bear plays a state other than ready, it starts none of its small things.
    var calm = false
    private var nextGlance: TimeInterval
    private var breath: Double = 0, breathAt: TimeInterval, breathLength: TimeInterval = 3.4
    private var lastSide: Float = Bool.random() ? 1 : -1
    /// The gestures still to come in this turn, each once; then a new turn in a new order.
    private var turn: [Gesture] = []
    private var lastGesture: Gesture?

    init(now: TimeInterval) {
        nextGlance = now + .random(in: 1.5...3.5)
        breathAt = now
    }

    /// How far a resting paw is turned down for each radian the head tilts to its side, by itself: the
    /// left paw, the right paw. The paws rest a finger under the chin, the left one nearer: tilted onto
    /// one, the head went into it. These are the least that keep them out.
    static let tilt: (left: Float, right: Float) = (2, 0.4)

    static func ease(_ x: Float) -> Float { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }

    /// Turning its head somewhere, so worth drawing at the full rate; breathing and swaying alone are slow enough for a third of it.
    func busy(at t: TimeInterval) -> Bool { glance?.turning(at: t) ?? false }

    /// Something else plays until `t`: nothing of its own starts before then, and not at once after.
    mutating func rest(until t: TimeInterval) {
        nextGlance = max(nextGlance, t + .random(in: 1.0...2.0))
    }

    /// A hi is coming: whatever it is doing, it comes back now, quickly.
    mutating func attend(at t: TimeInterval) {
        guard var g = glance, t < g.end else { return }
        if g.stop == nil { g.stop = t }
        glance = g
        nextGlance = max(nextGlance, t + 3)
    }

    /// `blinking`: a look somewhere does not start while the bear blinks; it waits for the eyes to open.
    mutating func pose(at t: TimeInterval, blinking: Bool = false) -> Pose {
        breath += (t - breathAt) / breathLength
        breathAt = t
        if breath >= 1 { breath = breath.truncatingRemainder(dividingBy: 1); breathLength = .random(in: 3.0...4.2) }
        let inhale = Float(0.5 - 0.5 * cos(2 * .pi * breath))
        var p = Pose()
        p.bodyLift = 0.010 * inhale
        p.shoulders = 0.05 * inhale
        p.headPitch = -0.025 * inhale
        // A slow sway that never lines up with itself.
        p.bodyRoll = 0.020 * Float(sin(t * 0.83) * 0.6 + sin(t * 0.37 + 1.3) * 0.4)
        p.bodyYaw = 0.025 * Float(sin(t * 0.29 + 0.4))
        p.headYaw = 0.03 * Float(sin(t * 0.41 + 2.1))
        if calm, glance.map({ t >= $0.end }) ?? true { nextGlance = max(nextGlance, t + .random(in: 1.0...2.0)) }
        if !blinking, !calm, t >= nextGlance, glance.map({ t >= $0.end }) ?? true {
            let g = makeGlance(at: t)
            glance = g
            nextGlance = g.end + .random(in: 1.2...4.5)
        }
        if let g = glance {
            let w = g.weight(at: t)
            p.headYaw += g.pose.headYaw * w
            p.headPitch += g.pose.headPitch * w
            p.headRoll += g.pose.headRoll * w
            p.bodyYaw += g.pose.bodyYaw * w
            p.gaze += g.pose.gaze * w
            p.arms += g.pose.arms * w
            p.lower += g.pose.lower * w
            // The eyes smile once the arms are most of the way up, and open before they come down.
            p.smile += g.pose.smile * Self.ease((w - 0.35) / 0.5)
            let x = g.progress(at: t)
            switch g.gesture {
            case .bounce:
                // Two little bounces, the second smaller.
                let hop = Float(abs(sin(2 * .pi * x))) * (x < 0.5 ? 1 : 0.7)
                p.bodyLift += 0.03 * hop * w
                p.shoulders += 0.12 * hop * w
            case .hum:
                // The head rocks side to side twice, the body a little after it.
                let swell = Float(sin(.pi * x))
                let rock = g.size * Float(sin(4 * .pi * x)) * swell * w
                p.headRoll += rock
                // The right paw is clear of a rock this small.
                p.lower.x += Self.tilt.left * max(-rock, 0)
                p.bodyRoll += 0.03 * Float(sin(4 * .pi * x - 0.6)) * swell * w
            case .look, .stretch:
                break
            }
        }
        return p
    }

    /// The next gesture: each once a turn, in a new order every turn, never the same twice in a row.
    mutating func nextGesture() -> Gesture {
        if turn.isEmpty {
            turn = Gesture.allCases.shuffled()
            if turn.first == lastGesture { turn.swapAt(0, turn.count - 1) }
        }
        let next = turn.removeFirst()
        lastGesture = next
        return next
    }

    private mutating func makeGlance(at t: TimeInterval) -> Glance {
        // Mostly the other way from the last time.
        let side: Float = Int.random(in: 0..<4) == 0 ? lastSide : -lastSide
        lastSide = side
        var pose = Pose()
        switch nextGesture() {
        case .stretch:
            pose.arms = 1
            pose.smile = 1
            pose.headPitch = -0.14
            return Glance(gesture: .stretch, start: t, rise: .random(in: 0.6...0.8), hold: .random(in: 0.8...1.2), fall: .random(in: 0.6...0.8), pose: pose)
        case .bounce:
            return Glance(gesture: .bounce, start: t, rise: 0, hold: .random(in: 0.8...1.0), fall: 0, pose: pose)
        case .hum:
            return Glance(gesture: .hum, start: t, rise: 0, hold: .random(in: 2.0...2.6), fall: 0, pose: pose, size: side * .random(in: 0.08...0.11))
        case .look:
            break
        }
        switch Int.random(in: 0..<10) {
        case 0..<5: // a look to the side
            pose.headYaw = side * .random(in: 0.18...0.30)
            pose.bodyYaw = side * 0.05
            pose.headPitch = .random(in: -0.06...0.04)
            pose.gaze = SIMD2(side * 0.009, .random(in: -0.002...0.004))
        case 5..<8: // the head tilted, curious
            pose.headRoll = side * .random(in: 0.10...0.15)
            pose.lower = SIMD2(Self.tilt.left * max(-pose.headRoll, 0), Self.tilt.right * max(pose.headRoll, 0))
            pose.headYaw = side * 0.06
            pose.gaze = SIMD2(side * 0.004, 0.003)
        default: // a look up
            pose.headPitch = -.random(in: 0.12...0.18)
            pose.headYaw = side * 0.08
            pose.gaze = SIMD2(side * 0.005, 0.008)
        }
        return Glance(gesture: .look, start: t, rise: .random(in: 0.35...0.55), hold: .random(in: 0.8...2.0), fall: .random(in: 0.45...0.7), pose: pose)
    }

    /// The farthest a look to the side goes, `side` of the way toward one side (-1 to 1), with the
    /// sway's own turn on top, and nothing else.
    static func farthest(_ side: Float) -> Pose {
        var p = Pose()
        p.headYaw = side * (0.30 + 0.03)
        p.bodyYaw = side * (0.05 + 0.025)
        p.gaze = SIMD2(side * 0.009, 0)
        return p
    }

}

/// The joints `BearIdle` moves, found by name in the model's skeleton. A model without them stands still.
struct BearIdleJoints {
    let body: Int, head: Int
    let shoulders: (right: Int, left: Int)?
    /// The pupils and the smile's arcs, which look with them.
    let eyes: [Int]
    let pupils: [Int], arcs: [Int]
    /// The closed mouth and the open one, and the three sparkles.
    let mouths: [Int], sparkles: [Int]
    /// The upper arms and forearms, right and left.
    let arms: (upper: (right: Int, left: Int), fore: (right: Int, left: Int))?

    init?(names: [String]) {
        func joint(_ name: String) -> Int? { names.firstIndex { $0 == name || $0.hasSuffix("/" + name) } }
        guard let body = joint("Body"), let head = joint("Head") else { return nil }
        self.body = body
        self.head = head
        if let right = joint("Shoulder_R"), let left = joint("Shoulder_L") { shoulders = (right, left) } else { shoulders = nil }
        pupils = ["Eye_R", "Eye_L"].compactMap(joint)
        arcs = ["SmileEye_R", "SmileEye_L"].compactMap(joint)
        eyes = pupils + arcs
        mouths = ["Mouth", "MouthOpen"].compactMap(joint)
        sparkles = ["Spark_1", "Spark_2", "Spark_3"].compactMap(joint)
        if let ur = joint("UpperArm_R"), let ul = joint("UpperArm_L"), let fr = joint("Forearm_R"), let fl = joint("Forearm_L") {
            arms = ((ur, ul), (fr, fl))
        } else {
            arms = nil
        }
    }

    /// How far back the model's own blink puts the pupils, and forward the arcs, to swap them.
    static let swap: Float = 0.22
    /// How far the forearms turn down for work, and how far each way from there as the paws tap: they
    /// only ever go down from where they rest, so they stay out of the head and in sight under it.
    static let work: (down: Float, tap: Float, nod: Float) = (0.2, 0.2, 2)
    /// Both arms up, `arms` at 1: how far each goes along the model's wave, and how far its paw then
    /// comes in toward the cheek, as `bend` and `reach` bring it. Further along the wave the paws leave
    /// the picture's sides; nearer the cheeks they go into the head.
    static let cheer: (raise: Float, bend: Float, reach: Float) = (0.8, 0.2, 0.3)
    /// The right paw rubbing (`scratch` at 1): how far it goes along the wave, to beside the cheek, and
    /// how far its forearm turns each way as it rubs. Higher, the lowered head comes down on it.
    static let scratch: (raise: Float, rub: Float) = (0.5, 0.12)

    /// How far a pupil moves for `gaze`: across and up the face, and forward as much as across, so
    /// that it stays in front of the face's curve and its white.
    static func shift(_ gaze: SIMD2<Float>) -> SIMD3<Float> { SIMD3(gaze.x, gaze.y, abs(gaze.x)) }

    /// The raised paws, the open mouth and the sparkles, as the model has them at the top of its wave
    /// (`hello`): the paws and the sparkles part of the way; the mouth open from a quarter, as far as
    /// `pose.mouth` says. The model waves with its left paw only; the right one goes the same way on
    /// its own side. The wave takes the paw out round the head, which is wider than the shoulders: an
    /// arm turned straight up from where it hangs goes into the head. Laid before `apply`, which turns
    /// the joints from where these leave them.
    func show(_ pose: BearIdle.Pose, from hello: [Transform], in joints: inout [Transform]) {
        func toward(_ joint: Int, _ b: Transform, _ w: Float) {
            guard joint < joints.count, w > 0 else { return }
            let a = joints[joint], w = min(w, 1)
            joints[joint] = Transform(scale: simd_mix(a.scale, b.scale, SIMD3(repeating: w)), rotation: simd_slerp(a.rotation, b.rotation, w),
                                      translation: simd_mix(a.translation, b.translation, SIMD3(repeating: w)))
        }
        for joint in sparkles where joint < hello.count { toward(joint, hello[joint], pose.sparkles) }
        var sides: [(left: Int, right: Int)] = []
        if let (right, left) = shoulders { sides.append((left, right)) }
        if let (upper, fore) = arms { sides += [(upper.left, upper.right), (fore.left, fore.right)] }
        for (left, right) in sides where max(left, right) < min(joints.count, hello.count) {
            // The left joint's way to the top of the wave, on the other side of the body's middle.
            let from = joints[left], to = hello[left], turn = to.rotation * from.rotation.inverse
            let mirrored = Transform(scale: joints[right].scale * to.scale / from.scale,
                                     rotation: simd_quatf(ix: turn.imag.x, iy: -turn.imag.y, iz: -turn.imag.z, r: turn.real) * joints[right].rotation,
                                     translation: joints[right].translation + (to.translation - from.translation) * SIMD3(-1, 1, 1))
            toward(left, to, pose.raise + Self.cheer.raise * pose.arms)
            toward(right, mirrored, Self.cheer.raise * pose.arms + Self.scratch.raise * pose.scratch)
        }
        if pose.mouth >= 0.25 {
            for joint in mouths where joint < joints.count && joint < hello.count { joints[joint] = hello[joint] }
            if let open = mouths.last, open < joints.count { joints[open].scale.y *= min(pose.mouth, 1) }
        }
    }

    /// The pupils' or the arcs' height where the blink is.
    func shut(_ blink: BearBlink.Moment, in joints: inout [Transform]) {
        if let height = blink.pupils { for joint in pupils where joint < joints.count { joints[joint].scale.y = height } }
        if let height = blink.arcs { for joint in arcs where joint < joints.count { joints[joint].scale.y = height } }
    }

    /// `pose` laid on the model's standing pose. In the model's joints y is up, z forward and x across.
    func apply(_ pose: BearIdle.Pose, to joints: inout [Transform]) {
        guard joints.count > max(body, head) else { return }
        joints[body].translation.y += pose.bodyLift
        joints[body].rotation *= simd_quatf(angle: pose.bodyYaw, axis: [0, 1, 0]) * simd_quatf(angle: pose.bodyRoll, axis: [0, 0, 1])
        joints[head].rotation *= simd_quatf(angle: pose.headYaw, axis: [0, 1, 0]) * simd_quatf(angle: pose.headPitch, axis: [1, 0, 0])
            * simd_quatf(angle: pose.headRoll, axis: [0, 0, 1])
        if let (right, left) = shoulders, joints.count > max(right, left) {
            joints[right].rotation *= simd_quatf(angle: -pose.shoulders, axis: [0, 0, 1])
            joints[left].rotation *= simd_quatf(angle: pose.shoulders, axis: [0, 0, 1])
        }
        let shift = Self.shift(pose.gaze)
        for eye in eyes where eye < joints.count { joints[eye].translation += shift }
        if let (upper, fore) = arms, joints.count > max(upper.right, upper.left, fore.right, fore.left) {
            // Only as far as a paw rests: turned down while it is up, it would go into the head. The right
            // paw going up to rub is still beside the lowered head, and keeps its lowering.
            let resting = max(1 - pose.arms, 0)
            joints[fore.left].rotation *= simd_quatf(angle: pose.lower.x * min(max(resting - pose.raise, 0), 1), axis: [1, 0, 0])
            joints[fore.right].rotation *= simd_quatf(angle: pose.lower.y * min(resting, 1), axis: [1, 0, 0])
            let bend = Self.cheer.bend * pose.arms, reach = Self.cheer.reach * pose.arms
            joints[upper.left].rotation *= simd_quatf(angle: -0.6 * (pose.reach + reach), axis: [1, 0, 0])
            joints[fore.left].rotation *= simd_quatf(angle: -1.4 * (pose.bend + bend), axis: [0, 0, 1])
            joints[upper.right].rotation *= simd_quatf(angle: -0.6 * reach, axis: [1, 0, 0])
            joints[fore.right].rotation *= simd_quatf(angle: 1.4 * (bend + Self.scratch.rub * pose.rub), axis: [0, 0, 1])
            if pose.work > 0 {
                // The head is lowered over the paws, and nods: they go down twice as far as it does.
                let down = Self.work.down + Self.work.nod * max(pose.headPitch, 0)
                joints[fore.right].rotation *= simd_quatf(angle: (down - Self.work.tap * pose.tap) * pose.work, axis: [1, 0, 0])
                joints[fore.left].rotation *= simd_quatf(angle: (down + Self.work.tap * pose.tap) * pose.work, axis: [1, 0, 0])
            }
        }
        if pose.smile > 0 { smile(pose.smile, in: &joints) } else if pose.shut > 0 { smile(pose.shut, top: 0.2, in: &joints) }
    }

    /// The eyes going to the smile's arcs and back as a blink does: the pupils flatten to a line, are
    /// swapped for the arcs at that line, and the arcs curve up out of it.
    /// `top`: how tall the arcs grow, against the smile's; low, the eyes are shut as a line.
    private func smile(_ amount: Float, top: Float = 1, in joints: inout [Transform]) {
        let thin = BearBlink.thin
        if amount < 0.5 {
            for joint in pupils where joint < joints.count { joints[joint].scale.y = 1 - (1 - thin) * BearIdle.ease(amount / 0.5) }
            return
        }
        for joint in pupils where joint < joints.count { joints[joint].translation.z -= Self.swap; joints[joint].scale.y = thin }
        for joint in arcs where joint < joints.count {
            joints[joint].translation.z += Self.swap
            joints[joint].scale.y = min(top, BearBlink.flat) + max(top - BearBlink.flat, 0) * BearIdle.ease((amount - 0.5) / 0.5)
        }
    }
}
