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

struct Marquee<Content: View>: UIViewRepresentable {
    /// Points a second: positive moves the row to the left, negative to the right.
    var speed: Double
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

    func makeUIView(context: Context) -> MarqueeScrollView {
        let view = MarqueeScrollView()
        view.start = start
        apply(to: view)
        return view
    }

    func updateUIView(_ view: MarqueeScrollView, context: Context) { apply(to: view) }

    private func apply(to view: MarqueeScrollView) {
        let content = content, spacing = spacing, loops = loops
        view.configure(spacing: spacing, loops: loops) { copies in
            AnyView(HStack(spacing: spacing) {
                ForEach(0..<copies, id: \.self) { _ in
                    HStack(spacing: spacing) { content }.glassGroupIf(PillLook.live, spacing: spacing)
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

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarqueeScrollView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        return CGSize(width: width, height: uiView.stripHeight)
    }
}

/// The scroll view under `Marquee`. Its content is the row laid out `copies` times; the position is
/// kept inside the second copy by whole content widths, whoever moved it.
final class MarqueeScrollView: UIScrollView {
    var speed: Double = 0
    var running = true { didSet { if running != oldValue { wake() } } }
    var active = true { didSet { if active != oldValue { wake() } } }
    var stopped = false { didSet { if stopped != oldValue { wake() } } }
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
    private var last: CFTimeInterval = 0
    private var velocity: Double = 0
    /// How far the row has gone by itself, kept within one period: the content's transform.
    private var drift: Double = 0
    private var held = false
    private var resumeAt: CFTimeInterval = 0

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
        host.safeAreaRegions = []
        addSubview(host.view)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: MarqueeScrollView, _: UITraitCollection) in
            view.stale = true
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(spacing: CGFloat, loops: Bool, make: @escaping (Int) -> AnyView) {
        if loops != self.loops {
            placed = false
            drift = 0
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
        link.preferredFrameRateRange = PerfSwitch.on(.old120)
            ? CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        wake()
    }

    /// The clock runs while the row has something to do: it is in front, and it goes by itself or
    /// is still coming to rest.
    private func wake() {
        let needed = active && loops && (running || abs(velocity) > 0.05)
        guard let link, link.isPaused == needed else { return }
        link.isPaused = !needed
        last = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let delta = last > 0 ? min(max(0, now - last), 0.1) : 0
        last = now
        guard loops, period > 0 else { return }
        if isTracking || isDragging || isDecelerating || stopped {
            // A finger is on the row, the row still glides from its flick, or a pill's menu is open:
            // it stops going by itself at once and is the scroll view's to move.
            held = true
            velocity = 0
            MarqueeLog.note(self, now, "held")
            return
        }
        if held {
            held = false
            resumeAt = now + Self.rest
        }
        let target = running && now >= resumeAt ? speed : 0
        velocity += (target - velocity) * delta * 3
        if target == 0, abs(velocity) <= 0.05 {
            // At rest the content sits on whole pixels, so its text is sharp.
            velocity = 0
            let scale = max(traitCollection.displayScale, 1)
            drift = (drift * scale).rounded() / scale
            host.view.transform = CGAffineTransform(translationX: -drift, y: 0)
            MarqueeLog.note(self, now, "rest")
            wake()
            return
        }
        drift = (drift + velocity * delta).truncatingRemainder(dividingBy: period)
        if drift < 0 { drift += period }
        host.view.transform = CGAffineTransform(translationX: -drift, y: 0)
        MarqueeLog.note(self, now, "auto")
    }

    /// Where the row is, as the scroll view's position plus what it went by itself.
    fileprivate var shown: Double { Double(bounds.origin.x) + drift }
    fileprivate var finger: CGFloat { panGestureRecognizer.location(in: nil).x }
    fileprivate var pace: Double { velocity }
}

/// `-pokiMarqueeLog YES` writes what a row did, frame by frame, to Caches/marquee.log: for checking
/// in the simulator that a row follows the finger and when it goes on again. Debug builds only.
enum MarqueeLog {
    #if DEBUG
    private static let on = UserDefaults.standard.bool(forKey: "pokiMarqueeLog")
    private static var lines: [String] = []
    private static var flushed: CFTimeInterval = 0
    static func note(_ view: MarqueeScrollView, _ now: CFTimeInterval, _ what: String) {
        guard on else { return }
        lines.append(String(format: "%.4f %@ %@ shown %.2f finger %.1f pace %.2f", now, String(UInt(bitPattern: ObjectIdentifier(view).hashValue) % 1000), what, view.shown, view.finger, view.pace))
        guard now - flushed > 0.5, let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        flushed = now
        try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("marquee.log"), atomically: true, encoding: .utf8)
    }
    #else
    @inline(__always) static func note(_ view: MarqueeScrollView, _ now: CFTimeInterval, _ what: String) {}
    #endif
}
