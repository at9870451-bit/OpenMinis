import Foundation
import PokiCore

/// A tool call the model asked for: its id, the tool and the arguments as JSON text.
struct ToolCall {
    var id: String
    var name: String
    var arguments: String
}

/// One answer from the model: what it said, the tools it called and why it stopped.
struct ModelTurn {
    enum Ending { case tools, done, again, refused, cutOff }
    var texts: [String]
    var calls: [ToolCall]
    var ending: Ending
}

/// One provider's conversation. Each client keeps the history in its own API's form, append-only: what
/// the model sent goes back unchanged.
@MainActor
protocol ModelClient: AnyObject {
    /// Where this conversation runs, so the chat starts a new one when the owner picks another model.
    var signature: String { get }
    func say(_ text: String)
    func next(instructions: String, tools: [ToolSpec]) async throws -> ModelTurn
    func answer(_ call: ToolCall, _ result: PokiCore.ToolAnswer)
    /// A request failed before the model saw the owner's last message: it goes again with the next one.
    func forgetUnansweredQuestion()
}

/// An API's error, worded for the owner. The key never appears in it.
struct ModelFailure: LocalizedError {
    var errorDescription: String?
}

func postJSON(_ url: URL, headers: [String: String], body: [String: Any], key: String, provider: String) async throws -> (Int, [String: Any]?, Data) {
    var request = URLRequest(url: url, timeoutInterval: 120)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch {
        throw ModelFailure(errorDescription: AppLocalization.text(LocalizedStringResource("Poki could not reach \(provider). \(error.localizedDescription)")))
    }
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, json, data)
}

/// The API's own message, without the key (an API can repeat what it was sent).
func apiErrorText(_ json: [String: Any]?, _ data: Data, key: String) -> String {
    let text = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
    return key.isEmpty ? text : text.replacingOccurrences(of: key, with: "[redacted]")
}

// MARK: Anthropic

/// The Claude API's Messages endpoint over plain HTTPS (Swift has no official Anthropic SDK), with the
/// owner's key.
@MainActor
final class AnthropicClient: ModelClient {
    let key: String
    let model: String
    private var history: [[String: Any]] = []

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let version = "2026-10-21"

    init(key: String, model: String) { self.key = key; self.model = model }

    var signature: String { "anthropic/\(model)" }

    func say(_ text: String) { addUser(["type": "text", "text": text], plain: text) }

    func answer(_ call: ToolCall, _ result: PokiCore.ToolAnswer) {
        var parts: [[String: Any]] = [["type": "text", "text": result.text]]
        if let jpeg = result.jpeg {
            parts.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]])
        }
        addUser(["type": "tool_result", "tool_use_id": call.id, "content": parts, "is_error": result.isError], plain: nil)
    }

    /// Tool results and the owner's next words share one user turn.
    private func addUser(_ block: [String: Any], plain: String?) {
        if history.last?["role"] as? String == "user" {
            var last = history.removeLast()
            var content: [[String: Any]] = (last["content"] as? [[String: Any]]) ?? ((last["content"] as? String).map { [["type": "text", "text": $0]] } ?? [])
            content.append(block)
            last["content"] = content
            history.append(last)
        } else if let plain {
            history.append(["role": "user", "content": plain])
        } else {
            history.append(["role": "user", "content": [block]])
        }
    }

    func forgetUnansweredQuestion() {
        if history.last?["role"] as? String == "user", history.last?["content"] is String { history.removeLast() }
    }

    func next(instructions: String, tools: [ToolSpec]) async throws -> ModelTurn {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": instructions,
            "tools": tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] },
            "messages": history,
            // The prompt and the tools never change during a chat: every step after the first reads them from the cache.
            "cache_control": ["type": "ephemeral"],
            // Many steps with tools: medium effort is the guide's starting point for this kind of work.
            "output_config": ["effort": "medium"],
        ]
        var headers = ["x-api-key": key, "anthropic-version": Self.version]
        // A declined request is run again on a suitable model by the API itself (Sonnet 5.5 and Opus 5.5;
        // Haiku has no server-side fallback).
        if !model.hasPrefix("claude-haiku") {
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
            body["fallbacks"] = "default"
        }
        let (status, json, data) = try await postJSON(Self.endpoint, headers: headers, body: body, key: key, provider: "Anthropic")
        guard (200..<300).contains(status), let json else {
            let text = apiErrorText(json, data, key: key)
            let words: String = switch status {
            case 401: AppLocalization.text(LocalizedStringResource("Anthropic did not accept the key. Check it in Settings › Models."))
            case 403: AppLocalization.text(LocalizedStringResource("This Anthropic key can’t use \(ModelKeys.selectedModelName)."))
            case 429: AppLocalization.text(LocalizedStringResource("Anthropic says the key has hit its rate limit. Try again in a minute."))
            case 529: AppLocalization.text(LocalizedStringResource("Anthropic is overloaded right now. Try again in a minute."))
            default: AppLocalization.text(LocalizedStringResource("Anthropic answered \(status), \(text)"))
            }
            throw ModelFailure(errorDescription: words)
        }
        let content = json["content"] as? [[String: Any]] ?? []
        history.append(["role": "assistant", "content": content])
        let texts = content.filter { $0["type"] as? String == "text" }.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let calls = content.filter { $0["type"] as? String == "tool_use" }.map { block in
            ToolCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "",
                     arguments: (try? JSONSerialization.data(withJSONObject: block["input"] ?? [String: Any]())).map { String(decoding: $0, as: UTF8.self) } ?? "{}")
        }
        let ending: ModelTurn.Ending = switch json["stop_reason"] as? String {
        case "tool_use": .tools
        case "pause_turn": .again
        case "refusal": .refused
        case "max_tokens": .cutOff
        default: .done
        }
        return ModelTurn(texts: texts, calls: calls, ending: ending)
    }
}
