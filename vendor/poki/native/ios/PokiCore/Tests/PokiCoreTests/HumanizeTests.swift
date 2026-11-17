import XCTest
@testable import PokiCore

/// Touches and typing shaped after a person's (`Humanize`): what a seeded plan looks like, that the
/// shaped gestures keep their speed and their intent (a flick coasts, a resting drag stops), that the
/// legacy schedule comes back exactly when shaping is off, and what the session sends for each.
final class HumanizeTests: XCTestCase {
    /// The W3C steps of the one finger in an `/actions` body.
    func steps(_ body: JSON?) -> [JSON] { body?["actions"]?[0]?["actions"]?.array ?? [] }
    func moves(_ body: JSON?) -> [JSON] { steps(body).filter { $0["type"]?.string == "pointerMove" } }
    func total(_ body: JSON?) -> Double { steps(body).reduce(0) { $0 + ($1["duration"]?.double ?? 0) } / 1000 }

    // MARK: Plans

    func testASeededPlanRepeatsAndTwoSeedsDiffer() {
        var a = Humanize(enabled: true, seed: 7), b = Humanize(enabled: true, seed: 7), c = Humanize(enabled: true, seed: 8)
        let ta = a.tap(at: (100, 200)), tb = b.tap(at: (100, 200)), tc = c.tap(at: (100, 200))
        XCTAssertEqual(ta.map(\.x), tb.map(\.x))
        XCTAssertEqual(ta.map(\.t), tb.map(\.t))
        XCTAssertNotEqual(ta.last!.t, tc.last!.t)
    }

    func testATapPressesForAPersonsTimeAndStaysInsideTheElement() {
        var h = Humanize(enabled: true, seed: 1)
        let frame = Rect(x: 100, y: 300, width: 40, height: 20)
        var presses: [Double] = []
        for _ in 0..<500 {
            let tap = h.tap(at: (120, 310), within: frame)
            presses.append(tap.last!.t)
            XCTAssertEqual(tap.first!.t, 0)
            XCTAssertTrue(tap.map(\.t) == tap.map(\.t).sorted(), "time runs forward")
            // Inside the middle half of the element, and the lift within a point of the contact.
            XCTAssertTrue(tap.first!.x >= 110 && tap.first!.x <= 130 && tap.first!.y >= 305 && tap.first!.y <= 315, "\(tap.first!)")
            XCTAssertLessThanOrEqual(hypot(tap.last!.x - tap.first!.x, tap.last!.y - tap.first!.y), 0.91)
        }
        let sorted = presses.sorted()
        XCTAssertGreaterThanOrEqual(sorted.first!, 0.05)
        XCTAssertLessThanOrEqual(sorted.last!, 0.14)
        XCTAssertEqual(sorted[250], 0.075, accuracy: 0.01, "the median press")
        XCTAssertGreaterThan(Set(presses.map { Int($0 * 1000) }).count, 30, "no two taps alike")
    }

    func testATapOnAPointChosenOffTheCentreStaysWithinAPointOfIt() {
        var h = Humanize(enabled: true, seed: 3)
        // A covered element touched at its free part (y 700 of a 690-810 frame): the scatter must not
        // move the touch back under the cover.
        for _ in 0..<200 {
            let tap = h.tap(at: (195, 700), within: Rect(x: 0, y: 690, width: 390, height: 120))
            XCTAssertLessThanOrEqual(abs(tap.first!.y - 700), 1)
            XCTAssertLessThanOrEqual(abs(tap.first!.x - 195), 1)
        }
    }

    func testAFlickLiftsAtSpeedAndARestingDragComesToAStop() {
        var h = Humanize(enabled: true, seed: 11)
        let flick = h.drag(from: (200, 700), to: (200, 230), seconds: 0.25)
        let drag = h.drag(from: (200, 700), to: (200, 230), seconds: 0.4, rest: 0.2)
        func speed(_ p: [Humanize.Sample], lastMs: Double) -> Double {
            // Mean speed over the last `lastMs` of movement, points a second.
            let end = p.last!, cut = end.t - lastMs / 1000
            let before = p.last { $0.t <= cut } ?? p.first!
            return hypot(end.x - before.x, end.y - before.y) / max(0.001, end.t - before.t)
        }
        let mean = 470 / 0.25
        XCTAssertGreaterThan(speed(flick, lastMs: 50), mean, "the flick still gathers speed when it lifts, so the list coasts")
        let moving = drag.filter { $0.t <= drag.last!.t - 0.2 + 0.001 }
        XCTAssertLessThan(speed(moving, lastMs: 40), mean * 0.4, "the resting drag slows before it stops")
        let still = drag.last!, lastMove = moving.last!
        XCTAssertEqual(still.t - lastMove.t, 0.2, accuracy: 0.001, "then holds still for the rest")
        XCTAssertLessThan(hypot(still.x - lastMove.x, still.y - lastMove.y), 0.5, "without moving the list")
        // Both arrive within a few points of the target, both keep their movement time.
        XCTAssertEqual(flick.last!.y, 230, accuracy: 4)
        XCTAssertEqual(drag.last!.y, 230, accuracy: 4)
        XCTAssertEqual(flick.last!.t, 0.25, accuracy: 0.045, "15-40 ms of contact before the finger moves, no more")
        XCTAssertEqual(drag.last!.t, 0.6, accuracy: 0.045)
    }

    func testADragCurvesSlightlyAndIsSampledUnevenly() {
        var h = Humanize(enabled: true, seed: 5)
        let drag = h.drag(from: (100, 600), to: (300, 600), seconds: 0.3, rest: 0.15)
        let side = drag.map { abs($0.y - 600) }
        XCTAssertGreaterThan(side.max()!, 0.5, "an arc, not a ruler line")
        XCTAssertLessThan(side.max()!, 7, "but a slight one")
        let gaps = zip(drag.dropFirst(), drag).map { $0.t - $1.t }.filter { $0 > 0 }
        XCTAssertGreaterThan(Set(gaps.map { Int($0 * 10000) }).count, gaps.count / 2, "no fixed frame cadence")
        XCTAssertTrue(drag.map(\.t) == drag.map(\.t).sorted())
        XCTAssertTrue(zip(drag.dropFirst(), drag).allSatisfy { $0.x >= $1.x - 0.3 }, "the finger never goes back along the chord")
    }

    func testOffGivesTheExactLegacySchedule() {
        var h = Humanize.off
        XCTAssertEqual(h.tap(at: (10, 20)).map { "\($0.x),\($0.y),\($0.t)" }, ["10.0,20.0,0.0", "10.0,20.0,0.05"])
        let drag = h.drag(from: (0, 0), to: (0, 100), seconds: 0.4, rest: 0.15)
        XCTAssertEqual(drag.map(\.t), [0, 0.4, 0.55])
        XCTAssertEqual(drag.map(\.y), [0, 100, 100])
        XCTAssertEqual(h.drag(from: (0, 0), to: (0, 100), seconds: 0.25).map(\.t), [0, 0.25])
        XCTAssertTrue(h.typing("hello there").isEmpty == false)
    }

    func testTypingGoesInWordBurstsAtAQuickTypistsPace() {
        var h = Humanize(enabled: true, seed: 2)
        let plan = h.typing("meet me at the station at 7")
        XCTAssertEqual(plan.map(\.text).joined(), "meet me at the station at 7", "nothing lost or reordered")
        XCTAssertEqual(plan.map(\.text), ["meet ", "me ", "at ", "the ", "station ", "at ", "7"])
        XCTAssertEqual(plan.first!.gapBefore, 0)
        XCTAssertTrue(plan.dropFirst().allSatisfy { $0.gapBefore >= 0.04 && $0.gapBefore <= 0.22 })
        XCTAssertTrue(plan.allSatisfy { $0.frequency >= 12 && $0.frequency <= 40 })
        XCTAssertGreaterThan(Set(plan.map(\.frequency)).count, 2, "the pace varies")
        let seconds = Humanize.seconds(of: plan)
        XCTAssertGreaterThan(seconds, 0.8)
        XCTAssertLessThan(seconds, 3.0, "27 characters in well under 3 s")
    }

    func testLongTextTypesFasterAndCJKIsCutIntoShortBursts() {
        var h = Humanize(enabled: true, seed: 2)
        let long = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 4) // 176 characters
        let plan = h.typing(long)
        XCTAssertEqual(plan.map(\.text).joined(), long)
        XCTAssertLessThan(Humanize.seconds(of: plan), 6, "a long text is not read out letter by letter")
        XCTAssertTrue(plan.allSatisfy { $0.frequency >= 40 })
        let cjk = h.typing("今天天气很好我们去公园")
        XCTAssertEqual(cjk.map(\.text).joined(), "今天天气很好我们去公园")
        XCTAssertGreaterThan(cjk.count, 2, "text without spaces still comes in bursts")
        XCTAssertTrue(cjk.allSatisfy { $0.text.count <= 6 })
    }

    func testTheW3CBodyCarriesEverySampleAsATimedStep() {
        let body = Humanize.actions([[(10, 20, 0), (10, 20, 0.03), (11, 21, 0.08)]])
        let s = steps(body)
        XCTAssertEqual(s.map { $0["type"]?.string }, ["pointerMove", "pointerDown", "pause", "pointerMove", "pointerUp"])
        XCTAssertEqual(s[2]["duration"]?.double, 30)
        XCTAssertEqual(s[3]["duration"]?.double, 50)
        XCTAssertEqual(s[3]["x"]?.double, 11)
        XCTAssertEqual(body["actions"]?[0]?["parameters"]?["pointerType"]?.string, "touch")
        XCTAssertEqual(Humanize.seconds(of: [[(0, 0, 0), (0, 0, 0.5)], [(0, 0, 0), (0, 0, 0.7)]]), 0.7)
    }

    // MARK: The session

    func testAShapedTapGoesThroughActionsInsideTheElementAndAnOlderRunnerGetsWDAsTap() async {
        let (core, wda, _) = makeCore { $0.humanize = true }
        wda.tree([Node("Button", "Select", [300, 60, 80, 40])], app: "Photos")
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0)
        let body = wda.bodies("POST /actions").first
        let s = steps(body)
        XCTAssertEqual(s.first?["type"]?.string, "pointerMove")
        XCTAssertEqual(s[1]["type"]?.string, "pointerDown")
        XCTAssertEqual(s.last?["type"]?.string, "pointerUp")
        let x = s.first?["x"]?.double ?? 0, y = s.first?["y"]?.double ?? 0
        XCTAssertTrue(x >= 320 && x <= 360 && y >= 70 && y <= 90, "inside the button's middle: \(x), \(y)")
        XCTAssertTrue(total(body) >= 0.05 && total(body) <= 0.14, "pressed \(total(body)) s")
        XCTAssertTrue(result.text.contains("tap \"Select\" (sent"), result.text)

        wda.set("POST /actions") { _ in (404, ["value": ["error": "unknown command", "message": "Unhandled endpoint"]]) }
        let again = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertFalse(again.isError, again.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, "the legacy tap")
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["x"]?.double, 340)
    }

    func testAShapedSwipeIsAManySampleFlickAndADragComesToRest() async {
        let (core, wda, _) = makeCore { $0.humanize = true }
        _ = await core.call("look", [:])
        let swipe = await core.call("do", ["actions": [["swipe": "up"]]])
        XCTAssertFalse(swipe.isError, swipe.text)
        XCTAssertEqual(wda.bodies("POST /wda/pressAndDragWithVelocity").count, 0)
        let flick = wda.bodies("POST /actions").first
        XCTAssertGreaterThanOrEqual(moves(flick).count, 7, "sampled along the way")
        XCTAssertEqual(steps(flick).last?["type"]?.string, "pointerUp")
        XCTAssertNotEqual(steps(flick).dropLast().last?["type"]?.string, "pause", "a flick lifts while moving")
        XCTAssertEqual(total(flick), 0.25, accuracy: 0.05, "the swipe keeps its 250 ms")
        let ys = moves(flick).compactMap { $0["y"]?.double }
        XCTAssertGreaterThan(ys.first!, ys.last!, "the finger goes up")

        let drag = await core.call("do", ["actions": [["drag": [200, 600, 200, 200]]]])
        XCTAssertFalse(drag.isError, drag.text)
        let body = wda.bodies("POST /actions").last
        let s = steps(body)
        XCTAssertEqual(s.dropLast().last?["type"]?.string, "pause", "held still before the lift")
        XCTAssertEqual(s.dropLast().last?["duration"]?.double ?? 0, 150, accuracy: 1, "for the drag's 150 ms rest")
        XCTAssertEqual(total(body), 0.55, accuracy: 0.05)
        XCTAssertEqual(moves(body).last?["y"]?.double ?? 0, 200, accuracy: 4.5)
        XCTAssertTrue(drag.text.contains("drag from [200, 600] to [200, 200] in 400 ms"), drag.text)
    }

    func testARunnerWithoutActionsGetsThePressDrag() async {
        let (core, wda, _) = makeCore { $0.humanize = true }
        wda.set("POST /actions") { _ in (404, ["value": ["error": "unknown command", "message": "Unhandled endpoint"]]) }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["swipe": "up"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/pressAndDragWithVelocity").count, 1)
        XCTAssertEqual(wda.bodies("POST /wda/pressAndDragWithVelocity").first?["holdDuration"]?.double, 0)
    }

    /// scroll_to keeps its slow tail with shaped input (the shaped resting drag moved the gym's list
    /// 392-640 pt a swipe, the slow tail a steady 442-471), with its points and times varied a little.
    func testScrollToKeepsItsSlowTailVariedALittle() async {
        let (core, wda, _) = makeCore { $0.humanize = true }
        wda.source((1...30).map { ("Cell", "Row \($0)") })
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["scroll_to": ["text": "Row 99", "max_swipes": 2]]]])
        XCTAssertFalse(result.isError, result.text)
        // The fake runner records scroll_to's one-finger W3C drag under the press-drag route.
        let drags = wda.bodies("POST /wda/pressAndDragWithVelocity")
        XCTAssertEqual(drags.count, 2, "two swipes: \(wda.sent)")
        for d in drags {
            XCTAssertEqual(d["w3c"], .bool(true))
            XCTAssertEqual(d["holdDuration"]?.double ?? 0, 0.25, accuracy: 0.03, "the slow tail, within 10 %")
        }
        // A point varies by up to 2 pt and a time by up to 10 %, so one field can repeat by chance; the whole drag does not.
        XCTAssertNotEqual(drags[0], drags[1], "no two swipes alike")
    }

    func testALongPressHoldsExactlyAsAskedAndThePasteMenuOpensWithOne() async {
        let (core, wda, _) = makeCore { $0.humanize = true }
        wda.tree([Node("Cell", "Photo", [0, 100, 390, 120])], app: "Photos")
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["long_press": ["ref": 1, "ms": 900]]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/touchAndHold").count, 0)
        XCTAssertEqual(total(wda.bodies("POST /actions").first), 0.9, accuracy: 0.002)
        XCTAssertTrue(result.text.contains("long_press"), result.text)
    }

    func testShapedTypingGoesInBurstsWithAPaceAndReadsBackWhole() async {
        let (core, wda, _) = makeCore { $0.humanize = true }
        let field = FaultTests.Field()
        field.install(wda)
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "see you at noon"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(field.value.value, "see you at noon")
        let bursts = wda.bodies("POST /wda/keys")
        XCTAssertEqual(bursts.count, 4, "one burst a word: \(bursts)")
        XCTAssertTrue(bursts.allSatisfy { ($0["frequency"]?.double ?? 0) >= 12 && ($0["frequency"]?.double ?? 0) <= 40 })
        XCTAssertEqual(bursts.map { ($0["value"]?.array ?? []).compactMap(\.string).joined() }, ["see ", "you ", "at ", "noon"])
        XCTAssertTrue(result.text.contains("the field now reads \"see you at noon\""), result.text)
    }

    func testClearDeletesInOneBurstThenTypesInBursts() async {
        let (core, wda, _) = makeCore { $0.humanize = true }
        let field = FaultTests.Field()
        field.value.value = "old text"
        field.install(wda)
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "new", "clear": true]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(field.value.value, "new")
        let bursts = wda.bodies("POST /wda/keys")
        XCTAssertEqual(bursts.first?["value"]?.array?.count, 8, "the deletes first, at the keyboard's own pace")
        XCTAssertNil(bursts.first?["frequency"])
        XCTAssertEqual(bursts.count, 2)
    }

    func testTypingWithNoTimeForBurstsGoesInOneCall() async {
        let (core, wda, _) = makeCore { $0.humanize = true; $0.actionCap = 1.2 }
        let field = FaultTests.Field()
        field.install(wda)
        _ = await core.call("look", [:])
        let text = String(repeating: "a long text that does not fit the action's time at a person's pace ", count: 3)
        let result = await core.call("do", ["actions": [["type": .string(text)]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(field.value.value, text)
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1, "one call at the fixed pace: \(wda.sent)")
    }

    func testALongTextIsAtMostFourKeyCalls() async {
        var h = Humanize(enabled: true, seed: 7)
        let plan = h.typing("meet me by the old fountain near the north gate")
        XCTAssertGreaterThan(plan.count, 4)
        let merged = Humanize.merged(plan, into: 4)
        XCTAssertLessThanOrEqual(merged.count, 4)
        XCTAssertEqual(merged.map(\.text).joined(), "meet me by the old fountain near the north gate")
        XCTAssertEqual(merged.first?.gapBefore, 0)
    }

    /// CI simulator: on a loaded WebDriverAgent each key call answered only after the app was idle,
    /// and "Wi-Fi 你好" in bursts ran past the 9 s action half-typed. Once the first burst shows what
    /// a call costs, the rest goes in one call.
    func testASlowRunnerGetsTheRestOfTheTextInOneCall() async {
        let (core, wda, _) = makeCore { $0.humanize = true; $0.actionCap = 6 }
        let field = FaultTests.Field()
        field.install(wda)
        wda.delay("POST /wda/keys", 2)
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "Wi-Fi 你好"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(field.value.value, "Wi-Fi 你好")
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 2, "one burst, then the rest at once: \(wda.bodies("POST /wda/keys"))")
        XCTAssertNil(wda.bodies("POST /wda/keys").last?["frequency"])
    }

    func testThePinchIsTwoShapedFingers() async {
        let (core, wda, _) = makeCore { $0.humanize = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["pinch": ["x": 195, "y": 400, "scale": 2]]]])
        XCTAssertFalse(result.isError, result.text)
        let fingers = wda.bodies("POST /actions").first?["actions"]?.array ?? []
        XCTAssertEqual(fingers.count, 2)
        for f in fingers {
            let s = f["actions"]?.array ?? []
            XCTAssertGreaterThanOrEqual(s.filter { $0["type"]?.string == "pointerMove" }.count, 7)
            XCTAssertEqual(s.last?["type"]?.string, "pointerUp")
        }
    }

    func testOffSendsTheLegacyEndpointsExactly() async {
        let (core, wda, _) = makeCore { $0.humanize = false }
        wda.tree([Node("Button", "Select", [300, 60, 80, 40])], app: "Photos")
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["tap": 1], ["swipe": "up"], ["long_press": ["ref": 1, "ms": 500]]]])
        XCTAssertEqual(wda.bodies("POST /actions").count, 0)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["x"]?.double, 340)
        XCTAssertEqual(wda.bodies("POST /wda/pressAndDragWithVelocity").count, 1)
        XCTAssertEqual(wda.bodies("POST /wda/touchAndHold").first?["duration"]?.double, 0.5)
    }
}
