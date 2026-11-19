import Foundation

/// A read-only, local snapshot. Availability/configuration never means connected.
public struct AmoreDeviceStatus: Equatable, Sendable {
    public enum State: String, Sendable { case currentDevice, disconnected, needsPairing, waitingDeveloperMode, localChannel, preparing }
    public enum Transport: String, CaseIterable, Identifiable, Sendable {
        case inProcess, nativeTunnel, external
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .inProcess: "进程内本地通道（无需 VPN）"
            case .nativeTunnel: "内置原生隧道（需签名能力）"
            case .external: "外部连接（兼容回退）"
            }
        }
    }
    public let state: State
    public let transport: Transport?
    public let sessionOn: Bool
    public let automationEnabled: Bool
    public let runnerState: String
    public let runnerCode: String?
    public let inProcessOpen: Bool
    public let loopbackWorking: Bool
    public let loopbackText: String
    public let pairingPresent: Bool
    public let pairingVerifiedAt: Date?
    public let pairingProblem: String?
    /// Setup's last confirmation, not a fresh OS capability check.
    public let developerModeConfirmed: Bool
    public let localDDIMounted: Bool
    public let nativeTunnelAvailable: Bool
    public let nativeTunnelState: String
    public let problem: String?

    public var isConnectedToCurrentDevice: Bool { state == .currentDevice }
    public var title: String {
        switch state {
        case .currentDevice: "当前本机"
        case .disconnected: "未连接"
        case .needsPairing: "需配对"
        case .waitingDeveloperMode: "等待 DeveloperMode"
        case .localChannel: "本地通道"
        case .preparing: "正在准备"
        }
    }
    /// A pure reducer, also used by the regression harness. A listening relay,
    /// mounted DDI, or working TCP probe alone never establishes automation.
    public static func classify(pairingPresent: Bool, pairingRejected: Bool, developerMode: Bool,
                                sessionOn: Bool, runnerRunning: Bool, inProcessOpen: Bool,
                                inProcess: Bool, channelWorking: Bool, preparing: Bool) -> State {
        if !pairingPresent || pairingRejected { return .needsPairing }
        if sessionOn && runnerRunning && (inProcess ? inProcessOpen : channelWorking) { return .currentDevice }
        if !developerMode { return .waitingDeveloperMode }
        if preparing { return .preparing }
        if channelWorking { return .localChannel }
        return .disconnected
    }
}

public struct AmorePendingApproval: Identifiable, Equatable, Sendable {
    public let id: String
    public let action: String
    public let reason: String
    public let app: String
    public let expires: Date
    public let submitted: Bool
    public func canResolve(at date: Date) -> Bool { !submitted && expires > date }
    public static func canResolve(id: String, pendingIDs: Set<String>, expires: Date, submitted: Bool, at date: Date) -> Bool {
        !id.isEmpty && pendingIDs.contains(id) && !submitted && expires > date
    }
}

/// Upstream ActionLog persists reason/action/app/result/time, but does not keep
/// the original approval ID or expiry. Do not invent either for old history.
public struct AmoreApprovalHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let action: String
    public let app: String?
    public let reason: String?
    public let detail: String?
    public let approved: Bool
    public let at: Date
}
