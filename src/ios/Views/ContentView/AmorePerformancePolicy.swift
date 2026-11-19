import Foundation
import os.log

/// No classifier request and no keyword blacklist. Only a standalone greeting
/// in a fresh conversation gets a zero-tool budget; ambiguity keeps tools.
enum AmoreToolPolicy {
    static let noToolsThisTurn = "\n\nThis is a standalone greeting: answer normally and directly. No tools are provided for this turn; memory files were not loaded. The session's tool and memory preferences are unchanged."

    static let directAnswerRule = """
    Tool necessity (takes precedence over general encouragement to use tools):
    Answer greetings, casual conversation, translation, rewriting, explanations,
    and arithmetic on text supplied in the conversation directly. Do not call
    shell, browser, memory, or other tools merely to greet, think, or calculate
    simple supplied arithmetic. Do not look up memory just because a topic is new.
    Use tools when the user requests current/external information, verification,
    files, device state/control, or an external action, or when the task genuinely
    needs them. Consider the FULL conversation: short follow-ups such as 'continue'
    or '继续' can refer to an unfinished tool task and are not casual conversation.
    Never claim an external action or verification occurred without its result.
    """

    static func omitsTools(text: String, priorMessageCount: Int,
                           hasAttachments: Bool, hasPendingApproval: Bool,
                           isHelper: Bool, isResuming: Bool) -> Bool {
        guard priorMessageCount == 0, !hasAttachments, !hasPendingApproval,
              !isHelper, !isResuming else { return false }
        let greeting = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "!！.。?？～~"))
        return ["hi", "hello", "hey", "你好", "您好", "嗨", "哈喽", "哈囉", "早上好", "晚上好"].contains(greeting)
    }
}

/// Instruments has real elapsed intervals, not advertised/fabricated timings.
/// Never logs prompt text, output, arguments or credentials.
enum AmorePerformanceTrace {
    static let log = OSLog(subsystem: "com.amore.performance", category: .pointsOfInterest)
    private static let lock = NSLock()
    private static var firstToolClaimed = false

    static func beginFirstTool() -> OSSignpostID? {
        lock.lock()
        let first = !firstToolClaimed
        firstToolClaimed = true
        lock.unlock()
        guard first else { return nil }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "FirstTool", signpostID: id)
        return id
    }

    static func endFirstTool(_ id: OSSignpostID) {
        os_signpost(.end, log: log, name: "FirstTool", signpostID: id)
    }

    @MainActor private static var launchID: OSSignpostID?
    @MainActor static func beginColdLaunch() {
        guard launchID == nil else { return }
        let id = OSSignpostID(log: log)
        launchID = id
        os_signpost(.begin, log: log, name: "ColdLaunchToContent", signpostID: id)
    }
    @MainActor static func endColdLaunch() {
        guard let id = launchID else { return }
        os_signpost(.end, log: log, name: "ColdLaunchToContent", signpostID: id)
        launchID = nil
    }
}

/// Process-wide single flight covers install + native boot + hooks + overlay.
/// Constructing this actor has NO disk I/O and never boots the guest. A failed
/// flight is cleared; only complete readiness may enter the hot cache.
actor AmoreKernelReadiness {
    static let shared = AmoreKernelReadiness()
    private var flight: Task<Void, Error>?
    private var ready = false

    func ensureReady() async throws {
        try Task.checkCancellation()
        guard !RootfsManager.shared.didResetWhileBooted else {
            throw Self.failure("The Linux environment was reset. Please restart the app before using tools.")
        }
        if ready { return }
        if let flight {
            try await flight.value
            try Task.checkCancellation()
            return
        }
        // Not a child of one tool's cancellation: concurrent waiters share it.
        // Stop still prevents the cancelled caller from executing after ready.
        let task = Task.detached(priority: .userInitiated) {
            guard RootfsOperationGate.shared.begin() else {
                throw Self.failure("Another container operation is running. Try again after it finishes.")
            }
            defer { RootfsOperationGate.shared.end() }
            let id = OSSignpostID(log: AmorePerformanceTrace.log)
            os_signpost(.begin, log: AmorePerformanceTrace.log, name: "KernelReady", signpostID: id)
            defer { os_signpost(.end, log: AmorePerformanceTrace.log, name: "KernelReady", signpostID: id) }
            if !ISHKernel.shared.isBooted {
                os_signpost(.begin, log: AmorePerformanceTrace.log, name: "RootfsInstall", signpostID: id)
                do {
                    try RootfsManager.shared.installIfNeeded()
                } catch {
                    os_signpost(.end, log: AmorePerformanceTrace.log, name: "RootfsInstall", signpostID: id)
                    throw error
                }
                os_signpost(.end, log: AmorePerformanceTrace.log, name: "RootfsInstall", signpostID: id)
            }
            // become_first_process pins PID 1 to the calling pthread. Preserve
            // its stable main-thread affinity rather than running it on an
            // arbitrary Swift cooperative worker. Install/overlay I/O is off main.
            try await MainActor.run {
                guard !RootfsManager.shared.didResetWhileBooted else {
                    throw Self.failure("The Linux environment was reset. Please restart the app before using tools.")
                }
                if !ISHKernel.shared.isBooted {
                    os_signpost(.begin, log: AmorePerformanceTrace.log, name: "NativeKernelBoot", signpostID: id)
                    let code = ISHKernel.shared.boot(withRootPath: RootfsManager.shared.rootfsPath.path)
                    os_signpost(.end, log: AmorePerformanceTrace.log, name: "NativeKernelBoot", signpostID: id)
                    guard code >= 0 else { throw Self.failure("Kernel boot failed: \(code)") }
                }
                installSessionFileChangeTracker(kernel: ISHKernel.shared)
                MinisFsRouter.shared.installHook()
            }
            guard RootfsManager.shared.applyDefaultMountOverlay() else {
                throw Self.failure("The Linux environment overlay could not be prepared. Try again.")
            }
        }
        flight = task
        do {
            try await task.value
            ready = true
            flight = nil
        } catch {
            ready = false
            flight = nil
            throw error
        }
        try Task.checkCancellation()
    }

    private nonisolated static func failure(_ message: String) -> NSError {
        NSError(domain: "Amore.KernelReadiness", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
