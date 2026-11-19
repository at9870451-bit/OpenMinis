import XCTest
import SwiftUI
import UIKit
@testable import PokiComponents

/// Isolated production-helper tests; NOT a full App or drawer service test.
/// Host App target: copy AmoreDrawerFooterGlass.swift unchanged. Test target:
/// copy this file, changing ONLY the testable module name if necessary.
/// Existing Amore135HeaderUITests tests the extracted production footer's
/// geometry/actions. The host must also copy the new helper for that UI test.
/// Run on iOS 18 and 26. ImageRenderer below tests ONLY opaque accessibility
/// paint; it does not verify native backdrop blur, Liquid Glass or real taps.
@MainActor
final class Amore138DrawerGlassTests: XCTestCase {
    func testCompleteAvailabilityAndAccessibilityPolicy() {
        for supportsGlass in [false, true] {
            for reduceTransparency in [false, true] {
                for increaseContrast in [false, true] {
                    let expected: AmoreDrawerFooterGlassPolicy.Surface =
                        reduceTransparency || increaseContrast ? .opaque :
                            (supportsGlass ? .glass : .material)
                    XCTAssertEqual(AmoreDrawerFooterGlassPolicy.surface(
                        reduceTransparency: reduceTransparency,
                        increaseContrast: increaseContrast,
                        supportsLiquidGlass: supportsGlass), expected)
                }
            }
        }
    }

    func testPaintOnlyModifierPreservesBothFixedButtonSizes() {
        for size in [DynamicTypeSize.large, .accessibility3] {
            let newChat = Button {} label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.body.weight(.semibold))
                    Text("New Chat 新会话")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .padding(.horizontal, 14)
                .frame(width: 132, height: 52)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .environment(\.dynamicTypeSize, size)
            assertPaintPreservesMeasurement(newChat, shape: Capsule(), expected: CGSize(width: 132, height: 52))

            let settings = Button {} label: {
                Image(systemName: "gearshape")
                    .font(.title3.weight(.medium))
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .environment(\.dynamicTypeSize, size)
            assertPaintPreservesMeasurement(settings, shape: Circle(), expected: CGSize(width: 52, height: 52))
        }
    }

    func testAccessibilityFallbackUsesAdaptiveSemanticColoursWithReadableInk() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let traits = UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceStyle: style),
                    UITraitCollection(accessibilityContrast: contrast)
                ])
                let background = components(UIColor.secondarySystemBackground, traits: traits)
                let foreground = components(UIColor.label, traits: traits)
                XCTAssertEqual(background[3], 1, accuracy: 0.001)
                XCTAssertEqual(foreground[3], 1, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(contrastRatio(foreground, background), 4.5)
            }
        }
    }

    func testRealOpaquePaintInBothSchemes() throws {
        // Policy tests cover Reduce Transparency/Increase Contrast independently.
        // ImageRenderer receives a normal-contrast colour scheme; UIKit's
        // performAsCurrent alone cannot inject the SwiftUI contrast environment.
        for dark in [false, true] {
            let traits = UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
                UITraitCollection(accessibilityContrast: .normal)
            ])
            let root = AmoreDrawerFooterGlass(shape: Capsule(), forceOpaque: true)
                .frame(width: 80, height: 60)
                .environment(\.colorScheme, dark ? .dark : .light)
            var rendered: CGImage?
            traits.performAsCurrent {
                let renderer = ImageRenderer(content: root)
                renderer.scale = 1
                rendered = renderer.uiImage?.cgImage
            }
            let image = try XCTUnwrap(rendered)
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue))
            context.translateBy(x: -40, y: -30)
            context.draw(image, in: CGRect(x: 0, y: 0, width: 80, height: 60))
            let expected = components(UIColor.secondarySystemBackground, traits: traits)
            for index in 0..<3 {
                XCTAssertEqual(Double(pixel[index]) / 255, expected[index], accuracy: 0.012)
            }
            XCTAssertEqual(pixel[3], 255)
        }
    }

    private func assertPaintPreservesMeasurement<V: View, S: InsettableShape>(
        _ content: V, shape: S, expected: CGSize
    ) {
        let proposed = CGSize(width: 280, height: 1_000)
        let plain = UIHostingController(rootView: content).sizeThatFits(in: proposed)
        XCTAssertEqual(plain.width, expected.width, accuracy: 0.01)
        XCTAssertEqual(plain.height, expected.height, accuracy: 0.01)
        for reduceTransparency in [false, true] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                let painted = UIHostingController(rootView: content
                    .background(AmoreDrawerFooterGlass(shape: shape, forceOpaque: reduceTransparency || contrast == .increased)))
                    .sizeThatFits(in: proposed)
                XCTAssertEqual(painted.width, plain.width, accuracy: 0.01)
                XCTAssertEqual(painted.height, plain.height, accuracy: 0.01)
                XCTAssertGreaterThanOrEqual(painted.width, 44)
                XCTAssertGreaterThanOrEqual(painted.height, 44)
            }
        }
    }

    private func components(_ colour: UIColor, traits: UITraitCollection) -> [Double] {
        let resolved = colour.resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
        return [r, g, b, a].map(Double.init)
    }

    private func contrastRatio(_ foreground: [Double], _ background: [Double]) -> Double {
        func luminance(_ components: [Double]) -> Double {
            let linear = components.prefix(3).map { value in
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return zip(linear, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
