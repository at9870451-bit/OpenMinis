import Foundation

/// A single persistent control owns the trailing slot. Keep Stop/Queue ahead
/// of idle calling: background Agent jobs must never lose their Stop button.
enum AmoreComposerPrimaryAction: String, Equatable, Sendable {
    case transcribing, queue, stop, preparingCall, call, send

    static func resolve(waitingForVoice: Bool, processing: Bool, busy: Bool,
                        canSend: Bool, canEnqueue: Bool, offersCall: Bool,
                        hasContent: Bool, voiceInputActive: Bool,
                        preparingCall: Bool) -> Self {
        if waitingForVoice { return .transcribing }
        if processing && canEnqueue { return .queue }
        if busy && !canSend { return .stop }
        if preparingCall { return .preparingCall }
        if offersCall && !hasContent && !busy && !processing && !voiceInputActive {
            return .call
        }
        return .send
    }
}
