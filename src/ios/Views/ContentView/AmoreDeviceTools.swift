import Foundation
import AmoreDeviceKit

/// Deliberately keeps the original look/do/status contract visible rather than
/// pretending the device bridge can execute shell or browser commands.
@MainActor
enum AmoreDeviceTools {
    static var definitions: [AgentToolDefinition] {
        guard AmoreDeviceServices.isEnabled else { return [] }
        return [AgentToolDefinition(name: "device_control",
            description: "Control this iPhone through the user's paired developer connection. Use status to inspect readiness. look reads the screen and can return a screenshot; do sends the original structured actions. Requires Settings > Connection enabled and real pairing/DDI/approvals. Never bypass passcode, consent or permissions. The tool returns the original device errors and no fake success. The actions JSON follows the device schema returned by action=help.",
            parameters: [
                "action": AgentToolParam(type: .string, description: "Device action", enumValues: ["help", "status", "look", "do"]),
                "arguments_json": AgentToolParam(type: .string, description: "A JSON object for the underlying look/do tool, using the exact schema from action=help. Defaults to {} for status."),
                "tool_title": AgentToolParam(type: .string, description: "Short description of the device operation in the user's language.")
            ], required: ["action", "tool_title"], propertyOrdering: ["tool_title", "action", "arguments_json"])]
    }
    static func configureHost() {
        AmoreDeviceServices.configure(modelAvailable: {
            ProviderConfigStore.shared.instances.contains { $0.isEnabled && $0.hasAnyCredential }
        }, activeSessionID: { AIChatViewModel.activeSessionId }, stopAgent: { owner in
            if let id = owner ?? AIChatViewModel.activeSessionId,
               let vm = ViewModelCache.shared.get(for: id) { vm.cancel() }
        })
    }
    static func finish(sessionID: String?) { AmoreDeviceServices.finishTask(sessionID: sessionID) }
    static func cancel(sessionID: String?) { AmoreDeviceServices.cancelTask(sessionID: sessionID) }
    static func run(action: String, arguments: String, sessionID: String?) async -> (text: String, image: Data?, error: Bool) {
        guard AmoreDeviceServices.isEnabled else { return (AppLocalized("Enable device control in Settings > Connection first."), nil, true) }
        if action == "help" { return (AmoreDeviceServices.toolInstructions + "\n\n" + AmoreDeviceServices.toolCatalogJSON, nil, false) }
        guard ["status", "look", "do"].contains(action),
              let data = arguments.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            return (AppLocalized("Device arguments must be a JSON object using the original tool schema."), nil, true)
        }
        let answer = await AmoreDeviceServices.execute(action, arguments: arguments, sessionID: sessionID)
        return (answer.text, answer.jpeg, answer.isError)
    }
}
