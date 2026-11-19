import XCTest
import SwiftUI
import UIKit
@testable import PokiComponents

/// ISOLATED REAL HELPER, not a replacement SettingsSheet or device-service test.
/// Include production AmoreSettingsGlassStyle, SettingsFeatureIcon, AmoreTheme,
/// AmoreChatBackdrop and AmoreAppearance in the host. The existing
/// scripts/test-poki-components.sh copies these exact files. No chat/provider
/// singleton is instantiated. Run on iOS 18 and 26; Xcode is required.
@MainActor
final class Amore136SettingsStyleTests: XCTestCase {
    func testNativeMaterialGlassAndAccessibilityPolicy() {
        XCTAssertEqual(AmoreSettingsGlassPolicy.surface(reduceTransparency: false,
            supportsLiquidGlass: false), .material)
        XCTAssertEqual(AmoreSettingsGlassPolicy.surface(reduceTransparency: false,
            supportsLiquidGlass: true), .glass)
        for supportsGlass in [false, true] {
            XCTAssertEqual(AmoreSettingsGlassPolicy.surface(reduceTransparency: true,
                supportsLiquidGlass: supportsGlass), .opaque)
            XCTAssertEqual(AmoreSettingsGlassPolicy.surface(reduceTransparency: false,
                increaseContrast: true, supportsLiquidGlass: supportsGlass), .opaque)
        }
    }

    func testSevenQuietInkColoursRemainDistinctAndInStableOrder() {
        XCTAssertEqual(SettingsIconColor.allCases.count, 7)
        XCTAssertEqual(SettingsFeature.allCases.prefix(7).map(\.iconColor),
            [.red, .orange, .yellow, .green, .cyan, .blue, .purple])
        XCTAssertEqual(Set(SettingsIconColor.allCases.map(\.lightHex)).count, 7)
        XCTAssertEqual(Set(SettingsIconColor.allCases.map(\.darkHex)).count, 7)
        for ink in SettingsIconColor.allCases {
            XCTAssertGreaterThanOrEqual(contrast(ink.lightHex,
                AmoreSettingsGlassPolicy.opaqueFillHex(dark: false)), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(ink.darkHex,
                AmoreSettingsGlassPolicy.opaqueFillHex(dark: true)), 4.5)
            XCTAssertLessThan(saturation(ink.lightHex), 0.75)
            XCTAssertLessThan(saturation(ink.darkHex), 0.5)
        }
    }

    func testFallbackIsOpaqueAndAdaptiveNotForcedDark() {
        for dark in [false, true] {
            let style: UIUserInterfaceStyle = dark ? .dark : .light
            let resolved = AmoreSettingsGlassPalette.uiOpaqueFill.resolvedColor(
                with: UITraitCollection(userInterfaceStyle: style))
            let c = components(resolved)
            let expected = AmoreSettingsGlassPolicy.opaqueFillHex(dark: dark)
            for (i, shift) in [16, 8, 0].enumerated() {
                XCTAssertEqual(c[i], CGFloat((expected >> shift) & 255) / 255, accuracy: 0.001)
            }
            XCTAssertEqual(c[3], 1, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(contrast(dark ? 0xFFFFFF : 0x000000, expected), 4.5)
        }
        XCTAssertEqual(AmoreAppearance.storageKey, "amore.appearance")
        XCTAssertNil(AmoreAppearance.automatic.colorScheme)
        XCTAssertEqual(AmoreAppearance.light.colorScheme, .light)
        XCTAssertEqual(AmoreAppearance.dark.colorScheme, .dark)
    }

    func testRealOpaqueSurfaceActuallyPaintsInBothSchemes() throws {
        for dark in [false, true] {
            for _ in [false, true] {
                // Cover the helper's REAL paint branch, not only its policy.
                let root = AmoreSettingsGlassRowBackground(forceOpaque: true)
                    .frame(width: 80, height: 60)
                    .environment(\.colorScheme, dark ? .dark : .light)

                let renderer = ImageRenderer(content: root)
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage?.cgImage)
                var pixel = [UInt8](repeating: 0, count: 4)
                let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                // Sample the centre, not the decorative half-point separator.
                context.translateBy(x: -40, y: -30)
                context.draw(image, in: CGRect(x: 0, y: 0, width: 80, height: 60))
                let hex = AmoreSettingsGlassPolicy.opaqueFillHex(dark: dark)
                for (i, shift) in [16, 8, 0].enumerated() {
                    XCTAssertEqual(Double(pixel[i]), Double((hex >> shift) & 255), accuracy: 2)
                }
                XCTAssertEqual(pixel[3], 255)
            }
        }
    }

    func testPaintOnlyHelperDoesNotChangeTextOrControlMeasurement() {
        for size in [DynamicTypeSize.large, .accessibility3] {
            let row = Button {} label: {
                Label("Appearance 外观与可访问性", systemImage: "paintbrush")
                    .font(.body)
            }
            .environment(\.dynamicTypeSize, size)
            let plain = UIHostingController(rootView: row)
            let glass = UIHostingController(rootView: row
                .background(AmoreSettingsGlassRowBackground()))
            let opaque = UIHostingController(rootView: row
                .background(AmoreSettingsGlassRowBackground(forceOpaque: true)))
            let proposed = CGSize(width: 280, height: 1_000)
            let expected = plain.sizeThatFits(in: proposed)
            for actual in [glass.sizeThatFits(in: proposed), opaque.sizeThatFits(in: proposed)] {
                XCTAssertEqual(actual.width, expected.width, accuracy: 0.01)
                XCTAssertEqual(actual.height, expected.height, accuracy: 0.01)
            }
        }
    }

    func testMountedSettingsGlassSnapshotsFollowAppearance() async throws {
        // Production paint and icons mounted in a real List. This is a component
        // host, not the full SettingsSheet or a device-service acceptance test.
        for dark in [false, true] {
            let style: UIUserInterfaceStyle = dark ? .dark : .light
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let prior = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.overrideUserInterfaceStyle = style
            let root = NavigationStack {
                List {
                    Section("Appearance") {
                        Label { Text("Theme · Follow System") } icon: { SettingsFeatureIcon(symbol: "paintbrush", feature: .appearance) }
                    }.amoreSettingsGlassRows()
                    Section("Agent Runtime") {
                        Label { Text("Model providers") } icon: { SettingsFeatureIcon(symbol: "server.rack", feature: .providers) }
                        Label { Text("Local device status") } icon: { SettingsFeatureIcon(symbol: "iphone", feature: .developerConnection) }
                        Label { Text("Device approvals") } icon: { SettingsFeatureIcon(symbol: "checkmark.shield", feature: .permissions) }
                        Label { Text("Workflow output") } icon: { SettingsFeatureIcon(symbol: "rectangle.stack", feature: .tools) }
                    }.amoreSettingsGlassRows()
                    Section("Storage") {
                        Label { Text("Runtime environment") } icon: { SettingsFeatureIcon(symbol: "shippingbox", feature: .rootfs) }
                        Label { Text("Storage management") } icon: { SettingsFeatureIcon(symbol: "internaldrive", feature: .storage) }
                    }.amoreSettingsGlassRows()
                    Section("About") {
                        Label { Text("About Amore") } icon: { SettingsFeatureIcon(symbol: "info", feature: .about) }
                    }.amoreSettingsGlassRows()
                }.amoreSettingsGlass().navigationTitle("Settings")
            }.environment(\.colorScheme, dark ? .dark : .light)
            let host = UIHostingController(rootView: root)
            window.rootViewController = host
            host.loadViewIfNeeded(); host.view.frame = window.bounds
            window.makeKeyAndVisible(); window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 450_000_000)
            host.view.layoutIfNeeded(); window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            var painted = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                painted = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(painted)
            let bytes = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
            let colors = Set(stride(from: 0, to: bytes.count - 3, by: 64).map {
                (Int(bytes[$0]) / 16) * 256 + (Int(bytes[$0 + 1]) / 16) * 16 + Int(bytes[$0 + 2]) / 16
            })
            XCTAssertGreaterThan(colors.count, 15, "Blank/solid screenshots must fail")
            let item = XCTAttachment(image: image)
            item.name = "Amore136-Production-Settings-Style-" + (dark ? "Dark" : "Light")
            item.lifetime = .keepAlways; add(item)
            window.isHidden = true; window.rootViewController = nil; prior?.makeKey()
        }
    }

    // Native material/glass backdrop sampling and real List/Form tap routing
    // require a mounted window + simulator UI taps; the opaque renderer above
    // intentionally makes NO claim to validate live blur, SetupStep pushes,
    // permissions, approvals, account data or a physical device connection.
    private func components(_ color: UIColor) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        return [r, g, b, a]
    }

    private func saturation(_ hex: UInt32) -> Double {
        let c = [16, 8, 0].map { Double((hex >> $0) & 255) / 255 }
        let high = c.max()!, low = c.min()!
        return high == 0 ? 0 : (high - low) / high
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            let c = [16, 8, 0].map { shift -> Double in
                let v = Double((hex >> shift) & 255) / 255
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return zip(c, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
