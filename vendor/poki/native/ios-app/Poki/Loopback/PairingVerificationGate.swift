import Foundation

/// A successful untrusted service hello must not cause an endless sequence of
/// full pairing/tunnel checks when that later connection keeps failing.
struct PairingVerificationGate {
    private(set) var failures = 0
    private(set) var nextAttempt = Date.distantPast
    func permits(at now: Date) -> Bool { now >= nextAttempt }
    mutating func failed(at now: Date) {
        failures = min(failures + 1, 4)
        let delays: [TimeInterval] = [10, 30, 60, 120]
        nextAttempt = now.addingTimeInterval(delays[failures - 1])
    }
    mutating func reset() { failures = 0; nextAttempt = .distantPast }
}

/// Only accept a full check for the network/port/record it started against.
/// Contains record location/revision, never its contents or keys.
struct PairingVerificationContext: Equatable {
    let networkRevision: Int
    let port: UInt16
    let transport: String
    let pairingPath: String?
    let recordRevision: UInt64
}
