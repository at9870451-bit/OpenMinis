// Adapted from Element X iOS (https://github.com/element-hq/element-x-ios/tree/21758530da454c65969c6ef159b9ca47b9394a7a,
// ElementX/Sources/Other/Pills/PillView.swift).
// Copyright 2025 Element Creations Ltd. Copyright 2023-2025 New Vector Ltd.
// SPDX-License-Identifier: AGPL-3.0-only. See THIRD_PARTY_NOTICES.md.
// Poki's changes: the app's icon in front of its name, as the home page's pills show an app (the
// owner, 2026-11-13), on a faint ground of the text's own colour, sized from the surrounding font; no
// Compound colours, status emoji or loading context.

import SwiftUI
import UIKit

/// Sizes shared by the attachment, which reserves the room, and the view, which draws in it.
struct PillMetrics {
    let pointSize: CGFloat

    var height: CGFloat { (pointSize * 1.5).rounded() }
    var icon: CGFloat { height - 6 }
    var labelFont: UIFont { .systemFont(ofSize: (pointSize * 0.88).rounded(), weight: .semibold) }
    var leading: CGFloat { 3 }
    var gap: CGFloat { 5 }
    var trailing: CGFloat { 8 }

    func size(for text: String) -> CGSize {
        let label = (text as NSString).size(withAttributes: [.font: labelFont]).width.rounded(.up)
        return CGSize(width: leading + icon + gap + label + trailing, height: height)
    }
}

/// An app's capsule: its icon in the Home Screen's shape and its name in the semibold of the home
/// page's pills. The icon is the one on this iPhone, else the one Poki carries, always in its light
/// look. In the message field it sits on a faint ground of the text's colour; in your blue bubble,
/// on a faint white one with a white name.
struct PillView: View {
    let data: PillTextAttachmentData

    private var metrics: PillMetrics { PillMetrics(pointSize: data.fontData.pointSize) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.icon * 0.225, style: .continuous)
        let ink = data.onAccent ? Color.white : Color(.label)
        HStack(spacing: metrics.gap) {
            Group {
                if let icon = AppIconStore.shared.icon(data.app.id, dark: false) {
                    Image(uiImage: icon).resizable().interpolation(.high)
                } else {
                    DefaultAppIcon(size: metrics.icon)
                }
            }
            .frame(width: metrics.icon, height: metrics.icon)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            Text(verbatim: data.label)
                .font(Font(metrics.labelFont))
                .foregroundStyle(ink)
                .lineLimit(1)
        }
        .padding(.leading, metrics.leading)
        .padding(.trailing, metrics.trailing)
        .frame(height: metrics.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(data.onAccent ? Color.white.opacity(0.22) : Color(.label).opacity(0.08), in: .capsule)
        .accessibilityLabel(Text(verbatim: data.label))
    }

    /// The capsule drawn as a picture, for the field's attachment and the bubble's inline image; each
    /// one drawn once, so a bubble drawn again (a task's progress) does not draw its capsules again.
    @MainActor
    static func image(_ data: PillTextAttachmentData, scale: CGFloat, dark: Bool) -> UIImage? {
        let key = "\(data.app.id)|\(data.label)|\(data.fontData.pointSize)|\(scale)|\(dark)|\(data.onAccent)"
        if let drawn = drawn[key] { return drawn }
        let image = draw(data, scale: scale, dark: dark)
        if drawn.count > 200 { drawn.removeAll() }
        drawn[key] = image
        return image
    }

    @MainActor private static var drawn: [String: UIImage] = [:]

    @MainActor
    private static func draw(_ data: PillTextAttachmentData, scale: CGFloat, dark: Bool) -> UIImage? {
        let renderer = ImageRenderer(content: PillView(data: data).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = scale > 0 ? scale : 3
        renderer.proposedSize = ProposedViewSize(PillMetrics(pointSize: data.fontData.pointSize).size(for: data.label))
        return renderer.uiImage
    }
}
