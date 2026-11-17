import SwiftUI
import UIKit

// The pieces every screen is drawn from, in the website's design language (ESP-139 final boards 01,
// 03 and 04: the blue page, glass cards and white capsule buttons; long lists are white cards on the
// blue). Colours come from `Site` (Shared/ActivityTheme.swift), the one token table the Live Activity
// uses too. Type is Geist; Chinese falls back to PingFang by itself.

enum Geist: String {
    case regular = "Geist-Regular", medium = "Geist-Medium", semibold = "Geist-SemiBold", bold = "Geist-Bold"
    /// Weight 800: the boards' display type.
    case heavy = "Geist-Black"

    func font(_ size: CGFloat) -> Font { .custom(rawValue, size: size, relativeTo: .body) }
    /// The extra space SwiftUI needs to reach the boards' line height.
    func spacing(_ size: CGFloat, lineHeight: CGFloat) -> CGFloat {
        max(0, lineHeight - (UIFont(name: rawValue, size: size)?.lineHeight ?? size * 1.2))
    }
}

extension View {
    /// Geist at a size and line height from the boards, with letter spacing in em.
    func site(_ size: CGFloat, _ weight: Geist = .regular, line: CGFloat? = nil, tracking em: CGFloat = 0) -> some View {
        font(Self.systemFont(size, weight))
    }

    /// The system text style nearest to a board size, so Dynamic Type and the system font apply.
    static func systemFont(_ size: CGFloat, _ weight: Geist) -> Font {
        let style: Font = switch size {
        case 26...: .title.bold()
        case 20..<26: .title3
        case 16.5..<20: .body
        case 14.5..<16.5: .subheadline
        case 12.5..<14.5: .footnote
        default: .caption
        }
        switch weight {
        case .regular: return style
        case .medium: return style.weight(.medium)
        case .semibold, .bold, .heavy: return style.weight(.semibold)
        }
    }

    /// SF Mono, for addresses, codes and countdowns.
    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight, design: .monospaced))
    }

    /// A glass card on the blue page: white 8 %, a 1 pt white edge that is brighter along the top.
    /// A grouped section's card, as an inset grouped list draws it.
    func glassCard(_ radius: CGFloat = 10, fill: Color = Site.glass) -> some View {
        background(fill, in: .rect(cornerRadius: 10, style: .continuous))
    }

    /// The same card, for lists.
    func whiteCard(_ radius: CGFloat = 10) -> some View {
        background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

/// The page: the website's blue, the docs site's darker blue in dark mode (the boards draw light mode
/// only; the dark value is from ESP-139's token table).
struct SitePage<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            content
        }
        .foregroundStyle(Color(.label))
    }
}

extension Site {
    static func page(_ scheme: ColorScheme) -> Color { scheme == .dark ? night : blue }
}

/// A group's caption above a card: "AGENTS", "RUNNER".
struct GroupLabel: View {
    var text: LocalizedStringKey
    var body: some View {
        Text(text).site(13, line: 16).foregroundStyle(Site.c4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 7)
    }
}

/// The small print under a card.
struct GroupFootnote: View {
    var text: LocalizedStringKey
    var body: some View {
        Text(text).site(13, line: 18).foregroundStyle(Site.c4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.top, 8)
    }
}

/// A row inside a white card: the title, a grey value and a chevron when it goes somewhere.
struct WhiteRow<Trailing: View>: View {
    var title: LocalizedStringKey
    var titleColor: Color = Site.text
    var divider = true
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 8) {
            Text(title).site(17, line: 22).foregroundStyle(titleColor).frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .contentShape(.rect)
        .overlay(alignment: .bottom) { if divider { Site.hair.frame(height: 1) } }
    }
}

extension WhiteRow where Trailing == EmptyView {
    init(title: LocalizedStringKey, titleColor: Color = Site.text, divider: Bool = true) {
        self.init(title: title, titleColor: titleColor, divider: divider) { EmptyView() }
    }
}

/// The grey value and chevron at the end of a white row.
struct RowValue: View {
    var text: Text?
    var color: Color = Site.text3
    var chevron = true
    var body: some View {
        HStack(spacing: 6) {
            if let text { text.site(15, line: 18).foregroundStyle(color) }
            if chevron { Text(verbatim: "›").site(15, line: 18).foregroundStyle(Site.text3) }
        }
    }
}

/// The one main button on a page: a white capsule with blue text; glass and dimmed while it can't be used.
struct CapsuleButton: View {
    var title: LocalizedStringKey
    var height: CGFloat = 52
    var enabled = true
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!enabled)
    }
}

/// The boards' switch: on is a white track with a blue knob; off is a glass track with a white knob.
struct SiteToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch)
    }
}

/// The bear, round.
struct BearAvatar: View {
    var size: CGFloat
    var body: some View {
        Image("Bear", bundle: PokiPortResources.bundle).resizable().scaledToFill().frame(width: size, height: size).clipShape(.circle)
            .accessibilityHidden(true)
    }
}

/// A sheet's title row: an optional back link, the title in the middle, an optional Done.
struct SheetHeader: View {
    var title: Text
    var back: LocalizedStringKey?
    var sideWidth: CGFloat = 90
    var onBack: (() -> Void)?
    var done: (() -> Void)?
    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let back, let onBack {
                    Button(action: onBack) {
                        HStack(spacing: 4) { Text(verbatim: "‹"); Text(back) }.site(17, line: 22)
                    }
                    .buttonStyle(.plain)
                } else { Color.clear.frame(height: 1) }
            }
            .frame(width: sideWidth, alignment: .leading)
            title.site(17, .semibold, line: 22).lineLimit(1).frame(maxWidth: .infinity)
            Group {
                if let done {
                    Button(action: done) { Text("Done").site(17, .semibold, line: 22) }.buttonStyle(.plain)
                } else { Color.clear.frame(height: 1) }
            }
            .frame(width: sideWidth, alignment: .trailing)
        }
        .foregroundStyle(Color(.label))
        .frame(height: 52)
        .padding(.horizontal, 20)
    }
}

/// The white grabber at the top of a sheet.
struct Grabber: View {
    var body: some View {
        Color.clear.frame(height: 0).accessibilityHidden(true)
    }
}

/// A coloured dot and a word: "● Online".
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 7
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

/// Numbered instructions in a glass card (setup) or a white card (a proxy app's steps).
struct NumberedLines: View {
    var lines: [String]
    var onWhite = false
    var body: some View {
        VStack(alignment: .leading, spacing: onWhite ? 10 : 12) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                HStack(alignment: .firstTextBaseline, spacing: onWhite ? 8 : 10) {
                    Text(verbatim: "\(i + 1).").site(onWhite ? 14 : 15, line: onWhite ? 19 : 21)
                        .foregroundStyle(onWhite ? Site.text3 : Site.c4)
                        .frame(width: onWhite ? 14 : 18, alignment: .trailing)
                    Text(LocalizedStringKey(line)).site(onWhite ? 14 : 15, line: onWhite ? 19 : 21)
                        .foregroundStyle(onWhite ? Site.text2 : Color(.label))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Lets a page with its own back link keep the edge swipe back.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { viewControllers.count > 1 }
}
