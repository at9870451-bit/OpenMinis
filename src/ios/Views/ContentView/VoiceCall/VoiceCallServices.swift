import Foundation
import AVFoundation

extension VoiceCallAudioIO: VoiceCallAudioTransport {}

@MainActor
extension VoiceCallServices {
    static var configured: Self {
        Self(authorize: {
            guard await VoiceActivityDetector.requestMicrophonePermission() else { return false }
            if VoiceProviderResolver.resolvedInputCandidates().isEmpty {
                return await SystemVoiceProvider.ensureSpeechAuthorization()
            }
            return true
        }, transcribe: { audio in
            let language = SpeechRecognitionManager.shared.locale.identifier
            var last: Error = VoiceProviderError.noAudioData
            for entry in VoiceProviderResolver.resolvedInputCandidates() {
                try Task.checkCancellation()
                guard let provider = VoiceProviderResolver.inputProvider(for: entry) else { continue }
                do {
                    return try await provider.transcribe(VoiceInputRequest(audioData: audio,
                        model: entry.model.id, language: language, resolvedModel: entry.model)).text
                } catch is CancellationError { throw CancellationError() }
                catch { last = error }
            }
            try Task.checkCancellation()
            guard await SystemVoiceProvider.ensureSpeechAuthorization() else { throw last }
            let onDevice: Bool?
            switch VoiceProviderResolver.resolvedSystemInputMode() {
            case .auto: onDevice = nil
            case .online: onDevice = false
            case .offline: onDevice = true
            }
            return try await SystemVoiceProvider.shared.transcribe(VoiceInputRequest(audioData: audio,
                language: language, onDeviceRecognition: onDevice)).text
        }, synthesize: { text in
            var last: Error?
            for entry in VoiceProviderResolver.resolvedOutputCandidates() {
                try Task.checkCancellation()
                guard let provider = VoiceProviderResolver.outputProvider(for: entry) else { continue }
                do {
                    return try await provider.synthesize(VoiceOutputRequest(input: text,
                        model: entry.model.id, voice: entry.model.id,
                        speed: VoiceOutputPreferences.speedMultiplier, responseFormat: .wav,
                        resolvedModel: entry.model))
                } catch is CancellationError { throw CancellationError() }
                catch { last = error }
            }
            try Task.checkCancellation()
            // Use the exact existing System provider as the final local fallback.
            do {
                return try await SystemVoiceProvider.shared.synthesize(VoiceOutputRequest(input: text,
                    voice: VoiceProviderResolver.resolvedSystemOutputVoiceId(), responseFormat: .wav))
            } catch { throw last ?? error }
        })
    }
}

@MainActor
extension VoiceSessionManager {
    convenience init() { self.init(audio: VoiceCallAudioIO(), services: .configured) }
}
