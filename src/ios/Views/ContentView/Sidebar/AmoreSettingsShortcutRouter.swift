import SwiftUI

/// One replayable route slot. Notifications alone can arrive before the
/// SettingsSheet has mounted; the observable value is consumed onAppear too.
@MainActor
final class AmoreSettingsShortcutRouter: ObservableObject {
    static let shared = AmoreSettingsShortcutRouter()
    @Published private(set) var pending: String?
    private init() {}
    func open(_ path: String) { pending = path }
    func consume() -> String? { let next = pending; pending = nil; return next }
}
