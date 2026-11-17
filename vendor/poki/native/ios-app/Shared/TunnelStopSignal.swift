import Foundation

/// The Darwin notification the packet tunnel posts, with no payload, just before it stops for a
/// reason that is not a failure (the owner turned it off in Settings, another VPN took the single
/// packet tunnel). It is named after the tunnel's bundle id plus this suffix, so a signing tool that
/// rewrites the id rewrites both sides. Compiled into the app and into the tunnel.
enum TunnelStopSignal {
    static let suffix = ".stopped-on-purpose"
}
