// Carried over from Jacob Mobin's AppleIntelligenceGlowEffect, IOS.swift and IOS_LowPowerMode.swift
// (https://github.com/jacobamobin/AppleIntelligenceGlowEffect/tree/5f388f1c51322f62f2181693e125d955d9a45237).
//
// MIT License
//
// Copyright (c) 2025 Jacob Mobin
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// Changed for Poki:
// - the colours are Poki's brand band (`BrandBand.glow`) instead of the six of Apple Intelligence;
// - only the lower part of the screen's edge shows (a mask), since the talk's light is at the bottom;
// - the lines are `spread` times as wide and as soft, and the whole light takes a `strength`, both set
//   by what the talk is doing;
// - the frame is the view's own (a GeometryReader) instead of `UIScreen.main.bounds`, so it fits a
//   column on iPad, and the padding that lined the original up with the status bar is gone;
// - Low Power Mode draws the original's low-power variant, and Reduce Motion holds the colours still.

import Combine
import SwiftUI

/// The light along the bottom edge of the screen while you talk with Poki, in Poki's blues.
struct TalkEdgeGlow: View {
    /// How much of the light shows, 0 to 1.
    var strength: Double
    /// How wide and soft the lines are, against the original's.
    var spread: CGFloat = 1.7

    @State private var gradientStops: [Gradient.Stop] = TalkEdgeGlow.generateGradientStops()
    @State private var timer: AnyCancellable?
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { geometry in
            let corner: CGFloat = sizeClass == .regular ? 18 : 55
            ZStack {
                if lowPower {
                    EffectNoBlur(gradientStops: gradientStops, width: 6 * spread, corner: corner, size: geometry.size)
                    Effect(gradientStops: gradientStops, width: 10 * spread, blur: 6 * spread, corner: corner, size: geometry.size)
                } else {
                    EffectNoBlur(gradientStops: gradientStops, width: 6 * spread, corner: corner, size: geometry.size)
                    Effect(gradientStops: gradientStops, width: 9 * spread, blur: 4 * spread, corner: corner, size: geometry.size)
                    Effect(gradientStops: gradientStops, width: 11 * spread, blur: 12 * spread, corner: corner, size: geometry.size)
                    Effect(gradientStops: gradientStops, width: 15 * spread, blur: 15 * spread, corner: corner, size: geometry.size)
                }
            }
            .drawingGroup() // Composite layers into a single render pass
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0.72), .init(color: .white, location: 0.96)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .opacity(strength)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            // Use a single timer for all layers to avoid redundant updates
            timer = Timer.publish(every: lowPower ? 1.0 : 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { _ in
                    withAnimation(.easeInOut(duration: lowPower ? 1.5 : 1.0)) {
                        gradientStops = TalkEdgeGlow.generateGradientStops()
                    }
                }
        }
        .onDisappear {
            // Cancel timer to prevent memory leaks
            timer?.cancel()
            timer = nil
        }
    }

    // Function to generate random gradient stops
    static func generateGradientStops() -> [Gradient.Stop] {
        BrandBand.glow.map { Gradient.Stop(color: $0, location: Double.random(in: 0...1)) }
            .sorted { $0.location < $1.location }
    }
}

private struct Effect: View {
    var gradientStops: [Gradient.Stop]
    var width: CGFloat
    var blur: CGFloat
    var corner: CGFloat
    var size: CGSize

    var body: some View {
        RoundedRectangle(cornerRadius: corner)
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(stops: gradientStops),
                    center: .center
                ),
                lineWidth: width
            )
            .frame(width: size.width, height: size.height)
            .blur(radius: blur)
            .compositingGroup() // Optimize blur rendering
    }
}

private struct EffectNoBlur: View {
    var gradientStops: [Gradient.Stop]
    var width: CGFloat
    var corner: CGFloat
    var size: CGSize

    var body: some View {
        RoundedRectangle(cornerRadius: corner)
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(stops: gradientStops),
                    center: .center
                ),
                lineWidth: width
            )
            .frame(width: size.width, height: size.height)
    }
}

extension BrandBand {
    /// The band's blues with its two lightest once more, as the six colours the edge light moves between.
    static var glow: [Color] { colours + [Color(hex: 0x4AB2F7), Color(hex: 0xA9D8FF)] }
}
