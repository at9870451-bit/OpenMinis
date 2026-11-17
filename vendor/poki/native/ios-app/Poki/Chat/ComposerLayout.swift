import SwiftUI

/// Keeps the same editor alive and the controls on the bottom edge while the field expands above them.
struct ComposerLayout: Layout {
    var expansion: CGFloat
    var spacing: CGFloat = 8

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let sizes = measure(width: width, subviews: subviews)
        return CGSize(width: width, height: sizes.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measure(width: bounds.width, subviews: subviews)
        let bottom = bounds.maxY
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bottom), anchor: .bottomLeading,
                          proposal: ProposedViewSize(sizes.leading))
        subviews[1].place(at: CGPoint(x: bounds.minX + sizes.fieldInset, y: bottom - sizes.fieldRise),
                          anchor: .bottomLeading, proposal: ProposedViewSize(sizes.field))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bottom), anchor: .bottomTrailing,
                          proposal: ProposedViewSize(sizes.trailing))
    }

    private func measure(width: CGFloat, subviews: Subviews)
        -> (leading: CGSize, field: CGSize, trailing: CGSize, fieldInset: CGFloat, fieldRise: CGFloat, height: CGFloat) {
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        let inlineWidth = width - leading.width - trailing.width - 2 * spacing
        let progress = inlineWidth < 140 ? 1 : min(1, max(0, expansion))
        let fieldWidth = inlineWidth + (width - inlineWidth) * progress
        let field = subviews[1].sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil))
        let controlsHeight = max(leading.height, trailing.height)
        let inlineRise = max(0, (controlsHeight - field.height) / 2)
        let fieldRise = inlineRise + (controlsHeight + spacing - inlineRise) * progress
        return (leading, field, trailing, (leading.width + spacing) * (1 - progress), fieldRise,
                max(controlsHeight, field.height + fieldRise))
    }
}
