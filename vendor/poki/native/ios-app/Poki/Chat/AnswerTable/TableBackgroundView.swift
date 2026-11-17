// From gonzalezreal/swift-markdown-ui (commit 8371aeb, Sources/MarkdownUI/Views/Blocks/TableBackgroundView.swift),
// Copyright (c) 2020 Guillermo Gonzalez, MIT License. See THIRD_PARTY_NOTICES.md. Unchanged.
import SwiftUI

struct TableBackgroundView: View {
  @Environment(\.tableBackgroundStyle) private var tableBackgroundStyle

  private let tableBounds: TableBounds

  init(tableBounds: TableBounds) {
    self.tableBounds = tableBounds
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(0..<self.tableBounds.rowCount, id: \.self) { row in
        ForEach(0..<self.tableBounds.columnCount, id: \.self) { column in
          let bounds = self.tableBounds.bounds(forRow: row, column: column)

          Rectangle()
            .fill(self.tableBackgroundStyle.background(row, column))
            .offset(x: bounds.minX, y: bounds.minY)
            .frame(width: bounds.width, height: bounds.height)
        }
      }
    }
  }
}
