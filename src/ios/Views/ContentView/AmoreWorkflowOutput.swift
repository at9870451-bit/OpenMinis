import Foundation

extension Notification.Name {
    /// UI-only change; never sent to the model, export or audit pipeline.
    static let amoreWorkflowOutputDidChange = Notification.Name("amore.workflow.hideOutput.changed")
}

/// Settings integration: bind to `isHidden` via `setHidden(_:)`, or write `key`
/// then post `amoreWorkflowOutputDidChange`. Default false; no VM state needed.
/// Does not modify the existing chat.foldConsecutiveTools / auto-expand choices.
enum AmoreWorkflowOutput {
    static let key = "amore.workflow.hideOutput"
    static var isHidden: Bool { UserDefaults.standard.bool(forKey: key) }

    @MainActor
    static func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        UserDefaults.standard.set(hidden, forKey: key)
        NotificationCenter.default.post(name: .amoreWorkflowOutputDidChange, object: nil)
    }

    /// Pure planning: user/final text, failures, cancellations, pending tools,
    /// info and approval/delegation cards are barriers. Running tool capsules
    /// already show concise status and retain their tappable output detail.
    static func ranges(_ inputs: [ToolFoldPlanner.Input]) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        var start: Int?
        func close(at end: Int) {
            if let first = start { ranges.append(first...end) }
            start = nil
        }
        for (i, input) in inputs.enumerated() {
            switch input {
            case .thinking, .note, .tool(.succeeded):
                if start == nil { start = i }
            default:
                close(at: i - 1)
            }
        }
        close(at: inputs.count - 1)
        return ranges
    }

    /// Reuse the production FoldedRun and .toolGroup mapping so height estimate,
    /// self-sizing, expansion, anchoring and content keys stay on one path.
    /// Nothing is removed from messages, agentHistory, memory, export or DB.
    static func foldedRuns(in blocks: [AssistantBlock]) -> [ToolFoldPlanner.FoldedRun] {
        ranges(ToolFoldPlanner.inputs(for: blocks)).map { range in
            let members = blocks[range]
            let first = members[members.startIndex]
            let tools = members.filter { if case .tool(.succeeded) = ToolFoldPlanner.input(for: $0) { return true }; return false }
            let durations = tools.compactMap(\.toolDuration)
            return ToolFoldPlanner.FoldedRun(
                key: "workflow:" + (first.toolUseId ?? first.id.uuidString),
                firstBlockId: first.id, memberIds: members.map(\.id),
                group: ToolFoldPlanner.Group(range: range, toolCount: tools.count,
                                             failedCount: 0, cancelledCount: 0),
                duration: durations.isEmpty ? nil : durations.reduce(0, +))
        }
    }
}
