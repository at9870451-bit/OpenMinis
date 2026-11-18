import SwiftUI
import UIKit

/// The Amore conversation owns navigation, session/model state and all actions.
/// New conversation lives only at the bottom-left of the sidebar.
@MainActor
public struct AmoreConversationChrome: View {
    public var home: Bool
    public var thinking: Bool
    public var busy: Bool
    public var title: String
    public var active: Bool
    public var portrait: UIImage?
    public var emoji: String
    private let trailing: AnyView
    public var openThreads: () -> Void
    public var openModel: () -> Void
    @State private var pokes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var avatar: CGFloat = 56

    public init(home: Bool, thinking: Bool, busy: Bool, title: String, active: Bool = true,
                portrait: UIImage? = nil, emoji: String = "", trailing: AnyView = AnyView(Color.clear),
                openThreads: @escaping () -> Void, openModel: @escaping () -> Void) {
        self.home = home; self.thinking = thinking; self.busy = busy
        self.title = title; self.active = active; self.portrait = portrait; self.emoji = emoji
        self.trailing = trailing
        self.openThreads = openThreads; self.openModel = openModel
    }
    public var body: some View {
        let side = min(70, max(50, avatar))
        ZStack(alignment: .top) {
            HStack {
                Button(action: openThreads) {
                    Image(systemName: "line.3.horizontal")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(.label))
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassSurface(in: Circle(), interactive: true)
                .accessibilityLabel(Text("Conversations"))
                .accessibilityIdentifier("chat.threads")
                Spacer(minLength: 8)
                trailing
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
                    .glassSurface(in: Circle(), interactive: true)
            }
            .padding(.top, (side - 48) / 2)
            Button {
                pokes &+= 1
                openModel()
            } label: {
                VStack(spacing: 6) {
                    AmoreCompanionView(mood: thinking ? .thinking : busy ? .working : .idle,
                                       side: side, pokes: pokes, active: active, portrait: portrait, emoji: emoji)
                    Text(verbatim: title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(.label))
                        .padding(.horizontal, 12).frame(minHeight: 24)
                        .glassSurface(in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .light), trigger: pokes)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityHint(Text("Choose a model"))
            .accessibilityIdentifier("chat.header.details")
            .padding(.horizontal, 60)
        }
        .glassGroup()
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 4)
        .frame(maxWidth: 720)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}
