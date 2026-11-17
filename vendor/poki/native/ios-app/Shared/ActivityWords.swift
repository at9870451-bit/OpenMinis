import Foundation

/// The Live Activity's words, in English and Simplified Chinese (LiveActivity.xcstrings, carried by
/// both the app and the widget extension), following Poki’s UI language. The table is the Live
/// Activity's own; the app's other screens have theirs in Localizable.xcstrings. Home and All Steps
/// borrow `label` for PokiCore's step labels.
///
/// How much it says (ESP-162): a status word, one or two words (two to four Chinese characters), and
/// one content line, at most four words (eight Chinese characters). How to do something is never
/// here; tapping the activity opens Poki, which explains it.
///
/// The app keeps the state's words in English ("Runner Stopped", "Waiting for agent", PokiCore's
/// "Tap “Send”"), and the face words them in Poki's UI language when it draws them, so the
/// app's own checks on them do not depend on the language.
enum ActivityWords {
    static let table = "LiveActivity"

    /// A word the app keeps in English, in Poki's UI language. A state the app names in English
    /// ("Runner asleep") is said in Poki's one set of status words; a text the table does not have (an
    /// error from the pairing) stays as it is.
    static func local(_ key: String) -> String {
        if let word = states[key] { return word.text }
        return AppLocalization.bundle.localizedString(forKey: key, value: key, table: table)
    }

    /// The app's English names of a state (the activity's `headline`, `RunnerStatus.title`) that are
    /// said as a status word. The names stay as they are: the app and the face compare them.
    static let states: [String: StatusWord] = [
        "Ready for the agent": .ready, "Waiting for agent": .ready,
        // Standing by takes the next request by itself: Ready, as in the app (the owner, 2026-11-13).
        "Runner asleep": .ready, "Sleeping": .ready,
        "Not started": .notStarted,
        "Starting the runner": .starting, "Starting native services": .starting,
        "Thinking": .thinking, "Listening": .listening, "Speaking": .speaking,
        "Finished": .done,
    ]

    /// The lines Poki itself puts on a run ("Thinking", "Carrying on"), as against a step label from
    /// PokiCore ("Tap “Send”"): with no plan to say what the task is doing, only these are shown.
    static let statusLines: Set<String> = [
        "Thinking", "Starting the runner", "Starting native services", "Continuing", "Step skipped",
        "Carrying on", "The agent carried on by itself",
    ]

    /// A step label from PokiCore in Poki's UI language, whole, for the app's own screens.
    /// Several actions ("Tap “Search”, then type “cats”") are worded one by one and joined in that
    /// language's own way.
    static func label(_ label: String) -> String {
        let parts = actions(label)
        guard parts.count > 1 else { return translate(label) }
        let words = parts.enumerated().map { index, part in
            // PokiCore lowercases every action after the first; the table has them capitalised.
            translate(index == 0 ? part : part.prefix(1).uppercased() + part.dropFirst())
        }
        return words.dropFirst().reduce(words[0]) { String(activity: "\($0), then \($1)") }
    }

    /// PokiCore's reason for an approval ("sending a message (\"send\")", "input in Wallet") in the
    /// system's language, without the word in brackets that set it off.
    static func reason(_ why: String) -> String {
        let plain = why.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if plain.hasPrefix("input in ") {
            guard let name = AppName.display(String(plain.dropFirst("input in ".count))) else { return "" }
            return String(activity: "Input in \(name)")
        }
        return local(plain)
    }

    /// A label's actions. A ", then " inside typed text (between “ and ”) does not split it.
    private static func actions(_ label: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for piece in label.components(separatedBy: ", then ") {
            current = current.isEmpty ? piece : current + ", then " + piece
            if current.filter({ $0 == "“" }).count == current.filter({ $0 == "”" }).count {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// The labels PokiCore writes (Computer.label in PokiCore's StepLabels.swift). Those with a name
    /// or a value in them are matched here; the fixed ones ("Swipe up", "Drag") and the app's own
    /// lines ("Starting the runner") are looked up as they are.
    private static func translate(_ label: String) -> String {
        func quoted(_ verb: String) -> String? {
            guard label.hasPrefix(verb + " “"), label.hasSuffix("”") else { return nil }
            return String(label.dropFirst(verb.count + 2).dropLast())
        }
        func after(_ words: String) -> String? {
            label.hasPrefix(words + " ") ? String(label.dropFirst(words.count + 1)) : nil
        }
        if let name = quoted("Tap") { return String(activity: "Tap “\(name)”") }
        if let name = quoted("Press and hold") { return String(activity: "Press and hold “\(name)”") }
        if let text = quoted("Type") { return String(activity: "Type “\(text)”") }
        if let name = quoted("Run") { return String(activity: "Run “\(name)”") }
        if let name = quoted("Scroll to") { return String(activity: "Scroll to “\(name)”") }
        if let point = after("Tap at") { return String(activity: "Tap at \(point)") }
        if let point = after("Press and hold at") { return String(activity: "Press and hold at \(point)") }
        if let rest = after("Type"), rest.hasSuffix(" hidden characters"), let count = Int(rest.prefix { $0.isNumber }) {
            return String(activity: "Type \(count) hidden characters")
        }
        let fixed = local(label)
        if fixed != label { return fixed }
        if let rest = after("Press"), rest.hasSuffix(" button") { return String(activity: "Press \(String(rest.dropLast(7))) button") }
        if let key = after("Press") { return String(activity: "Press \(key)") }
        if let app = after("Open") {
            guard let name = AppName.display(app) else { return local("Open") }
            return String(activity: "Open \(name)")
        }
        return label
    }
}

extension String {
    /// One of the Live Activity's words, from its own table.
    init(activity key: String.LocalizationValue) {
        self = AppLocalization.text(LocalizedStringResource(key, table: ActivityWords.table))
    }
}
