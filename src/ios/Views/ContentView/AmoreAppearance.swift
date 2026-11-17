import SwiftUI
import UIKit

/// The same three user-facing choices as Poki. A new key deliberately ignores
/// removed legacy overrides: upgrades start in Automatic, not a stale forced mode.
enum AmoreAppearance: String, CaseIterable, Identifiable, Sendable {
    case automatic = ""
    case light
    case dark
    static let storageKey = "amore.appearance"
    var id: String { rawValue }

    static func resolved(_ raw: String) -> Self { Self(rawValue: raw) ?? .automatic }
    var title: String {
        switch self {
        case .automatic: return AppLocalized("Automatic")
        case .light: return AppLocalized("Light")
        case .dark: return AppLocalized("Dark")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .automatic: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    @MainActor func apply(to window: UIWindow) {
        guard window.overrideUserInterfaceStyle != interfaceStyle else { return }
        UIView.performWithoutAnimation { window.overrideUserInterfaceStyle = interfaceStyle }
    }
    @MainActor func applyToAppWindows() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            // Do not override the app's separate locked/screen-saver overlay.
            for window in scene.windows where window.windowLevel == .normal { apply(to: window) }
        }
    }
}

/// Does not key/recreate the root, providers, chat model, recordings or streams.
/// UIKit windows share the choice so menus and native sheets resolve the same
/// trait collection as SwiftUI. Automatic hands control straight back to iOS.
struct AmoreAppearanceHost: ViewModifier {
    @AppStorage(AmoreAppearance.storageKey) private var raw = AmoreAppearance.automatic.rawValue
    @Environment(\.scenePhase) private var phase
    private var mode: AmoreAppearance { .resolved(raw) }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(mode.colorScheme)
            .onAppear { mode.applyToAppWindows() }
            .onChange(of: raw) { _ in mode.applyToAppWindows() }
            .onChange(of: phase) { next in
                if next == .active { mode.applyToAppWindows() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeVisibleNotification)) { event in
                if let window = event.object as? UIWindow, window.windowLevel == .normal {
                    mode.apply(to: window)
                }
            }
    }
}

struct AmoreAppearanceSection: View {
    @AppStorage(AmoreAppearance.storageKey) private var raw = AmoreAppearance.automatic.rawValue
    private var choice: AmoreAppearance { .resolved(raw) }

    var body: some View {
        Section {
            ForEach(AmoreAppearance.allCases) { option in
                Button {
                    guard choice != option else { return }
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { raw = option.rawValue }
                    option.applyToAppWindows()
                } label: {
                    HStack(spacing: 12) {
                        Text(option.title).foregroundStyle(PokiTheme.primaryText)
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(PokiTheme.blueText)
                            .opacity(choice == option ? 1 : 0)
                            .accessibilityHidden(true)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choice == option ? .isSelected : [])
                .accessibilityIdentifier("amore.appearance." + (option == .automatic ? "automatic" : option.rawValue))
            }
        } header: {
            Text(AppLocalized("Theme"))
        } footer: {
            Text(AppLocalized("Automatic follows the iPhone’s appearance setting."))
        }
        .listRowBackground(PokiTheme.settingsCard)
    }
}
