import SwiftUI

/// The marquee may instantiate dozens of copies of one phone shortcut at launch.
/// Its first frame must NEVER synchronously call private UIKit icon APIs,
/// PNG encode, load cache files or start one App Store request per duplicate.
/// These are the original Poki App Store artworks carried with Amore 1.40.
/// Other apps get a neutral placeholder until the user explicitly starts a task.
@MainActor
struct AmoreFastAppIcon: View {
    let appName: String
    let size: CGFloat

    private var carriedName: String? {
        switch appName.lowercased() {
        case "meituan", "美团", "com.meituan.imeituan": return "AmoreCarried-meituan"
        case "meituan waimai", "美团外卖", "com.meituan.itakeaway": return "AmoreCarried-meituan-waimai"
        case "xianyu", "闲鱼", "com.taobao.fleamarket": return "AmoreCarried-xianyu"
        default: return nil
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225)
        Group {
            if let carriedName {
                Image(carriedName).resizable().scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .resizable().scaledToFit().padding(size * 0.2)
                    .foregroundStyle(.secondary)
                    .background(Color(.tertiarySystemFill))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
