import SwiftUI
import AmoreDeviceKit

/// Only phone shortcuts represent third-party apps. A page/prompt's appName
/// (including "Amore") must not be mistaken for an installed app.
@MainActor
struct AmoreShortcutAppIcon: View {
    let item: AmoreHomeShortcut
    let size: CGFloat

    var body: some View {
        if #available(iOS 18.0, *), item.id.hasPrefix("phone-"),
           AmoreCapsuleApps.bundleID(for: item.appName) != nil {
            AmoreInstalledAppIcon(app: item.appName, size: size)
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: size * 0.68, weight: .medium))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
