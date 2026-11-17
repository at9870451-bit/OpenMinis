import Foundation
import NetworkExtension
import XCTest
@testable import PokiLoopback

final class LoopbackTests: XCTestCase {
    func testTCPConversationIsReflectedWithoutChangingPortsPayloadOrChecksums() {
        // IPv4/TCP fixtures: SYN to RemotePairing, SYN-ACK back, and data to a dynamic port.
        let packets = [
            ("4500002800014000400626bf0a0700020a070001c350c00000000001000000005002ffff18800000",
             "4500002800014000400626bf0a0700010a070002c350c00000000001000000005002ffff18800000"),
            ("4500002800024000400626be0a0700020a070001c000c35000000002000000025012ffff186d0000",
             "4500002800024000400626be0a0700010a070002c000c35000000002000000025012ffff186d0000"),
            ("4500002c00034000400626b90a0700020a070001c350d6d800000003000000035018ffff25b00000706f6b69",
             "4500002c00034000400626b90a0700010a070002c350d6d800000003000000035018ffff25b00000706f6b69"),
        ]
        for (sent, received) in packets {
            XCTAssertEqual(LoopbackPacket.reflect(bytes(sent)), bytes(received))
        }
    }

    func testPacketsOutsideTheLocalTCPRouteAndMalformedPacketsAreDropped() {
        let tcp = bytes("4500002800014000400626bf0a0700020a070001c350c00000000001000000005002ffff18800000")
        var invalid: [Data] = [Data(), tcp.prefix(19), tcp.prefix(39)]
        for (offset, value) in [(0, 0x65), (0, 0x44), (2, 1), (3, 20), (6, 0x20), (7, 1), (9, 17), (15, 3), (19, 8), (32, 0x40), (32, 0xf0)] {
            var packet = tcp
            packet[offset] = UInt8(value)
            invalid.append(packet)
        }
        for packet in invalid { XCTAssertNil(LoopbackPacket.reflect(packet)) }
    }

    private func bytes(_ hex: String) -> Data {
        var result = Data()
        var start = hex.startIndex
        while start < hex.endIndex {
            let end = hex.index(start, offsetBy: 2)
            result.append(UInt8(hex[start..<end], radix: 16)!)
            start = end
        }
        return result
    }
}

#if canImport(NetworkExtension)
import NetworkExtension

extension LoopbackTests {
    func testTunnelRoutesOnlyTheDeveloperAddressWithoutDNSOrIPv6() throws {
        let settings = LoopbackNetworkSettings.make()
        let ipv4 = try XCTUnwrap(settings.ipv4Settings)
        XCTAssertEqual(ipv4.addresses, ["10.7.0.2"])
        XCTAssertEqual(ipv4.subnetMasks, ["255.255.255.255"])
        XCTAssertEqual(ipv4.includedRoutes?.count, 1)
        XCTAssertEqual(ipv4.includedRoutes?.first?.destinationAddress, "10.7.0.1")
        XCTAssertEqual(ipv4.includedRoutes?.first?.destinationSubnetMask, "255.255.255.255")
        XCTAssertEqual(ipv4.excludedRoutes?.first?.destinationAddress, "0.0.0.0")
        XCTAssertNil(settings.dnsSettings)
        XCTAssertNil(settings.ipv6Settings)
        XCTAssertNil(settings.proxySettings)
        XCTAssertEqual(settings.mtu, 1500)
    }
}
#endif

/// GitHub issue 44: the app dials the tunnel again after it drops, but not after the owner turned it off
/// in Settings, or after another VPN took the single packet tunnel.
final class TunnelStopTests: XCTestCase {
    func testOnlyAnEndByTheOwnerOrAnotherVPNLeavesTheTunnelDown() {
        for reason in [NEProviderStopReason.userInitiated, .superceded] { XCTAssertTrue(TunnelStop.isOnPurpose(reason), "\(reason.rawValue)") }
        let failures: [NEProviderStopReason] = [.none, .providerFailed, .noNetworkAvailable, .unrecoverableNetworkChange, .connectionFailed, .idleTimeout, .sleep, .configurationFailed, .appUpdate]
        for reason in failures { XCTAssertFalse(TunnelStop.isOnPurpose(reason), "\(reason.rawValue)") }
    }
}
