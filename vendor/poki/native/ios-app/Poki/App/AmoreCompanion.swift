import SwiftUI
import SceneKit
import UIKit

/// Original Amore companion, built procedurally. No Poki bear model, texture,
/// clip or recognizable silhouette is bundled. Animation stays in SceneKit,
/// not a SwiftUI timer that invalidates the conversation every frame.
enum AmoreCompanionMood: String { case idle, thinking, working }

struct AmoreCompanionView: View {
    var mood: AmoreCompanionMood
    var side: CGFloat
    var pokes: Int
    var active: Bool = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var resting = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        AmoreCompanionScene(mood: mood, pokes: pokes,
            animate: active && scenePhase == .active && !reduceMotion && !resting,
            dark: colorScheme == .dark)
            .frame(width: side, height: side)
            .background(Color(uiColor: colorScheme == .dark ? UIColor(red: 0.04, green: 0.10, blue: 0.18, alpha: 1) : UIColor(red: 0.90, green: 0.95, blue: 1, alpha: 1)), in: Circle())
            .clipShape(Circle())
            .accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in updateResting() }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in updateResting() }
            .onAppear { updateResting() }
    }
    private func updateResting() {
        let info = ProcessInfo.processInfo
        resting = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }
}

struct AmoreCompanionScene: UIViewRepresentable {
    let mood: AmoreCompanionMood
    let pokes: Int
    let animate: Bool
    let dark: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> AmoreCompanionSurface {
        let surface = AmoreCompanionSurface()
        let view = surface.sceneView
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 30
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.delegate = context.coordinator
        context.coordinator.surface = surface
        surface.animate = animate
        context.coordinator.configure(view, mood: mood, pokes: pokes, animate: animate, dark: dark)
        return surface
    }
    func updateUIView(_ surface: AmoreCompanionSurface, context: Context) {
        let changed = surface.animate != animate || context.coordinator.currentMood != mood
        surface.animate = animate
        context.coordinator.configure(surface.sceneView, mood: mood, pokes: pokes, animate: animate, dark: dark)
        if changed || surface.poster.image == nil { surface.refreshPoster() }
    }
    static func dismantleUIView(_ surface: AmoreCompanionSurface, coordinator: Coordinator) {
        surface.sceneView.delegate = nil
        surface.sceneView.isPlaying = false
        surface.sceneView.scene?.isPaused = true
        surface.sceneView.scene = nil
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let scene = SCNScene()
        let camera = SCNNode()
        weak var surface: AmoreCompanionSurface?
        var currentMood: AmoreCompanionMood? { lastMood }
        let doll = SCNNode()
        let head = SCNNode()
        let arm = SCNNode()
        let antenna = SCNNode()
        private let ambient = SCNNode()
        private var lastMood: AmoreCompanionMood?
        private var lastPokes: Int?
        private var animationStarted = false

        override init() {
            super.init()
            doll.name = "amore.companion"
            scene.rootNode.addChildNode(doll)
            buildDoll()
            camera.camera = SCNCamera()
            camera.camera?.usesOrthographicProjection = true
            camera.camera?.orthographicScale = 1.45
            camera.position = SCNVector3(0, 0.25, 4.5)
            scene.rootNode.addChildNode(camera)
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 480
            scene.rootNode.addChildNode(ambient)
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .omni
            key.light?.intensity = 900
            key.position = SCNVector3(-2, 3, 4)
            scene.rootNode.addChildNode(key)
        }
        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            DispatchQueue.main.async { [weak self] in
                guard let surface = self?.surface, surface.animate else { return }
                surface.poster.isHidden = true
            }
        }
        private func material(_ color: UIColor, glow: Bool = false) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = color
            m.lightingModel = .physicallyBased
            m.roughness.contents = 0.83
            m.metalness.contents = 0.02
            if glow { m.emission.contents = color.withAlphaComponent(0.35) }
            return m
        }
        @discardableResult
        private func sphere(_ name: String, color: UIColor, scale: SCNVector3, at position: SCNVector3, parent: SCNNode) -> SCNNode {
            let geometry = SCNSphere(radius: 0.5)
            geometry.segmentCount = 28
            geometry.materials = [material(color)]
            let node = SCNNode(geometry: geometry)
            node.name = name; node.scale = scale; node.position = position
            parent.addChildNode(node)
            return node
        }
        private func buildDoll() {
            let blue = UIColor(red: 0.12, green: 0.57, blue: 0.96, alpha: 1)
            let cream = UIColor(red: 0.94, green: 0.98, blue: 1, alpha: 1)
            sphere("body", color: blue, scale: SCNVector3(1.05, 1.16, 0.80), at: SCNVector3(0, -0.26, 0), parent: doll)
            head.name = "head"; head.position = SCNVector3(0, 0.43, 0.06); doll.addChildNode(head)
            sphere("helmet", color: cream, scale: SCNVector3(1.32, 1.06, 0.95), at: SCNVector3(0, 0, 0), parent: head)
            let face = SCNBox(width: 1.02, height: 0.42, length: 0.10, chamferRadius: 0.17)
            face.materials = [material(UIColor(red: 0.04, green: 0.13, blue: 0.24, alpha: 1))]
            let panel = SCNNode(geometry: face)
            panel.position = SCNVector3(0, 0.02, 0.43); head.addChildNode(panel)
            for x: Float in [-0.24, 0.24] {
                sphere(x < 0 ? "eye.left" : "eye.right", color: .white,
                       scale: SCNVector3(0.11, 0.17, 0.06), at: SCNVector3(x, 0.04, 0.51), parent: head)
            }
            sphere("smile", color: UIColor(red: 0.31, green: 0.88, blue: 1, alpha: 1),
                   scale: SCNVector3(0.15, 0.04, 0.025), at: SCNVector3(0, -0.075, 0.51), parent: head)
            let stem = SCNCapsule(capRadius: 0.026, height: 0.22)
            stem.materials = [material(blue)]
            let stemNode = SCNNode(geometry: stem); stemNode.position = SCNVector3(0, 0.59, 0)
            head.addChildNode(stemNode)
            antenna.geometry = SCNSphere(radius: 0.075)
            antenna.geometry?.materials = [material(UIColor(red: 1, green: 0.62, blue: 0.28, alpha: 1), glow: true)]
            antenna.position = SCNVector3(0, 0.73, 0); head.addChildNode(antenna)
            for sign: Float in [-1, 1] {
                sphere("foot", color: cream, scale: SCNVector3(0.40, 0.25, 0.62), at: SCNVector3(sign * 0.29, -0.82, 0.14), parent: doll)
                let joint = sign > 0 ? arm : SCNNode()
                joint.name = sign > 0 ? "arm.wave" : "arm.left"
                joint.position = SCNVector3(sign * 0.55, -0.10, 0)
                doll.addChildNode(joint)
                sphere("sleeve", color: blue, scale: SCNVector3(0.25, 0.64, 0.30), at: SCNVector3(sign * 0.04, -0.17, 0), parent: joint)
                sphere("hand", color: cream, scale: SCNVector3(0.27, 0.26, 0.28), at: SCNVector3(sign * 0.08, -0.42, 0.01), parent: joint)
            }
            sphere("heart-light", color: UIColor(red: 1, green: 0.49, blue: 0.51, alpha: 1),
                   scale: SCNVector3(0.15, 0.15, 0.05), at: SCNVector3(0, -0.22, 0.40), parent: doll)
        }
        func configure(_ view: SCNView, mood: AmoreCompanionMood, pokes: Int, animate: Bool, dark: Bool) {
            ambient.light?.intensity = dark ? 650 : 480
            view.pointOfView = camera
            view.rendersContinuously = animate
            view.isPlaying = animate
            scene.isPaused = !animate
            if !animate { return }
            if !animationStarted {
                animationStarted = true
                let rise = SCNAction.moveBy(x: 0, y: 0.035, z: 0, duration: 1.8)
                rise.timingMode = .easeInEaseOut
                doll.runAction(.repeatForever(.sequence([rise, rise.reversed()])), forKey: "breathe")
                for name in ["eye.left", "eye.right"] {
                    guard let eye = head.childNode(withName: name, recursively: true) else { continue }
                    let openY = eye.scale.y
                    let close = SCNAction.customAction(duration: 0.09) { node, elapsed in
                        node.scale.y = openY * (1 - 0.87 * Float(elapsed / 0.09))
                    }
                    let open = SCNAction.customAction(duration: 0.13) { node, elapsed in
                        node.scale.y = openY * (0.13 + 0.87 * Float(elapsed / 0.13))
                    }
                    eye.runAction(.repeatForever(.sequence([.wait(duration: 4.7), close, .wait(duration: 0.06), open])), forKey: "blink")
                }
            }
            if mood != lastMood {
                lastMood = mood
                head.removeAction(forKey: "mood")
                antenna.removeAction(forKey: "glow")
                head.eulerAngles = SCNVector3Zero
                switch mood {
                case .idle:
                    let look = SCNAction.rotateTo(x: 0, y: 0.10, z: 0, duration: 2.0)
                    look.timingMode = .easeInEaseOut
                    head.runAction(.repeatForever(.sequence([look, .rotateTo(x: 0, y: -0.10, z: 0, duration: 2.0)])), forKey: "mood")
                case .thinking:
                    let tip = SCNAction.rotateTo(x: 0.08, y: -0.15, z: 0.12, duration: 0.45)
                    tip.timingMode = .easeInEaseOut
                    head.runAction(tip, forKey: "mood")
                    antenna.runAction(.repeatForever(.sequence([.scale(to: 1.25, duration: 0.6), .scale(to: 1, duration: 0.6)])), forKey: "glow")
                case .working:
                    head.runAction(.repeatForever(.sequence([.rotateTo(x: 0.10, y: 0, z: 0, duration: 0.45), .rotateTo(x: -0.02, y: 0, z: 0, duration: 0.45)])), forKey: "mood")
                }
            }
            if let previous = lastPokes, pokes != previous {
                arm.removeAction(forKey: "hello")
                let lift = SCNAction.rotateTo(x: 0, y: 0, z: 2.15, duration: 0.18)
                arm.runAction(.sequence([lift, .rotateTo(x: 0, y: 0, z: 1.6, duration: 0.16), lift,
                                         .rotateTo(x: 0, y: 0, z: 0, duration: 0.24)]), forKey: "hello")
            }
            lastPokes = pokes
        }
    }
}

/// A paused or Reduce-Motion avatar must still show its initial real model.
/// Poster is a SceneKit-rendered image, not separate artwork or a test fake.
final class AmoreCompanionSurface: UIView {
    let sceneView = SCNView(frame: .zero)
    let poster = UIImageView()
    var animate = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; backgroundColor = .clear
        poster.contentMode = .scaleAspectFit
        poster.isUserInteractionEnabled = false
        addSubview(sceneView); addSubview(poster)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let changed = sceneView.bounds.size != bounds.size
        sceneView.frame = bounds; poster.frame = bounds
        if changed || poster.image == nil { refreshPoster() }
    }
    func refreshPoster() {
        guard bounds.width > 1, bounds.height > 1, sceneView.pointOfView != nil else { return }
        poster.image = sceneView.snapshot()
        poster.isHidden = false
        sceneView.setNeedsDisplay()
    }
}
