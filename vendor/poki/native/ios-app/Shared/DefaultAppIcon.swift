import SwiftUI

/// Poki's existing icon where an app has no usable artwork.
struct DefaultAppIcon: View {
    var size: CGFloat
    var body: some View {
        Image("Bear").resizable().scaledToFill()
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}
