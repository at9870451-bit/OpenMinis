import SwiftUI

/// Only phone shortcuts represent third-party apps. A page/prompt's appName
/// (including "Amore") must not be mistaken for an installed app.
@MainActor
struct AmoreShortcutAppIcon: View {
    let item: AmoreHomeShortcut
    let size: CGFloat

    var body: some View {
        if item.id.hasPrefix("phone-") {
            // No KnownApps scan or synchronous system icon lookup during a
            // marquee's many first-frame clones. App identity remains a label.
            AmoreFastAppIcon(appName: item.appName, size: size)
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: size * 0.68, weight: .medium))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
