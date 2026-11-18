import SwiftUI
import UIKit

/// Cached normalized SOUL icon. Online/imported bytes have already passed
/// SoulIconSource and the native config-confirmation flow before reaching here.
@MainActor
final class AmoreCompanionProfile: ObservableObject {
    static let shared = AmoreCompanionProfile()
    @Published private(set) var image: UIImage?
    @Published private(set) var emoji = ""
    @Published private(set) var name = "Amore"
    private var raw = ""
    private var observer: NSObjectProtocol?
    private init() {
        reload()
        observer = NotificationCenter.default.addObserver(forName: .soulMdChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }
    func reload() {
        let metadata = SoulStore.cachedMetadata
        name = metadata.name.isEmpty ? "Amore" : metadata.name
        guard metadata.icon != raw else { return }
        raw = metadata.icon
        image = SoulIconImage.decode(raw)
        emoji = image == nil && raw.count == 1 ? raw : ""
    }
    var hasCustomIcon: Bool { image != nil || !emoji.isEmpty }
}
