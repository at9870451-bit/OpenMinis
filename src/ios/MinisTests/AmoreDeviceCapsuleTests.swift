import XCTest
import AmoreDeviceKit
@testable import Minis

/// No device connection, pairing data or secrets are touched by these tests.
@MainActor
final class AmoreDeviceCapsuleTests: XCTestCase {
    private func block(_ name: String = "device_control", status: ToolBlockStatus = .running,
                       input: String? = nil, output: String = "") -> AssistantBlock {
        let value = AssistantBlock(kind: .shellTool(command: name), content: output, toolStatus: status)
        value.toolInputArgs = input
        return value
    }

    func testOnlyRealDeviceToolIsEligible() {
        XCTAssertTrue(AmoreDeviceTaskCapsule.isDeviceTool(block()))
        XCTAssertFalse(AmoreDeviceTaskCapsule.isDeviceTool(block("shell_execute")))
        XCTAssertFalse(AmoreDeviceTaskCapsule.isDeviceTool(block("device_control\nlaunch")))
    }

    @available(iOS 18.0, *)
    func testOriginalAppIdentityAndRequestedLaunchParsing() {
        XCTAssertEqual(AmoreCapsuleApps.bundleID(for: "美团"), "com.meituan.imeituan")
        XCTAssertEqual(AmoreCapsuleApps.bundleID(for: "闲鱼"), "com.taobao.fleamarket")
        let call = #"{"action":"do","arguments_json":"{\"actions\":[{\"launch\":\"com.meituan.itakeaway\"},{\"launch\":{\"bundle\":\"com.taobao.fleamarket\"}}]}"}"#
        XCTAssertEqual(AmoreCapsuleApps.requestedLaunches(deviceToolArguments: call),
                       ["com.meituan.itakeaway", "com.taobao.fleamarket"])
        XCTAssertTrue(AmoreCapsuleApps.requestedLaunches(deviceToolArguments: #"{"action":"status"}"#).isEmpty)
        XCTAssertTrue(AmoreCapsuleApps.requestedLaunches(deviceToolArguments: #"{"action":"do","arguments_json":"not json"}"#).isEmpty)
        XCTAssertTrue(AmoreCapsuleApps.requestedLaunches(deviceToolArguments: nil).isEmpty)
    }

    func testToolStateIsNotFabricatedByShortcut() {
        let fake = block("shell_execute", status: .success,
                         input: #"{"action":"do","arguments_json":"{\"actions\":[{\"launch\":\"com.taobao.fleamarket\"}]}"}"#)
        XCTAssertFalse(AmoreDeviceTaskCapsule.isDeviceTool(fake))
        let real = block(status: .failed(message: "not_sent"), input: fake.toolInputArgs,
                         output: "not_sent: Device is not ready; no device action was executed.")
        XCTAssertTrue(AmoreDeviceTaskCapsule.isDeviceTool(real))
    }
}
