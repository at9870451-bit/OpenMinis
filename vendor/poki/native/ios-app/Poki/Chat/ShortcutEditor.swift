import SwiftUI

/// A home page pill's Edit popup (long press, Edit): a small card over the page with the pill's
/// sentence and its app, Cancel and Save. It is two rows, so it is not a page (the owner). The card is
/// the glass of the cards that ask for an answer (`ApprovalAskCard`), Save is Poki's blue, and the app
/// row opens in place to the choices, as a row of Poki's card does (`PokiStatusCard`). Beginning the
/// sentence with an app's name picks that app; taking the app's name out of a sentence that began
/// with it leaves no app, and the pill shows Poki's icon. Picking another app puts its name at the
/// start of the sentence in place of the old one's.
///
/// It is shown in a full screen cover with nothing behind it, so it lies over the message field and the
/// top bar too, and it moves clear of the keyboard as any page does. The cover comes without the
/// system's slide (`HomePage` opens it in a transaction without animations); the card fades in itself.
struct ShortcutEditor: View {
    var shortcut: HomeShortcut
    /// The sentence took or gave up the keyboard. The page behind follows that keyboard as well.
    var typing: (Bool) -> Void = { _ in }
    var save: (_ sentence: String, _ app: String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sentence: String
    /// A bundle ID, or empty for none.
    @State private var app: String
    /// The app row is open to the choices.
    @State private var choosing = false
    @State private var shown = false
    @State private var cardFrame = CGRect.null
    @FocusState private var writing: Bool
    /// Every app Poki knows by name, by its name on this iPhone.
    private let apps: [(id: String, name: String)]

    init(shortcut: HomeShortcut, typing: @escaping (Bool) -> Void = { _ in },
         save: @escaping (_ sentence: String, _ app: String?) -> Void) {
        self.shortcut = shortcut
        self.typing = typing
        self.save = save
        _sentence = State(initialValue: shortcut.prompt)
        _app = State(initialValue: shortcut.app)
        apps = KnownApps.all.map { app -> (id: String, name: String) in (app.id, app.name(in: .current)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var empty: Bool { sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ZStack {
            // The page dims behind the card. A tap there puts the keyboard or the choices away first.
            Color.black.opacity(shown ? (scheme == .dark ? 0.45 : 0.25) : 0)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: tapOutside)
                .accessibilityLabel(Text("Close"))
                .accessibilityAddTraits(.isButton)
            ScrollView {
                card
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("shortcut.editor")) } action: { cardFrame = $0 }
                    .padding(.vertical, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center, for: .alignment)
            .padding(.horizontal, 24)
            .contentShape(.rect)
            .coordinateSpace(name: "shortcut.editor")
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("shortcut.editor")).onEnded { tap in
                guard !cardFrame.isNull, !cardFrame.contains(tap.location) else { return }
                tapOutside()
            })
            .scaleEffect(shown || reduceMotion ? 1 : 0.92)
            .opacity(shown ? 1 : 0)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { close() }
        }
        .presentationBackground(.clear)
        .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.18)) { shown = true } }
        .onChange(of: sentence) { old, new in
            // One sentence, wrapped: Return puts the keyboard away.
            if new.contains("\n") {
                sentence = new.replacingOccurrences(of: "\n", with: "")
                writing = false
                return
            }
            app = ShortcutApp.following(new, was: old, app: app.isEmpty ? nil : app) ?? ""
        }
        .onChange(of: app) { _, picked in
            sentence = ShortcutApp.sentence(sentence, for: picked.isEmpty ? nil : picked)
        }
        .onChange(of: writing) { _, writing in
            if writing { choosing = false }
            typing(writing)
        }
    }

    private func tapOutside() {
        if writing || choosing {
            writing = false
            choosing = false
        } else {
            close()
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            Text("Edit Shortcut").font(.headline).foregroundStyle(Color(.label))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                TextField("What Poki should do", text: $sentence, axis: .vertical)
                    .lineLimit(1...3)
                    .submitLabel(.done)
                    .focused($writing)
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .accessibilityIdentifier("shortcut.edit.sentence")
                Rectangle().fill(Color(.separator)).frame(height: 1 / 3).padding(.leading, 16)
                Button {
                    writing = false
                    choosing.toggle()
                } label: {
                    appRow
                }
                .buttonStyle(ShortcutRowStyle())
                .accessibilityValue(Text(verbatim: appName))
                .accessibilityIdentifier("shortcut.edit.app")
                if choosing { appChoices }
            }
            // No glass on glass: the two rows are a plain fill inside the card.
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(.rect(cornerRadius: 18, style: .continuous))
            let actions = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            actions {
                Button(action: close) {
                    Text("Cancel").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(QuietCapsuleButtonStyle())
                .accessibilityIdentifier("shortcut.edit.cancel")
                Button {
                    save(sentence, app.isEmpty ? nil : app)
                    close()
                } label: {
                    Text("Save")
                }
                .buttonStyle(SaveCapsuleButtonStyle())
                .disabled(empty)
                .opacity(empty ? 0.4 : 1)
                .accessibilityIdentifier("shortcut.edit.save")
            }
        }
        .padding(18)
        .frame(maxWidth: typeSize.isAccessibilitySize ? 520 : 340)
        .glassSurface(in: RoundedRectangle(cornerRadius: 30, style: .continuous), fallback: .card)
        .animation(.snappy(duration: 0.28), value: choosing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shortcut.edit")
    }

    private var appName: String { apps.first { $0.id == app }?.name ?? AppLocalization.text(LocalizedStringResource("None")) }

    /// The app row: its name, the app chosen with its icon, and the arrow that opens the choices under it.
    private var appRow: some View {
        HStack(spacing: 8) {
            Text("App").foregroundStyle(Color(.label)).frame(maxWidth: .infinity, alignment: .leading)
            icon(app)
            Text(verbatim: appName).foregroundStyle(Color(.secondaryLabel)).fixedSize(horizontal: false, vertical: true)
            Image(systemName: choosing ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.bold)).foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 16).frame(minHeight: 50).contentShape(.rect)
    }

    /// None, then every app by name, the one chosen ticked: five rows high, and the rest scrolls.
    private var appChoices: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 0) {
                    choice("", name: AppLocalization.text(LocalizedStringResource("None")))
                    ForEach(apps, id: \.id) { choice($0.id, name: $0.name) }
                }
            }
            .frame(height: 220)
            .onAppear { reader.scrollTo(app, anchor: .center) }
        }
        .overlay(alignment: .top) { Rectangle().fill(Color(.separator)).frame(height: 1 / 3) }
        .transition(.opacity)
    }

    private func choice(_ id: String, name: String) -> some View {
        Button {
            app = id
            choosing = false
        } label: {
            HStack(spacing: 10) {
                icon(id)
                Text(verbatim: name).foregroundStyle(Color(.label)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Tint.blue)
                    .opacity(id == app ? 1 : 0).frame(width: 20)
            }
            .padding(.horizontal, 16).frame(minHeight: 44).contentShape(.rect)
        }
        .buttonStyle(ShortcutRowStyle())
        .accessibilityAddTraits(id == app ? .isSelected : [])
        .id(id)
    }

    /// An app's icon, or Poki's for none: what the pill will show.
    @ViewBuilder private func icon(_ id: String) -> some View {
        if id.isEmpty { DefaultAppIcon(size: 24) } else { AppIconView(app: id, size: 24, alwaysLight: true) }
    }

    /// The card fades out, then the cover goes without the system's slide.
    private func close() {
        writing = false
        withAnimation(.easeOut(duration: 0.18)) { shown = false } completion: {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { dismiss() }
        }
    }
}

/// Save: Poki's blue with white words, the message field's send button's colours, the same in light
/// and dark (the owner: no black button with white words). Its size and its press are the solid
/// capsule's (`SolidCapsuleButtonStyle`).
private struct SaveCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Tint.blue, in: .capsule)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A row of a card or a menu: a light press highlight, as a system menu's.
struct ShortcutRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(Color(.label).opacity(configuration.isPressed ? 0.08 : 0))
    }
}
