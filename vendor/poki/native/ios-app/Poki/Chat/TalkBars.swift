/*
 * Copyright 2025 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Carried over from LiveKit's components-swift, BarAudioVisualizer.swift
// (https://github.com/livekit/components-swift/blob/9f28db3ae5d2b51f3033ea725c952ddacb5657d0/Sources/LiveKitComponents/UI/Visualizer/BarAudioVisualizer.swift).
// Changed for Poki, which does not link the LiveKit SDK and has no audio levels to read:
// - `AgentState` is `TalkBars.Mode`, with `quiet` added (no bar lit) for a talk that was interrupted;
// - the bars' heights come from `TalkBars.levels` instead of LiveKit's `AudioProcessor`: made-up
//   levels, highest in the middle, while somebody speaks, and none otherwise;
// - with Reduce Motion nothing moves: the bars for the mode stand still.

import SwiftUI

/// A talk's state as a row of vertical bars: a sweep while it connects, the middle bar pulsing while
/// Poki listens, a quick sweep while it thinks, and all bars moving while somebody speaks.
struct TalkBars: View {
    enum Mode: Equatable { case initializing, listening, thinking, speaking, quiet }

    var mode: Mode
    var barColor: Color = .primary
    var barCount = 5
    var barSpacingFactor: CGFloat = 0.015
    var barMinOpacity = 0.16
    /// How high the bars go while somebody speaks, 0 to 1.
    var loudness = 1.0

    @State private var bands: [Double] = []
    @State private var animationPhase = 0
    @State private var animationTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animationProperties: PhaseAnimationProperties { PhaseAnimationProperties(barCount: barCount) }

    var body: some View {
        GeometryReader { geometry in
            let highlightingSequence = animationProperties.highlightingSequence(mode: mode)
            let highlighted = highlightingSequence[animationPhase % highlightingSequence.count]

            bars(geometry: geometry, highlighted: highlighted)
                .onAppear { startAnimation(mode) }
                .onDisappear { stopAnimation() }
                .onChange(of: mode) { _, newMode in startAnimation(newMode) }
                .onChange(of: loudness) { startAnimation(mode) }
                .animation(.easeInOut, value: animationPhase)
                .animation(.easeInOut(duration: 0.3), value: mode)
                .animation(.easeInOut(duration: Self.levelStep), value: bands)
        }
    }

    @ViewBuilder
    private func bars(geometry: GeometryProxy, highlighted: PhaseAnimationProperties.HighlightedBars) -> some View {
        let totalSpacing = geometry.size.width * barSpacingFactor * CGFloat(barCount + 1)
        let availableWidth = geometry.size.width - totalSpacing
        let barWidth = availableWidth / CGFloat(barCount)
        let barMinHeight = barWidth // Use bar width as minimum height for square proportions

        HStack(alignment: .center, spacing: geometry.size.width * barSpacingFactor) {
            ForEach(0 ..< barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barMinHeight)
                    .fill(barColor)
                    .opacity(highlighted.contains(index) ? 1 : barMinOpacity)
                    .frame(
                        width: barWidth,
                        height: (geometry.size.height - barMinHeight) * CGFloat(index < bands.count ? bands[index] : 0) + barMinHeight,
                        alignment: .center
                    )
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(width: geometry.size.width)
    }

    private func startAnimation(_ mode: Mode) {
        animationTask?.cancel()
        animationPhase = 0
        bands = mode == .speaking && reduceMotion ? Self.levels(barCount, loudness: loudness, at: 0.5) : []
        guard !reduceMotion else { return }
        let duration = animationProperties.duration(mode: mode)
        animationTask = Task {
            while !Task.isCancelled {
                if mode == .speaking {
                    bands = Self.levels(barCount, loudness: loudness, at: .random(in: 0.25...1))
                    try? await Task.sleep(for: .seconds(Self.levelStep))
                } else {
                    try? await Task.sleep(for: .seconds(duration))
                    animationPhase += 1
                }
            }
        }
    }

    private func stopAnimation() {
        animationTask?.cancel()
    }

    /// How often the made-up levels change while somebody speaks.
    private static let levelStep = 0.14

    /// Levels for one moment of speech: `peak` in the middle, less toward the ends, each bar a little off.
    static func levels(_ count: Int, loudness: Double, at peak: Double) -> [Double] {
        let middle = Double(count - 1) / 2
        return (0 ..< count).map { index in
            let fromMiddle = middle == 0 ? 0 : abs(Double(index) - middle) / middle
            let level = peak * (1 - 0.55 * fromMiddle) * .random(in: 0.6...1)
            return min(max(level * loudness, 0), 1)
        }
    }
}

extension TalkBars {
    private struct PhaseAnimationProperties {
        typealias HighlightedBars = Set<Int>

        private let barCount: Int
        private let veryLongDuration: TimeInterval = 1000

        init(barCount: Int) {
            self.barCount = barCount
        }

        func duration(mode: Mode) -> TimeInterval {
            switch mode {
            case .initializing: 2 / Double(barCount)
            case .listening: 0.5
            case .thinking: 0.15
            case .speaking, .quiet: veryLongDuration
            }
        }

        func highlightingSequence(mode: Mode) -> [HighlightedBars] {
            switch mode {
            case .initializing: (0 ..< barCount).map { HighlightedBars([$0, barCount - 1 - $0]) }
            case .listening: barCount % 2 == 0 ? [[(barCount / 2) - 1, barCount / 2], []] : [[barCount / 2], []]
            case .thinking: Array((0 ..< barCount) + (0 ..< barCount).reversed()).map { HighlightedBars([$0]) }
            case .speaking: [HighlightedBars(0 ..< barCount)]
            case .quiet: [[]]
            }
        }
    }
}
