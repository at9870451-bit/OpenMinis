import SwiftUI

/// Independent iOS 16-compatible outline. The outgoing bubble has its small
/// bottom corner on the right; the assistant's is on the left. Only the
/// 22/7 pt visual measurements are taken from the reference, not its code.
struct PokiMessageBubbleShape: InsettableShape {
    enum Direction: Equatable {
        case incoming
        case outgoing
    }

    var direction: Direction
    private var insetAmount: CGFloat = 0

    init(direction: Direction) {
        self.direction = direction
    }

    func inset(by amount: CGFloat) -> PokiMessageBubbleShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard bounds.width > 0, bounds.height > 0 else { return Path() }

        let radius = min(max(0, 22 - insetAmount), min(bounds.width, bounds.height) / 2)
        let tail = min(max(0, 7 - insetAmount), radius)
        let bottomLeft = direction == .incoming ? tail : radius
        let bottomRight = direction == .outgoing ? tail : radius
        let left = bounds.minX, right = bounds.maxX
        let top = bounds.minY, bottom = bounds.maxY
        // Cubic approximation of a quarter circle; no iOS 17-only shape API.
        let curve: CGFloat = 0.5522847498
        var path = Path()
        path.move(to: CGPoint(x: left + radius, y: top))
        path.addLine(to: CGPoint(x: right - radius, y: top))
        path.addCurve(to: CGPoint(x: right, y: top + radius),
                      control1: CGPoint(x: right - radius + radius * curve, y: top),
                      control2: CGPoint(x: right, y: top + radius - radius * curve))
        path.addLine(to: CGPoint(x: right, y: bottom - bottomRight))
        path.addCurve(to: CGPoint(x: right - bottomRight, y: bottom),
                      control1: CGPoint(x: right, y: bottom - bottomRight + bottomRight * curve),
                      control2: CGPoint(x: right - bottomRight + bottomRight * curve, y: bottom))
        path.addLine(to: CGPoint(x: left + bottomLeft, y: bottom))
        path.addCurve(to: CGPoint(x: left, y: bottom - bottomLeft),
                      control1: CGPoint(x: left + bottomLeft - bottomLeft * curve, y: bottom),
                      control2: CGPoint(x: left, y: bottom - bottomLeft + bottomLeft * curve))
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addCurve(to: CGPoint(x: left + radius, y: top),
                      control1: CGPoint(x: left, y: top + radius - radius * curve),
                      control2: CGPoint(x: left + radius - radius * curve, y: top))
        path.closeSubpath()
        return path
    }
}

/// Shared by live rows, context-menu previews and offscreen export hosts.
/// Keep the key beside the surface so isolated component hosts can compile it
/// without importing the entire chat row implementation.
private struct ChatSnapshotRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chatSnapshotRendering: Bool {
        get { self[ChatSnapshotRenderingKey.self] }
        set { self[ChatSnapshotRenderingKey.self] = newValue }
    }
}

/// Small, deterministic policy also usable by isolated component tests.
enum PokiAssistantMessageSurfacePolicy {
    static func usesOpaqueFill(reduceTransparency: Bool, snapshotRendering: Bool) -> Bool {
        reduceTransparency || snapshotRendering
    }
}

/// Paint only: no padding, frame, clipping or gesture on the hosted markdown.
/// Material/glass is clipped on this BACKGROUND only. Selection handles,
/// links, code attachments and TextKit's cell-sizing path stay untouched.
struct PokiAssistantMessageSurface: View {
    var isHighlighted = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chatSnapshotRendering) private var snapshotRendering

    private var shape: PokiMessageBubbleShape {
        PokiMessageBubbleShape(direction: .incoming)
    }

    var body: some View {
        paintedBackground
            .shadow(color: colorScheme == .light ? PokiTheme.bubbleShadow : .clear,
                    radius: 6, x: 0, y: 2)
            .overlay {
                shape.fill(ChatColors.accent.opacity(isHighlighted ? 0.10 : 0))
            }
            .overlay {
                shape.strokeBorder(PokiTheme.bubbleRing.opacity(0.5), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var paintedBackground: some View {
        if PokiAssistantMessageSurfacePolicy.usesOpaqueFill(
            reduceTransparency: reduceTransparency, snapshotRendering: snapshotRendering
        ) {
            // Accessibility needs a predictable contrast surface; offscreen
            // export has no live backdrop for material to sample. Both use the
            // original opaque, adaptive system-grouped assistant bubble colour.
            shape.fill(PokiTheme.assistantBubble)
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                // No interactive glass: the surface must never own gestures.
                Color.clear.glassEffect(.regular, in: shape).clipShape(shape)
            } else {
                materialBackground
            }
            #else
            materialBackground
            #endif
        }
    }

    private var materialBackground: some View {
        // A real system backdrop blur, not a translucent white/black fill.
        shape.fill(.regularMaterial).clipShape(shape)
    }
}
