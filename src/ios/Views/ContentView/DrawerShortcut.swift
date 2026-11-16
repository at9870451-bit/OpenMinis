import SwiftUI

/// Shared by the real sidebar and its simulator layout checks.
struct DrawerShortcutLabel: View {
    let title: String
    let symbol: String
    let accent: Color
    @ScaledMetric(relativeTo: .callout) private var iconSize = 18
    @ScaledMetric(relativeTo: .callout) private var minimumHeight = 48

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(PokiTheme.primaryText)
                .lineLimit(2)
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
