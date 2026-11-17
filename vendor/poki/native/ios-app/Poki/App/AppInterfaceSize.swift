import SwiftUI
import UIKit

/// One native content-size category for this window, including UIKit presentations and editors.
/// Removing the override restores iOS's current per-app preference immediately.
enum AppInterfaceSize {
    static let defaultsKey = "appInterfaceSize"
    static let system = "system"
    static let categories: [UIContentSizeCategory] = [
        .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
        .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
        .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
    ]

    static func category(for preference: String) -> UIContentSizeCategory? {
        categories.first { $0.rawValue == preference }
    }

    static func apply(_ preference: String, to window: UIWindow) {
        if let category = category(for: preference) {
            if !window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self)
                || window.traitCollection.preferredContentSizeCategory != category {
                window.traitOverrides.preferredContentSizeCategory = category
            }
        } else if window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self) {
            window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        }
    }

    /// The navigation bars use Poki's custom fonts, which must resolve against this window's traits.
    static func updateNavigationFonts(in window: UIWindow) {
        let traits = window.traitCollection
        let systemLarge = UIFont.preferredFont(forTextStyle: .largeTitle, compatibleWith: traits)
        let bold = systemLarge.fontDescriptor.withSymbolicTraits(.traitBold) ?? systemLarge.fontDescriptor
        let large = Prominent.uiFont(.largeTitle, .bold, compatibleWith: traits) ?? UIFont(descriptor: bold, size: systemLarge.pointSize)
        let inline = Prominent.uiFont(.headline, .semibold, compatibleWith: traits) ?? UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        func apply(_ bar: UINavigationBar) {
            var largeAttributes = bar.largeTitleTextAttributes ?? [:]
            var inlineAttributes = bar.titleTextAttributes ?? [:]
            largeAttributes[.font] = large
            inlineAttributes[.font] = inline
            bar.largeTitleTextAttributes = largeAttributes
            bar.titleTextAttributes = inlineAttributes
        }
        apply(UINavigationBar.appearance())
        func visit(_ controller: UIViewController) {
            if let navigation = controller as? UINavigationController { apply(navigation.navigationBar) }
            controller.children.forEach(visit)
            if let presented = controller.presentedViewController { visit(presented) }
        }
        if let root = window.rootViewController { visit(root) }
    }

}

struct InterfaceSizeSettingsView: View {
    @AppStorage(AppInterfaceSize.defaultsKey) private var preference = AppInterfaceSize.system
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: String?
    @State private var editing = false

    private let sliderHeight: CGFloat = 52
    private let topInset: CGFloat = 20
    private let bottomInset: CGFloat = 12

    private var displayedPreference: String { draft ?? preference }
    private var displayedSize: DynamicTypeSize {
        AppInterfaceSize.category(for: displayedPreference).flatMap(DynamicTypeSize.init) ?? typeSize
    }
    private var followsSystem: Bool { AppInterfaceSize.category(for: displayedPreference) == nil }
    private var index: Int {
        let category = AppInterfaceSize.category(for: displayedPreference) ?? UIContentSizeCategory(typeSize)
        return AppInterfaceSize.categories.firstIndex(of: category) ?? 3
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 0) {
                        controls
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 25))

                    VStack(alignment: .leading, spacing: 8) {
                        SettingsHeader("Preview")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                        GeometryReader { preview in
                            InterfaceSizePreview()
                                .frame(width: preview.size.width, height: preview.size.height)
                        }
                        .frame(minHeight: 520)
                    }
                }
                .frame(minHeight: max(0, geometry.size.height - topInset - bottomInset), alignment: .top)
                .padding(.horizontal, 16)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: followsSystem)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        // Keep this entire page live while tracking. Changing UIWindow traits during the native
        // slider's tracking repeatedly invalidates UIKit and SwiftUI's glass/scroll layout together.
        // The visible page shares one local category; persist and update the window when tracking ends.
        .dynamicTypeSize(displayedSize)
        .onDisappear(perform: commit)
        .onChange(of: scenePhase) { _, phase in if phase != .active { commit() } }
        .onChange(of: preference) { _, _ in if !editing { draft = nil } }
        .navigationTitle(AppLocalization.text(LocalizedStringResource("Interface Size")))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var controls: some View {
        Toggle("Follow System", isOn: Binding(
            get: { followsSystem },
            set: { followsSystem in
                draft = nil
                preference = followsSystem ? AppInterfaceSize.system : UIContentSizeCategory(typeSize).rawValue
            }
        ))
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .accessibilityIdentifier("interfaceSize.followSystem")
        VStack(spacing: 0) {
            Divider()
            Slider(value: Binding(
                get: { Double(index) },
                set: { value in
                    let step = Int(value.rounded())
                    let selected = AppInterfaceSize.categories[step].rawValue
                    if displayedPreference != selected {
                        draft = selected
                        if !editing { commit() }
                    }
                }
            ), in: 0...Double(AppInterfaceSize.categories.count - 1), step: 1) {
                Text("Interface Size")
            } minimumValueLabel: {
                endpoint("Interface Size Minimum", size: 14)
            } maximumValueLabel: {
                endpoint("Interface Size Maximum", size: 18)
            } onEditingChanged: { tracking in
                editing = tracking
                if !tracking { commit() }
            }
            .sensoryFeedback(.selection, trigger: index)
            .tint(Color(.secondaryLabel))
            .accessibilityValue(Text("Size \(index + 1) of \(AppInterfaceSize.categories.count)"))
            .accessibilityIdentifier("interfaceSize.slider")
            .frame(maxHeight: .infinity)
        }
        .frame(height: sliderHeight)
        .opacity(followsSystem ? 0 : 1)
        .frame(height: followsSystem ? 0 : sliderHeight, alignment: .top)
        .clipped()
        .allowsHitTesting(!followsSystem)
        .accessibilityHidden(followsSystem)
    }

    private func commit() {
        guard let selected = draft else { return }
        if preference != selected { preference = selected }
        draft = nil
    }

    private func endpoint(_ label: LocalizedStringKey, size: CGFloat) -> some View {
        Text(label)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28)
            .dynamicTypeSize(.large)
            .accessibilityHidden(true)
    }

}

/// Sample data rendered by the production chat components so their appearance stays in sync.
private struct InterfaceSizePreview: View {
    private let started = Date(timeIntervalSince1970: 0)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    MessageBubble(direction: .outgoing, text: AppLocalization.text(LocalizedStringResource("Help me plan tomorrow.")), tail: true)
                    MessageBubble(direction: .incoming, text: AppLocalization.text(LocalizedStringResource("Start with your most important task in the morning. Leave time for lunch and a short walk.\n\nI can also help you set a reminder.")), tail: true)
                    TaskCard(title: AppLocalization.text(LocalizedStringResource("Reminder created")),
                             steps: [PlanStep(AppLocalization.text(LocalizedStringResource("Tomorrow at 9:00 AM")), state: .done)],
                             state: .done, app: AppIconStore.name("com.apple.reminders") ?? "Reminders", started: started,
                             ended: started.addingTimeInterval(2), plannedTotal: 1)
                    MessageBubble(direction: .outgoing, text: AppLocalization.text(LocalizedStringResource("Show me the full plan.")), tail: true)
                    MessageBubble(direction: .incoming, text: AppLocalization.text(LocalizedStringResource("Tomorrow’s plan  \n9:00 — Start with your most important task.  \n12:00 — Take a lunch break.  \n12:45 — Go for a short walk.  \n14:00 — Catch up on messages.  \n16:30 — Review today’s progress.")), tail: true)
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.top, for: .initialOffset)
        }
        .topBar {
            ChatTopBar(status: PokiStatus(.ready), home: false, busy: false,
                       openThreads: {}, newConversation: {}, openDetails: {})
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Poki"))
        }
        .bottomBar(softEdge: true) {
            ComposerInputView(input: .constant(""), focused: .constant(false), running: false,
                              send: { _, _ in }, stop: {}, openVoice: {})
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Message Poki"))
                .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 10)
                .frame(maxWidth: 720)
        }
        .background { HomeBackdrop(home: false, working: false, frozen: true) }
        .overlayPreferenceValue(PicturePlaceKey.self) { anchors in
            GeometryReader { proxy in
                PokiFlight(status: PokiStatus(.ready), home: false, writing: false,
                           places: anchors.mapValues { proxy[$0] }, pokes: 0, tap: {})
            }
            .allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .accessibilityIdentifier("interfaceSize.preview")
    }
}
