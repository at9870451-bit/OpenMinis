// The chat's prompt and tools are the Mac Poki Agent's, copied from this repository at main 729c77e:
// - agent-system.md is agent/prompts/system.md (the same text as agent/prompts/pi-app.md, which
//   agent/task-runner.mjs loads), except two sentences that named tools the app lacks: a locked phone
//   is the owner's to unlock and a password prompt is handed to them, and a purchase is a plain tap;
//   and, for ESP-465, the Return sentence names the type answer's read-back as the check before
//   Return, an action's check lines (the send check after Return) count as evidence, and finish_task
//   comes in the reply right after the observation that verifies the result; and a last paragraph on
//   when a reply uses a Markdown table, which the chat draws as a table (the terminal and message
//   channels the Mac agent answers in do not);
// - the instructions put PokiCore's own MCP instructions first, as task-runner.mjs puts the MCP server's
//   instructions first;
// - look, do and status are PokiCore's tools with their MCP descriptions;
// - report_plan and finish_task are task-runner.mjs's harness tools (#startModel), descriptions and
//   schemas unchanged.
// Not copied, because the app has none of their tools: agent/prompts/call-draft.md and
// agent/skills/iphone-unlock/SKILL.md, unlock_device and handle_alert.
import Foundation
import PokiCore

/// One tool as the model sees it, before a provider puts it in its own form.
struct ToolSpec {
    var name: String
    var description: String
    var schema: [String: Any]
}

enum Harness {
    static let system: String = {
        guard let url = Bundle.main.url(forResource: "agent-system", withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    static var instructions: String { [PokiCore.toolInstructions, system, WebTools.instructions].joined(separator: "\n\n") }

    static let splitViewInstructions = """
    You are Poki, completing the owner's task in two visible iPhone Split View apps while Poki stays in the background. Reply in the owner's language. Publish a short plan with report_plan before acting.
    Start with look and choose pane left or right. Check the app identity and screen before acting. Choose the other pane with a fresh look before using it. The screenshot, element references and points belong to the selected pane. Use only these two apps and leave both windows in place. If the layout changes, look again to confirm it before acting. If the two apps cannot be confirmed, ask the owner to restore them.
    To drag between panes, read the destination first, then select the source with look. Send one do action with drag: {from: source element number or [x,y], to: [x,y], to_pane: left or right}. Use the screenshot of the destination to choose its local drop point. Read the destination again and compare it with the previous evidence. For a photo, verify that the image itself appeared. Sending a gesture does not prove the item arrived. If the result is unclear, report it as unconfirmed and avoid duplicates.
    Before entering text, check the intended field and its content. Verify the result in the same pane and keep further actions within the request. When a tool requests the owner's approval, wait for their decision. If a password, verification or system prompt needs the owner, ask them to take over with handoff and wait for them. Call finish_task after checking the last result. Set success=false when the requested outcome has not been verified.
    """

    /// The instructions for a task: the above, then the saved notes and the routines that fit it.
    @MainActor static func instructions(for task: String, inSplitView: Bool = false) -> String {
        if inSplitView {
            if ApprovalClassifier.mode == .reply { return splitViewInstructions + "\n\n" + replyApprovals }
            return splitViewInstructions
        }
        let brief = PokiCore.memoryBrief(for: task)
        var parts = [instructions]
        parts.append("When the owner asks to continue or resume, identify the task from this conversation or an explicitly selected saved task. If no task matches or more than one could match, ask the owner which task before calling any action tool. Long-term notes and saved routines describe preferences and reusable steps; they are not pending tasks and never authorize choosing a different task.")
        // Poki learns the owner's repeated tasks: a saved routine runs them in one call next time.
        // The routines that fit are in the brief below, so the first call can be the routine itself:
        // listing them first cost a whole model turn before anything happened on the phone. Poki is in
        // front when a task begins, so a first look reads only the owner's chat (ESP-465). finish_task
        // ends the chat's task and the app brings Poki back (chatTaskEnded), so a finish: true do is a
        // step more; the save rides in the same reply instead of a turn before it.
        parts.append("Choose the route from the owner's request. For a website task, start with web_open and use only web tools; do not call look or do to check readiness, open Safari, or finish the task. For an app task, start with do {run: name} when the routine below covers it, else do {launch: bundle id}. When you are not sure of an app's iPhone bundle id, or a launch answers that no app with that bundle id is installed, do not tell the owner the app is missing yet: go home ({button: \"home\"}), swipe down on the Home Screen to search, type the app's name and tap it; say the app is not installed only when that search finds nothing. Send report_plan with the first action. Use both routes only when the owner explicitly requested a separate app part, and put that part in its own plan step with the app's name. A failed step is not permission to switch routes. Finish with finish_task. After a successful app task that was not already a routine, save its steps with routines {action: \"save\", name, description}, named the way the owner would ask for it.")
        // A model decides approvals from what the owner said. A refused step goes through once the
        // owner says yes to it, so the agent asks in words and tries again.
        if ApprovalClassifier.mode == .reply {
            parts.append(replyApprovals)
        }
        if let apps = appIDs(for: task) { parts.append(apps) }
        if !brief.isEmpty { parts.append(brief) }
        return parts.joined(separator: "\n\n")
    }

    private static let replyApprovals = "Approvals here are decided from what the owner said in this chat. When a step is refused (declined), do not tell the owner to tap anything: ask them in plain words whether they want that step done, naming the step, and if they say yes, send the same step again."

    @MainActor private static func appIDs(for task: String) -> String? {
        let apps = AppIconStore.bundleIDs(namedIn: task).compactMap { KnownApps.byID[$0.lowercased()] }
        guard !apps.isEmpty else { return nil }
        let lines = apps.map { app -> String in
            let names = app.names.joined(separator: " / ")
            let others = app.otherIDs.isEmpty ? "" : " (another edition: \(app.otherIDs.joined(separator: ", ")))"
            return "- \(names): \(app.id)\(others)"
        }
        return "The apps this request names and their iPhone bundle ids. Launch them with these ids, not ids from memory (Android package names differ):\n" + lines.joined(separator: "\n")
    }

    /// Poki's own browser's tools (ESP-145) sit beside the phone's.
    static let tools: [ToolSpec] = phoneTools + WebTools.specs + [reportPlan, finishTask]

    static let splitViewTools: [ToolSpec] = [
        ToolSpec(name: "look", description: "Read the app, numbered UI elements and screenshot of the left or right pane. Select a pane explicitly when you first read and whenever moving between apps. Points use the selected screenshot’s own coordinates.",
                 schema: object(["pane": ["type": "string", "enum": ["left", "right"]], "full": ["type": "boolean"]], [])),
        ToolSpec(name: "do", description: "Act in the selected pane, then read it. Actions include {tap: ref or [x,y]}, {type: text, ref?: number}, {key: return|delete|tab|space|escape}, {scroll_to: text}, {swipe: direction}, {back: true}, {wait_until: text}, {handoff: {kind, text}}, and {drag: {from: ref or [x,y], to: [x,y], to_pane: left or right}} for a continuous cross-pane drag. Read the destination first and the source second. The drop point uses destination-local coordinates. Read the destination after sending the drag. Do not switch apps or end Split View.",
                 schema: object(["actions": ["type": "array", "items": ["type": "object"], "minItems": 0, "maxItems": 20], "full": ["type": "boolean"]], ["actions"])),
    ] + phoneTools.filter { $0.name == "status" } + [reportPlan, finishTask]

    /// PokiCore's catalog: look, do and status.
    static let phoneTools: [ToolSpec] = {
        guard let data = PokiCore.toolCatalogJSON.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { tool in
            guard let name = tool["name"] as? String, let description = tool["description"] as? String, let schema = tool["inputSchema"] as? [String: Any] else { return nil }
            return ToolSpec(name: name, description: description, schema: schema)
        }
    }()

    private static func object(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    private static let string: [String: Any] = ["type": "string"]

    static let reportPlan = ToolSpec(
        name: "report_plan",
        description: "Publish a plan before actions. Update currentStep (1-based) on each step. title names the task in two to four words, as a heading in the user's language (\"Text Mom\", \"Order the usual\"), not the user's sentence; send it with the first plan. When the task sends a message to someone, to is that person as the user named them (\"Mom\"); leave it out otherwise.",
        schema: object(["steps": ["type": "array", "items": string, "minItems": 1, "maxItems": 8], "currentStep": ["type": "integer", "minimum": 1, "maximum": 8], "title": string, "to": string], ["steps", "currentStep"]))

    static let finishTask = ToolSpec(
        name: "finish_task",
        description: "Finish after the last observation verifies the requested result. If unable to complete, set success=false and explain what was completed, what blocked completion and what was tried. details must contain the requested facts, not only a page title; every value must match a whole current label or value. Declare answer.kind: action for a performed change, field for fixed values, list for requested entries. Read tasks must never use action. For field, items select current refs and label/value; when a field is combined into a label such as \"Capacity,90%\", use prefix \"Capacity,\" and suffix \"%\" to preserve the field identity while reading a new value. For list, items select all requested current rows in order with their names/times; start_ref and end_ref identify unique section labels immediately before and after those rows. Omit section refs if no reliable boundaries exist. Never invent refs or use a heading as a requested value.",
        schema: object([
            "success": ["type": "boolean"], "summary": string,
            "details": ["type": "array", "items": object(["label": string, "value": string], ["label", "value"])],
            "answer": object([
                "kind": ["type": "string", "enum": ["action", "field", "list"]],
                "items": ["type": "array", "items": object(["ref": string, "field": ["type": "string", "enum": ["label", "value"]], "prefix": string, "suffix": string], ["ref", "field"])],
                "start_ref": string, "end_ref": string,
            ], ["kind"]),
        ], ["success", "summary", "details", "answer"]))

    /// task-runner.mjs's answers to its harness tools.
    static let planPublished = "Plan published. Continue."
    static let resultRecorded = "Result recorded. Explain it briefly to the user."
    static let invalidPlan = "Invalid model plan"
    static let invalidResult = "Invalid task result"
}
