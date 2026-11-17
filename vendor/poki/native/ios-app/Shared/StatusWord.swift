import Foundation

/// Poki's status words, in standard product language: two to four Chinese characters, no subject, no
/// voice of its own ("Ready", "Paused", "Needs approval"; the owner, 2026-11-12). The one table every
/// place that says Poki's state reads (Status.xcstrings): the bear's word (`PokiMood.word`) and through
/// it the top of the chat, the home page, the status card and Settings; and, in the widget extension,
/// which cannot see the app's `PokiMood`, the Dynamic Island, the Lock Screen card and their alerts.
enum StatusWord: CaseIterable {
    case ready, thinking, running, checking
    case needsApproval, needsYourAction
    case done, error, paused, off
    case disconnected, starting, notStarted, notSetUp
    case listening, speaking

    static let table = "Status"

    var text: String {
        switch self {
        case .ready: AppLocalization.text(LocalizedStringResource("Ready", table: "Status"))
        case .thinking: AppLocalization.text(LocalizedStringResource("Thinking", table: "Status"))
        case .running: AppLocalization.text(LocalizedStringResource("Running", table: "Status"))
        case .checking: AppLocalization.text(LocalizedStringResource("Checking", table: "Status"))
        case .needsApproval: AppLocalization.text(LocalizedStringResource("Needs approval", table: "Status"))
        case .needsYourAction: AppLocalization.text(LocalizedStringResource("Needs your action", table: "Status"))
        case .done: AppLocalization.text(LocalizedStringResource("Done", table: "Status"))
        case .error: AppLocalization.text(LocalizedStringResource("Error", table: "Status"))
        case .paused: AppLocalization.text(LocalizedStringResource("Paused", table: "Status"))
        case .off: AppLocalization.text(LocalizedStringResource("Off", table: "Status"))
        case .disconnected: AppLocalization.text(LocalizedStringResource("Disconnected", table: "Status"))
        case .starting: AppLocalization.text(LocalizedStringResource("Starting", table: "Status"))
        case .notStarted: AppLocalization.text(LocalizedStringResource("Not started", table: "Status"))
        case .notSetUp: AppLocalization.text(LocalizedStringResource("Not set up", table: "Status"))
        case .listening: AppLocalization.text(LocalizedStringResource("Listening", table: "Status"))
        case .speaking: AppLocalization.text(LocalizedStringResource("Speaking", table: "Status"))
        }
    }
}
