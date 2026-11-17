import SwiftUI
import UIKit

/// Poki's public fog-blue colour tables, rendered by Amore's own static
/// bilinear rasterizer. No Poki brand image, mesh animation code or dependency
/// is copied. Four small textures are generated once, never per message delta.
enum AmoreChatLight {
    static let columns = 4
    static let homeRows: [Double] = [0, 0.425, 0.575, 0.78, 1]
    static let chatRows: [Double] = [0, 0.755, 0.845, 0.935, 1]
    static let darkConversationStrength = 0.45
    static let homeLight: [UInt32] = [
        0xF5F7FA,0xF5F7FA,0xF5F7FA,0xF5F7FA,
        0xF5F7FA,0xF5F7FA,0xF5F7FA,0xF5F7FA,
        0xE4F0FC,0xEDF3FB,0xEAEEFB,0xF0F2FA,
        0xA6D6FA,0xB2D1FD,0xB6C4FB,0xC6CCF8,
        0x4AB2F7,0x3A8CFE,0x4878F6,0x6C80F0]
    static let homeDark: [UInt32] = [
        0x05070D,0x05070D,0x05070D,0x05070D,
        0x05070D,0x05070D,0x05070D,0x05070D,
        0x06101F,0x071226,0x08102A,0x070C1C,
        0x0B3C8A,0x0C4FC0,0x173FB0,0x14286E,
        0x1260D8,0x1A6FF0,0x2056E0,0x2440B8]
    static let chatLight: [UInt32] = [
        0xF5F8FC,0xF5F8FC,0xF5F8FC,0xF5F8FC,
        0xF5F8FC,0xF5F8FC,0xF5F8FC,0xF5F8FC,
        0xE8F3FC,0xE7F0FC,0xE8EEFC,0xEBEFFB,
        0xDFEFFB,0xDDEAFC,0xDFE8FB,0xE4E9FA,
        0xDBEEFB,0xD9E8FC,0xDBE5FB,0xE0E6FA]
    static let chatDark: [UInt32] = [
        0x05070D,0x05070D,0x05070D,0x05070D,
        0x05070D,0x05070D,0x05070D,0x05070D,
        0x060E1C,0x070F1E,0x070D1D,0x070B1A,
        0x071227,0x08142A,0x081128,0x090E23,
        0x07142B,0x08172F,0x09132D,0x0A1027]

    @MainActor private static let homeDay = raster(homeLight, rows: homeRows)
    @MainActor private static let homeNight = raster(homeDark, rows: homeRows)
    @MainActor private static let chatDay = raster(chatLight, rows: chatRows)
    @MainActor private static let chatNight = raster(chatDark, rows: chatRows)

    @MainActor static func texture(home: Bool, dark: Bool) -> UIImage? {
        home ? (dark ? homeNight : homeDay) : (dark ? chatNight : chatDay)
    }

    /// A small, opaque backdrop: content and text remain native at full scale.
    @MainActor private static func raster(_ colors: [UInt32], rows: [Double]) -> UIImage? {
        let width = 128, height = 256
        guard colors.count == rows.count * columns else { return nil }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let fy = Double(y) / Double(height - 1)
            let lower = max(0, min(rows.count - 2, (rows.lastIndex(where: { $0 <= fy }) ?? 0)))
            let vy = (fy - rows[lower]) / max(0.0001, rows[lower + 1] - rows[lower])
            let blendY = min(1, max(0, vy))
            let smoothY = blendY * blendY * (3 - 2 * blendY)
            for x in 0..<width {
                let fx = Double(x) / Double(width - 1) * Double(columns - 1)
                let left = min(columns - 2, Int(fx))
                let bx = fx - Double(left)
                for channel in 0..<3 {
                    let shift = UInt32((2 - channel) * 8)
                    func component(_ row: Int, _ col: Int) -> Double {
                        Double((colors[row * columns + col] >> shift) & 255)
                    }
                    let top = component(lower, left) * (1 - bx) + component(lower, left + 1) * bx
                    let bottom = component(lower + 1, left) * (1 - bx) + component(lower + 1, left + 1) * bx
                    bytes[(y * width + x) * 4 + channel] = UInt8((top * (1 - smoothY) + bottom * smoothY).rounded())
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Native mesh on iOS18+, cached static texture on iOS16/17. Keeping the
/// backdrop independent from the message list avoids frame-by-frame text work.
@MainActor
struct AmoreChatBackdrop: View {
    let home: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            layers
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var layers: some View {
        ZStack(alignment: .bottom) {
            PokiTheme.background
            layer(home: false)
            layer(home: true)
                .overlay(alignment: .bottom) {
                    Ellipse()
                        .fill(RadialGradient(colors: [edge.opacity(0.45), edge.opacity(0.12), .clear],
                            center: .center, startRadius: 0, endRadius: 310))
                        .frame(width: 796, height: 79)
                        .offset(y: 39)
                }
                .opacity(home ? 1 : scheme == .dark ? AmoreChatLight.darkConversationStrength : 0)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: home)
    }

    private var edge: Color { scheme == .dark ? Color(red: 0.624, green: 0.816, blue: 1) : .white }

    @ViewBuilder private func layer(home: Bool) -> some View {
        if #available(iOS 18.0, *) {
            AmoreFogMesh(home: home, dark: scheme == .dark)
        } else if let image = AmoreChatLight.texture(home: home, dark: scheme == .dark) {
            Image(uiImage: image).resizable().interpolation(.high)
        }
    }
}

/// Public colour/position design values, independently rendered by native
/// SwiftUI. Deliberately static: no copied animation code or hidden timer.
@available(iOS 18.0, *)
private struct AmoreFogMesh: View {
    let home: Bool
    let dark: Bool
    var body: some View {
        let rgb = home ? (dark ? AmoreChatLight.homeDark : AmoreChatLight.homeLight)
                       : (dark ? AmoreChatLight.chatDark : AmoreChatLight.chatLight)
        MeshGradient(width: 4, height: 5, points: points,
            colors: rgb.map { n in
                Color(red: Double((n >> 16) & 255) / 255,
                      green: Double((n >> 8) & 255) / 255,
                      blue: Double(n & 255) / 255)
            }, smoothsColors: true, colorSpace: .perceptual)
    }
    private var points: [SIMD2<Float>] {
        let x: [[Float]] = [[0,0.34,0.67,1],[0,0.34,0.67,1],[0,0.32,0.70,1],
                            [0,0.36,0.67,1],[0,0.34,0.67,1]]
        let y: [[Float]] = home
            ? [[0,0,0,0],[0.42,0.44,0.41,0.43],[0.56,0.60,0.55,0.59],
               [0.76,0.80,0.75,0.81],[1,1,1,1]]
            : [[0,0,0,0],[0.75,0.76,0.75,0.76],[0.84,0.86,0.83,0.85],
               [0.93,0.94,0.92,0.94],[1,1,1,1]]
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(20)
        for row in 0..<5 {
            let shifted = home && dark && (row == 2 || row == 3)
            let drop: Float = shifted ? 0.02 : 0
            for col in 0..<4 {
                let px: Float = x[row][col]
                let py: Float = y[row][col] + drop
                result.append(SIMD2<Float>(px, py))
            }
        }
        return result
    }
}
