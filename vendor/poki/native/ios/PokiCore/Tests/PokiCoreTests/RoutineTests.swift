import XCTest
@testable import PokiCore

/// Routines: a task's do actions are recorded, saved by name, replayed in one call that waits for each
/// target and stops at a screen that differs; notes; export and import.
final class RoutineTests: XCTestCase {
    /// Settings → General → About, a screen per tap.
    final class Pages: @unchecked Sendable {
        let wda: FakeWDA
        let page = LockedBox(0)
        var screens: [[Node]]
        init(_ wda: FakeWDA, _ screens: [[Node]]) {
            self.wda = wda
            self.screens = screens
            show(0)
            wda.set("POST /wda/tap") { [self] _ in
                let next = min(self.page.value + 1, self.screens.count - 1)
                self.show(next)
                return (200, ["value": .null])
            }
        }
        func show(_ i: Int) { page.value = i; wda.tree(screens[i], app: "Settings") }
    }

    static let home = [Node("Button", "General", [16, 100, 358, 44]), Node("Button", "Privacy", [16, 144, 358, 44])]
    static let general = [Node("NavigationBar", "General", [0, 50, 390, 44]), Node("Button", "About", [16, 100, 358, 44]), Node("Button", "Software Update", [16, 144, 358, 44])]
    static let about = [Node("NavigationBar", "About", [0, 50, 390, 44]), Node("StaticText", "iOS Version", [16, 100, 358, 44], value: "27.3"), Node("StaticText", "Model Name", [16, 144, 358, 44], value: "iPhone")]

    func core(_ store: RoutineStore = RoutineStore(url: nil)) -> (PokiCore, FakeWDA, Pages) {
        let wda = FakeWDA()
        let pages = Pages(wda, [Self.home, Self.general, Self.about])
        let (core, _, _) = makeCore(wda) { $0.memory = store }
        return (core, wda, pages)
    }

    func number(of label: String, in text: String) -> Int? {
        for line in text.split(separator: "\n") where line.contains("\"\(label)") {
            let digits = line.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
            if let n = Int(digits) { return n }
        }
        return nil
    }

    /// Records Settings → General → About by hand and saves it.
    func recordAbout(_ core: PokiCore) async -> ToolResult {
        let first = await core.call("look", [:])
        let general = number(of: "General", in: first.text)!
        let second = await core.call("do", ["actions": [["tap": .number(Double(general))]]])
        guard let about = number(of: "About", in: second.text) else { XCTFail(second.text); return second }
        _ = await core.call("do", ["actions": [["tap": .number(Double(about))]]])
        return await core.call("routines", ["action": "save", "name": "iOS version", "description": "read the iOS version in Settings", "read": ["iOS Version"]])
    }

    func testATaskIsSavedAsARoutineByWhatItTapped() async {
        let store = RoutineStore(url: nil)
        let (core, _, _) = core(store)
        let saved = await recordAbout(core)
        XCTAssertTrue(saved.text.contains("saved \"iOS version\" (2 steps"), saved.text)
        let routine = store.routine(named: "iOS version")!
        XCTAssertEqual(routine.steps.map { $0.target?.label }, ["General", "About"])
        XCTAssertEqual(routine.steps.map { $0.target?.type }, ["Button", "Button"])
        XCTAssertEqual(routine.app, "com.apple.Preferences")
        XCTAssertTrue(routine.expect.contains("About") || routine.expect.contains("iOS Version"), "\(routine.expect)")
    }

    func testARunRepeatsTheRoutineInOneCallAndReadsTheValue() async {
        let (core, wda, pages) = core()
        _ = await recordAbout(core)
        pages.show(0)
        let taps = wda.bodies("POST /wda/tap").count
        _ = await core.call("look", [:])
        let run = await core.call("do", ["actions": [["run": "iOS version"]]])
        XCTAssertTrue(run.text.contains("run \"iOS version\": 2 steps"), run.text)
        XCTAssertTrue(run.text.contains("end check passed"), run.text)
        XCTAssertTrue(run.text.contains("read: iOS Version = 27.3"), run.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, taps + 2)
        XCTAssertEqual(pages.page.value, 2)
        XCTAssertFalse(run.isError)
    }

    func testARunStopsWhereTheScreenDiffersAndSendsNothingMore() async {
        let store = RoutineStore(url: nil)
        let (core, wda, pages) = core(store)
        _ = await recordAbout(core)
        pages.screens[0] = [Node("Button", "Privacy", [16, 100, 358, 44])]
        pages.show(0)
        let taps = wda.bodies("POST /wda/tap").count
        _ = await core.call("look", [:])
        let run = await core.call("do", ["actions": [["run": "iOS version"]]])
        XCTAssertTrue(run.text.contains("stopped at step 1 of 2"), run.text)
        XCTAssertTrue(run.text.contains("Button \"General\" is not on screen"), run.text)
        XCTAssertTrue(run.text.contains("app: Settings"), "the stop answers with the screen: \(run.text)")
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, taps)
        XCTAssertEqual(store.routine(named: "iOS version")?.failuresInARow, 1)
        XCTAssertEqual(store.routine(named: "iOS version")?.lastStop?.step, 1)
    }

    func testTwoLikeTargetsFarFromTheRecordedOneAreNotGuessedBetween() async {
        let (core, wda, pages) = core()
        _ = await recordAbout(core)
        pages.screens[0] = [Node("Button", "General", [16, 400, 358, 44]), Node("Button", "General", [16, 600, 358, 44])]
        pages.show(0)
        let taps = wda.bodies("POST /wda/tap").count
        _ = await core.call("look", [:])
        let run = await core.call("do", ["actions": [["run": "iOS version"]]])
        XCTAssertTrue(run.text.contains("2 elements match Button \"General\""), run.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, taps)
    }

    /// The brief goes into every task's prompt: a full memory stays within 4000 characters, and keeps
    /// the routine that fits the task and the newest note.
    func testTheBriefStaysShortWhenTheMemoryIsFull() async throws {
        let store = RoutineStore(url: nil)
        let (core, _, _) = core(store)
        _ = await recordAbout(core)
        var other = try XCTUnwrap(store.routine(named: "iOS version"))
        for i in 0..<30 {
            other.name = "errand \(i)"
            other.description = String(repeating: "an errand the owner runs every week, ", count: 8)
            store.save(other)
        }
        for i in 0..<50 { _ = store.remember("note \(i): " + String(repeating: "a long fact about the owner. ", count: 10), by: "test") }

        let brief = store.brief(for: "what iOS version is this")

        XCTAssertLessThanOrEqual(brief.count, 4000)
        XCTAssertTrue(brief.contains("- iOS version: read the iOS version in Settings"), brief)
        XCTAssertTrue(brief.contains("note 49: "), brief)
    }

    func testAStaleRoutineIsNotOfferedAndASaveOverItStartsItsRecordAgain() async {
        let store = RoutineStore(url: nil)
        let (core, _, pages) = core(store)
        _ = await recordAbout(core)
        XCTAssertTrue(store.brief(for: "what iOS version is this").contains("iOS version"))
        pages.screens[0] = [Node("Button", "Privacy", [16, 100, 358, 44])]
        for _ in 0..<2 { pages.show(0); _ = await core.call("look", [:]); _ = await core.call("do", ["actions": [["run": "iOS version"]]]) }
        XCTAssertTrue(store.routine(named: "iOS version")!.stale)
        XCTAssertFalse(store.brief(for: "what iOS version is this").contains("iOS version:"))
    }

    func testTheFirstLookOfATaskNamesTheRoutinesAndFinishOffersToSave() async {
        let (core, _, pages) = core()
        let first = await core.call("look", [:])
        XCTAssertFalse(first.text.contains("routines"), first.text)
        _ = await recordAbout(core)
        pages.show(0)
        let finished = await core.call("do", ["actions": [["tap": 1]], "finish": true])
        XCTAssertTrue(finished.text.contains("learn: this task took"), finished.text)
        let next = await core.call("look", [:])
        XCTAssertTrue(next.text.contains("routines for this app: \"iOS version\""), next.text)
    }

    func testTypedTextBecomesAParameterAndAPasswordIsNeverKept() async {
        let store = RoutineStore(url: nil)
        let (core, _, _) = core(store)
        _ = await core.call("look", [:])
        // Record by hand: the type actions as the recorder sees them.
        let c = core.computer
        c.refs = [1: Element(type: "SearchField", label: "Search", value: nil, identifier: nil, frame: Rect(x: 16, y: 60, width: 358, height: 36), depth: 1)]
        c.trace = [c.recordable(["type": "hello", "ref": 1])!]
        let (routine, _) = c.routine(named: "search", description: "", read: [], expect: [], by: "test")
        XCTAssertEqual(routine?.steps.first?.action["type"]?.string, "{{text_1}}")
        XCTAssertEqual(routine?.params["text_1"], "hello")
        XCTAssertEqual(routine?.steps.first?.target?.label, "Search")
        c.refs = [1: Element(type: "SecureTextField", label: "Password", value: nil, identifier: nil, frame: Rect(x: 16, y: 60, width: 358, height: 36), depth: 1)]
        let secret = c.recordable(["type": "hunter2", "ref": 1])!
        XCTAssertEqual(secret.step.secret, true)
        XCTAssertNil(secret.typed)
        XCTAssertFalse(secret.step.action.serialized().contains("hunter2"))
    }

    func testNotesExportAndImportMoveTheMemoryBetweenPhones() async throws {
        let a = RoutineStore(url: nil)
        let (core, _, _) = core(a)
        _ = await recordAbout(core)
        let remembered = await core.call("routines", ["action": "remember", "text": "Mom is the contact Mama"])
        XCTAssertTrue(remembered.text.contains("remembered"), remembered.text)
        let exported = await core.call("routines", ["action": "export"])
        XCTAssertTrue(exported.text.contains("\"schema\" : \"poki.agent-backup/1\""), String(exported.text.prefix(200)))

        let b = RoutineStore(url: nil)
        let summary = try b.importData(Data(exported.text.utf8), by: "test")
        XCTAssertTrue(summary.contains("1 routines added"), summary)
        XCTAssertEqual(b.notes.map(\.text), ["Mom is the contact Mama"])
        XCTAssertEqual(b.routine(named: "iOS version")?.steps.count, 2)
        // Importing the same file again changes nothing; an older copy does not replace a newer one.
        let again = try b.importData(Data(exported.text.utf8), by: "test")
        XCTAssertTrue(again.contains("0 routines added, 0 replaced"), again)
        XCTAssertThrowsError(try b.importData(Data(#"{"schema":"other/1"}"#.utf8), by: "test"))
        XCTAssertTrue(b.brief(for: "anything").contains("Mom is the contact Mama"))
    }

    func testTheBackupCopyIsWrittenAndARestoredOneIsMergedIn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poki-routines-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RoutineStore(url: dir.appendingPathComponent("memory.json"), backupDirectory: dir.appendingPathComponent("AgentBackup"))
        store.remember("Use the work email", by: "owner")
        let backup = dir.appendingPathComponent("AgentBackup/poki-agent-backup.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertNil(store.importRestoredBackup(), "our own copy is not imported again")
        // Poki Setup puts another phone's backup there.
        let other = RoutineStore(url: nil)
        other.remember("Mom is the contact Mama", by: "owner")
        try other.exportData().write(to: backup)
        let reopened = RoutineStore(url: dir.appendingPathComponent("memory.json"), backupDirectory: dir.appendingPathComponent("AgentBackup"))
        XCTAssertNotNil(reopened.importRestoredBackup())
        XCTAssertEqual(Set(reopened.notes.map(\.text)), ["Use the work email", "Mom is the contact Mama"])
    }

    func testTheToolIsListedAndAnswersWithoutTheRunner() async {
        let (core, _, _) = core()
        let list = await core.rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], session: nil)
        XCTAssertTrue(list.reply?.serialized().contains("\"name\":\"routines\"") == true)
        let empty = await core.call("routines", ["action": "list"])
        XCTAssertTrue(empty.text.contains("none saved yet"), empty.text)
        let bad = await core.call("routines", ["action": "show", "name": "nope"])
        XCTAssertTrue(bad.isError)
    }
}
