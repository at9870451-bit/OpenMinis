import SwiftUI
import Combine
import OSLog

// Only test-host environment for the unmodified production ChatSendButton.
// No model/network/timer/device action is started by this view.
struct AppLogger {
    let category: String
    func info(_ text: String) {}
}
@MainActor final class AIChatViewModel: ObservableObject {
    @Published var isProcessing = false
    let sessionId: String? = "composer-probe"
    var stopped: () -> Void = {}
    func stopByUser() { isProcessing = false; stopped() }
}
@MainActor final class AgentJobRegistry: ObservableObject {
    static let shared = AgentJobRegistry()
    @Published var liveScheduled = false
    @Published var activeChildren = false
    func hasLiveScheduledJobs(createdBy: String) -> Bool { liveScheduled }
    func hasActiveChildren(parent: String) -> Bool { activeChildren }
}
@MainActor final class SessionActivityTracker: ObservableObject {
    static let shared = SessionActivityTracker()
    @Published var busy = false
    func isBusy(_ id: String) -> Bool { busy }
}

struct Amore138ComposerProbe: View {
    @StateObject private var vm = AIChatViewModel()
    @ObservedObject private var jobs = AgentJobRegistry.shared
    @ObservedObject private var tracker = SessionActivityTracker.shared
    @State private var text = ""
    @State private var attachment = false
    @State private var dictating = false
    @State private var waiting = false
    @State private var modelReady = true
    @State private var preparing = false
    @State private var action = "none"
    private var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment }
    private var canSend: Bool { modelReady && !vm.isProcessing && (hasContent || dictating) }
    var body: some View {
        VStack(spacing: 16) {
            Text("Production send / call control — inert test actions").font(.caption)
            HStack(spacing: 2) {
                TextField("Type", text: $text).accessibilityIdentifier("probe.composer.text")
                Button { dictating.toggle() } label: { Image(systemName: "mic").frame(width: 44,height: 44) }
                    .accessibilityIdentifier("probe.dictation")
                ChatSendButton(vm: vm, canSend: canSend, canEnqueue: vm.isProcessing && hasContent,
                    isWaitingToSendVoice: waiting,
                    onSend: { action = "send" }, onEnqueue: { action = "queue" },
                    offersVoiceCall: true, hasComposerContent: hasContent,
                    isDictating: dictating, isPreparingVoiceCall: preparing,
                    onVoiceCall: { action = "call" })
            }.padding(8).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 24))
            Text(action).accessibilityIdentifier("probe.lastAction")
            Button("Fill text") { text = "Hello" }.accessibilityIdentifier("probe.fill")
            Button("Clear text") { text = ""; attachment = false }.accessibilityIdentifier("probe.clear")
            Button("Attachment") { attachment.toggle() }.accessibilityIdentifier("probe.attachment")
            Button("Busy") { vm.isProcessing.toggle() }.accessibilityIdentifier("probe.busy")
            Button("Background child") { jobs.activeChildren.toggle() }.accessibilityIdentifier("probe.child")
            Button("Waiting for ASR") { waiting.toggle() }.accessibilityIdentifier("probe.waiting")
            Button("Model ready") { modelReady.toggle() }.accessibilityIdentifier("probe.model")
            Button("Preparing call") { preparing.toggle() }.accessibilityIdentifier("probe.preparing")
        }.padding()
        .onAppear {
            UserDefaults.standard.set(false,forKey: StopConfirmPolicy.settingsKey)
            jobs.activeChildren = false; jobs.liveScheduled = false; tracker.busy = false
            vm.stopped = { action = "stop" }
        }
    }
}
