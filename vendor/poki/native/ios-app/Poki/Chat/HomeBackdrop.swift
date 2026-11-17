import SwiftUI

/// The light behind the chat (ESP-376, the owner's pick "fog blue"), two layers one over the other.
/// The conversation's ground is always there: a clean pale page with a faint brand-blue glow behind
/// the message field, under a quarter of the screen high, still unless Poki is at work. Over it, on the
/// home page, lies the home's light: paper white above, blue rising from the bottom edge, breathing
/// slowly (ESP-470). In light, your first message makes the home's light sink 260 points and fade, so
/// it seems to draw back to the glow and stop there. In dark it stays where it is, stops breathing and
/// dims to a little under half: under the dark ground's plain top three quarters the conversation read
/// as black after the home's blue, so it keeps the same light, only quieter, and going in is a dimming
/// rather than a change of ground.
///
/// Points, colours, grain and bright edge are the design's final table (定稿-首页渐变和玻璃参数,
/// sections 1 to 4, 9 and 10). The system's mesh was laid beside the design's own rendering of the same
/// table before anything was moved, and the table's points are used as they are; the breathing moves
/// them about those places and never changes a colour. Nothing in here may be wider than the page: a
/// stack takes the width of its widest layer and stretches the meshes to it, which is how the bright
/// edge, laid in the stack at its own 797 points, once showed only the middle half of the light.
///
/// The light stands still in the shape of the table with Reduce Motion or Low Power Mode on or the phone
/// running hot, and its clock stops while the app is not active, another page covers this one or the
/// drawer is open. With Reduce Motion nothing sinks either; the change between the two layers is a fade.
struct HomeBackdrop: View {
    /// The home page is in front.
    var home: Bool
    /// Poki is at work in the conversation: its glow drifts.
    var working: Bool
    /// Stands still at rest, for laying a screenshot beside the design (`-pokiChat backdrop`).
    var frozen = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.coveredByDrawer) private var covered
    /// False while another page is pushed over this one.
    @State private var shown = false
    /// How strongly the home's light shows behind the conversation in dark: as much as keeps the system's
    /// secondary text above 4.5 to 1 right down to the message field, where the light is brightest. At
    /// half it measured 4.4 there.
    static let darkChatLight = 0.45

    var body: some View {
        let dark = scheme == .dark
        let strained = DeviceStrain.shared.resting
        let resting = reduceMotion || frozen || strained || PerfSwitch.on(.backdropStill)
        let seen = shown && scenePhase == .active && !covered
        let breathing = home && !resting && seen ? 1.0 : 0
        ZStack(alignment: .bottom) {
            Tint.page
            // Starting or stopping, the drift eases in and out over 600 ms; it never jumps back.
            DriftingMesh(mesh: .chat, dark: dark, drift: working && !home && !resting && seen ? 1 : 0)
                .animation(.easeInOut(duration: 0.6), value: working)
            DriftingMesh(mesh: .home, dark: dark, drift: breathing)
                .overlay(alignment: .bottom) { EdgeLight(dark: dark) }
                .offset(y: home || reduceMotion || dark ? 0 : 260)
                .opacity(home ? 1 : dark ? Self.darkChatLight : 0)
                .animation(HomeMotion.ground(reduceMotion), value: home)
        }
        // Coming back to the page, the light takes a second to start breathing again rather than
        // jumping to where its clock has got to.
        .animation(.easeInOut(duration: 1), value: seen && !strained)
        .overlay { Grain.image.resizable(resizingMode: .tile).opacity(0.03).blendMode(.overlay) }
        .compositingGroup()
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear { shown = true }
        .onDisappear { shown = false }
    }
}

/// The home light's breathing (ESP-470: the owner asked for a breathing like the Gemini app's, on
/// the colours as they are), its settings in one place to tune on a phone.
///
/// Once a `period` the band of light rises and settles: the lowest of the three middle rows by
/// `rise` of the page's height, the two above it by less, all together. The lower blues and the
/// bottom edge drift sideways by up to `flow` of the page's width: each row as a piece at its own
/// pace, and each point a little on its own, so the colours slide past each other rather than sway in
/// step. The band also dims and brightens by `glow`, a quarter breath after it rises, so it does not
/// swell as one block. No two paces divide evenly, so the light never comes back to the same shape in
/// step and is never seen to start again. The top row and the four corners never move; the side
/// points only slide along their edge.
enum HomeBreath {
    /// Seconds for one breath.
    static let period: Double = 7.5
    /// How far the band rises and settles, as a share of the page's height.
    static let rise: Float = 0.11
    /// How far the lower blues drift sideways at most, as a share of the page's width.
    static let flow: Float = 0.15
    /// How much the band dims at the bottom of its breath, as a share of its strength.
    static let glow: Double = 0.09

    static let motion: [PointMotion] =
        PointMotion.breath(row: 1, rise * 0.45) + PointMotion.breath(row: 2, rise * 0.8) + PointMotion.breath(row: 3, rise)
        + sway(row: 2, frequency: 0.62, phase: 0, own: [(0.83, 1.0), (0.91, 3.0)])
        + sway(row: 3, frequency: 0.71, phase: 2.0, own: [(0.77, 5.0), (0.87, 2.4)])
        + sway(row: 4, frequency: 0.53, phase: 4.1, own: [(0.67, 0.7), (0.59, 3.6)])
        + [PointMotion(index: 9, axis: .y, amplitude: 0.02, frequency: 0.79, phase: 1.0),
           PointMotion(index: 10, axis: .y, amplitude: 0.02, frequency: 0.93, phase: 3.0),
           PointMotion(index: 13, axis: .y, amplitude: 0.02, frequency: 0.69, phase: 5.0),
           PointMotion(index: 14, axis: .y, amplitude: 0.02, frequency: 0.97, phase: 2.4)]

    /// The middle two points of a row going sideways: three quarters of `flow` together, the last
    /// quarter each at its own pace.
    private static func sway(row: Int, frequency: Double, phase: Double, own: [(frequency: Double, phase: Double)]) -> [PointMotion] {
        own.enumerated().flatMap { column, alone in
            let index = row * LightMesh.columns + 1 + column
            return [PointMotion(index: index, axis: .x, amplitude: flow * 0.75, frequency: frequency, phase: phase),
                    PointMotion(index: index, axis: .x, amplitude: flow * 0.25, frequency: alone.frequency, phase: alone.phase)]
        }
    }
}

/// One of the two grids of the design's final table: four points across, five down.
struct LightMesh {
    /// Each row's height at its four points, from the top.
    var rows: [[Float]]
    /// How much lower the two middle rows sit in dark.
    var darkDrop: Float
    var light: [UInt32]
    var dark: [UInt32]
    /// Seconds for one turn of a motion at `frequency` 1.
    var period: Double
    /// How each point moves about its place at full drift.
    var motion: [PointMotion]
    /// How much the whole mesh dims at the bottom of its breath at full drift, a quarter turn after
    /// the motion at `frequency` 1.
    var glow: Double = 0

    static let columns = 4
    /// Where the points stand across the page: the two middle rows are a little out of line on
    /// purpose, so the edge of the light is not a regular arc.
    private static let across: [[Float]] = [[0, 0.34, 0.67, 1], [0, 0.34, 0.67, 1], [0, 0.32, 0.70, 1], [0, 0.36, 0.67, 1], [0, 0.34, 0.67, 1]]

    /// The home page (sections 1 and 4), breathing as `HomeBreath` says.
    static let home = LightMesh(
        rows: [[0, 0, 0, 0], [0.42, 0.44, 0.41, 0.43], [0.56, 0.60, 0.55, 0.59], [0.76, 0.80, 0.75, 0.81], [1, 1, 1, 1]], darkDrop: 0.02,
        light: [0xF5F7FA, 0xF5F7FA, 0xF5F7FA, 0xF5F7FA,
                0xF5F7FA, 0xF5F7FA, 0xF5F7FA, 0xF5F7FA,
                0xE4F0FC, 0xEDF3FB, 0xEAEEFB, 0xF0F2FA,
                0xA6D6FA, 0xB2D1FD, 0xB6C4FB, 0xC6CCF8,
                0x4AB2F7, 0x3A8CFE, 0x4878F6, 0x6C80F0],
        dark: [0x05070D, 0x05070D, 0x05070D, 0x05070D,
               0x05070D, 0x05070D, 0x05070D, 0x05070D,
               0x06101F, 0x071226, 0x08102A, 0x070C1C,
               0x0B3C8A, 0x0C4FC0, 0x173FB0, 0x14286E,
               0x1260D8, 0x1A6FF0, 0x2056E0, 0x2440B8],
        period: HomeBreath.period, motion: HomeBreath.motion, glow: HomeBreath.glow)

    /// The conversation (section 10): the home's bottom colours taken 85 % of the way back to the
    /// page, starting three quarters of the way down. While Poki works, the middle of the third and
    /// fourth rows each go round a small ellipse about their place, 3 % of the page, once in 14
    /// seconds, each starting a quarter turn after the last so the glow does not sway as one piece.
    static let chat = LightMesh(
        rows: [[0, 0, 0, 0], [0.75, 0.76, 0.75, 0.76], [0.84, 0.86, 0.83, 0.85], [0.93, 0.94, 0.92, 0.94], [1, 1, 1, 1]], darkDrop: 0,
        light: [0xF5F8FC, 0xF5F8FC, 0xF5F8FC, 0xF5F8FC,
                0xF5F8FC, 0xF5F8FC, 0xF5F8FC, 0xF5F8FC,
                0xE8F3FC, 0xE7F0FC, 0xE8EEFC, 0xEBEFFB,
                0xDFEFFB, 0xDDEAFC, 0xDFE8FB, 0xE4E9FA,
                0xDBEEFB, 0xD9E8FC, 0xDBE5FB, 0xE0E6FA],
        dark: [0x05070D, 0x05070D, 0x05070D, 0x05070D,
               0x05070D, 0x05070D, 0x05070D, 0x05070D,
               0x060E1C, 0x070F1E, 0x070D1D, 0x070B1A,
               0x071227, 0x08142A, 0x081128, 0x090E23,
               0x07142B, 0x08172F, 0x09132D, 0x0A1027],
        period: 14,
        motion: [(9, 0), (10, Double.pi / 2), (13, .pi), (14, 3 * .pi / 2)].flatMap { index, phase in
            [PointMotion(index: index, axis: .x, amplitude: 0.03, phase: phase - .pi / 2),
             PointMotion(index: index, axis: .y, amplitude: 0.03, frequency: 0.8, phase: phase)]
        })

    /// The grid at time `t`, with each point moved `drift` of the way along its motion (0 the table
    /// as it is). The top and the bottom edge never move up or down.
    func points(at t: TimeInterval, drift: Double, dark: Bool) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        for (r, row) in rows.enumerated() {
            let drop = dark && (r == 2 || r == 3) ? darkDrop : 0
            for (c, y) in row.enumerated() { points.append(SIMD2(Self.across[r][c], y + drop)) }
        }
        guard drift > 0 else { return points }
        let turn = t * 2 * .pi / period
        for move in motion { move.apply(to: &points[move.index], at: turn, drift: Float(drift)) }
        return points
    }

    /// The mesh as the system draws it, at time `t`.
    func gradient(at t: TimeInterval, drift: Double, dark: Bool) -> MeshGradient {
        MeshGradient(width: Self.columns, height: rows.count, points: points(at: t, drift: drift, dark: dark),
                     colors: (dark ? self.dark : light).map { Color(hex: $0) }, smoothsColors: true, colorSpace: .perceptual)
    }

    /// How strongly the mesh shows at time `t`: 1 at rest, down to 1 - 2 × `glow` at full drift.
    func strength(at t: TimeInterval, drift: Double) -> Double {
        1 - drift * glow * (1 - cos(t * 2 * .pi / period - .pi / 2))
    }
}

/// How one point of a mesh moves about its place: along one axis, by `amplitude` of the page, at
/// `frequency` turns per turn of its mesh's period, from `phase` in its turn.
///
/// From `AnimationPattern.swift` in rryam/MeshingKit (commit 1c519ac7, MIT License, Copyright (c) 2024
/// Rudrank Riyam; see THIRD_PARTY_NOTICES.md): `PointAnimation` and its `apply`, a cosine offset per
/// point and axis with each point's own frequency, which several motions of one point add up. Changed
/// here: a starting phase, the offset scaled by the drift, and no `.both` axis.
struct PointMotion {
    enum Axis { case x, y }
    var index: Int
    var axis: Axis
    var amplitude: Float
    var frequency: Double = 1
    var phase: Double = 0

    func apply(to point: inout SIMD2<Float>, at turn: Double, drift: Float) {
        let value = amplitude * drift * Float(cos(turn * frequency + phase))
        switch axis {
        case .x: point.x += value
        case .y: point.y += value
        }
    }

    /// A whole row rising and settling together, at the mesh's own period.
    static func breath(row: Int, _ amplitude: Float) -> [PointMotion] {
        (0..<LightMesh.columns).map { PointMotion(index: row * LightMesh.columns + $0, axis: .y, amplitude: amplitude) }
    }
}

/// A mesh that moves as far as `drift` says (0 still, 1 its full motion). `drift` animates, so the
/// light eases into its movement and back to rest; at rest the clock stops.
private struct DriftingMesh: View, Animatable {
    var mesh: LightMesh
    var dark: Bool
    var drift: Double
    var animatableData: Double {
        get { drift }
        set { drift = newValue }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: drift <= 0)) { context in
            let t = BackdropClock.fixed ?? context.date.timeIntervalSinceReferenceDate
            let _ = BackdropLog.note(mesh.period, t, drift)
            mesh.gradient(at: t, drift: drift, dark: dark)
                .opacity(mesh.strength(at: t, drift: drift))
        }
        .modifier(MeshRaster())
    }
}

/// How a moving mesh is drawn each time it changes: on the graphics processor (`drawingGroup`), at a
/// third of the screen's pixels across and down, then scaled up to the page. The mesh has no detail
/// finer than a few dozen points and the grain is laid over it at full size, so the smaller picture
/// scaled up is the same light for a ninth of the pixels.
private struct MeshRaster: ViewModifier {
    static let shrink: CGFloat = 3

    func body(content: Content) -> some View {
        if PerfSwitch.on(.oldMeshDirect) {
            content
        } else if PerfSwitch.on(.oldMeshFullSize) {
            content.drawingGroup()
        } else {
            GeometryReader { geometry in
                content
                    .frame(width: geometry.size.width / Self.shrink, height: geometry.size.height / Self.shrink)
                    .drawingGroup()
                    .scaleEffect(Self.shrink, anchor: .topLeading)
            }
        }
    }
}

/// `-pokiBackdropLog YES` writes each frame a moving mesh draws, with its drift, to Caches/backdrop.log:
/// for checking in the simulator how often the light redraws and that it stops in the background,
/// under another page and with Reduce Motion. Debug builds only.
enum BackdropLog {
    #if DEBUG
    private static let on = UserDefaults.standard.bool(forKey: "pokiBackdropLog")
    private static var lines: [String] = []
    private static var flushed: TimeInterval = 0
    static func note(_ period: Double, _ now: TimeInterval, _ drift: Double) {
        guard on, drift > 0 else { return }
        lines.append(String(format: "%.4f period %.1f drift %.3f", now, period, drift))
        guard now - flushed > 0.5, let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        flushed = now
        try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("backdrop.log"), atomically: true, encoding: .utf8)
    }
    #else
    @inline(__always) static func note(_ period: Double, _ now: TimeInterval, _ drift: Double) {}
    #endif
}

/// `-pokiBackdropClock 100` holds the moving light at that moment of its motion, so two builds can be
/// laid over each other pixel for pixel. Debug builds only.
enum BackdropClock {
    #if DEBUG
    static let fixed: TimeInterval? = UserDefaults.standard.object(forKey: "pokiBackdropClock") == nil
        ? nil : UserDefaults.standard.double(forKey: "pokiBackdropClock")
    #else
    static let fixed: TimeInterval? = nil
    #endif
}

/// The design's soft falloff for its two lights: a Gaussian read off at these distances from the
/// centre, as shares of the centre's strength, gone at 1.2 times the radius.
enum SoftLight {
    static func stops(_ colour: Color, strength: Double) -> [Gradient.Stop] {
        [(0.0, 1.0), (0.25, 0.85), (0.5, 0.52), (0.75, 0.23), (1.0, 0.07), (1.2, 0.0)].map { at, share in
            Gradient.Stop(color: colour.opacity(strength * share), location: at / 1.2)
        }
    }
}

/// A bright line along the bottom edge of the home page: a flat ellipse of light, 332 by 33 points
/// about the middle of the edge.
private struct EdgeLight: View {
    var dark: Bool
    var body: some View {
        let colour = dark ? Color(hex: 0x9FD0FF) : .white
        EllipticalGradient(stops: SoftLight.stops(colour, strength: dark ? 0.45 : 0.40), center: .center,
                           startRadiusFraction: 0, endRadiusFraction: 0.5)
            .frame(width: 332 * 2.4, height: 33 * 2.4)
            .offset(y: 33 * 1.2)
            .allowsHitTesting(false)
    }
}

/// A tile of grey noise, made once: laid over a wide, pale gradient at 3 % it breaks up the bands
/// that eight bits per channel would show.
enum Grain {
    static let image: Image = {
        let side = 256
        var bytes = [UInt8](repeating: 0, count: side * side)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for i in bytes.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)
        let cg = provider.flatMap {
            CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return cg.map { Image(decorative: $0, scale: 1) } ?? Image(systemName: "square")
    }()
}
