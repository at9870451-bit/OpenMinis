import XCTest
@testable import Amore134Components

final class Amore136DeviceStateTests: XCTestCase {
    func testPairingPresenceNeverMeansConnected() {
        XCTAssertEqual(AmoreDeviceStatus.classify(pairingPresent: true, pairingRejected: false, developerMode: true,
            sessionOn: false, runnerRunning: false, inProcessOpen: false, inProcess: true, channelWorking: false, preparing: false), .disconnected)
    }
    func testWorkingChannelWithoutSessionIsNotCurrentDevice() {
        XCTAssertEqual(AmoreDeviceStatus.classify(pairingPresent: true, pairingRejected: false, developerMode: true,
            sessionOn: false, runnerRunning: false, inProcessOpen: false, inProcess: false, channelWorking: true, preparing: false), .localChannel)
    }
    func testInProcessMustActuallyOpen() {
        XCTAssertNotEqual(AmoreDeviceStatus.classify(pairingPresent: true, pairingRejected: false, developerMode: true,
            sessionOn: true, runnerRunning: true, inProcessOpen: false, inProcess: true, channelWorking: true, preparing: false), .currentDevice)
        XCTAssertEqual(AmoreDeviceStatus.classify(pairingPresent: true, pairingRejected: false, developerMode: true,
            sessionOn: true, runnerRunning: true, inProcessOpen: true, inProcess: true, channelWorking: false, preparing: false), .currentDevice)
    }
    func testMissingAndRejectedPairingWinOverOldReadyState() {
        for exists in [false,true] {
            XCTAssertEqual(AmoreDeviceStatus.classify(pairingPresent: exists, pairingRejected: true, developerMode: true,
                sessionOn: true, runnerRunning: true, inProcessOpen: true, inProcess: true, channelWorking: true, preparing: false), .needsPairing)
        }
    }
    func testDeveloperModeAndPreparingStatesAreAccurate() {
        XCTAssertEqual(AmoreDeviceStatus.classify(pairingPresent: true, pairingRejected: false, developerMode: false,
            sessionOn: false, runnerRunning: false, inProcessOpen: false, inProcess: true, channelWorking: false, preparing: true), .waitingDeveloperMode)
        XCTAssertEqual(AmoreDeviceStatus.classify(pairingPresent: true, pairingRejected: false, developerMode: true,
            sessionOn: false, runnerRunning: false, inProcessOpen: false, inProcess: true, channelWorking: false, preparing: true), .preparing)
    }
    func testApprovalRequiresStablePendingIDAndUnexpiredUnsubmittedRequest() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(AmorePendingApproval.canResolve(id: "one", pendingIDs: ["one"], expires: now.addingTimeInterval(1), submitted: false, at: now))
        XCTAssertFalse(AmorePendingApproval.canResolve(id: "other", pendingIDs: ["one"], expires: now.addingTimeInterval(1), submitted: false, at: now))
        XCTAssertFalse(AmorePendingApproval.canResolve(id: "one", pendingIDs: ["one"], expires: now, submitted: false, at: now))
        XCTAssertFalse(AmorePendingApproval.canResolve(id: "one", pendingIDs: ["one"], expires: now.addingTimeInterval(1), submitted: true, at: now))
    }
}
