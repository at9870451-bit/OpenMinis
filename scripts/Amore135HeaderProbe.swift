import SwiftUI
import UIKit
import OSLog

// TEST HOST ONLY. No kernel, credentials, browser, terminal, sync or audio service.
// These names satisfy the DEBUG-only diagnostics in the unmodified extracted menu.
enum NavbarEvalStats {
    static var menuEval = 0
    static var toolbarPass = 0
    static let logger = Logger(subsystem: "app.amore.components135", category: "TestNavbar")
}
enum ChatNavMenuBarItem {
    static let logger = Logger(subsystem: "app.amore.components135", category: "TestMenu")
}
final class LastAPIRequestBody {
    static let shared = LastAPIRequestBody()
    func getAll() -> [String] { [] } // Empty synthetic history; never reads real requests.
}

struct Amore135HeaderProbe: View {
    @State private var lastAction = "none"
    @State private var calls: [String: Int] = [:]
    @State private var speak = false
    @State private var cache = false
    @State private var tier: SpeedTier = .standard
    @State private var awake = false
    @State private var saver = false
    @State private var hitRect = "pending"
    private var empty: Bool { ProcessInfo.processInfo.arguments.contains("-amore135-empty-messages") }

    private func record(_ action: String) {
        lastAction = action
        calls[action, default: 0] += 1
    }

    var body: some View {
        VStack(spacing: 12) {
            // Exactly the production composition: real Chrome + AnyView + real UIKit menu.
            AmoreConversationChrome(home: false, thinking: false, busy: false,
                title: "Header Probe", active: true, trailing: AnyView(menu
                    .frame(width: 48, height: 48)
                    .accessibilityLabel(Text(AppLocalized("Conversation options")))
                    .accessibilityIdentifier("amore.conversationOptions")),
                openThreads: { record("openThreads") }, openModel: { record("openModel") })
                .background(HeaderHitRectReader { value in
                    if hitRect != value { hitRect = value }
                })
            Text("TEST HOST ONLY — callbacks are local State, not real services")
                .font(.caption).accessibilityIdentifier("amore135.header.root")
            Text(lastAction).accessibilityIdentifier("amore135.header.lastAction")
            Text("\(calls[lastAction, default: 0])").accessibilityIdentifier("amore135.header.actionCount")
            Text("\(calls.values.reduce(0, +))").accessibilityIdentifier("amore135.header.totalCount")
            Text("speak=\(speak);cache=\(cache);tier=\(tier.rawValue);awake=\(awake);saver=\(saver)")
                .font(.caption).accessibilityIdentifier("amore135.header.toggles")
            Text(hitRect).font(.caption2).accessibilityIdentifier("amore135.header.hitRect")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PokiTheme.background.ignoresSafeArea())
    }

    private var menu: some View {
        ChatTrailingMenuButton(
            fillsRoundHeader: true,
            messagesEmpty: empty, hasSession: true, isForcePulling: false,
            iCloudSyncEnabled: true, memoryEnabled: true,
            speakEnabled: speak, showEnhancedCacheToggle: true, enhancedCacheEnabled: cache,
            showFastModeToggle: true, speedTier: tier,
            showUltrafast: !ProcessInfo.processInfo.arguments.contains("-amore135-fast-switch"),
            keepAwakeEnabled: awake, screenSaverNowEnabled: saver,
            modeSessionKey: "probe-session", pureChatEnabled: false,
            onSetPureChatMode: { _ in record("setPureChatMode") },
            onNewChat: { record("onNewChat") }, onCompact: { record("onCompact") },
            onClearChat: { record("onClearChat") }, onForceSync: { record("onForceSync") },
            onForcePull: { record("onForcePull") }, onOpenTerminal: { record("onOpenTerminal") },
            onOpenBrowser: { record("onOpenBrowser") }, onBrowseFiles: { record("onBrowseFiles") },
            onSkills: { record("onSkills") }, onMCPs: { record("onMCPs") },
            onMemories: { record("onMemories") },
            setSpeakEnabled: { speak = $0; record("setSpeakEnabled") },
            setEnhancedCache: { cache = $0; record("setEnhancedCache") },
            setSpeedTier: { tier = $0; record("setSpeedTier") },
            setKeepAwake: { awake = $0; record("setKeepAwake") },
            setScreenSaverNow: { saver = $0; record("setScreenSaverNow") },
            onTokenUsage: { record("onTokenUsage") },
            onCopyRequests: { record("onCopyRequests") }, onCopySessionData: { record("onCopySessionData") },
            onShare: { record("onShare") }, onSearchInChat: { record("onSearchInChat") })
    }
}

// Read-only observer. It does NOT resize the UIButton or replace its menu/actions.
// Intrinsic glyph bounds are intentionally small in production; report the real
// point(inside:) expansion, then UI tests inject physical taps at its 44pt edges.
private struct HeaderHitRectReader: UIViewRepresentable {
    let report: (String) -> Void
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { sample(view, attempt: 0) }
    private func sample(_ anchor: UIView, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak anchor] in
            guard let anchor else { return }
            guard let window = anchor.window, let button = findButton(window) else {
                if attempt < 20 { sample(anchor, attempt: attempt + 1) }
                return
            }
            let dx = min(0, (button.bounds.width - 44) / 2)
            let dy = min(0, (button.bounds.height - 44) / 2)
            let local = button.bounds.insetBy(dx: dx, dy: dy)
            let rect = button.convert(local, to: window)
            let points = [CGPoint(x: local.midX, y: local.midY),
                CGPoint(x: local.minX + 1, y: local.midY), CGPoint(x: local.maxX - 1, y: local.midY),
                CGPoint(x: local.midX, y: local.minY + 1), CGPoint(x: local.midX, y: local.maxY - 1)]
            let accepted = points.allSatisfy { button.point(inside: $0, with: nil) }
            report("\(rect.minX)|\(rect.minY)|\(rect.width)|\(rect.height)|\(accepted)|UIButton")
        }
    }
    private func findButton(_ root: UIView) -> ChatTrailingMenuButton.HitPaddedButton? {
        if let button = root as? ChatTrailingMenuButton.HitPaddedButton { return button }
        for child in root.subviews { if let found = findButton(child) { return found } }
        return nil
    }
}
