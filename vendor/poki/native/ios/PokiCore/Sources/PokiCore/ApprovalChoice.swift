import Foundation

/// How the owner answers a step the rules hold back that is not a payment, a deletion or Wallet:
/// in words in Poki's chat, on an Allow card, or not at all (the app's Approvals page).
public enum ApprovalMode: String, CaseIterable, Identifiable, Sendable {
    case reply, confirm, off
    public var id: String { rawValue }
}

/// How readily the chat model lets such a step through before the owner is asked, least asking first.
public enum ApprovalLevel: String, CaseIterable, Identifiable, Sendable {
    case permissive, balanced, strict, everything
    public var id: String { rawValue }
}

/// The way of asking saved on the phone, from the keys each version of the app wrote. Nothing saved
/// at all is Never Ask: a new install, and an owner who never touched Approvals, are not asked. Past
/// that, an update never asks less than the version it replaces, and a value that cannot be read asks
/// the most: With Confirmation at Ask for Everything, an Allow card for every step.
public enum ApprovalChoice {
    /// This version's choice.
    public static let modeKey = "approvals.mode.v2"
    /// The choice 0.3.0 and the test build after 0.3.1 kept. 0.3.1 ignored it and asked as its
    /// switches said, so an owner with both is asked as the stricter of the two.
    public static let earlierModeKey = "approvals.mode"
    /// Saved with the way of asking here and in the test build, and by 0.3.1's auto-classifier and
    /// 0.3.0 before that.
    public static let levelKey = "approvals.classifier.level"
    /// 0.3.1's two switches: Ask Me (on unless turned off) and the auto-classifier (a test, off
    /// unless turned on).
    public static let askKey = "approvals.ask"
    public static let classifierKey = "approvals.classifier"
    private static let allKeys = [modeKey, earlierModeKey, levelKey, askKey, classifierKey]

    /// `saved` reads a key as UserDefaults stores it.
    public static func resolve(_ saved: (String) -> Any?) -> (mode: ApprovalMode, level: ApprovalLevel) {
        // Reading the keys is the only record of a choice, so there is nothing to migrate or mark: an owner
        // who saves one (here, or on a version that wrote one of these) is read by the rules below, and
        // everyone else stays here.
        if allKeys.allSatisfy({ saved($0) == nil }) { return (.off, .everything) }
        let level = saved(levelKey)
        if let mode = saved(modeKey) {
            guard let mode = (mode as? String).flatMap(ApprovalMode.init) else { return (.confirm, .everything) }
            return (mode, (level as? String).flatMap(ApprovalLevel.init) ?? .everything)
        }
        let switches = switches752(saved)
        guard let earlier = saved(earlierModeKey) else { return switches }
        guard let mode = (earlier as? String).flatMap(ApprovalMode.init) else { return (.confirm, .everything) }
        // The test build showed Balanced for a choice made before any sensitivity was.
        let chosen = (mode, level == nil ? .balanced : (level as? String).flatMap(ApprovalLevel.init) ?? .everything)
        return asking(chosen) > asking(switches) ? chosen : switches
    }

    /// What 0.3.1's switches did.
    static func switches752(_ saved: (String) -> Any?) -> (mode: ApprovalMode, level: ApprovalLevel) {
        // The auto-classifier on: the model judged every step, at the sensitivity picked there,
        // Balanced until one was.
        if saved(classifierKey) as? Bool == true {
            guard let level = saved(levelKey) else { return (.reply, .balanced) }
            return (.reply, (level as? String).flatMap(ApprovalLevel.init) ?? .everything)
        }
        // Otherwise Ask Me off asked nothing and Ask Me on the owner for every step, whatever
        // sensitivity a classifier turned off again left saved.
        return (saved(askKey) as? Bool == false ? .off : .confirm, .everything)
    }

    /// How much a way of asking asks, least first: never; the model at a sensitivity, a no it gives
    /// going to the owner's card before one the agent asks about in words; the owner's card for
    /// every step.
    static func asking(_ choice: (mode: ApprovalMode, level: ApprovalLevel)) -> Int {
        guard choice.mode != .off else { return 0 }
        return 1 + 2 * ApprovalLevel.allCases.firstIndex(of: choice.level)! + (choice.mode == .confirm ? 1 : 0)
    }
}
