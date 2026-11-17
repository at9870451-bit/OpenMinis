import Foundation

/// When Poki's built-in local connection (the packet tunnel) is dialled again after it failed or
/// dropped. It holds the policy and no timers: the app asks `lost()` for the wait before the next try.
/// The waits are 1, 2, 4, 8, 16 s, then 30 s, eight tries in all (about two minutes); then the owner
/// decides, from Poki's Setup. Opening Poki alone never dials, which avoids displacing a VPN they just turned on.
public struct ReconnectPlan: Sendable {
    public static let waits: [Double] = [1, 2, 4, 8, 16, 30, 30, 30]
    /// A connection that stayed up this long makes its loss a new story: the count starts over. A
    /// tunnel that comes up and drops again at once keeps counting, so it cannot be dialled forever.
    public static let stableAfter: Double = 30

    private var failures = 0
    private var upSince: Date?

    public init() {}

    /// True after the owner ended the connection on purpose (Disconnect, Turn off) until they start it again.
    public private(set) var stoppedByOwner = false

    /// The tunnel is up.
    public mutating func connected(at date: Date = Date()) { upSince = date }

    /// The tunnel failed or dropped. The seconds to wait before the next try, or nil for no more tries.
    public mutating func lost(at date: Date = Date()) -> Double? {
        if let up = upSince, date.timeIntervalSince(up) >= Self.stableAfter { failures = 0 }
        upSince = nil
        guard !stoppedByOwner, failures < Self.waits.count else { return nil }
        defer { failures += 1 }
        return Self.waits[failures]
    }

    public mutating func ownerStopped() { stoppedByOwner = true }

    public mutating func ownerStarted() {
        stoppedByOwner = false
        failures = 0
        upSince = nil
    }
}

/// Whether the owner appears to have a VPN of their own on. Best effort: a VPN that sets no proxy
/// (Tailscale, for example) may not be detected. The built-in connection is dialled again only when
/// none is detected, because a second packet tunnel could displace theirs.
public enum OtherVPN {
    /// `names` are the network interfaces iOS has scoped settings for (the keys of `__SCOPED__` in
    /// `CFNetworkCopySystemProxySettings`). Called while Poki's own tunnel is down, so a tunnel
    /// interface among them is somebody else's.
    public static func isOn(interfaces names: [String]) -> Bool {
        names.contains { name in ["utun", "ipsec", "ppp", "tun", "tap"].contains { name.hasPrefix($0) } }
    }
}
