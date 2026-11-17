import Foundation

/// The port of this iPhone's remote pairing service. iOS does not keep it at 49152: it gives the
/// service the next free port whenever it starts it, and names that port only in the service's
/// Bonjour record (`_remotepairing._tcp`). After a restart of the phone it is 49152 as a rule; once
/// iOS has started the service again it is another one, and 49152 refuses although the loopback
/// works. Poki starts at 49152 and looks the port up when it does not answer.
enum RemotePairingPort {
    static let standard: UInt16 = 49152
    /// The port in use, for the probes here. The launcher keeps its own copy (`use` sets both).
    @MainActor private(set) static var current: UInt16 = standard

    /// Every later connection of the launcher, the pairing check and the signer goes to `port`.
    @MainActor static func use(_ port: UInt16) {
        current = port
        poki_set_remote_pairing_port(port)
    }

    /// Whether Poki looks for a moved port now. Only then does the launcher read a refused connection
    /// as a moved port (`pairing_port`); otherwise a refusal keeps its earlier meaning, and on a
    /// mounted disk image it goes to Poki's own session.
    @MainActor private(set) static var searching = false

    @MainActor static func setSearching(_ on: Bool) {
        guard on != searching else { return }
        searching = on
        poki_set_pairing_port_search(on)
    }

    /// When a look may start after the port stopped answering: at once, then 10 s and 30 s after the
    /// look before. Three looks, then none until the network changes or the port answers again.
    static let lookDelays: [TimeInterval] = [0, 10, 30]

    /// Whether a look in Bonjour is due. Never on cellular alone: there iOS refuses the developer
    /// services' loopback itself (GitHub issue 35), and a mounted disk image goes to Poki's own
    /// session at once instead of waiting for a port.
    static func lookDue(cellularOnly: Bool, looks: Int, lastAt: Date, now: Date) -> Bool {
        guard !cellularOnly, looks < lookDelays.count else { return false }
        return now.timeIntervalSince(lastAt) >= lookDelays[looks]
    }

    /// What one look in Bonjour gave.
    struct Search: Equatable {
        /// The port that answered at 10.7.0.1, when one did.
        var found: UInt16?
        /// The ports Bonjour listed (this iPhone's, and those of other iPhones on the network).
        var listed: [UInt16] = []
        var problem: String?

        /// One line for the log.
        func said(besides current: UInt16) -> String {
            if let found { return "the remote pairing service answers on port \(found) (Bonjour lists \(listed.map(String.init).joined(separator: ", ")))" }
            if let problem { return "port \(current) does not answer, and Bonjour could not be searched (\(problem))" }
            if listed.isEmpty { return "port \(current) does not answer, and Bonjour lists no remote pairing service (is Wi-Fi on, and Local Network allowed for Poki?)" }
            return "port \(current) does not answer, and no port Bonjour lists (\(listed.map(String.init).joined(separator: ", "))) answers at 10.7.0.1"
        }
    }

    /// Looks the port up: the ports Bonjour lists, each tried at 10.7.0.1, which is always this
    /// iPhone. Another iPhone's port answers here only if this one listens on it too, and then the
    /// pairing check that follows tells. `current` is not tried again: it was just refused.
    @MainActor static func search(besides current: UInt16,
                       browse: () async -> (ports: [UInt16], problem: String?),
                       answers: (UInt16) async -> Bool) async -> Search {
        let (ports, problem) = await browse()
        var search = Search(found: nil, listed: ports, problem: problem)
        for port in ports where port != current {
            if await answers(port) { search.found = port; break }
        }
        return search
    }
}

/// One Bonjour search for `_remotepairing._tcp` and the port of every service it finds. Used on the
/// main thread only; the browser and its services call back on the main run loop.
final class RemotePairingBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var resolved = Set<ObjectIdentifier>()
    private var ports: [UInt16] = []
    private var problem: String?
    private var done: (([UInt16], String?) -> Void)?

    /// The ports of the remote pairing services on this network, within `timeout` seconds (sooner
    /// when every service found has given its port).
    @MainActor static func ports(timeout: TimeInterval = 3) async -> (ports: [UInt16], problem: String?) {
        let search = RemotePairingBrowser()
        return await withCheckedContinuation { continuation in
            // On the main queue whatever thread this closure runs on: the browser needs its run loop.
            DispatchQueue.main.async {
                search.start(timeout: timeout) { ports, problem in continuation.resume(returning: (ports, problem)) }
            }
        }
    }

    private func start(timeout: TimeInterval, done: @escaping ([UInt16], String?) -> Void) {
        self.done = done
        browser.delegate = self
        browser.schedule(in: .main, forMode: .common)
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
        // The closure keeps this object until the search ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { self.finish() }
    }

    private func finish() {
        guard let done else { return }
        self.done = nil
        browser.stop()
        services.forEach { $0.stop() }
        services = []
        done(ports, problem)
    }

    /// Every service found has answered: a moment for one more to turn up, then done.
    private func finishWhenAllResolved() {
        guard !services.isEmpty, resolved.count == services.count else { return }
        let count = services.count
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if self.services.count == count { self.finish() }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 2.5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        problem = "Bonjour error \(errorDict[NetService.errorCode]?.intValue ?? 0)"
        finish()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if let port = UInt16(exactly: sender.port), port != 0, !ports.contains(port) { ports.append(port) }
        resolved.insert(ObjectIdentifier(sender))
        finishWhenAllResolved()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolved.insert(ObjectIdentifier(sender))
        finishWhenAllResolved()
    }
}
