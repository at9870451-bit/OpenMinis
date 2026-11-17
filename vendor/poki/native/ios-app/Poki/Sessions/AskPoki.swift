import Foundation
import PokiCore

/// `ask_poki`: an outside agent (Claude, Codex, any MCP client) hands a whole task to Poki's own agent,
/// which runs it on this iPhone with the owner's model (their key or ChatGPT sign-in) and answers with
/// the result. The agent can still call look and do itself; this is the other way of working. It is
/// listed only once the owner has set up a model, and it waits while the owner's own chat runs a task.
@MainActor
enum AskPoki {
    static let schema = #"{"type":"object","properties":{"task":{"type":"string","description":"What to do on the iPhone, in plain words, as you would ask a person. Include every detail Poki needs (names, text to type); Poki cannot ask you back."},"check":{"type":"boolean","description":"true: no new task; answer with the result of the task you handed over earlier, or say it is still running."}},"additionalProperties":false}"#

    static let description = "Hand a REPETITIVE phone task to Poki, the small agent on this iPhone: something the owner does often (the same order, the same message, the same settings), ideally one Poki already has a saved routine for (routines {action: \"list\"} shows them). Poki repeats it by itself with the owner's own model, which is quicker but less capable than you, and answers with the result. For anything new, unusual or tricky, drive the phone yourself with look and do; when that worked and could come again, save it with routines {action: \"save\", name, description} so Poki (and ask_poki) can repeat it next time. One task at a time. A task can take minutes: when it is not done before your call would time out, the answer says it is still working, and you call ask_poki with {\"check\": true} a little later for the result."

    private(set) static weak var app: AppModel?
    /// The owner's chat (the Debug probe's `chat` mode sends to it).
    private(set) static weak var chat: ChatModel?
    private static var running: [String: ChatModel] = [:]
    /// Hand-offs by the requester's session: the task under way, then its answer until it is read.
    private static var jobs: [String: Task<(text: String, success: Bool?), Never>] = [:]

    static func install(app: AppModel, chat: ChatModel) {
        self.app = app
        self.chat = chat
        refresh()
        NotificationCenter.default.addObserver(forName: ModelKeys.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { refresh() }
        }
    }

    /// Listed when the chosen model is set up; unlisted otherwise.
    /// Diagnostics → Testing → ask_poki: off by default in the alpha (outside agents drive with look and do).
    static let onKey = "askPoki.on"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: onKey) }

    static func refresh() {
        guard let app else { return }
        guard isOn else { app.setHostTools([]); return }
        guard ModelKeys.hasUsableKey || ModelKeys.selectedProvider == .custom && !ModelKeys.customURL.isEmpty else { app.setHostTools([]); return }
        app.setHostTools([HostTool(name: "ask_poki", description: description, schemaJSON: schema) { arguments, session, timeLeft in
            await run(arguments: arguments, session: session, timeLeft: timeLeft)
        }])
    }

    static func run(arguments: String, session: String?, timeLeft: Double? = nil) async -> PokiCore.ToolAnswer {
        let args = (arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        let key = session ?? "local"
        if args["check"] as? Bool == true {
            guard let job = jobs[key] else {
                return PokiCore.ToolAnswer(text: "nothing pending: no task was handed to Poki in this session, or its result was already given", jpeg: nil, isError: false)
            }
            return await answer(job, key: key, within: timeLeft)
        }
        guard let task = (args["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
            return PokiCore.ToolAnswer(text: "error: task is empty; nothing was done", jpeg: nil, isError: true)
        }
        guard let app else { return PokiCore.ToolAnswer(text: "error: Poki is not ready", jpeg: nil, isError: true) }
        if chat?.running == true || ChatModel.delegatedBusy != nil || !running.isEmpty {
            return PokiCore.ToolAnswer(text: "busy: Poki's agent is already working on a task on this iPhone; nothing was done. Try again in a minute, or use look and do.", jpeg: nil, isError: true)
        }
        let store = SessionStore.shared
        let requester = store.client(of: session)
        let id = store.handoffID(for: session)
        let handoff = ChatModel(app: app, kind: .handoff, requester: requester, sessionID: id)
        running[id] = handoff
        AppLog.shared.add("chat", "\(requester) handed a task to Poki (\(task.count) characters)")
        jobs[key] = Task { @MainActor in
            let result = await handoff.runDelegated(task)
            running[id] = nil
            return result
        }
        return await answer(jobs[key]!, key: key, within: timeLeft)
    }

    /// The task's answer when it ends within `seconds` (nil: however long it takes), else "still working".
    private static func answer(_ job: Task<(text: String, success: Bool?), Never>, key: String, within seconds: Double?) async -> PokiCore.ToolAnswer {
        let result: (text: String, success: Bool?)?
        if let seconds {
            // Whichever comes first: the task's end or the caller's deadline (the task goes on either way).
            result = await withCheckedContinuation { continuation in
                let once = Once(continuation)
                Task { @MainActor in once.resume(await job.value) }
                Task { @MainActor in try? await Task.sleep(for: .seconds(seconds)); once.resume(nil) }
            }
        } else {
            result = await job.value
        }
        guard let result else {
            return PokiCore.ToolAnswer(text: "working: Poki is still on the task. Call ask_poki with {\"check\": true} in a minute for the result.", jpeg: nil, isError: false)
        }
        jobs[key] = nil
        return PokiCore.ToolAnswer(text: result.text, jpeg: nil, isError: false)
    }

    /// The hand-off running in this session, for its live transcript.
    static func live(_ id: String) -> ChatModel? { running[id] }

    /// The session of the hand-off under way, if one is.
    static var liveSessionID: String? { running.keys.first }
}

/// Resumes a continuation once; later answers are dropped.
@MainActor
private final class Once {
    private var continuation: CheckedContinuation<(text: String, success: Bool?)?, Never>?
    init(_ continuation: CheckedContinuation<(text: String, success: Bool?)?, Never>) { self.continuation = continuation }
    func resume(_ value: (text: String, success: Bool?)?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
