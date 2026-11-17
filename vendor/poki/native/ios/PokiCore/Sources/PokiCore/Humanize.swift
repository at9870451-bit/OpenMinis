import Foundation

/// Touches and typing shaped after a person's, so the owner's own apps take Poki's input as the
/// owner's. A synthesised touch that holds for exactly 50 ms without moving, a drag that runs in a
/// straight line at one speed, text that arrives at a fixed 120 characters a second: apps that watch
/// for scripted input see all three, and some treat the owner's session as a bot (captchas, silent
/// refusals, a logged-out account). A person's tap holds for 50 to 140 ms, lands a point or two off
/// the centre and drifts slightly before lifting; a swipe accelerates and decelerates along a
/// minimum-jerk profile (Flash & Hogan 1985) with a slight sideways arc; typing comes in word-sized
/// bursts at an uneven pace.
///
/// Speed is kept: the shaped gesture takes the time the plain one took (a tap gains ~25 ms of hold,
/// a drag 15-40 ms of contact before it moves), a flick still lifts at speed so the list coasts, and
/// a resting drag still ends with the finger still. Typing is the one trade: a short text goes at a
/// quick typist's pace (about 20 characters a second plus word gaps) and a long one faster.
///
/// `POKI_HUMANIZE=off` (or `CoreConfig.humanize = false`) sends the exact legacy schedules through the
/// legacy endpoints, so the gym can compare the two; `POKI_HUMANIZE_SEED=<n>` makes a run repeatable.
/// Every plan is a list of fingers, each a list of (x, y, seconds since the finger went down), sent
/// as W3C pointer actions (`POST /actions`), which WebDriverAgent and Poki's in-process table both
/// turn into one XCPointerEventPath with those waypoints.
struct Humanize: Sendable {
    typealias Sample = (x: Double, y: Double, t: Double)

    private(set) var enabled: Bool
    private var state: UInt64

    /// On unless `POKI_HUMANIZE` is off, 0 or false.
    static let envEnabled: Bool = !["off", "0", "false", "no"].contains((ProcessInfo.processInfo.environment["POKI_HUMANIZE"] ?? "").lowercased())

    init(enabled: Bool = Humanize.envEnabled, seed: UInt64? = nil) {
        self.enabled = enabled
        let fromEnv = ProcessInfo.processInfo.environment["POKI_HUMANIZE_SEED"].flatMap { UInt64($0) }
        state = seed ?? fromEnv ?? (UInt64(DispatchTime.now().uptimeNanoseconds) ^ (UInt64(ProcessInfo.processInfo.processIdentifier) << 32))
    }

    static var off: Humanize { Humanize(enabled: false, seed: 0) }

    // MARK: Sampling (SplitMix64: small, well distributed, no dependency)

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func uniform() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * uniform() }
    /// Standard normal (Box-Muller, one draw per call).
    mutating func normal() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
    /// Log-normal around `median`, clamped: how long presses, pauses and key gaps are distributed.
    mutating func lognormal(median: Double, sigma: Double, min lo: Double, max hi: Double) -> Double {
        min(hi, max(lo, median * exp(sigma * normal())))
    }
    /// Normal with `sigma`, clamped to ±`limit`.
    mutating func scatter(_ sigma: Double, limit: Double) -> Double { min(limit, max(-limit, normal() * sigma)) }

    // MARK: Profiles

    /// Minimum-jerk position along a reach: 0 at s 0, 1 at s 1, still at both ends.
    static func minimumJerk(_ s: Double) -> Double {
        let s = min(1, max(0, s))
        return s * s * s * (10 - 15 * s + 6 * s * s)
    }

    /// A flick's profile: the first 62 % of a minimum-jerk reach, rescaled to arrive, so the finger
    /// is still gathering speed when it lifts (1.4 times its mean speed) and the list coasts as it
    /// does after a person's flick. The plain two-point drag lifted at exactly its mean speed.
    static func flick(_ s: Double) -> Double {
        let cut = 0.62
        return minimumJerk(cut * min(1, max(0, s))) / minimumJerk(cut)
    }

    // MARK: Plans

    /// One finger's tap: contact a point or two off `p` (inside `frame`'s middle when one is known),
    /// a press of 50-140 ms (median 75), and a drift of under a point before the lift.
    mutating func tap(at p: (x: Double, y: Double), within frame: Rect? = nil) -> [Sample] {
        guard enabled else { return [(p.x, p.y, 0), (p.x, p.y, 0.05)] }
        let contact = contactPoint(p, within: frame)
        let press = lognormal(median: 0.075, sigma: 0.3, min: 0.05, max: 0.14)
        let (dx, dy) = drift(0.2, 0.9)
        return [(contact.x, contact.y, 0), (contact.x, contact.y, press * uniform(0.3, 0.7)), (contact.x + dx, contact.y + dy, press)]
    }

    /// A long press: the hold is exact (the model asked for it); the contact is scattered as a tap's
    /// and the finger drifts under a point while it holds.
    mutating func longPress(at p: (x: Double, y: Double), seconds: Double, within frame: Rect? = nil) -> [Sample] {
        guard enabled else { return [(p.x, p.y, 0), (p.x, p.y, seconds)] }
        let contact = contactPoint(p, within: frame)
        let (dx, dy) = drift(0.2, 0.8)
        return [(contact.x, contact.y, 0), (contact.x + dx * 0.5, contact.y + dy * 0.5, seconds * 0.5), (contact.x + dx, contact.y + dy, seconds)]
    }

    /// A drag from one point to another in `seconds` of movement, after `hold` seconds still (a
    /// press-and-drag) and before `rest` seconds still (so the list stops where the finger stopped;
    /// 0 = a flick that leaves the list coasting). Movement follows a minimum-jerk profile (the
    /// flick's truncated one when there is no rest) along the chord with a slight arc (0.4-1.5 % of
    /// the distance, at most 6 points) and sub-point drift, sampled about every 16 ms with uneven
    /// spacing. The movement time is kept as given, with 15-40 ms of contact added before it starts.
    mutating func drag(from: (x: Double, y: Double), to: (x: Double, y: Double), seconds: Double, hold: Double = 0, rest: Double = 0) -> [Sample] {
        let seconds = max(0.05, seconds)
        guard enabled else {
            var out: [Sample] = [(from.x, from.y, 0)]
            if hold > 0 { out.append((from.x, from.y, hold)) }
            out.append((to.x, to.y, hold + seconds))
            if rest > 0 { out.append((to.x, to.y, hold + seconds + rest)) }
            return out
        }
        let start = (x: from.x + scatter(1, limit: 2), y: from.y + scatter(1, limit: 2))
        // The lift lands further off for a fast flick than for a drag that comes to rest.
        let endScatter = rest > 0 ? 0.5 : 1.5
        let end = (x: to.x + scatter(endScatter, limit: 4), y: to.y + scatter(endScatter, limit: 4))
        let dx = end.x - start.x, dy = end.y - start.y
        let distance = max(1, hypot(dx, dy))
        let (nx, ny) = (-dy / distance, dx / distance)
        let arc = min(6, distance * uniform(0.004, 0.015)) * (uniform() < 0.5 ? -1 : 1)
        let dwell = hold + uniform(0.015, 0.04)
        var out: [Sample] = [(start.x, start.y, 0)]
        if hold > 0 { out.append((start.x, start.y, hold * uniform(0.9, 1))) }
        out.append((start.x, start.y, dwell))
        let steps = max(6, Int((seconds * 60).rounded()))
        var t = 0.0, noise = 0.0
        for i in 1...steps {
            // Uneven frame spacing: no two samples the same distance apart in time.
            let dt = (seconds / Double(steps)) * uniform(0.75, 1.25)
            t = i == steps ? seconds : min(seconds - 0.004 * Double(steps - i), t + dt)
            let s = t / seconds
            let p = rest > 0 ? Self.minimumJerk(s) : Self.flick(s)
            noise = noise * 0.7 + scatter(0.25, limit: 0.6)
            let side = arc * sin(.pi * s) + noise
            out.append((start.x + dx * p + nx * side, start.y + dy * p + ny * side, dwell + t))
        }
        if rest > 0 {
            // Exactly still: the list must stop where the finger stopped (scroll_to's overlap check
            // and drag-back assume no coasting), and a sub-point tremor is not worth that risk.
            let last = out.last!
            out.append((last.x, last.y, dwell + seconds + rest))
        }
        return out
    }

    /// A pinch: two fingers on either side of `p`, each moving from `a` to `b` points off it along a
    /// minimum-jerk profile in `seconds`, their contacts and lifts scattered as a drag's.
    mutating func pinch(at p: (x: Double, y: Double), from a: Double, to b: Double, seconds: Double) -> [[Sample]] {
        let angle = enabled ? uniform(-0.25, 0.25) : 0
        return [-1.0, 1.0].map { sign in
            let from = (x: p.x + sign * a * cos(angle), y: p.y + sign * a * sin(angle))
            let to = (x: p.x + sign * b * cos(angle), y: p.y + sign * b * sin(angle))
            return drag(from: from, to: to, seconds: seconds, rest: enabled ? 0.03 : 0)
        }
    }

    /// Typed text as bursts: each word with its space is one burst at its own pace, with a pause
    /// between words. A short text (up to 40 characters) goes at a quick typist's pace, 12-40
    /// characters a second (median 22) with 40-220 ms between words; a longer one at 40-80 with
    /// 20-60 ms gaps, since a person would have pasted it. Text without spaces (CJK) is cut into
    /// bursts of 2-4 characters. Deletes stay one burst at 60 a second (a held delete key repeats).
    /// `frequency` is WebDriverAgent's `/wda/keys` characters per second.
    mutating func typing(_ text: String) -> [(text: String, frequency: Int, gapBefore: Double)] {
        let short = text.count <= 40
        var bursts: [String] = [], current = ""
        for ch in text {
            current.append(ch)
            let breaks = ch == " " || ch == "\n" || (!short && current.count >= 12) || (current.count >= (short ? 2 : 4) && !(ch.isLetter && ch.isASCII) && !ch.isNumber && !ch.isPunctuation && !ch.isWhitespace && uniform() < 0.5)
            if breaks { bursts.append(current); current = "" }
        }
        if !current.isEmpty { bursts.append(current) }
        return bursts.enumerated().map { i, burst in
            let frequency = short ? lognormal(median: 22, sigma: 0.25, min: 12, max: 40) : lognormal(median: 55, sigma: 0.2, min: 40, max: 80)
            let gap = i == 0 ? 0 : short ? lognormal(median: 0.09, sigma: 0.4, min: 0.04, max: 0.22) : uniform(0.02, 0.06)
            return (burst, Int(frequency.rounded()), gap)
        }
    }

    /// The plan in at most `count` bursts: neighbours are joined, each joined burst keeps the first
    /// one's gap and goes at the mean of their paces, so the text and its rhythm stay close.
    static func merged(_ plan: [(text: String, frequency: Int, gapBefore: Double)], into count: Int) -> [(text: String, frequency: Int, gapBefore: Double)] {
        guard count > 0, plan.count > count else { return plan }
        let size = Int((Double(plan.count) / Double(count)).rounded(.up))
        return stride(from: 0, to: plan.count, by: size).map { start in
            let group = plan[start..<min(plan.count, start + size)]
            return (group.map(\.text).joined(), group.map(\.frequency).reduce(0, +) / group.count, group.first?.gapBefore ?? 0)
        }
    }

    /// How long a typing plan takes on the keyboard: the bursts at their pace plus the gaps.
    static func seconds(of plan: [(text: String, frequency: Int, gapBefore: Double)]) -> Double {
        plan.reduce(0) { $0 + $1.gapBefore + Double($1.text.count) / Double(max(1, $1.frequency)) }
    }

    // MARK: Helpers

    /// `p` moved by a normal scatter of 0.8 points (at most 2), kept inside the middle half of
    /// `frame` when one is given, so the touch never leaves the element.
    private mutating func contactPoint(_ p: (x: Double, y: Double), within frame: Rect?) -> (x: Double, y: Double) {
        var x = p.x + scatter(0.8, limit: 2), y = p.y + scatter(0.8, limit: 2)
        if let f = frame, f.width >= 4, f.height >= 4 {
            let inset = Rect(x: f.x + f.width / 4, y: f.y + f.height / 4, width: f.width / 2, height: f.height / 2)
            if inset.contains(p) {
                x = min(inset.maxX, max(inset.x, x))
                y = min(inset.maxY, max(inset.y, y))
            } else {
                // The point was chosen off the centre on purpose (a free part of a covered element):
                // stay within a point of it.
                x = min(p.x + 1, max(p.x - 1, x))
                y = min(p.y + 1, max(p.y - 1, y))
            }
        }
        return (x, y)
    }

    private mutating func drift(_ lo: Double, _ hi: Double) -> (Double, Double) {
        let angle = uniform() * 2 * .pi, r = uniform(lo, hi)
        return (r * cos(angle), r * sin(angle))
    }

    /// Fingers as W3C pointer actions: per finger a move to the contact, a down, then each sample as
    /// a timed move (a pause when the finger did not move), and an up.
    static func actions(_ fingers: [[Sample]]) -> JSON {
        func round(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        let sources: [JSON] = fingers.enumerated().map { index, finger in
            guard let first = finger.first else { return .null }
            var steps: [JSON] = [
                ["type": "pointerMove", "duration": 0, "x": .number(round(first.x)), "y": .number(round(first.y))],
                ["type": "pointerDown", "button": 0],
            ]
            var last = first
            for s in finger.dropFirst() {
                let ms = max(0, ((s.t - last.t) * 1000).rounded())
                if s.x == last.x && s.y == last.y {
                    steps.append(["type": "pause", "duration": .number(ms)])
                } else {
                    steps.append(["type": "pointerMove", "duration": .number(ms), "x": .number(round(s.x)), "y": .number(round(s.y))])
                }
                last = s
            }
            steps.append(["type": "pointerUp", "button": 0])
            return ["type": "pointer", "id": .string("finger\(index + 1)"), "parameters": ["pointerType": "touch"], "actions": .array(steps)]
        }
        return ["actions": .array(sources)]
    }

    /// When the last sample lifts, in seconds, for the request's time limit.
    static func seconds(of fingers: [[Sample]]) -> Double { fingers.compactMap { $0.last?.t }.max() ?? 0 }
}
