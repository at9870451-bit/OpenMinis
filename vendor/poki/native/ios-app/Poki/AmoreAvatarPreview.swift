import SwiftUI
import UIKit

/// A public preview of the same companion rendered by Amore's chat header.
@MainActor
public struct AmoreAvatarPreview: View {
    let side: CGFloat
    let portrait: UIImage?
    let emoji: String
    public init(side: CGFloat = 56, portrait: UIImage? = nil, emoji: String = "") {
        self.side = side; self.portrait = portrait; self.emoji = emoji
    }
    public var body: some View {
        AmoreCompanionView(mood: .idle, side: side, pokes: 0, portrait: portrait, emoji: emoji)
    }
}
