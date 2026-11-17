// The Live Activity's views. The structure (one card per surface drawn from one presentation, the
// expanded island's content under the camera, the approval buttons, the compact status) is ported
// from AgentLiveActivityWidget.swift in Clarklevis1995/dsh-mobile (commit ebe19764,
// AgentLiveActivityWidget/AgentLiveActivityWidget.swift), MIT License, Copyright (c) 2026 Chaofan Li.
// The approval countdown, counted by the system with `Text(timerInterval:countsDown:)`, follows
// ios/AgentActivity/AgentActivityWidget.swift in onehumanbeing/esp32-iphone-agent (commit cc966294),
// MIT License, Copyright (c) 2026 Henry Yuan. Interpolated text, the phase spring and margins kept
// concentric with the island's corners are from leepokai/Codync (commit 848070d,
// apps/ios/Widgets/CodyncWidgets.swift), Copyright 2026 Po Kai Lee, Apache License 2.0. The layout,
// the bear that rises from the bottom edge, the two-line compact island and the colours are Poki's
// own: ESP-344's final design (定稿规格, drawn at 402 by 874 points). The design draws to the island's
// edge; iOS does not (see `ActivityMetrics.islandClip`), so what stood on the edge stands on the
// system's line instead. Run as a real Live Activity on the iOS 27 simulator; not yet on a phone.
// See THIRD_PARTY_NOTICES.md.
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Sizes, in points, from ESP-344's final design. The Lock Screen card and the expanded island are
/// 376 wide there and at most 160 tall (the system's limit for a Live Activity). Every view here
/// draws one `ActivityFace`, so the four presentations always say the same thing.
enum ActivityMetrics {
    /// The largest text size the Live Activity draws: above it the one question and the two answers
    /// no longer fit the Lock Screen card or the island, so they stay at this size.
    static let largestType: DynamicTypeSize = .large
    /// The card's corner as iOS draws it, and the expanded island's.
    static let lockCorner: CGFloat = 24
    static let islandCorner: CGFloat = 46
    /// The design's heights for the expanded island count the row beside the camera as 38 points.
    /// iOS makes that row 36.67, so the island comes out 1.33 lower than the design's number.
    static let cameraRow: CGFloat = 38
    static let systemCameraRow: CGFloat = 36.67
    /// iOS draws nothing of ours nearer than this to the expanded island's outline, also with the
    /// content margins at zero: it clips the content to the outline drawn in by 12.33 points, with
    /// a corner of about 36. Measured on a real Live Activity on the iOS 27 simulator (a 402-point
    /// iPhone, island 374 wide); not yet on a phone. So the bear stands on that line and not on the
    /// edge, and a control near a corner keeps clear of the corner's curve.
    static let islandClip: CGFloat = 12.33
    static let islandClipCorner: CGFloat = 36
    static let compactHeight: CGFloat = 36.67
    /// What the system cuts off the compact island's and the minimal circle's edge: the bear stays
    /// whole inside it. Measured at the bottom edge on the iOS 27 simulator; the other sides are taken
    /// to be the same. Not yet measured on a phone.
    static let compactClip: CGFloat = 4.33
    /// The compact island's left block, and the side of the bear's whole picture in it.
    static let compactBlock: CGFloat = 51
    static let compactBear: CGFloat = 27.2
    /// The compact island's right block during a run: one width from step to step, so the island
    /// keeps its size while the words change.
    static let compactWords: CGFloat = 52
    /// The app's icon on the compact island's right during a run, and in the circle short of room.
    static let compactIcon: CGFloat = 22
    static let narrowIcon: CGFloat = 18
    /// Short of room, every block fits a circle this wide.
    static let narrowCircle: CGFloat = 28
    /// The bear's whole picture in that circle and in the minimal circle: one side for every pose, so
    /// the bear does not grow or shrink when the state changes.
    static let circleBear: CGFloat = 22.6
    static let button: CGFloat = 38
    /// The Don’t Ask Again row under the two answers, and the space between. iOS cuts a Live Activity
    /// off at about 160 points, so the row sits in the card's own height.
    static let stopAskingText: CGFloat = 22
    static let stopAskingGap: CGFloat = 6
    static let stopCircle: CGFloat = 46
    static let stopCapsule: CGFloat = 34
    static let smallThumbnail = CGSize(width: 34, height: 72)
    static let smallThumbnailCorner: CGFloat = 7

    struct Sizes {
        var island: CGFloat, islandBear: CGFloat, islandLeft: CGFloat
        var lock: CGFloat, lockBear: CGFloat, lockLeft: CGFloat
        /// The short cards keep the bear 4 points off the left edge; the tall ones let it touch.
        var lockBearInset: CGFloat
    }

    static func sizes(_ face: ActivityFace) -> Sizes {
        switch face.size {
        case .low:
            Sizes(island: 106, islandBear: 96, islandLeft: 104, lock: 112, lockBear: 104, lockLeft: 122, lockBearInset: 4)
        case .working:
            // Before the run is in an app it has no line yet (the runner waking): the lower island.
            Sizes(island: (face.bottom.hasLine ? 118 : 106) + 18, islandBear: 96, islandLeft: 104,
                  lock: face.bottom.hasLine ? 134 : 124, lockBear: 116, lockLeft: 122, lockBearInset: 4)
        case .asking:
            Sizes(island: 150, islandBear: 128, islandLeft: 130, lock: 154, lockBear: 134, lockLeft: 138, lockBearInset: 0)
        case .tall:
            Sizes(island: 160, islandBear: 134, islandLeft: 134, lock: 160, lockBear: 136, lockLeft: 138, lockBearInset: 0)
        }
    }

    /// The screenshot on the right of the Lock Screen card: as tall as the card allows, a phone's shape.
    static func thumbnail(_ face: ActivityFace) -> CGSize? {
        switch face.thumbnail {
        case .none: return nil
        case .small: return smallThumbnail
        case .large:
            let height = sizes(face).lock - 28
            return CGSize(width: (height * 0.46).rounded(), height: height)
        }
    }
}

extension ActivityFace.Bottom {
    /// A run in an app, or with a plan, draws the line that says work goes on.
    var hasLine: Bool { if case .progress(let line, _) = self { line } else { false } }
    var isProgress: Bool { if case .progress = self { true } else { false } }
    var isHandoff: Bool { if case .handoff = self { true } else { false } }
    var isApproval: Bool { switch self { case .approval, .deciding: true; default: false } }
}

extension ActivityFace {
    /// Where the outside agent's badge goes (ESP-344 定稿规格, section 14): after the app's name while
    /// Poki works; after the reason while it waits for an answer on the island (on the card the reason
    /// may take two lines, so there it stays left of the countdown); beside the small value otherwise.
    enum BadgePlace { case afterPlace, afterReason, besideValue }
    func badgePlace(_ surface: ActivitySurface) -> BadgePlace {
        if bottom.isProgress { return .afterPlace }
        if bottom.isApproval, surface == .island { return .afterReason }
        return .besideValue
    }
}

// MARK: Lock Screen & Non-Dynamic Island Top Banner

/// The Lock Screen card (and the banner on a phone without the island): the website's blue with
/// only white on it, the bear rising from its bottom-left corner. The widget adds the blue itself.
struct LockScreenCard: View {
    var face: ActivityFace
    @Environment(\.isLuminanceReduced) private var dimmed
    /// The system's appearance. The card sets its own content to dark below and the widget sets the
    /// whole card to dark, so where the widget draws it the real one comes in from outside (`cardDark`).
    @Environment(\.colorScheme) private var scheme
    @Environment(\.cardDark) private var outside
    private let theme = ActivityTheme.current

    var body: some View {
        let sizes = ActivityMetrics.sizes(face)
        let skin = CardSkin.skin(dark: outside ?? (scheme == .dark || dimmed))
        let palette = theme.lock(on: skin)
        ZStack(alignment: .bottomLeading) {
            RisingBear(bear: face.bear, side: sizes.lockBear, rim: 26, colour: palette.rim)
                .padding(.leading, sizes.lockBearInset)
            words(palette)
                .padding(.leading, sizes.lockLeft).padding(.trailing, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: sizes.lock)
        .frame(maxWidth: .infinity)
        .foregroundStyle(palette.text)
        .environment(\.colorScheme, .dark)
        .background {
            CardArt(skin: skin, bearSide: sizes.lockBear, bearInset: sizes.lockBearInset,
                    bearMiddle: CGPoint(x: face.bear.middle.x, y: face.bear.middle.y))
        }
        .animation(dimmed ? nil : ActivityMotion.phase, value: face.bear)
        .animation(dimmed ? nil : ActivityMotion.step, value: face.content)
        .accessibilityElement(children: .contain)
    }

    private func words(_ palette: ActivityPalette) -> some View {
        let top: CGFloat = switch face.size { case .low: 30; case .working, .asking: 22; case .tall: 20 }
        let bottom: CGFloat = switch face.size { case .low: 0; case .working: 12; case .asking, .tall: 16 }
        let hasKicker = face.kicker != nil || face.event != nil
        // The screenshot stands in the top right corner, over the words' column and outside its
        // flow: the words keep clear of it, and it never pushes the control off the card.
        let shot = Thumbnail.picture
        let thumbnail = shot == nil ? nil : ActivityMetrics.thumbnail(face)
        let reserved = thumbnail.map { $0.width + 12 } ?? 0
        // The value (time, countdown) sits on the first line that has room for it: beside the
        // control where the control leaves room, and always there when the screenshot takes the
        // top line's end.
        let metaBesideControl = face.bottom.isHandoff || thumbnail != nil && face.bottom.isProgress
        // Beside the screenshot the countdown keeps to its digits, to leave the reason its room.
        let meta = MetaCluster(face: face, palette: palette, meta: face.lockMeta ?? face.meta, badge: face.badgePlace(.lockScreen) == .besideValue,
                               timer: thumbnail != nil && !metaBesideControl ? 38 : 46)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if hasKicker {
                    HStack(spacing: 8) {
                        Kicker(face: face, palette: palette)
                        Spacer(minLength: 0)
                        if !metaBesideControl { meta }
                    }
                    .frame(height: 16)
                }
                Title(face: face, palette: palette, large: face.size == .low).padding(.top, hasKicker ? 3 : 0)
                if face.subtitle != nil || !hasKicker && !metaBesideControl {
                    Group {
                        if hasKicker || metaBesideControl {
                            Subtitle(face: face, palette: palette)
                        } else if face.size == .low {
                            // A finished run: what it took and when, on one line, or one under the other.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { Subtitle(face: face, palette: palette); Spacer(minLength: 0); meta }
                                VStack(alignment: .leading, spacing: 3) { Subtitle(face: face, palette: palette); meta }
                            }
                        } else {
                            HStack(alignment: .top, spacing: 8) {
                                Subtitle(face: face, palette: palette, lines: thumbnail == nil ? nil : 2)
                                Spacer(minLength: 0)
                                meta
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                if face.bottom.hasLine { RunLine(palette: palette).padding(.top, 9) }
            }
            .padding(.trailing, reserved)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Control(face: face, surface: .lockScreen)
                if metaBesideControl { meta }
            }
            .padding(.trailing, thumbnail != nil && face.thumbnail == .large ? reserved : 0)
        }
        .padding(.top, top).padding(.bottom, bottom)
        .overlay(alignment: .topTrailing) {
            if let thumbnail, let shot {
                Thumbnail(image: shot, size: thumbnail, corner: face.thumbnail == .small ? ActivityMetrics.smallThumbnailCorner : 10)
                    .padding(.top, 14)
            }
        }
    }
}

// MARK: Dynamic Island, expanded

/// Lays NoTapIntent under a region of the expanded island while `on` (`ActivityFace.shieldsTaps`): iOS
/// opens the activity's app on any tap no control takes, and this button takes it and does nothing.
/// Allow, Don't Allow, Stop and Continue sit above it and still work.
struct TapShield: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on {
            content.background {
                Button(intent: NoTapIntent()) { Color.clear.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}

/// Beside the camera, left: nothing. The bear stands in the bottom-left corner and says the state.
struct IslandLeading: View {
    var face: ActivityFace
    var body: some View { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
}

/// Beside the camera, right: nothing to see. iOS sets this region against the island's top edge at
/// its content's own height, which put the value half under the system's clip; the value is drawn
/// from `IslandBottom` instead, at a place of its own. The value stays here unseen, so the row beside
/// the camera keeps the size it had.
struct IslandTrailing: View {
    var face: ActivityFace
    var body: some View {
        MetaCluster(face: face, palette: ActivityTheme.current.island, meta: face.meta)
            .padding(.trailing, 30)
            .hidden()
            .accessibilityHidden(true)
    }
}

/// Under the camera: the bear from the bottom edge, and the words and the control beside it.
struct IslandBottom: View {
    var face: ActivityFace
    @Environment(\.isLuminanceReduced) private var dimmed
    private let theme = ActivityTheme.current

    var body: some View {
        let sizes = ActivityMetrics.sizes(face)
        let palette = theme.island
        let height = sizes.island - ActivityMetrics.cameraRow
        ZStack(alignment: .bottomLeading) {
            // Taller than this region in the two low states: the ears reach up beside the camera.
            // The bear stands on the system's line: moved in from the left edge by as much as iOS
            // cuts away, so its cheek is whole, and shaded where the line cuts it below.
            RisingBear(bear: face.bear, side: sizes.islandBear, rim: 22, lift: ActivityMetrics.islandClip, colour: palette.rim)
                .frame(width: sizes.islandBear, height: height, alignment: .bottom)
                .padding(.leading, ActivityMetrics.islandClip)
            words(palette)
                .padding(.leading, sizes.islandLeft)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // The one small value (time, countdown, a tick) with the outside agent's badge to its left,
        // beside the camera: its middle 26 points under the island's top edge and 30 in from the
        // right, where the corner of the system's clip no longer reaches it.
        .overlay(alignment: .topTrailing) {
            MetaCluster(face: face, palette: palette, meta: face.meta, badge: face.badgePlace(.island) == .besideValue)
                .frame(height: 24)
                .padding(.trailing, 30)
                .offset(y: -(ActivityMetrics.systemCameraRow - 14))
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        // A talk with Poki is on: the brand band along the island's lower edge, under the words.
        .background(alignment: .bottom) {
            if face.talkGlow, !dimmed { TalkGlow().transition(.opacity) }
        }
        .foregroundStyle(palette.text)
        .environment(\.colorScheme, .dark)
        .animation(dimmed ? nil : ActivityMotion.phase, value: face.talkGlow)
        .animation(dimmed ? nil : ActivityMotion.phase, value: face.bear)
        .animation(dimmed ? nil : ActivityMotion.step, value: face.content)
    }

    @ViewBuilder private func words(_ palette: ActivityPalette) -> some View {
        let hasKicker = face.kicker != nil || face.event != nil
        if case .progress(let line, let stop) = face.bottom {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Kicker(face: face, palette: palette).frame(height: 16).padding(.top, 1)
                    Title(face: face, palette: palette).padding(.top, 2)
                    if line { RunLine(palette: palette).padding(.top, 11) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if stop || face.endsTalk {
                    // In the lowest island the circles sit a little higher, clear of the corner.
                    HStack(spacing: 10) {
                        if face.endsTalk { EndTalkButton(circle: true) }
                        if stop { StopButton(surface: .island) }
                    }
                    .padding(.top, (line ? 16 : 6) + 9)
                    .transition(.opacity)
                }
            }
            .padding(.trailing, 20)
        } else {
            let top: CGFloat = face.size == .tall ? 3 : 5
            // A capsule 14 up and 24 in clears the corner of the system's clip.
            let bottom: CGFloat = switch face.size { case .low, .working: 0; case .asking, .tall: 14 }
            VStack(alignment: .leading, spacing: 0) {
                if hasKicker { Kicker(face: face, palette: palette).frame(height: 16).padding(.top, 1) }
                Title(face: face, palette: palette).padding(.top, hasKicker ? 2 : top)
                HStack(spacing: 6) {
                    Subtitle(face: face, palette: palette)
                    if face.badgePlace(.island) == .afterReason, let caller = face.caller { CallerBadge(name: caller, size: 18).frame(height: 16) }
                }
                .padding(.top, face.size == .tall ? 2 : 3)
                Spacer(minLength: 0)
                Control(face: face, surface: .island)
            }
            .padding(.trailing, 24)
            .padding(.bottom, bottom)
        }
    }
}

// MARK: Dynamic Island, compact and minimal

/// The whole small bear (ESP-503): ears, head and outline inside the 4.33 points the system cuts off,
/// a soft shade over its lower edge. A new state changes the pose where the bear stands. Short of
/// room, the bear in a circle 28 points across.
struct CompactLeading: View {
    var face: ActivityFace
    @Environment(\.isLuminanceReduced) private var dimmed
    var body: some View {
        let side = ActivityMetrics.compactBear
        let origin = face.bear.compactOrigin
        LimitedWidth { narrow in
            if narrow {
                NarrowBear(bear: face.bear)
            } else {
                ZStack {
                    Image(face.bear.image).resizable().interpolation(.high)
                        .frame(width: side, height: side)
                        .overlay(alignment: .bottom) { Rim(colour: .black.opacity(0.45), height: 6) }
                        .offset(x: origin.x, y: origin.y)
                        .frame(width: ActivityMetrics.compactBlock, height: ActivityMetrics.compactHeight, alignment: .topLeading)
                        .id(face.bear)
                        .transition(.opacity)
                }
                .frame(width: ActivityMetrics.compactBlock, height: ActivityMetrics.compactHeight)
                .clipped()
            }
        }
        .animation(dimmed ? nil : ActivityMotion.pose, value: face.bear)
        .accessibilityHidden(true)
    }
}

/// The right of the compact island: the app a run is in, its time, or a short word or symbol.
struct CompactTrailing: View {
    var face: ActivityFace
    @Environment(\.isLuminanceReduced) private var dimmed
    private let theme = ActivityTheme.current
    var body: some View {
        let palette = theme.island
        LimitedWidth { narrow in
            if narrow { self.narrow(palette) } else { wide(palette) }
        }
        .environment(\.colorScheme, .dark)
        .animation(dimmed ? nil : ActivityMotion.step, value: face.compact)
    }

    /// Short of room: the app's icon, a time, a short count or a symbol, inside a circle 28 points
    /// across. A count too long to fit leaves the block empty: the system then closes it.
    @ViewBuilder private func narrow(_ palette: ActivityPalette) -> some View {
        let side = ActivityMetrics.narrowCircle
        switch face.compact {
        case .app(let app, _):
            if let icon = AppIconFile.image(app) {
                AppIcon(image: icon, side: ActivityMetrics.narrowIcon).frame(width: side, height: side)
            } else {
                DefaultAppIcon(size: ActivityMetrics.narrowIcon).frame(width: side, height: side)
            }
        case .elapsed(let since):
            RunTime(since: since, font: theme.narrowTimer, colour: palette.text, width: 26).frame(width: side, height: side)
        case .text(let count, _) where count.contains("/") && count.count <= 5:
            Text(count).font(theme.narrowCount).foregroundStyle(palette.text)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth: 26).frame(width: side, height: side)
        case .countdown(let until), .asking(_, let until):
            Text(timerInterval: Countdown.range(until), countsDown: true)
                .font(theme.narrowTimer).foregroundStyle(palette.approval)
                .multilineTextAlignment(.center)
                .frame(width: 26).frame(width: side, height: side)
        case .symbol(let name, let tone):
            StateSymbol(name: name, tone: tone, palette: palette, size: name == "checkmark" ? 15.5 : name.hasPrefix("exclamationmark") ? 16 : 15)
                .frame(width: side, height: side)
        default:
            EmptyView()
        }
    }

    private func wide(_ palette: ActivityPalette) -> some View {
        ZStack {
            switch face.compact {
            case .app(let app, _):
                if let icon = AppIconFile.image(app) {
                    AppIcon(image: icon, side: ActivityMetrics.compactIcon).padding(.trailing, 3)
                } else {
                    DefaultAppIcon(size: ActivityMetrics.compactIcon).padding(.trailing, 3)
                }
            case .elapsed(let since):
                RunTime(since: since, font: theme.compact.monospacedDigit(), colour: palette.text, width: 42)
            case .text(let text, let tone):
                Text(text).font(theme.compact).foregroundStyle(palette.color(tone))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
            case .code(let code):
                Text(code).font(theme.compactCode).foregroundStyle(palette.accent)
                    .lineLimit(1).minimumScaleFactor(0.8)
            case .asking(let text, let until):
                VStack(alignment: .trailing, spacing: 0) {
                    Text(text).font(theme.compact).foregroundStyle(palette.approval).frame(height: 15)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    // No fixedSize on timer text (see TimerText): a fixed frame instead.
                    Text(timerInterval: Countdown.range(until), countsDown: true)
                        .font(theme.compactCount).foregroundStyle(palette.quiet)
                        .multilineTextAlignment(.trailing)
                        .frame(width: ActivityMetrics.compactWords, height: 13, alignment: .trailing)
                }
                .frame(width: ActivityMetrics.compactWords, alignment: .trailing)
            case .countdown(let until):
                TimerText(range: Countdown.range(until), down: true, colour: palette.approval, width: 42)
            case .symbol(let name, let tone):
                StateSymbol(name: name, tone: tone, palette: palette, size: name == "checkmark" ? 15.5 : name.hasPrefix("exclamationmark") ? 16 : 15)
            }
        }
        .frame(maxWidth: 52, alignment: .trailing)
        .clipped()
        .padding(.trailing, 4)
    }
}

/// The bear where the island is short of room: the whole bear in a circle 28 points across, placed
/// per pose (`ActivityBear.circleOrigin`).
private struct NarrowBear: View {
    var bear: ActivityBear
    var body: some View {
        let side = ActivityMetrics.circleBear
        let origin = bear.circleOrigin
        let circle = ActivityMetrics.narrowCircle
        ZStack {
            Image(bear.image).resizable().interpolation(.high)
                .frame(width: side, height: side)
                .offset(x: origin.x, y: origin.y)
                .frame(width: circle, height: circle, alignment: .topLeading)
                .id(bear)
                .transition(.opacity)
        }
        .frame(width: circle, height: circle)
        .clipShape(.circle)
    }
}

/// Another app's activity shares the island: only the bear, no ring, the whole bear inside the
/// circle's visible part (the circle less the 4.33 points the system cuts off), placed per pose.
struct MinimalView: View {
    var face: ActivityFace
    @Environment(\.isLuminanceReduced) private var dimmed
    var body: some View {
        let side = ActivityMetrics.circleBear
        let inset = ActivityMetrics.compactClip
        let origin = face.bear.circleOrigin
        let circle = ActivityMetrics.compactHeight
        LimitedWidth { narrow in
            if narrow {
                NarrowBear(bear: face.bear)
            } else {
                ZStack {
                    Image(face.bear.image).resizable().interpolation(.high)
                        .frame(width: side, height: side)
                        .offset(x: inset + origin.x, y: inset + origin.y)
                        .frame(width: circle, height: circle, alignment: .topLeading)
                        .id(face.bear)
                        .transition(.opacity)
                }
                .frame(width: circle, height: circle)
                .clipShape(.circle)
            }
        }
        .animation(dimmed ? nil : ActivityMotion.pose, value: face.bear)
        .accessibilityHidden(true)
    }
}

// MARK: Pieces

/// The bear in a corner: the whole square picture, its lower edge on the surface's, darkening
/// towards that edge as if it came up from inside. A new state changes the pose where the bear stands.
private struct RisingBear: View {
    var bear: ActivityBear
    var side: CGFloat
    var rim: CGFloat
    /// How far above the bottom edge the shade ends: where the surface's clip cuts the bear.
    var lift: CGFloat = 0
    var colour: Color
    var body: some View {
        ZStack {
            Image(bear.image).resizable().interpolation(.high)
                .frame(width: side, height: side)
                .id(bear)
                .transition(.opacity)
        }
        // The shade covers the bear alone: over a gradient a whole strip would show as a rectangle
        // beside it. While one pose fades into the next, it follows the next one's outline.
        .overlay(alignment: .bottom) {
            Rim(colour: colour, height: rim).padding(.bottom, lift)
                .mask(alignment: .bottom) { Image(bear.image).resizable().interpolation(.high).frame(width: side, height: side) }
        }
        .accessibilityHidden(true)
    }
}

private struct Rim: View {
    var colour: Color
    var height: CGFloat
    var body: some View {
        LinearGradient(colors: [colour.opacity(0), colour], startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .allowsHitTesting(false)
    }
}

/// Over the title: the app the run is in, in the accent colour, and beside it for a few seconds what
/// just happened ("Started", "Allowed").
private struct Kicker: View {
    var face: ActivityFace
    var palette: ActivityPalette
    private let theme = ActivityTheme.current
    var body: some View {
        HStack(spacing: 7) {
            if let kicker = face.kicker {
                Text(kicker).font(theme.kicker).foregroundStyle(palette.accent)
                    .contentTransition(.numericText())
                    .layoutPriority(1)
            }
            if let word = face.event {
                Text(word).font(theme.place)
                    .foregroundStyle(palette.color(face.eventTone))
                    .contentTransition(.interpolate)
            }
            // An outside agent's run: its badge follows the app's name and never gives way to it.
            if face.bottom.isProgress, let caller = face.caller { CallerBadge(name: caller, size: 18).frame(height: 16) }
        }
        .lineLimit(1).minimumScaleFactor(0.8)
    }
}

/// The main line. A new step's words blend into the old ones where they stand.
private struct Title: View {
    var face: ActivityFace
    var palette: ActivityPalette
    /// The Lock Screen's short cards say Poki's state in large type.
    var large = false
    private let theme = ActivityTheme.current
    var body: some View {
        if face.contentIsCode {
            Text(face.content)
                .font(theme.code).tracking(theme.codeTracking)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(height: 46)
                .contentTransition(.numericText())
        } else {
            // 19 points semibold for a step and a finished run, 20 bold for a question or a thing to do,
            // 24 bold for Poki's state on a short Lock Screen card.
            let stepLike = face.size == .working || face.size == .low
            Text(face.content)
                .font(large ? theme.status : stepLike ? theme.step : theme.title).tracking(theme.titleTracking)
                .foregroundStyle(palette.text.opacity(face.stale ? 0.72 : 1))
                .lineLimit(1).minimumScaleFactor(large ? 0.65 : 0.8)
                .contentTransition(.interpolate)
                .frame(height: large ? 30 : stepLike ? 24 : 25, alignment: .leading)
        }
    }
}

private struct Subtitle: View {
    var face: ActivityFace
    var palette: ActivityPalette
    /// More lines than the state asks for, where the column is narrow.
    var lines: Int?
    private let theme = ActivityTheme.current
    var body: some View {
        if let subtitle = face.subtitle {
            let lines = max(lines ?? 1, face.subtitleLines)
            Text(subtitle)
                .font(theme.subtitle)
                .foregroundStyle(palette.reason)
                .lineLimit(lines)
                .lineSpacing(lines > 1 ? 1 : 0)
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.interpolate)
        }
    }
}

/// The small value in a corner, with the outside agent's badge to its left.
private struct MetaCluster: View {
    var face: ActivityFace
    var palette: ActivityPalette
    var meta: ActivityFace.Meta
    /// The badge stands here; elsewhere it follows the app's name or the reason.
    var badge = true
    /// The room a running time keeps, so the words beside it do not shift as its digits change.
    var timer: CGFloat = 46
    private let theme = ActivityTheme.current
    var body: some View {
        HStack(spacing: 6) {
            if badge, let caller = face.caller { CallerBadge(name: caller, size: 18) }
            switch meta {
            case .none:
                EmptyView()
            case .text(let text):
                Text(text).font(theme.place).foregroundStyle(palette.quiet)
                    .lineLimit(1).minimumScaleFactor(0.8)
            case .countdown(let until):
                TimerText(range: Countdown.range(until), down: true, colour: palette.approval, width: timer)
            case .clock(let date):
                Text(date, style: .time).font(theme.place).foregroundStyle(palette.quiet).lineLimit(1)
            case .elapsed(let since):
                TimerText(range: since...since.addingTimeInterval(12 * 3600), down: false, colour: palette.quiet, width: timer)
            case .symbol(let name, let tone):
                StateSymbol(name: name, tone: tone, palette: palette, size: name == "checkmark" ? 16 : 17)
            }
        }
    }
}

/// A tick in the accent colour, or the red disc of a problem with its mark in white.
private struct StateSymbol: View {
    var name: String
    var tone: ActivityTone
    var palette: ActivityPalette
    var size: CGFloat
    var body: some View {
        if tone == .problem {
            Image(systemName: name).font(.system(size: size, weight: .semibold))
                .symbolRenderingMode(.palette).foregroundStyle(.white, ActivityTheme.red)
        } else {
            Image(systemName: name).font(.system(size: size, weight: .semibold))
                .foregroundStyle(palette.color(tone))
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

/// What sits at the bottom of a card: Stop, the approval's buttons, Done, Open Poki, or the setup
/// steps. On the expanded island a run's Stop is the round button beside the words instead.
private struct Control: View {
    var face: ActivityFace
    var surface: ActivitySurface
    private let theme = ActivityTheme.current

    var body: some View {
        let palette = theme.palette(surface)
        switch face.bottom {
        case .none:
            if face.endsTalk { EndTalkButton(circle: false).transition(.opacity) }
        case .progress(_, let stop):
            if surface == .lockScreen {
                HStack(spacing: 8) {
                    if stop { StopButton(surface: surface) }
                    if face.endsTalk { EndTalkButton(circle: false) }
                }
                .transition(.opacity)
            }
        case .approval(let id):
            ApprovalButtons(approvalID: id, surface: surface, stopAsking: face.offersStopAsking)
                .transition(.activityRow)
        case .deciding(let text):
            Text(text)
                .font(theme.button)
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: ActivityMetrics.button, maxHeight: ActivityMetrics.button)
                .background(palette.buttonFill, in: .capsule)
                .contentTransition(.interpolate)
        case .handoff(let id):
            HandoffDoneButton(handoffID: id, surface: surface)
                .transition(.activityRow)
        case .openPoki:
            Link(destination: face.link) {
                Text(String(activity: "Open Poki"))
                    .font(theme.button)
                    .foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity, minHeight: ActivityMetrics.button, maxHeight: ActivityMetrics.button)
                    .background(palette.buttonFill, in: .capsule)
            }
            .transition(.activityRow)
        case .segments(let number, let count):
            SegmentLine(step: number, total: count, palette: palette)
                .transition(.activityRow)
        }
    }
}

/// The run under way, without saying how far: a track with a soft light on it, the same at every
/// step. Drawn still: a Live Activity does not run repeating animations, and the island and the Lock
/// Screen card only change when an update comes.
private struct RunLine: View {
    var palette: ActivityPalette
    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                LinearGradient(colors: [palette.segmentDone.opacity(0), palette.segmentDone, palette.segmentDone.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: (box.size.width * 0.34).rounded())
                    .clipShape(.capsule)
                    .offset(x: box.size.width * 0.28)
            }
        }
        .frame(height: 4)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

/// How long the run has taken, counted up by the system, in the compact island.
private struct RunTime: View {
    var since: Date
    var font: Font
    var colour: Color
    var width: CGFloat
    var body: some View {
        // No fixedSize on timer text (see TimerText): a fixed frame instead.
        Text(timerInterval: since...since.addingTimeInterval(12 * 3600), countsDown: false)
            .font(font).foregroundStyle(colour)
            .multilineTextAlignment(.trailing)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(width: width, alignment: .trailing)
    }
}

/// An app's icon in the island: its own picture, the system's corner.
private struct AppIcon: View {
    var image: UIImage
    var side: CGFloat
    var body: some View {
        Image(uiImage: image).resizable().interpolation(.high)
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: side * 5 / 22, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The icon of the app a run is in, for the compact island. The app writes it to the App Group
/// container when the run comes into the app (the widget cannot look icons up itself), one file per
/// app, so a late or failed write never shows another app's icon.
enum AppIconFile {
    /// The island draws it at 22 points: three times that, and the file stays small.
    static let pixels: CGFloat = 66
    /// The app's own previews draw icons from this when there is no file (the widget never sets it).
    @MainActor static var preview: ((String) -> UIImage?)?

    static func url(_ app: String) -> URL? {
        let key = KnownApps.find(app)?.id ?? app.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = key.lowercased().utf8.prefix(64).map { String(format: "%02x", $0) }.joined()
        return SharedContainer.url?.appendingPathComponent("app-icons", isDirectory: true).appendingPathComponent(name + ".png")
    }

    @MainActor static func image(_ app: String) -> UIImage? {
        url(app).flatMap { UIImage(contentsOfFile: $0.path) } ?? preview?(app)
    }

    /// Writes `icon` for `app`, shrunk to `pixels`, unless the file is already there.
    static func write(_ icon: UIImage, for app: String) {
        guard let url = url(app), !FileManager.default.fileExists(atPath: url.path) else { return }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format).pngData { _ in
            icon.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? small.write(to: url, options: .atomic)
    }
}


/// One segment per step, 4 points high, 3 apart: lit up to the step under way, red where an action
/// under the step did not go through.
private struct SegmentLine: View {
    var step: Int
    var total: Int
    var palette: ActivityPalette
    var failed: [Int] = []
    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...max(1, total), id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index > step ? palette.track : failed.contains(index) ? palette.segmentFailed : palette.segmentDone)
                    .frame(height: 4)
            }
        }
        .animation(ActivityMotion.step, value: step)
        .accessibilityHidden(true)
    }
}

/// Don’t Allow and Allow, the same width. Allow asks for Face ID first (see ApproveActionIntent),
/// so it carries the Face ID glyph.
struct ApprovalButtons: View {
    var approvalID: String
    var surface: ActivitySurface
    /// Don’t Ask Again under the two answers, for a step that turning asking off reaches.
    var stopAsking = false
    private let theme = ActivityTheme.current

    var body: some View {
        VStack(spacing: ActivityMetrics.stopAskingGap) {
            answers
            if stopAsking { stopAskingButton }
        }
    }

    /// Like Allow it asks for Face ID first (see StopAskingIntent), and it allows this step too.
    private var stopAskingButton: some View {
        let palette = theme.palette(surface)
        return Button(intent: StopAskingIntent(approvalID: approvalID)) {
            Text(String(activity: "Don’t ask again"))
                .font(theme.button)
                .foregroundStyle(palette.text.opacity(0.8))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: ActivityMetrics.stopAskingText, maxHeight: ActivityMetrics.stopAskingText)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var answers: some View {
        let palette = theme.palette(surface)
        let height = ActivityMetrics.button
        return HStack(spacing: 8) {
            Button(intent: DenyActionIntent(approvalID: approvalID)) {
                Text(String(activity: "Don’t Allow"))
                    .font(theme.button)
                    .foregroundStyle(palette.text)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                    .background(palette.buttonFill, in: .capsule)
            }
            .buttonStyle(.plain)
            Button(intent: ApproveActionIntent(approvalID: approvalID)) {
                HStack(spacing: 6) {
                    Image(systemName: "faceid").font(.system(size: 13, weight: .semibold))
                    Text(String(activity: "Allow")).font(theme.button).lineLimit(1)
                }
                .foregroundStyle(palette.primaryText)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(palette.primaryFill, in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }
}

/// The one button of "your turn": the person finished what the agent could not do, and the agent
/// carries on (HandoffDoneIntent).
struct HandoffDoneButton: View {
    var handoffID: String
    var surface: ActivitySurface
    private let theme = ActivityTheme.current

    var body: some View {
        let palette = theme.palette(surface)
        let height = ActivityMetrics.button
        Button(intent: HandoffDoneIntent(handoffID: handoffID)) {
            Text(String(activity: "Continue"))
                .font(theme.button)
                .foregroundStyle(palette.primaryText)
                .lineLimit(1).minimumScaleFactor(0.85)
                .padding(.horizontal, 18)
                .frame(maxWidth: surface == .island ? .infinity : nil, minHeight: height, maxHeight: height)
                .background(palette.primaryFill, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Stop: stops the runner, and with it iOS's automation banner, until the agent's next request. On
/// the island it is drawn as the system draws Screen Recording's: a white ring round a red square.
/// On the blue card it is a white capsule with the red square and the word.
struct StopButton: View {
    var surface: ActivitySurface
    private let theme = ActivityTheme.current
    var body: some View {
        Button(intent: StopRunnerIntent()) {
            if surface == .island {
                let side = ActivityMetrics.stopCircle
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: side * 0.05)
                    RoundedRectangle(cornerRadius: side * 0.1, style: .continuous).fill(ActivityTheme.red)
                        .frame(width: side * 0.4, height: side * 0.4)
                }
                .frame(width: side, height: side)
                .contentShape(.circle)
            } else {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(ActivityTheme.red).frame(width: 11, height: 11)
                    Text(String(activity: "Stop")).font(theme.button).foregroundStyle(Color(hex: 0x111111))
                }
                .padding(.horizontal, 14)
                .frame(height: ActivityMetrics.stopCapsule)
                .background(.white, in: .capsule)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(activity: "Stop")))
    }
}

/// End during a talk with Poki: ends the talk and closes the microphone; a task Poki is on goes on.
/// Beside the island's Stop, a circle with the microphone struck through; elsewhere a white capsule
/// that says End, drawn as Stop is. Ending a talk here is pull request #250's interaction.
struct EndTalkButton: View {
    var circle: Bool
    private let theme = ActivityTheme.current
    var body: some View {
        Button(intent: EndTalkIntent()) {
            if circle {
                let side = ActivityMetrics.stopCircle
                Image(systemName: "mic.slash.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: side, height: side)
                    .background(.white.opacity(0.18), in: .circle)
                    .contentShape(.circle)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "mic.slash.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(ActivityTheme.red)
                    Text(String(activity: "End")).font(theme.button).foregroundStyle(Color(hex: 0x111111))
                }
                .padding(.horizontal, 14)
                .frame(height: ActivityMetrics.stopCapsule)
                .background(.white, in: .capsule)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(activity: "End talk")))
    }
}

/// A time the system counts by itself between updates: an approval's time left, a run's time so far.
private struct TimerText: View {
    var range: ClosedRange<Date>
    var down: Bool
    var colour: Color
    var width: CGFloat
    var body: some View {
        // No fixedSize on timer text: it blanks the whole card on iOS 26.
        Text(timerInterval: range, countsDown: down)
            .font(ActivityTheme.current.value).foregroundStyle(colour)
            .multilineTextAlignment(.trailing)
            .frame(width: width, alignment: .trailing)
    }
}

enum Countdown {
    /// Counting down to `until`. The start is fixed just under an hour before it (not "now", which the
    /// system may take at another moment than it draws), so the remaining time is always `until - now`.
    static func range(_ until: Date) -> ClosedRange<Date> { until.addingTimeInterval(-3599)...until }
}

/// The latest screenshot, read from the App Group container and drawn like a small phone. The view is
/// drawn again with every update, so a new file shows in place, without a fade. A file that cannot
/// be read is no screenshot: the card then lays its words out to the right edge.
struct Thumbnail: View {
    /// The app's own previews draw this when there is no file (the widget never sets it).
    @MainActor static var previewImage: UIImage?
    @MainActor static var picture: UIImage? { (SharedContainer.thumbnailURL.flatMap { UIImage(contentsOfFile: $0.path) }) ?? previewImage }
    var image: UIImage
    var size: CGSize
    var corner: CGFloat
    private let theme = ActivityTheme.current
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Image(uiImage: image).resizable().scaledToFill()
            .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.glassEdge, lineWidth: 1))
    }
}
