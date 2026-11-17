import Foundation
import PokiCore

/// OpenAI's Responses API over plain HTTPS with the owner's key: GPT-6.1 Terra by default, with low
/// reasoning as the Mac Poki Agent's pi loop runs it (ESP-62), and no service tier. Nothing is stored at OpenAI
/// (`store: false`); every output item, encrypted reasoning included, goes back in the next request.
@MainActor
final class OpenAIClient: ModelClient {
    let key: String
    let model: String
    private var input: [[String: Any]] = []

    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    init(key: String, model: String) { self.key = key; self.model = model }

    var signature: String { "openai/\(model)" }

    func say(_ text: String) { input.append(["role": "user", "content": text]) }

    func answer(_ call: ToolCall, _ result: PokiCore.ToolAnswer) {
        var output: [[String: Any]] = [["type": "input_text", "text": result.text]]
        if let jpeg = result.jpeg {
            // One pixel per screen point: "high" keeps the picture at its size, so a point on it is a point to tap.
            output.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())", "detail": "high"])
        }
        input.append(["type": "function_call_output", "call_id": call.id, "output": output])
    }

    func forgetUnansweredQuestion() {
        if input.last?["role"] as? String == "user" { input.removeLast() }
    }

    func next(instructions: String, tools: [ToolSpec]) async throws -> ModelTurn {
        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            // do's actions are free-form objects, which strict schemas do not allow.
            "tools": tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.schema, "strict": false] },
            // The phone runs one request at a time.
            "parallel_tool_calls": false,
            "reasoning": ["effort": "low"],
            "max_output_tokens": 16000,
            "store": false,
            "include": ["reasoning.encrypted_content"],
        ]
        let (status, json, data) = try await postJSON(Self.endpoint, headers: ["authorization": "Bearer \(key)"], body: body, key: key, provider: "OpenAI")
        guard (200..<300).contains(status), let json else {
            let text = apiErrorText(json, data, key: key)
            let code = (json?["error"] as? [String: Any])?["code"] as? String
            let words: String = switch status {
            case 401: AppLocalization.text(LocalizedStringResource("OpenAI did not accept the key. Check it in Settings › Models."))
            case 403, 404: AppLocalization.text(LocalizedStringResource("This OpenAI key can’t use \(ModelKeys.selectedModelName)."))
            case 429 where code == "insufficient_quota": AppLocalization.text(LocalizedStringResource("This OpenAI key has no credit left. Check billing at platform.openai.com."))
            case 429: AppLocalization.text(LocalizedStringResource("OpenAI says the key has hit its rate limit. Try again in a minute."))
            default: AppLocalization.text(LocalizedStringResource("OpenAI answered \(status), \(text)"))
            }
            throw ModelFailure(errorDescription: words)
        }
        if json["status"] as? String == "failed" {
            let text = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw ModelFailure(errorDescription: AppLocalization.text(LocalizedStringResource("OpenAI answered \(status), \(text)")))
        }
        let output = json["output"] as? [[String: Any]] ?? []
        input.append(contentsOf: output)
        var texts: [String] = []
        var refused = false
        for item in output where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
                if part["type"] as? String == "refusal" { refused = true }
                if part["type"] as? String == "output_text", let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { texts.append(text) }
            }
        }
        let calls = output.filter { $0["type"] as? String == "function_call" }.map {
            ToolCall(id: $0["call_id"] as? String ?? "", name: $0["name"] as? String ?? "", arguments: $0["arguments"] as? String ?? "{}")
        }
        let reason = (json["incomplete_details"] as? [String: Any])?["reason"] as? String
        let ending: ModelTurn.Ending =
            json["status"] as? String == "incomplete" ? (reason == "content_filter" ? .refused : .cutOff)
            : refused ? .refused
            : calls.isEmpty ? .done : .tools
        return ModelTurn(texts: texts, calls: calls, ending: ending)
    }
}
