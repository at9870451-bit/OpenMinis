import SwiftUI

// Each conversation in the drawer shows the icon of the app it worked in (the owner's examples: Notes,
// Starbucks, WeChat), found by AppIconStore.

extension SavedSession {
    /// The app the conversation worked in: its newest task's app (`TaskApps`, kept on the task's card),
    /// or for an outside agent's own steps, the app most of them ran in. Nil before any step in an app.
    @MainActor var app: String? {
        if let task = entries.last(where: { if case .plan = $0.kind { TaskApps.key($0.app) != nil } else { false } }) {
            return TaskApps.key(task.app)
        }
        return TaskApps.mostStepped(entries.map { if case .step = $0.kind { $0.app } else { nil } })
    }
}
