import XCTest
@testable import Amore134Components

final class Amore138ComposerTests: XCTestCase {
    private func action(wait: Bool = false, processing: Bool = false, busy: Bool = false,
                        send: Bool = false, queue: Bool = false, call: Bool = true,
                        content: Bool = false, dictation: Bool = false,
                        preparing: Bool = false) -> AmoreComposerPrimaryAction {
        .resolve(waitingForVoice: wait, processing: processing, busy: busy, canSend: send,
                 canEnqueue: queue, offersCall: call, hasContent: content,
                 voiceInputActive: dictation, preparingCall: preparing)
    }
    func testOnlyIdleEmptySlotCalls() {
        XCTAssertEqual(action(),.call)
        XCTAssertEqual(action(content: true),.send)
        XCTAssertEqual(action(send: true,content: true),.send)
        XCTAssertEqual(action(call: false),.send)
        XCTAssertEqual(action(dictation: true),.send)
        XCTAssertEqual(action(preparing: true),.preparingCall)
    }
    func testBusyAndQueuedTasksKeepOriginalControls() {
        XCTAssertEqual(action(processing: true,busy: true),.stop)
        XCTAssertEqual(action(processing: true,busy: true,queue: true,content: true),.queue)
        XCTAssertEqual(action(busy: true),.stop)
        XCTAssertEqual(action(busy: true,send: true,content: true),.send)
    }
    func testFinishingVoiceNeverBecomesACall() {
        XCTAssertEqual(action(wait: true),.transcribing)
        XCTAssertEqual(action(wait: true,processing: true,busy: true,queue: true,preparing: true),.transcribing)
    }
    func testAttachmentPresenceDoesNotDependOnModelReadiness() {
        XCTAssertEqual(action(content: true),.send,"Attachment with no model must show disabled Send, not call")
        XCTAssertEqual(action(processing: true,busy: true,content: true),.stop)
    }
    func testCompleteBooleanMatrixHasNoUnsafeCallState() {
        for mask in 0..<1024 {
            let flags=(0..<10).map { mask & (1 << $0) != 0 }
            let result=action(wait: flags[0],processing: flags[1],busy: flags[2],send: flags[3],queue: flags[4],call: flags[5],content: flags[6],dictation: flags[7],preparing: flags[8])
            if result == .call {
                XCTAssertTrue(flags[5]);XCTAssertFalse(flags[0] || flags[1] || flags[2] || flags[6] || flags[7] || flags[8])
            }
        }
    }
}
