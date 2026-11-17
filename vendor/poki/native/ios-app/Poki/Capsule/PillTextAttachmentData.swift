// Adapted from Element X iOS (https://github.com/element-hq/element-x-ios/tree/21758530da454c65969c6ef159b9ca47b9394a7a,
// ElementX/Sources/Other/Pills/PillTextAttachmentData.swift).
// Copyright 2025 Element Creations Ltd. Copyright 2023-2025 New Vector Ltd.
// SPDX-License-Identifier: AGPL-3.0-only. See THIRD_PARTY_NOTICES.md.
// Poki's changes: a pill stands for an app and keeps the exact words typed for it, instead of a
// Matrix user or room; it is never encoded, so it is not Codable.

import UIKit

/// What a capsule stands for: the app, and the words that were typed for it, which is what the plain
/// text gets back when the capsule is read out.
struct PillTextAttachmentData: Equatable {
    struct Font: Equatable {
        let descender: CGFloat
        let lineHeight: CGFloat
        let pointSize: CGFloat
    }

    let app: AppCapsule
    /// The words as written, which the plain text gets back.
    let text: String
    /// The name as the capsule shows it ("Uber" for a typed "uber").
    var label: String { app.label(for: text) }

    /// How far below the baseline the pill starts, so it sits centred on the surrounding text.
    var baselineOffset: CGFloat {
        fontData.descender + (fontData.lineHeight - PillMetrics(pointSize: fontData.pointSize).height) / 2
    }
    /// The font of the text around the pill, which the pill is centred on and scaled to.
    let fontData: Font
    /// In your blue bubble rather than the message field.
    var onAccent = false
}

extension PillTextAttachmentData {
    init(app: AppCapsule, text: String, font: UIFont, onAccent: Bool = false) {
        self.app = app
        self.text = text
        fontData = Font(descender: font.descender, lineHeight: font.lineHeight, pointSize: font.pointSize)
        self.onAccent = onAccent
    }
}
