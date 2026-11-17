import XCTest
import SwiftUI
import UIKit
@testable import PokiComponents

@MainActor
final class PokiAppearanceTests: XCTestCase {
    func testAppearanceChoiceMatchesAutomaticLightDarkAndUnknownRecovers() async {
        XCTAssertEqual(AmoreAppearance.allCases.map(\.rawValue), ["", "light", "dark"])
        XCTAssertEqual(AmoreAppearance.resolved("unknown"), .automatic)
        XCTAssertNil(AmoreAppearance.automatic.colorScheme)
        XCTAssertEqual(AmoreAppearance.light.colorScheme, .light)
        XCTAssertEqual(AmoreAppearance.dark.colorScheme, .dark)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        AmoreAppearance.dark.apply(to: window)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
        AmoreAppearance.light.apply(to: window)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .light)
        AmoreAppearance.automatic.apply(to: window)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .unspecified)
    }

    func testPreferencePersistsWithoutSharingAppIconModeOrOldOverride() async throws {
        let suite = "app.amore.appearance-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2, forKey: "appearanceMode")
        defaults.set(1, forKey: "appIconMode")
        XCTAssertEqual(AmoreAppearance.resolved(defaults.string(forKey: AmoreAppearance.storageKey) ?? ""), .automatic)
        defaults.set(AmoreAppearance.dark.rawValue, forKey: AmoreAppearance.storageKey)
        XCTAssertEqual(AmoreAppearance.resolved(defaults.string(forKey: AmoreAppearance.storageKey) ?? ""), .dark)
        XCTAssertEqual(defaults.integer(forKey: "appIconMode"), 1)
    }

    func testAppearanceSemanticColorsMatchReference() async {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            XCTAssertEqual(PokiTheme.uiAssistantBubble.resolvedColor(with: traits),
                           UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits))
            XCTAssertEqual(PokiTheme.uiFieldEdge.resolvedColor(with: traits),
                           UIColor.systemGray4.resolvedColor(with: traits))
            XCTAssertEqual(PokiTheme.uiSettingsCard.resolvedColor(with: traits),
                           UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits))
        }
        XCTAssertEqual(AmoreChatLight.darkConversationStrength, 0.45)
        XCTAssertEqual(AmoreChatLight.homeLight.count, 20)
        XCTAssertEqual(AmoreChatLight.chatDark.count, 20)
    }

    func testBubbleTailDirectionAndSafeInsetsDoNotChangeLayout() async {
        let rect = CGRect(x: 0, y: 0, width: 180, height: 100)
        let outgoing = PokiMessageBubbleShape(direction: .outgoing).path(in: rect)
        let incoming = PokiMessageBubbleShape(direction: .incoming).path(in: rect)
        XCTAssertTrue(outgoing.contains(CGPoint(x: 177, y: 97)))
        XCTAssertFalse(outgoing.contains(CGPoint(x: 3, y: 97)))
        XCTAssertTrue(incoming.contains(CGPoint(x: 3, y: 97)))
        XCTAssertFalse(incoming.contains(CGPoint(x: 177, y: 97)))
        XCTAssertFalse(incoming.contains(CGPoint(x: 3, y: 3)))
        let inset = PokiMessageBubbleShape(direction: .outgoing).inset(by: 1).path(in: rect)
        XCTAssertGreaterThanOrEqual(inset.boundingRect.minX, 1)
        XCTAssertLessThanOrEqual(inset.boundingRect.maxX, 179)
        XCTAssertTrue(PokiMessageBubbleShape(direction: .incoming).path(in: .zero).isEmpty)
    }

    func testRenderActualChatAndAppearanceInLightDark() async throws {
        for dark in [false, true] {
            for home in [false, true] {
                let view = AppearanceChatReference(home: home, drawer: false)
                try await snapshot(view, dark: dark, name: "Amore-" + (home ? "Home" : "Chat") + (dark ? "-Dark" : "-Light"))
            }
            try await snapshot(AppearanceChatReference(home: false, drawer: true), dark: dark,
                         name: "Amore-Drawer" + (dark ? "-Dark" : "-Light"))
            try await snapshot(AppearanceReference(), dark: dark,
                         name: "Amore-Appearance" + (dark ? "-Dark" : "-Light"))
        }
    }

    private func snapshot<V: View>(_ view: V, dark: Bool, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: { $0.isKeyWindow })
        let host = UIHostingController(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        host.loadViewIfNeeded()
        host.view.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        window.layoutIfNeeded()
        // Yield rather than spin RunLoop.main from an async MainActor test:
        // SwiftUI must get a display transaction to create hosted content.
        try await Task.sleep(nanoseconds: 250_000_000)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        var didDraw = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            didDraw = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(didDraw, "UIKit could not render " + name)
        let cg = try XCTUnwrap(image.cgImage)
        var rgba = [UInt8](repeating: 0, count: 20 * 40 * 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 20, height: 40,
            bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 20, height: 40))
        var colors = Set<Int>()
        for i in stride(from: 0, to: rgba.count, by: 4) {
            colors.insert((Int(rgba[i]) / 16) * 256 + (Int(rgba[i + 1]) / 16) * 16 + Int(rgba[i + 2]) / 16)
        }
        XCTAssertGreaterThan(colors.count, 8, "Blank/empty snapshot must not count as visual acceptance: " + name)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct AppearanceReference: View {
    var body: some View {
        NavigationStack {
            List { AmoreAppearanceSection() }
                .scrollContentBackground(.hidden)
                .background { AmoreChatBackdrop(home: true) }
                .navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct AppearanceChatReference: View {
    let home: Bool
    let drawer: Bool
    var body: some View {
        ZStack {
            if drawer {
                PokiTheme.sidebar.ignoresSafeArea()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Amore").font(.largeTitle.bold())
                        DrawerShortcutLabel(title: "Agent Tools", symbol: "wrench.and.screwdriver", accent: PokiTheme.toolOrange)
                        DrawerShortcutLabel(title: "Memory", symbol: "brain.head.profile", accent: PokiTheme.memoryRose)
                        Text("Today").font(.footnote).foregroundStyle(PokiTheme.sidebarHeading)
                        Text("Conversation").padding(14).background(PokiTheme.selection, in: RoundedRectangle(cornerRadius: 14))
                        Spacer()
                        Button("New Conversation") {}.buttonStyle(.borderedProminent).tint(PokiTheme.blue)
                    }.padding(20).frame(width: 304)
                    Spacer(minLength: 0)
                }
            }
            ZStack {
                AmoreChatBackdrop(home: home)
                VStack(spacing: 20) {
                    HStack { Image(systemName: "line.3.horizontal"); Spacer(); Text("Amore").font(.headline); Spacer(); Image(systemName: "square.and.pencil") }
                        .padding(.top, 20)
                    if home { Spacer(); Image(systemName: "sparkles").font(.system(size: 50)).foregroundStyle(PokiTheme.blue); Text("Amore").font(.largeTitle.bold()) }
                    else {
                        HStack { Spacer(minLength: 60); Text("你好，帮我整理今天的任务。").padding(16).foregroundStyle(PokiTheme.outgoingText)
                            .background(PokiTheme.blue, in: PokiMessageBubbleShape(direction: .outgoing)) }
                        HStack { Text("好的，我会先查看任务，再给你清晰的安排。").padding(16)
                            .background { PokiAssistantMessageSurface() }; Spacer(minLength: 40) }
                    }
                    Spacer()
                    HStack(spacing: 16) {
                        Image(systemName: "plus").font(.title2)
                        Text("Message Amore").foregroundStyle(PokiTheme.homePlaceholder)
                        Spacer(minLength: 0)
                        Image(systemName: "mic").font(.title3)
                        Image(systemName: "waveform").padding(12).foregroundStyle(.white).background(PokiTheme.blue, in: Circle())
                    }.padding(8).modifier(PokiComposerMaterial())
                }.padding(.horizontal, 18).padding(.bottom, 10)
            }.offset(x: drawer ? 304 : 0)
        }.foregroundStyle(PokiTheme.primaryText)
    }
}
