import Combine
import Foundation

@MainActor
protocol VoiceCallSpeechDelegate: AnyObject {
    var callSpeechEnabled: Bool { get }
    func enqueueCallSpeech(_ text: String)
    func stopCallSpeech()
}

/// A small mockable seam over the EXISTING conversation, not a new agent.
@MainActor
protocol VoiceCallConversation: AnyObject {
    var voiceCallDelegate: (any VoiceCallSpeechDelegate)? { get set }
    var callIsProcessing: Bool { get }
    var callCanStart: Bool { get }
    var callError: String? { get }
    var callReply: String { get }
    var callProcessing: AnyPublisher<Bool, Never> { get }
    var callChanges: AnyPublisher<Void, Never> { get }
    func submitCallTurn(_ text: String) -> Bool
    func cancelCallTurn()
}


@MainActor
final class VoiceCallPresentationStore: ObservableObject {
    static let shared = VoiceCallPresentationStore()
    @Published var isPresented = false
}
