import Foundation

/// What needs the owner's approval on the phone before it is sent. Words match whole words or
/// phrases, case-insensitively, in the label, value or identifier of the element an action touches: at
/// the start of the text, anywhere in a short one, or anywhere on an action button. A name inside a
/// longer text is not an action (seen on the phone: "Contact photo for Best Buy" was taken for a payment).
public struct SensitivityRules: Sendable, Equatable {
    public var secureFields = true
    public var payments: [String] = ["pay", "payment", "buy", "purchase", "subscribe", "checkout", "place order", "transfer", "send money", "confirm payment", "apple pay", "支付", "付款", "购买", "订阅", "转账", "确认支付", "下单", "購買", "訂閱", "轉賬", "轉帳", "確認支付", "下單"]
    public var deletions: [String] = ["delete", "remove", "erase", "reset", "delete all", "删除", "移除", "抹掉", "清空", "还原", "刪除", "還原"]
    public var sending: [String] = ["send", "post", "reply", "发送", "回复", "发布", "發送", "回覆", "發布"]
    /// Apps where every input needs approval (banking, wallets).
    public var guardedApps: [String] = ["com.apple.Passbook"]
    /// Words that place a call wherever they are tapped.
    public var calling: [String] = ["call", "拨打", "呼叫", "撥打"]
    /// Apps where tapping anything can place a call (a contact in Favorites or Recents rings it). FaceTime is
    /// here rather than a word: Settings lists a "FaceTime" row that places no call.
    public var callingApps: [String] = ["com.apple.mobilephone", "com.apple.facetime"]
    /// Apps where tapping a sending word needs approval.
    public var messagingApps: [String] = ["com.apple.MobileSMS", "com.apple.mobilemail", "com.tencent.xin", "net.whatsapp.WhatsApp", "ph.telegra.Telegraph", "com.burbn.instagram", "com.atebits.Tweetie2", "com.facebook.Messenger", "com.hammerandchisel.discord", "com.tinyspeck.chatlyio"]
    public var enabled = true
    public init() {}

    /// The rules a way of asking holds steps back by. Never asking lets typing a password, sending a
    /// message and placing a call go ahead; payments, deletions and Wallet still wait for the owner.
    public func asked(_ mode: ApprovalMode) -> SensitivityRules {
        guard mode == .off else { return self }
        var rules = self
        rules.secureFields = false
        rules.sending = []
        rules.messagingApps = []
        rules.calling = []
        rules.callingApps = []
        return rules
    }

    static func matches(_ text: String, _ words: [String], elementType: String = "Other") -> String? {
        let lowered = text.lowercased()
        // Preserve the base matcher’s whitespace-based short-label protection for every type.
        // Long Buttons and later whole-word matches add protection to that baseline.
        let short = lowered.split(whereSeparator: \.isWhitespace).count <= 4
        // Explicit exception agreed for this rule: digits also bound Latin words, so buy1/1pay
        // remain unmatched even though the original matcher treated digits as boundaries.
        let boundary: (Character?) -> Bool = { c in c.map { !$0.isLetter && !$0.isNumber } ?? true }
        for word in words {
            let w = word.lowercased()
            guard !w.isEmpty else { continue }
            var search = lowered.startIndex..<lowered.endIndex
            while let range = lowered.range(of: w, range: search) {
                // CJK words match anywhere; Latin words need whole-word boundaries.
                if w.unicodeScalars.contains(where: { $0.value > 0x2E80 }) { return word }
                let before = range.lowerBound == lowered.startIndex ? nil : lowered[lowered.index(before: range.lowerBound)]
                let after = range.upperBound == lowered.endIndex ? nil : lowered[range.upperBound]
                let opens = lowered[..<range.lowerBound].allSatisfy { !$0.isLetter && !$0.isNumber }
                if boundary(before) && boundary(after) && (elementType == "Button" || opens || short) { return word }
                // An earlier substring ("buying") must not hide a later whole word ("buy").
                search = range.upperBound..<lowered.endIndex
            }
        }
        return nil
    }

    /// Why this action needs approval, or nil.
    func reason(touching element: Element?, typing: Bool, app: Foreground?, secureOnScreen: Bool) -> String? {
        guard enabled else { return nil }
        if let bundle = app?.bundleID, guardedApps.contains(bundle) { return "input in \(app?.describe ?? bundle)" }
        if typing, secureFields, element?.isSecure == true || (element == nil && secureOnScreen) { return "typing into a password field" }
        guard !typing else { return nil }
        guard let element else {
            // A tap in Phone rings whatever it lands on, also where nothing can be read.
            if let bundle = app?.bundleID, callingApps.contains(bundle) { return "a call (in \(app?.describe ?? bundle))" }
            return nil
        }
        let texts = [element.text, element.identifier ?? ""]
        func match(_ words: [String]) -> String? {
            texts.lazy.compactMap { Self.matches($0, words, elementType: element.type) }.first
        }
        if let word = match(payments) { return "a payment (\"\(word)\")" }
        if let word = match(deletions) { return "deleting (\"\(word)\")" }
        if let bundle = app?.bundleID, callingApps.contains(bundle) { return "a call (in \(app?.describe ?? bundle))" }
        if let word = match(calling) { return "a call (\"\(word)\")" }
        if let bundle = app?.bundleID, messagingApps.contains(bundle), let word = match(sending) {
            return "sending a message (\"\(word)\")"
        }
        return nil
    }
}

/// How a tap sent outside `do` (`PokiCore.clearTap`) may go ahead. The associated text is the rule's reason.
public enum TapClearance: Sendable, Equatable {
    /// No rule asks for approval.
    case clear
    case approved(String)
    case declined(String)
    /// Nobody answered in time, or another request replaced it.
    case unanswered(String)
    /// The tap would land in Poki, where the approval card is; the text says so for the model.
    case refused(String)

    public var mayTap: Bool {
        switch self { case .clear, .approved: true; case .declined, .unanswered, .refused: false }
    }
}

public struct Approval: Sendable, Equatable {
    public var id: String
    public var app: String
    public var summary: String
    public var reason: String
    public var requested: Date
    public var expires: Date
    /// Turning asking off (Never Ask) would stop every step this approval covers from asking: the owner
    /// can be offered Don't Ask Again. False where a payment, a deletion, Wallet or a screen not read yet
    /// would still ask.
    public var stopsWhenOff = false
    /// The actions it covers, as a fingerprint: the same actions sent again run once it is granted.
    var fingerprint: String
    var workspaceSession: String?
}

/// Pending and granted approvals. At most one is pending; it is granted or declined only from the app
/// (the Live Activity). Every `do` and every voice tap (`PokiCore.clearTap`) withdraws it first, so a
/// press the automation lands afterwards finds nothing to grant. Both also refuse to tap in Poki when
/// they can tell it is in front.
final class Approvals: @unchecked Sendable {
    enum Decision: Sendable { case approved, declined, expired }
    private struct Entry {
        var approval: Approval
        var decision: Decision?
        var waiters: [UUID: CheckedContinuation<Decision?, Never>] = [:]
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    let lifetime: Double
    let emit: @Sendable (CoreEvent) -> Void

    init(lifetime: Double = 120, emit: @escaping @Sendable (CoreEvent) -> Void) {
        self.lifetime = lifetime
        self.emit = emit
    }

    /// Drops expired entries (under the lock); returns the pending ones that expired, for events.
    private func sweep(at date: Date = Date()) -> [Approval] {
        var expired: [Approval] = []
        for (id, entry) in entries where entry.approval.expires <= date {
            entries[id] = nil
            if entry.decision == nil {
                expired.append(entry.approval)
                entry.waiters.values.forEach { $0.resume(returning: .expired) }
            }
        }
        return expired
    }

    var pending: Approval? {
        lock.lock()
        let expired = sweep()
        let p = entries.values.first { $0.decision == nil }?.approval
        lock.unlock()
        expired.forEach { emit(.approvalEnded(id: $0.id, approved: nil)) }
        return p
    }

    /// A granted approval for exactly these actions, used up by this call.
    func consumeGrant(fingerprint: String, workspaceSession: String? = nil) -> Approval? {
        lock.lock()
        let expired = sweep()
        let found = entries.first {
            $0.value.approval.fingerprint == fingerprint && $0.value.approval.workspaceSession == workspaceSession && $0.value.decision == .approved
        }
        if let found { entries[found.key] = nil }
        lock.unlock()
        expired.forEach { emit(.approvalEnded(id: $0.id, approved: nil)) }
        return found?.value.approval
    }

    func request(app: String, summary: String, reason: String, fingerprint: String, workspaceSession: String? = nil, stopsWhenOff: Bool = false) -> Approval {
        let date = Date()
        let approval = Approval(id: String(UUID().uuidString.prefix(8)).lowercased(), app: app, summary: summary, reason: reason, requested: date, expires: date.addingTimeInterval(lifetime), stopsWhenOff: stopsWhenOff, fingerprint: fingerprint, workspaceSession: workspaceSession)
        lock.lock()
        // One pending at a time: a new request replaces an older one, which ends unanswered.
        let replaced = entries.values.filter { $0.decision == nil }
        for old in replaced {
            old.waiters.values.forEach { $0.resume(returning: .expired) }
            entries[old.approval.id] = nil
        }
        entries[approval.id] = Entry(approval: approval)
        lock.unlock()
        replaced.forEach { emit(.approvalEnded(id: $0.approval.id, approved: nil)) }
        emit(.approvalRequested(approval))
        // The request ends when its time is up even if no call comes to sweep it: the app holds its
        // card, the idle stop and Stop Runner until it hears so.
        Task { [weak self, lifetime] in
            await sleep(seconds: lifetime + 0.05)
            _ = self?.pending
        }
        return approval
    }

    /// Withdraws a pending approval (the agent moved on to something else).
    func withdraw(id: String) {
        lock.lock()
        guard let entry = entries[id], entry.decision == nil else { lock.unlock(); return }
        entries[id] = nil
        lock.unlock()
        entry.waiters.values.forEach { $0.resume(returning: .expired) }
        emit(.approvalEnded(id: id, approved: nil))
    }

    /// A local Split View task cannot carry a pending or granted decision across panes or tasks.
    func discardWorkspaceDecisions(session: String?) {
        guard let session else { return }
        lock.lock()
        let discarded = entries.values.filter { $0.approval.workspaceSession == session }
        for entry in discarded { entries[entry.approval.id] = nil }
        lock.unlock()
        for entry in discarded where entry.decision == nil {
            entry.waiters.values.forEach { $0.resume(returning: .expired) }
            emit(.approvalEnded(id: entry.approval.id, approved: nil))
        }
    }

    func resolve(id: String, approved: Bool) {
        lock.lock()
        guard var entry = entries[id], entry.decision == nil else { lock.unlock(); return }
        let decision: Decision = approved ? .approved : .declined
        let waiters = entry.waiters
        entry.decision = decision
        entry.waiters = [:]
        entries[id] = approved ? entry : nil
        lock.unlock()
        waiters.values.forEach { $0.resume(returning: decision) }
        emit(.approvalEnded(id: id, approved: approved))
    }

    /// Waits for the decision, at most `seconds`; nil when it is still pending then, or when the
    /// waiting task is cancelled (the caller gave up): the request itself stays for the owner.
    func wait(id: String, seconds: Double) async -> Decision? {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Decision?, Never>) in
                lock.lock()
                guard var entry = entries[id] else { lock.unlock(); continuation.resume(returning: .expired); return }
                if let decision = entry.decision { lock.unlock(); continuation.resume(returning: decision); return }
                guard !Task.isCancelled else { lock.unlock(); continuation.resume(returning: nil); return }
                entry.waiters[token] = continuation
                entries[id] = entry
                lock.unlock()
                Task {
                    await sleep(seconds: seconds)
                    self.takeWaiter(id: id, token: token)?.resume(returning: nil)
                }
            }
        } onCancel: {
            takeWaiter(id: id, token: token)?.resume(returning: nil)
        }
    }

    private func takeWaiter(id: String, token: UUID) -> CheckedContinuation<Decision?, Never>? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.waiters.removeValue(forKey: token)
    }
}
