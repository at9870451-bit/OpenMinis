import SwiftUI
import UIKit
import ObjectiveC

/// The original Poki module is built separately at its real iOS18 minimum.
/// Loading is user initiated and failures remain visible, never a dummy success.
struct OriginalPokiScreen: UIViewControllerRepresentable {
    enum Page: String { case chat, connection }

    static var isAvailable: Bool {
        guard #available(iOS 18.0, *),
              let frameworks = Bundle.main.privateFrameworksURL else { return false }
        return frameworks.appendingPathComponent("Poki.framework").isFileURL
            && FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("Poki.framework/Poki").path)
    }
    let page: Page

    func makeUIViewController(context: Context) -> UIViewController {
        guard #available(iOS 18.0, *) else {
            return Self.failure(AppLocalized("The original Poki pages require iOS 18 or later. Your existing Amore chats remain available."))
        }
        guard let frameworks = Bundle.main.privateFrameworksURL else {
            return Self.failure(AppLocalized("The original page framework is missing from this build."))
        }
        let url = frameworks.appendingPathComponent("Poki.framework")
        guard let framework = Bundle(url: url) else {
            return Self.failure(AppLocalized("The original page framework is missing from this build."))
        }
        do { try framework.loadAndReturnError() }
        catch { return Self.failure(error.localizedDescription) }
        guard let factory = NSClassFromString("AmorePokiEntry"),
              let method = class_getClassMethod(factory, NSSelectorFromString("viewController:")) else {
            return Self.failure(AppLocalized("The original page entry could not be loaded."))
        }
        typealias Factory = @convention(c) (AnyClass, Selector, NSString) -> Unmanaged<UIViewController>
        let call = unsafeBitCast(method_getImplementation(method), to: Factory.self)
        return call(factory, NSSelectorFromString("viewController:"), page.rawValue as NSString).takeUnretainedValue()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    private static func failure(_ message: String) -> UIViewController {
        UIHostingController(rootView: OriginalPokiLoadFailure(message: message))
    }
}

private struct OriginalPokiLoadFailure: View {
    let message: String
    @AppStorage("amore.originalPokiChat") private var enabled = true
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(AppLocalized("Unable to open original page")).font(.headline)
            Text(message).font(.callout).multilineTextAlignment(.center)
            if enabled {
                Button(AppLocalized("Return to Amore chats")) { enabled = false }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24)
    }
}
}

/// Host-only switch between the preserved Amore engine and original source UI.
/// A separate model/database avoids rewriting old Amore conversation records.
struct OriginalPokiChatEntry: View {
    @AppStorage("amore.originalPokiChat") private var enabled = true
    var body: some View {
        ZStack(alignment: .topTrailing) {
            OriginalPokiScreen(page: .chat)
            Button(AppLocalized("Return to Amore chats")) { enabled = false }
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 6).padding(.trailing, 12)
                .accessibilityIdentifier("originalPoki.returnToAmore")
        }
    }
}
