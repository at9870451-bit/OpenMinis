import AVFoundation
import Combine
import Foundation
import SwiftUI

@MainActor
final class VoiceSessionManager: ObservableObject, VoiceCallSpeechDelegate, VoiceCallAudioIODelegate {
    private static weak var current: VoiceSessionManager?
    @Published private(set) var state: VoiceCallState = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var muted = false
    @Published private(set) var speakerEnabled = true
    @Published private(set) var transcript = ""
    @Published private(set) var reply = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var connectedAt: Date?
    private var machine = VoiceStateMachine()
    private let audio: any VoiceCallAudioTransport
    private let services: VoiceCallServices
    private weak var conversation: (any VoiceCallConversation)?
    private var pendingText: [String] = []
    private var asrIdentity: UUID?
    private var asrTask: Task<Void, Never>?
    private var ttsTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingAudio: [Data] = []
    private var speechQueue: [String] = []
    private var speechEpoch: UInt64 = 0
    private var ownsAgentTurn = false
    private var ownerGeneration: UInt64 = 0
    private var playing = false
    private var synthesizing = false
    private var joiningSegment = false

    init(audio: any VoiceCallAudioTransport, services: VoiceCallServices) {
        self.audio = audio
        self.services = services
        self.audio.delegate = self
    }
    var isActive: Bool { machine.state.isLive }
    var canControlAudio: Bool { isActive && connectedAt != nil && ![.interrupted, .connecting, .requestingPermission].contains(state) }
    var callSpeechEnabled: Bool { isActive && !machine.userIsSpeaking && state != .interrupted }
    private func publish(_ next: VoiceCallState? = nil) {
        if let next { machine.set(next) }
        state = machine.state; muted = machine.microphoneMuted
    }

    func connect(to conversation: any VoiceCallConversation) async {
        guard !isActive else { return }
        guard Self.current == nil || Self.current === self else {
            errorMessage = AppLocalized("Another voice call is active."); publish(.failed); return
        }
        guard conversation.callCanStart, !conversation.callIsProcessing else {
            errorMessage = AppLocalized("Choose a chat model and finish the current response before calling.")
            publish(.failed); return
        }
        Self.current = self
        self.conversation = conversation
        let token = machine.start(); publish(); errorMessage = nil
        guard await services.authorize(), machine.accepts(token), Self.current === self else {
            if machine.accepts(token) { fail(AppLocalized("Microphone or speech recognition permission was not granted.")) }
            return
        }
        publish(.connecting)
        do {
            // Calling is explicit user intent, but it does not change the user's
            // persisted read-aloud, microphone-mode or voice-provider settings.
            VoiceOutputState.shared.stop()
            try await audio.start()
            guard machine.accepts(token), Self.current === self else { audio.stop(); return }
            audio.useSpeaker(speakerEnabled)
            conversation.voiceCallDelegate = self
            observe(conversation)
            connectedAt = Date(); publish(.listening)
        } catch {
            if machine.accepts(token) { fail(error.localizedDescription) }
        }
    }

    private func observe(_ conversation: any VoiceCallConversation) {
        conversation.callProcessing.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] processing in
            guard let self, self.isActive,
                  processing == self.conversation?.callIsProcessing else { return }
            if processing {
                if !self.machine.userIsSpeaking, !self.playing { self.publish(.thinking) }
            } else {
                self.ownsAgentTurn = false
                if let error = self.conversation?.callError { self.errorMessage = error }
                if self.joiningSegment { self.transcribeNext(); self.submitRecognizedIfReady() }
                else if !self.playing && !self.synthesizing && self.speechQueue.isEmpty {
                    self.publish(self.muted ? .muted : .listening)
                }
            }
        }.store(in: &subscriptions)
        conversation.callChanges.throttle(for: .milliseconds(120), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isActive else { return }
                    self.reply = self.conversation?.callReply ?? self.reply
                }
            }.store(in: &subscriptions)
    }

    func callAudioSpeechBegan() {
        guard isActive, !muted, state != .interrupted else { return }
        let bargeIn = ownsAgentTurn || playing || synthesizing || !speechQueue.isEmpty
        _ = machine.speechBegan(invalidatePrevious: bargeIn); publish()
        // Speech-onset stops the duplex output before ASR/network completion.
        if bargeIn {
            stopCallSpeech()
            asrIdentity = nil; asrTask?.cancel(); asrTask = nil
            pendingAudio.removeAll(); pendingText.removeAll(); joiningSegment = false
            if ownsAgentTurn { conversation?.cancelCallTurn(); ownsAgentTurn = false }
        }
        errorMessage = nil
    }
    func callAudioPartialSegment(_ wav: Data) { acceptSegment(wav, final: false) }
    func callAudioSegment(_ wav: Data) { acceptSegment(wav, final: true) }
    private func acceptSegment(_ wav: Data, final: Bool) {
        guard isActive, !muted, state != .interrupted else { return }
        if final { machine.segmentEnded(); publish() }
        guard wav.count > 44 else { submitRecognizedIfReady(); return }
        // Bounded in memory. A provider that cannot keep up pauses capture;
        // it does not grow an unbounded mic recording or pretend it heard it.
        guard pendingAudio.count < 8 else {
            callAudioInterrupted()
            errorMessage = AppLocalized("Please pause briefly while speech recognition catches up."); return
        }
        pendingAudio.append(wav)
        transcribeNext()
    }
    private func transcribeNext() {
        guard isActive, !muted, asrTask == nil, !pendingAudio.isEmpty else { return }
        if conversation?.callIsProcessing == true { joiningSegment = true; return }
        joiningSegment = false
        let wav = pendingAudio.removeFirst(), token = machine.generation, requestID = UUID()
        asrIdentity = requestID
        publish(.transcribing)
        asrTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.asrIdentity == requestID {
                    self.asrIdentity = nil; self.asrTask = nil
                    self.submitRecognizedIfReady()
                    self.transcribeNext()
                    if !self.machine.userIsSpeaking && !self.ownsAgentTurn && self.pendingAudio.isEmpty && self.pendingText.isEmpty && !self.playing && !self.synthesizing {
                        self.publish(.listening)
                    }
                }
            }
            do {
                let recognized = try await self.services.transcribe(wav).trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard self.machine.accepts(token), !self.muted else { return }
                guard !recognized.isEmpty else { return }
                self.pendingText.append(recognized)
                self.transcript = self.pendingText.joined(separator: " ")
            } catch is CancellationError { }
            catch {
                if self.machine.accepts(token) {
                    self.errorMessage = error.localizedDescription
                    self.publish(.listening)
                }
            }
        }
    }

    private func submitRecognizedIfReady() {
        guard isActive, !muted, !machine.userIsSpeaking,
              pendingAudio.isEmpty, asrTask == nil, !pendingText.isEmpty,
              let conversation, !conversation.callIsProcessing else { return }
        let text = pendingText.joined(separator: " ")
        pendingText.removeAll(); ownsAgentTurn = true
        ownerGeneration = machine.generation
        if conversation.submitCallTurn(text) { publish(.thinking) }
        else {
            ownsAgentTurn = false
            errorMessage = AppLocalized("The chat could not accept this voice turn. Check the model or context limit.")
            publish(.listening)
        }
    }

    func enqueueCallSpeech(_ rawText: String) {
        let text = VoiceTextSanitizer.sanitize(rawText)
        guard callSpeechEnabled, ownsAgentTurn, !text.isEmpty else { return }
        // A stream sentence is the unit: start synthesizing immediately, while
        // the Agent keeps streaming and the microphone stays echo-cancelled.
        guard speechQueue.count < 40 else {
            errorMessage = AppLocalized("Voice output is catching up. The complete reply remains in chat.")
            return
        }
        speechQueue.append(text)
        pumpSpeech()
    }
    private func pumpSpeech() {
        guard isActive, !playing, !synthesizing, !speechQueue.isEmpty else { return }
        let text = speechQueue.removeFirst(), token = speechEpoch
        synthesizing = true
        ttsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.services.synthesize(text)
                try Task.checkCancellation()
                guard self.isActive, token == self.speechEpoch else { return }
                self.synthesizing = false; self.playing = true; self.publish(.speaking)
                try self.audio.play(audio) { [weak self] in
                    guard let self, self.isActive, token == self.speechEpoch else { return }
                    self.playing = false; self.ttsTask = nil
                    if self.speechQueue.isEmpty {
                        self.publish(self.conversation?.callIsProcessing == true ? .thinking : .listening)
                    }
                    self.pumpSpeech()
                }
            } catch is CancellationError { }
            catch {
                guard self.isActive, token == self.speechEpoch else { return }
                self.synthesizing = false; self.playing = false; self.ttsTask = nil
                self.errorMessage = error.localizedDescription
                self.publish(.listening)
                self.pumpSpeech()
            }
        }
    }
    func stopCallSpeech() {
        speechEpoch &+= 1
        ttsTask?.cancel(); ttsTask = nil
        speechQueue.removeAll(); playing = false; synthesizing = false
        audio.stopPlayback()
    }
    func callAudioLevel(_ value: Float) { if isActive { level = muted ? 0 : value } }
    func callAudioInterrupted() {
        guard isActive else { return }
        machine.interrupt(); publish()
        asrIdentity = nil; asrTask?.cancel(); asrTask = nil; pendingAudio.removeAll(); pendingText.removeAll()
        stopCallSpeech(); audio.stop(); level = 0
        if ownsAgentTurn { conversation?.cancelCallTurn(); ownsAgentTurn = false }
    }
    func resume() async {
        guard state == .interrupted else { return }
        let token = machine.generation
        do {
            publish(.connecting)
            try await audio.start()
            guard machine.accepts(token), Self.current === self else { audio.stop(); return }
            audio.useSpeaker(speakerEnabled); audio.setMuted(muted)
            publish(muted ? .muted : .listening)
        } catch { if machine.accepts(token) { callAudioInterrupted(); errorMessage = error.localizedDescription } }
    }
    func toggleMute() {
        guard canControlAudio else { return }
        let value = !muted
        machine.mute(value); publish(); level = 0
        asrIdentity = nil; asrTask?.cancel(); asrTask = nil; pendingAudio.removeAll(); pendingText.removeAll(); joiningSegment = false
        audio.setMuted(value)
    }
    func toggleSpeaker() {
        guard isActive else { return }
        speakerEnabled.toggle(); audio.useSpeaker(speakerEnabled)
    }
    func interruptReply() {
        guard isActive else { return }
        stopCallSpeech()
        if ownsAgentTurn { conversation?.cancelCallTurn(); ownsAgentTurn = false }
        publish(muted ? .muted : .listening)
    }
    func hangUp() {
        guard state != .ended else { return }
        machine.finish(); publish()
        asrIdentity = nil; asrTask?.cancel(); asrTask = nil; pendingAudio.removeAll(); pendingText.removeAll()
        stopCallSpeech(); audio.stop(); subscriptions.removeAll(); level = 0
        if ownsAgentTurn { conversation?.cancelCallTurn() }
        ownsAgentTurn = false
        if conversation?.voiceCallDelegate === self { conversation?.voiceCallDelegate = nil }
        conversation = nil
        if Self.current === self { Self.current = nil }
    }
    private func fail(_ message: String) {
        errorMessage = message
        stopCallSpeech(); audio.stop(); publish(.failed)
        if conversation?.voiceCallDelegate === self { conversation?.voiceCallDelegate = nil }
        conversation = nil
        if Self.current === self { Self.current = nil }
    }
}
