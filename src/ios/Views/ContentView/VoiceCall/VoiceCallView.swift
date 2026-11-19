import SwiftUI
import AVFoundation

/// Explicit full-screen call. Dictation keeps its original editor; this view
/// neither reuses its transcript as a draft nor creates a second Agent engine.
struct VoiceCallView: View {
    let conversation: any VoiceCallConversation
    @StateObject private var manager = VoiceSessionManager()
    @ObservedObject private var appLock = SessionLockStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showTranscript = true

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.06, blue: 0.14), .black, Color(red: 0.01, green: 0.08, blue: 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Amore Voice").font(.title2.weight(.semibold))
                        if let date = manager.connectedAt {
                            Text(date, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    Spacer()
                    Button { showTranscript.toggle() } label: {
                        Image(systemName: showTranscript ? "text.bubble.fill" : "text.bubble")
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.1), in: Circle())
                    }.accessibilityLabel(AppLocalized("Show call transcript"))
                }
                Text(AppLocalized(manager.state.title)).font(.headline)
                    .accessibilityIdentifier("voice.call.state")
                Spacer(minLength: 12)
                VoiceCallWaveform(state: manager.state, level: manager.level, reduceMotion: reduceMotion)
                    .frame(height: 180)
                    .accessibilityLabel(AppLocalized(manager.state.title))
                    .padding(.horizontal, 16)
                if let error = manager.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.orange)
                        .multilineTextAlignment(.center).padding(.horizontal)
                        .accessibilityIdentifier("voice.call.error")
                }
                if let vm = conversation as? AIChatViewModel {
                    VoiceCallQuestions(vm: vm)
                }
                if showTranscript {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if !manager.transcript.isEmpty {
                                Text(manager.transcript).foregroundStyle(.white.opacity(0.7))
                                    .accessibilityIdentifier("voice.call.transcript")
                            }
                            if !manager.reply.isEmpty { Text(manager.reply).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 210)
                }
                Spacer(minLength: 12)
                if manager.state == .interrupted {
                    Button(AppLocalized("Resume voice call")) { Task { await manager.resume() } }
                        .buttonStyle(.borderedProminent).tint(.blue)
                } else if manager.state == .speaking || manager.state == .thinking {
                    Button(AppLocalized("Interrupt reply")) { manager.interruptReply() }
                        .buttonStyle(.bordered).tint(.white)
                        .accessibilityIdentifier("voice.call.interrupt")
                }
                HStack(spacing: 26) {
                    control(symbol: manager.muted ? "mic.slash.fill" : "mic.fill", label: manager.muted ? "Unmute microphone" : "Mute microphone", active: manager.muted) { manager.toggleMute() }
                        .disabled(!manager.canControlAudio).accessibilityIdentifier("voice.call.mute")
                    Button {
                        manager.hangUp(); dismiss()
                    } label: {
                        Image(systemName: "phone.down.fill").font(.title2)
                            .frame(width: 66, height: 66).background(.red, in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel(AppLocalized("Hang up"))
                        .accessibilityIdentifier("voice.call.hangup")
                    control(symbol: manager.speakerEnabled ? "speaker.wave.3.fill" : "speaker.fill", label: "Toggle speaker", active: manager.speakerEnabled) { manager.toggleSpeaker() }
                        .disabled(!manager.canControlAudio).accessibilityIdentifier("voice.call.speaker")
                }.padding(.bottom, 20)
                Text(AppLocalized("Uses this conversation, its memory and approved tools. Microphone stops when you leave the call."))
                    .font(.caption2).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
            }.padding(24).foregroundStyle(.white)
        }
        .modifier(AmoreDevicePrompts(isCallSurface: true))
        .task {
            VoiceCallPresentationStore.shared.isPresented = true
            guard !appLock.appIsLocked else { manager.hangUp(); dismiss(); return }
            await manager.connect(to: conversation)
        }
        .onDisappear { manager.hangUp(); VoiceCallPresentationStore.shared.isPresented = false }
        .onChange(of: appLock.appIsLocked) { _, locked in
            if locked { manager.hangUp(); dismiss() }
        }
        .onChange(of: phase) { _, phase in
            if phase == .background { manager.callAudioInterrupted() }
        }
        .interactiveDismissDisabled(manager.isActive)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("voice.call.screen")
    }
    private func control(symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3)
                .frame(width: 56, height: 56)
                .background(active ? .blue.opacity(0.65) : .white.opacity(0.13), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(AppLocalized(label))
    }
}

struct VoiceCallWaveform: View {
    let state: VoiceCallState
    let level: Float
    let reduceMotion: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !state.isLive)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<21, id: \.self) { index in
                    let active = state == .speaking || state == .thinking || state == .listening
                    let wave = abs(sin(time * (state == .thinking ? 1.6 : 4) + Double(index) * 0.55))
                    let amplitude = state == .speaking ? 0.65 : state == .thinking ? 0.2 : Double(level)
                    Capsule().fill(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
                        .frame(width: 5, height: active ? 12 + wave * (20 + amplitude * 90) : 10)
                }
            }.frame(maxWidth: .infinity, minHeight: 150)
             .background(.black.opacity(0.65), in: Capsule())
             .overlay(Capsule().stroke(.blue.opacity(0.35), lineWidth: 1))
        }.drawingGroup().allowsHitTesting(false)
    }
}

private struct VoiceCallQuestions: View {
    @ObservedObject var vm: AIChatViewModel
    @ObservedObject private var asks = UserAskCenter.shared
    private var blocks: [AssistantBlock] {
        vm.messages.suffix(3).flatMap(\.blocks).filter {
            asks.ask(forToolUseId: $0.toolUseId)?.state == .pending
        }
    }
    var body: some View {
        if !blocks.isEmpty {
            ScrollView { VStack(spacing: 12) { ForEach(blocks) { UserAskCardView(block: $0) } } }
                .frame(maxHeight: 260)
                .accessibilityIdentifier("voice.call.approvals")
        }
    }
}
