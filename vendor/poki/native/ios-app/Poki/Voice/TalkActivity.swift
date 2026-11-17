import Foundation

// A talk that shows on the Live Activity and can be ended there is the interaction of pull request #250;
// the code is written here. The talk goes into the state's existing `voice` field, follows the talk's
// phase, and takes the Live Activity with it when it ends only if nothing else is on it.

/// The Live Activity during a talk with Poki, in front and while a step of the talk has Poki in another
/// app: it says whether Poki is listening, working or speaking, and its End ends the talk.
@MainActor
final class TalkActivity {
    private let voice: VoiceModel
    private let activity: ActivityController
    private let deviceName: @MainActor () -> String
    /// Poki is on: its Live Activity stays when the talk ends.
    private let keepsActivity: @MainActor () -> Bool
    private var shown: PokiState.Voice?
    /// What EndTalkIntent's notification reaches; it holds this weakly, so an ended TalkActivity hears nothing.
    private let mailbox: Mailbox

    init(voice: VoiceModel, activity: ActivityController, deviceName: @escaping @MainActor () -> String,
         keepsActivity: @escaping @MainActor () -> Bool) {
        self.voice = voice
        self.activity = activity
        self.deviceName = deviceName
        self.keepsActivity = keepsActivity
        mailbox = Mailbox()
        mailbox.owner = self
        mailbox.listen()
        follow()
    }

    /// The talk's state as the Live Activity says it: nil while no talk is on.
    static func state(of voice: VoiceModel) -> PokiState.Voice? {
        guard voice.isOn else { return nil }
        switch voice.phase {
        case .off, .lost: return nil
        case .connecting, .listening, .hearing: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        }
    }

    private func follow() {
        withObservationTracking { show(Self.state(of: voice)) } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func show(_ talk: PokiState.Voice?) {
        guard talk != shown else { return }
        let started = shown == nil
        shown = talk
        activity.update { $0.voice = talk }
        // Started from a tap in Poki, the one time iOS lets a Live Activity start.
        if started, talk != nil { activity.start(deviceName: deviceName()) }
        // Only a Live Activity that shows nothing else goes with the talk: an approval, a hand-off, a
        // problem, pairing or setup stays.
        if talk == nil, !keepsActivity(), activity.state.phase == .idle { activity.end() }
    }

    fileprivate func endFromLiveActivity() {
        guard voice.isOn else { return }
        AppLog.shared.add("voice", "the talk was ended from the Live Activity")
        voice.stop()
    }

    private final class Mailbox {
        weak var owner: TalkActivity?

        func listen() {
            let observer = Unmanaged.passUnretained(self).toOpaque()
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, _, _, _ in
                guard let observer else { return }
                let mailbox = Unmanaged<Mailbox>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in mailbox.owner?.endFromLiveActivity() }
            }, TalkSignal.end as CFString, nil, .deliverImmediately)
        }

        deinit {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                               CFNotificationName(TalkSignal.end as CFString), nil)
        }
    }
}
