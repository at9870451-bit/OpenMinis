import SwiftUI

/// Shared by the real sidebar and its simulator layout checks.
struct DrawerShortcutLabel: View {
    let title: String
    let symbol: String
    let accent: Color
    @ScaledMetric(relativeTo: .callout) private var iconSize = 18
    @ScaledMetric(relativeTo: .callout) private var minimumHeight = 48
    @Environment(\.dynamicTypeSize) private var typeSize

    // Production shortcuts pass semantic primary/secondary. Resolve those to
    // blue-panel ink, while preserving explicitly supplied coloured accents.
    private var sidebarAccent: Color {
        if accent == .primary { return PokiTheme.sidebarInk }
        if accent == .secondary { return PokiTheme.sidebarHeading }
        return accent
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(sidebarAccent)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(PokiTheme.sidebarInk)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
