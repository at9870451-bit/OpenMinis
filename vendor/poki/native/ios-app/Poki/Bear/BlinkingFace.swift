import SwiftUI
import UIKit

/// The bear's face for Poki's state, alive: it blinks every few seconds, now and then twice, and
/// gives a small hop when its state changes (ESP-468). It fills the square it is given.
///
/// It is drawn from the bear's cutouts. Each face with open eyes has a copy with both eyes, white and
/// pupil, filled with the face's own colour (PokiBearLids-<face>.png, made by scripts/make-bear-blink.py),
/// and the eyes of the cutout are laid back over it, so the whole eye is squeezed shut. A shut eye is
/// a thin line on the face, as the sleeping face's, not a line across a white disc. When the
/// three-dimensional bear arrives (ESP-319), its rendering takes the place of this view: Poki's
/// picture in the top bar and in the flight from the home page draw nothing else.
/// With Reduce Motion it neither blinks nor hops.
struct BlinkingFace: View {
    var mood: PokiMood
    /// The square's side. Given, not measured: measured inside the flight to the top bar, the bear
    /// lagged a beat behind its circle.
    var side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.coveredByDrawer) private var covered
    /// 0 with the eyes open, 1 shut.
    @State private var shut = 0.0
    @State private var hop = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let eyes = BearEyes.table[mood], !reduceMotion, let lids = BearEyes.lids(mood), let face = PokiMood.cutout(mood, small: true) {
                Image(uiImage: lids).resizable().interpolation(.high)
                ForEach(eyes.indices, id: \.self) { i in
                    let eye = eyes[i]
                    Image(uiImage: face).resizable().interpolation(.high)
                        .frame(width: side, height: side)
                        .mask(alignment: .topLeading) {
                            Ellipse().frame(width: eye.width * side, height: eye.height * side)
                                .offset(x: eye.minX * side, y: eye.minY * side)
                        }
                        // The lids close toward the lower part of the eye, as the sleeping face's do.
                        .modifier(EyeShut(shut: shut, anchor: UnitPoint(x: eye.midX, y: eye.minY + eye.height * 0.62)))
                }
            } else if let face = PokiMood.cutout(mood, small: true) {
                Image(uiImage: face).resizable().interpolation(.high)
            }
        }
        .frame(width: side, height: side)
        // A new face is just there: no animation around it may fade it in late.
        .animation(nil, value: mood)
        .keyframeAnimator(initialValue: 1.0, trigger: hop) { content, scale in
            content.scaleEffect(scale, anchor: .bottom)
        } keyframes: { _ in
            CubicKeyframe(0.9, duration: 0.09)
            SpringKeyframe(1.0, duration: 0.4, spring: .bouncy(duration: 0.4, extraBounce: 0.2))
        }
        .onChange(of: mood) { if !reduceMotion { hop += 1 } }
        .task(id: reduceMotion || covered) { await blink() }
        .accessibilityHidden(true)
    }

    /// Blinks until the view goes or the drawer opens over it: every 2.5 to 5.5 seconds, one time in
    /// four twice in a row.
    private func blink() async {
        guard !reduceMotion, !covered else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.5...5.5)))
            for _ in 0..<(Int.random(in: 0..<4) == 0 ? 2 : 1) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.07)) { shut = 1 }
                try? await Task.sleep(for: .milliseconds(90))
                withAnimation(.easeOut(duration: 0.13)) { shut = 0 }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}

/// One eye closing: squeezed toward its anchor, and over the last few frames darkened to the brown
/// of the sleeping face's line, so the shut eye is a brown line, not a white sliver with the pupil in it.
/// Animatable, so the colour follows each frame of the blink.
private struct EyeShut: ViewModifier, Animatable {
    var shut: Double
    var anchor: UnitPoint
    var animatableData: Double {
        get { shut }
        set { shut = newValue }
    }

    func body(content: Content) -> some View {
        // The pupils' and the sleeping line's brown: rgb(65, 34, 25).
        let dark = max(0, (shut - 0.85) / 0.15)
        content
            .colorMultiply(Color(red: 1 - 0.745 * dark, green: 1 - 0.867 * dark, blue: 1 - 0.902 * dark))
            .scaleEffect(x: 1, y: 1 - 0.92 * shut, anchor: anchor)
    }
}

/// Where the eyes are on each face with open eyes, as fractions of the cutout's side (the rectangle of
/// the ellipse that holds each eye's white and pupil), and the pictures with them filled. The table is
/// printed by scripts/make-bear-blink.py.
enum BearEyes {
    static func lids(_ mood: PokiMood) -> UIImage? { UIImage(named: "PokiBearLids-\(mood.rawValue)") }

    static let table: [PokiMood: [CGRect]] = [
        .hello: [CGRect(x: 0.1562, y: 0.3555, width: 0.2734, height: 0.2852), CGRect(x: 0.4648, y: 0.3281, width: 0.2617, height: 0.2852)],
        .ready: [CGRect(x: 0.1875, y: 0.3398, width: 0.2852, height: 0.3008), CGRect(x: 0.5195, y: 0.3438, width: 0.2812, height: 0.3047)],
        .thinking: [CGRect(x: 0.2031, y: 0.2734, width: 0.2734, height: 0.2852), CGRect(x: 0.5195, y: 0.3672, width: 0.2656, height: 0.2773)],
        .onYourPhone: [CGRect(x: 0.2031, y: 0.3398, width: 0.2695, height: 0.2852), CGRect(x: 0.5195, y: 0.3672, width: 0.2578, height: 0.2891)],
        .checking: [CGRect(x: 0.1953, y: 0.3438, width: 0.3086, height: 0.3242), CGRect(x: 0.5273, y: 0.4180, width: 0.2539, height: 0.2852)],
        .needsYou: [CGRect(x: 0.1641, y: 0.3750, width: 0.2578, height: 0.2734), CGRect(x: 0.4609, y: 0.3828, width: 0.2461, height: 0.2695)],
        .tripped: [CGRect(x: 0.2227, y: 0.4023, width: 0.2695, height: 0.2695), CGRect(x: 0.5078, y: 0.4336, width: 0.2422, height: 0.2539)],
        .cantReach: [CGRect(x: 0.2383, y: 0.4453, width: 0.2695, height: 0.2461), CGRect(x: 0.5078, y: 0.3945, width: 0.2500, height: 0.2539)],
        .listening: [CGRect(x: 0.1562, y: 0.3086, width: 0.2539, height: 0.2539), CGRect(x: 0.4258, y: 0.3828, width: 0.2500, height: 0.2656)],
        .speaking: [CGRect(x: 0.1758, y: 0.3281, width: 0.2812, height: 0.2930), CGRect(x: 0.4883, y: 0.3398, width: 0.2578, height: 0.2852)],
    ]
}
