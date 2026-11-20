import Foundation

/// Shared UI/core API. Main-agent ToolDefinitions, AgentLoop and the central
/// ConcurrentTools dispatcher must use this exact session-scoped read. All
/// tools are forbidden when true, including device_control and unknown names.
enum AmorePureChatMode {
    static func isEnabled(
        sessionID: String?, draftID: String?, defaults: UserDefaults = .standard
    ) -> Bool {
        ChatExecutionModePolicy.mode(sessionId: sessionID, draftId: draftID, defaults: defaults) == .pureChat
    }

    /// The caller supplies the current processing state; the UI does not
    /// change modes mid-turn. A missing core execution gate rejects entry.
    @discardableResult
    static func setEnabled(
        _ enabled: Bool,
        sessionID: String?, draftID: String?,
        isBusy: Bool = false,
        defaults: UserDefaults = .standard,
        gateInstalled: Bool = ChatExecutionModePolicy.executionGateInstalled
    ) -> ChatExecutionModePolicy.ChangeResult {
        ChatExecutionModePolicy.requestChange(
            to: enabled ? .pureChat : .agent,
            sessionId: sessionID, draftId: draftID,
            isBusy: isBusy, defaults: defaults, gateInstalled: gateInstalled)
    }
}

/// A conversation's execution policy, not a model or a new agent identity.
/// The existing model selection, message history, streaming and memory setting
/// remain unchanged when this value changes.
enum ChatExecutionMode: String, Equatable {
    case agent
    case pureChat
}

enum ChatExecutionModePolicy {
    private static let keyPrefix = "chat.executionMode.v1."

    /// IMPORTANT: Keep false until the AgentLoop advertisement AND the central
    /// executeSingleToolUse dispatch have both been wired to this policy. An
    /// attractive menu switch with a working tool executor is unsafe. The
    /// integrator should set this to true ONLY after both checks are tested.
    static let executionGateInstalled = true

    enum ChangeResult: Equatable {
        case changed
        case unchanged
        case busy
        case unavailable
        case gateNotInstalled
    }

    private static func key(_ id: String) -> String { keyPrefix + id }

    /// The real session takes precedence; a pre-send draft override follows
    /// its first message into the real session. This migration is synchronous
    /// and idempotent so it also works when the agent starts before a view
    /// refresh after ensureSession(). No global mode and no implicit inheritance
    /// to a fresh draft or an unrelated conversation.
    static func mode(sessionId: String?, draftId: String?, defaults: UserDefaults = .standard) -> ChatExecutionMode {
        if let sessionId, !sessionId.isEmpty {
            let realKey = key(sessionId)
            if let draftId, !draftId.isEmpty, draftId != sessionId {
                let draftKey = key(draftId)
                if defaults.object(forKey: realKey) == nil,
                   let draftMode = defaults.string(forKey: draftKey) {
                    defaults.set(draftMode, forKey: realKey)
                }
                defaults.removeObject(forKey: draftKey)
            }
            return decode(defaults.object(forKey: realKey))
        }
        guard let draftId, !draftId.isEmpty else { return .agent }
        return decode(defaults.object(forKey: key(draftId)))
    }

    private static func decode(_ value: Any?) -> ChatExecutionMode {
        guard let value else { return .agent } // Existing sessions keep Agent mode.
        // Unknown or corrupted *stored* modes must not silently enable tools.
        return (value as? String).flatMap(ChatExecutionMode.init(rawValue:)) ?? .pureChat
    }

    /// Refuse a switch while any turn is in flight; never cancel it, never
    /// promise retroactive enforcement. Caller shows a visible message.
    @discardableResult
    static func requestChange(
        to target: ChatExecutionMode,
        sessionId: String?, draftId: String?,
        isBusy: Bool,
        defaults: UserDefaults = .standard,
        gateInstalled: Bool = executionGateInstalled
    ) -> ChangeResult {
        guard !isBusy else { return .busy }
        guard let id = sessionId ?? draftId, !id.isEmpty else { return .unavailable }
        // Exit is always allowed (and explicit); entry is never offered while
        // its fail-closed core dispatch has not been integrated.
        guard target != .pureChat || gateInstalled else { return .gateNotInstalled }
        guard mode(sessionId: sessionId, draftId: draftId, defaults: defaults) != target else { return .unchanged }
        defaults.set(target.rawValue, forKey: key(id))
        return .changed
    }

    /// The core must use this BEFORE dispatch, including concurrent calls,
    /// stale model tool_use, resumed turns and subagent/MCP/device requests.
    /// No allowlist: all names are denied in pure chat, even future tools.
    static func permitsTool(named name: String, mode: ChatExecutionMode) -> Bool {
        mode == .agent
    }

    /// The same policy must suppress ALL tool definitions sent to providers.
    static func advertisedTools<T>(_ tools: [T], mode: ChatExecutionMode) -> [T] {
        mode == .agent ? tools : []
    }

    /// Append after other system-prompt fragments in pure chat only. Existing
    /// history and enabled memory context may still be supplied as passive
    /// context; this forbids running tools (including memory writes/reads).
    static let pureChatInstruction = """
    This conversation is in Pure Chat Mode. Respond directly in text, like a consumer chat assistant. \
    Do not request, simulate, delegate, or execute any device, computer, browser, file, MCP, memory, or other tools. \
    You may use conversation history and memory already included in context; do not read or write memory with tools. \
    If an action requires a tool, explain briefly that the user can switch back to Amore Agent using the … menu. \
    This mode does not change your model, personality, or the user's existing memory preference.
    """
}
