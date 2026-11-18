// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from JosssphZhou/poki Chat/Marquee.swift at
// 69585293051fee03c7ad110f037d8f4dd2a4e96f.
// Original algorithm and MIT MarqueeSwiftUI attribution follow below.
// Amore changes: namespacing, iOS16 fallback, stable content revision,
// lifecycle/performance instrumentation without file IO, and test hooks.
// The home page's suggestion rows: a row that goes by on its own, slowly and without an end, and that
// a finger stops, moves and flicks as it does any scroll view, because it is one (ESP-340, the owner:
// "it has to scroll, sideways, not too fast, but it must be smooth").
//
// Two things here follow nainamaharjan/MarqueeSwiftUI (commit 0b877e64, MarqueeSwiftUI/MarqueeView.swift,
// MIT License, Copyright (c) 2024 nainamaharjan; see THIRD_PARTY_NOTICES.md): the row moves by the
// time that really passed since the last frame, its speed easing toward where it should be
// (`velocity += (target - velocity) * delta * 3`), and the content is laid out several times over
// while the position wraps by one content's width, so there is no seam and no repeating animation
// that jumps where it starts again. That file was first carried over whole and measured in the
// simulator. By itself the row moved evenly; under a finger it followed for about a second and then
// stood still while the finger went on, inside the home page's own scroll view. So the touch is the
// system's here: a `UIScrollView` holds the pills, which gives the stop on touch, the following, the
// flick and the difference between a tap and a drag as every scroll view has them. Folding the
// position back while it scrolls, in `layoutSubviews`, is the way Apple's StreetScroller sample makes
// a scroll view endless (written from memory of it, not copied).
//
// What moves the row on its own is a transform on the content, set once a display frame from a
// `CADisplayLink`: a transform is not rounded to whole pixels, so 18 points a second is an even
// glide and not a step every few frames. The scroll view's own position is left to the finger.
import SwiftUI
import UIKit

struct AmoreMarquee<Content: View>: UIViewRepresentable {
    /// Points a second: positive moves the row to the left, negative to the right.
    var speed: Double
    var revision: String = ""
    var spacing: CGFloat = 8
    /// How far along its content the row starts.
    var start: CGFloat = 0
    /// Points over which each end of the row fades out; 0 cuts it at its edges.
    var edgeFade: CGFloat = 0
    /// Goes by itself. False (Reduce Motion, Low Power Mode, the keyboard up) lets it come to rest; a
    /// finger still moves it.
    var running = true
    /// The page is in front. Otherwise the clock stops.
    var active = true
    /// Endless. False draws the content once, as a plain row that scrolls (VoiceOver reads each thing once).
    var loops = true
    /// Stands still at once, as under a finger, while something lifted from it is open (a pill's menu).
    var stopped = false
    @ViewBuilder var content: Content

    func makeUIView(context: Context) -> AmoreMarqueeScrollView {
        let view = AmoreMarqueeScrollView()
        view.start = start
        apply(to: view)
        return view
    }

    func updateUIView(_ view: AmoreMarqueeScrollView, context: Context) { apply(to: view) }

    private func apply(to view: AmoreMarqueeScrollView) {
        let content = content, spacing = spacing, loops = loops
        view.configure(revision: revision, spacing: spacing, loops: loops) { copies in
            AnyView(HStack(spacing: spacing) {
                ForEach(0..<copies, id: \.self) { _ in
                    HStack(spacing: spacing) { content }
                }
            }
            .padding(.horizontal, loops ? 0 : 20)
            .fixedSize())
        }
        view.speed = speed
        view.edgeFade = edgeFade
        view.running = running
        view.active = active
        view.stopped = stopped
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AmoreMarqueeScrollView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        return CGSize(width: width, height: uiView.stripHeight)
    }
}

/// The scroll view under `Marquee`. Its content is the row laid out `copies` times; the position is
/// kept inside the second copy by whole content widths, whoever moved it.
final class AmoreMarqueeScrollView: UIScrollView {
    var speed: Double = 0
    var running = true { didSet { if running != oldValue { wake() } } }
    var active = true { didSet { if active != oldValue { wake() } } }
    var stopped = false {
        didSet {
            if stopped != oldValue {
                if stopped { clock.hold() }
                wake()
            }
        }
    }
    var start: CGFloat = 0
    var edgeFade: CGFloat = 0 { didSet { if edgeFade != oldValue { setNeedsLayout() } } }
    private(set) var stripHeight: CGFloat = 48
    /// The ends' fade (ESP-474). A mask SwiftUI puts around the row fades the pills' words but not
    /// their glass, which stood cut off at the screen's edges; on this view's own layer it fades both.
    /// It is laid over the visible part, so it stays where it is while the row goes by under it.
    private let fade: CAGradientLayer = {
        let fade = CAGradientLayer()
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [UIColor.clear, .black, .black, .clear].map(\.cgColor)
        return fade
    }()

    /// How long after the finger has lifted and the row has come to rest it goes on by itself again.
    static let rest: CFTimeInterval = 2

    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var make: ((Int) -> AnyView)?
    private var spacing: CGFloat = 8
    private var loops = true
    private var copies = 4
    /// One content's width and the space after it: the distance after which the row looks the same.
    private var period: CGFloat = 0
    private var stale = true
    private var placed = false
    private var laidWidth: CGFloat = 0

    private var link: CADisplayLink?
    private var clock = AmoreMarqueeClock()

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        scrollsToTop = false
        // The pills' glass and its shadow reach past the row, as `scrollClipDisabled` allowed before.
        clipsToBounds = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        addSubview(host.view)
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: AmoreMarqueeScrollView, _: UITraitCollection) in
                view.stale = true; view.setNeedsLayout()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private var contentRevision: String?
    func configure(revision: String, spacing: CGFloat, loops: Bool, make: @escaping (Int) -> AnyView) {
        guard contentRevision != revision || self.spacing != spacing || self.loops != loops else { return }
        contentRevision = revision
        if loops != self.loops {
            placed = false
            clock.resetDrift()
            host.view.transform = .identity
        }
        self.spacing = spacing
        self.loops = loops
        self.make = make
        host.rootView = make(loops ? copies : 1)
        stale = true
        setNeedsLayout()
        wake()
    }

    /// Sizes the content, and lays out as many copies as fill the row with one to spare on each side
    /// of the copy the position is kept in, plus one period for the drift.
    private func measure() {
        stale = false
        laidWidth = bounds.width
        let open = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        var size = host.sizeThatFits(in: open)
        if loops, size.width > 0 {
            let one = (size.width + spacing) / CGFloat(copies)
            let needed = max(4, Int(((bounds.width + spacing) / one).rounded(.up)) + 3)
            if needed != copies, let make {
                copies = needed
                host.rootView = make(copies)
                size = host.sizeThatFits(in: open)
            }
            period = (size.width + spacing) / CGFloat(copies)
        } else {
            period = 0
        }
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.center = CGPoint(x: size.width / 2, y: size.height / 2)
        contentSize = CGSize(width: size.width, height: 0)
        if abs(size.height - stripHeight) > 0.5, size.height > 0 {
            stripHeight = size.height
            invalidateIntrinsicContentSize()
        }
        if loops, !placed, period > 0, bounds.width > 0 {
            placed = true
            bounds.origin.x = period + start
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if stale || laidWidth != bounds.width { measure() }
        placeFade()
        guard loops, period > 0 else { return }
        var x = bounds.origin.x
        while x >= 2 * period { x -= period }
        while x < period { x += period }
        if x != bounds.origin.x { bounds.origin.x = x }
    }

    /// Over the visible part, and past it above and below for the glass's shadow.
    private func placeFade() {
        guard edgeFade > 0, bounds.width > 2 * edgeFade else { layer.mask = nil; return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let end = Double(edgeFade / bounds.width)
        fade.locations = [0, end, 1 - end, 1].map { NSNumber(value: $0) }
        fade.frame = bounds.insetBy(dx: 0, dy: -24)
        CATransaction.commit()
        if layer.mask !== fade { layer.mask = fade }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // 60 frames a second. At 18 to 20 points a second that is a third of a point, one pixel on a
        // 3x screen, a frame: as even a glide as 120 gives, and the page is not drawn twice as often
        // for it. Other motion (the drawer, scrolling) still gets 120 where the display has it.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        wake()
    }

    /// The clock runs while the row has something to do: it is in front, and it goes by itself or
    /// is still coming to rest.
    private func wake() {
        let needed = active && loops && !stopped && (running || abs(clock.velocity) > 0.05)
        guard let link, link.isPaused == needed else { return }
        link.isPaused = !needed
        clock.resetTimestamp()
    }

    @objc private func tick(_ link: CADisplayLink) { advance(to: link.targetTimestamp) }

    /// Deterministic production tick, also exercised by simulator tests.
    func advance(to now: CFTimeInterval) {
        guard active, loops, period > 0 else { return }
        let state = clock.advance(to: now, period: Double(period), speed: speed,
                                  running: running,
                                  touching: isTracking || isDragging || isDecelerating || stopped,
                                  scale: Double(traitCollection.displayScale))
        host.view.transform = CGAffineTransform(translationX: -clock.drift, y: 0)
        AmoreMarqueeLog.note(self, now, state)
        if state == "rest" { wake() }
    }

    var animationClockPaused: Bool { link?.isPaused ?? true }
    var repeatedPeriod: CGFloat { period }
    var contentCopies: Int { copies }
    deinit { link?.invalidate() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            stale = true; setNeedsLayout()
        }
    }

    /// Where the row is, as the scroll view's position plus what it went by itself.
    var shown: Double { Double(bounds.origin.x) + clock.drift }
    var finger: CGFloat { panGestureRecognizer.location(in: nil).x }
    var pace: Double { clock.velocity }
}

/// No per-frame disk writes. Runtime counters are read only by component tests.
enum AmoreMarqueeLog {
    @inline(__always) static func note(_ view: AmoreMarqueeScrollView, _ now: CFTimeInterval, _ what: String) {}
}
