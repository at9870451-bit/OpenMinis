import Metal
import QuartzCore
import RealityKit
import SwiftUI
import UIKit

// The three-dimensional bear, drawn live by RealityKit. The renderer's setup (RealityRenderer, the
// camera, light only from the model's own picture at exponent 0, no other light, no tone mapping,
// four-times multisampling, the paused animations scrubbed by time) is the modelling's own check
// renderer, rkrender.swift, with which the bear's colours were matched to the design. Any other light
// greys it.

/// The model's three files in Bear/Model, as the modelling hands them over. A new version of the bear
/// is these three files replaced; nothing in the code names a frame or a size of its own.
/// - PokiBear.usdz: the bear, with one timeline that holds every gesture;
/// - PokiBear-clips.json: where on that timeline each gesture is, in frames;
/// - PokiBear-light.png: the light it was coloured under.
@MainActor
@Observable
final class BearModel {
    static let shared = BearModel()

    struct Loaded {
        let entity: Entity
        let clips: BearClips
        let light: EnvironmentResource
    }

    private(set) var loaded: Loaded?
    private(set) var failed = false
    @ObservationIgnored private var started = false

    /// Starts loading once; at launch, so the home page usually has the bear before it shows.
    func load() {
        guard !started else { return }
        started = true
        Task {
            do {
                // `-pokiBearLoad slow` or `fail`: the late and the broken model, to see the flat bear stand in.
                let test = UserDefaults.standard.string(forKey: "pokiBearLoad")
                if test == "slow" { try await Task.sleep(for: .seconds(5)) }
                guard test != "fail",
                      let model = Bundle.main.url(forResource: "PokiBear", withExtension: "usdz"),
                      let clipsURL = Bundle.main.url(forResource: "PokiBear-clips", withExtension: "json"),
                      let lightURL = Bundle.main.url(forResource: "PokiBear-light", withExtension: "png"),
                      let source = CGImageSourceCreateWithURL(lightURL as CFURL, nil),
                      let picture = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else { throw CocoaError(.fileNoSuchFile) }
                let clips = try BearClips(json: Data(contentsOf: clipsURL))
                let light = try await EnvironmentResource(equirectangular: picture, withName: "PokiBear-light")
                let entity = try await Entity(contentsOf: model)
                loaded = Loaded(entity: entity, clips: clips, light: light)
            } catch {
                failed = true
            }
        }
    }
}

/// The gestures on the model's timeline, in seconds.
struct BearClips {
    let idle, wave, blink: ClosedRange<TimeInterval>
    /// The top of the wave, where it matches the design's hello picture.
    let hello: TimeInterval
    /// Frames a second on the model's timeline.
    let fps: Double

    /// Reads `{"fps": 30, "clips": {"idle": [95, 105], "wave": [20, 94], "blink": [5, 12]},
    /// "design_hello_frame": 42}`. A file without the three gestures is not a bear; without the hello
    /// frame, the wave's middle stands in.
    init(json: Data) throws {
        struct File: Decodable {
            let fps: Double
            let clips: [String: [Int]]
            let design_hello_frame: Int?
        }
        let file = try JSONDecoder().decode(File.self, from: json)
        func span(_ name: String) throws -> ClosedRange<TimeInterval> {
            guard let frames = file.clips[name], frames.count == 2, frames[0] <= frames[1], file.fps > 0 else {
                throw CocoaError(.coderReadCorrupt)
            }
            return Double(frames[0]) / file.fps...Double(frames[1]) / file.fps
        }
        fps = file.fps
        idle = try span("idle")
        wave = try span("wave")
        blink = try span("blink")
        let top = file.design_hello_frame.map { Double($0) / file.fps } ?? (wave.lowerBound + wave.upperBound) / 2
        hello = min(max(top, wave.lowerBound), wave.upperBound)
    }

    /// How long a move takes; idle lasts until the next one.
    func length(_ move: BearMove) -> TimeInterval {
        switch move {
        case .idle: .infinity
        case .blink: BearBlink.length
        case .hi: 2 * (hello - wave.lowerBound) / BearMove.hiPace
        }
    }

    /// The time on the timeline `elapsed` seconds into a move.
    func time(_ move: BearMove, after elapsed: TimeInterval) -> TimeInterval {
        switch move {
        case .idle:
            // The idle clip is the bear standing still, the same pose in every frame: it holds the first
            // one, and `BearIdle` makes it breathe and look about on top of it.
            #if DEBUG
            // `-pokiBearFrame <frame>` holds that frame of the timeline instead, to look at one pose.
            if let frame = UserDefaults.standard.string(forKey: "pokiBearFrame").flatMap(Double.init) { return frame / fps }
            #endif
            return idle.lowerBound
        case .blink:
            // The model's blink frames at `BearBlink`'s pace. The time is a frame's number over the rate,
            // as the modeller's renderer has it: an eye shape is there at its frame exactly.
            return ((blink.lowerBound * fps).rounded() + BearBlink.at(elapsed).frame) / fps
        case .hi:
            let rise = hello - wave.lowerBound, x = min(max(elapsed * BearMove.hiPace, 0), 2 * rise)
            return wave.lowerBound + (x <= rise ? x : 2 * rise - x)
        }
    }
}

/// The blink: one kind only, at one pace, never two in a row. The model's own seven frames took a
/// quarter of a second and the closed eye's arc came in whole the frame after a thick half-shut pupil.
/// Here the lids come down over 0.14 s to a thin line, stay shut for 0.06 s as a low arc no taller than
/// that line, and go up over 0.2 s: 0.4 s in all, easing in and out each way. The model's frames still
/// give the shapes (open to half shut, its first two steps; the closed eye, its middle two; half open
/// to open, its last two), and between the pupil and the arc the eyes are swapped at a whole frame
/// only, since between two of them neither shows and the eye pads were blank and white. Only the
/// heights are set on top: the pupils' as they shut and open, the arcs' while shut.
enum BearBlink {
    static let closing: TimeInterval = 0.14, shut: TimeInterval = 0.06, opening: TimeInterval = 0.2
    static var length: TimeInterval { closing + shut + opening }
    /// How tall the pupils are when the arcs take their place, against open.
    static let thin: Float = 0.12
    /// How tall the arcs are while the eyes are shut, against the smile's: a line, not a smile.
    static let flat: Float = 0.3
    /// Seconds from the end of one blink to the start of the next: drawn at random in this range.
    static let gap: ClosedRange<TimeInterval> = 4...7

    /// A frame on the model's blink, from 0 (open) to 7 (open again), whole while the arcs show; and
    /// the height the pupils, or the arcs, are drawn at, against their own.
    struct Moment: Equatable {
        var frame: Double
        var pupils: Float?
        var arcs: Float?
    }

    static func at(_ elapsed: TimeInterval) -> Moment {
        let x = min(max(elapsed, 0), length)
        if x < closing {
            let down = BearIdle.ease(Float(x / closing))
            return Moment(frame: 2 * Double(down), pupils: 1 - (1 - thin) * down, arcs: nil)
        }
        if x < closing + shut {
            return Moment(frame: (x - closing) / shut < 0.5 ? 3 : 4, pupils: nil, arcs: flat)
        }
        let up = BearIdle.ease(Float((x - closing - shut) / opening))
        return Moment(frame: 5 + 2 * Double(up), pupils: thin + (1 - thin) * up, arcs: nil)
    }
}

/// What the bear does. `hi` answers a tap: the wave's rise to its top and back down, half as fast
/// again, about a second in all, so it is over before what the tap opens has come up.
enum BearMove {
    case idle, blink, hi
    static let hiPace = 1.5
}

/// What the bear is doing and since when: a move plays once, then the next one queued, then idle,
/// which holds. Every 4 to 7 seconds of idle it blinks once, the only thing that makes it blink: not
/// while its head is turning, but as soon as it holds still.
struct BearPlayback {
    private(set) var move: BearMove = .idle
    private var since: TimeInterval = 0
    private var queued: [BearMove] = []
    private(set) var nextBlink: TimeInterval = 0

    /// Nothing but idle and blinks: a tap may start a move.
    var free: Bool { move != .hi }

    /// Where the blink is at `now`, while it blinks.
    func blink(at now: TimeInterval) -> BearBlink.Moment? { move == .blink ? BearBlink.at(now - since) : nil }

    mutating func play(_ moves: [BearMove], at now: TimeInterval) {
        queued = Array(moves.dropFirst())
        move = moves.first ?? .idle
        since = now
        if move == .idle { scheduleBlink(after: now) }
    }

    /// A tap's hi: after the blink, if the bear is blinking, so that its eyes do not jump open.
    mutating func greet(at now: TimeInterval) {
        if move == .blink { queued = [.hi] } else { play([.hi], at: now) }
    }

    /// The time on the model's timeline to show at `now`. `steady` is false while the head is turning:
    /// a blink due then waits for it to stop.
    mutating func time(at now: TimeInterval, clips: BearClips, steady: Bool = true) -> TimeInterval {
        while move != .idle, now - since > clips.length(move) {
            since += clips.length(move)
            move = queued.isEmpty ? .idle : queued.removeFirst()
            if move == .idle { scheduleBlink(after: since) }
        }
        if move == .idle, now >= nextBlink, steady {
            play([.blink], at: now)
        }
        return clips.time(move, after: now - since)
    }

    private mutating func scheduleBlink(after now: TimeInterval) {
        nextBlink = now + .random(in: BearBlink.gap)
    }
}

/// Fades the white eye pads and hides the highlights as the eyes shut, using the original mesh.
/// The pads keep their authored binding to the head; they fade out completely so the closed-eye
/// arcs are not drawn on full white discs. Both materials still render with the face in one pass.
///
/// Do not rebind the pads by regenerating the imported skinned mesh here. On physical iOS 27.0,
/// even `MeshResource.generate(from: model.mesh.contents)` with unchanged contents triggers a
/// CoreRE assertion, not a Swift error that `try?` can catch. A bear without parts named `EyePad_…` and
/// `Catchlight_…` and joints ending in `Eye_L` and `Eye_R` keeps its eyes as they are.
@MainActor
private struct EyePads {
    /// The eye's joint scale under which the eye counts as shutting; the blink's first step is 0.7.
    static let shutting: Float = 0.75

    private let bear: ModelEntity
    private let eyes: [Int]
    private let pad: Int, highlight: Int
    private let white: PhysicallyBasedMaterial
    private let shown: PhysicallyBasedMaterial
    private let hidden: PhysicallyBasedMaterial
    /// How open the pads were last drawn: their material is made again only when that changes.
    private var drawnOpen: Float = 1

    init?(bear: ModelEntity) {
        guard let model = bear.model, let skeleton = model.mesh.contents.skeletons.first else { return nil }
        let contents = model.mesh.contents
        let names = skeleton.joints.map(\.name)
        func materialIndex(_ prefix: String) -> Int? {
            let indices = Set(contents.models.filter { $0.id.hasPrefix(prefix) }.flatMap { $0.parts.map(\.materialIndex) })
            return indices.count == 1 ? indices.first : nil
        }
        guard let pad = materialIndex("EyePad_"), let highlight = materialIndex("Catchlight_"),
              let white = model.materials[pad] as? PhysicallyBasedMaterial,
              let highlightMaterial = model.materials[highlight] as? PhysicallyBasedMaterial else { return nil }
        var eyes: [Int] = []
        for part in contents.models {
            if part.id.hasPrefix("EyePad_") {
                let side = part.id.dropFirst("EyePad_".count).prefix(1)
                guard let eye = names.firstIndex(where: { $0 == "Eye_\(side)" || $0.hasSuffix("/Eye_\(side)") }) else { return nil }
                eyes.append(eye)
            }
        }
        guard eyes.count == 2 else { return nil }
        self.bear = bear
        self.eyes = eyes
        self.pad = pad
        self.highlight = highlight
        self.white = white
        shown = highlightMaterial
        var hidden = highlightMaterial
        hidden.blending = .transparent(opacity: .init(scale: 0))
        hidden.writesDepth = false
        self.hidden = hidden
    }

    /// Fades the pads, and hides the highlight, while the eyes are not open, at the pose just updated.
    mutating func follow() {
        let transforms = bear.jointTransforms
        var open: Float = 1
        for eye in eyes where eye < transforms.count {
            let x = min(max((transforms[eye].scale.y - Self.shutting) / (1 - Self.shutting), 0), 1)
            open = min(open, x * x * (3 - 2 * x))
        }
        guard open != drawnOpen, var model = bear.model else { return }
        drawnOpen = open
        var pads = white
        if case .transparent(let opacity) = white.blending {
            pads.blending = .transparent(opacity: .init(scale: opacity.scale * open, texture: opacity.texture))
        }
        model.materials[pad] = pads
        model.materials[highlight] = open == 1 ? shown : hidden
        bear.model = model
    }
}

/// Where the chat is covered (the conversations drawer, Poki's profile over it): the bear holds still.
extension EnvironmentValues {
    @Entry var bearCovered = false
}

/// The bear for a face the model has, over the flat picture that stands in for it. The flat picture
/// shows when the face is not the model's, with Reduce Motion or Low Power Mode, while the phone runs
/// hot (back to the model once it cools down), when the model failed to load, and when it is not drawn
/// within 0.3 seconds; the model then fades in once it is. The square is never empty past those 0.3
/// seconds, and a change of face is just there, with no fade.
///
/// A poke makes it say hi (`BearMove.hi`), with a small hop and a tap you feel; a poke while it still
/// does only gets the feel, so moves never pile up. The flat picture hops.
struct ModelBear<Flat: View>: View {
    /// What the bear plays; nil for a face the model does not play yet, which stays flat.
    var act: BearAct?
    /// The square's side at rest, in points: the bear is drawn at that size and scaled from it.
    var side: CGFloat
    /// The bear is in sight: otherwise it holds its last frame and draws nothing. Leaving the screen,
    /// the drawer or the profile over it, and the background count too, without being told.
    var live = true
    /// Counts the touches on the bear.
    var pokes = 0
    @ViewBuilder var flat: () -> Flat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.bearCovered) private var covered
    @State private var shown = false
    @State private var drawn = false
    @State private var waited = false
    @State private var handle = BearHandle()
    @State private var hops = 0
    @State private var hopped = Date.distantPast
    private var store: BearModel { BearModel.shared }
    private var modelled: Bool { act != nil }

    private var usable: Bool { !reduceMotion && !DeviceStrain.shared.resting && !store.failed }
    private var showsModel: Bool { modelled && usable && drawn }

    var body: some View {
        ZStack {
            flat().opacity(showsModel || (modelled && usable && !waited) ? 0 : 1)
            if usable, let loaded = store.loaded {
                LiveBear(loaded: loaded, pixels: Int((side * displayScale).rounded()), handle: handle, act: act ?? .ready,
                         live: live && modelled && shown && !covered && scenePhase == .active) {
                    withAnimation(waited ? .easeOut(duration: 0.3) : nil) { drawn = true }
                }
                .aspectRatio(1, contentMode: .fit)
                .opacity(showsModel ? 1 : 0)
            }
        }
        // A change of face fades between the model and the flat picture.
        .animation(.easeInOut(duration: 0.25), value: modelled)
        .keyframeAnimator(initialValue: 1.0, trigger: hops) { content, scale in
            content.scaleEffect(x: 2 - scale, y: scale, anchor: .bottom)
        } keyframes: { _ in
            CubicKeyframe(0.93, duration: 0.08)
            CubicKeyframe(1.06, duration: 0.12)
            SpringKeyframe(1.0, duration: 0.35, spring: .bouncy(duration: 0.35, extraBounce: 0.15))
        }
        .sensoryFeedback(.impact(weight: .light), trigger: pokes)
        .onChange(of: pokes) {
            // With Reduce Motion the picture stays still: only the feel of the tap answers.
            if reduceMotion { return }
            if showsModel { if handle.sayHi() { hops += 1 } } else if -hopped.timeIntervalSinceNow > 0.55 { hopped = .now; hops += 1 }
        }
        .task {
            store.load()
            try? await Task.sleep(for: .milliseconds(300))
            waited = true
        }
        // The renderer goes with the model; the one made when the model is usable again shows only once
        // it has drawn, over the flat picture until then.
        .onChange(of: usable) { _, usable in if !usable { drawn = false } }
        .onAppear { shown = true }
        .onDisappear { shown = false }
    }
}

/// The renderer in a view of its own.
private struct LiveBear: UIViewRepresentable {
    let loaded: BearModel.Loaded
    let pixels: Int
    let handle: BearHandle
    let act: BearAct
    let live: Bool
    let drawn: () -> Void

    func makeUIView(context: Context) -> BearCanvas {
        let canvas = BearCanvas(loaded: loaded, pixels: pixels, drawn: drawn)
        handle.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: BearCanvas, context: Context) {
        canvas.act = act
        canvas.live = live
    }

    static func dismantleUIView(_ canvas: BearCanvas, coordinator: ()) { canvas.live = false }
}

/// The way from a touch to the renderer.
@MainActor
final class BearHandle {
    fileprivate weak var canvas: BearCanvas?

    /// Says hi, unless it still is; says whether it does.
    func sayHi() -> Bool { canvas?.sayHi() ?? false }
}

/// A transparent Metal layer the bear is rendered into while it is in sight: 30 times a second while it
/// blinks, says hi or turns its head, 10 while it only breathes and sways. A pose that holds still (a model
/// without the joints `BearIdle` moves) stops it until the next blink.
///
/// The model's poses are read once from its timeline, for the frames the bear plays, and then set on
/// its joints directly, with `BearIdle` on top: the timeline's own playback would set them back.
private final class BearCanvas: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private let renderer: RealityRenderer?
    private let clips: BearClips
    private let drawn: () -> Void
    private var skins: [ModelEntity] = []
    /// The model's pose at each frame the bear plays, a pose for each skin.
    private var poses: [Int: [[Transform]]] = [:]
    private var idle = BearIdle(now: CACurrentMediaTime())
    /// The skin `BearIdle` moves, and its joints.
    private var idleSkin: (index: Int, joints: BearIdleJoints)?
    /// The skin with the eyes, which the blink shuts.
    private var faceSkin: (index: Int, joints: BearIdleJoints)?
    private var rate = 30
    /// A reaction to the state playing now, once.
    private var reaction: BearReaction?
    /// The stance for the state, and the way to it from the last one.
    private var stance = BearStanceChange(.ready, at: CACurrentMediaTime())
    /// While it says hi in a state with a stance of its own: the stance steps aside for the wave.
    private var aside: (from: TimeInterval, to: TimeInterval)?
    /// The model's pose at the top of its wave: the open mouth and the sparkles are taken from it.
    private var helloPose: [[Transform]]?

    /// What the bear plays. A change to a state with a reaction plays it once, from where the bear is.
    var act: BearAct = .ready {
        didSet {
            guard act != oldValue else { return }
            let now = CACurrentMediaTime()
            stance.go(to: act, at: now)
            idle.calm = ![.ready, .done, .failed].contains(act)
            if live { resume() }
            guard let next = BearReaction(act, at: now) else { return }
            reaction = next
            idle.attend(at: now)
            idle.rest(until: next.end)
            if live { resume() }
        }
    }

    private func reacting(at now: TimeInterval) -> Bool { reaction.map { now < $0.end } ?? false }

    /// The eyes are shut or smiling for the state: no blink then.
    private var eyesBusy = false

    /// How much of the stance shows: all of it, but for a hi, when it steps aside for the wave and back.
    private func stepAside(at now: TimeInterval) -> Float {
        guard let (from, to) = aside else { return 1 }
        if now >= to + 0.3 { aside = nil; return 1 }
        if now < from + 0.2 { return 1 - BearIdle.ease(Float((now - from) / 0.2)) }
        if now < to { return 0 }
        return BearIdle.ease(Float((now - to) / 0.3))
    }
    private var pads: EyePads?
    private var playback = BearPlayback()
    private var link: CADisplayLink?
    private var wake: Task<Void, Never>?
    private var lastPose: [simd_float4x4] = []
    /// Frames still to draw after the pose last changed: the skinning on screen trails the pose by a
    /// frame or two (the check renderer draws three passes for one picture), so the pose a gesture
    /// ends on is drawn a few times before the bear holds still.
    private var settling = 0
    private var rendering = false
    private var presented = false

    var live = false {
        didSet {
            guard live != oldValue else { return }
            if live {
                playback.play([.idle], at: CACurrentMediaTime())
                resume()
            } else {
                link?.isPaused = true
                wake?.cancel()
            }
        }
    }

    init(loaded: BearModel.Loaded, pixels: Int, drawn: @escaping () -> Void) {
        clips = loaded.clips
        self.drawn = drawn
        renderer = try? RealityRenderer()
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        let layer = layer as! CAMetalLayer
        layer.device = MTLCreateSystemDefaultDevice()
        // Linear half floats: RealityRenderer premultiplies its edges in linear light, and a layer
        // in linear light blends them so. In an sRGB layer the compositor took those edges for
        // premultiplied in sRGB, and they came out as a bright, stepped rim against the circle.
        layer.pixelFormat = .rgba16Float
        layer.framebufferOnly = false
        layer.isOpaque = false
        // RealityRenderer writes Display P3 values, as the phone's screen shows them.
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.drawableSize = CGSize(width: max(pixels, 1), height: max(pixels, 1))
        guard let renderer else { return }

        let entity = loaded.entity.clone(recursive: true)
        // Prepare the eye materials without rebuilding the model's skinned mesh.
        func skin(_ e: Entity) -> ModelEntity? {
            if let model = e as? ModelEntity, !model.jointNames.isEmpty { return model }
            return e.children.lazy.compactMap(skin).first
        }
        pads = skin(entity).flatMap(EyePads.init)
        renderer.entities.append(entity)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 19.458
        camera.camera.fieldOfViewOrientation = .vertical
        camera.camera.near = 0.05
        camera.camera.far = 100
        // The design's frame: the flat pictures and the model line up in it, the head at the same height.
        camera.look(at: SIMD3(0, 0.9, 0), from: SIMD3(0, 0.9, 3.5), relativeTo: nil)
        renderer.entities.append(camera)
        renderer.activeCamera = camera
        renderer.lighting.resource = loaded.light
        renderer.lighting.intensityExponent = 0
        renderer.cameraSettings.isToneMappingEnabled = false
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))

        var controllers: [AnimationPlaybackController] = []
        func walk(_ e: Entity) {
            for animation in e.availableAnimations {
                controllers.append(e.playAnimation(animation, transitionDuration: 0, startsPaused: true))
            }
            if let model = e as? ModelEntity, !model.jointNames.isEmpty { skins.append(model) }
            e.children.forEach(walk)
        }
        walk(entity)
        var frames = Set<Int>()
        func add(_ span: ClosedRange<TimeInterval>) {
            frames.formUnion(Int((span.lowerBound * clips.fps).rounded(.down))...Int((span.upperBound * clips.fps).rounded(.up)))
        }
        add(clips.idle.lowerBound...clips.idle.lowerBound)
        add(clips.blink)
        add(clips.wave.lowerBound...clips.hello)
        let held = clips.time(.idle, after: 0)
        add(held...held)
        for frame in frames.sorted() {
            controllers.forEach { $0.time = Double(frame) / clips.fps }
            try? renderer.update(0)
            poses[frame] = skins.map(\.jointTransforms)
        }
        controllers.forEach { $0.stop() }
        helloPose = poses[Int((clips.hello * clips.fps).rounded())]
        faceSkin = skins.indices.lazy.compactMap { i in BearIdleJoints(names: self.skins[i].jointNames).map { (i, $0) } }.first
        // `-pokiBearFrame` holds a frame to look at: the bear does not move about over it.
        if held == clips.idle.lowerBound { idleSkin = faceSkin }
    }

    /// The bear moves about by itself: it has the joints for it, and the phone is not running hot. Hot,
    /// it only blinks, and draws nothing in between.
    private var moving: Bool {
        idleSkin != nil && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    /// The model's pose at a frame of its timeline, between two frames a mix of the two.
    private func pose(at frame: Double) -> [[Transform]]? {
        // A whole frame a hair off by rounding is that frame: between two, the eyes may not show.
        let frame = abs(frame - frame.rounded()) < 1e-6 ? frame.rounded() : frame
        let below = Int(frame.rounded(.down)), x = Float(frame - Double(below))
        guard let a = poses[below] ?? poses.min(by: { abs(Double($0.key) - frame) < abs(Double($1.key) - frame) })?.value else { return nil }
        guard x > 1e-4, let b = poses[below + 1] else { return a }
        return zip(a, b).map { a, b in
            zip(a, b).map { a, b in
                Transform(scale: simd_mix(a.scale, b.scale, SIMD3(repeating: x)), rotation: simd_slerp(a.rotation, b.rotation, x),
                          translation: simd_mix(a.translation, b.translation, SIMD3(repeating: x)))
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        link?.invalidate()
        wake?.cancel()
    }

    fileprivate func sayHi() -> Bool {
        guard live, presented, playback.free, !reacting(at: CACurrentMediaTime()) else { return false }
        let now = CACurrentMediaTime()
        idle.attend(at: now)
        playback.greet(at: now)
        aside = (now, now + clips.length(.hi) + 0.2)
        resume()
        return true
    }

    private func resume() {
        wake?.cancel()
        if link == nil {
            let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick))
            // The gestures are drawn at 30 frames a second: so they move at the rate they were made.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    /// How long before a blink the bear is drawn at the full rate.
    private static let lead: TimeInterval = 0.2

    fileprivate func tick() {
        guard live, !rendering, let renderer, let layer = layer as? CAMetalLayer else { return }
        let now = CACurrentMediaTime()
        let time = playback.time(at: now, clips: clips, steady: !moving || !(idle.busy(at: now) || reacting(at: now) || stance.changing(at: now) || eyesBusy))
        guard var standing = pose(at: time * clips.fps) else { return }
        if let blink = playback.blink(at: now), let (index, joints) = faceSkin, index < standing.count {
            joints.shut(blink, in: &standing[index])
        }
        if moving, let (index, joints) = idleSkin, index < standing.count {
            var move = idle.pose(at: now, blinking: playback.move == .blink)
            #if DEBUG
            // `-pokiBearLook <-1…1>` holds the head turned that far toward one side, as far as a look
            // to the side goes (1), to look at the eyes there.
            if let side = UserDefaults.standard.string(forKey: "pokiBearLook").flatMap(Float.init) { move = BearIdle.farthest(side) }
            #endif
            move = move + stance.pose(at: now) * stepAside(at: now)
            if let reaction, reacting(at: now) { move = move + reaction.pose(at: now) }
            if let hello = helloPose, index < hello.count { joints.show(move, from: hello[index], in: &standing[index]) }
            joints.apply(move, to: &standing[index])
            eyesBusy = move.shut > 0.05 || move.smile > 0.05
        }
        if let reaction, !reacting(at: now) { self.reaction = nil }
        for (skin, joints) in zip(skins, standing) { skin.jointTransforms = joints }
        // Breathing and swaying alone are slow: a third of the rate is enough, and a third of the work.
        // A blink is drawn at the full rate from its first frame: the rate goes up a moment before it,
        // as a blink that began on a slow frame lost its first steps and looked quicker than the next.
        // A state with something moving in it (at work, talking, waving) is drawn at the full rate too.
        let still: Set<BearAct> = [.ready, .done, .failed, .waiting, .paused, .thinking]
        let wanted = playback.move == .idle && !idle.busy(at: now) && reaction == nil && !stance.changing(at: now) && still.contains(stance.act)
            && playback.nextBlink - now > Self.lead ? 10 : 30
        if wanted != rate {
            rate = wanted
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(wanted), maximum: Float(wanted), preferred: Float(wanted))
        }
        do {
            if !presented {
                // As the check renderer does: a few passes at the first frame let the skinning settle.
                try renderer.update(0)
                try renderer.update(0)
                try renderer.update(0)
            }
            let pose = skins.flatMap { $0.jointTransforms.map(\.matrix) }
            if presented, Self.same(pose, lastPose) {
                if settling == 0 {
                    // A bear that moves about by itself is only between two breaths: it goes on.
                    if playback.move == .idle, !moving { sleepUntilBlink() }
                    return
                }
                settling -= 1
            } else {
                settling = 3
            }
            guard let drawable = layer.nextDrawable() else { return }
            pads?.follow()
            BearLog.note(now, playback.move, time * clips.fps)
            lastPose = pose
            rendering = true
            nonisolated(unsafe) let shown = drawable
            // The eyes' shapes are a flip book in the mesh, and on screen it trails the time by a pass:
            // drawn once, the frame after the blink's line was the white of the eye pads with neither
            // the line nor the smile. One pass into a texture never shown, finished before the picture
            // is drawn, as the modeller's renderer draws three for one picture.
            // Standing, the eyes keep their shape and the pass is not needed: a head that turns a frame
            // late does not show.
            if playback.move != .idle, let spare = spare(like: drawable.texture) {
                let warm = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: spare))
                try renderer.updateAndRender(deltaTime: 0, cameraOutput: warm, onComplete: { [weak self] _ in
                    DispatchQueue.main.async { self?.draw(into: shown) }
                })
            } else {
                draw(into: shown)
            }
        } catch {
            rendering = false
        }
    }

    private func draw(into drawable: CAMetalDrawable) {
        guard let renderer else { rendering = false; return }
        do {
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: drawable.texture))
            nonisolated(unsafe) let shown = drawable
            try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { [weak self] _ in
                shown.present()
                DispatchQueue.main.async { self?.finished() }
            })
        } catch {
            rendering = false
        }
    }

    private var spareTexture: MTLTexture?

    /// A texture the size of the picture, never shown, for the pass that lets the mesh catch up.
    private func spare(like texture: MTLTexture) -> MTLTexture? {
        if let spareTexture, spareTexture.width == texture.width, spareTexture.height == texture.height { return spareTexture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                                  height: texture.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        spareTexture = texture.device.makeTexture(descriptor: descriptor)
        return spareTexture
    }

    /// Two poses a pixel cannot tell apart: the idle clip's frames differ by rounding only.
    private static func same(_ a: [simd_float4x4], _ b: [simd_float4x4]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            let d = x - y
            if max(simd_reduce_max(simd_abs(d.columns.0)), simd_reduce_max(simd_abs(d.columns.1)),
                   simd_reduce_max(simd_abs(d.columns.2)), simd_reduce_max(simd_abs(d.columns.3))) > 1e-4 { return false }
        }
        return true
    }

    private func finished() {
        rendering = false
        if !presented {
            presented = true
            drawn()
        }
    }

    /// The pose holds: nothing to draw until the next blink.
    private func sleepUntilBlink() {
        link?.isPaused = true
        let delay = max(0, playback.nextBlink - Self.lead - CACurrentMediaTime())
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.live else { return }
            self.link?.isPaused = false
        }
    }
}

/// Holds the canvas weakly: a display link keeps its target alive.
private final class Ticker {
    weak var canvas: BearCanvas?
    init(_ canvas: BearCanvas) { self.canvas = canvas }
    @objc func tick() { MainActor.assumeIsolated { canvas?.tick() } }
}

/// `-pokiBearLog YES` writes each frame the bear draws, with its move, to Caches/bear.log: for checking
/// in the simulator that it draws only while something moves and stops when it is out of sight.
/// Debug builds only.
enum BearLog {
    #if DEBUG
    private static let on = UserDefaults.standard.bool(forKey: "pokiBearLog")
    private static var lines: [String] = []
    static func note(_ now: TimeInterval, _ move: BearMove, _ frame: Double) {
        guard on else { return }
        lines.append(String(format: "%.4f %@ %.3f", now, String(describing: move), frame))
        guard let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("bear.log"), atomically: true, encoding: .utf8)
    }
    #else
    @inline(__always) static func note(_ now: TimeInterval, _ move: BearMove, _ frame: Double) {}
    #endif
}
