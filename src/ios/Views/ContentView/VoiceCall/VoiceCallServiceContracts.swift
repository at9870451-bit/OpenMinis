import AVFoundation
import Foundation

protocol VoiceCallAudioIODelegate: AnyObject {
    func callAudioSpeechBegan()
    func callAudioPartialSegment(_ wav: Data)
    func callAudioSegment(_ wav: Data)
    func callAudioLevel(_ level: Float)
    func callAudioInterrupted()
}

extension VoiceCallAudioIODelegate {
    func callAudioPartialSegment(_ wav: Data) { callAudioSegment(wav) }
}


@MainActor
protocol VoiceCallAudioTransport: AnyObject {
    var delegate: VoiceCallAudioIODelegate? { get set }
    func start() async throws
    func setMuted(_ value: Bool)
    func useSpeaker(_ enabled: Bool)
    func stopPlayback()
    func play(_ data: Data, completed: @escaping @MainActor () -> Void) throws
    func stop()
}
@MainActor
struct VoiceCallServices {
    var authorize: () async -> Bool
    var transcribe: (Data) async throws -> String
    var synthesize: (String) async throws -> Data

}
