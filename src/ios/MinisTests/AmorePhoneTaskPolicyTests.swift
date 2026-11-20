import Foundation
import XCTest
@testable import Minis

final class AmorePhoneTaskPolicyTests: XCTestCase {
    func testExplicitAppCommandsArePhoneTasksButQuestionsAreNot() {
        let meituan = ["com.meituan.imeituan"]
        XCTAssertTrue(AmorePhoneTaskPolicy.isPhoneTask("打开美团看看附近外卖", knownAppIDs: meituan))
        XCTAssertTrue(AmorePhoneTaskPolicy.isPhoneTask("请帮我打开闲鱼消息", knownAppIDs: ["com.taobao.fleamarket"]))
        XCTAssertTrue(AmorePhoneTaskPolicy.isPhoneTask("请使用 Amore 已连接的 iPhone 设备工具完成任务。任务：打开微信"))
        XCTAssertFalse(AmorePhoneTaskPolicy.isPhoneTask("美团是什么软件？", knownAppIDs: meituan))
        XCTAssertFalse(AmorePhoneTaskPolicy.isPhoneTask("解释如何打开美团的通知设置", knownAppIDs: meituan))
        XCTAssertFalse(AmorePhoneTaskPolicy.isPhoneTask("打开以下网页", knownAppIDs: []))
    }
    func testMobileTaskNeverFallsBackToComputerTools() {
        let tools = ["device_control", "shell_execute", "browser_use", "subagent_task", "mcp_execute", "memory_get"]
        let allowed = tools.filter { AmorePhoneTaskPolicy.permitsTool($0, isPhoneTask: true) }
        XCTAssertEqual(allowed, ["device_control"])
        XCTAssertEqual(tools.filter { AmorePhoneTaskPolicy.permitsTool($0, isPhoneTask: false) }, tools)
        XCTAssertTrue(ChatExecutionModePolicy.advertisedTools(tools, mode: .pureChat).isEmpty)
    }
}
