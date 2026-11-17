import PokiNative
import PokiCore
import SwiftUI
import UIKit

/// The Debug tab's check of UI automation from Poki's own process (no runner, no port): open the
/// daemon session, tap, type. Every step goes to Poki's log, to the system log (`PokiInProcess`), and
/// to Documents/inprocess-probe.json.
///
/// Launch arguments run it without touching the phone, for a device check from the Mac:
/// `-pokiInProcess self` taps the field below and types into it, then reads it back;
/// `-pokiInProcess later -pokiProbeX 200 -pokiProbeY 300 -pokiProbeDelay 8` waits, then taps that
/// point and types, whatever app is in front by then;
/// `-automationPath runner -pokiInProcess source -pokiProbeDelay 10` waits, then keeps the front app's
/// tree as read by Poki Runner and by Poki's own process;
/// `-pokiInProcess apps -pokiProbeApp BUNDLE` launches that app, launches Settings, activates the app,
/// launches it again and terminates it, noting the front app and its pid after each;
/// `-pokiInProcess tools -pokiProbeApp BUNDLE` runs PokiCore's look and do as an agent would: open
/// the app, tap its first field and type, open Settings and swipe, press Home, looking after each;
/// `-pokiInProcess reopen -pokiProbeRounds 5` closes the session and opens it again that many times in
/// this one process, reading the screen after each open (issue 347), with every step's seconds;
/// `-pokiInProcess lifecycle -pokiProbeRounds 5` runs whole tasks through PokiCore (task, read, end,
/// session closed) that many times, then one whose new session cannot read;
/// `-pokiInProcess delivery` reopens the session, then taps and types in Poki and in Settings and
/// brings Poki back, saying which of those arrived;
/// `-pokiInProcess gym` runs the whole Poki Gym scorecard (native/ios-gym/check) through PokiCore on
/// this path, answering approvals as the owner would, into Documents/gym-scorecard.txt and
/// Documents/gym-pictures (the gym workflow's scorecard-inprocess job).
@MainActor
final class InProcessProbe: ObservableObject {
    static let shared = InProcessProbe()
    static let sample = "poki123 AbC 中文24680"

    @Published private(set) var lines: [String] = []
    @Published private(set) var running = false
    @Published var x = "201"
    @Published var y = "437"
    @Published var delay = "8"
    weak var field: UITextField?

    let queue = DispatchQueue(label: "poki.inprocess.probe", qos: .userInitiated)
    private var record: [[String: Any]] = []

    func startFromLaunchArguments(model: AppModel) {
        let defaults = UserDefaults.standard
        guard let mode = defaults.string(forKey: "pokiInProcess") else { return }
        if let v = defaults.string(forKey: "pokiProbeX") { x = v }
        if let v = defaults.string(forKey: "pokiProbeY") { y = v }
        if let v = defaults.string(forKey: "pokiProbeDelay") { delay = v }
        Task {
            // The field has to be on screen for the self test.
            try? await Task.sleep(for: .seconds(1.5))
            switch mode {
            case "self": await selfTest()
            case "later": await later()
            case "read": await readOnly()
            case "separate": await separateTrial()
            case "delivery": await deliveryCheck()
            case "lifecycle": await lifecycleCheck(model: model, rounds: defaults.integer(forKey: "pokiProbeRounds") > 0 ? defaults.integer(forKey: "pokiProbeRounds") : 5)
            case "reopen": await reopenCycle(rounds: defaults.integer(forKey: "pokiProbeRounds") > 0 ? defaults.integer(forKey: "pokiProbeRounds") : 5)
            case "port": await portCheck()
            case "source": await sourceBothPaths(model: model)
            case "apps": await appsCycle(defaults.string(forKey: "pokiProbeApp") ?? "local.pokimcp.fixture")
            case "tools": await toolsCycle(model: model, app: defaults.string(forKey: "pokiProbeApp") ?? "local.pokimcp.fixture")
            case "workspace", "workspace-input": await workspaceRead(model: model, testInput: mode == "workspace-input")
            case "workspace-fullscreen": await workspaceRead(model: model, testInput: true, fullScreen: true)
            case "workspace-layout": await workspaceLayout(model: model)
            case "workspace-drag": await workspaceDrag(model: model)
            case "workspace-owner": await workspaceOwner(model: model)
            case "workspace-cancel": await workspaceCancel(model: model)
            case "workspace-adjacent": await workspaceAdjacent(model: model)
            case "gym": await gymScorecard(model: model)
            case "chat", "workspace-chat", "workspace-model", "fullscreen-model":
                await chatCycle(model: model, inSplitView: mode.hasPrefix("workspace-"), configuredModel: mode.hasSuffix("-model"))
            case "web": await WebDemo.run()
            case "bench": await benchmark(model: model, rounds: defaults.integer(forKey: "pokiBenchRounds") > 0 ? defaults.integer(forKey: "pokiBenchRounds") : 5)
            default: await prepareOnly()
            }
        }
    }

    func prepareOnly() async {
        guard begin("prepare") else { return }
        _ = await prepare()
        end()
    }

    func readOnly() async {
        guard begin("read") else { return }
        defer { end() }
        guard await prepare() else { return }
        await read()
    }

    private func read() async {
        let result = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            queue.async { c.resume(returning: PKInProcess.shared().readProbe()) }
        }
        let parts = result.keys.sorted().map { "\($0)=\(result[$0]!)" }.joined(separator: " ")
        note("read: \(parts)", result.merging(["step": "read"]) { a, _ in a })
    }

    /// Taps Poki's own empty field, which focuses it only if the tap arrived, types the sample and
    /// reads the field back.
    func selfTest() async {
        guard begin("self test") else { return }
        defer { end() }
        guard await prepare(), let field else { return }
        field.text = ""
        field.resignFirstResponder()
        try? await Task.sleep(for: .seconds(0.4))
        let frame = field.convert(field.bounds, to: nil)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let pasteboard = UIPasteboard.general.changeCount
        let tap = await touch([[PKTouchPoint.at(point, offset: 0), PKTouchPoint.at(point, offset: 0.05)]], "tap at [\(Int(point.x)), \(Int(point.y))]")
        try? await Task.sleep(for: .seconds(0.6))
        note("tap landed: field focused = \(field.isFirstResponder)", ["step": "tap_check", "focused": field.isFirstResponder])
        guard tap.delivery == .sent else { return }
        let typed = await type(Self.sample)
        try? await Task.sleep(for: .seconds(0.6))
        let value = field.text ?? ""
        let same = value == Self.sample
        note("read back: \(same ? "same as sent" : "differs (\(value.count) characters)"); clipboard \(UIPasteboard.general.changeCount == pasteboard ? "unchanged" : "changed")",
             ["step": "read_back", "same": same, "characters": value.count, "clipboard_unchanged": UIPasteboard.general.changeCount == pasteboard, "type_delivery": typed.delivery.rawValue])
    }

    /// For another app in front: waits, then taps the point (or, with x "field", the first text or
    /// search field in the front app's tree) and types the sample there, then reads the focused
    /// field back through the in-process tree.
    func later() async {
        guard begin("tap and type later") else { return }
        defer { end() }
        guard await prepare() else { return }
        let seconds = Double(delay) ?? 8
        let background = UIApplication.shared.beginBackgroundTask(withName: "In-process probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        note("waiting \(Int(seconds)) s; bring the app to try to the front", ["step": "wait", "seconds": seconds])
        try? await Task.sleep(for: .seconds(seconds))
        note("app state: \(UIApplication.shared.applicationState == .active ? "Poki in front" : "Poki in the background")", ["step": "state", "active": UIApplication.shared.applicationState == .active])
        var point = CGPoint(x: Double(x) ?? 201, y: Double(y) ?? 437)
        if x == "field" {
            guard let found = await frontField() else { note("no text or search field in the front app's tree", ["step": "field_missing"]); return }
            point = found
        }
        let tap = await touch([[PKTouchPoint.at(point, offset: 0), PKTouchPoint.at(point, offset: 0.05)]], "tap at [\(Int(point.x)), \(Int(point.y))]")
        guard tap.delivery == .sent else { return }
        try? await Task.sleep(for: .seconds(1.0))
        _ = await type(Self.sample)
        try? await Task.sleep(for: .seconds(0.8))
        let value = await focusedValue()
        // A field that already held text (a fixture app kept running since an earlier check) ends with
        // the sample instead of equalling it.
        let appended = value.map { $0 != Self.sample && $0.hasSuffix(Self.sample) } ?? false
        note("read back in the front app: \(value == Self.sample ? "same as sent" : appended ? "sent text appended to what the field held" : value.map { "differs (\($0.count) characters)" } ?? "no focused field")",
             ["step": "read_back_front", "same": value == Self.sample, "appended": appended, "focused": value != nil, "characters": value?.count ?? 0])
        await read()
    }

    func appsCycle(_ bundle: String) async {
        guard begin("open, switch and close \(bundle)") else { return }
        defer { end() }
        guard await prepare() else { return }
        let background = UIApplication.shared.beginBackgroundTask(withName: "In-process probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        for (action, target) in [("launch", bundle), ("launch", "com.apple.Preferences"), ("activate", bundle), ("launch", bundle), ("terminate", bundle)] {
            let result = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
                queue.async {
                    let t = ProcessInfo.processInfo.systemUptime
                    let code = PKInProcess.shared().app(target, action: action)
                    Thread.sleep(forTimeInterval: 1)
                    let front = PKInProcess.shared().frontApp()
                    c.resume(returning: ["code": code ?? "", "seconds": ProcessInfo.processInfo.systemUptime - t,
                                         "front": front["bundleId"] as? String ?? "", "front_pid": front["pid"] as? Int ?? 0])
                }
            }
            note("\(action) \(target): \((result["code"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "done"), front \(result["front"] ?? "?") pid \(result["front_pid"] ?? 0)",
                 result.merging(["step": "app", "action": action, "bundle": target]) { a, _ in a })
        }
    }

    func toolsCycle(model: AppModel, app bundle: String) async {
        guard begin("look and do through PokiCore") else { return }
        defer { end() }
        guard await prepare() else { return }
        model.inProcessReadyForProbe()
        let background = UIApplication.shared.beginBackgroundTask(withName: "In-process probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        func call(_ label: String, _ name: String, _ arguments: String) async -> String {
            let t = ProcessInfo.processInfo.systemUptime
            let result = await model.phoneTool(name, arguments: arguments)
            let head = result.text.split(separator: "\n").prefix(3).joined(separator: " | ")
            note("\(label): \(result.isError ? "failed" : "ok") \(head.prefix(200))",
                 ["step": "tool", "label": label, "tool": name, "error": result.isError, "seconds": ProcessInfo.processInfo.systemUptime - t, "text": String(result.text.prefix(4000))])
            return result.text
        }
        _ = await call("look first", "look", "{}")
        _ = await call("open the app", "do", "{\"actions\":[{\"launch\":\"\(bundle)\"}]}")
        if let field = await frontField() {
            _ = await call("tap the field and type", "do", "{\"actions\":[{\"tap\":[\(Int(field.x)),\(Int(field.y))]},{\"type\":\"\(Self.sample)\"}]}")
        } else {
            note("no field in the app's tree", ["step": "field_missing"])
        }
        let typed = await call("look after typing", "look", "{}")
        note("the typed text \(typed.contains(Self.sample) ? "is" : "is not") on the screen", ["step": "typed_seen", "seen": typed.contains(Self.sample)])
        _ = await call("open Settings", "do", "{\"actions\":[{\"launch\":\"com.apple.Preferences\"}]}")
        let before = await call("look before the swipe", "look", "{}")
        _ = await call("swipe up", "do", "{\"actions\":[{\"swipe\":\"up\"}]}")
        let after = await call("look after the swipe", "look", "{}")
        note("the swipe \(before == after ? "did not change" : "changed") the screen", ["step": "swipe_seen", "changed": before != after])
        _ = await call("press Home", "do", "{\"actions\":[{\"button\":\"home\"}]}")
        let home = await call("look at Home", "look", "{}")
        let front = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in queue.async { c.resume(returning: PKInProcess.shared().frontApp()) } }
        note("after Home the front app is \(front["bundleId"] as? String ?? "?")", ["step": "home_seen", "bundle": front["bundleId"] as? String ?? "", "look_mentions_home": home.lowercased().contains("springboard") || home.contains("Home")])
    }

    /// On a Duo, put an empty test note and Settings › General side by side after preparing.
    private func workspaceRead(model: AppModel, testInput: Bool, fullScreen: Bool = false) async {
        guard begin("Duo workspace") else { return }
        defer { end() }
        guard await prepare() else { return }
        model.inProcessReadyForProbe()
        _ = await model.phoneTool("look", arguments: "{}") // Open PokiCore's session before backgrounding.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Duo workspace probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        try? await Task.sleep(for: .seconds(Double(delay) ?? 8))
        func call(_ name: String, _ arguments: String, _ label: String) async -> PokiCore.ToolAnswer {
            let start = ProcessInfo.processInfo.systemUptime
            let output = await model.phoneToolWithPicture(name, arguments: arguments)
            let header = output.text.split(separator: "\n").first.map(String.init) ?? ""
            let status = output.text.split(separator: "\n").first { $0.hasPrefix("error:") || $0.hasPrefix("did:") } ?? ""
            note("workspace \(label): \(header) \(status)", ["step": name, "label": label, "error": output.isError,
                 "picture": output.jpeg != nil, "text": header, "seconds": ProcessInfo.processInfo.systemUptime - start])
            return output
        }
        let first = await call("look", fullScreen ? "{}" : "{\"pane\":\"left\"}", "first read")
        guard !first.isError else { return }
        let second: PokiCore.ToolAnswer
        if fullScreen {
            second = await call("do", "{\"actions\":[{\"launch\":\"com.apple.Preferences\"}],\"full\":true}", "open Settings")
        } else {
            second = await call("look", "{\"pane\":\"right\"}", "second read")
        }
        guard !second.isError else { return }
        let settingsOnLeft = !fullScreen && first.text.hasPrefix("app: 设置")
        let settings = settingsOnLeft && testInput ? await call("look", "{\"pane\":\"left\"}", "select Settings") : second
        if testInput, settings.text.hasPrefix("app: 设置"),
           let row = settings.text.split(separator: "\n").first(where: { $0.contains("\"隔空投送\"") }),
           let ref = Int(row.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)) {
            _ = await call("do", "{\"actions\":[{\"tap\":\(ref)}]}", "open AirDrop page")
        }
        let editor: PokiCore.ToolAnswer
        if fullScreen {
            editor = await call("do", "{\"actions\":[{\"launch\":\"com.apple.mobilenotes\"}]}", "open Notes")
        } else {
            let editorSide = settingsOnLeft ? "right" : "left"
            editor = await call("look", "{\"pane\":\"\(editorSide)\"}", "Notes read")
        }
        guard testInput, !editor.isError, editor.text.hasPrefix("app: 备忘录") else { return }
        let tap = await call("do", "{\"actions\":[{\"tap\":[180,150]}]}", "Notes editor focus")
        guard !tap.isError else { return }
        _ = await call("do", "{\"actions\":[{\"type\":\"Duo test\"}]}", "Notes typing")
    }

    private func workspaceLayout(model: AppModel) async {
        guard begin("Duo layout change") else { return }
        defer { end() }
        guard await prepare() else { return }
        model.inProcessReadyForProbe()
        _ = await model.phoneTool("look", arguments: "{}")
        let background = UIApplication.shared.beginBackgroundTask(withName: "Duo layout probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        try? await Task.sleep(for: .seconds(Double(delay) ?? 8))
        let pane = await model.phoneTool("look", arguments: "{\"pane\":\"left\"}")
        note("workspace layout read left: \(!pane.isError)", ["step": "read", "ok": !pane.isError])
        guard !pane.isError, pane.text.hasPrefix("app: 备忘录") else { return }
        let keys = await model.phoneTool("do", arguments: "{\"actions\":[{\"type\":\"Duo focus test\"}]}")
        let sentKeys = keys.text.contains("(sent,")
        note("workspace key input before focus: \(sentKeys ? "sent" : "refused")", ["step": "focus", "refused": !sentKeys])
        note("workspace layout ready to collapse", ["step": "wait"])
        try? await Task.sleep(for: .seconds(18))
        let result = await model.phoneTool("do", arguments: "{\"actions\":[{\"tap\":[180,150]}]}")
        let refused = result.text.contains("split_view_changed") || result.text.contains("nothing was sent") || result.text.contains("(not_sent,")
        note("workspace stale tap: \(refused ? "refused" : "unexpected result")", ["step": "stale_tap", "refused": refused])
    }

    private func workspaceOwner(model: AppModel) async {
        guard begin("workspace task isolation") else { return }
        defer { end() }
        guard await prepare() else { return }
        model.inProcessReadyForProbe()
        _ = await model.phoneTool("look", arguments: "{}")
        let background = UIApplication.shared.beginBackgroundTask(withName: "Duo owner probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        note("workspace owner ready", ["step": "workspace_ready"])
        try? await Task.sleep(for: .seconds(Double(delay) ?? 8))
        let owner = UUID().uuidString
        let read = await model.runTool("look", arguments: "{\"pane\":\"left\"}", localSession: owner)
        guard !read.isError, read.jpeg != nil else { note("workspace owner could not read", ["step": "owner_read", "ok": false]); return }
        let outside = await model.phoneToolWithPicture("look", arguments: "{\"pane\":\"right\"}")
        let refused = outside.isError && outside.jpeg == nil && outside.text.contains("another task is using Split View")
        note("workspace owner excludes other callers: \(refused)", ["step": "owner_exclusive", "ok": refused])
        await model.finishSplitViewTask(localSession: owner)
        let released = await model.phoneToolWithPicture("look", arguments: "{\"pane\":\"right\"}")
        note("workspace owner released: \(!released.isError && released.jpeg != nil)", ["step": "owner_release", "ok": !released.isError && released.jpeg != nil])
        model.finishTask()
    }

    /// Uses the public-photo fixture and cancels a drop into Safari while it waits for approval.
    private func workspaceCancel(model: AppModel) async {
        guard begin("workspace approval cancellation") else { return }
        defer { end() }
        guard await prepare() else { return }
        model.inProcessReadyForProbe()
        _ = await model.phoneTool("look", arguments: "{}")
        let background = UIApplication.shared.beginBackgroundTask(withName: "Duo cancel probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        note("workspace cancel ready", ["step": "workspace_ready"])
        try? await Task.sleep(for: .seconds(Double(delay) ?? 8))
        let owner = UUID().uuidString
        let right = await model.runTool("look", arguments: "{\"pane\":\"right\",\"full\":true}", localSession: owner)
        let left = await model.runTool("look", arguments: "{\"pane\":\"left\",\"full\":true}", localSession: owner)
        guard !right.isError, right.text.contains("The Blue Marble"), !left.isError,
              left.text.contains("Duo Attachment Replay"), left.text.contains("Split View: left is com.apple.mobilenotes") else {
            note("workspace cancel fixture not visible", ["step": "fixture_missing"])
            await model.finishSplitViewTask(localSession: owner)
            return
        }
        var requested: PendingApproval?
        model.onProbeApproval = { requested = $0 }
        defer { model.onProbeApproval = nil }
        let action = "{\"actions\":[{\"drag\":{\"from\":[180,250],\"to\":[180,300],\"to_pane\":\"right\"}}]}"
        let call = Task { await model.runTool("do", arguments: action, localSession: owner) }
        for _ in 0..<60 where requested == nil { try? await Task.sleep(for: .milliseconds(50)) }
        call.cancel()
        let result = await call.value
        await model.finishSplitViewTask(localSession: owner)
        let status = await model.runTool("status", arguments: "{}")
        let pending = status.text.contains("approval waiting on the phone:")
        note("workspace cancel asked: \(requested != nil), cancelled: \(result.isError), pending: \(pending)",
             ["step": "workspace_cancel", "asked": requested != nil, "cancelled": result.isError, "pending": pending])
    }

    private func workspaceDrag(model: AppModel) async {
        guard begin("workspace image drop") else { return }
        defer { end() }
        guard await prepare() else { return }
        model.inProcessReadyForProbe()
        _ = await model.phoneTool("look", arguments: "{}")
        let background = UIApplication.shared.beginBackgroundTask(withName: "Duo drag probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        note("workspace drag ready", ["step": "workspace_ready"])
        try? await Task.sleep(for: .seconds(Double(delay) ?? 8))
        func run(_ name: String, _ arguments: String, _ label: String) async -> PokiCore.ToolAnswer {
            let result = await model.phoneToolWithPicture(name, arguments: arguments)
            let outcome = result.text.split(separator: "\n").prefix(3)
                .filter { $0.hasPrefix("app:") || $0.hasPrefix("did:") || $0.hasPrefix("error:") }
                .map(String.init).joined(separator: "\n")
            note("workspace drag \(label) \(!result.isError)", ["step": label, "ok": !result.isError, "outcome": outcome])
            return result
        }
        let target = await run("look", "{\"pane\":\"left\"}", "destination")
        guard !target.isError, target.text.hasPrefix("app: 备忘录") else { return }
        let source = await run("look", "{\"pane\":\"right\",\"full\":true}", "source")
        guard !source.isError, source.text.hasPrefix("app: Safari") || source.text.hasPrefix("app: Chrome") else { return }
        let defaults = UserDefaults.standard
        let from: JSON
        if let imageTitle = defaults.string(forKey: "pokiProbeImage"), !imageTitle.isEmpty {
            let matches = source.text.split(separator: "\n").compactMap { line -> Int? in
                guard line.contains(" Image "), line.localizedCaseInsensitiveContains(imageTitle) else { return nil }
                return Int(line.drop(while: { !$0.isNumber }).prefix(while: \.isNumber))
            }
            guard matches.count == 1, let image = matches.first else {
                note("workspace image target not unique", ["step": "source_image", "matches": matches.count])
                return
            }
            note("workspace image located by accessibility label", ["step": "source_image", "matches": 1])
            from = .number(Double(image))
        } else {
            from = [.number(Double(x) ?? 200), .number(Double(y) ?? 250)]
        }
        let hold = defaults.double(forKey: "pokiProbeDragHold")
        let arguments: JSON = ["actions": [["drag": ["from": from, "to": [170, 120], "to_pane": "left",
                                                     "hold_ms": .number(hold > 0 ? hold : 360), "ms": 1050]]]]
        let drop = await run("do", arguments.serialized(), "drop")
        guard !drop.isError else { return }
        let after = await run("look", "{\"pane\":\"left\",\"full\":true}", "verify")
        let evidence = after.text.split(separator: "\n").first { $0.hasPrefix("Split View drop:") }
        note("workspace drag destination read after drop", ["step": "attachment_read", "evidence": evidence.map(String.init) ?? ""])
        model.finishTask()
    }

    private func workspaceAdjacent(model: AppModel) async {
        guard begin("Poki beside Settings") else { return }
        defer { end() }
        guard await prepare() else { return }
        model.inProcessReadyForProbe()
        try? await Task.sleep(for: .seconds(Double(delay) ?? 8))
        let read = await model.phoneToolWithPicture("look", arguments: "{}")
        let ok = !read.isError && read.jpeg != nil && read.text.hasPrefix("app: 设置")
        note("workspace adjacent Settings read: \(ok)", ["step": "adjacent_read", "ok": ok])
        guard ok else { return }
        let tap = await model.phoneTool("do", arguments: "{\"actions\":[{\"tap\":[180,582]}]}")
        let sent = tap.text.contains("(sent,")
        note("workspace adjacent Settings tap: \(sent)", ["step": "adjacent_tap", "ok": sent])
    }

    private func frontField() async -> CGPoint? {
        await withCheckedContinuation { (c: CheckedContinuation<CGPoint?, Never>) in
            queue.async {
                var code: NSString?
                guard let xml = PKInProcess.shared().sourceXML(nil, code: &code),
                      let match = xml.firstMatch(of: /<XCUIElementType(?:SearchField|TextField|TextView)\b[^>]*? x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"/),
                      let fx = Double(match.1), let fy = Double(match.2), let w = Double(match.3), let h = Double(match.4), w > 0, h > 0 else { c.resume(returning: nil); return }
                c.resume(returning: CGPoint(x: fx + w / 2, y: fy + h / 2))
            }
        }
    }

    private func focusedValue() async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            queue.async {
                var code: NSString?
                var focus: NSDictionary?
                _ = PKInProcess.shared().sourceXML(&focus, code: &code)
                c.resume(returning: focus?["value"] as? String)
            }
        }
    }

    /// Whether ending a session ends the Automation Running banner: a session of its own (not the
    /// shared one), one tap, a hold, then its connection closed. Only meaningful in a fresh process.
    func separateTrial() async {
        guard begin("separate session trial") else { return }
        defer { end() }
        let point = CGPoint(x: Double(x) ?? 201, y: Double(y) ?? 437)
        let hold = Double(delay) ?? 8
        note("separate session: open, Automation Mode, tap [\(Int(point.x)), \(Int(point.y))], hold \(Int(hold)) s, close", ["step": "separate_start"])
        let result = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            queue.async { c.resume(returning: PKInProcess.shared().separateSessionTrial(at: point, hold: hold)) }
        }
        let line = result.keys.sorted().map { "\($0)=\(result[$0].map { "\($0)" } ?? "")" }.joined(separator: " ")
        note("separate session: \(line); watch whether the banner goes now", (["step": "separate_result"] as [String: Any]).merging(result) { a, _ in a })
    }

    /// Issue 347's check: the session is closed (the banner goes) and opened again in this same
    /// process, `rounds` times, and after each open the front app, its tree and a picture must all
    /// read. Each step's seconds are kept, so the same run measures how fast stop and start are. The
    /// 2 s after a close are for the person watching to see the banner go, not for the session.
    func reopenCycle(rounds: Int = 5) async {
        guard begin("close and reopen, \(rounds) rounds") else { return }
        defer { end() }
        guard await prepare() else { return }
        await read()
        var passed = 0
        for round in 1...max(1, rounds) {
            let closed = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
                queue.async { c.resume(returning: PKInProcess.shared().close()) }
            }
            note(String(format: "round %d close: %@ in %.3f s (%@)", round, (closed["closed"] as? Bool) == true ? "closed" : "nothing open",
                        (closed["seconds"] as? Double) ?? 0, closed["detail"] as? String ?? ""),
                 (["step": "reopen_close", "round": round] as [String: Any]).merging(closed) { a, _ in a })
            try? await Task.sleep(for: .seconds(2))
            let started = ProcessInfo.processInfo.systemUptime
            let opened = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
                queue.async { c.resume(returning: PKInProcess.shared().prepare()) }
            }
            guard (opened["ok"] as? Bool) == true else {
                note("round \(round) open: failed: \(opened["code"] ?? "?") \(opened["detail"] ?? "")", (["step": "reopen_open", "round": round] as [String: Any]).merging(opened) { a, _ in a })
                continue
            }
            let readStarted = ProcessInfo.processInfo.systemUptime
            let screen = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
                queue.async { c.resume(returning: PKInProcess.shared().readProbe()) }
            }
            let done = ProcessInfo.processInfo.systemUptime
            let reads = (screen["front_ok"] as? Bool) == true && (screen["tree_ok"] as? Bool) == true && (screen["picture_ok"] as? Bool) == true
            if reads { passed += 1 }
            var fields: [String: Any] = ["step": "reopen_open", "round": round, "reads": reads, "open_seconds": readStarted - started, "read_seconds": done - readStarted]
            fields.merge(opened) { a, _ in a }
            fields.merge(screen) { a, _ in a }
            note(String(format: "round %d open: generation %@, device %@, open %.3f s (session %.3f, first look %.3f), read %.3f s: %@", round,
                        "\(opened["generation"] ?? "?")", opened["device"] as? String ?? "?", readStarted - started,
                        (opened["seconds"] as? Double) ?? 0, (opened["warm_seconds"] as? Double) ?? 0, done - readStarted,
                        reads ? "front app, \(screen["tree_elements"] ?? 0) elements and a picture" : "NOT READ (\(screen["tree_error"] ?? screen["front_error"] ?? screen["picture_error"] ?? screen["error"] ?? "no front app"))"),
                 fields)
        }
        note("reopen: \(passed) of \(rounds) rounds read the screen after reopening", ["step": "reopen_result", "passed": passed, "rounds": rounds])
    }

    /// Whole tasks, as the chat runs them, in this one process: each round begins a task, reads the
    /// screen through PokiCore (which opens the session), ends the task (which closes the session and
    /// takes iOS's banner away), and waits. Then one round in which the new session is made to fail
    /// its readiness check: the read has to fail with that reason, the session must not be taken as
    /// open then or a few seconds later, and the round after it has to read on a new session.
    func lifecycleCheck(model: AppModel, rounds: Int) async {
        guard begin("task, close, next task (\(rounds) rounds, then a session that cannot read)") else { return }
        defer { end() }
        let background = UIApplication.shared.beginBackgroundTask(withName: "In-process probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        let device = UIDevice.current
        note("build \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?")), \(device.model), iOS \(device.systemVersion)", ["step": "lifecycle_build"])
        var passed = 0, checks = 0
        func check(_ name: String, _ ok: Bool, _ detail: String, _ fields: [String: Any] = [:]) {
            checks += 1
            if ok { passed += 1 }
            note("\(ok ? "PASS" : "FAIL") \(name): \(detail)", fields.merging(["step": "lifecycle_check", "check": name, "ok": ok]) { a, _ in a })
        }
        func generation() async -> UInt64 {
            await withCheckedContinuation { (c: CheckedContinuation<UInt64, Never>) in queue.async { c.resume(returning: PKInProcess.shared().generation()) } }
        }
        /// Waits for a close that iOS answered after close number `after`, at most `seconds`.
        func closed(after: Int, within seconds: Double) async -> (close: AppModel.InProcessClose, seconds: Double)? {
            let started = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - started < seconds {
                if let close = model.lastInProcessClose, close.number > after { return (close, ProcessInfo.processInfo.systemUptime - started) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }
        func tool(_ name: String, _ arguments: String) async -> (text: String, failed: Bool, picture: Bool, seconds: Double) {
            let t = ProcessInfo.processInfo.systemUptime
            let result = await model.runTool(name, arguments: arguments)
            return (result.text, result.isError, result.jpeg != nil, ProcessInfo.processInfo.systemUptime - t)
        }
        func look() async -> (text: String, failed: Bool, picture: Bool, seconds: Double) { await tool("look", "{}") }
        func endTask() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in model.finishTask { c.resume() } }
        }
        /// A task as the chat runs one: look (Poki is in front), open Settings, which answers with the
        /// screen read in Settings, then the end of the task, which brings Poki back and closes the
        /// session. The read counts only with a picture and Settings' elements in it.
        func round(_ name: String) async -> UInt64? {
            model.chatTaskBegan()
            let first = await look()
            let read = await tool("do", #"{"actions":[{"launch":"com.apple.Preferences"}]}"#)
            let now = await generation()
            let elements = read.text.split(separator: "\n").filter { $0.range(of: #"^\D*\d+ \S+ ".*" \[-?\d+,-?\d+,\d+,\d+\]"#, options: .regularExpression) != nil }.count
            let ok = !read.failed && read.picture && read.text.contains("com.apple.Preferences") && elements > 0
            check("\(name) read", ok, "\(ok ? "Settings read" : "NOT read: \(read.text.prefix(160))") in \(String(format: "%.2f", read.seconds)) s (first look \(first.failed ? "failed" : "answered") in \(String(format: "%.2f", first.seconds)) s), \(elements) elements, \(read.picture ? "a picture" : "no picture"), session generation \(now)",
                  ["seconds": read.seconds, "first_look_seconds": first.seconds, "generation": now, "elements": elements, "picture": read.picture, "text": String(read.text.prefix(600))])
            let before = model.lastInProcessClose?.number ?? 0
            let ended = ProcessInfo.processInfo.systemUptime
            await endTask()
            let done = await closed(after: before, within: 15)
            let gone = done.map { $0.close.closed && !model.hasOpenInProcessSession } ?? false
            check("\(name) close", gone, done.map { String(format: "iOS answered the close for %@ %.2f s after the task ended (close took %.2f s): %@; Poki holds %@ session", $0.close.why, ProcessInfo.processInfo.systemUptime - ended, $0.close.seconds, $0.close.closed ? "closed" : "nothing was open", model.hasOpenInProcessSession ? "an open" : "no") } ?? "no close answered within 15 s of the end of the task",
                  ["closed": done?.close.closed ?? false, "close_seconds": done?.close.seconds ?? -1])
            try? await Task.sleep(for: .seconds(3))
            return ok ? now : nil
        }
        var last: UInt64 = 0
        for i in 1...max(1, rounds) {
            if let now = await round("round \(i)") {
                if i > 1 { check("round \(i) new session", now != last, "generation \(last) before, \(now) now") }
                last = now
            }
        }
        // A session that opens but cannot read.
        note("simulated: the next session's readiness check is made to fail through the testing flag", ["step": "lifecycle_simulated_failure"])
        PKInProcess.shared().failNextReadinessCheck = true
        model.chatTaskBegan()
        let broken = await look()
        let named = broken.text.contains("could not read the screen") || broken.text.contains("session_unreadable")
        check("unreadable session reported", broken.failed && named, "the read \(broken.failed ? "failed" : "did not fail") in \(String(format: "%.2f", broken.seconds)) s: \(broken.text.prefix(240))",
              ["seconds": broken.seconds, "text": String(broken.text.prefix(600))])
        check("unreadable session not open", !model.hasOpenInProcessSession, "Poki \(model.hasOpenInProcessSession ? "took" : "did not take") the session as open")
        // Nothing may open again by itself: no new session for 30 s, with the task still under way.
        let brokenGeneration = await generation()
        try? await Task.sleep(for: .seconds(30))
        let quiet = await generation()
        check("no reopen after the failure", !model.hasOpenInProcessSession && quiet == brokenGeneration,
              "30 s later the session is \(model.hasOpenInProcessSession ? "open" : "still not open"), generation \(brokenGeneration) then \(quiet)",
              ["generation_before": brokenGeneration, "generation_after": quiet])
        await endTask()
        try? await Task.sleep(for: .seconds(2))
        if let after = await round("round after the failure") {
            check("broken session not reused", after != brokenGeneration, "generation \(brokenGeneration) could not read, the next task read on \(after)")
        }
        PKInProcess.shared().failNextReadinessCheck = false
        note("lifecycle: \(passed) of \(checks) checks passed", ["step": "lifecycle_done", "passed": passed, "checks": checks])
    }

    /// Nothing in Poki may listen on WebDriverAgent's port on the in-process path: a connection to
    /// 127.0.0.1:8100 from inside the app has to be refused.
    /// Whether actions arrive on a session reopened in this process: closes and reopens, then taps and
    /// types in Poki's own field, opens Settings, taps and types in its search field, and brings Poki
    /// back, with the app read in front after each and every step's seconds.
    func deliveryCheck() async {
        guard begin("delivery after a reopen") else { return }
        defer { end() }
        guard await prepare() else { return }
        let background = UIApplication.shared.beginBackgroundTask(withName: "In-process probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        let own = Bundle.main.bundleIdentifier ?? ""
        var passed = 0, checks = 0
        func check(_ name: String, _ ok: Bool, _ detail: String, _ fields: [String: Any] = [:]) {
            checks += 1
            if ok { passed += 1 }
            note("\(ok ? "PASS" : "FAIL") \(name): \(detail)", fields.merging(["step": "delivery_check", "check": name, "ok": ok]) { a, _ in a })
        }
        func front() async -> String {
            await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                queue.async { c.resume(returning: PKInProcess.shared().frontApp()["bundleId"] as? String ?? "") }
            }
        }
        func app(_ action: String, _ bundle: String) async -> (code: String?, seconds: Double) {
            await withCheckedContinuation { (c: CheckedContinuation<(code: String?, seconds: Double), Never>) in
                queue.async {
                    let t = ProcessInfo.processInfo.systemUptime
                    let code = PKInProcess.shared().app(bundle, action: action)
                    c.resume(returning: (code, ProcessInfo.processInfo.systemUptime - t))
                }
            }
        }
        _ = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            queue.async { c.resume(returning: PKInProcess.shared().close()) }
        }
        try? await Task.sleep(for: .seconds(2))
        let opened = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            queue.async { c.resume(returning: PKInProcess.shared().prepare()) }
        }
        check("reopen", (opened["ok"] as? Bool) == true, "generation \(opened["generation"] ?? "?"), device \(opened["device"] as? String ?? "?")", opened)
        guard (opened["ok"] as? Bool) == true else { return }
        let first = await front()
        check("front app", first == own, "read \(first.isEmpty ? "none" : first), Poki is in front", ["front": first])
        if let field {
            field.text = ""
            field.resignFirstResponder()
            try? await Task.sleep(for: .seconds(0.4))
            let frame = field.convert(field.bounds, to: nil)
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let tap = await touch([[PKTouchPoint.at(point, offset: 0), PKTouchPoint.at(point, offset: 0.05)]], "tap Poki's field at [\(Int(point.x)), \(Int(point.y))]")
            try? await Task.sleep(for: .seconds(0.6))
            check("tap in Poki", field.isFirstResponder, String(format: "field focused %@, answered in %.3f s", field.isFirstResponder ? "yes" : "no", tap.seconds), ["seconds": tap.seconds])
            if field.isFirstResponder {
                let typed = await type(Self.sample)
                try? await Task.sleep(for: .seconds(0.6))
                let same = field.text == Self.sample
                check("type in Poki", same, String(format: "read back %@, answered in %.3f s", same ? "same as sent" : "differs", typed.seconds), ["seconds": typed.seconds])
                field.text = ""
                field.resignFirstResponder()
            }
        }
        let settings = "com.apple.Preferences"
        let launch = await app("launch", settings)
        try? await Task.sleep(for: .seconds(1))
        let second = await front()
        check("open Settings", launch.code == nil && second == settings,
              String(format: "%@ in %.3f s, front %@", launch.code ?? "done", launch.seconds, second.isEmpty ? "none" : second),
              ["seconds": launch.seconds, "code": launch.code ?? "", "front": second])
        if second == settings {
            if let point = await frontField() {
                let tap = await touch([[PKTouchPoint.at(point, offset: 0), PKTouchPoint.at(point, offset: 0.05)]], "tap Settings' search field at [\(Int(point.x)), \(Int(point.y))]")
                try? await Task.sleep(for: .seconds(1.0))
                var typed = tap
                if tap.delivery == .sent { typed = await type(Self.sample) }
                try? await Task.sleep(for: .seconds(0.8))
                let value = await focusedValue()
                let same = value.map { $0.hasSuffix(Self.sample) } ?? false
                check("tap and type in Settings", same,
                      String(format: "%@, tap %.3f s, typing %.3f s", same ? "read back same as sent" : value == nil ? "no focused field after the tap" : "read back differs", tap.seconds, typed.seconds),
                      ["tap_seconds": tap.seconds, "type_seconds": typed.seconds])
            } else {
                check("tap and type in Settings", false, "no search field in Settings' tree")
            }
        }
        let back = await app("activate", own)
        try? await Task.sleep(for: .seconds(1))
        let last = await front()
        check("back to Poki", back.code == nil && last == own,
              String(format: "%@ in %.3f s, front %@", back.code ?? "done", back.seconds, last.isEmpty ? "none" : last),
              ["seconds": back.seconds, "code": back.code ?? "", "front": last])
        note("delivery: \(passed) of \(checks) checks passed", ["step": "delivery_result", "passed": passed, "checks": checks])
    }

    func portCheck() async {
        guard begin("port 8100") else { return }
        defer { end() }
        let result = await probe(label: "8100", host: "127.0.0.1", port: 8100, timeout: 2)
        note("127.0.0.1:8100: \(result.outcome) \(result.detail) after \(result.milliseconds) ms", ["step": "port_8100", "outcome": result.outcome, "detail": result.detail])
    }

    /// The gym scorecard on the in-process path: the same scenarios and checks as the runner path's
    /// executable, through this app's PokiCore and InProcessWDA. Approvals are answered the way the
    /// owner would on the Live Activity (the scorecard says when and how).
    func gymScorecard(model: AppModel) async {
        guard begin("gym scorecard") else { return }
        defer { end() }
        guard await prepare() else { return }
        model.inProcessReadyForProbe()
        let background = UIApplication.shared.beginBackgroundTask(withName: "Gym scorecard")
        defer { UIApplication.shared.endBackgroundTask(background) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let transcript = GymTranscript()
        // The owner's side of approvals: PokiCore asks, the approver answers after the delay the
        // scorecard set (there is no session on, so the app's own list does not see them).
        let asked = GymAskedApprovals()
        let approver = GymApprover { id, approved in
            if let approval = asked.byID[id] { model.resolve(approval, approved: approved) }
        }
        model.onProbeApproval = { approval in
            asked.byID[approval.id] = approval
            NSLog("PokiGym approval asked: %@ (%@)", approval.summary, approval.reason)
            approver.requested(id: approval.id)
        }
        defer { model.onProbeApproval = nil }
        var env = GymEnvironment(call: { name, args in
            let answer = await model.phoneToolWithPicture(name, arguments: args.serialized())
            return (answer.text, answer.jpeg.map { [$0] } ?? [])
        }, log: { line in
            transcript.lines.append(line)
            NSLog("PokiGym %@", String(line.prefix(900)))
        })
        env.pictures = documents.appendingPathComponent("gym-pictures")
        env.approveNext = { approver.next($0) }
        env.path = "in-process"
        let scorecard = GymScorecard(env: env)
        await scorecard.run()
        let report = scorecard.report
        transcript.lines.append(report)
        NSLog("PokiGym %@", report)
        note("gym scorecard: \(scorecard.rows.filter { $0.ms > 0 }.count) calls, \(scorecard.failures.count) failures", ["step": "gym", "failures": scorecard.failures])
        try? transcript.lines.joined(separator: "\n").write(to: documents.appendingPathComponent("gym-scorecard.txt"), atomically: true, encoding: .utf8)
    }

    /// `-pokiInProcess chat -pokiProbeModelURL http://127.0.0.1:8765/v1`: Poki's own agent end to end on
    /// this path. The chat is pointed at an OpenAI-compatible endpoint (on CI, a scripted model on the
    /// Mac), the owner sends a task, pi runs it with look and do on the phone, the session is saved; then an
    /// outside agent's `ask_poki` runs a second task as a hand-off. Into Documents/inprocess-probe.json.
    func chatCycle(model: AppModel, inSplitView: Bool = false, configuredModel: Bool = false) async {
        guard begin("chat with Poki's agent") else { return }
        defer { end() }
        let defaults = UserDefaults.standard
        let probeTask = defaults.string(forKey: "pokiProbeTask")
        guard !configuredModel || (ModelKeys.hasUsableKey && probeTask?.isEmpty == false) else {
            note("configured model unavailable, or no test task specified", ["step": "configured_model_unavailable", "hasUsableKey": ModelKeys.hasUsableKey])
            return
        }
        guard await prepare() else { return }
        model.inProcessReadyForProbe()
        let background = UIApplication.shared.beginBackgroundTask(withName: "Chat probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        if !configuredModel {
            ModelKeys.customURL = defaults.string(forKey: "pokiProbeModelURL") ?? "http://127.0.0.1:8765/v1"
            ModelKeys.customModel = defaults.string(forKey: "pokiProbeModel") ?? "poki-mock"
            ModelKeys.selectedProvider = .custom
            model.askPokiTool = true
        }
        AskPoki.refresh()
        guard let chat = AskPoki.chat else { note("no chat", ["step": "chat_missing"]); return }
        chat.newConversation()
        let task = probeTask ?? "Open the Poki fixture app and tell me what it shows."
        if inSplitView || configuredModel {
            _ = await model.phoneTool("look", arguments: "{}")
            note("workspace-chat: ready to restore the two test apps", ["step": "workspace_ready"])
            try? await Task.sleep(for: .seconds(Double(delay) ?? 8))
        }
        let t0 = ProcessInfo.processInfo.systemUptime
        chat.send(task, inSplitView: inSplitView)
        for _ in 0..<1200 {
            if !chat.running { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let seconds = ProcessInfo.processInfo.systemUptime - t0
        let replies: [String] = chat.entries.compactMap { if case .poki(let text) = $0.kind { text } else { nil } }
        let problems: [String] = chat.entries.compactMap { if case .note(.problem(let why)) = $0.kind { why } else { nil } }
        note("chat task: \(chat.calls.count) tool calls in \(String(format: "%.1f", seconds)) s, \(replies.count) replies, \(problems.count) problems",
             ["step": "chat", "running": chat.running, "seconds": seconds, "calls": chat.calls.map { ["name": $0.name, "ok": $0.ok, "ms": $0.ms] },
              "replies": replies, "problems": problems])
        // Saved like any conversation: the Sessions list shows it.
        try? await Task.sleep(for: .seconds(1))
        let saved = SessionStore.shared.session(chat.sessionID)
        note("chat session saved: \(saved != nil)", ["step": "chat_saved", "saved": saved != nil, "entries": saved?.entries.count ?? 0, "calls": saved?.calls.count ?? 0])
        guard !inSplitView, !configuredModel else { return }
        // An outside agent hands a task over.
        let t1 = ProcessInfo.processInfo.systemUptime
        let handoff = await model.phoneToolWithPicture("ask_poki", arguments: "{\"task\":\"Open the Poki fixture app and tell me what it shows.\"}")
        note("ask_poki: \(handoff.isError ? "failed" : "ok") in \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - t1)) s",
             ["step": "ask_poki", "error": handoff.isError, "text": String(handoff.text.prefix(4000))])
        let handoffs = SessionStore.shared.sessions.filter { $0.kind == .handoff }
        note("hand-off sessions saved: \(handoffs.count)", ["step": "handoff_saved", "count": handoffs.count, "entries": handoffs.first?.entries.count ?? 0])
    }

    /// The scorecard's log, kept for Documents/gym-scorecard.txt.
    private final class GymTranscript { var lines: [String] = [] }
    /// The approvals PokiCore asked for during the scorecard, by id.
    private final class GymAskedApprovals { var byID: [String: PendingApproval] = [:] }

    // MARK: Steps

    func prepare() async -> Bool {
        note("prepare: opening the daemon session and Automation Mode", ["step": "prepare_start"])
        let result = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            queue.async { c.resume(returning: PKInProcess.shared().prepare()) }
        }
        let ok = (result["ok"] as? Bool) == true
        let seconds = String(format: "%.3f", (result["seconds"] as? Double) ?? 0)
        note(ok ? "prepare: ready in \(seconds) s, generation \(result["generation"] ?? "?"), enable \((result["reused"] as? Bool) == true ? "reused" : "new")"
                : "prepare: failed in \(seconds) s: \(result["code"] ?? "?") \(result["detail"] ?? "")",
             result.merging(["step": "prepare"]) { a, _ in a })
        return ok
    }

    private func touch(_ fingers: [[PKTouchPoint]], _ what: String) async -> PKOutcome {
        let outcome = await withCheckedContinuation { (c: CheckedContinuation<PKOutcome, Never>) in
            queue.async { c.resume(returning: PKInProcess.shared().touch(fingers, timeout: 5)) }
        }
        report(what, outcome)
        return outcome
    }

    private func type(_ text: String) async -> PKOutcome {
        let outcome = await withCheckedContinuation { (c: CheckedContinuation<PKOutcome, Never>) in
            queue.async { c.resume(returning: PKInProcess.shared().type(text, timeout: 10)) }
        }
        report("type \(text.count) characters", outcome)
        return outcome
    }

    private func report(_ what: String, _ o: PKOutcome) {
        let delivery = ["not_sent", "sent", "unknown"][o.delivery.rawValue]
        note("\(what): \(delivery) in \(String(format: "%.3f", o.seconds)) s, generation \(o.generation)\(o.code.map { ", \($0)" } ?? "")\(o.detail.map { " (\($0))" } ?? "")",
             ["step": what, "delivery": delivery, "seconds": o.seconds, "generation": o.generation, "code": o.code ?? NSNull()])
    }

    // MARK: Record

    func begin(_ what: String) -> Bool {
        guard !running else { return false }
        running = true
        record = []
        note("start: \(what)", ["step": "begin", "what": what])
        return true
    }

    func end() {
        running = false
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted]) else { return }
        try? data.write(to: directory.appendingPathComponent("inprocess-probe.json"))
    }

    func note(_ line: String, _ fields: [String: Any]) {
        var entry = fields
        entry["uptime"] = ProcessInfo.processInfo.systemUptime
        record.append(entry)
        lines.append(line)
        NSLog("PokiInProcess %@", line)
        AppLog.shared.add("inprocess", line)
    }
}

/// General › Testing Options: the automation path switch and the probes (752 had them in Settings ›
/// Diagnostics; ESP-152 removed them on a line where they had no caller).
struct InProcessSection: View {
    @ObservedObject var probe = InProcessProbe.shared
    @Environment(AppModel.self) private var model
    @AppStorage("automationPath") private var path = AutomationPath.inProcess.rawValue
    private let running = AutomationPath.current

    var body: some View {
        Section {
            Picker("Agents' actions go through", selection: $path) {
                Text("Poki Runner").tag(AutomationPath.runner.rawValue)
                Text("Poki itself").tag(AutomationPath.inProcess.rawValue)
            }
            if path != running.rawValue {
                Text("Takes effect when Poki starts again.").font(.caption).foregroundStyle(.orange)
            }
            ProbeField(probe: probe).frame(height: 44)
            HStack {
                Button("Port 8100") { Task { await probe.portCheck() } }
                Button("Separate session") { Task { await probe.separateTrial() } }
            }.disabled(probe.running)
            Button("Compare both paths (5 rounds)") { Task { await probe.benchmark(model: model, rounds: 5) } }.disabled(probe.running)
            Button("Close and reopen (5 rounds)") { Task { await probe.reopenCycle(rounds: 5) } }.disabled(probe.running)
            Button("Reopen, then tap, type and open an app") { Task { await probe.deliveryCheck() } }.disabled(probe.running)
            Button("Whole tasks, 5 rounds, then a session that cannot read") { Task { await probe.lifecycleCheck(model: model, rounds: 5) } }.disabled(probe.running)
            HStack {
                Button("Prepare") { Task { await probe.prepareOnly() } }
                Spacer()
                Button("Read") { Task { await probe.readOnly() } }
                Spacer()
                Button("Self test") { Task { await probe.selfTest() } }
            }
            .buttonStyle(.borderless).disabled(probe.running)
            HStack {
                TextField("x", text: $probe.x).keyboardType(.numberPad)
                TextField("y", text: $probe.y).keyboardType(.numberPad)
                TextField("s", text: $probe.delay).keyboardType(.numberPad)
                Button("Later") { Task { await probe.later() } }.buttonStyle(.borderless).disabled(probe.running)
            }
            .monospacedDigit()
            ForEach(probe.lines.indices.reversed(), id: \.self) { i in Text(probe.lines[i]).font(.caption2.monospaced()).textSelection(.enabled) }
        } header: {
            Text("In-process automation")
        } footer: {
            Text("Taps and types from Poki itself, without Poki Runner. Self test taps the field above and types into it. Later waits, then taps the point (x, y) and types, in whatever app is in front.")
        }
    }
}

private struct ProbeField: UIViewRepresentable {
    let probe: InProcessProbe
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "In-process test field"
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.accessibilityIdentifier = "inprocess-field"
        probe.field = field
        return field
    }
    func updateUIView(_ view: UITextField, context: Context) { probe.field = view }
}
