import XCTest
import SwiftUI
import UIKit
import UniformTypeIdentifiers
@testable import PokiComponents

@MainActor
final class PokiComponentTests: XCTestCase {
    func testPokiPageAndSidebarColorsResolveInBothModes() async {
        check(PokiTheme.uiBackground, light: 0xF5F8FC, dark: 0x05070D)
        check(PokiTheme.uiSidebar, light: 0xF5F8FC, dark: 0x05070D)
        check(PokiTheme.uiBlue, light: 0x0177FD, dark: 0x0177FD)
        check(PokiTheme.uiBlueText, light: 0x0177FD, dark: 0x4C9DFF)
        check(PokiTheme.uiPortrait, light: 0xE3EEFF, dark: 0x0C2748)
        check(PokiTheme.uiDanger, light: 0xE5484D, dark: 0xF2555A)
    }

    func testDrawerUsesPokiTravelNotFullScreenOverlay() async {
        XCTAssertEqual(PokiDrawerMetrics.travel(for: 390), 304)
        XCTAssertEqual(PokiDrawerMetrics.travel(for: 430), 335)
        XCTAssertEqual(PokiDrawerMetrics.travel(for: 1024), 420)
    }

    func testZIPPickerAcceptsMislabelledPublicItems() async {
        XCTAssertEqual(AmorePluginDocumentPicker.contentTypes(folder: false), [.item])
        XCTAssertEqual(AmorePluginDocumentPicker.contentTypes(folder: true), [.folder])
        let zip = URL(fileURLWithPath: "/tmp/evans-repo.zip")
        var received: URL?
        var cancelled = false
        let handler = AmorePluginDocumentPicker.Coordinator(onSelection: {
            received = try? $0.get()
        }, onCancel: { cancelled = true })
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        handler.documentPicker(picker, didPickDocumentsAt: [zip])
        XCTAssertEqual(received, zip)
        XCTAssertFalse(cancelled)
        handler.documentPickerWasCancelled(picker)
        XCTAssertTrue(cancelled)
    }

    func testThemeReferenceComponentsLightAndDark() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let scheme: ColorScheme = style == .dark ? .dark : .light
            let view = ThemeReference().environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view.frame(width: 390, height: 720))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = style == .dark ? "Poki-Components-Dark" : "Poki-Components-Light"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testFullWindowClipIncludesTopAndBottomSafeAreas() async {
        let insets = EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)
        let bounds = PokiDrawerPanelBounds(containerSize: CGSize(width: 390, height: 763), safeAreaInsets: insets)
        XCTAssertEqual(bounds.size, CGSize(width: 390, height: 844))
        XCTAssertEqual(bounds.centerOffset, CGSize(width: 0, height: -6.5))
        let shape = PokiConversationPanel(radius: 47)
        let path = shape.path(in: CGRect(origin: .zero, size: bounds.size))
        XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: 0.5)))
        XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: 843.5)))
        XCTAssertTrue(path.contains(CGPoint(x: 80, y: 80)))
        XCTAssertTrue(path.contains(CGPoint(x: 8, y: 422)))
        XCTAssertEqual(PokiDrawerMetrics.cornerRadius(progress: 0, safeAreaInsets: insets), 0)
        XCTAssertEqual(PokiDrawerMetrics.cornerRadius(progress: 1, safeAreaInsets: insets), 47)
    }

    func testShortcutIconsHaveDistinctAccessibleColorPairs() async {
        check(PokiTheme.uiToolOrange, light: 0xB85C00, dark: 0xFFB66B)
        check(PokiTheme.uiAgentPurple, light: 0x7954D6, dark: 0xB69CFF)
        check(PokiTheme.uiSkillTeal, light: 0x087C6F, dark: 0x5ED8C8)
        check(PokiTheme.uiMemoryRose, light: 0xB94278, dark: 0xF399C2)
        check(PokiTheme.uiRootfsIndigo, light: 0x4D59BE, dark: 0xA5ACFF)
        check(PokiTheme.uiBotCyan, light: 0x087DA5, dark: 0x70D5F3)
    }

    func testActualOpenPanelDoesNotExposeChatPixelsOrWhiteCorners() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let scheme: ColorScheme = style == .dark ? .dark : .light
            for reduced in [false, true] {
                let red = try render(PanelReference(chatColor: .red, reduced: reduced), scheme: scheme)
                let green = try render(PanelReference(chatColor: .green, reduced: reduced), scheme: scheme)
                XCTAssertEqual(red.pngData(), green.pngData(), "Open glass must not retain chat pixels")
                for point in [CGPoint(x: 304, y: 1), CGPoint(x: 304, y: 842)] {
                    let pixel = try rgba(red, at: point)
                    XCTAssertFalse(pixel[0] > 0.995 && pixel[1] > 0.995 && pixel[2] > 0.995,
                                   "Open drawer must not leave a pure-white corner")
                }
                let attachment = XCTAttachment(image: red)
                attachment.name = "Actual-Drawer-" + (style == .dark ? "Dark" : "Light") + (reduced ? "-ReduceMotion" : "")
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testUIKitBackedChatAlsoDisappearsBehindPureGlass() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for reduced in [false, true] {
                let first = try await windowSnapshot(PanelReference(chatColor: .red, reduced: reduced, usesUIKit: true), style: style)
                let second = try await windowSnapshot(PanelReference(chatColor: .green, reduced: reduced, usesUIKit: true), style: style)
                for point in [CGPoint(x: 304, y: 1), CGPoint(x: 304, y: 842),
                              CGPoint(x: 350, y: 300), CGPoint(x: 350, y: 700)] {
                    let a = try rgba(first, at: point)
                    let b = try rgba(second, at: point)
                    for index in 0..<3 { XCTAssertEqual(a[index], b[index], accuracy: 0.035, "UIKit chat colour leaked through glass") }
                }
                let attachment = XCTAttachment(image: second)
                attachment.name = "UIKit-Glass-" + (style == .dark ? "Dark" : "Light") + (reduced ? "-ReducedMotion" : "")
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func windowSnapshot<V: View>(_ content: V, style: UIUserInterfaceStyle) async throws -> UIImage {
        let scheme: ColorScheme = style == .dark ? .dark : .light
        let host = UIHostingController(rootView: content.environment(\.colorScheme, scheme).ignoresSafeArea())
        host.overrideUserInterfaceStyle = style
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = style
        window.backgroundColor = PokiTheme.uiSidebar
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func render<V: View>(_ content: V, scheme: ColorScheme) throws -> UIImage {
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme)
            .frame(width: 390, height: 844))
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage)
    }

    private func rgba(_ image: UIImage, at point: CGPoint) throws -> [CGFloat] {
        let source = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(source.width), height: CGFloat(source.height)))
            return true
        }
        XCTAssertTrue(drawn)
        let offset = (Int(point.y) * source.width + Int(point.x)) * 4
        return (0..<4).map { CGFloat(bytes[offset + $0]) / 255 }
    }

    private func check(_ color: UIColor, light: UInt32, dark: UInt32,
                       file: StaticString = #filePath, line: UInt = #line) {
        for (style, value) in [(UIUserInterfaceStyle.light, light), (.dark, dark)] {
            let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a), file: file, line: line)
            XCTAssertEqual(r, CGFloat((value >> 16) & 255) / 255, accuracy: 0.003, file: file, line: line)
            XCTAssertEqual(g, CGFloat((value >> 8) & 255) / 255, accuracy: 0.003, file: file, line: line)
            XCTAssertEqual(b, CGFloat(value & 255) / 255, accuracy: 0.003, file: file, line: line)
        }
    }
}

private struct ThemeReference: View {
    var body: some View {
        ZStack(alignment: .leading) {
            PokiTheme.sidebar
            VStack(alignment: .leading, spacing: 18) {
                Text("Amore").font(.largeTitle.bold()).foregroundStyle(PokiTheme.primaryText)
                Text("Today").font(.caption).foregroundStyle(PokiTheme.sidebarHeading)
                Text("Conversation").padding(12).frame(width: 240, alignment: .leading)
                    .background(PokiTheme.selection, in: RoundedRectangle(cornerRadius: 14))
                Spacer()
                Label("New Conversation", systemImage: "square.and.pencil")
                    .padding().background(PokiTheme.blue, in: Capsule()).foregroundStyle(.white)
            }.padding(24).frame(width: 304)
            VStack(spacing: 20) {
                Circle().fill(PokiTheme.portrait).frame(width: 44, height: 44)
                    .overlay(Image(systemName: "sparkles").foregroundStyle(PokiTheme.blueText))
                Text("AI assistant").foregroundStyle(PokiTheme.primaryText)
                HStack {
                    Label("Waiting", systemImage: "hand.raised").foregroundStyle(PokiTheme.amberInk)
                        .padding(8).background(PokiTheme.amberSoft, in: Capsule())
                    Label("Done", systemImage: "checkmark").foregroundStyle(PokiTheme.greenInk)
                        .padding(8).background(PokiTheme.greenSoft, in: Capsule())
                }.font(.caption)
                Spacer()
                HStack {
                    Image(systemName: "plus").foregroundStyle(PokiTheme.blueText)
                    Text("Message Amore").foregroundStyle(PokiTheme.secondaryText)
                    Spacer()
                    Image(systemName: "arrow.up.circle.fill").symbolRenderingMode(.palette)
                        .foregroundStyle(.white, PokiTheme.blue)
                }.padding(16).background {
                    RoundedRectangle(cornerRadius: 24).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 24).fill(PokiTheme.floatingSurface)
                }
            }.padding(20).frame(width: 390, height: 720)
                .background(PokiTheme.background)
                .overlay(PokiConversationCover(progress: 1, onClose: {}))
                .clipShape(RoundedRectangle(cornerRadius: 36))
                .offset(x: 304)
        }
    }
}

private struct PanelReference: View {
    let chatColor: Color
    let reduced: Bool
    var usesUIKit = false
    private let insets = EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)
    var body: some View {
        ZStack(alignment: .topLeading) {
            PokiTheme.sidebar
            VStack(alignment: .leading, spacing: 12) {
                Text("Amore").font(.largeTitle.bold()).foregroundStyle(PokiTheme.primaryText)
                DrawerShortcutLabel(title: "Agent Tools", symbol: "wrench.and.screwdriver", accent: PokiTheme.toolOrange)
                DrawerShortcutLabel(title: "Sub Agents", symbol: "person.2", accent: PokiTheme.agentPurple)
                DrawerShortcutLabel(title: "Skills", symbol: "puzzlepiece.extension", accent: PokiTheme.skillTeal)
                DrawerShortcutLabel(title: "Memory", symbol: "brain.head.profile", accent: PokiTheme.memoryRose)
            }.padding(20).frame(width: 304).padding(.top, 47)
            PokiDrawerConversationPanel(containerSize: CGSize(width: 390, height: 763),
                safeAreaInsets: insets, drawerWidth: 304, progress: 1, presentationActive: true,
                reduceMotion: reduced, onClose: {}) {
                    if usesUIKit {
                        UIKitChatProbe(color: UIColor(chatColor))
                    } else {
                        chatColor.overlay(Text("OLD CHAT MUST NOT SHOW").foregroundStyle(.white))
                    }
                }
                .offset(y: 47)
        }.frame(width: 390, height: 844).clipped()
    }
}

private struct UIKitChatProbe: UIViewRepresentable {
    let color: UIColor
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = color
        let label = UILabel()
        label.text = "OLD UIKIT CHAT MUST NOT SHOW"
        label.frame = CGRect(x: 20, y: 150, width: 300, height: 60)
        view.addSubview(label)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { view.backgroundColor = color }
}
