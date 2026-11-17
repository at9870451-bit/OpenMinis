import AVFoundation
import Speech
import SwiftUI

/// What an earlier version of Poki left on this phone. None of it is written by this version before
/// launch has read it, so it tells an update (or a reinstall the Keychain restored) from a fresh install:
/// a saved conversation, or a setting an earlier version stored (setup progress, the relay, the model,
/// approvals, voice).
enum EarlierVersion {
    nonisolated static func leftTraces(defaults: UserDefaults, sessionsFolder: URL) -> Bool {
        let settings = ["setup", "relayAddress", "relayEnabled", "chat.provider", "chat.installationID", "approvals.ask", "wantsOn", "voice.model"]
        let conversations = (try? FileManager.default.contentsOfDirectory(at: sessionsFolder, includingPropertiesForKeys: nil))?
            .contains { $0.pathExtension == "json" } ?? false
        return conversations || settings.contains { defaults.object(forKey: $0) != nil }
    }
}

/// The first run: Poki says hello, then goes through what it needs (this iPhone, a model, the microphone),
/// each of which can wait, and says what to try. Someone who used an earlier version never sees it on
/// updating; it can be gone through again from Settings › Automation › Setup.
enum FirstRun {
    /// Absent until the first launch of a version with the first run decides it, once.
    static let key = "pokiFirstRun"
    enum Record: String { case due, done }

    /// Call at launch before anything this version writes to the defaults.
    nonisolated static func decide(defaults: UserDefaults = .standard, sessionsFolder: URL = SessionStore.defaultFolder) {
        guard defaults.string(forKey: key) == nil else { return }
        let record: Record = EarlierVersion.leftTraces(defaults: defaults, sessionsFolder: sessionsFolder) ? .done : .due
        defaults.set(record.rawValue, forKey: key)
    }

    /// Whether to show it at this launch. Scripted launches (the in-app tests, the screenshot and check
    /// scripts, which all pass `-poki…` arguments) have nobody to go through it; `-pokiScreen welcome` asks
    /// for it.
    static func isDue(defaults: UserDefaults = .standard) -> Bool {
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if arguments["pokiScreen"] as? String == "welcome" { return true }
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil { return false }
        if arguments.keys.contains(where: { $0.hasPrefix("poki") }) { return false }
        return defaults.string(forKey: key) == Record.due.rawValue
    }

    static func finish(defaults: UserDefaults = .standard) { defaults.set(Record.done.rawValue, forKey: key) }
}

/// The pages of the first run, over the home page's light.
struct FirstRunGuide: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// A setup step a link opened (a pairing file from Poki Setup) while the first run is up.
    @Binding var link: SetupStep?
    var done: () -> Void

    enum Page: Int, CaseIterable { case hello, phone, model, voice, ready }

    @State private var page = Page.hello
    @State private var path = NavigationPath()
    @State private var hasModel = ModelKeys.hasUsableKey
    @State private var voiceAllowed = FirstRunGuide.voiceAllowedNow
    @State private var addingAccount = false
    @State private var keyFor: ModelProvider?
    @State private var signingIn = false

    private static var voiceAllowedNow: Bool {
        AVAudioApplication.shared.recordPermission == .granted && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// The first item still open on the phone's list, numbered from one.
    private var nextStep: (number: Int, step: SetupStep)? {
        SetupStep.shown.enumerated().first { !model.isDone($0.element) }.map { ($0.offset + 1, $0.element) }
    }

    private var ready: Bool { model.setupLooksComplete }

    private var mood: PokiMood {
        switch page {
        case .hello: .hello
        case .phone: .onYourPhone
        case .model: .thinking
        case .voice: .listening
        case .ready: ready ? .done : .ready
        }
    }

    private var title: String {
        switch page {
        case .hello: AppLocalization.text(LocalizedStringResource("Hello, I’m Poki"))
        case .phone: AppLocalization.text(LocalizedStringResource("Set Up This iPhone"))
        case .model: AppLocalization.text(LocalizedStringResource("Pick a Model"))
        case .voice: AppLocalization.text(LocalizedStringResource("Talk Instead of Typing"))
        case .ready: ready ? AppLocalization.text(LocalizedStringResource("All Set")) : AppLocalization.text(LocalizedStringResource("Nearly There"))
        }
    }

    private var words: String {
        switch page {
        case .hello:
            return AppLocalization.text(LocalizedStringResource("Tell me what you need, by text or by voice, and I do it on your iPhone while you watch."))
        case .phone:
            return AppLocalization.text(LocalizedStringResource("\(SetupStep.shown.count) switches, each turned on once. They tick themselves as you go."))
        case .model:
            return AppLocalization.text(LocalizedStringResource("I think with a model from your own account. Sign in or add a key. You can change it any time."))
        case .voice:
            return AppLocalization.text(LocalizedStringResource("To hear you, I need the microphone and speech recognition."))
        case .ready:
            return ready
                ? AppLocalization.text(LocalizedStringResource("Try “Order my usual coffee”. Type it, or say it."))
                : AppLocalization.text(LocalizedStringResource("Look around now. Once the switches are on, I can use this iPhone. They are in Settings › Automation › Setup."))
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        FirstRunPortrait(mood: mood)
                            .padding(.top, 28)
                        dots.padding(.top, 22)
                        VStack(spacing: 10) {
                            Text(verbatim: title)
                                .font(Prominent.font(size: 28, relativeTo: .title, .semibold))
                                .foregroundStyle(Color(.label))
                                .accessibilityAddTraits(.isHeader)
                            Text(verbatim: words)
                                .font(.body)
                                .foregroundStyle(Tint.homeSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            detail.padding(.top, 14)
                        }
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                        .id(page)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .offset(y: 12).combined(with: .opacity), removal: .opacity))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                buttons
            }
            .background { HomeBackdrop(home: true, working: false) }
            .toolbar {
                if page != .hello {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.left") { go(Page(rawValue: page.rawValue - 1) ?? .hello) }
                            .accessibilityIdentifier("firstRun.back")
                    }
                }
            }
            .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0).toolbar(.visible, for: .navigationBar) }
            .onChange(of: path.count) { _, _ in refresh() }
            .onChange(of: link, initial: true) { _, step in
                guard let step else { return }
                link = nil
                page = .phone
                path = NavigationPath([step])
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
            .onAppear { model.loopback.resume() }
            .sheet(isPresented: $addingAccount, onDismiss: refresh) { AddAccount() }
            .sheet(item: $keyFor, onDismiss: refresh) { KeyEntry(provider: $0) }
            .sheet(isPresented: $signingIn, onDismiss: refresh) { ChatGPTSignIn() }
        }
        .interactiveDismissDisabled()
        // Keep the existing limit until the guide's rows and buttons are verified at AX3–AX5.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Page.allCases, id: \.self) { each in
                Capsule()
                    .fill(each == page ? Tint.blueText : Tint.blueLine)
                    .frame(width: each == page ? 20 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(page.rawValue + 1) of \(Page.allCases.count)"))
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .phone:
            FirstRunCard {
                ForEach(Array(SetupStep.shown.enumerated()), id: \.element) { index, step in
                    if index > 0 { Divider().padding(.leading, 58) }
                    NavigationLink(value: step) { stepRow(step) }
                        .buttonStyle(PressedDimStyle())
                        .accessibilityIdentifier("firstRun.step.\(step.rawValue)")
                }
            }
        case .model:
            FirstRunCard {
                ForEach(Array(Self.namedProviders.enumerated()), id: \.element) { index, provider in
                    if index > 0 { Divider().padding(.leading, 58) }
                    Button { open(provider) } label: { providerRow(provider) }
                        .buttonStyle(PressedDimStyle())
                }
                Divider().padding(.leading, 58)
                Button { addingAccount = true } label: {
                    HStack(spacing: 14) {
                        SettingsIcon(symbol: "ellipsis", size: 30)
                        Text("More Providers").font(.body).foregroundStyle(Color(.label))
                        Spacer(minLength: 8)
                        Text(verbatim: "\(ModelProvider.allCases.count - Self.namedProviders.count)").foregroundStyle(Color(.secondaryLabel))
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color(.tertiaryLabel))
                    }
                    .padding(.horizontal, 14).frame(minHeight: 56).contentShape(.rect)
                }
                .buttonStyle(PressedDimStyle())
            }
            .id(hasModel)
        default:
            EmptyView()
        }
    }

    /// The providers named on the page; the rest are behind More Providers.
    private static let namedProviders: [ModelProvider] = [.chatgpt, .anthropic, .openai]

    private func stepRow(_ step: SetupStep) -> some View {
        let ticked = model.isDone(step)
        // At the accessibility sizes the state goes under the name, as Settings lays its rows out.
        let stacked = typeSize.isAccessibilitySize
        return HStack(spacing: 14) {
            if !stacked { SettingsIcon(symbol: ticked ? "checkmark" : step.symbol, size: 30) }
            VStack(alignment: .leading, spacing: 4) {
                Text(step.pageTitle).font(.body).foregroundStyle(Color(.label)).multilineTextAlignment(.leading)
                if stacked { stepState(step, ticked: ticked) }
            }
            Spacer(minLength: 8)
            if !stacked { stepState(step, ticked: ticked) }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 14).padding(.vertical, stacked ? 10 : 0).frame(minHeight: 56).contentShape(.rect)
    }

    @ViewBuilder private func stepState(_ step: SetupStep, ticked: Bool) -> some View {
        if ticked {
            Text("Done").font(.subheadline).foregroundStyle(Tint.greenInk)
        } else if nextStep?.step == step {
            Text("Next").font(.footnote.weight(.semibold)).foregroundStyle(Tint.amberInk)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Tint.amberSoft, in: .capsule)
        }
    }

    private func providerRow(_ provider: ModelProvider) -> some View {
        HStack(spacing: 14) {
            ProviderTile(provider: provider, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: provider.name).font(.body).foregroundStyle(Color(.label))
                Text(ModelAccounts.method(provider)).font(.footnote).foregroundStyle(Color(.secondaryLabel))
            }
            Spacer(minLength: 8)
            if ModelAccounts.isSetUp(provider) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Tint.green)
                    .accessibilityLabel(Text("Account Added"))
            } else {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 56).contentShape(.rect)
    }

    /// The one button to press, and under it the way past on a page that asks for something not done.
    private var buttons: some View {
        VStack(spacing: 4) {
            SettingsPill(title: primaryWord, prominent: true, action: primary)
                .accessibilityIdentifier("firstRun.primary")
            if showsLater {
                Button { go(next) } label: {
                    Text("Not Now").font(.subheadline.weight(.medium)).foregroundStyle(Color(.label).opacity(0.72))
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                }
                .accessibilityIdentifier("firstRun.later")
            }
        }
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 8)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    private var primaryWord: LocalizedStringKey {
        switch page {
        case .hello: "Get Started"
        case .phone:
            if let nextStep { "Continue with Step \(nextStep.number)" } else { "Continue" }
        case .model: hasModel ? "Continue" : "Add an Account"
        case .voice: voiceAllowed ? "Continue" : "Allow Microphone"
        case .ready: "Start"
        }
    }

    private var showsLater: Bool {
        switch page {
        case .phone: nextStep != nil
        case .model: !hasModel
        case .voice: !voiceAllowed
        case .hello, .ready: false
        }
    }

    private var next: Page { Page(rawValue: page.rawValue + 1) ?? .ready }

    private func primary() {
        switch page {
        case .hello: go(next)
        case .phone:
            if let nextStep { path.append(nextStep.step) } else { go(next) }
        case .model:
            if hasModel { go(next) } else { addingAccount = true }
        case .voice:
            guard !voiceAllowed else { return go(next) }
            Task {
                voiceAllowed = await Dictation.allowed()
                go(next)
            }
        case .ready:
            FirstRun.finish()
            done()
        }
    }

    private func open(_ provider: ModelProvider) {
        if provider.signsIn { signingIn = true } else { keyFor = provider }
    }

    private func go(_ to: Page) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.1)) { page = to }
    }

    private func refresh() {
        hasModel = ModelKeys.hasUsableKey
        voiceAllowed = Self.voiceAllowedNow
    }
}

/// Settings' way back into the first run: a blue text button that opens the pages over everything.
/// It carries its own cover, so whichever settings page lists the setup items places it with one line.
/// `wide` stretches it to the page width with a 44-point row, for pages that are not a List; `row`
/// draws it as a settings row, with the icon the rows beside it have.
struct FirstRunAgain: View {
    var wide = false
    var row = false
    @State private var welcoming = false

    var body: some View {
        Button { welcoming = true } label: {
            if row {
                SettingsRow(title: "Show Welcome Pages Again", symbol: "hand.wave").contentShape(.rect)
            } else {
                Text("Show Welcome Pages Again")
                    .foregroundStyle(Tint.blueText)
                    .frame(maxWidth: wide ? .infinity : nil, minHeight: wide ? 44 : nil)
                    .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("setup.firstRun")
        .fullScreenCover(isPresented: $welcoming) { FirstRunGuide(link: .constant(nil), done: { welcoming = false }) }
    }
}

/// Poki's round picture at the top of each page, in the white ring the home page gives it.
private struct FirstRunPortrait: View {
    var mood: PokiMood
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .title) private var side: CGFloat = 104

    var body: some View {
        let dark = scheme == .dark
        // Grows with the text, up to half as large again: at the accessibility sizes the words need the room.
        PokiPortrait(mood: mood, side: min(side, 156))
            .overlay(Circle().strokeBorder(Color.white.opacity(dark ? 0.85 : 1), lineWidth: 2.5))
            .shadow(color: dark ? Color(hex: 0x3C8DFF).opacity(0.35) : Color(hex: 0x0177FD).opacity(0.18), radius: dark ? 10 : 9, y: 5)
    }
}

/// The rows of a page on one card, as Settings groups them.
private struct FirstRunCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .multilineTextAlignment(.leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Tint.line, lineWidth: 1))
    }
}
