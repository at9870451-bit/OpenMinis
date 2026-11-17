import Foundation

/// What a talk with Poki is doing, as its screens say it: one value at a time, worked out from the
/// voice session (`VoiceModel.talkState`). The message field's talk bar, the light along the bottom
/// edge and Poki's picture all read this, so they change together.
enum TalkState: Equatable {
    case connecting
    /// The microphone is open and nobody speaks.
    case listening
    /// The person is speaking.
    case hearing
    case thinking
    /// A step of the talk is running on the phone.
    case acting
    case speaking
    /// The person spoke over Poki's answer, or stopped it: said for a moment, then Poki listens again.
    case interrupted
    /// The talk ended without being asked to. Why, in the session's own words.
    case failed(String)

    /// Why a talk ended when its connection dropped, as the session's phase carries it.
    static let connectionLost = "Connection lost"

    var isFailed: Bool { if case .failed = self { true } else { false } }

    /// The state in the app's status words: two to four characters in Chinese, no subject.
    var word: String {
        switch self {
        case .connecting: AppLocalization.text(LocalizedStringResource("Connecting"))
        case .listening, .hearing: StatusWord.listening.text
        case .thinking: StatusWord.thinking.text
        case .acting: StatusWord.running.text
        case .speaking: StatusWord.speaking.text
        case .interrupted: AppLocalization.text(LocalizedStringResource("Interrupted"))
        case .failed(let why): why == Self.connectionLost ? StatusWord.disconnected.text : StatusWord.error.text
        }
    }

    /// What went wrong, for the line under the word; nil when the word says it all.
    var reason: String? {
        guard case .failed(let why) = self else { return nil }
        return why == Self.connectionLost ? AppLocalization.text(LocalizedStringResource("Check the network, then try again.")) : why
    }
}
