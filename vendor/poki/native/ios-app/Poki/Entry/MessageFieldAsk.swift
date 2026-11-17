import Observation

/// A system entry asked for the message field with the keyboard up. ChatView takes it once it is on
/// screen, so a cold launch, where the chat appears after the request, goes the same way as Poki in front.
@MainActor
@Observable
final class MessageFieldAsk {
    static let shared = MessageFieldAsk()
    private(set) var pending = false

    func ask() { pending = true }

    func take() -> Bool {
        defer { pending = false }
        return pending
    }
}
