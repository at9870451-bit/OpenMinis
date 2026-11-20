import Foundation

/// Explicit iPhone task routing. Ordinary questions (including questions ABOUT
/// apps) remain regular Amore chat. Only a user command to operate a known app,
/// or a phone-shortcut draft the owner elected to send, opts into this policy.
enum AmorePhoneTaskPolicy {
    static let instruction = """
    This request operates apps on THIS iPhone, never the host's Linux shell or a computer browser. The only action tool is device_control, backed by the original PokiCore/PKInProcess module. For a known app, use device_control do with {"actions":[{"launch":"iOS bundle ID"}]}, then look to read the real screen; continue with numbered tap/type/swipe and verify the result. An app icon or 50 ms Remote Pairing hello does NOT prove launch or automation readiness. If a bundle ID fails, inspect Home/Spotlight through device_control instead of claiming the app is missing. Do not invent success or bypass pairing, Developer Mode, DDI, system authorization, app login or owner approvals. Report not_sent, failure and waiting-for-owner truthfully. Never substitute shell_execute, browser_use, MCP, subagents or computer tools for phone actions.
    """
    private static let commands = ["打开", "打開", "启动", "啟動", "进入", "進入", "操作", "使用", "查看", "检查", "檢查", "在", "用", "切换到", "切換到", "open ", "launch ", "use ", "check ", "navigate to "]
    static func isPhoneTask(_ message: String, knownAppIDs: [String] = []) -> Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.hasPrefix("请使用 Amore 已连接的 iPhone 设备工具完成任务。") ||
           text.hasPrefix("Use Amore's connected iPhone device tools.") { return true }
        let prefixes = ["请帮我", "請幫我", "帮我", "幫我", "请", "請"]
        let task = prefixes.first(where: { text.hasPrefix($0) }).map { String(text.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) } ?? text
        let lowered = task.lowercased()
        let asksAction = commands.contains { lowered.hasPrefix($0) }
        return asksAction && (!knownAppIDs.isEmpty || task.hasPrefix("操作这台手机") || task.hasPrefix("打开手机上的"))
    }
    static func permitsTool(_ name: String, isPhoneTask: Bool) -> Bool { !isPhoneTask || name == "device_control" }
}
