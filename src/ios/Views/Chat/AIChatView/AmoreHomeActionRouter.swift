import SwiftUI
import UIKit

@MainActor
struct AmoreHomeActionRouter {
    let setInput: (String) -> Void
    let openPage: (String) -> Void
    var openLink: (URL) -> Void = { UIApplication.shared.open($0) }

    func perform(_ action: AmoreHomeShortcut.Action) {
        guard AmoreShortcutRanking.validAction(action) else { return }
        switch action.kind {
        case .prompt:
            setInput(action.value)
        case .link:
            guard let url = URL(string: action.value) else { return }
            openLink(url)
        case .page:
            openPage(AmoreShortcutRoutes.canonicalPage(action.value))
        }
    }
}
