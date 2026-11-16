import SwiftUI

private let confirmSheetLogger = AppLogger(category: "ConfigConfirmSheet")

/// The user-facing sheet that gates every minis-config write.
///
/// Mounted at app root; observes ConfigConfirmationGate.shared.pending
/// and presents a sheet whenever a change is queued. Users can:
///   • toggle approval per-row
///   • tap "Apply" (writes the approved subset)
///   • tap "Cancel" (rejects the entire batch)
/// Auto-dismisses after the gate's 30 s timeout fires (gate sets
/// outcome = .timedOut → pending becomes nil shortly after via the
/// resolve path).
struct ConfigConfirmSheet: View {
    @ObservedObject var gate: ConfigConfirmationGate
    /// Local mirror of the change's items so per-row toggles update
    /// immediately even though the underlying object is in a separate
    /// observable. We sync the toggles back when the user taps Apply.
    @State private var workingItems: [PendingConfigChangeItem] = []

    var body: some View {
        if let change = gate.pending {
            sheetBody(change: change)
                .onAppear {
                    workingItems = change.items
                    confirmSheetLogger.info("appear id=\(change.id) items=\(workingItems.count) approved=\(approvedCount)")
                }
                .onChange(of: change.id) { _ in
                    workingItems = change.items
                    confirmSheetLogger.info("change id=\(change.id) items=\(workingItems.count) approved=\(approvedCount)")
                }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func sheetBody(change: PendingConfigChange) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let caption = change.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(PokiTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                List {
                    Section {
                        ForEach($workingItems) { $item in
                            ConfigConfirmRow(item: $item)
                                .listRowBackground(PokiTheme.surface)
                                .listRowSeparatorTint(PokiTheme.divider)
                        }
                    }
                    // [T-config-readable] Batch summary: the readable sentences
                    // of the rows still switched on, grouped by the record they
                    // touch. Updates live as rows are toggled.
                    if workingItems.count > 1, !summaryLines.isEmpty {
                        Section {
                            ForEach(Array(summaryLines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(verbatim: "•")
                                        .foregroundStyle(PokiTheme.secondaryText)
                                    Text(verbatim: line)
                                        .font(.subheadline)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } header: {
                            Text("Summary of approved changes")
                                .foregroundStyle(PokiTheme.secondaryText)
                        }
                        .listRowBackground(PokiTheme.surface)
                        .listRowSeparatorTint(PokiTheme.divider)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .pokiScreen()
            .navigationTitle(workingItems.count > 1
                             ? "Confirm \(workingItems.count) changes"
                             : "Confirm change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) {
                        gate.userReject()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(approvedCount == 0 ? "Reject All" : "Apply") {
                        confirmSheetLogger.info("tap primary pending=\(change.id) items=\(workingItems.count) approved=\(approvedCount)")
                        gate.userApprove(items: workingItems)
                    }
                    .bold()
                    .tint(approvedCount == 0 ? PokiTheme.danger : PokiTheme.primaryButton)
                    .disabled(workingItems.isEmpty)
                }
            }
        }
        .presentationDetents([.fraction(0.75)])
        .interactiveDismissDisabled()    // force explicit Apply / Cancel
    }

    private var approvedCount: Int {
        workingItems.filter { $0.isApproved }.count
    }

    /// Approved rows' readable sentences, rows about the same record kept
    /// together (first-appearance order), global settings as their own group.
    private var summaryLines: [String] {
        var order: [String] = []
        var bySubject: [String: [String]] = [:]
        for item in workingItems where item.isApproved {
            guard let r = item.readable else { continue }
            let key = r.subject ?? "~global"
            if bySubject[key] == nil { order.append(key) }
            bySubject[key, default: []].append(contentsOf: r.displayText.components(separatedBy: "\n"))
        }
        return order.flatMap { bySubject[$0] ?? [] }
    }
}

/// [T-config-readable] Hairline between a change's raw values (path, old →
/// new) and its readable sentence. System separator color: legible in light
/// and dark mode without competing with the row separators between items.
struct ConfigReadableDivider: View {
    var body: some View {
        Rectangle()
            .fill(PokiTheme.divider)
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }
}

private struct ConfigConfirmRow: View {
    @Binding var item: PendingConfigChangeItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.verb.uppercased())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(verbForeground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(verbBackground, in: Capsule())
                Text(item.displayName)
                    .font(.system(.body, design: .default))
                    .foregroundStyle(PokiTheme.primaryText)
                Spacer()
                Toggle("", isOn: $item.isApproved)
                    .tint(PokiTheme.tagText)
                    .labelsHidden()
                    .scaleEffect(0.85)
            }
            Text(item.path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(PokiTheme.secondaryText)
            HStack(alignment: .top, spacing: 6) {
                if !item.oldDisplay.isEmpty {
                    Text(item.oldDisplay)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(PokiTheme.secondaryText)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(PokiTheme.secondaryText.opacity(0.75))
                }
                if !item.newDisplay.isEmpty {
                    Text(item.newDisplay)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(item.risk == .destructive ? PokiTheme.danger
                                         : item.risk == .sensitive ? PokiTheme.tagText
                                         : PokiTheme.primaryText)
                        .fontWeight(.medium)
                }
            }
            .font(.system(.footnote, design: .monospaced))

            // [T-config-readable] What the raw values above mean, in words,
            // set apart from them by a hairline. Both appear only together, so
            // a row without readable text never shows a stray line.
            if let readable = item.readable, !readable.displayText.isEmpty {
                ConfigReadableDivider()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "text.bubble")
                        .font(.caption)
                        .foregroundStyle(PokiTheme.secondaryText)
                    Text(verbatim: readable.displayText)
                        .font(.subheadline)
                        .foregroundStyle(PokiTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            if item.risk == .destructive {
                Label("This may affect later tool calls.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(PokiTheme.danger)
            } else if item.risk == .sensitive {
                Label("Reversible, but worth a quick look.", systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(PokiTheme.tagText)
            }
        }
        .padding(.vertical, 4)
        .opacity(item.isApproved ? 1.0 : 0.45)
    }

    private var verbForeground: Color {
        switch item.verb.lowercased() {
        case "remove", "delete": return PokiTheme.danger
        case "hide": return PokiTheme.secondaryText
        default: return PokiTheme.tagText
        }
    }

    private var verbBackground: Color {
        switch item.verb.lowercased() {
        case "remove", "delete": return PokiTheme.danger.opacity(0.12)
        case "hide": return PokiTheme.surface
        default: return PokiTheme.tagBackground
        }
    }
}
