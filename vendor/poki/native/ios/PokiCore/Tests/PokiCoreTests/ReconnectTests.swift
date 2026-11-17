import XCTest
@testable import PokiCore

/// GitHub issue 44: the built-in local VPN failed twice in an hour and stayed down for 101 s and 134 s,
/// until someone opened Poki. These are the rules for dialling it again by itself.
final class ReconnectTests: XCTestCase {
    func testTriesBackOffAndStopAtTheCap() {
        var plan = ReconnectPlan()
        let waits = (0..<10).map { _ in plan.lost() }
        XCTAssertEqual(waits, [1, 2, 4, 8, 16, 30, 30, 30, nil, nil])
    }

    func testNothingIsTriedAfterTheOwnerEndedItUntilTheyStartItAgain() {
        var plan = ReconnectPlan()
        XCTAssertEqual(plan.lost(), 1)
        plan.ownerStopped()
        XCTAssertNil(plan.lost())
        XCTAssertTrue(plan.stoppedByOwner)
        plan.ownerStarted()
        XCTAssertFalse(plan.stoppedByOwner)
        XCTAssertEqual(plan.lost(), 1, "the count starts over with the owner's own start")
    }

    func testAConnectionThatHeldStartsTheCountOverButOneThatDroppedAtOnceDoesNot() {
        var plan = ReconnectPlan()
        let up = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(plan.lost(at: up), 1)
        XCTAssertEqual(plan.lost(at: up), 2)
        plan.connected(at: up)
        XCTAssertEqual(plan.lost(at: up.addingTimeInterval(5)), 4, "up for 5 s: a flapping tunnel keeps counting")
        plan.connected(at: up.addingTimeInterval(10))
        XCTAssertEqual(plan.lost(at: up.addingTimeInterval(10 + 60)), 1, "up for a minute: a new loss is a new story")
    }

    func testATunnelInterfaceMeansAnotherVPNIsOn() {
        XCTAssertTrue(OtherVPN.isOn(interfaces: ["en0", "utun4"]), "a packet tunnel (WireGuard, LocalDevVPN, Karing, most others)")
        XCTAssertTrue(OtherVPN.isOn(interfaces: ["ipsec0"]), "IKEv2 and IPsec")
        XCTAssertTrue(OtherVPN.isOn(interfaces: ["ppp0"]), "L2TP and PPTP")
        XCTAssertFalse(OtherVPN.isOn(interfaces: ["en0", "pdp_ip0", "awdl0", "llw0"]), "Wi-Fi, cellular and the links between Apple devices are not VPNs")
        XCTAssertFalse(OtherVPN.isOn(interfaces: []))
    }
}
