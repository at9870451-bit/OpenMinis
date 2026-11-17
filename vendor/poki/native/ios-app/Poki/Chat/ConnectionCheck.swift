import Foundation
import PiSwiftAI

/// Test Connection on the key page: the smallest real request (a few tokens) through pi, the code and
/// provider definitions the chat runs on, with the key, address and model on the page, saved or not.
/// It writes nothing and logs nothing. The key goes only to its provider and never into the words: a
/// server that repeats it has it replaced.
enum ConnectionCheck {
    /// How the test ended, in the owner's words.
    enum Result: Equatable {
        case works(model: String)
        case badKey(reason: String?)
        case unreachable(reason: String?)
        case noEndpoint
        case timedOut
        case noModel(String, reason: String?)
        case notAllowed(reason: String?)
        case failed(status: Int?, reason: String?)

        var passed: Bool {
            if case .works = self { return true }
            return false
        }

        var words: String {
            switch self {
            case .works(let model): AppLocalization.text(LocalizedStringResource("Connection works. Model: \(model)"))
            case .badKey: AppLocalization.text(LocalizedStringResource("The key is not valid. Check that it was copied in full."))
            case .unreachable: AppLocalization.text(LocalizedStringResource("Poki can’t reach this address. Check the address and the network."))
            case .noEndpoint: AppLocalization.text(LocalizedStringResource("The address answers, but has no chat API there. Check that it ends in /v1."))
            case .timedOut: AppLocalization.text(LocalizedStringResource("No answer within 10 seconds. Check the address and the network, then try again."))
            case .noModel(let model, _): AppLocalization.text(LocalizedStringResource("The model \(model) doesn’t exist, or this key can’t use it."))
            case .notAllowed: AppLocalization.text(LocalizedStringResource("Not enough quota or permission. Check the account’s billing and the key’s permissions."))
            case .failed(let status?, _): AppLocalization.text(LocalizedStringResource("The server returned an error (\(status))."))
            case .failed(nil, _): AppLocalization.text(LocalizedStringResource("The test didn’t finish."))
            }
        }

        /// The server's own short reason, without the key, when it gave one.
        var detail: String? {
            switch self {
            case .badKey(let reason), .unreachable(let reason), .noModel(_, let reason), .notAllowed(let reason), .failed(_, let reason): reason
            case .works, .noEndpoint, .timedOut: nil
            }
        }
    }

    static let deadline: Double = 10

    /// One request with `key` (a custom endpoint may have none) to the provider's chat model, or for a
    /// custom endpoint to `customURL` and `modelID`. The first of the answer and the deadline wins.
    @MainActor
    static func run(_ provider: ModelProvider, key: String, customURL: String = "", modelID: String = "") async -> Result {
        let id = provider == .custom ? modelID.trimmingCharacters(in: .whitespaces) : ModelKeys.model(for: provider)
        guard let model = provider.piModel(id, customURL: provider == .custom ? customURL : nil) else {
            return .failed(status: nil, reason: nil)
        }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = Probe()
        let cancel = CancellationToken()
        var options = SimpleStreamOptions()
        options.apiKey = key.isEmpty && provider == .custom ? "none" : key
        // A connection check runs before a conversation exists. Give this probe its own
        // routing identifier, using PiSwift's OpenCode host and provider checks.
        options.headers = openCodeSessionHeaders(model: model, sessionId: UUID().uuidString, headers: options.headers)
        options.maxTokens = 16
        options.maxRetries = 0
        options.timeoutMs = Int(deadline * 1000) + 5000
        options.signal = cancel
        // pi's Google adapter takes no HTTP client of its own; its answer is read from pi's message alone.
        if model.api != .googleGenerativeAI { options.httpClient = probe }
        let context = Context(messages: [.user(UserMessage(content: .text("Reply with OK.")))])
        let request = options

        let outcome: Outcome = await withCheckedContinuation { (done: CheckedContinuation<Outcome, Never>) in
            let first = FirstAnswer(done)
            let work = Task { @MainActor in
                do {
                    let reply = try await completeSimple(model: model, context: context, options: request)
                    first.finish(.reply(reply))
                } catch {
                    first.finish(.thrown(error.localizedDescription))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(deadline))
                if first.finish(.late) { cancel.cancel(); work.cancel() }
            }
        }
        let seen = probe.seen
        switch outcome {
        case .late:
            return .timedOut
        case .reply(let reply) where reply.stopReason != .error && reply.stopReason != .aborted:
            return .works(model: seen.servedModel ?? reply.responseModel ?? reply.model)
        case .reply(let reply):
            return classify(seen, message: reply.errorMessage ?? "", key: key, model: id, custom: provider == .custom)
        case .thrown(let message):
            return classify(seen, message: message, key: key, model: id, custom: provider == .custom)
        }
    }

    /// Sorts a failed request by its HTTP status, its transport error and the server's own words. The
    /// status and body come from the probe; the Google adapter's come from pi's message, which carries
    /// the server's JSON.
    static func classify(_ seen: Probe.Seen, message: String, key: String, model: String, custom: Bool) -> Result {
        if let failure = seen.failure {
            switch failure {
            case .timedOut: return .timedOut
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost,
                 .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection, .cannotLoadFromNetwork:
                return .unreachable(reason: nil)
            default: break
            }
        }
        let body = seen.body.isEmpty ? message : seen.body
        let json = errorJSON(body)
        let status = seen.status ?? (json?["code"] as? Int) ?? statusIn(message)
        let reason = shortReason(json, body, key: key)
        let lower = ((json?["message"] as? String) ?? body).lowercased() + " " + ((json?["code"] as? String) ?? "").lowercased()
            + " " + ((json?["type"] as? String) ?? "").lowercased() + " " + ((json?["status"] as? String) ?? "").lowercased()

        let keyWords = ["invalid_api_key", "invalid api key", "incorrect api key", "api key not valid", "invalid x-api-key", "authentication_error", "unauthenticated", "api_key_invalid"]
        if status == 401 || keyWords.contains(where: lower.contains) { return .badKey(reason: reason) }
        let modelWords = ["model_not_found", "does not exist", "not found", "unknown model", "invalid model", "no such model", "not_found_error"]
        let namesModel = lower.contains("model") && modelWords.contains(where: lower.contains)
        if status == 404 { return namesModel || !custom ? .noModel(model, reason: reason) : .noEndpoint }
        if namesModel, status == 400 { return .noModel(model, reason: reason) }
        let quotaWords = ["quota", "credit", "billing", "insufficient", "permission", "rate limit", "rate_limit", "resource_exhausted", "payment"]
        if [402, 403, 429].contains(status ?? 0) || quotaWords.contains(where: lower.contains) { return .notAllowed(reason: reason) }
        if [408, 504, 524].contains(status ?? 0) { return .timedOut }
        if status == nil, lower.contains("timed out") || lower.contains("timeout") { return .timedOut }
        if status == nil, seen.failure != nil { return .unreachable(reason: reason) }
        return .failed(status: status, reason: reason)
    }

    /// The `error` object of the server's JSON, which may follow pi's prefix ("OpenAI API error (401): {…}").
    private static func errorJSON(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] { return error }
        if let error = object["error"] as? String { return ["message": error] }
        return object["message"] is String ? object : nil
    }

    /// The status in pi's words for a failed request: "(401)" or "(HTTP 401)".
    private static func statusIn(_ message: String) -> Int? {
        guard let match = message.firstMatch(of: #/\((?:HTTP )?([1-5]\d\d)\)/#) else { return nil }
        return Int(match.1)
    }

    /// At most 140 characters of the server's message on one line, with the key replaced.
    private static func shortReason(_ json: [String: Any]?, _ body: String, key: String) -> String? {
        var text = (json?["message"] as? String) ?? (json == nil ? body : "")
        if key.count >= 6 { text = text.replacingOccurrences(of: key, with: "[redacted]") }
        text = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("<") { return nil }  // an HTML error page says nothing useful here
        guard !text.isEmpty else { return nil }
        return text.count > 140 ? String(text.prefix(139)) + "…" : text
    }

    private enum Outcome: Sendable {
        case reply(AssistantMessage)
        case thrown(String)
        case late
    }

    /// pi's own HTTP client with a look at the answer: its status, a transport error's code, the first
    /// 4 KB of its body (the error's words, or the model that answered), passed on unchanged.
    final class Probe: ProviderHTTPClient, @unchecked Sendable {
        struct Seen {
            var status: Int?
            var failure: URLError.Code?
            var body = ""
            var servedModel: String? {
                guard let match = body.firstMatch(of: #/"(?:model|modelVersion)"\s*:\s*"([^"]+)"/#) else { return nil }
                return String(match.1)
            }
        }

        private let inner = DefaultProviderHTTPClient()
        private let lock = NSLock()
        private var status: Int?
        private var failure: URLError.Code?
        private var head = Data()

        var seen: Seen {
            lock.withLock { Seen(status: status, failure: failure, body: String(decoding: head, as: UTF8.self)) }
        }

        func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
            try await send(request, timeoutPolicy: .request)
        }

        func send(_ request: URLRequest, timeoutPolicy: ProviderHTTPTimeoutPolicy) async throws -> ProviderHTTPResponse {
            let response: ProviderHTTPResponse
            do {
                response = try await inner.send(request, timeoutPolicy: timeoutPolicy)
            } catch {
                lock.withLock { failure = (error as? URLError)?.code }
                throw error
            }
            lock.withLock { status = response.statusCode }
            let body = response.body
            let tee = AsyncThrowingStream<Data, Error> { continuation in
                let task = Task {
                    do {
                        for try await chunk in body {
                            self.keep(chunk)
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return ProviderHTTPResponse(statusCode: response.statusCode, headers: response.headers, body: tee)
        }

        private func keep(_ chunk: Data) {
            lock.withLock {
                guard head.count < 4096 else { return }
                head.append(chunk.prefix(4096 - head.count))
            }
        }
    }
}

/// The first of the reply and the deadline; the other is dropped. True for the one that won. Both
/// finish on the main actor.
private final class FirstAnswer<Value> {
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    @discardableResult func finish(_ value: Value) -> Bool {
        guard let continuation else { return false }
        continuation.resume(returning: value)
        self.continuation = nil
        return true
    }
}
