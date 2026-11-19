import Foundation

enum VoiceCallState: String, Equatable, Sendable {
    case idle, requestingPermission, connecting, listening, transcribing
    case thinking, speaking, muted, interrupted, failed, ended
    var isLive: Bool { ![.idle, .ended, .failed].contains(self) }
    var title: String {
        switch self {
        case .idle: return "Start a voice call"
        case .requestingPermission: return "Microphone permission"
        case .connecting: return "Connecting voice"
        case .listening: return "Listening"
        case .transcribing: return "Recognizing speech"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking — you can interrupt"
        case .muted: return "Microphone muted"
        case .interrupted: return "Audio interrupted — tap to resume"
        case .failed: return "Voice call unavailable"
        case .ended: return "Call ended"
        }
    }
}

/// Generation IDs reject delayed ASR/TTS results after barge-in, hangup or mute.
/// No network, audio session or conversation data is owned by this value type.
struct VoiceStateMachine {
    private(set) var state: VoiceCallState = .idle
    private(set) var generation: UInt64 = 0
    private(set) var microphoneMuted = false
    private(set) var userIsSpeaking = false
    mutating func start() -> UInt64 {
        generation &+= 1; microphoneMuted = false; userIsSpeaking = false
        state = .requestingPermission; return generation
    }
    mutating func set(_ next: VoiceCallState) {
        guard state != .ended || next == .requestingPermission else { return }
        state = microphoneMuted && [.listening,.transcribing].contains(next) ? .muted : next
    }
    @discardableResult mutating func speechBegan(invalidatePrevious: Bool = true) -> UInt64 {
        guard state.isLive, !microphoneMuted else { return generation }
        if invalidatePrevious { generation &+= 1 }
        userIsSpeaking = true; state = .listening
        return generation
    }
    mutating func segmentEnded() { userIsSpeaking = false; if state.isLive { set(.transcribing) } }
    mutating func mute(_ value: Bool) {
        microphoneMuted = value
        if value { generation &+= 1; userIsSpeaking = false; state = .muted }
        else if state.isLive { state = .listening }
    }
    mutating func interrupt() { generation &+= 1; userIsSpeaking = false; state = .interrupted }
    mutating func finish() { generation &+= 1; userIsSpeaking = false; state = .ended }
    func accepts(_ token: UInt64) -> Bool { state.isLive && token == generation }
}
