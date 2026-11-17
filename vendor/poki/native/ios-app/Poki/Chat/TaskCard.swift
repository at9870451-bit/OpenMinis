import SwiftUI
import UIKit

// The task card, the approval card and the "Your turn" card (ESP-326 boards "31 Task card: every state",
// "03 Chat: Back in Poki mid-task", "04 Chat: Needs you", "05 Chat: Your turn"). Sizes, radii and
// spacing are the prototype's (原型/src/chat.tsx), type through the system's text styles. They take
// plain values, so the chat, an outside agent's session and the screenshots' sample scenes draw the
// same thing.

/// How a task's card reads: Poki has the phone (blue), it waits for you (amber), or it is over.
enum TaskCardState: Equatable {
    case running, needsYou, yourTurn, done, failed, stopped

    /// From a plan's steps: `live` is the task under way; `waiting` and `handedOver` are what holds it.
    init(steps: [PlanStep], live: Bool, waiting: Bool, handedOver: Bool) {
        if live {
            if handedOver { self = .yourTurn }
            else if waiting || steps.contains(where: { $0.state == .waiting }) { self = .needsYou }
            else { self = .running }
        } else if steps.contains(where: { $0.state == .failed }) { self = .failed }
        else if steps.allSatisfy({ $0.state == .done }) { self = .done }
        else { self = .stopped }
    }
}

/// How the card's marks read: on the blue card, amber while the task waits for you, plain once it is over.
private enum TaskTone { case blue, amber, plain }

/// One task's steps. While Poki has the phone it is the blue card: the only large blue block in the
/// chat, with what Poki sees of the screen beside the steps. The moment it stops to wait for you the
/// card goes back to plain and its marks turn amber; over, it folds to one row that opens on a tap.
struct TaskCard: View {
    var title: String
    var steps: [PlanStep]
    var state: TaskCardState
    /// The steps still to come, when the model published its whole plan.
    var upcoming: [String] = []
    /// The number of steps is known (the model published its plan): "Step 2 of 4" and the bar. Without
    /// it the card counts the steps so far and promises no total.
    var planned = true
    /// The outside agent that asked; nil when you did.
    var asker: String? = nil
    var app: String? = nil
    var usedBrowser = false
    var started: Date
    /// What the core last saw of the screen, for the task under way. Never stored with the conversation.
    var shot: Image? = nil
    /// When the task ended and how many steps its plan had, where the conversation kept them: the
    /// second line then says how long it took and out of how many steps it stopped.
    var ended: Date? = nil
    var plannedTotal: Int? = nil
    /// Nil until you fold or unfold it. A task that tripped starts unfolded, so the step it tripped on
    /// shows; so does one handed back to you. One waiting for your answer folds: the approval card speaks.
    @State private var open: Bool?
    @ScaledMetric(relativeTo: .footnote) private var endingSide = 20.0
    @ScaledMetric(relativeTo: .subheadline) private var cardInset = 12.0
    @Environment(\.dynamicTypeSize) private var typeSize

    private var total: Int { steps.count + upcoming.count }
    private var finished: Int { steps.filter { $0.state == .done }.count }
    private var blue: Bool { state == .running }
    private var waits: Bool { state == .needsYou || state == .yourTurn }
    private var tone: TaskTone { blue ? .blue : waits ? .amber : .plain }
    private var big: Bool { typeSize.isAccessibilitySize }
    private var isOpen: Bool { blue || (open ?? (state == .failed || state == .yourTurn)) }
    private var ink: Color { blue ? .white : Color(.label) }
    private var soft: Color { blue ? .white.opacity(0.74) : Color(.secondaryLabel) }
    /// Over: the result card (board 定稿 07), the app's icon, what was done, where and how long, and a
    /// mark for how it ended.
    private var over: Bool { state == .done || state == .failed || state == .stopped }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: over ? 20 : 26, style: .continuous)
        Group {
            if over {
                VStack(alignment: .leading, spacing: 0) {
                    // A tap on the row shows the steps; there is no chevron on the board.
                    Button { withAnimation(.snappy) { open = !isOpen } } label: { header.contentShape(.rect) }
                        .buttonStyle(.plain)
                        .accessibilityValue(Text(isOpen ? "Expanded" : "Collapsed"))
                        .accessibilityHint(Text(isOpen ? "Hides the steps" : "Shows the steps"))
                    if isOpen {
                        VStack(alignment: .leading, spacing: 14) { details }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 14)
                            .transition(.opacity)
                    }
                }
                .padding(.vertical, min(18, cardInset)).padding(.horizontal, min(20, cardInset + 2))
            } else if blue {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    details
                }
                .padding(16)
                .accessibilityElement(children: .combine)
            } else {
                DisclosureGroup(isExpanded: Binding(get: { isOpen }, set: { open = $0 })) {
                    VStack(alignment: .leading, spacing: 14) { details }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 14)
                } label: {
                    header
                }
                .tint(Color(.tertiaryLabel))
                .padding(.vertical, min(20, cardInset + (isOpen ? 4 : 0)))
                .padding(.leading, min(20, cardInset + (isOpen ? 4 : 0)))
                .padding(.trailing, min(20, cardInset + (isOpen ? 4 : 2)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(blue ? Tint.blue : Color(.secondarySystemGroupedBackground), in: shape)
        // Under the blue: a soft shadow in light; in dark it would read as a glow, so a hairline instead.
        .overlay(shape.strokeBorder(blue ? Tint.ring : waits ? Tint.amberLine : Tint.line, lineWidth: 1))
        .shadow(color: blue ? Tint.blueShadow : .clear, radius: 9, y: 6)
    }

    // MARK: The row every state has

    private var header: some View {
        HStack(spacing: over ? 12 : 10) {
            mark
            VStack(alignment: .leading, spacing: over ? 2 : 1) {
                Text(verbatim: title).font(.subheadline.weight(.semibold)).foregroundStyle(ink).lineLimit(big ? nil : 1)
                subline.font(over ? .footnote : .caption).foregroundStyle(soft).lineLimit(big ? nil : 1)
                // At the accessibility text sizes the title wraps and the label goes under it.
                if big, !over || asker != nil { pill }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 6)
            if !big, !over || asker != nil { pill }
            if over { ending }
        }
    }

    /// How a task ended, at the end of its result row: a green tick, a red cross or a grey stop.
    @ViewBuilder private var ending: some View {
        switch state {
        case .done: endMark("checkmark", Tint.green).accessibilityLabel(Text("Done"))
        case .failed: endMark("xmark", Tint.red).accessibilityLabel(Text("Failed"))
        default: endMark("stop.fill", Color(.systemGray), size: 7).accessibilityLabel(Text("Stopped"))
        }
    }

    private func endMark(_ name: String, _ color: Color, size: CGFloat = 9) -> some View {
        Image(systemName: name).font(.system(size: size * min(32, endingSide) / 20, weight: .heavy)).foregroundStyle(.white)
            .frame(width: min(32, endingSide), height: min(32, endingSide)).background(color, in: .circle)
    }

    /// Poki's face while the task is alive; a tick, a cross or a stop sign once it is over.
    @ViewBuilder private var mark: some View {
        switch state {
        case .running:
            // On the blue card the face needs no edge: its own blue is the card's.
            PokiBear(mood: .onYourPhone, small: true).frame(width: 34, height: 34)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
        case .needsYou: PokiAvatar(size: 34, mood: .needsYou)
        case .yourTurn: PokiAvatar(size: 34, mood: .yourTurn)
        case .done, .failed, .stopped:
            if let app, !app.isEmpty {
                AppIconView(app: app, size: 32)
            } else if usedBrowser {
                BrowserIcon()
            } else {
                BearAvatar(size: 32)
            }
        }
    }

    /// "Messages, 0:42" while the card is open and alive; where it is or how it ended otherwise.
    @ViewBuilder private var subline: some View {
        let app = AppName.display(self.app)
        let at = min(finished + 1, max(total, 1))
        switch state {
        case .done:
            if let ended {
                let took = Duration.seconds(max(0, ended.timeIntervalSince(started).rounded())).formatted(.time(pattern: .minuteSecond))
                if let app, !app.isEmpty { Text("\(app), done in \(took)") } else { Text("Done in \(took)") }
            } else if let app, !app.isEmpty {
                Text(verbatim: app)
            } else {
                Text("Done")
            }
        // The result card counts no steps (the owner, board 定稿 07): where it was and how it ended.
        case .failed:
            if let app, !app.isEmpty { Text("\(app), didn’t finish") } else { Text("Didn’t finish") }
        case .stopped:
            if let app, !app.isEmpty { Text("\(app), stopped") } else { Text("Stopped") }
        case .running, .needsYou, .yourTurn:
            if isOpen {
                HStack(spacing: 0) {
                    if let app, !app.isEmpty { Text("\(app), ") }
                    Text(started, style: .timer).monospacedDigit()
                }
            } else if planned, total > 1 {
                if let app, !app.isEmpty { Text("\(app), step \(at) of \(total)") } else { Text("Step \(at) of \(total)") }
            } else {
                Text("Step \(at)")
            }
        }
    }

    /// Who asked, or folded and waiting, what it waits for.
    @ViewBuilder private var pill: some View {
        if waits, !isOpen {
            TaskPill(text: Text(state == .yourTurn ? "Your turn" : "Needs you"), ink: Tint.amberInk, ground: Tint.amberSoft)
        } else {
            TaskPill(text: asker.map { Text(verbatim: $0) } ?? Text("You"),
                     ink: blue ? .white : Color(.secondaryLabel), ground: blue ? .white.opacity(0.18) : Color(.tertiarySystemFill))
        }
    }

    // MARK: The steps, what Poki sees, and how far it is

    @ViewBuilder private var details: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(steps) { step in
                    TaskStepRow(text: step.text, state: step.state, tone: tone).transition(PlanMotion.stepTransition)
                }
                ForEach(Array(upcoming.enumerated()), id: \.offset) { _, text in
                    TaskStepRow(text: text, state: nil, tone: tone)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(PlanMotion.enter, value: steps)
            // The picture gives its column to the words at the accessibility text sizes.
            if !big {
                if state == .yourTurn {
                    ShotWithheld()
                } else if blue || state == .needsYou, let shot {
                    TaskShot(image: shot, onBlue: blue)
                }
            }
        }
        if blue || waits, planned, total > 1 {
            HStack(spacing: 10) {
                ProgressView(value: Double(finished), total: Double(total))
                    .progressViewStyle(TaskBarStyle(track: blue ? .white.opacity(0.28) : Color(.tertiarySystemFill), fill: blue ? .white : Tint.amber))
                    .animation(.easeInOut(duration: 0.4), value: finished)
                Text("Step \(min(finished + 1, total)) of \(total)").font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(soft)
            }
        }
        if state == .yourTurn {
            // What holds while a step is yours: the core sends no input. It still reads the screen (that
            // is how it sees the step is over), so the card does not say it looks away.
            Text("Handed back to you. I’ll carry on when you’re done.")
                .font(.footnote.weight(.medium)).foregroundStyle(Tint.amberInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The small label on a task's row: who asked, or what it waits for.
private struct TaskPill: View {
    var text: Text
    var ink: Color
    var ground: Color
    var body: some View {
        text.font(.caption.weight(.medium)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).frame(minHeight: 24)
            .background(ground, in: .capsule)
    }
}

/// What Poki last saw of the screen, at the screen's own proportions: the core's small picture of its
/// latest look (96 pixels wide, the Live Activity's), so it is soft, and enough to tell which screen it is.
private struct TaskShot: View {
    var image: Image
    var onBlue: Bool
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        image.resizable().interpolation(.high).scaledToFit()
            .frame(width: 52).frame(maxHeight: 124)
            .clipShape(shape)
            .overlay(shape.strokeBorder(onBlue ? Color.white.opacity(0.55) : Tint.line, lineWidth: onBlue ? 2 : 1))
            .accessibilityLabel(Text("Latest screenshot"))
    }
}

/// In the picture's place while a step is yours: that screen is likely a passcode or a payment, so the
/// card does not show it.
private struct ShotWithheld: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(spacing: 6) {
            Image(systemName: "lock").font(.system(size: 16, weight: .medium))
            Text("Not shown").font(.caption2.weight(.medium)).multilineTextAlignment(.center)
        }
        .foregroundStyle(Color(.tertiaryLabel))
        .frame(width: 52, height: 112)
        .background(Color(.tertiarySystemFill), in: shape)
        .overlay(shape.strokeBorder(Tint.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// The task's bar: 4 points high, the board's colours (white on the blue card, amber while it waits).
private struct TaskBarStyle: ProgressViewStyle {
    var track: Color
    var fill: Color
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
            }
        }
        .frame(height: 4)
    }
}

/// One step of a task: a tick when done, a cross when it failed, a ring with a dot while under way, and
/// a dimmer ring for a step still to come (`state` nil).
private struct TaskStepRow: View {
    var text: String
    var state: PlanStep.State?
    var tone: TaskTone
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 18

    private var now: Bool { state == .current || state == .waiting }
    private var ink: Color { tone == .blue ? .white : Color(.label) }
    private var soft: Color { tone == .blue ? .white.opacity(0.74) : Color(.secondaryLabel) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            mark
                .frame(width: side, height: side)
                // The mark sits on the first line's middle, whatever the text size.
                .alignmentGuide(.firstTextBaseline) { $0.height * 0.8 }
                .animation(PlanMotion.swap, value: state)
            Text(Self.words(ActivityWords.label(text)))
                .font(now ? .subheadline.weight(.medium) : .subheadline)
                .foregroundStyle(state == .failed ? Tint.red : now ? ink : soft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ActivityWords.label(text)))
        .accessibilityValue(spoken)
    }

    @ViewBuilder private var mark: some View {
        switch state {
        case .done?:
            Circle().fill(tone == .blue ? Color.white.opacity(0.22) : Tint.greenSoft)
                .overlay {
                    DrawingCheck(color: tone == .blue ? .white : Tint.green, lineWidth: side / 12)
                        .frame(width: side * 0.6, height: side * 0.6)
                }
                .transition(PlanMotion.swapTransition)
        case .failed?:
            Circle().fill(Tint.redSoft)
                .overlay { Image(systemName: "xmark").font(.system(size: side * 0.5, weight: .bold)).foregroundStyle(Tint.red) }
        case .current?, .waiting?:
            let color = tone == .blue ? Color.white : tone == .amber ? Tint.amber : Color(.label)
            Circle().strokeBorder(color, lineWidth: side / 9)
                .overlay { Circle().fill(color).frame(width: side * 4 / 9, height: side * 4 / 9) }
                .transition(PlanMotion.swapTransition)
        case nil:
            Circle().strokeBorder(tone == .blue ? Color.white.opacity(0.4) : Color(.systemGray4), lineWidth: side / 9)
        }
    }

    /// The marks are shapes, so VoiceOver is told what they show.
    private var spoken: Text {
        switch state {
        case .done?: Text("Done")
        case .failed?: Text("Failed")
        case .current?, .waiting?: Text("In progress")
        case nil: Text("Upcoming")
        }
    }

    /// What Poki types or taps stands out: the words between curly quotes are set stronger, as on the board.
    static func words(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        var from = out.startIndex
        while from < out.endIndex, let opening = out[from...].range(of: "“"), let closing = out[opening.upperBound...].range(of: "”") {
            out[opening.lowerBound..<closing.upperBound].inlinePresentationIntent = .stronglyEmphasized
            from = closing.upperBound
        }
        return out
    }
}

// MARK: Approval

/// A step waiting for your answer, above the message field: what is asked, where, the words or the
/// button it is about, how long it waits, and the two answers. Allow takes a hold, so a stray tap
/// never lets a step through, and so does Don’t ask again, which allows the step too.
/// An approval, as one question from the rules' kind ("Allow payment?"), its countdown and the answers.
struct ApprovalAskCard: View {
    var title: String
    var expires: Date?
    var answer: (Bool) -> Void
    /// Allows this step and turns asking off. Nil on a step turning asking off does not reach.
    var stopAsking: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Side by side with Allow the wider, or one above the other at the accessibility text sizes,
        // as an alert's buttons.
        let answers = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(AnswerRow())
        VStack(alignment: .leading, spacing: 14) {
            // At the accessibility sizes the question has the card's whole width under the bear and the
            // countdown, so a word is never broken in the middle ("Allow pay-ment?").
            if typeSize.isAccessibilitySize {
                HStack(alignment: .center, spacing: 12) {
                    PokiAvatar(size: 48, mood: .needsYou)
                    Spacer(minLength: 0)
                    countdown
                }
                question
            } else {
                HStack(alignment: .center, spacing: 12) {
                    PokiAvatar(size: 48, mood: .needsYou)
                    question
                    countdown
                }
            }
            answers {
                Button { answer(false) } label: {
                    Text("Don’t Allow").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(QuietCapsuleButtonStyle())
                HoldToAllowButton { answer(true) }
            }
            if let stopAsking {
                // Allows this step and turns every approval off, so like Allow it takes a hold.
                HoldToAllowButton(title: "Don’t ask again", quiet: true, action: stopAsking)
            }
        }
        .padding(18)
        // It floats over the conversation and asks for an answer: the control layer, so glass.
        .glassSurface(in: RoundedRectangle(cornerRadius: 30, style: .continuous), fallback: .card)
    }

    private var question: some View {
        Text(verbatim: title).font(.headline).foregroundStyle(Color(.label)).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The countdown keeps its own width, so the question does not jump each second.
    @ViewBuilder private var countdown: some View {
        if let expires, expires > Date() {
            Text(timerInterval: Date()...expires, countsDown: true)
                .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(Tint.amberInk)
                .multilineTextAlignment(.trailing)
                .fixedSize()
                .padding(.horizontal, 10).frame(minHeight: 24)
                .background(Tint.amberSoft, in: .capsule)
                .accessibilityLabel(Text("Time left"))
        }
    }
}

/// The two answers side by side, the second 1.35 times the first: the board's Don’t Allow and Hold to Allow.
private struct AnswerRow: Layout {
    var spacing: CGFloat = 8
    var weights: [CGFloat] = [1, 1.35]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let heights = zip(subviews, widths(width)).map { subview, width in
            subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func widths(_ total: CGFloat) -> [CGFloat] {
        let free = max(0, total - spacing * CGFloat(weights.count - 1))
        let sum = weights.reduce(0, +)
        return weights.map { free * $0 / sum }
    }
}

/// Touch and hold: the button fills from the leading edge and allows when it is full. VoiceOver and
/// Switch Control activate it directly, as they can't hold. `quiet` is Don’t ask again: the same hold
/// as plain text under the two answers, which allows this step and turns approvals off.
struct HoldToAllowButton: View {
    var title: LocalizedStringKey = "Hold to Allow"
    var quiet = false
    var action: () -> Void
    @State private var filled: CGFloat = 0
    @State private var pressing = false
    @State private var allowed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Long enough to be meant, short enough not to drag.
    static let hold: Double = 0.7

    var body: some View {
        Text(title)
            .font(.subheadline.weight(quiet ? .medium : .semibold)).foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tint.onSolid))
            .frame(maxWidth: .infinity, minHeight: quiet ? 36 : 50)
            .background {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        if !quiet { Tint.solid }
                        (quiet ? Color.primary.opacity(0.14) : Tint.onSolid.opacity(0.32)).frame(width: geometry.size.width * filled)
                    }
                }
                .clipShape(.capsule)
            }
            .contentShape(.capsule)
            .scaleEffect(pressing && !reduceMotion ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: pressing)
            .onLongPressGesture(minimumDuration: Self.hold, maximumDistance: 44) {
                allowed += 1
                action()
            } onPressingChanged: { down in
                pressing = down
                withAnimation(down ? .linear(duration: Self.hold) : .easeOut(duration: 0.2)) { filled = down ? 1 : 0 }
            }
            .sensoryFeedback(.success, trigger: allowed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressing) { _, down in down }
            .accessibilityElement()
            .accessibilityLabel(quiet ? Text(title) : Text("Allow"))
            .accessibilityHint(quiet ? Text("Allows this step and turns approvals off.") : Text("Allows this step"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .accessibilityIdentifier(quiet ? "approval.stopAsking" : "approval.allow")
    }
}

// MARK: Your turn

/// Poki handed the phone back for something only you can do (a passcode, a password, Face ID): what
/// it asks, that it sends no input meanwhile, and the button that tells it to carry on. Amber is your
/// turn, so the whole card is.
struct TurnCard: View {
    var text: String
    var done: () -> Void

    /// `text` with a full stop if it ends on a letter or a digit (a full-width one after Chinese).
    static func sentence(_ text: String) -> String {
        guard let last = text.unicodeScalars.last, CharacterSet.alphanumerics.contains(last) else { return text }
        return text + (last.value >= 0x2E80 ? "。" : ".")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                PokiAvatar(size: 48, mood: .yourTurn)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "lock").font(.subheadline.weight(.semibold)).accessibilityHidden(true)
                        Text("Your turn").font(.headline)
                    }
                    // The reason comes as a phrase with no stop; a sentence follows it.
                    Text(verbatim: Self.sentence(text)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    // What the core keeps to while a step is handed over: no input is sent. It still reads
                    // the screen (that is how it sees the step is over), so the card does not say it looks away.
                    Text("I’m not tapping or typing while it’s your turn.").font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Tint.amberInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: done) { Text("Continue") }
                .buttonStyle(SolidCapsuleButtonStyle())
                .accessibilityIdentifier("handoff.done")
        }
        .padding(18)
        // A card over the conversation, like the approval: glass, tinted amber so it reads as yours.
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous), tint: Tint.amberSoft, fallback: .card)
    }
}

// MARK: Buttons and surfaces

/// Your own solid button: ink in light, white in dark. Blue stays Poki's.
struct SolidCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold)).foregroundStyle(Tint.onSolid)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Tint.solid, in: .capsule)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// The quiet answer beside a solid one: a grey capsule.
struct QuietCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(.label))
            .background(Color(.tertiarySystemFill), in: .capsule)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A drawn stand-in for the phone's screen in the sample scenes and the demo, which have no phone
/// behind them: a chat with a few bubbles, in the board's own colours for its thumbnails.
enum SampleShot {
    private static let light = draw(dark: false)
    private static let dark = draw(dark: true)

    static func image(dark: Bool) -> Image { Image(uiImage: dark ? Self.dark : light) }

    private static func draw(dark: Bool) -> UIImage {
        let size = CGSize(width: 180, height: 390)
        let line = UIColor(hex: dark ? 0x25282D : 0xEEF0F2), strong = UIColor(hex: dark ? 0x34383E : 0xDDE1E5)
        let mine = UIColor(hex: dark ? 0x1F5A3A : 0xCFEFD9)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(hex: dark ? 0x111315 : 0xFFFFFF).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            func pill(_ rect: CGRect, _ colour: UIColor) {
                colour.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: min(rect.height / 2, 14)).fill()
            }
            // The title and its line, bubbles from both sides, the field with its send button.
            pill(CGRect(x: 14, y: 26, width: 22, height: 22), strong)
            pill(CGRect(x: 44, y: 32, width: 64, height: 10), strong)
            line.setFill()
            UIRectFill(CGRect(x: 0, y: 60, width: size.width, height: 1))
            pill(CGRect(x: 14, y: 84, width: 96, height: 30), line)
            pill(CGRect(x: 14, y: 120, width: 70, height: 30), line)
            pill(CGRect(x: 62, y: 170, width: 104, height: 30), mine)
            pill(CGRect(x: 14, y: 220, width: 84, height: 30), line)
            pill(CGRect(x: 50, y: 270, width: 116, height: 44), mine)
            pill(CGRect(x: 14, y: 340, width: 122, height: 30), line)
            pill(CGRect(x: 142, y: 342, width: 26, height: 26), UIColor(hex: 0x1FB86A))
        }
    }
}
