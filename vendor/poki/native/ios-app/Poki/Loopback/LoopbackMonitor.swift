import Foundation
import Network
import Observation

/// Live loopback status: every few seconds while Poki is in front (and on demand), a TCP connect to
/// developer services at 10.7.0.1, which only answer when Poki or an external VPN reflects
/// 10.7.0.1 back to this phone. Network type is context, not proof of service availability.
@MainActor
@Observable
final class LoopbackMonitor {
    enum State: Equatable {
        case checking
        case working(ms: Int)
        /// A tunnel gave the phone a 10.7.0.x address, but nothing answered through it.
        case noAnswer
        case off
        var isWorking: Bool { if case .working = self { true } else { false } }
    }
    private(set) var state = State.checking
    private(set) var onWiFi = false
    /// The physical interface monitors report cellular without a usable Wi-Fi path.
    private(set) var cellularOnly = false
    /// The interfaces the system path lists, for Diagnostics: a proxy app's tunnel can change what the path reports.
    private(set) var pathSummary = ""
    private(set) var checkedAt: Date?
    /// When the loopback last stopped answering after it had worked; nil while it works.
    private(set) var droppedAt: Date?
    /// Called on every change of state, with the old and the new one.
    var onChange: ((State, State) -> Void)?
    private var timer: Timer?
    private let path = NWPathMonitor()
    private let wifiPath = NWPathMonitor(requiredInterfaceType: .wifi)
    private let cellularPath = NWPathMonitor(requiredInterfaceType: .cellular)
    private(set) var wifiUp = false
    private(set) var cellularUp = false
    private var running = false
    private var checkQueued = false
    private var probeEpoch = 0
    private(set) var networkRevision = 0
    private(set) var completedChecks = 0
    typealias Probe = (_ host: String, _ port: UInt16, _ timeout: TimeInterval) async -> ProbeResult
    private let connect: Probe
    typealias HandshakeProbe = (_ port: UInt16, _ timeout: TimeInterval) async -> RemotePairingProbeResult
    private let handshake: HandshakeProbe
    var remotePairingRequired: () -> Bool = { false }
    var onExplicitProtocolRetry: (() -> Void)?
    private var recoveringHandshake = false
    private var cachedHandshakes: [UInt16: (Date, RemotePairingProbeResult)] = [:]
    private(set) var lastPortSearch = "尚未发现端口"
    typealias Browse = () async -> (ports: [UInt16], problem: String?)
    private let browse: Browse
    private let tunnelInterface: () -> LoopbackInterface?

    /// Explicit user refresh may restart discovery, but never pairs or mounts DDI.
    func retryProtocolCheck() {
        onExplicitProtocolRetry?()
        probeEpoch &+= 1
        cachedHandshakes.removeAll()
        resetPortSearch()
        check()
    }
    private(set) var lastHandshake: RemotePairingProbeResult?
    private(set) var lastHandshakeAt: Date?

    /// A real launcher handshake failure invalidates TCP-only readiness. No
    /// trust record is deleted; subsequent Bonjour candidates need a handshake.
    func pairingHandshakeFailed() {
        // Every failure invalidates pending probes as well as cached success.
        recoveringHandshake = true
        probeEpoch &+= 1
        cachedHandshakes.removeAll()
        publish(.noAnswer, log: true)
        check()
    }

    /// A completed pair-verify/tunnel, not merely an interface or TCP socket.
    func pairingVerified() { recoveringHandshake = false }

    private func serviceProbe(port: UInt16, requireHandshake: Bool, epoch: Int) async -> ProbeResult {
        guard requireHandshake else { return await connect("10.7.0.1", port, 1.5) }
        let answer: RemotePairingProbeResult
        if let (at, cached) = cachedHandshakes[port],
           Date().timeIntervalSince(at) < (cached.handshakeOK ? 10 : 3) {
            answer = cached
        } else {
            answer = await handshake(port, 3)
            if epoch == probeEpoch { cachedHandshakes[port] = (Date(), answer) }
        }
        if epoch == probeEpoch { lastHandshake = answer; lastHandshakeAt = Date() }
        return ProbeResult(label: "Remote Pairing handshake", target: "10.7.0.1:\(port)",
            outcome: answer.handshakeOK ? "connected" : answer.tcpConnected ? "handshake_failed" : "failed",
            detail: answer.detail, milliseconds: answer.elapsedMS)
    }

    init(probe: @escaping Probe = { host, port, timeout in await AmoreDeviceKit.probe(label: "loopback", host: host, port: port, timeout: timeout) },
         handshakeProbe: @escaping HandshakeProbe = { port, timeout in await RemotePairingProbeResult.check(port: port, timeout: timeout) },
         monitorNetwork: Bool = true,
         browsePorts: @escaping Browse = { await RemotePairingBrowser.ports() },
         interface: @escaping () -> LoopbackInterface? = { loopbackInterface() }) {
        connect = probe; handshake = handshakeProbe; browse = browsePorts; tunnelInterface = interface
        guard monitorNetwork else { return }
        // The default path's interface types change while a proxy app's tunnel is up, so "only
        // cellular" is read from two monitors that each watch one physical interface type.
        path.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            let summary = "\(path.status): " + path.availableInterfaces.map { "\($0.name) (\($0.type))" }.joined(separator: ", ")
            Task { @MainActor in
                guard let self else { return }
                let pathChanged = !self.pathSummary.isEmpty && self.pathSummary != summary
                self.pathSummary = summary
                let wifiChanged = self.onWiFi != wifi
                self.onWiFi = wifi
                if wifiChanged || pathChanged { self.networkChanged(physical: wifiChanged) }
            }
        }
        wifiPath.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.interfaceChanged { $0.wifiUp = up } }
        }
        cellularPath.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.interfaceChanged { $0.cellularUp = up } }
        }
        let queue = DispatchQueue(label: "poki.path")
        path.start(queue: queue)
        wifiPath.start(queue: queue)
        cellularPath.start(queue: queue)
    }

    private func interfaceChanged(_ update: (LoopbackMonitor) -> Void) {
        let before = (wifiUp, cellularUp, cellularOnly)
        update(self)
        cellularOnly = Self.forcedCellular || (cellularUp && !wifiUp)
        if (wifiUp, cellularUp, cellularOnly) != before { networkChanged(physical: true) }
    }

    /// Whatever was probed before is stale. The Bonjour budget starts over only when a physical
    /// interface came or went: the path summary also changes when a proxy's tunnel rebinds.
    private func networkChanged(physical: Bool) {
        probeEpoch &+= 1
        networkRevision &+= 1
        cachedHandshakes.removeAll()
        if physical || !isWorking { resetPortSearch() }
        if !isWorking { publish(.checking, log: false) }
        check()
    }

    /// `-pokiLoopback cellular`, `working` or `noanswer`: a simulator has no cellular and no 10.7.0.x, so a screenshot sets the state by hand.
    nonisolated private static var forced: String? {
        #if targetEnvironment(simulator)
        UserDefaults.standard.string(forKey: "pokiLoopback")
        #else
        nil
        #endif
    }
    nonisolated private static var forcedCellular: Bool { forced == "cellular" }

    private static func same(_ a: State, _ b: State) -> Bool {
        switch (a, b) {
        case (.working(let x), .working(let y)): abs(x - y) < 100
        default: a == b
        }
    }

    var isWorking: Bool { state.isWorking }

    /// No developer port answered while only cellular was available. This does not locate the failure.
    var cellularRefused: Bool { state == .noAnswer && cellularOnly }

    /// Checks every `interval` seconds until `pause` (3 s in front; the app uses a slower one in the
    /// background while an agent works, so a dropped tunnel is noticed and named).
    func resume(every interval: TimeInterval = 3) {
        if let timer, abs(timer.timeInterval - interval) < 0.5 {
            check()
            return
        }
        timer?.invalidate()
        check()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in self?.check() } }
    }

    func pause() { timer?.invalidate(); timer = nil }

    /// Called when the remote pairing service was found on another port and that port is in use:
    /// whatever waits on a refused connection can try again now.
    var onPairingPort: ((UInt16) -> Void)?
    /// Called when the looks for a moved port ended without one: a refused connection is handled as
    /// before again (on a mounted disk image, Poki's own session), so whatever waits can try now.
    var onPairingPortSearchEnded: (() -> Void)?
    private var portLooks = 0
    private var portSearchedAt = Date.distantPast
    private var portSearchSaid = ""

    /// The remote pairing port does not answer although 10.7.0.1 reaches this iPhone: looks the
    /// port up in Bonjour (three times at most, never on cellular alone; `lookDue`) and, when one
    /// answers, uses it from here on.
    private func movedPairingPort(from port: UInt16, requireHandshake: Bool, epoch: Int) async -> ProbeResult? {
        guard epoch == probeEpoch else { return nil }
        guard RemotePairingPort.lookDue(cellularOnly: cellularOnly, looks: portLooks, lastAt: portSearchedAt, now: Date()) else { return nil }
        portLooks += 1
        portSearchedAt = Date()
        RemotePairingPort.setSearching(true)
        var answer: ProbeResult?
        let search = await RemotePairingPort.search(besides: port, browse: { await self.browse() }) { candidate in
            guard self.probeEpoch == epoch else { return false }
            let result = await self.serviceProbe(port: candidate, requireHandshake: requireHandshake, epoch: epoch)
            if result.outcome == "connected" { answer = result }
            return result.outcome == "connected"
        }
        // The same finding every 10 s is said once.
        let said = search.said(besides: port)
        guard probeEpoch == epoch else { return nil }
        lastPortSearch = said
        if said != portSearchSaid { portSearchSaid = said; AppLog.shared.add("loopback", said) }
        guard let found = search.found, let answer else {
            if portLooks >= RemotePairingPort.lookDelays.count {
                AppLog.shared.add("loopback", "no moved remote pairing port after \(portLooks) looks: a refused connection is handled as before until the network changes")
                endPortSearch()
            }
            return nil
        }
        RemotePairingPort.use(found)
        RemotePairingPort.setSearching(false)
        portLooks = 0
        onPairingPort?(found)
        return answer
    }

    /// The launcher stops waiting for a moved port: a refusal takes its earlier path again.
    private func endPortSearch() {
        guard RemotePairingPort.searching else { return }
        RemotePairingPort.setSearching(false)
        onPairingPortSearchEnded?()
    }

    /// The network changed, or the port answers: a later refusal is looked up from the start.
    private func resetPortSearch() {
        portLooks = 0
        portSearchedAt = .distantPast
        endPortSearch()
    }

    func check() {
        if running {
            checkQueued = true
            return
        }
        running = true
        checkQueued = false
        let epoch = probeEpoch
        Task {
            let port = RemotePairingPort.current
            let requireHandshake = recoveringHandshake || remotePairingRequired()
            var result = await serviceProbe(port: port, requireHandshake: requireHandshake, epoch: epoch)
            guard epoch == probeEpoch else { running = false; check(); return }
            if result.outcome == "connected" {
                if portLooks > 0 { resetPortSearch() }
            } else if requireHandshake {
                // A proxy can accept every TCP port and close after 5s. Only
                // a RemotePairing response qualifies a discovered candidate.
                result = await movedPairingPort(from: port, requireHandshake: true, epoch: epoch) ?? result
            } else {
                let lockdown = await connect("10.7.0.1", 62078, 1.5)
                guard epoch == probeEpoch else { running = false; check(); return }
                // 10.7.0.1 reaches this iPhone (lockdown answers, or the phone refused the port), and
                // the remote pairing service is not on the port Poki uses: iOS may have moved it.
                // Without this the page says Working while every connection is refused.
                if lockdown.outcome == "connected" || result.outcome == "refused" {
                    result = await movedPairingPort(from: port, requireHandshake: false, epoch: epoch) ?? lockdown
                } else {
                    // 10.7.0.1 does not reach this iPhone at all: not a moved port.
                    endPortSearch()
                    result = lockdown
                }
            }
            running = false
            // A network change makes this answer stale: ask again. A timer tick or resume() that came
            // while the probe was in flight does not: the answer stands, and one more check follows it.
            if epoch != probeEpoch {
                check()
                return
            }
            completedChecks &+= 1
            let interfaceOrAcceptedTCP = tunnelInterface() != nil || result.outcome == "handshake_failed"
            let probed: State = result.outcome == "connected" ? .working(ms: result.milliseconds) : interfaceOrAcceptedTCP ? .noAnswer : .off
            let next = Self.forcedCellular || Self.forced == "noanswer" ? State.noAnswer : Self.forced == "working" ? State.working(ms: 5) : probed
            // Only a change is published, so the screens are not redrawn every 3 s (a redraw while
            // the person drags a list makes scrolling stutter).
            publish(next, log: true)
            if checkQueued { check() }
        }
    }

    private func publish(_ next: State, log: Bool) {
        if next != .checking { checkedAt = Date() }
        guard !Self.same(next, state) else { return }
        let old = state
        state = next
        if case .working = old, !isWorking { droppedAt = Date() }
        if isWorking { droppedAt = nil }
        if log { AppLog.shared.add("loopback", "developer service: \(next)") }
        onChange?(old, next)
    }

    #if DEBUG
    /// Tests: set the state as a probe result would, running the change hook.
    func simulate(_ next: State) {
        publish(next, log: false)
    }
    #endif

    static var cellularHint: String { AppLocalization.text(LocalizedStringResource("This iPhone does not answer at 10.7.0.1 on cellular. With the developer disk image still mounted, new tasks start without the loopback. Renewing, updating and mounting the image need Wi-Fi.")) }
    /// Renewing, updating and the first mount of the disk image go through the loopback (ESP-448).
    static var needsWiFi: String { AppLocalization.text(LocalizedStringResource("This step needs Wi-Fi. Connect and try again.")) }

    var text: String {
        switch state {
        case .checking: AppLocalization.text(LocalizedStringResource("Checking…"))
        case .working: AppLocalization.text(LocalizedStringResource("Working"))
        case .noAnswer: AppLocalization.text(LocalizedStringResource("Tunnel on, no answer"))
        case .off: AppLocalization.text(LocalizedStringResource("Off"))
        }
    }

    var detail: String {
        switch state {
        case .checking: AppLocalization.text(LocalizedStringResource("Looking for this iPhone at 10.7.0.1."))
        case .working(let ms): AppLocalization.text(LocalizedStringResource("This iPhone answers at 10.7.0.1 (\(ms) ms)."))
        case .noAnswer where lastHandshake?.tcpConnected == true && lastHandshake?.handshakeOK == false:
            "TCP 已接通，但 Remote Pairing 服务未完成握手。配对密钥尚未验证；不会因此删除记录。请查看本机状态页的握手诊断。"
        case .noAnswer where cellularOnly: Self.cellularHint
        case .noAnswer: AppLocalization.text(LocalizedStringResource("The local interface is present, but this iPhone does not answer at 10.7.0.1. Reconnect the local connection and check Wi-Fi. If it still does not answer, pair again in Setup › Pairing, then check Developer Mode."))
        case .off: AppLocalization.text(LocalizedStringResource("This iPhone does not answer yet. Enable Poki's local connection, or choose an external connection in Setup."))
        }
    }
}
