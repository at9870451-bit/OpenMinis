import SwiftUI
import UIKit

// The drawer follows OpenBot's app drawer (OpenBot, apps/mobile/src/features/servers/components/
// app-drawer-shell.tsx, PolyForm Noncommercial License 1.0.0), moved from React Native to SwiftUI: the
// drawer lies under the page and the page slides away to uncover it; one progress value from 0 (closed)
// to 1 (open) that the finger moves directly; on release the progress plus a sixth of a second of the
// finger's speed decides open or closed, past 0.45 when opening and 0.55 when closing; the spring starts
// at the finger's speed; the page's corners round within the first 15 % of the way, to the larger of
// 34 points and the safe area; the drawer comes in from 24 points to the leading side and from 55 %
// opacity; the uncovered page dims and a tap on it closes. Changed from OpenBot: the uncovered strip is
// a little over a fifth of the screen, as in ChatGPT's iPhone app; no blur over the page; the spring
// bounces a little; a drag past fully open stretches with resistance.
// OpenBot: https://github.com/nightly-labs/openbot at commit a74951c.
// Required Notice: Copyright 2026 Synthetify Labs spółka z ograniczoną odpowiedzialnością.
//
// The page as a card with a hairline edge and a shadow on the drawer follows DrawerSideBar
// (shubhamKachhiya/DrawerSideBar at commit 93370a0, Sources/DrawerSideBar/SideBarNavigationView.swift,
// MIT License, Copyright (c) 2026 shubhamKachhiya). Changed from it: no scaling of the page, and its corners are drawn
// with the drawer's own colour rather than by clipping the page.

/// The conversations as a drawer under the chat (iPhone): the chat is a card that slides to the
/// trailing side with the finger and uncovers them, a strip of it left showing. A tap on that strip or a
/// drag back toward the leading side closes it. iOS has no drawer of its own on iPhone, so this one is
/// drawn; what is inside it is a system List.
///
/// A drag opens it only while the chat itself is in front (`enabled`): with a page pushed over the
/// chat, the leading edge belongs to the system's swipe back. Open, a sideways drag anywhere closes it.
///
/// Reduce Motion: nothing slides; the conversations fade in over the chat where they rest.
struct ThreadsDrawer<Drawer: View>: ViewModifier {
    @Binding var isOpen: Bool
    var enabled: Bool
    @ViewBuilder var drawer: () -> Drawer

    /// How far open the drawer is: 0 closed, 1 open, a little past either while the spring settles.
    @State private var progress: CGFloat = 0
    /// The progress when the drawer's current drag began; nil while none is under way.
    @State private var dragStart: CGFloat?
    /// True once the drawer has closed all the way. Set when the closing spring ends, not with the progress
    /// itself: the progress jumps to its target and the spring only draws the way there.
    @State private var hidden = true
    /// From the moment a drag takes the drawer until just after the finger lifts. The list's buttons
    /// ignore their taps meanwhile (`drawerSliding`): a row lets its tap through when the finger lifts
    /// inside it, however far it went sideways. Only that lift: a tap a moment later, while the spring
    /// still settles, opens the row.
    @State private var sliding = false
    /// True while a drag is under way, so a drag the system cancels (no `onEnded`) still settles.
    @GestureState private var dragging = false
    @State private var screen = CGSize(width: 402, height: 874)
    @State private var insets = EdgeInsets()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// Where the content scrolls sideways by itself (`scrollsSideways`), in screen coordinates.
    @State private var sideways: [CGRect] = []

    private var layout: ThreadsDrawerLayout { ThreadsDrawerLayout(screen: screen, insets: insets) }
    /// The progress for what is drawn: never below closed, and while it bounces, not far past open.
    private var shown: CGFloat { min(max(progress, 0), 1.08) }
    private var settled: CGFloat { min(shown, 1) }

    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            menu.zIndex(reduceMotion ? 2 : 0)
            card(content).zIndex(1)
        }
        .simultaneousGesture(drag, including: (enabled || isOpen) ? .all : .subviews)
        .background(Tint.sidebar.ignoresSafeArea())
        // The safe area, read where it is kept (a reader that ignores it reads none).
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { insets = geometry.safeAreaInsets }
                    .onChange(of: geometry.safeAreaInsets) { _, new in insets = new }
            }
            .ignoresSafeArea(.keyboard)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { screen = geometry.size }
                    .onChange(of: geometry.size) { _, new in screen = new }
            }
            .ignoresSafeArea()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isOpen)
        .onChange(of: isOpen) { _, open in
            // The keyboard belongs to the chat's message field, not to the list beside it.
            if open { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            // Opened or closed from elsewhere (the chat's button, a row, a launch argument): the same spring.
            if dragStart == nil, progress != (open ? 1 : 0) { settle(open, speed: 0) }
        }
        .onChange(of: dragging) { _, now in
            // The system took the drag away before it ended: go back to where it was.
            if !now, dragStart != nil { dragStart = nil; release(); settle(isOpen, speed: 0) }
        }
        .onAppear { progress = isOpen ? 1 : 0; hidden = !isOpen }
    }

    /// The chat as the card on top: it slides to the trailing side, its leading corners round, its edge
    /// and shadow show against the drawer, and it dims. Open, it takes every touch for itself: a tap closes.
    private func card(_ content: Content) -> some View {
        let radius = layout.corner(settled)
        let dark = scheme == .dark
        return content
            .environment(\.coveredByDrawer, isOpen)
            .accessibilityHidden(isOpen)
            .onPreferenceChange(SidewaysScrollAreas.self) { sideways = $0 }
            .overlay { cover(dark: dark) }
            .overlay {
                if !hidden, !reduceMotion {
                    ZStack {
                        CardCorners(radius: radius).fill(Tint.sidebar)
                        RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity((dark ? 0.16 : 0.08) * settled), lineWidth: 0.5)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
            }
            .background {
                if !hidden, !reduceMotion {
                    RoundedRectangle(cornerRadius: radius).fill(Tint.page)
                        .shadow(color: .black.opacity((dark ? 0.5 : 0.07) * settled), radius: 20, x: -2)
                        .ignoresSafeArea()
                }
            }
            .offset(x: reduceMotion ? 0 : shown * layout.travel)
    }

    /// Over the uncovered chat: a dim, so its own buttons do not look like they can be tapped, and the
    /// touch that closes the drawer.
    private func cover(dark: Bool) -> some View {
        Color.black.opacity((dark ? ThreadsDrawerMotion.dimDark : ThreadsDrawerMotion.dim) * settled)
            .ignoresSafeArea()
            .contentShape(.rect)
            .onTapGesture { settle(false, speed: 0) }
            .allowsHitTesting(isOpen)
            .accessibilityElement()
            .accessibilityLabel(Text("Close Conversations"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { settle(false, speed: 0) }
            .accessibilityHidden(!isOpen)
    }

    /// The conversations, on the drawer's own ground, under the card.
    private var menu: some View {
        drawer()
            .environment(\.inThreadsDrawer, true)
            .frame(width: layout.travel)
            .overlay(alignment: .trailing) {
                // With Reduce Motion the list lies over the chat: a hairline where it ends.
                if reduceMotion { Rectangle().fill(Color(.separator)).frame(width: 0.5).ignoresSafeArea() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .offset(x: reduceMotion ? 0 : (settled - 1) * ThreadsDrawerMotion.menuShift)
            .opacity(reduceMotion ? settled : (hidden ? 0 : 0.55 + 0.45 * settled))
            .environment(\.drawerSliding, sliding)
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)
            .accessibilityAction(.escape) { settle(false, speed: 0) }
    }

    /// Opens or closes with the drawer's spring, starting at `speed` (progress per second). With Reduce
    /// Motion a fade.
    private func settle(_ open: Bool, speed: CGFloat) {
        let target: CGFloat = open ? 1 : 0
        let animation = reduceMotion ? ThreadsDrawerMotion.fade : ThreadsDrawerMotion.spring(from: progress, to: target, speed: speed)
        if open { hidden = false }
        withAnimation(animation, completionCriteria: .removed) { progress = target } completion: {
            if progress == 0, dragStart == nil { hidden = true }
        }
        if isOpen != open { isOpen = open }
    }

    /// Lets the list's buttons take taps again once the lift that ended the drag has passed them by.
    private func release() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { if dragStart == nil { sliding = false } }
    }

    /// The drag began on something that scrolls sideways itself (the home page's suggestion rows),
    /// and not at the screen's very edge: it is that row's, not the drawer's.
    private func scrolls(_ value: DragGesture.Value) -> Bool {
        !isOpen && value.startLocation.x > 24 && sideways.contains { $0.contains(value.startLocation) }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                let dx = value.translation.width
                if dragStart == nil {
                    // A mostly sideways drag in the drawer's direction; an up or down one belongs to the scroll view.
                    guard abs(dx) > abs(value.translation.height) * 1.5, isOpen ? dx < 0 : dx > 0, !scrolls(value) else { return }
                    dragStart = progress
                    sliding = true
                }
                guard let start = dragStart else { return }
                var next = start + dx / layout.travel
                // Past fully open the card stretches with resistance.
                if next > 1 { next = 1 + (next - 1) * 0.12 }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { progress = max(0, next); hidden = false }
            }
            .onEnded { value in
                guard dragStart != nil else { return }
                dragStart = nil
                release()
                let speed = value.velocity.width / layout.travel
                let projected = min(progress, 1) + speed / 6
                settle(projected > (isOpen ? 0.55 : 0.45), speed: speed)
            }
    }
}

/// Where the card rests when open, from the screen's size and safe area.
struct ThreadsDrawerLayout {
    var screen: CGSize
    var insets: EdgeInsets

    /// The strip of the chat left showing when open: a little over a fifth of the screen.
    var strip: CGFloat { max(72, (screen.width * 0.22).rounded()) }

    /// How far the card moves from closed to open, and how far the finger moves it: the same distance, so
    /// the card stays under the finger. Also the drawer's width.
    var travel: CGFloat { max(min(screen.width - strip, 420), 1) }

    /// The card's corners at `progress`: square when closed, round within the first 15 % of the way, as
    /// round as the iPhone's own where it has round corners.
    func corner(_ progress: CGFloat) -> CGFloat {
        max(34, insets.top, insets.bottom) * min(1, max(0, progress) / 0.15)
    }
}

/// The two leading corners outside a rounded card, filled with the drawer's colour: the card looks
/// rounded without the whole chat being clipped on every frame.
struct CardCorners: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, rect.width / 2, rect.height / 2)
        guard r > 0 else { return path }
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
        path.closeSubpath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.closeSubpath()
        return path
    }
}

enum ThreadsDrawerMotion {
    /// The spring the drawer settles with when opened or closed by a button or a tap.
    static let settle = Animation.interpolatingSpring(duration: 0.42, bounce: 0.12)
    /// With Reduce Motion: a plain fade.
    static let fade = Animation.easeInOut(duration: 0.22)
    /// The uncovered chat's dim at fully open, in light and in dark.
    static let dim: CGFloat = 0.06
    static let dimDark: CGFloat = 0.3
    /// How far to the leading side the list starts as the card begins to move.
    static let menuShift: CGFloat = 24

    /// The spring from `from` to `to`, starting at the finger's `speed` (progress per second).
    /// SwiftUI takes the starting speed as a share of the distance to go.
    static func spring(from: CGFloat, to: CGFloat, speed: CGFloat) -> Animation {
        let distance = to - from
        guard abs(distance) > 0.01, speed != 0 else { return settle }
        let share = max(-4, min(12, speed / distance))
        return .interpolatingSpring(duration: 0.42, bounce: 0.12, initialVelocity: share)
    }
}

extension EnvironmentValues {
    /// True while the drawer is open over this page: its own motion (the light's breathing, the bear's
    /// blinking, the suggestion rows) stands still until it closes.
    @Entry var coveredByDrawer = false
    /// True inside the drawer, where a sideways drag over the list closes it rather than swiping a row.
    @Entry var inThreadsDrawer = false
    /// True while a drag moves the drawer: a button in it that the finger lifts from does nothing. Not
    /// `disabled`, which greys the list as it moves.
    @Entry var drawerSliding = false
}

/// Where on the screen a sideways drag belongs to the content: such a view says where it is, and the
/// drawer's swipe leaves drags that begin there alone.
struct SidewaysScrollAreas: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    /// Marks this view as scrolling sideways by itself while `on`.
    func scrollsSideways(_ on: Bool = true) -> some View {
        background { GeometryReader { geometry in Color.clear.preference(key: SidewaysScrollAreas.self, value: on ? [geometry.frame(in: .global)] : []) } }
    }
}

extension View {
    func threadsDrawer<Drawer: View>(isOpen: Binding<Bool>, enabled: Bool, @ViewBuilder drawer: @escaping () -> Drawer) -> some View {
        modifier(ThreadsDrawer(isOpen: isOpen, enabled: enabled, drawer: drawer))
    }
}
