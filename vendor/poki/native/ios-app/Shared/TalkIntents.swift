import AppIntents
import Foundation

/// End on the Live Activity while you talk with Poki: ends the talk without opening Poki, the same way
/// as End in the message field. The widget runs this in its own process, so it only rings the app, as
/// StopRunnerIntent does; TalkActivity hears the ring and ends the talk. No authentication: ending a
/// talk is always safe. Ending a talk from the island is the interaction of pull request #250; this code
/// is written here, on this file's neighbour StopRunnerIntent.
struct EndTalkIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End talk"
    static let openAppWhenRun = false
    static let isDiscoverable = false
    init() {}
    func perform() async throws -> some IntentResult {
        TalkSignal.ring(TalkSignal.end)
        return .result()
    }
}

/// The Darwin notifications between the Live Activity and the talk in the app. No payload: the name
/// is the message. Under the App Group's name, as ApprovalMailbox's are.
enum TalkSignal {
    static let end = SharedContainer.appGroup + ".talk.end"

    static func ring(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}
