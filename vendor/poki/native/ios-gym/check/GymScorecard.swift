// Poki Gym scorecard: drives PokiCore's look/do (its MCP handler, as the agent calls it) through
// every Poki Gym scenario, the system apps and a few faults, and scores each against the owner's
// rules: every call answers in time with a picture, the tree is read under animation, an action
// moves the screen, a busy or dead runner never hangs the agent.
//
// One file for both paths: the macOS executable (check/main.swift) runs it against Poki Runner
// (WebDriverAgent) on a simulator; Poki itself runs it on the in-process path (InProcessProbe's
// `gym` mode). Everything that depends on the host (the tool call, simctl, pictures) comes in
// through `GymEnvironment`.
import Foundation
import PokiCore

/// What the scorecard needs from where it runs.
public struct GymEnvironment {
    /// One tool call (`look`, `do`, `status`) with its arguments: the answer text and its pictures.
    public var call: (_ name: String, _ args: JSON) async -> (text: String, pictures: [Data])
    public var log: (String) -> Void
    /// Where each call's picture goes, or nil.
    public var pictures: URL?
    public var gymBundle = "nz.zheha.poki.gym"
    /// A shell for simctl (the macOS host), or nil: the faults that need one are skipped.
    public var shell: ((_ args: [String]) async -> String)?
    public var udid = "booted"
    public var runnerBundle = "com.facebook.WebDriverAgentRunner.xctrunner"
    /// Whether the host restarts a dead runner when PokiCore asks (the runner path's start script).
    public var canRestartRunner = false
    /// WDA's raw XML tree, for diagnostics, or nil.
    public var rawTree: () async -> String? = { nil }
    /// Whether the simulator has an app (the CI runtime ships without Notes, Mail and Messages).
    public var installed: (_ bundle: String) async -> Bool = { _ in false }
    /// Allows (or, with a negative delay, denies) the next approval PokiCore asks for, after that
    /// many seconds, as the owner would on the Live Activity. Nil: no approvals are answered.
    public var approveNext: ((_ seconds: Double) -> Void)?
    /// A label for the report: "runner" or "in-process".
    public var path = "runner"

    public init(call: @escaping (_ name: String, _ args: JSON) async -> (text: String, pictures: [Data]), log: @escaping (String) -> Void) {
        self.call = call
        self.log = log
    }
}

public struct GymRow {
    public var scenario: String
    public var step: String
    public var ms: Int
    public var ok: Bool
    public var note: String
}

/// Answers approvals as the owner would on the Live Activity: `next(seconds)` allows (or, negative,
/// declines) the next approval PokiCore asks for, that many seconds after it is asked.
@MainActor
public final class GymApprover {
    private var plan: Double?
    private let resolve: (_ id: String, _ approved: Bool) -> Void
    public init(resolve: @escaping (_ id: String, _ approved: Bool) -> Void) { self.resolve = resolve }
    public func next(_ seconds: Double) { plan = seconds }
    /// PokiCore asked (an approvalRequested event, or the app's approvals list grew).
    public func requested(id: String) {
        guard let seconds = plan else { return }
        plan = nil
        let resolve = self.resolve
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(abs(seconds) * 1e9))
            resolve(id, seconds >= 0)
        }
    }
}

@MainActor
public final class GymScorecard {
    public private(set) var rows: [GymRow] = []
    public private(set) var failures: [String] = []
    private var scenario = "setup"
    private let env: GymEnvironment
    private var gymBundle: String { env.gymBundle }

    public init(env: GymEnvironment) { self.env = env }

    private func log(_ line: String) { env.log(line) }

    /// One tool call, timed. A call that does not answer within `hang` seconds is the worst failure the
    /// owner named (the agent stuck); it is recorded as HUNG and the run goes on.
    @discardableResult
    func call(_ step: String, _ name: String, _ args: JSON = .object([:]), budget: Double = 20, hang: Double = 90) async -> String {
        let started = Date()
        let env = self.env
        let reply: (text: String, pictures: [Data])? = await withTaskGroup(of: (text: String, pictures: [Data])?.self) { group in
            group.addTask { await env.call(name, args) }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(hang * 1e9)); return nil }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard let reply else {
            log("=== \(scenario) / \(step): HUNG after \(ms) ms\n")
            rows.append(GymRow(scenario: scenario, step: step, ms: ms, ok: false, note: "HUNG: no answer in \(Int(hang)) s"))
            failures.append("\(scenario) / \(step): no answer in \(Int(hang)) s")
            return "HUNG"
        }
        let text = reply.text
        let pictures = reply.pictures
        if let folder = env.pictures {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safe = "\(scenario)-\(step)".replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            for (i, data) in pictures.enumerated() {
                try? data.write(to: folder.appendingPathComponent(String(format: "%02d-%@%@.jpg", rows.count + 1, safe, i == 0 ? "" : "-\(i + 1)")))
            }
        }
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        var notes: [String] = []
        if Double(ms) / 1000 > budget { notes.append("slow: over \(Int(budget)) s") }
        // The routines tool reads and writes the phone's memory only: it never sends a picture.
        if pictures.isEmpty, name != "routines" { notes.append("no picture") }
        log("=== \(scenario) / \(step): \(ms) ms, \(pictures.count) image(s)\n\(text)\n")
        rows.append(GymRow(scenario: scenario, step: step, ms: ms, ok: notes.isEmpty, note: notes.isEmpty ? first.prefix(70).description : notes.joined(separator: "; ")))
        for n in notes { failures.append("\(scenario) / \(step): \(n)") }
        return text
    }

    func check(_ ok: Bool, _ what: String) {
        log(ok ? "PASS \(scenario): \(what)" : "FAIL \(scenario): \(what)")
        rows.append(GymRow(scenario: scenario, step: what, ms: 0, ok: ok, note: ok ? "pass" : "FAIL"))
        if !ok { failures.append("\(scenario): \(what)") }
    }

    /// The number of the first (or last) listed element whose line holds `text`, optionally of a type.
    func ref(in answer: String, _ text: String, type: String? = nil, last: Bool = false) -> Int? {
        let candidates = answer.split(separator: "\n").filter { line in
            line.contains("\"") && line.contains(text) && (type.map { line.contains(" \($0) ") } ?? true)
        }
        // An element whose whole label is the text comes before one that only contains it (a tap on
        // "Open" must not land on the alert "Open in Poki Gym?").
        let exact = candidates.filter { $0.contains(" \"\(text)\" ") || $0.contains(" \"\(text) = ") }
        // Only element lines count: a "did: wait_until: "text" appeared" line also quotes the text.
        func number(_ line: Substring) -> Int? {
            Int(line.split(separator: " ").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "+~ ")) } ?? "")
        }
        let numbered = (exact.isEmpty ? candidates : exact).compactMap(number)
        return last ? numbered.last : numbered.first
    }

    /// A system permission alert ("X Would Like to Send You Notifications") sits over every app until
    /// it is answered; an agent taps Don't Allow. Returns the read after it, or the answer as it was.
    /// A first-run tip (Safari's TipView with Close) or a What's New sheet (Continue) over an app's
    /// screen: an agent dismisses it and reads again. Returns the read after it, or the answer as it was.
    func dismissTip(_ answer: String) async -> String {
        if answer.contains("TipView"), let close = ref(in: answer, "Close", type: "Button") {
            return await call("tap Close on the tip", "do", ["actions": [["tap": .number(Double(close))], ["wait_until": ["settled": true, "ms": 1500]]]])
        }
        if answer.contains("What’s New") || answer.contains("What's New"), let cont = ref(in: answer, "Continue", type: "Button") {
            return await call("tap Continue on the What's New sheet", "do", ["actions": [["tap": .number(Double(cont))], ["wait_until": ["settled": true, "ms": 2000]]]])
        }
        return answer
    }

    func dismissSystemAlert(_ answer: String) async -> String {
        guard answer.contains("Would Like") || answer.contains("Don’t Allow") || answer.contains("Don't Allow") else { return answer }
        guard let no = ref(in: answer, "Don’t Allow", type: "Button") ?? ref(in: answer, "Don't Allow", type: "Button") else { return answer }
        return await call("tap Don't Allow on the system alert", "do", ["actions": [["tap": .number(Double(no))], ["wait_until": ["settled": true, "ms": 2000]]]])
    }

    /// While the runner is down (killed, or restarted by PokiCore's watchdog), every answer says so
    /// and a tree read is impossible; an agent keeps looking until one comes. Up to 45 s.
    func awaitRunner(_ answer: String) async -> String {
        var answer = answer
        for i in 1...15 where answer.contains("it is being restarted") || answer.contains("no element tree") || answer.contains("read: failed") {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            answer = await call("look while the runner comes back (\(i))", "look", budget: 30)
        }
        return answer
    }

    /// The frame [x, y, w, h] of the first listed element whose line holds `text`.
    func frame(in answer: String, _ text: String, type: String? = nil) -> [Double]? {
        guard let n = ref(in: answer, text, type: type),
              let line = answer.split(separator: "\n").first(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "+~ ")).hasPrefix("\(n) ") }),
              let r = line.range(of: #"\[(-?[0-9]+), ?(-?[0-9]+), ?([0-9]+), ?([0-9]+)\]"#, options: .regularExpression) else { return nil }
        let v = line[r].split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Double($0) }
        return v.count == 4 ? v : nil
    }

    /// Opens a Gym scenario the way an agent would: back to the menu (the Menu button, or a fresh
    /// launch), tap the scenario's row, and read; the title "Gym: <name>" must be on screen. (simctl
    /// openurl is not used: from outside the app it raises an "Open in Poki Gym?" system alert.)
    func open(_ name: String) async -> String {
        scenario = name
        var answer = await awaitRunner(await call("look", "look"))
        answer = await dismissSystemAlert(answer)
        if !answer.contains("Gym: menu") {
            if let menu = ref(in: answer, "\"Menu\"", type: "Button") {
                answer = await call("tap Menu", "do", ["actions": [["tap": .number(Double(menu))]]])
            } else {
                answer = await call("launch Poki Gym fresh", "do", ["actions": [["launch": ["bundle": .string(gymBundle), "fresh": true]]]])
            }
        }
        if ref(in: answer, "\"\(name)", type: "Button") == nil { answer = await awaitRunner(await call("look at the menu", "look")) }
        // The menu is longer than the screen: a row below the fold is reached with scroll_to.
        if ref(in: answer, "\"\(name)", type: "Button") == nil {
            let scrolled = await scrollTo(name, step: "scroll_to the \(name) row", max: 4)
            answer = ref(in: scrolled, "\"\(name)", type: "Button") != nil ? scrolled : await call("look at the menu (scrolled)", "look")
        }
        guard let row = ref(in: answer, "\"\(name)", type: "Button") else {
            check(false, "the \(name) row is on the menu"); return answer
        }
        answer = await call("open \(name)", "do", ["actions": [["tap": .number(Double(row))]]])
        for i in 1...2 where !answer.contains("Gym: \(name)") { answer = await call("look at \(name)\(i == 1 ? "" : " (again)")", "look") }
        check(answer.contains("Gym: \(name)"), "the \(name) screen is in front")
        return answer
    }

    /// scroll_to as an agent uses it: PokiCore stops when an action's time runs out and says to call
    /// again to go on; the agent calls again until the text is found or the list is through.
    func scrollTo(_ text: String, step: String, budget: Double = 30, max: Int = 20) async -> String {
        var answer = ""
        for i in 1...max {
            answer = await call(i == 1 ? step : "\(step) (again, \(i))", "do", ["actions": [["scroll_to": .string(text)]]], budget: budget)
            if answer.contains("found at") { break }
            if !(answer.contains("call scroll_to again") || answer.contains("may have been delivered")) { break }
        }
        return answer
    }

    /// Taps the element with `text` and reads; `state` must then be on screen.
    /// `or` names other texts that prove the tap landed (the in-process tree lists only an alert or a
    /// sheet while one is up, so the state line behind it is not readable then).
    func tap(_ text: String, in answer: String, type: String? = nil, last: Bool = false, expect state: String, or also: [String] = [], then: [JSON] = []) async -> String {
        var answer = answer
        // A do's answer lists only what changed; an element that stayed keeps its number but is not
        // repeated, so the full list is read when the target is not in the answer (as an agent would).
        if ref(in: answer, text, type: type, last: last) == nil {
            answer = await call("look (full) for \(text)", "look", ["full": true])
        }
        guard let r = ref(in: answer, text, type: type, last: last) else {
            check(false, "\"\(text)\" is listed in the tree"); return answer
        }
        answer = await call("tap \(text)", "do", ["actions": .array([["tap": .number(Double(r))]] + then)])
        func landed(_ a: String) -> Bool { a.contains(state) || also.contains { a.contains($0) } }
        if !landed(answer) { answer = await call("look after tap \(text)", "look") }
        check(landed(answer), "tapping \"\(text)\" gives state \"\(state)\"\(also.isEmpty ? "" : " (or shows \(also.joined(separator: " / ")))")")
        return answer
    }

    // System apps, as the owner's tasks use them. Each is launched fresh, and a first-run sheet with
    // Continue is dismissed as an agent would.
    func launchApp(_ name: String, _ bundle: String) async -> String {
        scenario = name
        // A first-run sheet (What's New, Continue) can slide up a few seconds after the launch (Photos:
        // 3 s), so the screen is read again once it holds still, and Continue tapped when it is there.
        var answer = await call("launch \(name) fresh", "do", ["actions": [["launch": ["bundle": .string(bundle), "fresh": true]], ["wait_until": ["settled": true, "ms": 3000]]]], budget: 25)
        for i in 1...3 {
            if ref(in: answer, "Continue", type: "Button") == nil, i == 1 || !answer.contains("app: \(name)") {
                answer = await call("look at \(name) (\(i))", "look", ["full": true])
            }
            answer = await dismissSystemAlert(answer)
            if let cont = ref(in: answer, "Continue", type: "Button") {
                answer = await call("tap Continue on the first-run sheet (\(i))", "do", ["actions": [["tap": .number(Double(cont))], ["wait_until": ["settled": true, "ms": 2000]]]])
            } else if answer.contains("app: \(name)") { break }
        }
        check(answer.contains("app: \(name)"), "\(name) is in front after launch")
        return answer
    }
    /// The app named on the answer's first line ("app: Settings   read: ...").
    func frontApp(_ answer: String) -> String {
        guard let line = answer.split(separator: "\n").first(where: { $0.hasPrefix("app: ") }) else { return "?" }
        return String(line.dropFirst(5).components(separatedBy: "   read:").first ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// What the type action read back ("the field now reads \"...\"").
    func readBack(_ answer: String) -> String? {
        guard let r = answer.range(of: #"the field now reads "([^\n]*)""#, options: .regularExpression) else { return nil }
        return String(answer[r])
    }

    /// Runs every scenario; the rows and failures are on the object afterwards.
    public func run() async {
        await call("look (cold)", "look")
        let launched = await call("launch Poki Gym fresh", "do", ["actions": [["launch": ["bundle": .string(gymBundle), "fresh": true]]]], budget: 25)
        var menu = launched.contains("Gym: menu") ? launched : await call("look (menu)", "look")
        check(menu.contains("Gym: menu"), "Poki Gym is in front after launch")

        // 1. Animation that never idles: the tree must still come, and the Next button must work, in time.
        var a = await open("animation")
        var treeReads = 0
        for i in 1...3 {
            let read = await call("look under animation \(i)", "look", budget: 8)
            if !read.contains("read from the picture because") { treeReads += 1 }
        }
        check(treeReads >= 2, "the element tree is read under animation (\(treeReads)/3 reads were tree reads)")
        a = await call("look for Next", "look")
        a = await tap("Next", in: a, type: "Button", expect: "Next tapped 1")
        a = await tap("Next", in: a, type: "Button", expect: "Next tapped 2")
        let settled = await call("wait_until settled (never settles)", "do", ["actions": [["wait_until": ["settled": true, "ms": 3000]]]], budget: 12)
        check(settled.contains("wait_until"), "wait_until on a screen that never settles answers instead of waiting forever")

        // 2. A system alert on top of the screen.
        a = await open("alert")
        a = await tap("Show alert", in: a, type: "Button", expect: "alert shown", or: ["Gym alert"])
        a = await call("look at the alert", "look")
        check(a.contains("Gym alert") && ref(in: a, "OK", type: "Button") != nil, "the alert and its OK button are in the tree")
        a = await tap("OK", in: a, type: "Button", expect: "OK tapped")

        // 3. Typing into an empty field (direct typing; the paste prompt never comes up).
        a = await open("paste")
        // The in-process tree carries no placeholder (the field is "field" there, "Paste here" through
        // the runner): the one text field on the screen is the target either way.
        if let field = ref(in: a, "Paste here") ?? ref(in: a, "TextField", type: "TextField") {
            var typed = await call("type into the field", "do", ["actions": [["type": "hello gym 123", "ref": .number(Double(field))]]])
            if typed.contains("not_sent") {
                // The keyboard's first use can stall the CI simulator's runner; PokiCore restarts it and
                // says to send the type again, which an agent does.
                typed = await awaitRunner(typed)
                if let again = ref(in: typed, "Paste here") ?? ref(in: typed, "TextField", type: "TextField") { typed = await call("type into the field (again)", "do", ["actions": [["type": "hello gym 123", "ref": .number(Double(again))]]]) }
            }
            let shown = typed.contains("hello gym 123") ? typed : await call("look at the field", "look")
            check(shown.contains("hello gym 123"), "typed text is read back from the field")
            check(!shown.lowercased().contains("paste prompt") || shown.contains("hello gym 123"), "no paste prompt stops the typing")
        } else { check(false, "the text field is listed") }

        // A fresh simulator shows the keyboard's slide-to-type introduction over the keys after the first
        // typing; a phone in use never does. Dismissed here so it does not sit over later screens.
        scenario = "keyboard intro"
        let intro = await call("look for the keyboard intro", "look")
        if let cont = ref(in: intro, "Continue", type: "Button") {
            _ = await call("tap Continue on the keyboard intro", "do", ["actions": [["tap": .number(Double(cont))]]])
        }

        // 4. A long list: scroll_to by text, then tap.
        a = await open("list")
        let found = await scrollTo("Row 250", step: "scroll_to Row 250")
        check(found.contains("found at") || found.contains("found by scroll_to"), "scroll_to finds Row 250")
        a = found.contains("Row 250") ? found : await call("look for Row 250", "look")
        a = await tap("Row 250", in: a, expect: "Row 250 tapped")
        let missing = await call("scroll_to a row that does not exist", "do", ["actions": [["scroll_to": ["text": "Row 9999", "max_swipes": 2]]]], budget: 30)
        check(!missing.contains("HUNG"), "scroll_to for a missing text answers")
        // A drag by points (the content follows the finger: WDA's /actions, in-process the touch path).
        let before = await call("look before the drag", "look", ["full": true])
        let dragged = await call("drag the list up by 400 pt", "do", ["actions": [["drag": ["from": [200, 700], "to": [200, 300], "ms": 500]]]], budget: 12)
        check(dragged.contains("did: drag"), "a drag by points is sent")
        let topBefore = before.range(of: #"Button "Row [0-9]+""#, options: .regularExpression).map { String(before[$0]) } ?? "?"
        let after = dragged.contains("screen_changed: false") ? dragged : await call("look after the drag", "look", ["full": true])
        let topAfter = after.range(of: #"Button "Row [0-9]+""#, options: .regularExpression).map { String(after[$0]) } ?? "?"
        check(topAfter != topBefore, "the list moved under the drag (top row \(topBefore) -> \(topAfter))")

        // 5. A half sheet.
        a = await open("sheet")
        a = await tap("Open sheet", in: a, type: "Button", expect: "sheet open", or: ["\"Done\""])
        a = await call("look at the sheet", "look")
        a = await tap("Done", in: a, type: "Button", expect: "Done tapped")

        // 6. Focus that arrives late: type with no target once the field has focus.
        a = await open("focus")
        a = await tap("Start", in: a, type: "Button", expect: "Gym: focus")
        let late = await call("wait 2 s then type", "do", ["actions": [["wait": 2200], ["type": "late focus"]]])
        let lateShown = late.contains("late focus") ? late : await call("look at the late field", "look")
        check(lateShown.contains("late focus"), "typing lands in the field that took focus late")

        // 7. A dense tree: 3,000 elements. Reads must stay in budget and the button must be reachable.
        a = await open("dense")
        let dense = await call("look at 1,500 elements", "look", budget: 15)
        check(!dense.contains("HUNG"), "a dense tree is read")
        let foundButton = await scrollTo("Found", step: "scroll_to Found", budget: 40)
        // 1,500 cells come before the button, past what a listing shows; scroll_to's "found at [x, y, w, h]"
        // gives its frame, and an agent taps that point.
        if let r = foundButton.range(of: #"found at \[([0-9]+), ?([0-9]+), ?([0-9]+), ?([0-9]+)\]"#, options: .regularExpression) {
            let n = foundButton[r].split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
            let point: JSON = [.number(n[0] + n[2] / 2), .number(n[1] + n[3] / 2)]
            var after = await call("tap Found at its frame", "do", ["actions": [["tap": point]]])
            if !after.contains("Found tapped") { after = await call("look after tapping Found", "look", budget: 15) }
            check(after.contains("Found tapped"), "tapping \"Found\" at the frame scroll_to gave shows state \"Found tapped\"")
        } else {
            a = foundButton.contains("Found") ? foundButton : await call("look for Found", "look", budget: 15)
            a = await tap("Found", in: a, type: "Button", expect: "Found tapped")
        }

        // 8. Two decoys with the button's label and frame: the real button must still be tapped.
        a = await open("dup")
        a = await tap("Twin", in: a, type: "Button", last: true, expect: "Twin tapped")

        // 9. A web view filling the screen with one link.
        a = await open("fullscreen")
        // Diagnostic: WDA's raw XML for this screen, to see whether the web view's parts are there at all.
        if let xml = await env.rawTree() {
            func count(_ needle: String) -> Int { xml.components(separatedBy: needle).count - 1 }
            log("diag: raw XML has \(xml.count) characters; WebView nodes \(count("<XCUIElementTypeWebView")), Link nodes \(count("<XCUIElementTypeLink")), StaticText nodes \(count("<XCUIElementTypeStaticText")), 'A web page' \(count("A web page")), 'Open' \(count("\"Open\""))")
            if let r = xml.range(of: "<XCUIElementTypeWebView") { log("diag: web view node: " + xml[r.lowerBound...].prefix(600) + "\n") }
        }
        // The web view's parts reach the tree a few seconds after the page loads; PokiCore says so and
        // the agent reads again, as here (up to four times, a second apart).
        for i in 1...8 where ref(in: a, "Open") == nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            a = await call("look again at the web view (\(i))", "look")
        }
        a = await tap("Open", in: a, expect: "Opened")

        // 10. A navigation push and the system back button.
        a = await open("nav")
        a = await tap("Push", in: a, expect: "Pushed page")
        a = await call("look at the pushed page", "look")
        if let back = ref(in: a, "Gym: nav\"", type: "Button") ?? ref(in: a, "Back", type: "Button") {
            let popped = await call("tap back", "do", ["actions": [["tap": .number(Double(back))]]])
            let home = popped.contains("Gym: nav\n") || popped.contains("Gym: nav\"") && !popped.contains("Pushed page") ? popped : await call("look after back", "look")
            check(!home.contains("Pushed page"), "the system back button pops the page")
        } else { check(false, "a back button is listed on the pushed page") }

        // 11. An alert that pops up in the middle of a scroll: scroll_to must answer, the alert must be
        // dismissable, and the scroll must go on afterwards.
        a = await open("interrupt")
        let interrupted = await scrollTo("Item 150", step: "scroll_to Item 150 while an alert comes up", budget: 30, max: 4)
        check(!interrupted.contains("HUNG"), "scroll_to answers while an alert comes up")
        a = await call("look for the alert", "look")
        if ref(in: a, "Not now", type: "Button") != nil {
            a = await tap("Not now", in: a, type: "Button", expect: "Not now tapped")
        } else {
            check(a.contains("interrupted") || a.contains("Not now tapped"), "the alert in the middle of the scroll is seen (state interrupted)")
        }
        let resumed = await scrollTo("Item 150", step: "scroll_to Item 150 after the alert", budget: 30)
        check(resumed.contains("found at") || resumed.contains("found by scroll_to"), "scroll_to finds Item 150 after the alert")

        // 12. The app relaunches while a wait_until runs (a crash, or a process killed under memory
        // pressure): the wait must answer, and the next read must be a tree read of the new process.
        // (Needs simctl from outside: the runner path's host only.)
        if let shell = env.shell {
            _ = await open("animation")
            scenario = "relaunch in wait_until"
            async let waiting: String = call("wait_until a text that never comes (8 s)", "do", ["actions": [["wait_until": ["text": "Never shown", "ms": 8000]]]], budget: 15)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // Off the main actor: simctl blocks for seconds under load, and the call's answer is delivered on
            // the main actor (that wait was charged to PokiCore as an 18 s gap it could not account for).
            let relaunchLog = await shell(["xcrun", "simctl", "terminate", env.udid, gymBundle]) + shell(["xcrun", "simctl", "launch", env.udid, gymBundle])
            log(relaunchLog)
            let waited = await waiting
            check(!waited.contains("HUNG"), "wait_until answers while the app relaunches under it")
            var relaunched = ""
            for i in 1...3 {
                relaunched = await call("look after the relaunch (\(i))", "look")
                if relaunched.contains("app: Poki Gym") && relaunched.contains("Gym: menu") { break }
            }
            check(relaunched.contains("app: Poki Gym") && relaunched.contains("Gym: menu"), "the relaunched app's tree is read (menu in front)")
        }




        // 13. Settings: search with mixed Latin and CJK text, then the field cleared and searched again.
        a = await launchApp("Settings", "com.apple.Preferences")
        if ref(in: a, "Search", type: "SearchField") == nil { a = await call("look (full) for the search field", "look", ["full": true]) }
        if let field = ref(in: a, "Search", type: "SearchField") {
            let mixed = await call("type mixed text into Search", "do", ["actions": [["type": "Wi-Fi 网络 ok", "ref": .number(Double(field))]]])
            let shown = mixed.contains("Wi-Fi 网络 ok") ? mixed : await call("look at the search field", "look")
            check(shown.contains("Wi-Fi"), "the Latin part of the search text is read back")
            check(shown.contains("网络"), "the CJK part of the search text is read back (mixed text typed as keys)")
            // Search mode replaces the field (the answer says the old number is gone and lists the new one),
            // so the field is found again before the second type, as an agent reading the answer would.
            var fieldAgain = ref(in: shown, "Search", type: "SearchField") ?? ref(in: mixed, "Search", type: "SearchField")
            if fieldAgain == nil { fieldAgain = ref(in: await call("look (full) for the search field again", "look", ["full": true]), "Search", type: "SearchField") }
            let cleared = await call("type General with clear", "do", ["actions": [["type": "General", "ref": .number(Double(fieldAgain ?? field)), "clear": true]]])
            let after = readBack(cleared) ?? ""
            check(after.contains("General") && !after.contains("Wi-Fi"), "clear removes the earlier search text before the new one (read back: \(after.prefix(60)))")
            var cancelIn = cleared
            if ref(in: cancelIn, "Cancel", type: "Button") == nil { cancelIn = await call("look for Cancel", "look") }
            if let cancel = ref(in: cancelIn, "Cancel", type: "Button") {
                _ = await call("tap Cancel", "do", ["actions": [["tap": .number(Double(cancel))]]])
            }
        } else { check(false, "the Settings search field is listed") }

        // 13b. Routines: Settings → General → About by hand, saved, then repeated in one call; a run from a
        // screen where its first target is missing stops before it sends anything. The calls and time of
        // each way are in the rows ("by hand" against "run").
        scenario = "routine"
        _ = await call("finish the earlier task", "do", ["actions": [], "finish": true], budget: 20)
        let byHandFrom = rows.count
        a = await launchApp("Settings", "com.apple.Preferences")
        scenario = "routine"
        // The General page slides in after the tap; an agent waits for it to settle before the next tap.
        a = await tap("General", in: a, expect: "About", then: [["wait_until": ["settled": true, "ms": 2000]]])
        a = await tap("About", in: a, expect: "Model Name", or: ["iOS Version", "Software Version", "Name"])
        let byHand = rows[byHandFrom...].filter { $0.ms > 0 }
        let byHandMs = byHand.reduce(0) { $0 + $1.ms }
        let saved = await call("save the routine", "routines", ["action": "save", "name": "gym about", "description": "Settings, General, About", "read": ["iOS Version", "Model Name"]])
        check(saved.contains("saved \"gym about\""), "a task done by hand is saved as a routine (\(saved.prefix(90)))")
        let shown = await call("show the routine", "routines", ["action": "show", "name": "gym about"])
        check(shown.contains("General") && shown.contains("About"), "the routine keeps what was tapped by label")
        _ = await call("finish (back where it began)", "do", ["actions": [], "finish": true], budget: 20)
        let taskLook = await call("look (a new task)", "look")
        check(taskLook.contains("gym about") || frontApp(taskLook) != "Settings", "the first look of a task in Settings names its routines (or another app is in front)")
        let runFrom = rows.count
        let ran = await call("run the routine", "do", ["actions": [["run": "gym about"]]], budget: 30)
        let runMs = rows[runFrom...].reduce(0) { $0 + $1.ms }
        check(ran.contains("run \"gym about\"") && ran.contains("end check passed"), "the routine runs whole in one call and its end check passes (\(ran.split(separator: "\n").first(where: { $0.contains("run \"") }) ?? ran.prefix(120)))")
        log("ROUTINE by hand: \(byHand.count) calls, \(byHandMs) ms; run: 1 call, \(runMs) ms")
        rows.append(GymRow(scenario: "routine", step: "by hand \(byHand.count) calls \(byHandMs) ms, run 1 call \(runMs) ms", ms: 0, ok: true, note: "timing"))
        // The same path without its launch steps, run from the About screen: General is not there.
        _ = await call("save a copy", "routines", ["action": "save", "name": "gym about no launch"])
        if let r = shown.range(of: "steps as JSON (edit takes this shape): "),
           let steps = try? JSON.parse(String(shown[r.upperBound...]).split(separator: "\n").first.map(String.init) ?? ""),
           case .array(let all) = steps {
            let kept = all.filter { $0["action"]?["launch"] == nil && $0["action"]?["wait_until"] == nil }
            _ = await call("edit the copy", "routines", ["action": "edit", "name": "gym about no launch", "steps": .string(JSON.array(kept).serialized())])
            let stopped = await call("run where the first target is missing", "do", ["actions": [["run": "gym about no launch"]]], budget: 30)
            check(stopped.contains("stopped at step 1"), "a run whose first target is not on screen stops before sending anything (\(stopped.split(separator: "\n").first(where: { $0.contains("stopped") }) ?? stopped.prefix(120)))")
        } else { check(false, "show gives the steps as JSON") }
        _ = await call("forget the copy", "routines", ["action": "forget", "name": "gym about no launch"])
        _ = await call("forget the routine", "routines", ["action": "forget", "name": "gym about"])

        // 14. Notes: a new note, typing, a clear and a second type. The CI simulator runtime has no Notes;
        // then Contacts, with a new contact's First name field, stands in (the same typing path).
        if !(await env.installed("com.apple.mobilenotes")) {
            a = await launchApp("Contacts", "com.apple.MobileAddressBook")
            if ref(in: a, "Add", type: "Button") == nil { a = await call("look (full) for Add", "look", ["full": true]) }
            if let add = ref(in: a, "Add", type: "Button") {
                a = await call("tap Add", "do", ["actions": [["tap": .number(Double(add))], ["wait_until": ["settled": true, "ms": 2000]]]])
                if ref(in: a, "First name") == nil { a = await call("look (full) for First name", "look", ["full": true]) }
                if let first = ref(in: a, "First name") {
                    let typed = await call("type the first name", "do", ["actions": [["type": "Firstname", "ref": .number(Double(first))]]])
                    check((readBack(typed) ?? "").contains("Firstname"), "typing lands in the First name field (read back: \((readBack(typed) ?? "").prefix(50)))")
                    // Typing replaces the field element (the answer lists the new number and says the old is
                    // gone), so it is found again before each later type.
                    let field2 = ref(in: typed, "First name", type: "TextField") ?? first
                    let replaced = await call("type a second name with clear", "do", ["actions": [["type": "Second", "ref": .number(Double(field2)), "clear": true]]])
                    let rb = readBack(replaced) ?? ""
                    check(rb.contains("Second") && !rb.contains("Firstname"), "clear empties the field before the second text (read back: \(rb.prefix(50)))")
                    let field3 = ref(in: replaced, "First name", type: "TextField") ?? field2
                    let more = await call("type more without clear", "do", ["actions": [["type": " more", "ref": .number(Double(field3))]]])
                    let rb2 = readBack(more) ?? ""
                    check(rb2.contains("Second more"), "a second type appends (read back: \(rb2.prefix(50)))")
                } else { check(false, "the First name field is listed") }
                let cancelIn = await call("look for Cancel", "look")
                if let cancel = ref(in: cancelIn, "Cancel", type: "Button") { _ = await call("tap Cancel", "do", ["actions": [["tap": .number(Double(cancel))]]]) }
            } else { check(false, "the Add button is listed") }
        } else {
        a = await launchApp("Notes", "com.apple.mobilenotes")
        if ref(in: a, "New Note") == nil && ref(in: a, "New note") == nil { a = await call("look (full) for New Note", "look", ["full": true]) }
        if let compose = ref(in: a, "New Note", type: "Button") ?? ref(in: a, "New note", type: "Button") ?? ref(in: a, "Compose", type: "Button") {
            a = await call("tap New Note", "do", ["actions": [["tap": .number(Double(compose))]]])
            let typed = await call("type the first line (no ref: the note has focus)", "do", ["actions": [["wait_until": ["settled": true, "ms": 1500]], ["type": "First line of the note"]]])
            let first = typed.contains("First line of the note") ? typed : await call("look at the note", "look")
            check(first.contains("First line of the note"), "typing without a ref lands in the new note")
            if let body = ref(in: first, "First line of the note") ?? ref(in: first, "First line of the note", type: "TextView") {
                let replaced = await call("type a second text with clear", "do", ["actions": [["type": "Second text", "ref": .number(Double(body)), "clear": true]]])
                var rb = readBack(replaced) ?? ""
                if rb.isEmpty { rb = await call("look at the note after clear", "look") }
                check(rb.contains("Second text") && !rb.contains("First line"), "clear empties the note before the second text (read back: \(rb.prefix(60)))")
                let more = await call("type more without clear", "do", ["actions": [["type": " and more", "ref": .number(Double(body))]]])
                var rb2 = readBack(more) ?? ""
                if rb2.isEmpty { rb2 = await call("look at the note after the second type", "look") }
                check(rb2.contains("Second text and more"), "a second type appends to the note (read back: \(rb2.prefix(60)))")
            } else { check(false, "the note's text is listed as an element") }
            let doneIn = await call("look for Done", "look")
            if let done = ref(in: doneIn, "Done", type: "Button") { _ = await call("tap Done", "do", ["actions": [["tap": .number(Double(done))]]]) }
        } else { check(false, "the New Note button is listed") }
        }

        // 15. Safari: a page with links, scroll_to on page text, a link tapped.
        a = await launchApp("Safari", "com.apple.mobilesafari")
        // In-process, Safari's start page lists the address capsule as an Other "Search or enter website" for a
        // moment before it is the TextField "Address"; a tap on either focuses the field, so both serve.
        for i in 1...3 where ref(in: a, "Address") == nil && (i == 1 || ref(in: a, "Search or enter website") == nil) {
            if i > 1 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            a = await call("look (full) for the address bar (\(i))", "look", ["full": true])
        }
        if let address = ref(in: a, "Address") ?? ref(in: a, "Search or enter website") {
            // With the scheme, Safari's first suggestion is the site itself (a bare host's first suggestion
            // is a Google search on this runtime, and Go did not load it on 3 of 4 runs).
            var opened = await call("type a URL and return", "do", ["actions": [["type": "https://example.com/", "ref": .number(Double(address))], ["key": "return"], ["wait_until": ["text": "Example Domain", "ms": 12000]]]], budget: 25)
            // A busy runner answers not_sent and says to send the type again; Safari's first-use sheet
            // ("Safari search now shows personalized suggestions", Continue) can come up over the keyboard.
            for i in 1...2 where opened.contains("not_sent") || ref(in: opened, "Continue", type: "Button") != nil {
                if let cont = ref(in: opened, "Continue", type: "Button") {
                    opened = await call("tap Continue on Safari's first-use sheet", "do", ["actions": [["tap": .number(Double(cont))]]])
                }
                if opened.contains("not_sent") || ref(in: opened, "Example Domain") == nil {
                    opened = await awaitRunner(opened)
                    let field = ref(in: opened, "Address") ?? address
                    opened = await call("type a URL and return (again, \(i))", "do", ["actions": [["type": "https://example.com/", "ref": .number(Double(field)), "clear": true], ["key": "return"], ["wait_until": ["text": "Example Domain", "ms": 12000]]]], budget: 25)
                }
            }
            // The page's title as an element (not the wait_until's wording); when the return key did not
            // submit (seen once: the suggestions stayed), the suggestion row with the URL is tapped.
            var loaded = ref(in: opened, "Example Domain") != nil ? opened : await call("look at the page", "look")
            // (A suggestion row runs a search instead; the keyboard's Go key loads the URL.)
            if ref(in: loaded, "Example Domain") == nil, let go = ref(in: loaded, "Go", type: "Button") ?? ref(in: loaded, "go", type: "Button") ?? ref(in: loaded, "Go", type: "Key") ?? ref(in: loaded, "example.com", type: "StaticText") {
                loaded = await call("tap Go, or the site's suggestion row (return did not submit)", "do", ["actions": [["tap": .number(Double(go))], ["wait_until": ["text": "Example Domain", "ms": 12000]]]], budget: 25)
                if ref(in: loaded, "Example Domain") == nil { loaded = await call("look at the page (after the suggestion)", "look") }
            }
            if ref(in: loaded, "Example Domain") != nil {
                check(true, "the page loads and its text is in the tree")
                var link = await scrollTo("Learn more", step: "scroll_to the link's text", budget: 30, max: 3)
                // Safari's first-run tip (View Bookmarks, Share Menu...) can come up over the page.
                if link.contains("TipView") {
                    _ = await dismissTip(link)
                    link = await scrollTo("Learn more", step: "scroll_to the link's text (after the tip)", budget: 30, max: 3)
                }
                check(link.contains("found at") || link.contains("found by scroll_to") || ref(in: link, "Learn more") != nil, "scroll_to finds page text in Safari")
                var page = link
                if ref(in: page, "Learn more") == nil { page = await call("look (full) for the link", "look", ["full": true]) }
                if let l = ref(in: page, "Learn more", type: "Link") ?? ref(in: page, "Learn more") {
                    let followed = await call("tap the link and wait for the next page", "do", ["actions": [["tap": .number(Double(l))], ["wait_until": ["text": "Reserved Domains", "ms": 12000]]]], budget: 25)
                    let next = followed.contains("Reserved Domains") ? followed : await call("look at the next page", "look")
                    check(next.contains("Reserved Domains") || next.contains("screen_changed: true"), "tapping a link in Safari opens the next page")
                    let back = await call("back", "do", ["actions": [["back": true], ["wait_until": ["text": "Example Domain", "ms": 8000]]]], budget: 20)
                    check(back.contains("Example Domain") || back.contains("did: back"), "back returns to the first page")
                } else { check(false, "the link is listed in the tree") }
            } else { check(false, "the page loads (example.com over the runner's network)") }
        } else { check(false, "the Safari address bar is listed") }

        // 16. Photos: a grid cell tapped, then back to the grid.
        a = await launchApp("Photos", "com.apple.mobileslideshow")
        // The new Photos app's home shows the grid as one Button "Library" with no cells in the tree; the
        // cells are in the tree once Library is open.
        // The What's New sheet and a notification alert come a few seconds after the launch; both answered. (The
        // Library grid is a leaf in WDA's raw tree, so tapping it opens nothing: the picture is the way in.)
        for i in 1...4 where ref(in: a, "Photo,", type: "Image") == nil {
            a = await dismissSystemAlert(a)
            if let cont = ref(in: a, "Continue", type: "Button") {
                a = await call("tap Continue on What's New (\(i))", "do", ["actions": [["tap": .number(Double(cont))], ["wait_until": ["settled": true, "ms": 2500]]]])
            } else if ref(in: a, "Library", type: "Button") != nil { break }
            if ref(in: a, "Photo,", type: "Image") == nil { a = await call("look (full) for a photo (\(i))", "look", ["full": true]) }
        }
        // Diagnostic: does WDA's raw tree hold the grid's cells at all?
        if let xml = await env.rawTree() {
            func count(_ needle: String) -> Int { xml.components(separatedBy: needle).count - 1 }
            log("diag: Photos raw XML \(xml.count) characters; Image nodes \(count("<XCUIElementTypeImage")), Cell nodes \(count("<XCUIElementTypeCell")), 'Photo,' \(count("Photo,")), Button nodes \(count("<XCUIElementTypeButton"))")
            if let r = xml.range(of: "label=\"Library\"") { log("diag: Library node: " + xml[r.lowerBound...].prefix(700) + "\n") }
        }
        var cellRef = ref(in: a, "Photo,", type: "Image")
        var openedPhoto = ""
        if let cell = cellRef {
            openedPhoto = await call("tap a photo", "do", ["actions": [["tap": .number(Double(cell))], ["wait_until": ["settled": true, "ms": 2500]]]])
        } else if let f = frame(in: a, "Library", type: "Button") {
            // The grid's cells are not in the tree (the whole grid is one button): an agent taps a
            // thumbnail on the picture; the newest row sits at the bottom of the grid's frame.
            let point: JSON = [.number(f[0] + f[2] / 2), .number(f[1] + f[3] - 50)]
            openedPhoto = await call("tap a thumbnail on the picture (the cells are not in the tree)", "do", ["actions": [["tap": point], ["wait_until": ["settled": true, "ms": 2500]]]])
            cellRef = -1
        }
        if cellRef != nil {
            check(openedPhoto.contains("screen_changed: true"), "tapping a grid cell opens the photo (screen changed)")
            let backToGrid = await call("back to the grid", "do", ["actions": [["back": true], ["wait_until": ["settled": true, "ms": 2500]]]])
            var grid = (ref(in: backToGrid, "Photo,", type: "Image") ?? ref(in: backToGrid, "Library", type: "Button")) != nil ? backToGrid : await call("look (full) at the grid", "look", ["full": true])
            // The What's New sheet can slide up late, over the grid.
            // The What's New sheet can slide up late, over the grid, and the notifications alert after it.
            for _ in 1...3 where (ref(in: grid, "Photo,", type: "Image") ?? ref(in: grid, "Library", type: "Button")) == nil
                && (ref(in: grid, "Continue", type: "Button") != nil || grid.contains("Would Like")) {
                _ = await dismissSystemAlert(await dismissTip(grid))
                grid = await call("look (full) at the grid (after the sheet)", "look", ["full": true])
            }
            check((ref(in: grid, "Photo,", type: "Image") ?? ref(in: grid, "Library", type: "Button")) != nil, "back returns to the photo grid")
        } else { check(false, "a photo cell or the Library grid is listed") }

        // 17. A payment button: do holds the tap for the owner's answer and says so when they decline;
        // once they allow it (here the host answers after a few seconds, as the owner would on the
        // Live Activity) the tap is sent in the same call.
        // (The menu row says "approval", not "pay": a row whose label named the payment would itself ask.)
        a = await open("approval")
        if let pay = ref(in: a, "Pay now", type: "Button") {
            env.approveNext?(-2)
            let declined = await call("tap Pay now (declined after ~2 s)", "do", ["actions": [["tap": .number(Double(pay))]]], budget: 30)
            check(declined.contains("declined"), "do says the owner declined, within the call")
            check(!declined.contains("Pay now tapped"), "a declined tap is not sent")
            env.approveNext?(4)
            let paid = await call("tap Pay now (approved after ~4 s)", "do", ["actions": [["tap": .number(Double(pay))]]], budget: 30)
            check(!paid.contains("approval_required"), "do waits for the owner's answer instead of answering approval_required at once")
            let shown = paid.contains("Pay now tapped") ? paid : await call("look after the approved tap", "look")
            check(shown.contains("Pay now tapped"), "the approved tap is sent in the same call (state \"Pay now tapped\")")
            if let cancel = ref(in: shown, "Cancel order", type: "Button") {
                let plain = await call("tap Cancel order (not sensitive)", "do", ["actions": [["tap": .number(Double(cancel))]]], budget: 12)
                check(plain.contains("Cancel order tapped") || plain.contains("did: tap"), "a plain button in the same app is tapped without an approval")
            }
        } else { check(false, "the Pay now button is listed") }

        // 18. finish: true on the last do: the phone goes back to the app the task began in. A task
        // begins with its first call after the last finish, so the origin is whatever is in front then:
        // the gym (launched from outside on the runner path) or the home screen the earlier finish left.
        scenario = "finish"
        _ = await call("finish any earlier task", "do", ["actions": [], "finish": true], budget: 20)
        if let shell = env.shell {
            log(await shell(["xcrun", "simctl", "launch", env.udid, gymBundle]))
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let first = await call("look (the task begins here)", "look")
        let originApp = frontApp(first)
        let away = await call("launch Settings", "do", ["actions": [["launch": "com.apple.Preferences"], ["wait_until": ["settled": true, "ms": 2000]]]], budget: 25)
        check(away.contains("app: Settings"), "Settings is in front before finish (the task began in \(originApp))")
        let finished = await call("do with finish: true", "do", ["actions": [], "finish": true], budget: 20)
        check(finished.contains("finish: back in \(originApp)"), "the finish line says the phone went back to \(originApp)")
        var origin = finished
        for i in 1...3 where frontApp(origin) != originApp {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            origin = await call("look after finish (\(i))", "look")
        }
        check(frontApp(origin) == originApp, "after finish the phone is back in \(originApp), where the task began")

        // Faults. A. A look while the runner is busy with a long action: it must answer, not queue forever.
        scenario = "busy runner"
        _ = await open("animation")
        scenario = "busy runner"
        async let long: String = call("do with a 4 s wait", "do", ["actions": [["wait": 4000]]], budget: 12)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let during = await call("look while the do runs", "look", budget: 12)
        _ = await long
        check(!during.contains("HUNG"), "a look during a long do answers")

        // B. The runner dies (as after a tunnel drop): every call still answers, says so, and recovers when
        // the runner is back. (Runner path only: in-process there is no runner to kill.)
        if let shell = env.shell {
        scenario = "runner killed"
        log(await shell(["xcrun", "simctl", "terminate", env.udid, env.runnerBundle]))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let dead = await call("look with the runner dead", "look", budget: 30)
        check(!dead.contains("HUNG"), "a look with a dead runner answers")
        let deadDo = await call("do with the runner dead", "do", ["actions": [["swipe": "up"]]], budget: 30)
        check(!deadDo.contains("HUNG") && !deadDo.contains("did: swipe"), "a do with a dead runner answers and sends nothing")
        if env.canRestartRunner {
            // PokiCore asked the host to restart the runner; the look must come back by itself.
            // A tree read ("app: Poki Gym"), not the picture-only reading the fallback screenshot gives
            // while the runner is still down.
            var back = ""
            for i in 1...25 {
                back = await call("look after the runner restart (\(i))", "look", budget: 30)
                if back.contains("app: Poki Gym") { break }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            check(back.contains("app: Poki Gym"), "look reads the tree again once the runner is back")
            let afterDo = await call("do after the runner restart", "do", ["actions": [["swipe": "up"]]])
            check(afterDo.contains("did: swipe"), "do works again once the runner is back")
        }
        }

    }

    /// The scorecard table and its summary lines.
    public var report: String {
        var out = "\n| scenario | step | ms | ok | note |\n|---|---|---:|---|---|\n"
        for r in rows { out += "| \(r.scenario) | \(r.step) | \(r.ms == 0 ? "" : String(r.ms)) | \(r.ok ? "yes" : "NO") | \(r.note.replacingOccurrences(of: "|", with: "/")) |\n" }
        let calls = rows.filter { $0.ms > 0 }
        let worst = calls.max { $0.ms < $1.ms }
        out += "\npath: \(env.path); calls: \(calls.count), slowest: \(worst.map { "\($0.scenario) / \($0.step) \($0.ms) ms" } ?? "none"), failures: \(failures.count)\n"
        for f in failures { out += "  - \(f)\n" }
        return out
    }
}
