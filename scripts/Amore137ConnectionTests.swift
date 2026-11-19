import Foundation
import Darwin
import XCTest
@testable import AmoreDeviceKit

@MainActor
final class Amore137ConnectionTests: XCTestCase {
    override func setUp() async throws { RemotePairingPort.use(49152); RemotePairingPort.setSearching(false) }
    override func tearDown() async throws { RemotePairingPort.use(49152); RemotePairingPort.setSearching(false) }
    private func answer(_ port: UInt16, tcp: Bool = true, ok: Bool = false) -> RemotePairingProbeResult {
        RemotePairingProbeResult(host: "10.7.0.1", port: port, tcpConnected: tcp, handshakeOK: ok,
            stage: ok ? "ready" : tcp ? "handshake" : "connect", detail: ok ? "response" : "early eof", elapsedMS: 5)
    }
    private func awaitCheck(_ monitor: LoopbackMonitor, after: Date? = nil) async throws {
        for _ in 0..<100 {
            if let at = monitor.checkedAt, after == nil || at > after! { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The bounded injected monitor did not finish")
    }
    func testLocalDevVPNInterfaceDoesNotChangeDeviceTarget() {
        let addresses = [LocalAddress(interface: "utun4", address: "10.7.1.1", family: AF_INET),
                         LocalAddress(interface: "utun4", address: "fe80::1", family: AF_INET6)]
        XCTAssertEqual(loopbackInterface(addresses)?.address, "10.7.1.1")
        XCTAssertEqual(loopbackInterface(addresses)?.ipv6, ["fe80::1"])
        XCTAssertNil(loopbackInterface([LocalAddress(interface: "en0", address: "10.7.1.1", family: AF_INET)]))
        XCTAssertNil(loopbackInterface([LocalAddress(interface: "utun1", address: "10.7.10.1", family: AF_INET)]))
        XCTAssertNotNil(loopbackInterface([LocalAddress(interface: "utun0", address: "10.7.0.2", family: AF_INET)]))
    }
    func testTCPAcceptedButEOFIsNeverWorking() async throws {
        var tcpProbes = 0
        let monitor = LoopbackMonitor(probe: { host, port, _ in
            tcpProbes += 1; return ProbeResult(label: "TCP only", target: host, outcome: "connected")
        }, handshakeProbe: { port, _ in self.answer(port) }, monitorNetwork: false,
           browsePorts: { ([], nil) }, interface: { LoopbackInterface(interface: "utun0", address: "10.7.1.1", ipv6: []) })
        monitor.remotePairingRequired = { true }
        monitor.check(); try await awaitCheck(monitor)
        XCTAssertFalse(monitor.isWorking)
        XCTAssertEqual(monitor.state, .noAnswer)
        XCTAssertEqual(monitor.lastHandshake?.stage, "handshake")
        XCTAssertEqual(tcpProbes, 0, "A raw TCP accept must not substitute for the required protocol handshake")
    }
    func testProtocolResponseFindsMovedPortAfterEOF() async throws {
        var called: [UInt16] = []; var reported: UInt16?
        let monitor = LoopbackMonitor(handshakeProbe: { port, _ in
            called.append(port); return self.answer(port, ok: port == 49158)
        }, monitorNetwork: false, browsePorts: { ([49152,49155,49158], nil) }, interface: { nil })
        monitor.remotePairingRequired = { true }
        monitor.onPairingPort = { reported = $0 }
        monitor.check(); try await awaitCheck(monitor)
        XCTAssertTrue(monitor.isWorking)
        XCTAssertEqual(RemotePairingPort.current, 49158)
        XCTAssertEqual(reported, 49158)
        XCTAssertEqual(called, [49152,49155,49158])
        XCTAssertEqual(monitor.lastHandshake?.host, "10.7.0.1", "10.7.1.1 is not the phone service address")
    }
    func testAllCandidatesEOFDoesNotSelectAny() async throws {
        let monitor = LoopbackMonitor(handshakeProbe: { port, _ in self.answer(port) }, monitorNetwork: false,
            browsePorts: { ([49153,49154], nil) }, interface: { nil })
        monitor.remotePairingRequired = { true }
        monitor.check(); try await awaitCheck(monitor)
        XCTAssertFalse(monitor.isWorking)
        XCTAssertEqual(RemotePairingPort.current, 49152)
        XCTAssertTrue(monitor.lastPortSearch.contains("no port"))
    }
    func testLockdownRecordKeeps62078Compatibility() async throws {
        let monitor = LoopbackMonitor(probe: { host, port, _ in
            ProbeResult(label: "lockdown compatibility", target: host, outcome: port == 62078 ? "connected" : "timeout")
        }, handshakeProbe: { _, _ in XCTFail("RemotePairing should not be required for lockdown record");return self.answer(49152) },
          monitorNetwork: false, browsePorts: { ([], nil) }, interface: { nil })
        monitor.check(); try await awaitCheck(monitor)
        XCTAssertTrue(monitor.isWorking)
    }
    func testLauncherEOFFlushesCachedProtocolSuccess() async throws {
        var succeeds = true; var probes = 0
        let monitor = LoopbackMonitor(handshakeProbe: { port, _ in
            probes += 1;return self.answer(port, ok: succeeds)
        }, monitorNetwork: false, browsePorts: { ([], nil) }, interface: { nil })
        monitor.remotePairingRequired = { true }
        monitor.check(); try await awaitCheck(monitor)
        XCTAssertTrue(monitor.isWorking)
        _ = try XCTUnwrap(monitor.checkedAt)
        succeeds = false; let failureAt = Date(); monitor.pairingHandshakeFailed()
        try await awaitCheck(monitor, after: failureAt)
        XCTAssertFalse(monitor.isWorking)
        XCTAssertEqual(probes, 2, "EOF must not reuse the recent successful response")
    }
    func testLatestTimestampUpdatesWhenSameStateRepeats() async throws {
        let monitor = LoopbackMonitor(handshakeProbe: { port, _ in self.answer(port) }, monitorNetwork: false,
            browsePorts: { ([], nil) }, interface: { nil })
        monitor.remotePairingRequired = { true }
        monitor.check(); try await awaitCheck(monitor)
        let first = try XCTUnwrap(monitor.checkedAt)
        monitor.retryProtocolCheck(); try await awaitCheck(monitor, after: first)
        XCTAssertGreaterThan(try XCTUnwrap(monitor.checkedAt), first)
    }
    func testSearchIsDeduplicatedAndBounded() async {
        var tested: [UInt16] = []
        let result = await RemotePairingPort.search(besides: 49152, browse: {
            ([0,49152,49153,49153] + Array(49154...49200),nil)
        }, answers: { port in tested.append(port);return false })
        XCTAssertLessThanOrEqual(result.listed.count, 8)
        XCTAssertEqual(tested.count, 7)
        XCTAssertFalse(tested.contains(0));XCTAssertFalse(tested.contains(49152))
        XCTAssertEqual(Set(tested).count,tested.count)
    }
}
