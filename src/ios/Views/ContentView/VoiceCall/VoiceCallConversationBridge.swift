import Foundation
import Combine

extension AIChatViewModel: VoiceCallConversation {
    var callIsProcessing: Bool { isProcessing }
    var callCanStart: Bool { remoteDeviceId == nil && resolveCurrentEntry() != nil }
    var callError: String? { errorMessage }
    var callReply: String {
        guard let message = messages.last(where: { $0.role == .assistant }) else { return "" }
        return message.blocks.compactMap { block -> String? in
            if case .text = block.kind { return block.content }; return nil
        }.joined(separator: "\n")
    }
    var callProcessing: AnyPublisher<Bool, Never> { $isProcessing.eraseToAnyPublisher() }
    var callChanges: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
    func submitCallTurn(_ text: String) -> Bool {
        guard remoteDeviceId == nil, !isProcessing,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let previous = voiceUsedInComposition
        voiceUsedInComposition = true
        defer { voiceUsedInComposition = previous }
        send(overrideText: text, includeComposerAttachments: false)
        return isProcessing
    }
    func cancelCallTurn() { cancel() }
}
