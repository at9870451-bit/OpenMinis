import SwiftUI

/// The upstream top-bar layout is reused directly; Amore provides every action
/// and its real running state. There is no ChatModel/RootView behind this view.
@MainActor
public struct AmoreConversationChrome: View {
    public var home: Bool
    public var thinking: Bool
    public var busy: Bool
    public var title: String
    public var openThreads: () -> Void
    public var newConversation: () -> Void
    public var openModel: () -> Void
    public init(home: Bool, thinking: Bool, busy: Bool, title: String,
                openThreads: @escaping () -> Void, newConversation: @escaping () -> Void,
                openModel: @escaping () -> Void) {
        self.home = home; self.thinking = thinking; self.busy = busy; self.title = title
        self.openThreads = openThreads; self.newConversation = newConversation; self.openModel = openModel
    }
    public var body: some View {
        ChatTopBar(status: PokiStatus(thinking ? .thinking : .ready), home: false,
                   busy: busy, openThreads: openThreads, newConversation: newConversation,
                   openDetails: openModel, displayName: title)
            .overlayPreferenceValue(PicturePlaceKey.self) { anchors in
                GeometryReader { geometry in
                    if let anchor = anchors[.top] {
                        let rect = geometry[anchor]
                        PokiPicture(mood: thinking ? .thinking : .ready, side: HomeSizes().avatar)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
    }
}
