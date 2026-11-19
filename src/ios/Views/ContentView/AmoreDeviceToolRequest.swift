import Foundation

/// Validate the host wrapper before any developer connection or device action.
/// Do not coerce a missing/wrong action to status or a wrong payload to {}.
struct AmoreDeviceToolRequest {
    let action: String
    let argumentsJSON: String

    enum Invalid: LocalizedError {
        case request(String)
        var errorDescription: String? {
            if case .request(let reason) = self { return "not_sent: " + reason + " No device action was executed." }
            return nil
        }
    }
    init(_ values: [String: Any]) throws {
        guard let action = values["action"] as? String,
              ["help", "status", "look", "do"].contains(action) else {
            throw Invalid.request("device_control requires action=help, status, look or do; it must be a string.")
        }
        let object: [String: Any]
        if let payload = values["arguments_json"] {
            if let text = payload as? String {
                guard !text.isEmpty, text.utf8.count <= 64 * 1024,
                      let data = text.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data),
                      let dictionary = parsed as? [String: Any] else {
                    throw Invalid.request("arguments_json must be a complete JSON object, not an array, blank text or truncated JSON.")
                }
                object = dictionary
            } else if let dictionary = payload as? [String: Any], JSONSerialization.isValidJSONObject(dictionary) {
                // Some compatible tool backends decode a JSON-string parameter
                // to an object. Preserve it exactly, never silently discard it.
                object = dictionary
            } else {
                throw Invalid.request("arguments_json has the wrong type. Supply a JSON object string.")
            }
        } else {
            if action == "do" { throw Invalid.request("action=do requires arguments_json with an actions array. First call help for the schema.") }
            object = [:]
        }
        if action == "do" {
            guard let actions = object["actions"] as? [[String: Any]], actions.count <= 20 else {
                throw Invalid.request("action=do requires an actions array of at most 20 objects. Do not replace actions with actionJSON or a status query.")
            }
            guard !actions.isEmpty || object["finish"] as? Bool == true else {
                throw Invalid.request("The actions array is empty; there is no device action to send.")
            }
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= 64 * 1024, let json = String(data: data, encoding: .utf8) else {
            throw Invalid.request("Device arguments cannot be encoded as a bounded JSON object.")
        }
        self.action = action
        self.argumentsJSON = json
    }
}

enum AmoreDeviceToolPresentation {
    static func pending(action: String) -> String {
        "device_control · " + action + "\nWaiting for device execution/result; a tool label or service hello is not proof that an action ran."
    }
    static func completed(output: String, success: Bool, waitingForOwner: Bool) -> String {
        let result = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Device tool returned no readable result; no execution claim can be made." : output
        return waitingForOwner ? result + "\nWaiting for owner input or automation readiness; this is not a completed device action." : result
    }
}
