import Foundation
import Combine
import SwiftUI

@MainActor
final class AmoreHomeShortcutStore: ObservableObject {
    static let shared = AmoreHomeShortcutStore()
    @Published private(set) var items: [AmoreHomeShortcut] = []
    @Published private(set) var revision = 0

    private let key = "amore.home.shortcuts.v1"
    private let catalogKey = "amore.home.shortcuts.catalogVersion"
    private let storage: UserDefaults

    /// Injectable UserDefaults makes persistence/migration testable without touching user data.
    init(storage: UserDefaults = .standard) {
        self.storage = storage
        reload()
    }

    var visibleItems: [AmoreHomeShortcut] {
        items.filter { !$0.hidden && AmoreShortcutRanking.valid($0) }
    }

    func reload() {
        if let data = storage.data(forKey: key),
           let decoded = try? JSONDecoder().decode([AmoreHomeShortcut].self, from: data) {
            items = AmoreHomeShortcutPolicy.sanitized(decoded)
            if storage.integer(forKey: catalogKey) < 3, !decoded.isEmpty {
                let previousDefaultIDs: Set<String> = storage.integer(forKey: catalogKey) >= 2
                    ? Set(Self.defaults.filter { !$0.id.hasPrefix("phone-") }.map(\.id))
                    : ["new-task", "summarize", "settings", "rootfs"]
                items = AmoreHomeShortcutPolicy.upgrade(items, defaults: Self.defaults,
                    previousDefaultIDs: previousDefaultIDs)
            }
        } else {
            items = Self.defaults
        }
        storage.set(3, forKey: catalogKey)
        persist()
    }

    func add(_ item: AmoreHomeShortcut) throws {
        guard AmoreShortcutRanking.valid(item) else { throw StoreError.invalidShortcut }
        guard !items.contains(where: { $0.id == item.id }) else { throw StoreError.duplicateID }
        var canonical = item
        if canonical.action.kind == .page {
            canonical.action.value = AmoreShortcutRoutes.canonicalPage(canonical.action.value)
        }
        items.append(canonical)
        persist()
    }

    func update(_ item: AmoreHomeShortcut) throws {
        guard AmoreShortcutRanking.valid(item) else { throw StoreError.invalidShortcut }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { throw StoreError.missingShortcut }
        var replacement = item
        if replacement.action.kind == .page {
            replacement.action.value = AmoreShortcutRoutes.canonicalPage(replacement.action.value)
        }
        replacement.edited = true
        replacement.hidden = items[index].hidden
        items[index] = replacement
        persist()
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    func restoreDefaults() {
        // A deliberate reset restores the shipped items but keeps custom prompts.
        let custom = items.filter { item in !Self.defaults.contains(where: { $0.id == item.id }) }
        items = Self.defaults + custom
        persist()
    }

    func setHidden(_ hidden: Bool, id: String) {
        setVisible(!hidden, id: id)
    }

    func setVisible(_ visible: Bool, id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].hidden = !visible
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        storage.set(data, forKey: key)
        revision &+= 1
    }

    enum StoreError: LocalizedError {
        case invalidShortcut, duplicateID, missingShortcut
        var errorDescription: String? {
            switch self {
            case .invalidShortcut: return AppLocalized("This shortcut is not valid.")
            case .duplicateID: return AppLocalized("A shortcut with this ID already exists.")
            case .missingShortcut: return AppLocalized("This shortcut no longer exists.")
            }
        }
    }

    static var defaults: [AmoreHomeShortcut] { AmoreHomeShortcutCatalog.items }
}
