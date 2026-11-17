import XCTest
@testable import PokiCore

/// ESP-465: a task asked in Poki's chat begins with Poki in front. In the owner's log the first look of
/// 3 of 5 tasks (build 800) read Poki's own chat, and the task card showed that picture.
final class PokiFrontTests: XCTestCase {
    func pokiInFront() -> FakeWDA {
        let wda = FakeWDA()
        wda.source([("Button", "Talk"), ("StaticText", "Message to a friend")], app: "Poki")
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "nz.zheha.poki", "name": "Poki"]]) }
        return wda
    }

    func testALookWithPokiInFrontShowsNoneOfPokiAndSaysHowToStart() async {
        let (core, _, _) = makeCore(pokiInFront())
        let events = LockedBox<[CoreEvent]>([])
        Task { for await e in core.events { events.update { $0.append(e) } } }
        let looked = await core.call("look", [:])
        XCTAssertFalse(looked.isError, looked.text)
        XCTAssertNil(looked.jpeg, "no picture of the owner's chat goes to the model")
        XCTAssertFalse(looked.text.contains("Talk"), looked.text)
        XCTAssertFalse(looked.text.contains("Message to a friend"), looked.text)
        XCTAssertTrue(looked.text.contains("{launch: \"bundle id\"}"), looked.text)
        let finished = await eventually { events.value.contains { if case .toolFinished = $0 { return true }; return false } }
        XCTAssertTrue(finished)
        guard case .toolFinished(_, _, let facts)? = events.value.last else { return XCTFail("\(events.value)") }
        XCTAssertNil(facts.thumbnail, "the task card and the Live Activity get no picture of Poki")
    }

    /// The launch from Poki answers with the launched app's screen, picture and all.
    func testALaunchFromPokiShowsTheLaunchedApp() async {
        let wda = pokiInFront()
        let (core, _, _) = makeCore(wda)
        _ = await core.call("look", [:])
        for key in ["POST /wda/apps/launch", "POST /wda/apps/activate"] {
            wda.set(key) { [wda] _ in
                wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.mobilenotes", "name": "Notes"]]) }
                wda.source([("Button", "New Note")], app: "Notes")
                return (200, ["value": .null])
            }
        }
        let opened = await core.call("do", ["actions": [["launch": "com.apple.mobilenotes"]]])
        XCTAssertTrue(opened.text.contains("New Note"), opened.text)
        XCTAssertNotNil(opened.jpeg, opened.text)
    }
}
