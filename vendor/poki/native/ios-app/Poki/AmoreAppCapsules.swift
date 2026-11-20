import SwiftUI
import UIKit

/// Host-facing adapter for the ORIGINAL Poki KnownApps/AppIconStore/PillView/TaskApps.
/// Only app identity and artwork cross the static-framework boundary. No private
/// user records, device connection, or synthetic task state is read here.
@available(iOS 18.0, *)
@MainActor
public enum AmoreCapsuleApps {
    public static func bundleID(for name: String) -> String? { AppIconStore.bundleID(name) }
    /// Name recognition only. A bundle ID here is not evidence that an app is installed.
    public static func bundleIDs(namedIn text: String) -> [String] { AppIconStore.bundleIDs(namedIn: text) }

    /// A launch is a *requested* action, not proof the phone opened the app.
    /// The host must independently check the real tool status and result.
    public static func requestedLaunches(deviceToolArguments raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8),
              let call = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              call["action"] as? String == "do" else { return [] }
        let actions: String?
        if let json = call["arguments_json"] as? String { actions = json }
        else if let object = call["arguments_json"], JSONSerialization.isValidJSONObject(object),
                let encoded = try? JSONSerialization.data(withJSONObject: object) {
            actions = String(data: encoded, encoding: .utf8)
        } else { actions = nil }
        guard let actions else { return [] }
        return TaskApps.launches(inArguments: actions).compactMap(TaskApps.key)
    }
}

/// Original iPhone icon lookup (including light/dark editions and App Store
/// fallback) with an Amore-neutral placeholder instead of the upstream bear.
@available(iOS 18.0, *)
@MainActor
public struct AmoreInstalledAppIcon: View {
    public let app: String
    public let size: CGFloat
    public var alwaysLight: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    public init(app: String, size: CGFloat, alwaysLight: Bool = true) {
        self.app = app
        self.size = size
        self.alwaysLight = alwaysLight
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        let icon = AppIconStore.shared.icon(app, dark: !alwaysLight && colorScheme == .dark)
        Group {
            if let icon {
                Image(uiImage: icon).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
                    .padding(size * 0.18)
                    .background(Color(.tertiarySystemFill))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .task(id: app) { if icon == nil { await AppIconStore.shared.load(app) } }
        .accessibilityHidden(true)
    }
}

/// The production Poki PillView metrics/label, backed by the very same
/// installed-icon lookup. Render only known apps; unknown names aren't badges.
@available(iOS 18.0, *)
@MainActor
public struct AmoreAppNamePill: View {
    public let app: String
    public let fontSize: CGFloat

    public init(app: String, fontSize: CGFloat = 14) {
        self.app = app
        self.fontSize = fontSize
    }

    public var body: some View {
        if let known = KnownApps.find(app) {
            let capsule = AppCapsule(id: known.id, names: known.names)
            let data = PillTextAttachmentData(app: capsule,
                text: known.name(in: .current), font: .systemFont(ofSize: fontSize))
            PillView(data: data)
                .frame(width: PillMetrics(pointSize: fontSize).size(for: data.label).width,
                       height: PillMetrics(pointSize: fontSize).height)
        }
    }
}
