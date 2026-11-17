// From gonzalezreal/swift-markdown-ui (commit 8371aeb, Sources/MarkdownUI/Views/Blocks/TableView.swift,
// with RawTableColumnAlignment, RawTableRow and RawTableCell from Sources/MarkdownUI/Parser/BlockNode.swift),
// Copyright (c) 2020 Guillermo Gonzalez, MIT License. See THIRD_PARTY_NOTICES.md. Changed: the table is
// drawn directly instead of through a theme's table style, and a cell holds the answer's styled text
// instead of the library's inline nodes.
import SwiftUI

enum RawTableColumnAlignment: Character {
  case none = "\0"
  case left = "l"
  case center = "c"
  case right = "r"
}

struct RawTableRow: Hashable {
  let cells: [RawTableCell]
}

struct RawTableCell: Hashable {
  let content: AttributedString
}

struct TableView: View {
  @Environment(\.tableBorderStyle.strokeStyle.lineWidth) private var borderWidth

  private let columnAlignments: [RawTableColumnAlignment]
  private let rows: [RawTableRow]

  init(columnAlignments: [RawTableColumnAlignment], rows: [RawTableRow]) {
    self.columnAlignments = columnAlignments
    self.rows = rows
  }

  var body: some View {
    self.label
  }

  private var label: some View {
    Grid(horizontalSpacing: self.borderWidth, verticalSpacing: self.borderWidth) {
      ForEach(0..<self.rowCount, id: \.self) { row in
        GridRow {
          ForEach(0..<self.columnCount, id: \.self) { column in
            TableCell(row: row, column: column, cell: self.rows[row].cells[column])
              .gridColumnAlignment(.init(self.columnAlignments[column]))
          }
        }
      }
    }
    .padding(self.borderWidth)
    .tableDecoration(
      rowCount: self.rowCount,
      columnCount: self.columnCount,
      background: TableBackgroundView.init,
      overlay: TableBorderView.init
    )
  }

  private var rowCount: Int {
    self.rows.count
  }

  private var columnCount: Int {
    self.columnAlignments.count
  }
}

extension HorizontalAlignment {
  fileprivate init(_ rawTableColumnAlignment: RawTableColumnAlignment) {
    switch rawTableColumnAlignment {
    case .none, .left:
      self = .leading
    case .center:
      self = .center
    case .right:
      self = .trailing
    }
  }
}
