import SwiftUI

/// Array storage identity is O(1). Keeping both arrays alive while comparing
/// prevents an allocator from reusing the previous buffer's address. Every
/// session edit uses Array's copy-on-write storage and invalidates this key.
struct DrawerSessionSource: Equatable {
    let sessions: [ChatSession]

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.sessions.count == rhs.sessions.count else { return false }
        return lhs.sessions.withUnsafeBufferPointer { left in
            rhs.sessions.withUnsafeBufferPointer { right in
                left.baseAddress == right.baseAddress
            }
        }
    }
}

/// An immutable reference avoids deep comparison of a library-sized array in
/// SwiftUI's transaction graph. Sections contain IDs; only visible lazy rows
/// resolve their session. Replaced when source, query, archive or day changes.
final class DrawerHistorySnapshot {
    let groups: [DrawerSessionGroup]
    let sessionsByID: [String: ChatSession]
    let isSearching: Bool

    init(groups: [DrawerSessionGroup] = [], sessionsByID: [String: ChatSession] = [:], isSearching: Bool = false) {
        self.groups = groups
        self.sessionsByID = sessionsByID
        self.isSearching = isSearching
    }
}

/// A title-only history row, with scalable text and a 44-point touch target.
/// Dates belong to the cached section headings, not a ticking relative label.
struct ChatHistorySessionLabel: View {
    let title: String
    let selected: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Text(title)
            .font(.body)
            .foregroundStyle(PokiTheme.sidebarInk)
            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? PokiTheme.sidebarSelected : .clear)
            }
            .contentShape(Rectangle())
    }
}

/// A flat pressed fill, with no shadows, scaling or material render passes.
struct ChatHistoryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? PokiTheme.sidebarPressed : .clear)
            }
    }
}
