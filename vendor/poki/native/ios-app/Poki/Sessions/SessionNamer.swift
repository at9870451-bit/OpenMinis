import Foundation
import PiSwiftAI
import PokiCore

/// Names a chat after its first message with the chat's own model: two to four words, like a Notes or
/// ChatGPT title, so the Sessions list does not read "Poki" on every row. No tools, one short turn;
/// nothing is named if the model fails.
@MainActor
enum SessionNamer {
    static func name(for message: String, provider: ModelProvider, model: Model) async -> String? {
        let instructions = """
        You name chat conversations. Reply with only a short title of two to four words for the conversation \
        that starts with the user's message, in the user's language. No quotes, no punctuation at the end, no emoji.
        """
        let loop = PiLoop(provider: provider, model: model, tools: []) { _ in
            .init(text: "No tools.", jpeg: nil, isError: true)
        }
        let reply = Reply()
        let outcome = await loop.run(String(message.prefix(500)), instructions: instructions, maxTurns: 1) { text in if reply.text == nil { reply.text = text } }
        guard outcome == .done, var name = reply.text?.split(separator: "\n").first.map(String.init) else { return nil }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’.。*#"))
        guard !name.isEmpty, name.count <= 48 else { return nil }
        return name
    }
}

@MainActor
private final class Reply { var text: String? }
