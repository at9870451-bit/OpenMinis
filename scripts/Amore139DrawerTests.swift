import XCTest
import SwiftUI
import UIKit
@testable import Amore134Components

@MainActor
final class Amore139DrawerTests: XCTestCase {
    func testDefaultDrawerHasNoOpaqueBlueAndHonoursAccessibility() {
        XCTAssertEqual(PokiTheme.uiSidebar.cgColor.alpha, 0)
        XCTAssertFalse(AmoreDrawerSurfacePolicy.opaque(reduceTransparency: false, increasedContrast: false))
        XCTAssertTrue(AmoreDrawerSurfacePolicy.opaque(reduceTransparency: true, increasedContrast: false))
        XCTAssertTrue(AmoreDrawerSurfacePolicy.opaque(reduceTransparency: false, increasedContrast: true))
        XCTAssertLessThan(AmoreDrawerSurfacePolicy.materialOpacity, 0.5)
    }

    func testConversationPixelsRemainBehindDrawerAcrossAllPhases() async throws {
        for dark in [false, true] {
            for progress in [CGFloat(0), 0.5, 1] {
                let red = try await render(sample(.red, progress: progress), dark: dark)
                let blue = try await render(sample(.blue, progress: progress), dark: dark)
                // This point is INSIDE the left drawer at its open position,
                // not the formerly exposed conversation strip on the right.
                let r = try pixel(red, x: 110, y: 400)
                let b = try pixel(blue, x: 110, y: 400)
                XCTAssertGreaterThan(r.0 - b.0, 0.35, "Live red pixels disappeared at phase \(progress)")
                XCTAssertGreaterThan(b.2 - r.2, 0.35, "Live blue pixels disappeared at phase \(progress)")
            }
        }
    }

    func testTranscriptTextAndRealFooterSnapshots() async throws {
        for dark in [false, true] {
            let size = CGSize(width: 390, height: 844)
            let view = AmoreTransparentDrawer(size: size, drawerWidth: 306,
                progress: 1, presentationActive: true, reduceMotion: false, onClose: {}) {
                ZStack {
                    Color(uiColor: dark ? .black : .white)
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(0..<8, id: \.self) { index in
                            Text("Live message \(index) — 保留实时会话内容")
                                .foregroundStyle(Color.primary).padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(index.isMultiple(of: 2) ? Color.cyan.opacity(0.30) : Color.orange.opacity(0.28), in: RoundedRectangle(cornerRadius: 18))
                        }
                    }.padding(16)
                }
            } sidebar: {
                Amore135DrawerProbe()
            }
            let image = try await render(view, dark: dark)
            let a = XCTAttachment(image: image)
            a.name = "Amore139-Transparent-History-" + (dark ? "Dark" : "Light")
            a.lifetime = .keepAlways; add(a)
        }
    }

    func testAccessibilityOpaqueFallbackIsActuallyOpaque() async throws {
        let red = try await render(Color.red.overlay(AmoreDrawerBackdrop(forceOpaque: true)), dark: false)
        let blue = try await render(Color.blue.overlay(AmoreDrawerBackdrop(forceOpaque: true)), dark: false)
        let r = try pixel(red, x: 110, y: 400), b = try pixel(blue, x: 110, y: 400)
        XCTAssertEqual(r.0, b.0, accuracy: 0.015)
        XCTAssertEqual(r.2, b.2, accuracy: 0.015)
    }

    private func sample(_ color: Color, progress: CGFloat) -> some View {
        AmoreTransparentDrawer(size: CGSize(width: 390, height: 844), drawerWidth: 306,
            progress: progress, presentationActive: true, reduceMotion: false, onClose: {}) {
            color
        } sidebar: { Color.clear }
    }
    private func render<V: View>(_ view: V, dark: Bool) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let host = UIHostingController(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        window.rootViewController = host; host.loadViewIfNeeded(); host.view.frame = window.bounds
        host.view.backgroundColor = .clear
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(nanoseconds: 400_000_000)
        host.view.layoutIfNeeded(); window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn)
        return image
    }
    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> (Double,Double,Double) {
        let cg = try XCTUnwrap(image.cgImage); var rgba = [UInt8](repeating: 0, count: 390*844*4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 390, height: 844, bitsPerComponent: 8,
            bytesPerRow: 390*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 390, height: 844))
        let o = (y*390+x)*4
        return (Double(rgba[o])/255,Double(rgba[o+1])/255,Double(rgba[o+2])/255)
    }
}
