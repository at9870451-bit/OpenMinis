import SwiftUI
import UIKit

/// Updating the locale must also release the launch-time Geist navigation font for languages whose
/// glyphs it does not contain. Touch only typography in this window; keep its controllers and routes.
struct LanguageNavigationFonts: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }

    func updateUIView(_ view: UIView, context: Context) {
        let systemLarge = UIFont.preferredFont(forTextStyle: .largeTitle)
        let bold = systemLarge.fontDescriptor.withSymbolicTraits(.traitBold) ?? systemLarge.fontDescriptor
        let large = Prominent.uiFont(.largeTitle, .bold) ?? UIFont(descriptor: bold, size: systemLarge.pointSize)
        let inline = Prominent.uiFont(.headline, .semibold) ?? UIFont.preferredFont(forTextStyle: .headline)
        func apply(_ bar: UINavigationBar) {
            var largeAttributes = bar.largeTitleTextAttributes ?? [:]
            var inlineAttributes = bar.titleTextAttributes ?? [:]
            largeAttributes[.font] = large
            inlineAttributes[.font] = inline
            bar.largeTitleTextAttributes = largeAttributes
            bar.titleTextAttributes = inlineAttributes
        }
        apply(UINavigationBar.appearance())
        DispatchQueue.main.async { [weak view] in
            func visit(_ controller: UIViewController) {
                if let navigation = controller as? UINavigationController { apply(navigation.navigationBar) }
                controller.children.forEach(visit)
                if let presented = controller.presentedViewController { visit(presented) }
            }
            if let root = view?.window?.rootViewController { visit(root) }
        }
    }
}
