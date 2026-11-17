import PokiNative
import Foundation

/// poki_history_* through the C ABI (native/launcher/src/history.rs): the screen read as text through
/// the accessibility audit service, on a tunnel of its own and with no XCTest session.
enum HistoryBridge {
    final class Box: @unchecked Sendable {
        let progress: (@Sendable (Data) -> Void)?
        var continuation: CheckedContinuation<Data, Error>?
        init(progress: (@Sendable (Data) -> Void)?, continuation: CheckedContinuation<Data, Error>) {
            self.progress = progress
            self.continuation = continuation
        }
    }

    struct Failure: LocalizedError {
        let message: String
        let fix: String?
        let code: String
        var errorDescription: String? { message }
    }

    /// Runs one request. The answer is the result's `value` as JSON; `progress` gets every read of a
    /// run as JSON, on a launcher thread.
    static func call(_ request: [String: Any], progress: (@Sendable (Data) -> Void)? = nil) async throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: request)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            let box = Unmanaged.passRetained(Box(progress: progress, continuation: c))
            let rc = String(decoding: json, as: UTF8.self).withCString { text in
                poki_history_call(text, { context, event in
                    guard let context, let event else { return }
                    let unmanaged = Unmanaged<Box>.fromOpaque(context)
                    let box = unmanaged.takeUnretainedValue()
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(String(cString: event).utf8))) as? [String: Any] else { return }
                    if object["event"] as? String == "result" {
                        if object["ok"] as? Bool == true {
                            let value = (try? JSONSerialization.data(withJSONObject: object["value"] as? [String: Any] ?? [:])) ?? Data("{}".utf8)
                            box.continuation?.resume(returning: value)
                        } else {
                            box.continuation?.resume(throwing: Failure(message: object["error"] as? String ?? "The read failed.", fix: object["fix"] as? String, code: object["code"] as? String ?? ""))
                        }
                        box.continuation = nil
                        unmanaged.release()
                    } else if let line = object["progress"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: line) {
                        box.progress?(data)
                    }
                }, box.toOpaque())
            }
            if rc != 0 {
                box.takeUnretainedValue().continuation = nil
                box.release()
                c.resume(throwing: Failure(message: "The launcher did not take the request.", fix: nil, code: "config"))
            }
        }
    }

    static func cancel() { poki_history_cancel() }
}
