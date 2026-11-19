import AVFoundation
import UIKit
import Foundation
import RealTimeCutVADLibrary

/// Separate from dictation: one duplex engine with iOS voice-processing AEC.
/// Playback is sent through this SAME engine so echo cancellation has the far
/// end reference. No raw mic audio is written to disk or retained after hangup.
final class VoiceCallAudioIO: NSObject, VADDelegate {
    weak var delegate: VoiceCallAudioIODelegate?
    private var engine = AVAudioEngine()
    private var speaker = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "app.amore.voice-call.audio", qos: .userInitiated)
    private let controlLock = NSLock()
    private var live = false
    private var muted = false
    private var epoch: UInt64 = 0
    private var vad: VADWrapper?
    private var converter: AVAudioConverter?
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private var observers: [NSObjectProtocol] = []
    private var lastLevel: CFAbsoluteTime = 0
    private var lastSpeechStart: CFAbsoluteTime = 0
    private var primed = false
    private let audioOwner = UUID()
    // Owned exclusively by queue/VAD callbacks: 20s speech + 0.5s pre-roll.
    private var speechSamples: [Float] = []
    private var preRoll: [Float] = []
    private var segmentOpen = false
    private var continuedUtterance = false
    private var segmentFrames = 0
    private var quietFrames = 0
    private var pendingFrames = 0


    @MainActor
    func start() async throws {
        stop()
        guard await AudioSessionCoordinator.shared.beginVoiceCallAndWait(owner: audioOwner) else {
            AudioSessionCoordinator.shared.endVoiceCall(owner: audioOwner)
            throw VoiceProviderError.audioSessionPreempted
        }
        engine = AVAudioEngine(); speaker = AVAudioPlayerNode()
        var startError: Error?
        let configured = noff_try_objc {
            do {
                let input = self.engine.inputNode
                try input.setVoiceProcessingEnabled(true)
                self.engine.attach(self.speaker)
                self.engine.connect(self.speaker, to: self.engine.mainMixerNode, format: self.playFormat)
                let format = input.outputFormat(forBus: 0)
                guard format.channelCount > 0, format.sampleRate > 0,
                      let converter = AVAudioConverter(from: format, to: self.pcmFormat),
                      let vad = VADWrapper() else { throw VoiceProviderError.parseError("Microphone format unavailable") }
                self.converter = converter; self.vad = vad
                vad.setSileroModel(.v5); vad.setSamplerate(.SAMPLERATE_16)
                // 32ms frames: fast conversational end point, not dictation's 5s.
                vad.setThresholdWithVadStartDetectionProbability(0.6, vadEndDetectionProbability: 0.45,
                    voiceStartVadTrueRatio: 0.7, voiceEndFalseRatio: 0.9,
                    voiceStartFrameCount: 7, voiceEndFrameCount: 22)
                vad.delegate = self
                self.controlLock.lock(); self.live = true; self.muted = false; self.epoch &+= 1; self.controlLock.unlock()
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    self?.receive(buffer)
                }
                self.primed = true
                self.engine.prepare(); try self.engine.start(); self.speaker.play()
            } catch { startError = error }
        }
        if let startError { stop(); throw startError }
        guard configured, engine.isRunning else { stop(); throw VoiceProviderError.parseError("Voice processing engine did not start") }
        observeInterruptions()
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        controlLock.lock()
        let allowed = live && !muted && pendingFrames < 12
        let generation = epoch
        if allowed { pendingFrames += 1 }
        controlLock.unlock()
        guard allowed, let copied = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let target = copied.floatChannelData else {
            if allowed { controlLock.lock(); pendingFrames = max(0, pendingFrames - 1); controlLock.unlock() }
            return
        }
        copied.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(target[channel], source[channel], Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.controlLock.lock(); self.pendingFrames = max(0, self.pendingFrames - 1); self.controlLock.unlock() }
            self.controlLock.lock(); let current = self.live && !self.muted && generation == self.epoch; self.controlLock.unlock()
            guard current, let converter = self.converter else { return }
            let cap = AVAudioFrameCount(ceil(Double(copied.frameLength) * 16000 / copied.format.sampleRate) + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: self.pcmFormat, frameCapacity: cap) else { return }
            var consumed = false; var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return copied
            }
            guard error == nil, converted.frameLength > 0, let samples = converted.floatChannelData?[0] else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if now - self.lastLevel > 0.05 {
                self.lastLevel = now
                var power: Float = 0
                for i in 0..<Int(converted.frameLength) { power += samples[i] * samples[i] }
                let level = min(1, sqrt(power / Float(converted.frameLength)) * 7)
                DispatchQueue.main.async { [weak self] in self?.delegate?.callAudioLevel(level) }
            }
            let sampleCount = Int(converted.frameLength)
            if self.segmentOpen {
                self.speechSamples.append(contentsOf: UnsafeBufferPointer(start: samples, count: sampleCount))
            } else {
                self.preRoll.append(contentsOf: UnsafeBufferPointer(start: samples, count: sampleCount))
                if self.preRoll.count > 8000 { self.preRoll.removeFirst(self.preRoll.count - 8000) }
            }
            self.vad?.processAudioData(withBuffer: samples, count: UInt(converted.frameLength))
            self.segmentFrames += sampleCount
            // The third-party VAD also retains its own pre-roll: reset it at a
            // bounded interval so an always-talking caller cannot grow memory.
            if self.segmentOpen && self.speechSamples.count >= 320_000 {
                self.emitSamples(final: false)
                self.continuedUtterance = true
                self.resetDetector()
            } else if !self.segmentOpen && self.segmentFrames >= 160_000 {
                self.resetDetector()
            }
            if self.continuedUtterance && self.segmentOpen {
                var power: Float = 0
                for i in 0..<sampleCount { power += samples[i] * samples[i] }
                let rms = sqrt(power / Float(sampleCount))
                self.quietFrames = rms < 0.008 ? self.quietFrames + sampleCount : 0
                if self.quietFrames > 19_200 { self.emitSamples(final: true); self.resetDetector() }
            }
        }
    }

    @MainActor
    func setMuted(_ value: Bool) {
        controlLock.lock(); muted = value; epoch &+= 1; controlLock.unlock()
        // Hardware voice-processing mute prevents packets from being recorded
        // while mute is on; the software gate additionally rejects queued audio.
        engine.inputNode.isVoiceProcessingInputMuted = value
        queue.async { [weak self] in
            guard let self else { return }
            self.speechSamples.removeAll(); self.preRoll.removeAll(); self.segmentOpen = false; self.continuedUtterance = false
            self.resetDetector()
        }
    }

    @MainActor
    func useSpeaker(_ enabled: Bool) { AudioSessionCoordinator.shared.setVoiceCallSpeaker(enabled, owner: audioOwner) }

    @MainActor
    func stopPlayback() { speaker.stop(); if engine.isRunning { speaker.play() } }

    @MainActor
    func play(_ data: Data, completed: @escaping @MainActor () -> Void) throws {
        guard primed, engine.isRunning else { throw VoiceProviderError.audioSessionPreempted }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("amore-call-\(UUID().uuidString).audio")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = try AVAudioFile(forReading: temp)
        guard file.length > 0, file.length < 48_000 * 120,
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let convert = AVAudioConverter(from: file.processingFormat, to: playFormat) else {
            throw VoiceProviderError.parseError("Invalid voice playback audio")
        }
        try file.read(into: input)
        let count = AVAudioFrameCount(ceil(Double(input.frameLength) * playFormat.sampleRate / input.format.sampleRate) + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: count) else { throw VoiceProviderError.noAudioData }
        var consumed = false; var error: NSError?
        convert.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        guard output.frameLength > 0 else { throw VoiceProviderError.noAudioData }
        speaker.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor in completed() }
        }
        if !speaker.isPlaying { speaker.play() }
    }

    @MainActor
    func stop() {
        controlLock.lock(); live = false; epoch &+= 1; controlLock.unlock()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        speaker.stop(); engine.stop()
        if primed { _ = noff_try_objc { self.engine.inputNode.removeTap(onBus: 0) } }
        queue.sync { vad?.delegate = nil; vad = nil; converter = nil; speechSamples.removeAll(); preRoll.removeAll(); segmentOpen = false; continuedUtterance = false; segmentFrames = 0 }
        primed = false
        AudioSessionCoordinator.shared.endVoiceCall(owner: audioOwner)
    }

    @MainActor
    private func observeInterruptions() {
        for notification in [AVAudioSession.interruptionNotification, Notification.Name.AVAudioEngineConfigurationChange, UIApplication.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                if note.name == AVAudioSession.interruptionNotification,
                   (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.began.rawValue { return }
                if note.name == Notification.Name.AVAudioEngineConfigurationChange, self.engine.isRunning { return }
                MainActor.assumeIsolated { self.delegate?.callAudioInterrupted() }
            })
        }
    }

    private func resetDetector() {
        vad?.delegate = nil
        segmentFrames = 0; quietFrames = 0
        if let next = VADWrapper() {
            next.setSileroModel(.v5); next.setSamplerate(.SAMPLERATE_16)
            next.setThresholdWithVadStartDetectionProbability(0.6, vadEndDetectionProbability: 0.45,
                voiceStartVadTrueRatio: 0.7, voiceEndFalseRatio: 0.9,
                voiceStartFrameCount: 7, voiceEndFrameCount: 22)
            next.delegate = self; vad = next
        }
    }
    private func emitSamples(final: Bool) {
        let samples = speechSamples
        speechSamples.removeAll(keepingCapacity: true)
        if final { segmentOpen = false; continuedUtterance = false; quietFrames = 0 }
        var wav = Data()
        if !samples.isEmpty {
            var pcm = [Int16](); pcm.reserveCapacity(samples.count)
            for sample in samples { pcm.append(Int16(max(-1, min(1, sample)) * 32767).littleEndian) }
            let payload = pcm.withUnsafeBytes { Data($0) }
            func u32(_ value: UInt32) { var x = value.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
            func u16(_ value: UInt16) { var x = value.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
            wav.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + payload.count)); wav.append(contentsOf: "WAVEfmt ".utf8)
            u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
            wav.append(contentsOf: "data".utf8); u32(UInt32(payload.count)); wav.append(payload)
        }
        controlLock.lock(); let token = epoch; controlLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.controlLock.lock(); let valid = self.live && !self.muted && token == self.epoch; self.controlLock.unlock()
            guard valid else { return }
            if final { self.delegate?.callAudioSegment(wav) }
            else { self.delegate?.callAudioPartialSegment(wav) }
        }
    }
    func voiceStarted() {
        guard !segmentOpen else { return }
        segmentOpen = true; speechSamples = preRoll; preRoll.removeAll(keepingCapacity: true)
        controlLock.lock(); let allowed = live && !muted; let token = epoch; controlLock.unlock()
        guard allowed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.controlLock.lock(); let valid = self.live && !self.muted && token == self.epoch; self.controlLock.unlock()
            if valid { self.delegate?.callAudioSpeechBegan() }
        }
    }
    func voiceEnded(withWavData wavData: Data!) {
        guard segmentOpen else { return }
        emitSamples(final: true)
    }
    func voiceDidContinue(withPCMFloat pcmFloatData: Data!) {}
}
