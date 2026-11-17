import AVFoundation
import SwiftUI

/// Talk to Poki: say what to do, Poki does it on this iPhone and answers out loud.
struct VoiceView: View {
    @Environment(AppModel.self) private var app
    /// Set when Voice is a sheet over Home: the Done button closes it.
    var close: (() -> Void)?
    /// Pushed in the Poki tab: no navigation stack or Done of its own.
    var embedded = false
    @State private var micDenied = false
    @AppStorage(FieldDictation.buttonKey) private var dictationButton = FieldDictation.buttonShown

    private var voice: VoiceModel { app.voice }

    var body: some View {
        if embedded { form } else { NavigationStack { form.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { if let close { close() } else { dismiss() } } } } } }
    }

    private var form: some View {
        @Bindable var voice = voice
        return Form {
                // Voice runs in the chat (the waveform button for a live conversation, the microphone
                // beside it for dictation). This page only says how it runs and keeps its options.
                Section {
                    LabeledContent {
                        Text(voice.canTalkLive ? (VoiceDirect.apiKey != nil ? AppLocalization.text(LocalizedStringResource("OpenAI key")) : AppLocalization.text(LocalizedStringResource("Voice bridge"))) : AppLocalization.text(LocalizedStringResource("Not Available")))
                            .foregroundStyle(voice.canTalkLive ? Color.secondary : Color.orange)
                    } label: {
                        SettingsLabel("Live Voice", systemImage: "waveform")
                    }
                    // Dictation runs on this iPhone with every model; its microphone sits beside Send.
                    Toggle(isOn: $dictationButton) { SettingsLabel("Show Dictation Button in Message Field", systemImage: "mic") }
                        .accessibilityIdentifier("voice.dictationButton")
                    Toggle(isOn: $voice.muted) { SettingsLabel("Mute Poki’s Voice", systemImage: "speaker.slash") }
                } footer: {
                    if micDenied { Text("Poki can't use the microphone. Allow it in Settings, Privacy, Microphone.").foregroundStyle(.orange) }
                    else if voice.canTalkLive {
                        Text("In the chat, the waveform button starts a live conversation: Poki listens, acts and answers out loud, also while you are in another app. It ends by itself 8 seconds after an answer if nobody speaks. Tap End to stop sooner. The microphone in the message field only dictates.")
                    } else {
                        Text("A live conversation uses OpenAI’s Realtime voice, which needs an OpenAI API key in Settings › Models. Dictation in the message field works with every model.")
                    }
                }
                ActionButtonSection()
            }
            .navigationTitle(AppLocalization.text("Dictation & Mute"))
            .navigationBarTitleDisplayMode(.inline)
    }

    @Environment(\.dismiss) private var dismiss

    private var symbol: String {
        switch voice.phase {
        case .off: "waveform.slash"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .listening, .hearing: "waveform"
        case .thinking: "hand.tap.fill"
        case .speaking: "speaker.wave.2.fill"
        case .lost: "exclamationmark.triangle.fill"
        }
    }

    private static func icon(_ role: VoiceLine.Role) -> String {
        switch role {
        case .you: "person.wave.2"
        case .poki: "pawprint.fill"
        case .tool: "hand.tap"
        case .note: "info.circle"
        }
    }
}

/// Voice's rows on Settings › Advanced: how long the last answer took, and the voice bridge on a Mac
/// (live voice without an OpenAI key on this iPhone). They were Voice's own Advanced.
struct VoiceAdvancedRows: View {
    @Environment(AppModel.self) private var app
    @State private var bridgeText = ""
    @State private var editingBridge = false
    @State private var bridgeRejected = false
    @State private var removingBridge = false

    private var voice: VoiceModel { app.voice }

    var body: some View {
        if let ms = voice.lastTurnMS {
            LabeledContent { Text(verbatim: "\(ms) ms") } label: { SettingsLabel("Last Answer", systemImage: "timer") }
        }
        if let bridge = voice.bridge, !editingBridge {
            LabeledContent { Text(bridge.display).font(.footnote.monospaced()) } label: { SettingsLabel("Mac Voice Bridge", systemImage: "macbook") }
            Button { bridgeText = bridge.base.absoluteString; bridgeRejected = false; editingBridge = true } label: {
                SettingsRow(title: "Change Address", symbol: "pencil")
            }
            // The address carries the bridge's secret and is kept through a reinstall (SettingsVault):
            // removing it here is the only way to take it off the iPhone.
            Button(role: .destructive) { removingBridge = true } label: {
                SettingsRow(title: "Remove Address", symbol: "trash")
            }
            .accessibilityIdentifier("voice.bridge.remove")
            .confirmationDialog("Remove the Mac voice bridge address?", isPresented: $removingBridge, titleVisibility: .visible) {
                Button("Remove Address", role: .destructive) {
                    voice.removeBridge()
                    bridgeText = ""
                    // Now, not a second later: Poki closed in between would get the address back at its next launch.
                    SettingsVault.save()
                }
            } message: {
                Text("Talk with Poki then needs an OpenAI API key, or the address entered again.")
            }
        } else {
            TextField("Mac voice bridge address", text: $bridgeText)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.body.monospaced())
                .onSubmit(saveBridge)
            Button(action: saveBridge) { SettingsRow(title: "Save Address", symbol: "checkmark") }
                .disabled(bridgeText.trimmingCharacters(in: .whitespaces).isEmpty)
            Text(bridgeRejected ? "That is not a voice bridge address. It looks like http://192.168.1.10:47830/voice/ followed by a long code." : "Optional, for live voice without an OpenAI key on this iPhone. Run bin/voice-bridge.mjs on your Mac and enter the address it gives.")
                .font(.footnote).foregroundStyle(bridgeRejected ? Color.orange : Color.secondary)
        }
    }

    private func saveBridge() {
        bridgeRejected = !voice.setBridge(bridgeText)
        if !bridgeRejected { editingBridge = false }
    }
}

private extension View {
    /// Liquid Glass on iOS 26; the bordered prominent style before it.
    @ViewBuilder func prominentGlass() -> some View {
        if #available(iOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }
}
