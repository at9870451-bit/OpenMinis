import XCTest
import SwiftUI
import UIKit
import UniformTypeIdentifiers
@testable import PokiComponents

@MainActor
final class PokiComponentTests: XCTestCase {
    func testPokiPageAndSidebarColorsResolveInBothModes() async {
        check(PokiTheme.uiBackground, light: 0xF5F8FC, dark: 0x05070D)
        check(PokiTheme.uiSidebar, light: 0xEFF4FC, dark: 0x081329)
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
