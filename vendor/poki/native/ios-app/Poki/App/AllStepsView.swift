import SwiftUI

// MARK: All steps

/// Every recent step, newest first, on a white card (board 01, D).
struct AllStepsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if rows.isEmpty {
                ContentUnavailableView("No Steps Yet", systemImage: "clock", description: Text("Steps from your agent appear here and on the Lock Screen."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in StepRow(row: row) }
                } header: {
                    if let first = model.recentSteps.first {
                        Text("\(Self.stepCount(model)). Started at \(first.at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocalization.locale))).")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppName.display(model.currentApp) ?? AppLocalization.text(LocalizedStringResource("History")))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "12 steps", or "12 steps, 1 missed".
    @MainActor static func stepCount(_ model: AppModel) -> String {
        let steps = model.recentSteps
        let missed = steps.filter { !$0.ok }.count
        let count = AppLocalization.text(LocalizedStringResource("\(steps.count + (model.activityText != "Idle" ? 1 : 0)) steps"))
        return missed == 0 ? count : AppLocalization.text(LocalizedStringResource("\(count), \(missed) missed"))
    }

    struct Row {
        var text: String
        var detail: String
        var failed: Bool
        var at: Date
    }

    /// The step under way (waiting for approval or working) first, then the finished ones.
    private var rows: [Row] {
        var out: [Row] = []
        if model.activityText != "Idle" {
            out.append(Row(text: model.activityText, detail: model.approvals.isEmpty ? AppLocalization.text(LocalizedStringResource("Working")) : AppLocalization.text(LocalizedStringResource("Waiting for Approval")),
                           failed: false, at: Date()))
        }
        for step in model.recentSteps.reversed() {
            let failure = step.failure.map { AppLocalization.bundle.localizedString(forKey: $0, value: $0, table: nil) }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
            out.append(Row(text: step.text, detail: failure ?? AppName.display(step.app) ?? AppLocalization.text(LocalizedStringResource("Done")), failed: !step.ok, at: step.at))
        }
        return out
    }
}

private struct StepRow: View {
    var row: AllStepsView.Row
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ActivityWords.label(row.text)).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(row.at, style: .time).font(.caption).monospacedDigit().foregroundStyle(Color(.secondaryLabel))
                }
                Text(row.detail).font(.footnote).foregroundStyle(row.failed ? Color.red : Color.secondary).lineLimit(2)
            }
        } icon: {
            Image(systemName: row.failed ? "xmark.circle.fill" : Self.symbol(for: row.text))
                .foregroundStyle(row.failed ? Color.red : Color.accentColor)
        }
    }

    static func symbol(for text: String) -> String {
        let verb = text.split(separator: " ").first.map(String.init) ?? ""
        switch verb {
        case "Tap": return "hand.tap"
        case "Press": return text.hasSuffix("button") ? "button.horizontal.top.press" : "keyboard"
        case "Type": return "character.cursor.ibeam"
        case "Swipe", "Scroll": return "hand.draw"
        case "Drag": return "hand.point.up.left"
        case "Zoom": return "arrow.up.left.and.arrow.down.right"
        case "Open": return "app.badge"
        case "Look": return "eye"
        case "Wait": return "hourglass"
        default: return "sparkles"
        }
    }
}
