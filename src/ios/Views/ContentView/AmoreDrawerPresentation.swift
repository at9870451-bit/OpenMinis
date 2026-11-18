import SwiftUI

/// One source of progress for live chat, composer, avatar and marquee. The
/// message tree stays mounted; opening the sidebar never blanks its content.
enum AmoreDrawerPresentation {
    static func phase(_ progress: CGFloat) -> CGFloat { min(1, max(0, progress)) }
    static func composerScale(progress: CGFloat, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 1 : 1 - 0.16 * phase(progress)
    }
    static func dimOpacity(progress: CGFloat, dark: Bool) -> Double {
        Double(phase(progress)) * (dark ? 0.16 : 0.04)
    }
}

private struct AmoreDrawerProgressKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
extension EnvironmentValues {
    var amoreDrawerProgress: CGFloat {
        get { self[AmoreDrawerProgressKey.self] }
        set { self[AmoreDrawerProgressKey.self] = AmoreDrawerPresentation.phase(newValue) }
    }
}

struct AmoreDrawerComposerMotion: ViewModifier {
    @Environment(\.amoreDrawerProgress) private var progress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(AmoreDrawerPresentation.composerScale(progress: progress, reduceMotion: reduceMotion), anchor: .bottomLeading)
            .allowsHitTesting(progress < 0.001)
    }
}
