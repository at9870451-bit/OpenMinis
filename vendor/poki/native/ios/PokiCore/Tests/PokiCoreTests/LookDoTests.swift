import XCTest
@testable import PokiCore

/// The fixes from an agent's run in X: taps that cannot land, swipes that started on the reply bar,
/// slow drags, no-op actions that looked like success, the picture's scale, collapsed cells, fixed
/// waits and repeated text.
final class LookDoTests: XCTestCase {
    func testSplitViewSetupKeepsTheLauncherPrivateAndReleasesTheQueueOnStop() async throws {
        let (core, wda, _) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true))
        wda.set("POST /poki/workspace-launcher") { _ in (200, ["value": true]) }
        let reserved = await core.prepareWorkspace(session: "setup")
        XCTAssertTrue(reserved)
        let outside = await core.callTool("look", arguments: "{}", localSession: "other")
        XCTAssertTrue(outside.isError)
        XCTAssertNil(outside.jpeg)
        let unlisted = await core.callTool("workspace-launcher", arguments: "{}", localSession: "setup")
        XCTAssertTrue(unlisted.isError)
        do {
            _ = try await core.workspaceLauncherStep(session: "other", request: [:])
            XCTFail("Another session must not send launcher input")
        } catch is CancellationError {}
        XCTAssertTrue(wda.bodies("POST /poki/workspace-launcher").isEmpty)
        let result = try await core.workspaceLauncherStep(session: "setup", request: ["labels": ["Notes"], "menu": false])
        XCTAssertEqual(result, true)
        XCTAssertEqual(wda.bodies("POST /poki/workspace-launcher").count, 1)
        _ = await core.finishTask(switching: false, localSession: "setup")
        let released = await core.prepareWorkspace(session: "other")
        XCTAssertTrue(released)
        XCTAssertTrue(wda.bodies("POST /wda/apps/activate").isEmpty)
    }

    func testSplitViewTypingRetriesOnlyKeysThatWereNotSent() async throws {
        let (core, wda, _) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true)) { $0.humanize = false }
        let owned = await core.prepareWorkspace(session: "local")
        XCTAssertTrue(owned)
        let attempts = LockedBox(0)
        wda.set("POST /wda/keys") { _ in
            attempts.update { $0 += 1 }
            if attempts.value == 1 {
                return (500, ["value": ["error": "unknown error", "message": "not sent: finishing the focus read; nothing lands late"]])
            }
            return (200, ["value": .null])
        }
        try await core.computer.sendKeys(deletes: 0, text: "Duo", until: now() + 6)
        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(wda.bodies("POST /wda/keys").first, wda.bodies("POST /wda/keys").last)

        wda.set("POST /wda/keys") { _ in throw TransportError.other("delivery unknown") }
        do {
            try await core.computer.sendKeys(deletes: 0, text: "Duo", until: now() + 6)
            XCTFail("Unknown delivery must be verified before typing again")
        } catch let error as RunnerError {
            XCTAssertEqual(error.delivery, .unknown)
        }
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 3)
    }

    func testPlannedSplitViewChecksBothAppIdentitiesBeforeReading() async {
        let (core, wda, _) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true))
        wda.set("POST /poki/pane") { _ in
            (200, ["value": ["identity": "left/workspace", "bundleId": "com.apple.mobilenotes", "otherBundleId": "local.wrong"]])
        }
        let response = await core.callTool("look", arguments: "{\"pane\":\"left\"}", localSession: "chat-task",
                                           expectedApps: ["com.apple.mobilenotes", "com.apple.mobilesafari"])
        XCTAssertTrue(response.isError)
        XCTAssertNil(response.jpeg)
        XCTAssertTrue(response.text.contains("do not match the planned Split View pair"))
        let tap = await core.callTool("do", arguments: "{\"actions\":[{\"tap\":[100,100]}]}", localSession: "chat-task")
        XCTAssertTrue(tap.text.contains("look at the selected pane before sending input"), tap.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)

        wda.set("POST /poki/pane") { _ in
            (200, ["value": ["identity": "left/new-layout", "bundleId": "com.apple.mobilesafari", "otherBundleId": "com.apple.mobilenotes"]])
        }
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.mobilesafari"]]) }
        let matched = await core.callTool("look", arguments: "{\"pane\":\"left\"}", localSession: "chat-task",
                                          expectedApps: ["com.apple.mobilenotes", "com.apple.mobilesafari"])
        XCTAssertFalse(matched.isError, matched.text)
        XCTAssertTrue(matched.text.contains("Split View: left is com.apple.mobilesafari"))
    }

    func testSplitViewPaneChangesInvalidateReferencesAndFinishLeavesBothAppsOpen() async {
        let (core, wda, _) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true))
        let side = LockedBox("left")
        wda.set("POST /poki/pane") { args in
            let next = args?["side"]?.string ?? "auto"
            side.value = next
            if next == "auto" { return (200, ["value": .null]) }
            let left = next == "left"
            return (200, ["value": ["identity": .string(next), "bundleId": left ? "local.a" : "local.b",
                                     "otherBundleId": left ? "local.b" : "local.a"]])
        }
        wda.set("GET /wda/activeAppInfo") { _ in
            let left = side.value == "left"
            return (200, ["value": ["bundleId": left ? "local.a" : "local.b"]])
        }
        wda.source([("Button", "Same control")])
        let left = await core.call("look", ["pane": "left"], session: "workspace-owner")
        XCTAssertTrue(left.text.contains("Split View: left is local.a"), left.text)
        let competing = await core.call("look", ["pane": "right"], session: "other")
        XCTAssertTrue(competing.isError, competing.text)
        XCTAssertEqual(side.value, "left")
        let right = await core.call("look", ["pane": "right"], session: "workspace-owner")
        XCTAssertTrue(right.text.contains("Split View: right is local.b"), right.text)
        let stale = await core.call("do", ["actions": [["tap": 1]]], session: "workspace-owner")
        XCTAssertTrue(stale.text.contains("not in the latest read"), stale.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
        let finished = await core.call("do", ["actions": [], "finish": true], session: "workspace-owner")
        XCTAssertTrue(finished.text.contains("both apps stay open"), finished.text)
        XCTAssertEqual(side.value, "auto")
        XCTAssertTrue(wda.bodies("POST /wda/apps/activate").isEmpty)
    }

    func testSplitViewReadWaitsForPaneIdentityAfterSlowTree() async {
        let (core, wda, _) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true)) {
            $0.readTimeout = 4
        }
        wda.set("POST /poki/pane") { _ in
            (200, ["value": ["identity": "left/restored", "bundleId": "com.apple.Preferences",
                            "otherBundleId": "com.apple.mobilesafari", "x": 0, "y": 0]])
        }
        // In-process activeAppInfo waits behind source, so a valid pane can take over 2 s.
        wda.delay("GET /source", 3)
        wda.delay("GET /wda/activeAppInfo", 3)
        wda.delay("GET /screenshot", 4.8)

        let read = await core.callTool("look", arguments: #"{"pane":"left"}"#, localSession: "chat-task",
                                       expectedApps: ["com.apple.Preferences", "com.apple.mobilesafari"])
        XCTAssertFalse(read.isError, read.text)
        XCTAssertNotNil(read.jpeg, read.text)
        XCTAssertEqual(read.splitView?.app, "com.apple.Preferences")
        XCTAssertTrue(read.text.contains("General"), read.text)
    }

    func testSplitViewLocalTaskKeepsExclusiveControlAndFinishesOnlyItsOwnSession() async {
        let (core, wda, _) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true)) { $0.taskGap = 0 }
        let side = LockedBox("auto")
        wda.set("POST /poki/pane") { args in
            side.value = args?["side"]?.string ?? "auto"
            return (200, ["value": ["identity": "left/workspace", "bundleId": "com.apple.Preferences", "otherBundleId": "local.b"]])
        }
        let read = await core.callTool("look", arguments: "{\"pane\":\"left\"}", localSession: "chat-task")
        XCTAssertFalse(read.isError, read.text)
        let outside = await core.call("look", ["pane": "right"], session: "outside")
        XCTAssertTrue(outside.text.contains("another task is using Split View"), outside.text)
        XCTAssertNil(outside.jpeg)
        let cancelledElsewhere = await core.finishTask(localSession: "outside")
        XCTAssertNil(cancelledElsewhere)
        let idleFinish = await core.finishTask(ifNoLocalWorkspace: true)
        XCTAssertNil(idleFinish)
        XCTAssertEqual(side.value, "left")
        let finished = await core.finishTask(localSession: "chat-task")
        XCTAssertEqual(finished, "finish: both apps stay open in Split View")
        XCTAssertEqual(side.value, "auto")
        XCTAssertTrue(wda.bodies("POST /wda/apps/activate").isEmpty)
    }

    func testSplitViewStopWithdrawsApprovalWithoutSendingTheWaitingAction() async throws {
        let (core, wda, _) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true)) { $0.approvalWait = 30 }
        wda.set("POST /poki/pane") { _ in
            (200, ["value": ["identity": "left/workspace", "bundleId": "com.apple.Preferences", "otherBundleId": "local.b"]])
        }
        wda.source([("Button", "Delete test item")])
        let read = await core.callTool("look", arguments: "{\"pane\":\"left\"}", localSession: "workspace")
        XCTAssertFalse(read.isError, read.text)
        let call = Task {
            await core.callTool("do", arguments: "{\"actions\":[{\"tap\":1}]}", localSession: "workspace")
        }
        defer { call.cancel() }
        let requested = await eventually { core.pendingApproval != nil }
        XCTAssertTrue(requested)
        let approval = try XCTUnwrap(core.pendingApproval)
        let outside = await core.callTool("look", arguments: "{\"pane\":\"right\"}", localSession: "outside")
        XCTAssertTrue(outside.isError, outside.text)
        XCTAssertNil(outside.jpeg)
        let voice = await core.clearTap(on: "Delete test item", inApp: "com.apple.Preferences", named: "Settings", waiting: 1)
        XCTAssertFalse(voice.mayTap)
        XCTAssertEqual(core.pendingApproval?.id, approval.id)
        call.cancel()
        let result = await call.value
        XCTAssertTrue(result.isError, result.text)
        let revoked = await eventually { core.pendingApproval == nil }
        XCTAssertTrue(revoked)
        XCTAssertNil(core.pendingApproval)
        core.resolveApproval(id: approval.id, approved: true)
        let finished = await core.finishTask(localSession: "workspace")
        XCTAssertEqual(finished, "finish: both apps stay open in Split View")
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
        XCTAssertTrue(wda.bodies("POST /wda/apps/activate").isEmpty)
    }

    func testSplitViewStopReleasesTheOwnerHandoffForTheNextTask() async throws {
        let (core, wda, _) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true))
        wda.set("POST /poki/pane") { args in
            let side = args?["side"]?.string ?? "auto"
            return (200, ["value": ["identity": .string("\(side)/workspace"), "bundleId": "com.apple.Preferences", "otherBundleId": "local.b"]])
        }
        let read = await core.callTool("look", arguments: "{\"pane\":\"left\"}", localSession: "old")
        XCTAssertFalse(read.isError, read.text)
        let handoff = await core.callTool("do", arguments: "{\"actions\":[{\"handoff\":\"Review the test screen\"}]}", localSession: "old")
        XCTAssertFalse(handoff.isError, handoff.text)
        let id = try XCTUnwrap(core.handoff?.id)
        _ = await core.finishTask(switching: false)
        XCTAssertNil(core.handoff)
        core.handoffDone(id: id)
        _ = await core.finishTask(localSession: "old")
        let again = await core.callTool("look", arguments: "{\"pane\":\"right\"}", localSession: "new")
        XCTAssertFalse(again.isError, again.text)
        XCTAssertFalse(again.text.contains("handoff:"), again.text)
        XCTAssertTrue(wda.bodies("POST /wda/apps/activate").isEmpty)
    }

    func testSplitViewApprovalDoesNotCarryOverWhenTheOwnerReturnsToAPane() async throws {
        let (core, wda, _) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true)) { $0.approvalWait = 0 }
        let side = LockedBox("left")
        wda.set("POST /poki/pane") { args in
            side.value = args?["side"]?.string ?? "auto"
            return (200, ["value": ["identity": .string("\(side.value)/workspace"), "bundleId": "com.apple.Preferences", "otherBundleId": "local.b"]])
        }
        wda.source([("Button", "Delete test item")])
        func read(_ side: String) async {
            let result = await core.callTool("look", arguments: "{\"pane\":\"\(side)\"}", localSession: "workspace")
            XCTAssertFalse(result.isError, result.text)
        }
        await read("left")
        let action = "{\"actions\":[{\"tap\":[120,120]}]}"
        let held = await core.callTool("do", arguments: action, localSession: "workspace")
        XCTAssertTrue(held.text.contains("approval_required"), held.text)
        let approval = try XCTUnwrap(core.pendingApproval)
        core.resolveApproval(id: approval.id, approved: true)
        await read("right")
        await read("left")
        let retry = await core.callTool("do", arguments: action, localSession: "workspace")
        XCTAssertTrue(retry.text.contains("approval_required"), retry.text)
        XCTAssertNotEqual(core.pendingApproval?.id, approval.id)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testSplitViewDragRequiresBothFreshPaneReadsAndOneContinuousGesture() async {
        let (core, wda, _) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true))
        let side = LockedBox("left")
        wda.set("POST /poki/pane") { args in
            let next = args?["side"]?.string ?? "auto"
            side.value = next
            let left = next == "left"
            return (200, ["value": ["identity": .string("\(next)/workspace"),
                                    "bundleId": left ? "com.apple.mobilenotes" : "com.apple.mobilesafari",
                                    "otherBundleId": left ? "com.apple.mobilesafari" : "com.apple.mobilenotes",
                                    "x": left ? 0 : 400, "y": 0]])
        }
        wda.set("GET /wda/activeAppInfo") { _ in
            (200, ["value": ["bundleId": side.value == "left" ? "com.apple.mobilenotes" : "com.apple.mobilesafari"]])
        }
        #if canImport(Vision) && canImport(ImageIO) && canImport(CoreText) && os(macOS)
        let picture = LockedBox(PictureSketchTests.png { _ in })
        wda.set("GET /screenshot") { _ in (200, ["value": .string(picture.value.base64EncodedString())]) }
        #endif
        wda.set("POST /poki/workspace-drag") { _ in (200, ["value": .null]) }
        let drag: JSON = ["actions": [["drag": ["from": [150, 150], "to": [100, 100], "to_pane": "left"]]]]
        _ = await core.call("look", ["pane": "right"])
        let refused = await core.call("do", drag)
        XCTAssertTrue(refused.text.contains("read both panes"), refused.text)
        XCTAssertTrue(wda.bodies("POST /poki/workspace-drag").isEmpty)
        _ = await core.call("look", ["pane": "left"])
        _ = await core.call("look", ["pane": "right"])
        let sent = await core.call("do", drag)
        XCTAssertTrue(sent.text.contains("look there to confirm"), sent.text)
        let path = wda.bodies("POST /poki/workspace-drag").first?["actions"]?.array?.first?["actions"]?.array ?? []
        XCTAssertEqual(path.filter { $0["type"]?.string == "pointerDown" }.count, 1)
        XCTAssertEqual(path.filter { $0["type"]?.string == "pointerUp" }.count, 1)
        XCTAssertEqual(path.last(where: { $0["type"]?.string == "pointerMove" })?["x"]?.int, -300)
        let repeatDrop = await core.call("do", drag)
        XCTAssertTrue(repeatDrop.text.contains("already dragged"), repeatDrop.text)
        XCTAssertEqual(wda.bodies("POST /poki/workspace-drag").count, 1)
        let wrongPane = await core.call("look", ["pane": "right"])
        XCTAssertFalse(wrongPane.text.contains("Split View drop:"), wrongPane.text)
        #if canImport(Vision) && canImport(ImageIO) && canImport(CoreText) && os(macOS)
        picture.value = PictureSketchTests.png { $0.fill(CGRect(x: 40, y: 440, width: 150, height: 150)) }
        #else
        wda.tree([Node("Image", nil, [40, 70, 150, 150]), Node("Button", "Done", [20, 300, 60, 40])])
        #endif
        let evidence = await core.call("look", ["pane": "left"])
        #if canImport(Vision) && canImport(ImageIO) && canImport(CoreText) && os(macOS)
        XCTAssertTrue(evidence.text.contains("before: 0, now: 0"), evidence.text)
        XCTAssertTrue(evidence.text.contains("destination screenshot changed within ["), evidence.text)
        wda.tree([Node("Image", nil, [40, 70, 150, 150]), Node("Button", "Done", [20, 300, 60, 40])])
        let labeledByType = await core.call("look", ["pane": "left"])
        XCTAssertTrue(labeledByType.text.contains("Image \"\" [40,70,150,150]"), labeledByType.text)
        #else
        XCTAssertTrue(evidence.text.contains("before: 0, now: 1"), evidence.text)
        #endif
        let again = await core.call("look", ["pane": "left"])
        XCTAssertFalse(again.text.contains("Split View drop:"), again.text)

        _ = await core.call("look", ["pane": "right"])
        let adjustedDrop: JSON = ["actions": [["drag": ["from": [155, 152], "to": [110, 140], "to_pane": "left"]]]]
        let alreadySent = await core.call("do", adjustedDrop)
        XCTAssertTrue(alreadySent.text.contains("already dragged"), alreadySent.text)
        XCTAssertEqual(wda.bodies("POST /poki/workspace-drag").count, 1)
        let differentItem: JSON = ["actions": [["drag": ["from": [220, 180], "to": [100, 100], "to_pane": "left"]]]]
        let anotherDrop = await core.call("do", differentItem)
        XCTAssertTrue(anotherDrop.text.contains("look there to confirm"), anotherDrop.text)
        XCTAssertEqual(wda.bodies("POST /poki/workspace-drag").count, 2)
    }

    func testSplitViewDragCannotBeReplayedAfterLayoutChangesEvenWhenDestinationMoves() async {
        let (core, wda, _) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true))
        let layout = LockedBox("landscape")
        let selected = LockedBox("left")
        wda.set("POST /poki/pane") { args in
            let side = args?["side"]?.string ?? "left"
            if layout.value == "portrait" { return (400, ["value": ["error": "invalid argument", "message": "two visible apps could not be confirmed"]]) }
            selected.value = side
            let notes = (side == "left") == (layout.value == "landscape")
            return (200, ["value": ["identity": .string("\(side)/\(layout.value)"),
                "bundleId": notes ? "com.apple.mobilenotes" : "com.apple.mobilesafari",
                "otherBundleId": notes ? "com.apple.mobilesafari" : "com.apple.mobilenotes",
                "x": side == "left" ? 0 : 400, "y": 0]])
        }
        wda.set("GET /wda/activeAppInfo") { _ in
            let notes = (selected.value == "left") == (layout.value == "landscape")
            return (200, ["value": ["bundleId": notes ? "com.apple.mobilenotes" : "com.apple.mobilesafari"]])
        }
        wda.set("POST /poki/workspace-drag") { _ in
            layout.value = "portrait"
            return (200, ["value": .null])
        }
        let session = "rotation"
        _ = await core.call("look", ["pane": "left"], session: session, local: true)
        _ = await core.call("look", ["pane": "right"], session: session, local: true)
        let first: JSON = ["actions": [["drag": ["from": [150, 150], "to": [100, 100], "to_pane": "left"]]]]
        _ = await core.call("do", first, session: session, local: true)
        let interrupted = await core.call("look", ["pane": "left"], session: session, local: true)
        XCTAssertTrue(interrupted.isError, interrupted.text)
        XCTAssertTrue(interrupted.splitViewNeedsRead, interrupted.text)
        XCTAssertNil(interrupted.jpeg)

        // iOS can bring back the original binding with the exact same pane geometry.
        layout.value = "landscape"
        let sameDestination = await core.call("look", ["pane": "left"], session: session, local: true)
        XCTAssertTrue(sameDestination.text.contains("Do not repeat the drag"), sameDestination.text)

        layout.value = "rotatedBack"
        let destination = await core.call("look", ["pane": "right"], session: session, local: true)
        XCTAssertTrue(destination.text.contains("Do not repeat the drag"), destination.text)
        let source = await core.call("look", ["pane": "left"], session: session, local: true)
        XCTAssertFalse(source.isError, source.text)
        let replay: JSON = ["actions": [["drag": ["from": [150, 150], "to": [100, 100], "to_pane": "right"]]]]
        let refused = await core.call("do", replay, session: session, local: true)
        XCTAssertTrue(refused.text.contains("interrupted drags are not replayed"), refused.text)
        XCTAssertEqual(wda.bodies("POST /poki/workspace-drag").count, 1)
    }

    func testSplitViewDragWithUnknownDeliveryWaitsForFreshReadsAfterQuickRotation() async {
        let (core, wda, _) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true))
        let revision = LockedBox(1)
        let selected = LockedBox("left")
        let notes = "com.apple.mobilenotes", safari = "com.apple.mobilesafari"
        wda.set("POST /poki/pane") { args in
            let side = args?["side"]?.string ?? "left"
            selected.value = side
            return (200, ["value": ["identity": .string("\(side)/\(revision.value)"),
                "bundleId": .string(side == "left" ? notes : safari),
                "otherBundleId": .string(side == "left" ? safari : notes),
                "x": side == "left" ? 0 : 400, "y": 0]])
        }
        wda.set("GET /wda/activeAppInfo") { _ in
            (200, ["value": ["bundleId": .string(selected.value == "left" ? notes : safari)]])
        }
        wda.set("POST /poki/workspace-drag") { _ in
            // The native driver sees a turn during dispatch. By the next read the panes
            // have returned to their original positions, but the orientation revision advanced.
            revision.value += 2
            throw TransportError.other("sent, no confirmation: split_view_changed_after_dispatch")
        }

        let session = "quick-rotation-during-drag"
        let original = await core.call("look", ["pane": "left"], session: session, local: true)
        _ = await core.call("look", ["pane": "right"], session: session, local: true)
        let drag: JSON = ["actions": [["drag": ["from": [150, 150], "to": [100, 100], "to_pane": "left"]]]]
        let interrupted = await core.call("do", drag, session: session, local: true)
        XCTAssertTrue(interrupted.splitViewNeedsRead, interrupted.text)
        XCTAssertTrue(interrupted.text.contains("split_view_changed_after_dispatch"), interrupted.text)

        let tap: JSON = ["actions": [["tap": [100, 100]]]]
        let stale = await core.call("do", tap, session: session, local: true)
        XCTAssertTrue(stale.splitViewNeedsRead, stale.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)

        let destination = await core.call("look", ["pane": "left"], session: session, local: true)
        XCTAssertEqual(destination.splitView?.app, notes, destination.text)
        XCTAssertNotEqual(destination.splitView?.layout, original.splitView?.layout)
        XCTAssertTrue(destination.text.contains("Do not repeat the drag"), destination.text)
        _ = await core.call("look", ["pane": "right"], session: session, local: true)
        let replay = await core.call("do", drag, session: session, local: true)
        XCTAssertTrue(replay.text.contains("interrupted drags are not replayed"), replay.text)
        XCTAssertEqual(wda.bodies("POST /poki/workspace-drag").count, 1)

        let fresh = await core.call("do", tap, session: session, local: true)
        XCTAssertFalse(fresh.isError, fresh.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testSplitViewRotationNeverTapsAnOldDraftFieldAndFocusesTheRestoredOne() async {
        let (core, wda, _) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true))
        let layout = LockedBox("original")
        let field = "Draft message"
        wda.source([("TextField", field)])
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "local.notes"]]) }
        wda.set("POST /poki/pane") { args in
            let side = args?["side"]?.string ?? "left"
            let key = layout.value
            if key == "portrait" { return (400, ["value": ["error": "invalid argument", "message": "two visible apps could not be confirmed"]]) }
            return (200, ["value": ["identity": .string("\(side)/\(key)"), "bundleId": "local.notes",
                "otherBundleId": key == "wrongPair" ? "local.weather" : "local.safari",
                "x": side == "left" ? 0 : 400, "y": 0]])
        }
        let session = "draft-rotation"
        let expected: Set<String> = ["local.notes", "local.safari"]
        let original = await core.call("look", ["pane": "left"], session: session, local: true, expectedApps: expected)
        XCTAssertFalse(original.isError, original.text)
        XCTAssertTrue(original.text.contains(field), original.text)

        for incompatibleLayout in ["portrait", "wrongPair"] {
            layout.value = incompatibleLayout
            let read = await core.call("look", ["pane": "left"], session: session, local: true, expectedApps: expected)
            XCTAssertTrue(read.splitViewNeedsRead, read.text)
            XCTAssertNil(read.jpeg)
            let tap = await core.call("do", ["actions": [["tap": [100, 100]]]], session: session, local: true)
            XCTAssertTrue(tap.splitViewNeedsRead, tap.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
        }

        layout.value = "restored"
        let restored = await core.call("look", ["pane": "right"], session: session, local: true, expectedApps: expected)
        XCTAssertEqual(restored.splitView?.app, "local.notes", restored.text)
        XCTAssertNotEqual(restored.splitView?.layout, original.splitView?.layout)
        let tap = await core.call("do", ["actions": [["tap": [100, 100]]]], session: session, local: true)
        XCTAssertFalse(tap.isError, tap.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testSplitViewPaneIsReportedUnavailableOnOtherAutomationPaths() async {
        let (core, wda, _) = makeCore()
        let result = await core.call("look", ["pane": "right"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("unavailable"), result.text)
        XCTAssertTrue(wda.bodies("POST /poki/pane").isEmpty)
    }

    func testSplitViewDoesNotUseAFullScreenFallbackWhenTheSelectedAppDisappears() async {
        let (core, wda, host) = makeCore(FakeWDA(dynamicSize: true, paneSelection: true))
        wda.set("POST /poki/pane") { _ in
            (200, ["value": ["identity": "left", "bundleId": "local.a", "otherBundleId": "local.b"]])
        }
        host.ownScreenshot.value = Data("full screen".utf8)
        wda.set("GET /screenshot") { _ in (500, ["value": ["error": "unknown error", "message": "workspace changed"]]) }
        let read = await core.call("look", ["pane": "left"])
        XCTAssertTrue(read.isError, read.text)
        XCTAssertNil(read.jpeg)
        let action = await core.call("do", ["actions": [["tap": [80, 120]]]])
        XCTAssertTrue(action.text.contains("nothing was sent"), action.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    /// A reply thread: a table of posts with a reply bar drawn over its bottom.
    func thread(_ wda: FakeWDA, quotedY: Double = 742) {
        wda.tree([
            Node("Table", nil, [0, 0, 390, 844], [
                Node("Cell", "Post one", [0, 100, 390, 120]),
                Node("Cell", "Post two", [0, 220, 390, 120]),
                Node("Cell", "Quoted post", [0, quotedY, 390, 120]),
            ]),
            Node("Other", nil, [0, 744, 390, 100], [Node("TextView", "Post your reply", [16, 760, 300, 40])]),
        ])
    }

    func testTheSessionTurnsOffWDAsWaitsAfterEveryGesture() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        let settings = wda.bodies("POST /appium/settings").first?["settings"]
        XCTAssertEqual(settings?["animationCoolOffTimeout"]?.double, 0)
        XCTAssertEqual(settings?["accessibilityDeadline"]?.double, 2, "a read of an app that never idles fails fast instead of blocking WDA")
        XCTAssertEqual(settings?["waitForIdleTimeout"]?.double, 0.5)
    }

    /// The tree's order is not the drawing order, so a cover is a hint, never a refusal: the element
    /// is touched at its centre and the answer names what the tree puts over it.
    func testAnElementUnderTheReplyBarIsTappedAnywayAndTheAnswerSaysWhatLiesOverIt() async {
        let (core, wda, _) = makeCore()
        thread(wda, quotedY: 750)
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("3 Cell \"Quoted post\" [0,750,390,120]"), look.text)
        let result = await core.call("do", ["actions": [["tap": 3]]])
        XCTAssertFalse(result.text.contains("not_hittable"), result.text)
        XCTAssertTrue(result.text.contains("at [195, 797] (Other and TextView \"Post your reply\" lies over all of its visible part in the tree; touched anyway"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["y"]?.double ?? 0, 797, accuracy: 0.5, "the centre of its visible part")
    }

    /// Seen on the phone: Photos' Select button came after the photo grid in the tree, and the
    /// thumbnails that scroll under it counted as covering it. What scrolls inside a list never covers
    /// what is outside the list.
    func testWhatScrollsInsideAListDoesNotCoverAButtonOutsideIt() async {
        let (core, wda, _) = makeCore()
        wda.tree([
            Node("Button", "Select", [300, 60, 80, 40]),
            Node("CollectionView", nil, [0, 50, 390, 790], [Node("Image", "Photo", [260, 50, 130, 130]), Node("Image", "Photo", [130, 50, 130, 130])]),
        ], app: "Photos")
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("tap \"Select\" (sent"), result.text)
        XCTAssertFalse(result.text.contains("in the tree"), result.text)
        let body = wda.bodies("POST /wda/tap").first
        XCTAssertEqual(body?["x"]?.double ?? 0, 340, accuracy: 0.5)
        XCTAssertEqual(body?["y"]?.double ?? 0, 80, accuracy: 0.5)
    }

    func testAPartlyCoveredElementIsTappedOnItsVisiblePart() async {
        let (core, wda, _) = makeCore()
        thread(wda, quotedY: 690) // 690-810: the centre (750) is under the bar, 690-744 is free
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 3]]])
        XCTAssertFalse(result.isError, result.text)
        let y = wda.bodies("POST /wda/tap").first?["y"]?.double ?? 0
        XCTAssertTrue(y > 690 && y < 744, "tapped at y \(y)")
        XCTAssertTrue(result.text.contains("(its centre is under Other"), result.text)
    }

    func testAPointOffTheScreenIsNotHittable() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": [200, 900]]]])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("not_hittable: [200, 900] is off the screen (390x844 points)"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0)
    }

    func testInvalidActionArraysAreRejectedBeforeAnyActionRuns() async {
        let (core, wda, _) = makeCore()
        let invalid: [JSON] = [
            [:], ["actions": "oops"], ["actions": [7]],
            ["actions": .array(Array(repeating: ["tap": [100, 100]], count: 21))],
        ]
        for args in invalid {
            let result = await core.call("do", args)
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(result.text.contains("nothing was sent"), result.text)
        }
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0)
    }

    func testNegativeWaitIsAnActionError() async {
        let (core, _, _) = makeCore()
        let result = await core.call("do", ["actions": [["wait": -5]]])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("wait takes nonnegative milliseconds"), result.text)
    }

    func testASwipeStartsInsideTheListClearOfTheReplyBarAsAQuickFlick() async {
        let (core, wda, _) = makeCore()
        thread(wda)
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["swipe": "up"]]])
        XCTAssertFalse(result.isError, result.text)
        guard let body = wda.bodies("POST /wda/pressAndDragWithVelocity").first else { return XCTFail("no gesture sent: \(wda.sent)") }
        let fromY = body["fromY"]!.double!, toY = body["toY"]!.double!
        XCTAssertLessThan(fromY, 744, "the finger must not land on the reply bar")
        XCTAssertGreaterThan(fromY, toY)
        XCTAssertGreaterThan(toY, 844 * 0.06)
        XCTAssertEqual(body["pressDuration"]?.double, 0)
        XCTAssertEqual(body["holdDuration"]?.double, 0)
        XCTAssertEqual(wda.bodies("POST /wda/dragfromtoforduration").count, 0)
    }

    func testADragStopsBeforeLiftingAndUsesItsOwnSpeed() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["drag": [200, 600, 200, 200]]]])
        XCTAssertFalse(result.isError, result.text)
        let body = wda.bodies("POST /wda/pressAndDragWithVelocity").first
        XCTAssertEqual(body?["velocity"]?.double, 1000) // 400 points in the default 400 ms
        XCTAssertEqual(body?["holdDuration"]?.double, 0.15)
        XCTAssertTrue(result.text.contains("drag from [200, 600] to [200, 200] in 400 ms"), result.text)
    }

    func testAnOlderRunnerFallsBackToItsDrag() async {
        let (core, wda, _) = makeCore()
        wda.set("POST /wda/pressAndDragWithVelocity") { _ in (404, ["value": ["error": "unknown command", "message": "Unhandled endpoint"]]) }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["swipe": "up"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/dragfromtoforduration").count, 1)
    }

    func testASlowGestureIsNotTakenAsTheRunnerBeingGone() async {
        let (core, wda, host) = makeCore { $0.actionCap = 1.2 }
        wda.set("POST /wda/pressAndDragWithVelocity") { _ in try await Task.sleep(nanoseconds: 30_000_000_000); return (200, ["value": .null]) }
        _ = await core.call("look", [:])
        for _ in 0..<2 {
            let result = await core.call("do", ["actions": [["swipe": "up"], ["tap": 1]]])
            XCTAssertTrue(result.text.contains("may have been delivered"), result.text)
            XCTAssertTrue(result.text.contains("app: Settings"), "the read after it still answers: \(result.text)")
        }
        XCTAssertEqual(host.restarts.value, 0)
        XCTAssertEqual(core.runner.consecutiveMisses, 0)
    }

    func testScreenChangedSaysWhenAnActionDidNothing() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        let same = await core.call("do", ["actions": [["tap": [200, 400]]]])
        XCTAssertTrue(same.text.contains("screen_changed: false (the elements and the picture are the same as in the read before)"), same.text)
        XCTAssertTrue(same.text.contains("elements: none changed (2 on screen keep their numbers)"), same.text)
        wda.source([("Button", "General"), ("Button", "Privacy"), ("Button", "Wi-Fi")])
        let changed = await core.call("do", ["actions": [["tap": [200, 400]]]])
        XCTAssertTrue(changed.text.contains("screen_changed: true (the elements changed)"), changed.text)
        wda.set("GET /screenshot") { _ in (200, ["value": .string(Data("png2".utf8).base64EncodedString())]) }
        let picture = await core.call("do", ["actions": [["tap": [200, 400]]]])
        XCTAssertTrue(picture.text.contains("screen_changed: true (only the picture changed"), picture.text)
    }

    func testCoordinatePauseExplainsWhyEvenWhenScreenDidNotChange() async {
        let (core, wda, _) = makeCore()
        wda.source([("Button", "Already selected")])
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": [100, 120]], ["tap": [100, 120]]]])
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
        XCTAssertTrue(result.text.contains("screen_changed: false"), result.text)
        XCTAssertTrue(result.text.contains("not_sent from action 2: a coordinate action needs a fresh read"), result.text)
    }

    func testNumbersStayAndDoListsOnlyWhatChanged() async {
        let (core, wda, _) = makeCore()
        wda.source([("Button", "A"), ("Button", "B"), ("Button", "C")])
        _ = await core.call("look", [:])
        wda.source([("Button", "A"), ("Button", "B"), ("Button", "C"), ("Button", "D")])
        let added = await core.call("do", ["actions": []])
        XCTAssertTrue(added.text.contains("+4 Button \"D\" [16,232,358,44]"), added.text)
        XCTAssertFalse(added.text.contains("Button \"A\""), added.text)
        // B is gone; C and D move up and keep their numbers.
        wda.source([("Button", "A"), ("Button", "C"), ("Button", "D")])
        let moved = await core.call("do", ["actions": []])
        XCTAssertTrue(moved.text.contains("~3 Button \"C\" [16,144,358,44]"), moved.text)
        XCTAssertTrue(moved.text.contains("gone since the last read: 2 Button \"B\""), moved.text)
        _ = await core.call("do", ["actions": [["tap": 4]]])
        XCTAssertEqual(wda.bodies("POST /wda/tap").last?["y"]?.double, 210)
        // A whole new screen numbers from 1 again.
        wda.source([("Button", "X"), ("Button", "Y")])
        let next = await core.call("do", ["actions": []])
        XCTAssertTrue(next.text.contains(" 1 Button \"X\""), next.text)
    }

    func testRepeatsScrollBarsAndHoldersAreLeftOut() async {
        let (core, wda, _) = makeCore()
        let long = String(repeating: "word ", count: 60)
        wda.tree([
            Node("TextView", "Hello world. Line two", [16, 100, 358, 80], [
                Node("StaticText", "Hello world.", [16, 100, 358, 40]),
                Node("StaticText", "Line two", [16, 140, 358, 40]),
            ]),
            Node("Other", "Vertical scroll bar, 3 pages", [384, 90, 3, 700]),
            Node("Other", "Post", [16, 200, 80, 44], [Node("Button", "Post", [16, 200, 80, 44])]),
            Node("StaticText", long, [16, 300, 358, 200]),
        ])
        let lean = await core.call("look", [:])
        XCTAssertTrue(lean.text.contains("1 TextView \"Hello world. Line two\""), lean.text)
        XCTAssertFalse(lean.text.contains("StaticText \"Hello world.\""), lean.text)
        XCTAssertFalse(lean.text.contains("scroll bar"), lean.text)
        XCTAssertTrue(lean.text.contains("Button \"Post\""), lean.text)
        XCTAssertFalse(lean.text.contains("Other \"Post\""), lean.text)
        XCTAssertTrue(lean.text.contains("… (+150 characters)"), lean.text)
        let full = await core.call("look", ["full": true])
        XCTAssertTrue(full.text.contains("StaticText \"Hello world.\""), full.text)
        XCTAssertTrue(full.text.contains("Vertical scroll bar"), full.text)
        XCTAssertTrue(full.text.contains(long), "full keeps whole labels")
    }

    func testFullLookKeepsSnapshotTextBeyond512Characters() async {
        let (core, wda, _) = makeCore()
        let value = (1...40).map { String(format: "L%03dabcdefghijklmnopqrstuvwxyz", $0) }.joined(separator: "\n")
        wda.tree([Node("TextView", value, [16, 100, 358, 400])])

        let lean = await core.call("look", [:])
        XCTAssertTrue(lean.text.contains("… (+1089 characters)"), lean.text)
        let full = await core.call("look", ["full": true])
        XCTAssertTrue(full.text.contains(value), full.text)
    }

    func testACollapsedCellGetsTheTextReadFromThePictureOnAFullRead() async {
        let (core, wda, host) = makeCore()
        wda.tree([Node("Cell", "Ada Lovelace @ada 2h This is the post's text, long enough to be a whole cell. 13 replies 7 likes", [0, 100, 390, 200])])
        // "13" at 200-230 x 260-280 points on a 390x844 screen.
        host.texts.value = [RecognizedText(text: "13", box: Rect(x: 200 / 390, y: 260 / 844, width: 30 / 390, height: 20 / 844)),
                            RecognizedText(text: "outside", box: Rect(x: 0.1, y: 0.9, width: 0.1, height: 0.02))]
        let lean = await core.call("look", [:])
        XCTAssertTrue(lean.text.contains("[collapsed]"), lean.text)
        XCTAssertFalse(lean.text.contains("Text \"13\""), lean.text)
        let full = await core.call("look", ["full": true])
        XCTAssertTrue(full.text.contains("2 Text \"13\" [200,260,30,20] (read from the picture)"), full.text)
        XCTAssertFalse(full.text.contains("outside"), full.text)
        _ = await core.call("do", ["actions": [["tap": 2]]])
        let tap = wda.bodies("POST /wda/tap").last
        XCTAssertEqual(tap?["x"]?.double ?? 0, 215, accuracy: 0.01)
        XCTAssertEqual(tap?["y"]?.double ?? 0, 270, accuracy: 0.01)
    }

    func testTheScreenshotIsOnePixelPerScreenPoint() async {
        let (core, _, host) = makeCore()
        let result = await core.call("look", [:])
        XCTAssertEqual(host.widths.value.first, 390)
        XCTAssertTrue(result.text.contains("screenshot: 390 px wide, 1 px = 1 screen point"), result.text)
    }

    func testSplitResizeUpdatesPictureAndDropsTheOldTargets() async {
        let (core, wda, host) = makeCore(FakeWDA(dynamicSize: true))
        _ = await core.call("look", [:])
        wda.set("GET /wda/screen") { _ in (200, ["value": ["screenSize": ["width": 290, "height": 720]]]) }
        wda.set("GET /source") { _ in (500, ["value": ["error": "unknown error", "message": "no accessibility tree"]]) }
        let pane = await core.call("look", [:])
        XCTAssertEqual(host.widths.value.filter { $0 >= 200 }, [390, 290])
        XCTAssertTrue(pane.text.contains("screenshot: 290 px wide, 1 px = 1 screen point"), pane.text)
        let tap = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(tap.isError, tap.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testWaitUntilReadsUntilTheTextAppears() async {
        let (core, wda, _) = makeCore()
        _ = await core.call("look", [:])
        Task { try? await Task.sleep(nanoseconds: 400_000_000); wda.source([("Button", "General"), ("StaticText", "Done")]) }
        let result = await core.call("do", ["actions": [["wait_until": "done"]]])
        XCTAssertTrue(result.text.contains("wait_until: \"done\" appeared after"), result.text)
        XCTAssertFalse(result.text.contains("paused"), "no pause after a wait: \(result.text)")
        let missing = await core.call("do", ["actions": [["wait_until": ["text": "Nope", "ms": 300]]]])
        XCTAssertTrue(missing.text.contains("wait_until: not seen within 300 ms that \"Nope\" appeared"), missing.text)
        XCTAssertFalse(missing.isError, "not seeing it is a fact for the model, not an error")
        let settled = await core.call("do", ["actions": [["wait_until": ["settled": true]]]])
        XCTAssertTrue(settled.text.contains("wait_until: the screen held still after"), settled.text)
    }

    func testAWaitSaysHowLongItWaitedOnce() async {
        let (core, _, _) = makeCore()
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["wait": 100]]])
        XCTAssertTrue(result.text.contains("did: wait 100 ms (sent"), result.text)
        XCTAssertFalse(result.text.contains("waited 0 ms"), result.text)
        XCTAssertFalse(result.text.contains("paused"), result.text)
    }

    func testScrollToBringsATargetOutFromUnderTheBar() async {
        let (core, wda, _) = makeCore()
        thread(wda, quotedY: 760)
        _ = await core.call("look", [:])
        wda.set("POST /wda/pressAndDragWithVelocity") { [wda] _ in
            wda.tree([
                Node("Table", nil, [0, 0, 390, 844], [Node("Cell", "Quoted post", [0, 300, 390, 120])]),
                Node("Other", nil, [0, 744, 390, 100], [Node("TextView", "Post your reply", [16, 760, 300, 40])]),
            ])
            return (200, ["value": .null])
        }
        let result = await core.call("do", ["actions": [["scroll_to": "Quoted"]]])
        XCTAssertTrue(result.text.contains("scroll_to \"Quoted\": 1 swipes, found at [0,300,390,120]"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/pressAndDragWithVelocity").first?["holdDuration"]?.double, 0.25, "a drag with a slow tail before the lift")
    }

    func testAControlInsideABarOrAnInputBarListedApartFromItIsHittable() async {
        let (core, wda, _) = makeCore()
        // WeChat-like: the Send button is listed before the input bar and the keyboard that enclose it.
        wda.tree([
            Node("Table", nil, [0, 0, 390, 690], [Node("Cell", "Hello", [0, 100, 390, 60])]),
            Node("Button", "Send", [320, 705, 60, 40]),
            Node("Other", nil, [0, 700, 390, 50], [Node("TextView", "message", [16, 705, 290, 40])]),
            Node("Keyboard", nil, [0, 750, 390, 94], [Node("Key", "a", [10, 760, 30, 40])]),
            Node("Button", "Return", [300, 790, 80, 44]),
        ])
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 2], ["tap": 5]]])
        XCTAssertFalse(result.isError, result.text)
        let taps = wda.bodies("POST /wda/tap")
        XCTAssertEqual(taps.first?["x"]?.double, 350)
        XCTAssertEqual(taps.first?["y"]?.double, 725)
        XCTAssertEqual(taps.last?["y"]?.double, 812)
    }

    func testTheActionsGetTheirFullTimeAfterTheOwnerApproves() async {
        let (core, wda, _) = makeCore { $0.approvalWait = 4; $0.toolDeadline = 3; $0.actionCap = 1.5; $0.readTimeout = 1 }
        wda.source([("Button", "Delete Photo")])
        _ = await core.call("look", [:])
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if let p = core.pendingApproval { core.resolveApproval(id: p.id, approved: true) }
        }
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
        XCTAssertTrue(result.text.contains("approval: approved on the phone after"), result.text)
        XCTAssertTrue(result.text.contains("app: Settings"), "the read after it still answers: \(result.text)")
    }

    func testRowsListedBesideTheListDoNotShrinkTheSwipe() async {
        let (core, wda, _) = makeCore()
        // Some apps list their rows after the table instead of inside it.
        wda.tree([Node("Table", nil, [0, 0, 390, 844])] + (0..<7).map { Node("Cell", "Row \($0)", [0, Double(100 + $0 * 100), 390, 100]) } + [Node("TabBar", nil, [0, 790, 390, 54], [Node("Button", "Chats", [20, 795, 80, 44])])])
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["swipe": "up"]]])
        let body = wda.bodies("POST /wda/pressAndDragWithVelocity").first
        let fromY = body?["fromY"]?.double ?? 0, toY = body?["toY"]?.double ?? 0
        XCTAssertLessThan(fromY, 790, "not on the tab bar")
        XCTAssertGreaterThan(fromY - toY, 400, "a long swipe, from \(fromY) to \(toY)")
    }

    func testTheToolDescriptionsPointToScrollTo() {
        let text = PokiCore.tools.map { $0.serialized() }.joined() + PokiCore.instructions
        XCTAssertTrue(PokiCore.instructions.contains("scroll_to"))
        XCTAssertTrue(text.contains("wait_until"))
        XCTAssertTrue(text.contains("not_hittable"))
        XCTAssertTrue(text.contains("screen_changed"))
    }
}

#if canImport(Vision) && canImport(ImageIO) && canImport(CoreText) && os(macOS)
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

final class PictureSketchTests: XCTestCase {
    static func png(_ draw: (CGContext) -> Void) -> Data {
        let width = 402, height = 874
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        draw(context)
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Seen on the simulator: a scroll indicator fading out after a drag made a no-op wait answer
    /// screen_changed: true. A picture change is what a person would see.
    func testAFadingScrollIndicatorIsNotAChangeButASheetIs() throws {
        let plain = PictureSketch(png: Self.png { _ in })
        let indicator = PictureSketch(png: Self.png { $0.fill(CGRect(x: 396, y: 300, width: 3, height: 120)) })
        let cursor = PictureSketch(png: Self.png { $0.fill(CGRect(x: 40, y: 700, width: 2, height: 22)) })
        let sheet = PictureSketch(png: Self.png { $0.fill(CGRect(x: 0, y: 0, width: 402, height: 300)) })
        let photo = PictureSketch(png: Self.png { $0.fill(CGRect(x: 100, y: 400, width: 120, height: 120)) })
        XCTAssertNil(plain.hash, "decoded, not hashed")
        XCTAssertFalse(indicator.differs(from: plain))
        XCTAssertFalse(cursor.differs(from: plain))
        XCTAssertTrue(sheet.differs(from: plain))
        XCTAssertTrue(photo.differs(from: plain))
        XCTAssertFalse(plain.differs(from: PictureSketch(png: Self.png { _ in })))
        // A long indicator, as iOS draws it beside a two-page list, is a change (it moves a column of
        // cells), and the change is told by its share and box, so the reader knows it is a strip.
        let longIndicator = PictureSketch(png: Self.png { $0.fill(CGRect(x: 396, y: 110, width: 3, height: 700)) })
        let change = try XCTUnwrap(longIndicator.change(from: plain))
        XCTAssertTrue(longIndicator.differs(from: plain))
        XCTAssertTrue(change.share > 0.01 && change.share < 0.05, "\(change)")
        XCTAssertTrue(change.x > 0.9 && change.width <= 2.0 / 32 && change.height > 0.7, "\(change)")
        let page = try XCTUnwrap(sheet.change(from: plain))
        // CoreGraphics draws from the bottom, so the sheet is the lower third of the picture.
        XCTAssertTrue(page.share > 0.3 && page.width == 1 && page.height < 0.4 && page.y + page.height == 1, "\(page)")
    }
}

final class TextRecognitionTests: XCTestCase {
    /// Vision reads a rendered word back, with its box in parts of the picture from the top left.
    func testVisionReadsTextWithTopLeftBoxes() throws {
        let width = 600, height = 300
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let text = NSAttributedString(string: "Poki 13", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)])
        context.textPosition = CGPoint(x: 40, y: 200) // near the top: CoreGraphics counts from the bottom
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        // On a thread of its own with a limit, so a Vision that never answers fails the test instead of the run.
        let png = data as Data
        let box = LockedBox<[RecognizedText]??>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread { box.value = .some(TextRecognizer.recognize(png: png)); done.signal() }.start()
        XCTAssertEqual(done.wait(timeout: .now() + 60), .success, "Vision did not answer within 60 s")
        let found = try XCTUnwrap(box.value ?? nil)
        let line = try XCTUnwrap(found.first { $0.text.contains("13") }, "\(found)")
        XCTAssertLessThan(line.box.y, 0.5, "the box is measured from the top: \(line.box)")
    }
}
#endif
