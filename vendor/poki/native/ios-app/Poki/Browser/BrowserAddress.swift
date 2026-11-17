import Foundation

/// Which addresses Poki's browser may load. The browser is for public websites. This iPhone itself and
/// the network it is on (a router's page, a printer, a computer's local server) are not websites the
/// agent has any business reading or tapping, and a page must not be able to send the browser there.
enum BrowserAddress {
    enum Refusal: Equatable { case notWeb, local }

    #if DEBUG
    /// Tests serve their pages from 127.0.0.1. Never true in a release build.
    nonisolated(unsafe) static var allowsLocal = NSClassFromString("XCTestCase") != nil
    #else
    static let allowsLocal = false
    #endif

    /// Why this address is not loaded, or nil. Only http and https are judged: `about:blank`, `blob:`
    /// and `data:` are a page's own content.
    static func refusal(_ url: URL) -> Refusal? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return .notWeb }
        return isLocal(host) && !allowsLocal ? .local : nil
    }

    /// This device, a private or link-local network, or a name only a local network answers.
    static func isLocal(_ raw: String) -> Bool {
        var host = raw.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        guard !host.isEmpty else { return true }

        // IPv6, written out.
        var six = in6_addr()
        if host.contains(":") {
            guard inet_pton(AF_INET6, host, &six) == 1 else { return true }
            let b = withUnsafeBytes(of: six) { Array($0) }
            if b.allSatisfy({ $0 == 0 }) { return true }                              // ::
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }         // ::1
            if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true }                     // fe80::/10
            if b[0] & 0xfe == 0xfc { return true }                                     // fc00::/7
            if b[0] == 0xff { return true }                                            // multicast
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {   // ::ffff:a.b.c.d
                return isLocal(v4: (b[12], b[13], b[14], b[15]))
            }
            return false
        }

        // IPv4 in any form a browser takes: 127.0.0.1, 2130706433, 0x7f.1, 0177.0.0.1.
        var four = in_addr()
        if inet_aton(host, &four) == 1 {
            let b = withUnsafeBytes(of: four.s_addr) { Array($0) }
            return isLocal(v4: (b[0], b[1], b[2], b[3]))
        }

        if !host.contains(".") { return true }                                        // "router", "localhost"
        return [".localhost", ".local", ".lan", ".internal", ".home.arpa"].contains { host.hasSuffix($0) }
    }

    private static func isLocal(v4 b: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        switch b.0 {
        case 0, 10, 127: return true
        case 100: return b.1 & 0xc0 == 64          // 100.64.0.0/10, carrier and VPN ranges
        case 169: return b.1 == 254
        case 172: return b.1 & 0xf0 == 16
        case 192: return b.1 == 168
        default: return b.0 >= 224                  // multicast, reserved, broadcast
        }
    }
}
