import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A block of Backtape in words a person can read: a title and a few sentences.
struct BacktapeNote: Hashable, Sendable {
    var title: String
    var body: String
}

/// Writes a block's note with Apple's on-device model (the owner, 2026-11-14: where Apple
/// Intelligence is on the iPhone, use it). The text never leaves the phone. Without it, nothing is
/// written and the page shows the screen titles as before. No model is downloaded.
enum BacktapeWriter {
    /// Apple's own model, where Apple Intelligence is on the iPhone.
    static var apple: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    @MainActor
    static var available: Bool { apple }

    @MainActor
    static func write(_ entries: [HistoryEntry], period: String = "10 minutes") async -> BacktapeNote? {
        // Reads past the time limit keep no text: there is nothing to describe in them.
        let entries = entries.filter { !$0.text.isEmpty }
        guard available, !entries.isEmpty else { return nil }
        // The models' windows are small: up to 14 reads spread evenly over the time, the start of
        // each, about 3,000 characters in all.
        let take = min(entries.count, 14)
        let room = max(160, 3000 / take - 40)
        let long = entries.count > 1 && (entries.last!.at.timeIntervalSince(entries.first!.at)).magnitude > 20 * 3600
        var text = ""
        for index in 0..<take {
            let entry = entries[index * entries.count / take]
            let time = entry.at.formatted(date: long ? .abbreviated : .omitted, time: .shortened)
            text += "[\(time)] \(HistoryNames.app(entry.app)) \(entry.title)\n\(entry.text.prefix(room))\n\n"
        }
        let language = Locale(identifier: "en").localizedString(forIdentifier: AppLocalization.locale.identifier) ?? "English"
        let instructions = """
        You describe what a person did on their iPhone during \(period), from the text that was on \
        the screen. Write in \(language). First line: a title of at most 8 words. Then 2 or 3 plain \
        sentences that address the person as "you". Leave out buttons, menus, tab names and status \
        bar items. Say only what the text shows. No lists, no headings, no quotation marks.
        """
        guard let answer = await answer(to: text, instructions: instructions) else { return nil }
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*\"“” ").union(.whitespaces)) }
            .filter { !$0.isEmpty }
        guard let title = lines.first else { return nil }
        return BacktapeNote(title: String(title.prefix(90)), body: lines.dropFirst().joined(separator: " "))
    }

    @MainActor
    private static func answer(to text: String, instructions: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), apple {
            do {
                let session = LanguageModelSession(instructions: instructions)
                return try await session.respond(to: text).content
            } catch {
                AppLog.shared.add("history", "summary failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }
}
