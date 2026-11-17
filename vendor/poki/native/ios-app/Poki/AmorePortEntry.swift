import SwiftUI
import PokiCore
import UIKit

private final class PortResourceMarker {}
enum PokiPortResources {
    static let bundle = Bundle.main
}

/// One retained upstream AppModel/ChatModel pair. Opening Connection or Chat
/// never rebuilds an active task. The host owns presentation, not business state.
@MainActor
final class AmorePokiRuntime {
    static let shared = AmorePokiRuntime()
    let model: AppModel
    let chat: ChatModel
    private init() {
        signal(SIGPIPE, SIG_IGN)
        AppLocalization.publish()
        model = AppModel()
        chat = ChatModel(app: model)
        AskPoki.install(app: model, chat: chat)
    }
}

@MainActor
struct AmoreOriginalPokiPage: View {
    let connection: Bool
    let runtime = AmorePokiRuntime.shared
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Group {
            if connection {
                NavigationStack {
                    ConnectionView()
                        .navigationDestination(for: SetupStep.self) { step in SetupStepPage(step: step) }
                        .settingsPage()
                }
            } else {
                RootView()
            }
        }
        .environment(runtime.model)
        .environment(runtime.chat)
        .environment(\.locale, AppLocalization.locale)
        .task {
            if connection {
                runtime.model.loopback.resume()
                runtime.model.diskImage.notice()
            }
        }
        .onChange(of: phase) { _, value in
            guard connection else { return }
            if value == .active { runtime.model.becameActive() }
            else if value == .background { runtime.model.wentToBackground() }
        }
    }
}

/// Objective-C boundary lets the iOS16 host load the original iOS18 module only
/// when its user explicitly opens it. Never a dummy controller or fake state.
@objc(AmorePokiEntry)
public final class AmorePokiEntry: NSObject {
    @MainActor @objc public class func pause() {
        AmorePokiRuntime.shared.chat.stop()
        AmorePokiRuntime.shared.model.pauseByOwner()
    }

    @MainActor @objc public class func viewController(_ page: String) -> UIViewController {
        UIHostingController(rootView: AmoreOriginalPokiPage(connection: page == "connection"))
    }
}
