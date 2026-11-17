// The Lock Screen card's fog-blue ground (ESP-344 定稿规格, sections 6 and 12): a mesh in the home
// page's blues, a soft light behind the bear, light and dark.
// Source: this repository's local branch proto/esp-344-island-glow (31df16b7), Shared/ActivityTrial.swift
// and Shared/ActivityTrialViews.swift, the prototype pane's trial code, with its switches taken out.
import SwiftUI
import WidgetKit

/// The falloff of the home page's soft lights: a Gaussian read off at these distances from the
/// centre (in radii), as shares of the centre's strength, gone at 1.2 radii.
enum GlowFalloff {
    static let table: [(at: Double, share: Double)] = [(0, 1), (0.25, 0.85), (0.5, 0.52), (0.75, 0.23), (1, 0.07), (1.2, 0)]
    static let reach = 1.2

    static func stops(_ colour: Color, strength: Double) -> [Gradient.Stop] {
        table.map { Gradient.Stop(color: colour.opacity(strength * $0.share), location: $0.at / reach) }
    }
}

/// The card's ground in one appearance: a mesh of four points across and three down, the light
/// behind the bear, the colour of the fade the bear rises out of, and the flat colour the system is
/// given for what it draws itself (StandBy, its dismiss button).
struct CardSkin {
    var rows: [(y: Float, colours: [UInt32])]
    var halo: (colour: UInt32, strength: Double)
    var rim: UInt32
    var tint: UInt32

    /// Where the points stand across the card. The words start at 0.32, so the deep column comes early.
    static let across: [Float] = [0, 0.30, 0.66, 1]
    /// The halo's radius, in sides of the bear's picture.
    static let haloRadius = 0.64

    static let light = CardSkin(
        rows: [(0, [0x3E96FC, 0x0A70F2, 0x0A64E6, 0x2757DC]),
               (0.52, [0x429FFA, 0x086EF0, 0x0C62E2, 0x2B56DA]),
               (1, [0x4AB2F7, 0x0F76F4, 0x1266E6, 0x345CDE])],
        halo: (0xE2EEFF, 0.42), rim: 0x0854CE, tint: 0x0A6CEE)
    static let dark = CardSkin(
        rows: [(0, [0x0B3C8A, 0x0C4FC0, 0x173FB0, 0x14286E]),
               (0.55, [0x0E4DB0, 0x1260D8, 0x1B4BC8, 0x1C3493]),
               (1, [0x1260D8, 0x1A6FF0, 0x2056E0, 0x2440B8])],
        halo: (0x3C8DFF, 0.46), rim: 0x062468, tint: 0x0E4FBE)

    static func skin(dark: Bool) -> CardSkin { dark ? .dark : .light }

    var points: [SIMD2<Float>] { rows.flatMap { row in Self.across.map { SIMD2($0, row.y) } } }
    var colours: [Color] { rows.flatMap { $0.colours.map { Color(hex: $0) } } }
    /// The mesh's middle row from left to right: what shows where the mesh is not drawn.
    var across: [Gradient.Stop] { zip(Self.across, rows[1].colours).map { Gradient.Stop(color: Color(hex: $1), location: Double($0)) } }
}

/// Poki's brand band: the card's lowest row of blues, left to right, where its light is brightest. The
/// island's glow while you talk with Poki and the talk's marks in the app draw it.
enum BrandBand {
    static var colours: [Color] { CardSkin.light.rows[CardSkin.light.rows.count - 1].colours.map { Color(hex: $0) } }
}

/// While you talk with Poki: the brand band low in the expanded island, rising out of its bottom edge
/// and fading upward and toward the sides. Plain gradients and masks, no blur, so nothing in it asks
/// for an effect a Live Activity may not draw. Seen in the simulator only so far, not on a phone.
struct TalkGlow: View {
    var body: some View {
        LinearGradient(colors: BrandBand.colours, startPoint: .leading, endPoint: .trailing)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.35), location: 0.45),
                                         .init(color: .white, location: 1)], startPoint: .top, endPoint: .bottom))
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.22),
                                         .init(color: .white, location: 0.78), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(height: 30)
            .accessibilityHidden(true)
    }
}

/// The card's ground: the mesh and the halo behind the bear. It stands still: a Live Activity may
/// not run an animation of its own. Whether a Live Activity draws a `MeshGradient` on a phone is not
/// known (it does on the iOS 27 simulator), so the mesh's middle row lies under it as a plain
/// left-to-right gradient: if the mesh draws nothing, the card is still the same blues.
struct CardArt: View {
    var skin: CardSkin
    /// The bear's picture: its side, how far it stands from the left edge, and the middle of its head
    /// and hand as shares of the side. Its lower edge is the card's.
    var bearSide: Double
    var bearInset: Double
    var bearMiddle: CGPoint

    var body: some View {
        GeometryReader { proxy in
            let radius = CardSkin.haloRadius * bearSide * GlowFalloff.reach
            ZStack {
                LinearGradient(stops: skin.across, startPoint: .leading, endPoint: .trailing)
                MeshGradient(width: CardSkin.across.count, height: skin.rows.count, points: skin.points, colors: skin.colours,
                             smoothsColors: true, colorSpace: .perceptual)
                EllipticalGradient(stops: GlowFalloff.stops(Color(hex: skin.halo.colour), strength: skin.halo.strength),
                                   center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(x: bearInset + bearMiddle.x * bearSide, y: proxy.size.height - bearSide + bearMiddle.y * bearSide)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

/// The system's appearance as `CardTint` read it outside the card. The widget sets the whole card to
/// dark, so inside it the colour scheme always says dark; this carries the real one in. Nil where
/// nothing outside has said (the app's own previews), and there the card's own environment is read.
private struct CardDarkKey: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    var cardDark: Bool? {
        get { self[CardDarkKey.self] }
        set { self[CardDarkKey.self] = newValue }
    }
}

/// The Lock Screen card's tint, which the system uses for what it draws itself (StandBy, the strip
/// it adds under the card): the flat colour that goes with the card's gradient. The widget puts it
/// outside the line that sets the card to dark, so it reads the system's own appearance here and
/// hands it to the card. The Always-On display is drawn as in dark. On the iOS 27 simulator the Lock
/// Screen gives a Live Activity the dark appearance also while the system is in light, so the light
/// ground shows only where the system says light (not yet seen on a phone).
struct CardTint: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isLuminanceReduced) private var dimmed

    func body(content: Content) -> some View {
        let dark = scheme == .dark || dimmed
        content
            .environment(\.cardDark, dark)
            .activityBackgroundTint(Color(hex: CardSkin.skin(dark: dark).tint))
    }
}

/// Whether the island is short of room (the phone on its side, a second Live Activity beside ours):
/// each block must then fit a circle 28 points across. The system says so from iOS 27; the app's own
/// preview says so itself.
private struct NarrowIslandPreviewKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var narrowIslandPreview: Bool {
        get { self[NarrowIslandPreviewKey.self] }
        set { self[NarrowIslandPreviewKey.self] = newValue }
    }
}

struct LimitedWidth<Content: View>: View {
    @Environment(\.narrowIslandPreview) private var preview
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        if preview {
            content(true)
        } else {
            #if compiler(>=6.4)
            if #available(iOS 27.0, *) {
                System(content: content)
            } else {
                content(false)
            }
            #else
            content(false)
            #endif
        }
    }

    // The width signal is in the iOS 27 SDK (Xcode 27, Swift 6.4). An older Xcode builds without it,
    // and the island then lays out as if it always had its full width.
    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    private struct System: View {
        @Environment(\.isDynamicIslandLimitedInWidth) private var limited
        var content: (Bool) -> Content
        var body: some View { content(limited) }
    }
    #endif
}
