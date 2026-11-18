// SPDX-License-Identifier: AGPL-3.0-only
// Extracted from the Amore port of Poki Chat/Marquee.swift at
// 69585293051fee03c7ad110f037d8f4dd2a4e96f. Easing/time-wrap attribution:
// MarqueeSwiftUI, MIT, Copyright (c) 2024 nainamaharjan; see THIRD_PARTY_NOTICES.md.
import Foundation

/// Deterministic clock used by the UIKit marquee and pure-data regression tests.
/// Preserves Poki/MarqueeSwiftUI's dt clamp, easing, wrap and two-second touch rest.
struct AmoreMarqueeClock {
    private(set) var last: TimeInterval = 0
    private(set) var velocity: Double = 0
    private(set) var drift: Double = 0
    private(set) var held = false
    private(set) var resumeAt: TimeInterval = 0
    static let rest: TimeInterval = 2

    mutating func resetTimestamp() { last = 0 }
    mutating func resetDrift() { drift = 0 }
    mutating func hold() { held = true; velocity = 0 }

    @discardableResult
    mutating func advance(to now: TimeInterval, period: Double, speed: Double,
                          running: Bool, touching: Bool, scale: Double) -> String {
        let delta = last > 0 ? min(max(0, now - last), 0.1) : 0
        last = now
        guard period.isFinite, period > 0 else { return "idle" }
        if touching {
            held = true
            velocity = 0
            return "held"
        }
        if held {
            held = false
            resumeAt = now + Self.rest
        }
        let target = running && now >= resumeAt ? speed : 0
        velocity += (target - velocity) * delta * 3
        if target == 0, abs(velocity) <= 0.05 {
            velocity = 0
            let scale = max(scale, 1)
            drift = (drift * scale).rounded() / scale
            return "rest"
        }
        drift = (drift + velocity * delta).truncatingRemainder(dividingBy: period)
        if drift < 0 { drift += period }
        return "auto"
    }
}
