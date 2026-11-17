import Foundation
import Combine
import SwiftUI

@MainActor
final class AmoreHomeShortcutStore: ObservableObject {
    static let shared = AmoreHomeShortcutStore()
    @Published private(set) var items: [AmoreHomeShortcut] = []
    @Published private(set) var revision = 0

    private let key = "amore.home.shortcuts.v1"

    private init() { reload() }

    var visibleItems: [AmoreHomeShortcut] {
        items.filter { !$0.hidden && AmoreShortcutRanking.valid($0) }
    }

    func reload() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([AmoreHomeShortcut].self, from: data) {
            items = decoded.filter(AmoreShortcutRanking.valid)
        } else {
            items = Self.defaults
        }
        revision &+= 1
    }

    func add(_ item: AmoreHomeShortcut) throws {
        guard AmoreShortcutRanking.valid(item) else { throw StoreError.invalidShortcut }
        guard !items.contains(where: { $0.id == item.id }) else { throw StoreError.duplicateID }
        items.append(item)
        persist()
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    func setVisible(_ visible: Bool, id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].hidden = !visible
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
        revision &+= 1
    }

    enum StoreError: LocalizedError {
        case invalidShortcut, duplicateID
        var errorDescription: String? {
            switch self {
            case .invalidShortcut: return AppLocalized("This shortcut is not valid.")
            case .duplicateID: return AppLocalized("A shortcut with this ID already exists.")
            }
        }
    }

    static let defaults: [AmoreHomeShortcut] = [
        .init(id: "new-task", appName: "Amore", title: "Start a task", symbol: "sparkles", action: .init(kind: .prompt, value: "Help me start a new task.")),
        .init(id: "summarize", appName: "Amore", title: "Summarize text", symbol: "text.alignleft", action: .init(kind: .prompt, value: "Summarize the text I provide.")),
        .init(id: "settings", appName: "Amore", title: "Open settings", symbol: "gearshape", action: .init(kind: .page, value: "appearance")),
        .init(id: "rootfs", appName: "Amore", title: "Manage runtime", symbol: "shippingbox", action: .init(kind: .page, value: "rootfs"))
    ]
}
