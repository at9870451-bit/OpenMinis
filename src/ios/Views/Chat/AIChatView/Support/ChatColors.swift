//
//  ChatColors.swift
//  Minis - chat page (AIChatView)
//
//  ChatColors: the chat UI's color palette (system colors, light / dark).
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Color Palette (Poki Design System)

/// Every chat surface resolves through `PokiTheme`, so the chat page shares
/// the same warm-paper palette as the drawer, settings and composer.
enum ChatColors {
    static let background = PokiTheme.background
    static let secondaryBg = PokiTheme.surface
    static let inputIconBg = PokiTheme.surface
    static let inputIconBorder = PokiTheme.divider
    static let inputBg = PokiTheme.floatingSurface
    static let inputBorder = PokiTheme.fieldEdge
    static let placeholder = PokiTheme.homePlaceholder
    static let primaryText = PokiTheme.primaryText
    static let secondaryText = PokiTheme.secondaryText
    static let tertiaryText = PokiTheme.secondaryText.opacity(0.7)
    /// Poki outgoing blue stays identical in light and dark; queued messages
    /// keep their original provisional treatment and assistant text uses its
    /// own neutral adaptive surface.
    static let userBubble = PokiTheme.blue
    static let toolBg = PokiTheme.surface
    static let toolBorder = PokiTheme.divider
    static let accent = PokiTheme.aiAccentStrong
    static let sendButton = PokiTheme.primaryButton
    static let sendButtonDisabled = PokiTheme.secondaryText.opacity(0.35)
    /// AI-authored accents (thinking row, retry affordance, suggestions).
    static let aiAccent = PokiTheme.aiAccent
    static let aiTagBackground = PokiTheme.tagBackground
    static let aiTagText = PokiTheme.tagText
}
