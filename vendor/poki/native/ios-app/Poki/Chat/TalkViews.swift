import SwiftUI
import UIKit

// Speaking to Poki from the message field. The empty field's main button starts a talk with Poki at
// once (the owner, 2026-11-13: one tap, no menu); dictation has its own microphone beside it. The talk
// goes on in the chat with the field as its bar (pull request #250's interaction), and Talk with Poki
// without a voice key says so in the field's place, with a button to the key's form in Settings. The
// old Voice page no longer opens from anywhere a person can reach. The code and the look are this app's:
// glass, Poki's blue and its brand band, the system's type. The bars in the talk's mark are LiveKit's
// (TalkBars.swift) and the light along the bottom edge is Jacob Mobin's (TalkEdgeGlow.swift).

/// In the message field's place, on its glass: Talk with Poki was asked for with no OpenAI key and no
/// voice bridge. It says what is missing and goes straight to the OpenAI key's form in Settings. With
/// the key there but Live Voice turned off, it says that and goes to Live Voice.
struct VoiceKeyNotice: View {
    var addKey: () -> Void
    var close: () -> Void

    var body: some View {
        let off = ModelKeys.hasKey(.openai) && !VoiceDirect.enabled
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(BrandBand.diagonal, in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(off ? LocalizedStringKey("Live Voice Is Off") : LocalizedStringKey("No Voice Key Set Up")).font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                    Text(off ? LocalizedStringKey("Talk with Poki uses Live Voice on your OpenAI account. Turn it on in Settings. Dictate works without it.")
                             : LocalizedStringKey("Talk with Poki needs an OpenAI API key. Add one in Settings. Dictate works without it."))
                        .font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("composer.speak.needs-key")
            }
            // Side by side at the trailing edge; one above the other when large text leaves no room.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { Spacer(minLength: 0); later; add(off) }
                VStack(spacing: 8) { add(off).frame(maxWidth: .infinity); later.frame(maxWidth: .infinity) }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var later: some View {
        Button(action: close) {
            Text("Not Now").font(.body.weight(.semibold)).foregroundStyle(Color(.label)).lineLimit(1)
                .padding(.horizontal, 18).frame(minHeight: 44)
                .background(Color(.label).opacity(0.1), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.speak.later")
    }

    private func add(_ off: Bool) -> some View {
        Button(action: addKey) {
            Text(off ? LocalizedStringKey("Open Settings") : LocalizedStringKey("Add Key")).font(.body.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 18).frame(minHeight: 44)
                .background(Tint.blue, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.speak.add-key")
    }
}

/// The message field while you talk with Poki: what the talk is doing and for how long, a way to stop
/// Poki's answer while it speaks, Poki's voice on or off, and End. End here and End on the Live Activity
/// end the same talk. A talk that ended by itself says why here, with Try Again and Close.
///
/// It draws a `TalkState` and nothing else, so each state can be put on screen by itself.
struct TalkBar: View {
    var state: TalkState
    var since: Date?
    var muted: Bool
    var toggleMute: () -> Void
    var interrupt: () -> Void
    var end: () -> Void
    var retry: () -> Void
    var dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    var controlSize = CompactControlMetrics(base: 44, maximum: 52)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row
            // What went wrong, in full, under the row: a system's reason can run to several lines.
            if let reason = state.reason {
                Text(verbatim: reason).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.bottom, 4)
                    .accessibilityIdentifier("composer.talk.reason")
                    .transition(.opacity)
            }
        }
        .frame(minHeight: 48)
        .animation(TalkMotion.state, value: state)
        // A tap you feel where the talk turns: it starts to listen, it is cut off, it breaks.
        .sensoryFeedback(trigger: state) { old, new -> SensoryFeedback? in
            switch new {
            case .interrupted: return .impact(weight: .medium)
            case .failed: return .error
            case .listening where old == .connecting: return .start
            default: return nil
            }
        }
    }

    private var row: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            HStack(spacing: 10) {
                TalkOrb(state: state).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: state.word).font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                        .fixedSize(horizontal: false, vertical: true).contentTransition(.interpolate)
                    if let since, !state.isFailed {
                        Text(since, style: .timer).font(.footnote).monospacedDigit().foregroundStyle(Color(.secondaryLabel))
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { controls }
                VStack(alignment: .leading, spacing: 8) { controls }
            }
            .layoutPriority(1)
        }
    }

    @ViewBuilder private var controls: some View {
        if state.isFailed {
            round("xmark", label: "Close", identifier: "composer.talk.close", action: dismiss)
            capsule("Try Again", fill: Tint.blue, ink: .white, identifier: "composer.talk.retry", action: retry)
        } else {
            if state == .speaking {
                round("hand.raised.fill", label: "Interrupt", identifier: "composer.talk.interrupt", action: interrupt)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            round(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: muted ? "Unmute Poki’s Voice" : "Mute Poki’s Voice",
                  identifier: "composer.talk.mute", action: toggleMute)
            // The send button's blue, in light and dark (the owner, 2026-11-13: not white on black).
            capsule("End", fill: Tint.blue, ink: .white, identifier: "composer.talk.end", action: end)
                .accessibilityLabel(Text("End Talk"))
        }
    }

    private func round(_ symbol: String, label: LocalizedStringKey, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium)).foregroundStyle(Color(.label))
                .contentTransition(.symbolEffect(.replace))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(width: controlSize.side, height: controlSize.side)
                .background(Color(.label).opacity(scheme == .dark ? 0.16 : 0.1), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: symbol)
        }
    }

    private func capsule(_ title: LocalizedStringKey, fill: Color, ink: Color, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold)).foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).padding(.vertical, 10).frame(minHeight: 48)
                .background(fill, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// The talk's mark at the head of its bar: the brand band in a circle, and in it the bars for what the
/// talk is doing (`TalkBars`), a phone while a step runs on it, or an exclamation mark for a problem.
/// It dips when the talk is interrupted.
struct TalkOrb: View {
    var state: TalkState

    var body: some View {
        ZStack {
            switch state {
            case .acting:
                Image(systemName: "iphone").font(.title3.weight(.semibold))
                    .symbolEffect(.pulse, options: .repeating)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            case .failed:
                Image(systemName: "exclamationmark").font(.title3.weight(.bold))
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            default:
                TalkBars(mode: bars, barColor: .white, barSpacingFactor: 0.09, barMinOpacity: 0.4, loudness: state == .hearing ? 0.7 : 1)
                    .frame(width: 26, height: 22)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 48, height: 48)
        .background {
            if state.isFailed { Circle().fill(Tint.red) } else { Circle().fill(BrandBand.diagonal) }
        }
        .scaleEffect(state == .interrupted ? 0.86 : 1)
        .animation(TalkMotion.dip, value: state == .interrupted)
        .accessibilityHidden(true)
    }

    private var bars: TalkBars.Mode {
        switch state {
        case .connecting: .initializing
        case .listening: .listening
        case .thinking, .acting: .thinking
        case .hearing, .speaking: .speaking
        case .interrupted, .failed: .quiet
        }
    }
}

/// How a talk's screens move.
enum TalkMotion {
    /// From one state to the next: the word, the buttons that come and go, the mark.
    static let state = Animation.snappy(duration: 0.28)
    /// The mark's dip when the talk is interrupted, and its way back.
    static let dip = Animation.spring(duration: 0.32, bounce: 0.45)
    /// The message field turning into the talk's bar and back.
    static let enter = Animation.smooth(duration: 0.36)
    /// The light along the bottom edge following the talk.
    static let glow = Animation.easeInOut(duration: 0.5)
}

extension TalkState {
    /// How much of the light along the bottom edge shows: most while Poki speaks, least when it was
    /// cut off, none for a talk that broke.
    var glow: Double {
        switch self {
        case .connecting: 0.35
        case .listening: 0.6
        case .hearing: 0.85
        case .thinking: 0.55
        case .acting: 0.5
        case .speaking: 1
        case .interrupted: 0.25
        case .failed: 0
        }
    }
}

/// The brand band in the app: the Live Activity card's blues (BrandBand.colours), corner to corner.
extension BrandBand {
    static var diagonal: LinearGradient {
        LinearGradient(colors: colours, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
