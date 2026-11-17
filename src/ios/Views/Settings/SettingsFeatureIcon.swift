import SwiftUI

struct SettingsFeatureIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
