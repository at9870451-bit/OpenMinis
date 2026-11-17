import XCTest
@testable import PokiCore

/// The way of asking an owner finds after updating over 0.3.1 (752) or the test build that followed it,
/// for everything the phone can hold. 0.3.1 asked the owner for every message, call and password unless
/// Ask Me was off (nothing was asked) or the auto-classifier on (the model judged, at the sensitivity
/// picked for it, Balanced until one was). The test build kept its own choice in "approvals.mode", where
/// 0.3.0 had kept one 0.3.1 ignored. An update must not ask less than either, and a value that cannot be
/// read asks the most.
final class ApprovalChoiceTests: XCTestCase {
    /// How a message, a call or a password is asked about in Poki's own chat, least first: not at all,
    /// by the model at a sensitivity (its index, least asking first; a model's no going to the owner's
    /// card before one the agent asks about in words), or on the owner's card every time.
    enum Asking: Comparable { case nothing, model(Int), owner }

    static func asking(_ mode: ApprovalMode, _ level: ApprovalLevel) -> Asking {
        switch (mode, level) {
        case (.off, _): .nothing
        case (.confirm, .everything): .owner
        case (_, .permissive): .model(0 + (mode == .confirm ? 1 : 0))
        case (_, .balanced): .model(2 + (mode == .confirm ? 1 : 0))
        case (_, .strict): .model(4 + (mode == .confirm ? 1 : 0))
        case (_, .everything): .model(6)
        }
    }

    /// 0.3.1 as its code reads the same keys: `bool(forKey:)` for the classifier, Ask Me on unless it
    /// holds false, and the classifier's three sensitivities with Balanced for anything else.
    static func asked752(ask: Bool?, classifier: Bool?, level: String?) -> Asking {
        if classifier == true { return .model([0, 2, 4][["permissive": 0, "balanced": 1, "strict": 2][level ?? ""] ?? 1]) }
        return ask == false ? .nothing : .owner
    }

    /// The test build as its code reads the same keys: its choice in "approvals.mode" when it knows the
    /// word, else 0.3.1's switches with a sensitivity a classifier turned off again left saved; the
    /// sensitivity saved when it knows it, else Balanced once a choice or the classifier was made and
    /// Ask for Everything before.
    static func askedTestBuild(_ saved: [String: Any]) -> Asking {
        let chose = saved["approvals.mode"] != nil || saved["approvals.classifier"] as? Bool == true
        let level = (saved["approvals.classifier.level"] as? String).flatMap(ApprovalLevel.init) ?? (chose ? .balanced : .everything)
        if let mode = (saved["approvals.mode"] as? String).flatMap(ApprovalMode.init) { return asking(mode, level) }
        if saved["approvals.classifier"] as? Bool == true { return asking(.reply, level) }
        return asking(saved["approvals.ask"] as? Bool ?? true ? .confirm : .off, level)
    }

    func testAnUpdateOver752NeverAsksLess() {
        for ask in [nil, true, false] as [Bool?] {
            for classifier in [nil, true, false] as [Bool?] {
                for level in [nil, "permissive", "balanced", "strict", "everything", "loud"] as [String?] {
                    // What 0.3.0 or the test build saved, which 0.3.1 ignored; then a word nobody knows,
                    // and a value that is not a word.
                    for left in [nil, "reply", "confirm", "off", "sometimes", 1] as [Any?] {
                        var saved: [String: Any] = [:]
                        saved["approvals.ask"] = ask
                        saved["approvals.classifier"] = classifier
                        saved["approvals.classifier.level"] = level
                        if let left { saved["approvals.mode"] = left }
                        let now = ApprovalChoice.resolve { saved[$0] }
                        let asked = Self.asking(now.mode, now.level)
                        // An owner who saved nothing at all was never asked a question: Never Ask is the default.
                        if saved.isEmpty { XCTAssertEqual(now.mode, .off, "a phone that saved nothing"); continue }
                        let owner = "ask \(ask.map(String.init) ?? "unset"), classifier \(classifier.map(String.init) ?? "unset"), sensitivity \(level ?? "unset"), approvals.mode \(left.map { "\($0)" } ?? "unset"): \(now)"
                        XCTAssertGreaterThanOrEqual(asked, Self.asked752(ask: ask, classifier: classifier, level: level), "asks less than 0.3.1 did: " + owner)
                        // An owner who chose in the test build saw that choice and was asked by it.
                        if left != nil { XCTAssertGreaterThanOrEqual(asked, Self.askedTestBuild(saved), "asks less than the test build did: " + owner) }
                    }
                }
            }
        }
    }

    func testWhereEachOwnerLands() {
        let rows: [(name: String, saved: [String: Any], mode: ApprovalMode, level: ApprovalLevel)] = [
            ("never chose", [:], .off, .everything),
            ("updated from a version that saved only unrelated settings", ["wantsOn": true, "idleStopSeconds.v4": 120], .off, .everything),
            ("turned Ask Me on", ["approvals.ask": true], .confirm, .everything),
            ("saved a sensitivity and nothing else", ["approvals.classifier.level": "strict"], .confirm, .everything),
            ("turned the classifier off", ["approvals.classifier": false], .confirm, .everything),
            ("turned Ask Me off", ["approvals.ask": false], .off, .everything),
            ("turned the classifier on", ["approvals.classifier": true], .reply, .balanced),
            ("turned the classifier on at Strict", ["approvals.ask": true, "approvals.classifier": true, "approvals.classifier.level": "strict"], .reply, .strict),
            ("tried the classifier at Strict, then turned it off", ["approvals.ask": true, "approvals.classifier": false, "approvals.classifier.level": "strict"], .confirm, .everything),
            ("chose in 0.3.0, which 0.3.1 ignored: 0.3.1's every step is stricter", ["approvals.mode": "reply", "approvals.classifier.level": "permissive"], .confirm, .everything),
            ("turned Ask Me off, then chose With Confirmation at Strict in the test build", ["approvals.ask": false, "approvals.mode": "confirm", "approvals.classifier.level": "strict"], .confirm, .strict),
            ("turned Ask Me off, then chose With Message Reply in the test build", ["approvals.ask": false, "approvals.mode": "reply"], .reply, .balanced),
            ("turned the classifier on, then chose With Confirmation at Ask for Everything in the test build", ["approvals.classifier": true, "approvals.mode": "confirm", "approvals.classifier.level": "everything"], .confirm, .everything),
            ("chose Never Ask in the test build with Ask Me on", ["approvals.ask": true, "approvals.mode": "off", "approvals.classifier.level": "strict"], .confirm, .everything),
            ("a choice in approvals.mode nobody knows, Ask Me off", ["approvals.ask": false, "approvals.mode": "sometimes"], .confirm, .everything),
            ("a sensitivity nobody knows, classifier on", ["approvals.classifier": true, "approvals.classifier.level": "loud"], .reply, .everything),
            ("chose here", [ApprovalChoice.modeKey: "reply", "approvals.classifier.level": "strict"], .reply, .strict),
            ("chose Never Ask here", [ApprovalChoice.modeKey: "off", "approvals.ask": true], .off, .everything),
            ("a way of asking nobody knows", [ApprovalChoice.modeKey: "sometimes", "approvals.classifier.level": "permissive", "approvals.ask": false], .confirm, .everything),
        ]
        for row in rows {
            let now = ApprovalChoice.resolve { row.saved[$0] }
            XCTAssertEqual(now.mode, row.mode, row.name)
            XCTAssertEqual(now.level, row.level, row.name)
        }
    }
}
