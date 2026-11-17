import SwiftUI

// The settings rows adapt element-hq/compound-ios (commit a1db8e1b), copyright 2023-2024 New Vector Ltd.,
// GNU Affero General Public License v3.0 only (Poki's own licence); see THIRD_PARTY_NOTICES.md:
// - Sources/Compound/List/ListRowLabel.swift: the icon on its own subtle ground beside the title, the
//   description 2 pt under the title, 30 pt icons that scale with the text and do not size the row;
// - Sources/Compound/List/ListRowDetails.swift and ListRowAccessory.swift: the value and the chevron trailing.
// The settings home's order (the profile on top, then groups of rows) is element-hq/element-x-ios (commit
// 4447399a), ElementX/Sources/Screens/Settings/SettingsScreen/View/SettingsScreen.swift.
// Changed (ESP-469): Poki's round blue-soft ground (amber when the row needs you) instead of Compound's
// rounded square and Poki's Tint colours. The system List provides navigation, swipe actions, search
// and Dynamic Type.

enum SettingsRowMetrics {
    static let iconSize: CGFloat = 28
    static let iconSpacing: CGFloat = 12
    static let maximumIconSize: CGFloat = 44
    // The circle can extend slightly beyond the text's line box within the system row insets.
    static let iconLineInset: CGFloat = -3
}

/// A settings icon: the symbol in Poki's blue on its soft round ground; amber while the row needs you.
struct SettingsIcon: View {
    var symbol: String
    var warns = false
    /// Grey instead of blue, for the entry at the bottom of the conversations.
    var neutral = false
    private let maximumSize: CGFloat
    @ScaledMetric(relativeTo: .body) private var size = SettingsRowMetrics.iconSize
    @ScaledMetric(relativeTo: .body) private var glyph = SettingsRowMetrics.iconSize / 2

    init(symbol: String, warns: Bool = false, neutral: Bool = false, size: CGFloat = SettingsRowMetrics.iconSize) {
        maximumSize = max(SettingsRowMetrics.maximumIconSize, size * 1.5)
        self.symbol = symbol
        self.warns = warns
        self.neutral = neutral
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        _glyph = ScaledMetric(wrappedValue: size * 0.5, relativeTo: .body)
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: glyph * min(1, maximumSize / size), weight: .semibold))
            .foregroundStyle(warns ? Tint.amberInk : neutral ? Color(.label) : Tint.blueText)
            .frame(width: min(size, maximumSize), height: min(size, maximumSize))
            .background(warns ? Tint.amberSoft : neutral ? Color(.tertiarySystemFill) : Tint.blueSoft, in: .circle)
            .accessibilityHidden(true)
    }
}

/// A part of Poki as a row on the settings home: its icon, its name with what is in there under it, and
/// where it stands on the right (an amber chip when that needs you).
struct SettingsRow: View {
    var title: LocalizedStringKey
    var caption: LocalizedStringKey? = nil
    var symbol: String
    var value: String? = nil
    var warns = false
    /// A next action offered by the destination, such as finishing setup.
    var valueIsAction = false
    /// A coloured dot before the value (the relay's state on External Agents).
    var dot: Color? = nil
    /// What ends the row in place of a value: a green tick for a thing that is done, an arrow for a row
    /// that leaves Poki (the system's own chevron ends the rows that open a page).
    var accessory: Accessory? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconSpacing = SettingsRowMetrics.iconSpacing

    enum Accessory { case done, leaves }

    var body: some View {
        HStack(spacing: min(18, iconSpacing)) {
            SettingsIcon(symbol: symbol)
                .padding(.vertical, SettingsRowMetrics.iconLineInset)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(Color(.label))
                if let caption { Text(caption).font(.footnote).foregroundStyle(Color(.secondaryLabel)) }
                // At the accessibility sizes the value goes under the caption, as in Settings.
                if typeSize.isAccessibilitySize, let value { valueView(value) }
            }
            Spacer(minLength: 8)
            // The value keeps its width (a model's name, the way of asking); the caption wraps instead.
            if !typeSize.isAccessibilitySize, let value { valueView(value).lineLimit(1).layoutPriority(1) }
            switch accessory {
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Tint.green).accessibilityLabel(Text("Done"))
            case .leaves:
                Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)).foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            case nil: EmptyView()
            }
        }
    }

    @ViewBuilder private func valueView(_ value: String) -> some View {
        if warns {
            Text(verbatim: value).font(.footnote.weight(.semibold)).foregroundStyle(Tint.amberInk)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Tint.amberSoft, in: .capsule)
        } else {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(verbatim: value).font(.subheadline)
                    .foregroundStyle(valueIsAction ? Tint.blueText : Color(.secondaryLabel))
            }
        }
    }
}

/// The subpages' rows: a Label's symbol on the same round ground as the home page's rows, at the same
/// size, with the same gap, weight and height (`SettingsRow`), so every page under Settings draws its
/// rows one way.
struct SettingsLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var iconSpacing = SettingsRowMetrics.iconSpacing

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: min(18, iconSpacing)) {
            SettingsLabelIcon { configuration.icon }
            configuration.title
        }
    }
}

/// A label with its symbol on the round ground, for rows where the system's own label style does not
/// reach (inside a Toggle, a LabeledContent or a NavigationLink, a List draws its labels its own way).
struct SettingsLabel<Title: View, Icon: View>: View {
    var title: Title
    var icon: Icon
    @ScaledMetric(relativeTo: .body) private var iconSpacing = SettingsRowMetrics.iconSpacing

    init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {
        self.title = title()
        self.icon = icon()
    }

    var body: some View {
        HStack(spacing: min(18, iconSpacing)) {
            SettingsLabelIcon { icon }
            title
        }
    }
}

extension SettingsLabel where Title == Text, Icon == Image {
    init(_ title: LocalizedStringKey, systemImage: String) {
        self.init(title: { Text(title) }, icon: { Image(systemName: systemImage) })
    }
}

private struct SettingsLabelIcon<Icon: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var size = SettingsRowMetrics.iconSize
    @ScaledMetric(relativeTo: .body) private var glyph = SettingsRowMetrics.iconSize / 2
    @ViewBuilder var icon: Icon
    var body: some View {
        icon
            .font(.system(size: glyph * min(1, SettingsRowMetrics.maximumIconSize / size), weight: .semibold))
            .foregroundStyle(Tint.blueText)
            .frame(width: min(size, SettingsRowMetrics.maximumIconSize), height: min(size, SettingsRowMetrics.maximumIconSize))
            .background(Tint.blueSoft, in: .circle)
            // A row that can't be used yet (Add Agent before the relay) greys its icon too.
            .opacity(isEnabled ? 1 : 0.4)
            .padding(.vertical, SettingsRowMetrics.iconLineInset)
    }
}

private struct SettingsPageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelStyle(SettingsLabelStyle())
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { HomeBackdrop(home: true, working: false, frozen: true) }
    }
}

extension View {
    func settingsPage() -> some View { modifier(SettingsPageStyle()) }
}

/// A section's heading as the settings pages write it: in the words' own case.
struct SettingsHeader: View {
    var title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }
    var body: some View { Text(title).textCase(nil) }
}

/// A capsule button: black for the action you reach for most (Pause), outlined for the rest.
struct SettingsPill: View {
    var title: LocalizedStringKey
    var symbol: String? = nil
    var prominent = false
    var chevron = false
    var action: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var height = 44.0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.footnote.weight(.bold))
                        .foregroundStyle(prominent ? Tint.onSolid : Tint.blueText)
                }
                Text(title).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
                if chevron {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .foregroundStyle(prominent ? Tint.onSolid : Color(.label))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: max(44, height))
            .background(prominent ? Tint.solid : Color(.secondarySystemGroupedBackground), in: .capsule)
            .overlay { if !prominent { Capsule().strokeBorder(Color(.separator).opacity(0.6), lineWidth: 1) } }
            .contentShape(.capsule)
        }
        .buttonStyle(PressedDimStyle())
    }
}

/// One choice among a few, as a card with a ring around the chosen one (Approvals' ways of asking).
struct SettingsChoiceCard: View {
    var title: String
    var detail: String? = nil
    var selected: Bool
    var action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                    if let detail {
                        Text(verbatim: detail).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Tint.blue : Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            .overlay(shape.strokeBorder(selected ? Tint.blue.opacity(0.7) : Color(.separator).opacity(0.5), lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(PressedDimStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
