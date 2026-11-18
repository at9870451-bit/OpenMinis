import XCTest
import SwiftUI
import UIKit
import SceneKit
@testable import Amore134Components

@MainActor
final class Amore134Tests: XCTestCase {
    func testDrawerProgressAndComposerScaleAreBounded() {
        XCTAssertEqual(AmoreDrawerPresentation.composerScale(progress: 0, reduceMotion: false), 1)
        XCTAssertEqual(AmoreDrawerPresentation.composerScale(progress: 1, reduceMotion: false), 0.84, accuracy: 0.0001)
        XCTAssertEqual(AmoreDrawerPresentation.composerScale(progress: 3, reduceMotion: false), 0.84, accuracy: 0.0001)
        XCTAssertEqual(AmoreDrawerPresentation.composerScale(progress: 1, reduceMotion: true), 1)
        XCTAssertEqual(AmoreDrawerPresentation.phase(-1), 0)
        XCTAssertGreaterThan(PokiDrawerMetrics.cornerRadius(progress: 1, safeAreaInsets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)), 34)
    }

    func testOriginalMarqueeClockDirectionWrapHoldAndResume() {
        for speed in [20.0, -18.0] {
            var clock = AmoreMarqueeClock()
            for frame in 1...12000 {
                _ = clock.advance(to: Double(frame) / 30, period: 173, speed: speed, running: true, touching: false, scale: 2)
                XCTAssertGreaterThanOrEqual(clock.drift, 0)
                XCTAssertLessThan(clock.drift, 173)
            }
            XCTAssertEqual(clock.velocity, speed, accuracy: 0.01)
            _ = clock.advance(to: 401, period: 173, speed: speed, running: true, touching: true, scale: 2)
            XCTAssertEqual(clock.velocity, 0)
            let held = clock.drift
            _ = clock.advance(to: 401.1, period: 173, speed: speed, running: true, touching: false, scale: 2)
            _ = clock.advance(to: 402, period: 173, speed: speed, running: true, touching: false, scale: 2)
            XCTAssertEqual(clock.drift, held, accuracy: 0.51)
            for frame in 1...90 { _ = clock.advance(to: 403.1 + Double(frame)/30, period: 173, speed: speed, running: true, touching: false, scale: 2) }
            XCTAssertNotEqual(clock.velocity, 0)
        }
    }

    func testSidebarPreferencesDoNotInventEntriesOrRestoreExplicitEmpty() {
        let original: [AmoreSidebarShortcut] = [.tools, .providers, .appearance, .homeShortcuts]
        XCTAssertEqual(AmoreSidebarShortcutPreferences.decode(AmoreSidebarShortcutPreferences.encode(original)), original)
        XCTAssertEqual(AmoreSidebarShortcutPreferences.decode("[]"), [])
        XCTAssertEqual(AmoreSidebarShortcutPreferences.decode("[\"tools\",\"invalid\",\"tools\",\"memory\"]"), [.tools, .memory])
        XCTAssertEqual(AmoreSidebarShortcutPreferences.decode("broken"), AmoreSidebarShortcut.defaults)
        XCTAssertEqual(AmoreSidebarShortcut.allCases.count, 30)
    }

    func testShortcutCRUDAndPersistenceUseProductionStore() throws {
        let key = "amore134-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let store = AmoreHomeShortcutStore(storage: defaults)
        XCTAssertGreaterThanOrEqual(store.items.count, 18)
        var item = AmoreHomeShortcut(id: "test-new", appName: "Amore", title: "Test prompt", symbol: "sparkles", action: .init(kind: .prompt, value: "Draft a test. Do not send automatically."))
        try store.add(item)
        store.setHidden(true, id: item.id)
        XCTAssertFalse(store.visibleItems.contains { $0.id == item.id })
        item.title = "Changed"; try store.update(item)
        XCTAssertTrue(try XCTUnwrap(store.items.first { $0.id == item.id }).hidden)
        store.setHidden(false, id: item.id)
        XCTAssertTrue(store.visibleItems.contains { $0.id == item.id && $0.title == "Changed" })
        let reloaded = AmoreHomeShortcutStore(storage: defaults)
        XCTAssertTrue(reloaded.items.contains { $0.id == item.id && $0.title == "Changed" })
        reloaded.remove(id: item.id)
        XCTAssertFalse(AmoreHomeShortcutStore(storage: defaults).items.contains { $0.id == item.id })
        XCTAssertThrowsError(try store.add(.init(id: "unsafe", appName: "Amore", title: "Unsafe", symbol: "xmark", action: .init(kind: .link, value: "http://example.com"))))
    }

    func testDrawerOpenKeepsLiveConversationPixelsAndReduceMotionCloses() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let red = try await render(DrawerProbe(color: .red, progress: 1, reduceMotion: false), style: style, minimumColors: 2)
            let blue = try await render(DrawerProbe(color: .blue, progress: 1, reduceMotion: false), style: style, minimumColors: 2)
            let r = try pixel(red, x: 354, y: 400), b = try pixel(blue, x: 354, y: 400)
            XCTAssertGreaterThan(r.0, b.0 + 0.4)
            XCTAssertGreaterThan(b.2, r.2 + 0.4)
            let closed = try await render(DrawerProbe(color: .red, progress: 0, reduceMotion: true), style: style, minimumColors: 2)
            XCTAssertGreaterThan(try pixel(closed, x: 190, y: 400).0, 0.85)
            attach(red, name: "Amore134-Visible-Drawer-" + (style == .dark ? "Dark" : "Light"))
        }
    }

    func testActualHeaderAvatarMarqueeAndSidebarSnapshots() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let image = try await render(HeaderAndMarqueeProbe(), style: style)
            attach(image, name: "Amore134-Avatar-Marquee-" + (style == .dark ? "Dark" : "Light"))
            let side = try await render(Amore135DrawerProbe(), style: style)
            attach(side, name: "Amore134-Vertical-Shortcuts-" + (style == .dark ? "Dark" : "Light"))
        }
    }

    func testLiveGlassReplyAndCustomPortraitSnapshots() async throws {
        let portrait = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
            UIColor.systemIndigo.setFill(); UIBezierPath(ovalIn: CGRect(x: 20, y: 20, width: 56, height: 56)).fill()
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let sample = ZStack {
                LinearGradient(colors: [.blue.opacity(0.4), .purple.opacity(0.25), .cyan.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 28) {
                    AmoreConversationChrome(home: false, thinking: false, busy: false, title: "Custom image preview", active: false, portrait: portrait, openThreads: {}, openModel: {})
                    Text("AI reply · glass background\n回复文字与选择行为保持不变。\nhttps://example.com")
                        .foregroundStyle(PokiTheme.primaryText).padding(18)
                        .background(PokiAssistantMessageSurface())
                    Text("Opaque export fallback").padding(18)
                        .background(PokiAssistantMessageSurface()).environment(\.chatSnapshotRendering, true)
                    Spacer()
                }.padding(.top, 65).padding(.horizontal, 16)
            }.ignoresSafeArea()
            attach(try await render(sample, style: style), name: "Amore135-Glass-Custom-Avatar-" + (style == .dark ? "Dark" : "Light"))
        }
    }

    func testActualCompanionAnimationAndLifecyclePause() {
        let controller = AmoreCompanionScene.Coordinator()
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        view.scene = controller.scene
        controller.configure(view, mood: .thinking, pokes: 0, animate: true, dark: false)
        XCTAssertNotNil(controller.doll.action(forKey: "breathe"))
        XCTAssertNotNil(controller.head.childNode(withName: "eye.left", recursively: true)?.action(forKey: "blink"))
        XCTAssertNotNil(controller.antenna.action(forKey: "glow"))
        controller.configure(view, mood: .working, pokes: 1, animate: true, dark: true)
        XCTAssertNotNil(controller.arm.action(forKey: "hello"))
        controller.configure(view, mood: .idle, pokes: 1, animate: false, dark: false)
        XCTAssertFalse(view.isPlaying)
        XCTAssertTrue(controller.scene.isPaused)
    }

    func testActualDollRendersModelPixelsNotOnlyBackground() throws {
        let controller = AmoreCompanionScene.Coordinator()
        let surface = AmoreCompanionSurface(frame: CGRect(x: 0, y: 0, width: 240, height: 240))
        surface.sceneView.scene = controller.scene
        surface.sceneView.pointOfView = controller.camera
        controller.configure(surface.sceneView, mood: .idle, pokes: 0, animate: false, dark: false)
        surface.layoutIfNeeded()
        let image = surface.sceneView.snapshot()
        let cg = try XCTUnwrap(image.cgImage)
        var rgba = [UInt8](repeating: 0, count: 240*240*4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 240, height: 240, bitsPerComponent: 8, bytesPerRow: 240*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 240, height: 240))
        let opaque = stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] > 200 }.count
        XCTAssertGreaterThan(opaque, 4000, "Avatar must contain rendered doll pixels, not an empty circle")
        attach(image, name: "Amore134-Actual-3D-Doll")
    }

    func testEveryDefaultCapsuleHasAnIndependentRealActionCallback() {
        for item in AmoreHomeShortcutCatalog.items(chinese: true) {
            var inserted: String?; var destination: String?; var link: URL?
            let router = AmoreHomeActionRouter(setInput: { inserted = $0 }, openPage: { destination = $0 }, openLink: { link = $0 })
            router.perform(item.action)
            switch item.action.kind {
            case .prompt:
                XCTAssertEqual(inserted, item.action.value, item.id)
                XCTAssertNil(destination); XCTAssertNil(link)
            case .page:
                XCTAssertEqual(destination, AmoreShortcutRoutes.canonicalPage(item.action.value), item.id)
                XCTAssertNil(inserted); XCTAssertNil(link)
            case .link:
                XCTAssertEqual(link?.absoluteString, item.action.value, item.id)
            }
        }
    }

    func testSevenSettingsColorsAreDistinctAndOrdered() {
        XCTAssertEqual(SettingsIconColor.allCases.count, 7)
        XCTAssertEqual(SettingsFeature.allCases.prefix(7).map(\.iconColor), [.red, .orange, .yellow, .green, .cyan, .blue, .purple])
        XCTAssertEqual(Set(SettingsIconColor.allCases.map(\.lightHex)).count, 7)
        XCTAssertEqual(Set(SettingsIconColor.allCases.map(\.darkHex)).count, 7)
        XCTAssertEqual(SettingsIconColor.yellow.foregroundHex, 0x1C1C1E)
    }

    private func attach(_ image: UIImage, name: String) {
        let item = XCTAttachment(image: image); item.name = name; item.lifetime = .keepAlways; add(item)
    }
    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> (Double,Double,Double) {
        let cg = try XCTUnwrap(image.cgImage); var data = [UInt8](repeating: 0, count: 390*844*4)
        let context = try XCTUnwrap(CGContext(data: &data, width: 390, height: 844, bitsPerComponent: 8, bytesPerRow: 390*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 390, height: 844)); let offset = (y*390+x)*4
        return (Double(data[offset])/255, Double(data[offset+1])/255, Double(data[offset+2])/255)
    }
    private func render<V: View>(_ root: V, style: UIUserInterfaceStyle, minimumColors: Int = 9) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: root.environment(\.colorScheme, style == .dark ? .dark : .light))
        window.rootViewController = host; host.loadViewIfNeeded(); host.view.frame = window.bounds
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(nanoseconds: 500_000_000)
        host.view.setNeedsLayout(); host.view.layoutIfNeeded(); window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertTrue(drawn)
        let bytes = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        let unique = Set(stride(from: 0, to: bytes.count - 3, by: 64).map { (Int(bytes[$0])/16)*256 + (Int(bytes[$0 + 1])/16)*16 + Int(bytes[$0 + 2])/16 })
        XCTAssertGreaterThanOrEqual(unique.count, minimumColors, "Empty snapshots must fail")
        return image
    }
}

private struct DrawerProbe: View {
    let color: Color
    let progress: CGFloat
    let reduceMotion: Bool
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color(uiColor: .systemGroupedBackground)
                PokiDrawerConversationPanel(containerSize: geo.size, safeAreaInsets: geo.safeAreaInsets,
                    drawerWidth: PokiDrawerMetrics.travel(for: geo.size.width), progress: progress,
                    presentationActive: progress > 0, reduceMotion: reduceMotion, onClose: {}) {
                    color.overlay { Text("VISIBLE CONVERSATION").foregroundStyle(.white) }
                }
            }
        }.ignoresSafeArea()
    }
}
private struct HeaderAndMarqueeProbe: View {
    var body: some View {
        VStack {
            AmoreConversationChrome(home: true, thinking: false, busy: false, title: "Amore", active: true,
                // Legacy marquee snapshot only. Real UIKit menu taps/bounds are covered
                // separately by Amore135HeaderUITests and its production-extracted host.
                trailing: AnyView(Color.clear),
                openThreads: {}, openModel: {})
            Spacer(minLength: 12)
            Text("Amore").font(.largeTitle.bold())
            AmoreHomeMarqueePanel(items: AmoreHomeShortcutStore.defaults,
                revision: 1, active: false, onAction: { _ in })
            Spacer()
        }.background(PokiTheme.background)
    }
}
