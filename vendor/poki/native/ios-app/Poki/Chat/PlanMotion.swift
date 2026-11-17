// The plan bubble's motion, translated to SwiftUI from four Motion+ examples (Motion for React, read
// through the motion-plus MCP on 2026-11-07), with their parameters unchanged:
// - motion://examples/react/notifications-list: a new step enters from opacity 0, y +14, scaleX 0.8
//   (origin centre bottom) with a spring of stiffness 200, damping 18; the others move aside with the
//   same spring (`layout`). Exit: opacity 0, y +10, scaleX 0.9 in 0.2 s, ease (0.215, 0.61, 0.355, 1).
// - motion://examples/react/copy-button: the tick draws itself (pathLength 0 to 1) with a spring of
//   stiffness 300, damping 25, after 0.1 s; the icon swaps with opacity and a 4 pt blur on a spring of
//   stiffness 260, damping 18, the label 0.2 s after the icon (staggerChildren).
// - motion://examples/react/todo-list: a finished item's text changes over 0.4 s (Motion's default
//   ease, easeInOut) and its box fills with the item's colour.
// - motion://examples/react/typewriter-change-content: the step under way types its new text, first
//   backspacing to the part both texts share, one character at a time at 0.2 of the typing interval,
//   with the cursor blinking every 0.5 s after it finishes. The cursor here is a round dot in the text.
// The typing pace is Poki's own: 75 ms a character, and 250 ms more after a comma or a full stop.
// Motion+ is Motion's paid library (motion.dev/plus); these are its examples' parameters in SwiftUI, not its code.
import SwiftUI

enum PlanMotion {
    /// notifications-list: `{ type: "spring", stiffness: 200, damping: 18 }` (mass 1).
    static let enter = Animation.interpolatingSpring(mass: 1, stiffness: 200, damping: 18)
    /// notifications-list exit: 0.2 s, cubic-bezier(0.215, 0.61, 0.355, 1).
    static let exit = Animation.timingCurve(0.215, 0.61, 0.355, 1, duration: 0.2)
    /// copy-button checkSpring `{ stiffness: 300, damping: 25 }`, delay 0.1.
    static let check = Animation.interpolatingSpring(mass: 1, stiffness: 300, damping: 25).delay(0.1)
    /// copy-button swapSpring `{ stiffness: 260, damping: 18 }`.
    static let swap = Animation.interpolatingSpring(mass: 1, stiffness: 260, damping: 18)
    /// copy-button staggerChildren 0.2: the label follows the icon.
    static let stagger: Double = 0.2
    /// todo-list: `{ duration: 0.4 }`, Motion's default ease (easeInOut, 0.42, 0, 0.58, 1).
    static let complete = Animation.easeInOut(duration: 0.4)

    /// A step joining the plan.
    static let stepTransition = AnyTransition.asymmetric(
        insertion: .modifier(active: StepEntry(opacity: 0, y: 14, scaleX: 0.8), identity: StepEntry(opacity: 1, y: 0, scaleX: 1)),
        removal: .modifier(active: StepEntry(opacity: 0, y: 10, scaleX: 0.9), identity: StepEntry(opacity: 1, y: 0, scaleX: 1)).animation(exit))

    /// The swapping icon and label: opacity with a 4 pt blur.
    static let swapTransition = AnyTransition.modifier(active: Blurred(opacity: 0, radius: 4), identity: Blurred(opacity: 1, radius: 0))
}

private struct StepEntry: ViewModifier {
    var opacity: Double
    var y: CGFloat
    var scaleX: CGFloat
    func body(content: Content) -> some View {
        content.opacity(opacity).scaleEffect(x: scaleX, y: 1, anchor: .bottom).offset(y: y)
    }
}

private struct Blurred: ViewModifier {
    var opacity: Double
    var radius: CGFloat
    func body(content: Content) -> some View { content.opacity(opacity).blur(radius: radius) }
}

/// The tick of copy-button's CheckIcon ("M4 12l5 5L20 6" in a 24 box), drawn by `progress`.
struct DrawnCheck: Shape {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var path = Path()
        path.move(to: CGPoint(x: 4 * s, y: 12 * s))
        path.addLine(to: CGPoint(x: 9 * s, y: 17 * s))
        path.addLine(to: CGPoint(x: 20 * s, y: 6 * s))
        return path.trimmedPath(from: 0, to: progress)
    }
}

/// A tick that draws itself when it appears.
struct DrawingCheck: View {
    var color: Color
    var lineWidth: CGFloat = 2.5
    @State private var drawn: CGFloat = 0
    var body: some View {
        DrawnCheck(progress: drawn)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .onAppear { withAnimation(PlanMotion.check) { drawn = 1 } }
            .accessibilityHidden(true)
    }
}

/// Types toward `text`, backspacing to the common start first when it changes, then blinks its cursor.
struct TypewriterText: View {
    var text: String
    var font: Font
    var color: Color
    @State private var shown = ""
    @State private var typing = false
    @State private var runner: Task<Void, Never>?

    /// One character, in milliseconds.
    static let interval: Double = 75
    /// The extra wait after a comma or a full stop, in milliseconds.
    static let pause: Double = 250
    /// A backspace takes this share of a character (the typewriter-change-content example).
    static let backspaceFactor: Double = 0.2
    /// The cursor's blink, in seconds (the example's).
    static let blink: Double = 0.5

    var body: some View {
        // The cursor is a round dot set in the text itself, so it follows the last word onto a new
        // line when the words wrap. It holds still while typing and blinks once done.
        TimelineView(.periodic(from: .now, by: Self.blink)) { context in
            let on = typing || Int(context.date.timeIntervalSinceReferenceDate / Self.blink) % 2 == 0
            Self.line(shown, font: font, color: color, dot: on)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
        .onAppear { shown = ""; type(to: text) }
        .onChange(of: text) { _, new in type(to: new) }
        .onDisappear { runner?.cancel() }
    }

    /// The words and the dot as one text. A hidden dot keeps its place, so the line does not shift.
    static func line(_ shown: String, font: Font, color: Color, dot: Bool) -> Text {
        let words = Text(verbatim: shown).font(font).foregroundStyle(color)
        let cursor = Text(verbatim: "\u{00A0}\u{25CF}").font(.system(size: 9)).baselineOffset(1.5).foregroundStyle(dot ? color : Color.clear)
        return words + cursor
    }

    private func type(to target: String) {
        runner?.cancel()
        typing = true
        runner = Task { @MainActor in
            while shown != target {
                let delay = Self.delay(full: target, current: shown)
                try? await Task.sleep(for: .milliseconds(Int(delay)))
                if Task.isCancelled { return }
                shown = Self.next(current: shown, target: target)
            }
            typing = false
        }
    }

    /// One step toward `target`: a backspace while the shown text is not a start of it, else the next character.
    static func next(current: String, target: String) -> String {
        if needsBackspace(current, target) { return String(current.dropLast()) }
        return String(target.prefix(current.count + 1))
    }

    static func needsBackspace(_ current: String, _ full: String) -> Bool {
        current.count > full.count || (!current.isEmpty && !full.hasPrefix(current))
    }

    /// How long before the next step, in milliseconds.
    static func delay(full: String, current: String) -> Double {
        if needsBackspace(current, full) { return interval * backspaceFactor }
        guard let last = current.last else { return interval }
        return ",.，。".contains(last) ? interval + pause : interval
    }
}
