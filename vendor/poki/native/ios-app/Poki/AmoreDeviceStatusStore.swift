import Foundation
import Observation

@MainActor
@Observable
public final class AmoreDeviceStatusStore {
    // Observe the existing model; never instantiate another AppModel/ChatModel.
    private let model: AppModel
    private var refreshRevision = 0
    init(model: AppModel) { self.model = model }
    public var snapshot: AmoreDeviceStatus {
        _ = refreshRevision
        return model.amoreStatusSnapshot
    }
    public var pendingApprovals: [AmorePendingApproval] {
        model.approvals.map {
            AmorePendingApproval(id: $0.id, action: $0.summary, reason: $0.reason,
                                 app: $0.app, expires: $0.expires, submitted: model.approvalWasSubmitted($0.id))
        }
    }
    public var recentApprovalHistory: [AmoreApprovalHistoryEntry] {
        ActionLog.shared.entries.reversed().filter { $0.kind == .approval }.prefix(100).map {
            AmoreApprovalHistoryEntry(id: $0.id, action: $0.text, app: $0.app,
                                     reason: $0.why, detail: $0.detail, approved: $0.ok, at: $0.at)
        }
    }
    /// No authorization, pairing verification, VPN start or high-frequency polling.
    /// An external/native tunnel may get ONE existing loopback probe on user refresh.
    public func refresh() {
        model.lookForHandedPairing()
        ActionLog.shared.load()
        refreshRevision &+= 1
        if model.setup.loopback == .proxy || model.setup.loopback == .builtIn { model.loopback.check() }
    }
    public func selectTransport(_ transport: AmoreDeviceStatus.Transport) -> Bool {
        guard canChangeTransport else { return false }
        switch transport {
        case .inProcess: model.chooseConnection(.inProcess)
        case .nativeTunnel: model.chooseConnection(.builtIn)
        case .external: model.chooseConnection(.proxy)
        }
        // Selection is not activation, pairing, approval or proof of connection.
        return true
    }
    public var canChangeTransport: Bool { !model.connectionInUse && !model.tunnel.busy }
    public func retryConnectionProbe() {
        guard !model.usesLocalProcessTransport else { return }
        model.loopback.retryProtocolCheck()
    }
    public func stopAutomationSession() { AmoreDeviceServices.stopAutomationSession() }
    public var canPrepareAutomation: Bool {
        !model.amorePreparationInProgress && !model.sessionStarting && AmoreDeviceServices.isEnabled
    }
    /// Call only after a user gesture/confirmation. Refresh and page appearance
    /// deliberately never call this method.
    public func prepareAutomationByOwner() async {
        _ = await model.prepareAmoreAutomationByOwner()
        refreshRevision &+= 1
    }
    public var diagnosticText: String {
        let snapshot = model.amoreStatusSnapshot
        var lines = ["Amore local connection diagnostic", "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "service target: 10.7.0.1:\(RemotePairingPort.current)",
                     "transport: \(snapshot.transport?.rawValue ?? "none")",
                     "sessionOn: \(snapshot.sessionOn); runner: \(snapshot.runnerState); code: \(snapshot.runnerCode ?? "none")",
                     "Wi-Fi: \(model.loopback.wifiUp); cellular: \(model.loopback.cellularUp)",
                     "DDI mounted: \(snapshot.localDDIMounted); DDI files checked: \(model.diskImage.hasFiles); pairing present: \(snapshot.pairingPresent)",
                     "automationReady: \(snapshot.automationReady); phase: \(snapshot.preparationPhase)",
                     "full verification: \(snapshot.verificationStage.rawValue); attempt: \(model.amoreVerificationAttemptAt?.description ?? "never"); accepted: \(snapshot.pairingVerifiedAt?.description ?? "never")",
                     "verification error: \(snapshot.verificationError ?? "none"); retry not before: \(model.amoreVerificationRetryAt?.description ?? "now")",
                     "runner detail: \(snapshot.runnerDetail ?? "none"); fix: \(snapshot.runnerFix ?? "none"); attempt: \(snapshot.runnerAttempt.map(String.init) ?? "none")",
                     "in-process state: \(snapshot.processState); core readiness: \(model.amoreCoreReadiness)",
                     model.amoreDeviceLifecycleDiagnostic,
                     "owner preparation: \(snapshot.preparationResult ?? "not requested")",
                     "problem: \(snapshot.problem ?? "none")",
                     "Hello/handshakeOK is service reachability only; it is NOT authenticated pairing or automation readiness."]
        if let value = loopbackInterface() { lines.append("interface: \(value.interface) \(value.address)") }
        if let result = model.loopback.lastHandshake { lines.append(result.summary) }
        lines.append(model.loopback.lastPortSearch)
        return AmoreDeviceDiagnostic.safe(lines.joined(separator: "\n"))
    }
    public var handshakeDetail: String? { model.loopback.lastHandshake?.summary }
    public var lastProbeAt: Date? { model.loopback.checkedAt }
    public var portSearchDetail: String { model.loopback.lastPortSearch }
}

extension AppModel {
    var amoreStatusSnapshot: AmoreDeviceStatus {
        let transport: AmoreDeviceStatus.Transport?
        switch setup.loopback {
        case .none: transport = nil
        case .inProcess: transport = .inProcess
        case .builtIn: transport = .nativeTunnel
        case .proxy: transport = .external
        }
        let channel = hasOpenInProcessSession || ((transport == .external || transport == .nativeTunnel) && loopback.isWorking)
        let state = AmoreDeviceStatus.classify(pairingPresent: pairingPath != nil, pairingRejected: pairingTrouble != nil,
                                               developerMode: setup.developerMode, sessionOn: sessionOn,
                                               runnerRunning: runner.isRunning, inProcessOpen: hasOpenInProcessSession,
                                               inProcess: automationPath == .inProcess, channelWorking: channel,
                                               preparing: sessionStarting || preparingPhone || amorePreparationInProgress,
                                               automationReady: amoreAutomationReady,
                                               pairingVerified: amoreVerificationStage == .verified)
        return AmoreDeviceStatus(state: state, transport: transport, sessionOn: sessionOn,
                                 automationEnabled: AmoreDeviceServices.isEnabled, runnerState: runner.state,
                                 runnerCode: runner.code, runnerDetail: runner.detail.map(AmoreDeviceDiagnostic.safe),
                                 runnerFix: runner.fix.map(AmoreDeviceDiagnostic.safe), runnerAttempt: runner.attempt,
                                 automationReady: amoreAutomationReady, preparationPhase: amorePreparationPhase,
                                 preparationInProgress: amorePreparationInProgress, preparationResult: amorePreparationResult,
                                 verificationStage: amoreVerificationStage, verificationError: amoreVerificationError,
                                 processState: amoreProcessState, inProcessOpen: hasOpenInProcessSession,
                                 loopbackWorking: loopback.isWorking, loopbackText: loopback.text,
                                 pairingPresent: pairingPath != nil, pairingVerifiedAt: pairingVerifiedAt,
                                 pairingProblem: pairingTrouble, developerModeConfirmed: setup.developerMode,
                                 localDDIMounted: Self.localDDIMounted, nativeTunnelAvailable: tunnel.available,
                                 nativeTunnelState: String(describing: tunnel.state),
                                 problem: problem)
    }
}

public extension AmoreDeviceServices {
    private static let sharedStatus = AmoreDeviceStatusStore(model: model)
    static var statusStore: AmoreDeviceStatusStore { sharedStatus }
    static var statusSnapshot: AmoreDeviceStatus { model.amoreStatusSnapshot }
}
