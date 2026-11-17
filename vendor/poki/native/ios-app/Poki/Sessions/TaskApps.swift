import Foundation

/// The app a task was for, the one whose icon its conversation row and its result card show. It used
/// to be the app PokiCore last saw in front when the task's last call ended, which a stale or wrong
/// reading of the front app could make any app the phone had been in before.
///
/// In order: the app the task opened (a `launch` in its `do` calls); without one, the app most of its
/// actions ran in. Poki itself and the home screen never count. Between several, the one the request
/// names (the last opened, if it names more than one). With none, no app: the row shows no icon rather than a wrong one.
@MainActor
struct TaskApps: Equatable {
    /// The apps the task's `do` calls launched, in order, by key.
    private(set) var launched: [String] = []
    /// How many of the task's actions ended in each app, by key, and the order the apps were first seen.
    private(set) var steps: [String: Int] = [:]
    private var seen: [String] = []

    /// The key an app is known by: its bundle ID when Poki knows the app, else the name PokiCore read.
    /// Nil for Poki itself, the home screen and an unknown app.
    static func key(_ app: String?) -> String? {
        guard let app = app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else { return nil }
        // PokiCore names the home screen, the App Switcher and system alerts "Home screen (…)".
        if app.hasPrefix("Home screen") || app == "unknown" || app == "com.apple.springboard" { return nil }
        let key = AppIconStore.bundleID(app) ?? app
        if key == Bundle.main.bundleIdentifier || key.caseInsensitiveCompare("Poki") == .orderedSame { return nil }
        return key
    }

    /// The bundle IDs a `do` call's actions launch (`{"launch": "com.…"}` or `{"launch": {"bundle": …}}`).
    static func launches(inArguments arguments: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let actions = object["actions"] as? [[String: Any]] else { return [] }
        return actions.compactMap { action in
            (action["launch"] as? String) ?? ((action["launch"] as? [String: Any])?["bundle"] as? String)
        }
    }

    mutating func launch(_ app: String) {
        if let key = Self.key(app) { launched.append(key) }
    }

    /// One action ended with `app` in front.
    mutating func step(in app: String?) {
        guard let key = Self.key(app) else { return }
        if steps[key] == nil { seen.append(key) }
        steps[key, default: 0] += 1
    }

    /// The task's app, for the request it was asked with.
    func target(request: String) -> String? {
        var candidates: [String] = []
        for key in launched.isEmpty ? seen : launched where !candidates.contains(key) { candidates.append(key) }
        guard candidates.count > 1 else { return candidates.first }
        let named = AppIconStore.bundleIDs(namedIn: request)
        // The last one opened that the request names: an app opened first to look something up (Photos
        // for a dish's name) comes before the app the task is for.
        if let pick = candidates.last(where: named.contains) { return pick }
        // The most actions; between equals, the one opened (or reached) last.
        return candidates.enumerated().max { a, b in
            let (x, y) = (steps[a.element] ?? 0, steps[b.element] ?? 0)
            return x != y ? x < y : a.offset < b.offset
        }?.element
    }

    /// The app most of an outside agent's steps ran in, by the app each step recorded.
    static func mostStepped(_ apps: [String?]) -> String? {
        var tally = TaskApps()
        for app in apps { tally.step(in: app) }
        return tally.target(request: "")
    }
}
