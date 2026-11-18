import SwiftUI

/// Settings → chat handoff, draft-only. No model call, photo access or icon
/// write is performed here. New request cannot overwrite an existing draft.
@MainActor
final class AmoreAvatarDraftRouter: ObservableObject {
    static let shared = AmoreAvatarDraftRouter()
    @Published private(set) var targetDraftID: String?
    private var prompt: String?
    private init() {}
    func enqueue(prompt: String, draftID: String) {
        self.prompt = prompt
        targetDraftID = draftID
    }
    func consume(for draftID: String?, composerIsEmpty: Bool) -> String? {
        guard composerIsEmpty, let draftID, draftID == targetDraftID else { return nil }
        let result = prompt
        prompt = nil; targetDraftID = nil
        return result
    }
}
