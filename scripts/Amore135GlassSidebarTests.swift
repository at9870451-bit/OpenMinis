import XCTest
import SwiftUI
import UIKit
@testable import PokiComponents

/// Isolated-host helper. The host must include the production AmoreTheme,
/// PokiMessageSurface and ChatColors files. Change only the testable module
/// name when copying into a differently named component host.
@MainActor
final class Amore135GlassSidebarTests: XCTestCase {
    func testSidebarMatchesChatCanvasInBothAppearances() {
        check(PokiTheme.uiSidebar, style: .light, hex: 0xF5F8FC)
        check(PokiTheme.uiSidebar, style: .dark, hex: 0x05070D)
        check(PokiTheme.uiBackground, style: .light, hex: 0xF5F8FC)
        check(PokiTheme.uiBackground, style: .dark, hex: 0x05070D)
        XCTAssertEqual(PokiTheme.uiSidebar.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)),
                       PokiTheme.uiBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
        XCTAssertEqual(PokiTheme.uiSidebar.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)),
                       PokiTheme.uiBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
    }

    func testPrimaryAndSecondaryInkMeetAAInEveryDrawerState() {
        check(PokiTheme.uiSidebarInk, style: .light, hex: 0x173763)
        check(PokiTheme.uiSidebarInk, style: .dark, hex: 0xFFFFFF)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let backgrounds = [PokiTheme.uiSidebar, PokiTheme.uiSidebarControl,
                               PokiTheme.uiSidebarSelected, PokiTheme.uiSidebarPressed]
            for background in backgrounds {
                for ink in [PokiTheme.uiSidebarInk, PokiTheme.uiSidebarHeading] {
                    XCTAssertGreaterThanOrEqual(contrast(ink, background, style: style), 4.5)
                }
            }
            XCTAssertGreaterThanOrEqual(contrast(PokiTheme.uiSidebarActionInk,
                                                PokiTheme.uiSidebarAction, style: style), 4.5)
        }
    }

    func testLiveMaterialAndOpaqueExportAccessibilityPolicy() {
        XCTAssertFalse(PokiAssistantMessageSurfacePolicy.usesOpaqueFill(
            reduceTransparency: false, snapshotRendering: false))
        XCTAssertTrue(PokiAssistantMessageSurfacePolicy.usesOpaqueFill(
            reduceTransparency: true, snapshotRendering: false))
        XCTAssertTrue(PokiAssistantMessageSurfacePolicy.usesOpaqueFill(
            reduceTransparency: false, snapshotRendering: true))
        XCTAssertTrue(PokiAssistantMessageSurfacePolicy.usesOpaqueFill(
            reduceTransparency: true, snapshotRendering: true))
        var values = EnvironmentValues()
        XCTAssertFalse(values.chatSnapshotRendering)
        values.chatSnapshotRendering = true
        XCTAssertTrue(values.chatSnapshotRendering)
    }

    func testSurfaceDoesNotChangeHostedTextMeasurement() {
        let text = Text("AI reply\n正文与链接宽度不变")
            .font(.body).padding(.vertical, 2)
        let plain = UIHostingController(rootView: text)
        let live = UIHostingController(rootView: text.background(PokiAssistantMessageSurface()))
        let export = UIHostingController(rootView: text.background(PokiAssistantMessageSurface())
            .environment(\.chatSnapshotRendering, true))
        let proposed = CGSize(width: 280, height: 1_000)
        let expected = plain.sizeThatFits(in: proposed)
        for actual in [live.sizeThatFits(in: proposed), export.sizeThatFits(in: proposed)] {
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.01)
            XCTAssertEqual(actual.height, expected.height, accuracy: 0.01)
        }
    }

    private func check(_ color: UIColor, style: UIUserInterfaceStyle, hex: UInt32) {
        let c = components(color, style: style)
        for (i, shift) in [16, 8, 0].enumerated() {
            XCTAssertEqual(c[i], CGFloat((hex >> shift) & 255) / 255, accuracy: 0.0001)
        }
        XCTAssertEqual(c[3], 1, accuracy: 0.0001)
    }

    private func components(_ color: UIColor, style: UIUserInterfaceStyle) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getRed(&r, green: &g, blue: &b, alpha: &a))
        return [r, g, b, a]
    }

    private func contrast(_ foreground: UIColor, _ background: UIColor,
                          style: UIUserInterfaceStyle) -> Double {
        func luminance(_ color: UIColor) -> Double {
            let c = components(color, style: style).prefix(3).map { value -> Double in
                let v = Double(value)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return zip(c, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
