import SwiftUI

/// The voice page (ESP-171 boards "V Voice ready", "V Voice listening", "V Voice working with Island"):
/// one big line in the middle and the hold button at the bottom, on Poki's blue. It runs on VoiceModel
/// and VoiceDirect (the Realtime voice conversation or on-device dictation): holding the button starts the
/// conversation and Poki hears you; letting go leaves the turn to the model, which knows when you stopped;
/// sliding up ends it.
struct VoicePage: View {
    @Environment(AppModel.self) private var model
    var back: (() -> Void)? = nil
    var openDetails: () -> Void
    /// Accounts and Models: voice needs a chat model to dictate, or an OpenAI key to talk live.
    var openModel: () -> Void
    var select: (RootPage) -> Void
    @State private var holding = false
    @State private var cancelling = false

    private var voice: VoiceModel { model.voice }

    enum Face { case ready, listening, working }

    var body: some View {
        let face = Self.sample ?? currentFace
        VStack(spacing: 0) {
            MessageListHeader(dark: true, back: back, openDetails: openDetails)
            stage(face).frame(maxHeight: .infinity)
            HoldButton(listening: face == .listening, hint: hint(face))
                .gesture(hold)
                .padding(.bottom, 22)
            ModeLabels(page: .voice, dark: true, select: select)
        }
        .background((face == .listening ? Color(hex: 0x123A9C) : Site.blue).ignoresSafeArea())
        .animation(.snappy, value: face)
    }

    private var currentFace: Face {
        if holding || voice.phase == .hearing { return .listening }
        if voice.isOn && (voice.phase == .thinking || !model.approvals.isEmpty) { return .working }
        return .ready
    }

    // MARK: The middle

    @ViewBuilder private func stage(_ face: Face) -> some View {
        VStack(spacing: 14) {
            switch face {
            case .ready:
                Text("Hold and say it.").font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                Text(readyLine).font(.system(size: 17)).foregroundStyle(.white.opacity(0.72)).multilineTextAlignment(.center)
                    .onTapGesture { if !voice.canTalk { openModel() } }
            case .listening:
                heard.font(.system(size: 40, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                VoiceWaveform().padding(.top, 24).frame(height: 48)
            case .working:
                Text(workingTitle).font(.system(size: 34, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.center)
                Text(workingDetail).font(.system(size: 17)).foregroundStyle(.white.opacity(0.72))
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(0..<segments.total, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(i < segments.done ? 1 : 0.28)).frame(width: 44, height: 4)
                        }
                    }
                    if Self.sample == .working || !model.approvals.isEmpty {
                        HStack(spacing: 6) {
                            Capsule().fill(Color(hex: 0x0A2F6B)).frame(width: 22, height: 8)
                            Text("Waiting for you to approve in the Dynamic Island").font(.system(size: 13)).foregroundStyle(.white.opacity(0.72))
                        }
                        .padding(.top, 18)
                    }
                }
                .padding(.top, 18)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }

    private var readyLine: String {
        if case .lost(let why) = voice.phase { return why }
        if !voice.canTalk, VoiceDirect.apiKey == nil { return AppLocalization.text(LocalizedStringResource("Set up Poki’s model first. Tap to open Settings › Models.")) }
        return AppLocalization.text(LocalizedStringResource("“Text Mom I’m on my way.”"))
    }

    /// What Poki heard so far, the last word faded while you speak.
    private var heard: Text {
        let said = Self.sample == .listening ? AppLocalization.text(LocalizedStringResource("Text Mom\nI’m on my way…")) : (voice.lines.last { $0.role == .you }?.text ?? AppLocalization.text(LocalizedStringResource("Listening…")))
        guard let space = said.lastIndex(where: { $0 == " " || $0 == "\n" }) else { return Text(verbatim: said) }
        let last = Text(verbatim: String(said[said.index(after: space)...])).foregroundStyle(.white.opacity(0.5))
        return Text("\(String(said[...space]))\(last)")
    }

    private var workingTitle: String {
        if Self.sample == .working { return AppLocalization.text(LocalizedStringResource("Typing “On my way”")) }
        return ActivityWords.label(model.activityText)
    }

    private var workingDetail: String {
        if Self.sample == .working { return AppLocalization.text(LocalizedStringResource("Step 3 of 4, in Messages")) }
        let n = model.recentSteps.count + 1
        return AppName.display(model.currentApp).map { AppLocalization.text(LocalizedStringResource("Step \(n), in \($0)")) } ?? AppLocalization.text(LocalizedStringResource("Step \(n)"))
    }

    /// Done steps and the one under way. The total is not known until the task ends, so it grows.
    private var segments: (done: Int, total: Int) {
        if Self.sample == .working { return (3, 4) }
        let done = min(model.recentSteps.count, 7)
        return (done, done + 1)
    }

    private func hint(_ face: Face) -> LocalizedStringKey {
        switch face {
        case .ready: voice.isOn ? "Hold to talk, slide up to end" : "Hold to Talk"
        case .listening: cancelling ? "Release to end the conversation." : "Release to send. Slide up to cancel."
        case .working: "Hold to add something"
        }
    }

    // MARK: Holding

    private var hold: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !holding {
                    holding = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if voice.canTalk { model.prepareForTask(); Task { await voice.press() } } else { openModel() }
                }
                cancelling = value.translation.height < -60
            }
            .onEnded { _ in
                if cancelling { voice.stop() } else { voice.released() }
                holding = false
                cancelling = false
            }
    }

    // MARK: Screenshots

    /// `-pokiVoice ready|listening|working`: a board's face for the build's screenshots, with its sample words.
    static let sample: Face? = switch UserDefaults.standard.string(forKey: "pokiVoice") {
    case "ready": .ready
    case "listening": .listening
    case "working": .working
    default: nil
    }
}

/// The rings around the microphone: open on blue, filled while listening (the boards' 172, 124, 88 and
/// 200, 150, 104 pt circles).
private struct HoldButton: View {
    var listening: Bool
    var hint: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(listening ? Site.blue.opacity(0.35) : .clear)
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1.5))
                    .frame(width: listening ? 200 : 172, height: listening ? 200 : 172)
                Circle().fill(listening ? Site.blue : .clear)
                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
                    .frame(width: listening ? 150 : 124, height: listening ? 150 : 124)
                Circle().fill(.white)
                    .shadow(color: Color(hex: 0x002878).opacity(0.4), radius: 15, y: 14)
                    .frame(width: listening ? 104 : 88, height: listening ? 104 : 88)
                Image(systemName: "mic.fill").font(.system(size: 30, weight: .medium)).foregroundStyle(Site.blue)
            }
            .frame(width: 200, height: 200)
            .contentShape(.circle)
            .accessibilityElement()
            .accessibilityLabel(Text("Hold to Talk"))
            .accessibilityAddTraits(.isButton)
            Text(hint).font(.system(size: 13)).foregroundStyle(.white.opacity(0.84))
        }
        .animation(.spring(duration: 0.35, bounce: 0.25), value: listening)
    }
}

// RecordWaveform is from exyte/Chat (commit f382a14, Sources/ExyteChat/Views/Recording/RecordWaveform.swift,
// by Alisa Mylnikova), Copyright (c) 2019 exyte, MIT License; see THIRD_PARTY_NOTICES.md. Changed: the
// board's 14 bars (4 pt wide, 4 pt apart, up to 48 pt, fading at the ends), centred instead of on the
// bottom, and moving while Poki listens. The voice conversation gives no microphone levels, so the bars
// follow the board's shape instead of the sound.
struct VoiceWaveform: View {
    /// The board's heights and opacities.
    static let samples: [(height: CGFloat, opacity: Double)] = [
        (10, 0.5), (18, 0.6), (30, 1), (44, 1), (26, 1), (38, 1), (48, 1), (30, 1), (20, 1), (36, 1), (24, 0.8), (14, 0.6), (8, 0.4), (6, 0.3),
    ]
    static let spacing: CGFloat = 4
    static let width: CGFloat = 4
    static let maxSampleHeight: CGFloat = 48

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(Array(Self.samples.enumerated()), id: \.offset) { i, s in
                    let wave = 0.75 + 0.25 * sin(t * 6 + Double(i) * 0.9)
                    Capsule()
                        .fill(.white.opacity(s.opacity))
                        .frame(width: Self.width, height: max(Self.width, s.height * wave))
                }
            }
            .frame(height: Self.maxSampleHeight)
        }
        .accessibilityHidden(true)
    }
}
