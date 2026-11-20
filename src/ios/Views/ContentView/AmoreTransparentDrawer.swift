import SwiftUI

/// A paint-only policy. Default translucency never fills the pane with blue.
/// Respect the user's system accessibility request for an opaque surface.
enum AmoreDrawerSurfacePolicy {
    static func opaque(reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        reduceTransparency || increasedContrast
    }
}

struct AmoreDrawerBackdrop: View {
    var forceOpaque = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if forceOpaque || AmoreDrawerSurfacePolicy.opaque(
                reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased) {
                Color(uiColor: .systemBackground)
            } else {
                // Native ultra-thin material transmits the live transcript's
                // colours while blurring its glyphs. No opaque blue paint and
                // no low-alpha layer that reintroduces sharp text underneath.
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The actual chat/navigation tree appears exactly once. Sliding the sidebar
/// OVER it (rather than moving chat out from behind it) makes translucency real.
/// No snapshot, second AIChatView, cloned VM, store read or per-frame mutation.
struct AmoreTransparentDrawer<Chat: View, Sidebar: View>: View {
    let size: CGSize
    let drawerWidth: CGFloat
    let progress: CGFloat
    let presentationActive: Bool
    let reduceMotion: Bool
    let onClose: () -> Void
    private let chat: Chat
    private let sidebar: Sidebar

    init(size: CGSize, drawerWidth: CGFloat, progress: CGFloat,
         presentationActive: Bool, reduceMotion: Bool, onClose: @escaping () -> Void,
         @ViewBuilder chat: () -> Chat, @ViewBuilder sidebar: () -> Sidebar) {
        self.size = size; self.drawerWidth = drawerWidth; self.progress = progress
        self.presentationActive = presentationActive; self.reduceMotion = reduceMotion
        self.onClose = onClose; self.chat = chat(); self.sidebar = sidebar()
    }

    var body: some View {
        let phase = AmoreDrawerPresentation.phase(progress)
        let drawerIsPresented = phase > 0.001 || presentationActive
        ZStack(alignment: .leading) {
            // Keep the one UIKit/SwiftUI chat hierarchy mounted and enabled.
            // Toggling hit-testing or accessibility on its root can leave UIKit
            // controls non-hittable after the closing spring finishes.
            chat
                .environment(\.amoreDrawerProgress, phase)
                .frame(width: size.width, height: size.height)

            if drawerIsPresented {
                // Transparent hit shield above the live chat and below sidebar.
                // UIKit subviews remain mounted; the shield consumes touches even
                // over the left pane until an actual sidebar control handles them.
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if phase > 0.001 { onClose() }
                    }
                    .accessibilityHidden(true)
            }

            if drawerIsPresented {
                sidebar
                    .frame(width: drawerWidth, height: size.height, alignment: .leading)
                    .background { AmoreDrawerBackdrop().ignoresSafeArea(.container, edges: .vertical) }
                    .contentShape(Rectangle())
                    .offset(x: reduceMotion ? 0 : -drawerWidth * (1 - phase))
                    .opacity(reduceMotion ? phase : 1)
                    .allowsHitTesting(phase >= 0.999)
                    .accessibilityHidden(phase < 0.999)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .leading)
        .contentShape(Rectangle())
    }
}
