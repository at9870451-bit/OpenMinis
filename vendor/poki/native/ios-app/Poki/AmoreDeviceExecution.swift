import Foundation

/// A nil host conversation is still a real task. Optional equality alone loses
/// its first begin (nil == nil), so keep occupancy separately from its owner.
struct AmoreDeviceTaskLease: Equatable {
    private(set) var occupied = false
    private(set) var owner: String?
    enum Claim: Equatable { case began, continued, busy }
    mutating func claim(_ session: String?) -> Claim {
        if occupied { return owner == session ? .continued : .busy }
        occupied = true
        owner = session
        return .began
    }
    mutating func release(_ session: String?) -> Bool {
        guard occupied, owner == session else { return false }
        reset()
        return true
    }
    mutating func reset() { occupied = false; owner = nil }
}

/// Foreground callbacks can arrive between tools, before Core's toolStarted
/// event, or while preparation is waiting for the OS. None ends that work.
enum AmoreDeviceExecutionPolicy {
    static func mayCloseForForeground(taskActive: Bool, callsInFlight: Int, preparingByOwner: Bool) -> Bool {
        !taskActive && callsInFlight == 0 && !preparingByOwner
    }
}

/// Shared diagnostics include operational errors, never record contents or
/// credential-shaped material, even if a lower layer accidentally echoes it.
enum AmoreDeviceDiagnostic {
    static func safe(_ text: String) -> String {
        var value = text
        let patterns = [
            "(?is)-----BEGIN[^\\r\\n]*PRIVATE KEY-----.*?-----END[^\\r\\n]*PRIVATE KEY-----",
            "(?i)Bearer\\s+[A-Za-z0-9._~+/=-]+",
            "(?i)(?:sk-[A-Za-z0-9_-]{8,}|[A-Fa-f0-9]{48,}|[A-Za-z0-9+/]{64,}={0,2})",
            "(?i)[^\\s<>\\\"]*\\.mobiledevicepairing",
            "(?im)(?:api[_ -]?key|private[_ -]?key|secret|token|password|pairing_file|hostid|systembuid|hostcertificate|devicecertificate|rootcertificate)\\s*[\\\"']?\\s*[:=]\\s*[^\\r\\n]+"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[redacted]")
            }
        }
        return String(value.prefix(6000))
    }
}
