// Adapted from Element X iOS (https://github.com/element-hq/element-x-ios/tree/21758530da454c65969c6ef159b9ca47b9394a7a,
// ElementX/Sources/Other/Pills/PillTextAttachment.swift).
// Copyright 2025 Element Creations Ltd. Copyright 2023-2025 New Vector Ltd.
// SPDX-License-Identifier: AGPL-3.0-only. See THIRD_PARTY_NOTICES.md.
// Poki's changes: the pill is drawn into the attachment's image (PillView through ImageRenderer)
// instead of a hosted view, because Element's PillAttachmentViewProvider never received a view on
// the iOS 27 simulator; the attachment sizes itself from the pill's metrics.

import SwiftUI
import UIKit

/// Text attachment for pills display. It is one character in the text, so one backspace removes it.
final class PillTextAttachment: NSTextAttachment {
    let pillData: PillTextAttachmentData

    /// `traits` decide the colours (light or dark) and the scale the pill is drawn at.
    @MainActor
    init(pillData: PillTextAttachmentData, traits: UITraitCollection) {
        self.pillData = pillData
        super.init(data: nil, ofType: nil)
        image = PillView.image(pillData, scale: traits.displayScale, dark: traits.userInterfaceStyle == .dark)
        bounds = pillRect(maxWidth: .greatestFiniteMagnitude)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        pillRect(maxWidth: proposedLineFragment.width)
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        pillRect(maxWidth: lineFrag.width)
    }

    private func pillRect(maxWidth: CGFloat) -> CGRect {
        let size = PillMetrics(pointSize: pillData.fontData.pointSize).size(for: pillData.label)
        var rect = CGRect(origin: .zero, size: size)
        rect.origin.y = pillData.baselineOffset
        rect.size.width = min(rect.size.width, maxWidth)
        return rect
    }
}
