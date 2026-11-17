// From gonzalezreal/swift-markdown-ui (commit 8371aeb, Sources/MarkdownUI/Views/Blocks/TableCell.swift),
// Copyright (c) 2020 Guillermo Gonzalez, MIT License. See THIRD_PARTY_NOTICES.md. Changed: the GitHub
// theme's table cell style (Sources/MarkdownUI/Theme/Theme+GitHub.swift: a semibold header row, 6 by 13
// points of padding) is applied here instead of through a theme, the label is the cell's styled text,
// and a long cell wraps at a width that grows with the text size instead of stretching its column.
import SwiftUI

struct TableCell: View {
  @ScaledMetric(relativeTo: .subheadline) private var maxWidth: CGFloat = 220

  private let row: Int
  private let column: Int
  private let cell: RawTableCell

  init(row: Int, column: Int, cell: RawTableCell) {
    self.row = row
    self.column = column
    self.cell = cell
  }

  var body: some View {
    WidthLimit(maxWidth: self.maxWidth).callAsFunction { self.label }
      .fontWeight(self.row == 0 ? .semibold : nil)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, 6)
      .padding(.horizontal, 13)
      .tableCellBounds(forRow: self.row, column: self.column)
  }

  private var label: some View {
    Text(self.cell.content)
  }
}

/// Its content at its ideal width up to `maxWidth`, and wrapped at `maxWidth` beyond it, also where the
/// table scrolls sideways and so proposes no width at all.
private struct WidthLimit: Layout {
  var maxWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    let limit = min(proposal.width ?? .infinity, self.maxWidth)
    let ideal = content.sizeThatFits(.unspecified)
    return ideal.width <= limit ? ideal : content.sizeThatFits(.init(width: limit, height: nil))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: .init(width: bounds.width, height: nil))
  }
}
