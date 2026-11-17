import SwiftUI
import UIKit

@MainActor
struct AmoreHomeActionRouter {
    let setInput: (String) -> Void
    let openPage: (String) -> Void

    func perform(_ action: AmoreHomeShortcut.Action) {
        switch action.kind {
        case .prompt:
            setInput(action.value)
        case .link:
            guard let url = URL(string: action.value), url.scheme == "https" else { return }
            UIApplication.shared.open(url)
        case .page:
            openPage(action.value)
        }
    }
}
