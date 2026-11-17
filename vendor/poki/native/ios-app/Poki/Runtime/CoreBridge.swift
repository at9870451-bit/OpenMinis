import Foundation
import PokiCore

// The app shell's view of PokiCore (docs/ios-core.md, section 2) and PokiLauncher (section 3). LiveCore
// maps PokiCore's events onto ShellEvent; RustLauncher and RustPairing call PokiLauncher's C ABI.

/// What the shell shows. One-to-one with PokiCore's CoreEvent, plus the screenshot thumbnail the Live
/// Activity draws.
enum ShellEvent: Sendable {
    case relay(RelayStatus)
    /// `session` is the MCP client's session that made the call; nil for the app's own callers (the chat).
    case toolStarted(name: String, summary: String, session: String?)
    case toolFinished(summary: String, delivery: String, app: String?, thumbnail: Data?, error: String?, session: String?)
    /// An MCP client's session began (initialize) or ended (its DELETE).
    case session(SessionSignal)
    case approvalRequested(PendingApproval)
    case approvalEnded(id: String, approved: Bool?)
    /// The model handed a screen to the owner (a passcode, a password, a verification, a payment, other).
    case handoffRequested(id: String, kind: String, text: String?, app: String?)
    /// `how` is "done" (the owner tapped Done) or "takenBack" (the model went on by itself).
    case handoffEnded(id: String, how: String)
}

enum RelayStatus: Sendable, Equatable {
    case off, connecting, ready, offline(String)
    var text: String {
        switch self {
        case .off: "Off"
        case .connecting: "Connecting"
        case .ready: "Online"
        case .offline(let why): "Offline: \(why)"
        }
    }
    var isOffline: Bool {
        if case .offline = self { true } else { false }
    }
}

protocol CoreSession: AnyObject {
    func start(relay: RelayAddress)
    func stop()
    var events: AsyncStream<ShellEvent> { get }
    func resolveApproval(id: String, approved: Bool)
}

/// The launcher's state, as its JSON events report it.
struct RunnerStatus: Sendable, Equatable, Decodable {
    var state: String
    var detail: String?
    var attempt: Int?
    var fix: String?
    /// The launcher's short code for what to do, e.g. "ddi_bad" (download the image again).
    var code: String?
    var pairing: String?
    static let idle = RunnerStatus(state: "idle")

    var isRunning: Bool { state == "running" }
    var title: String {
        switch state {
        case "idle": "Not started"
        case "standby": "Sleeping"
        case "connecting": "Connecting"
        case "pairing": "Checking pairing"
        case "tunnel": "Opening tunnel"
        case "mounting_ddi": "Preparing"
        case "launching": "Starting"
        case "running": "Running"
        // The loopback works here: the phone refused the remote pairing port, and Poki looks it up.
        case "waiting_network" where code == "pairing_port": "Finding the pairing port"
        case "waiting_network": "Needs loopback"
        case "failed": "Stopped"
        default: state
        }
    }
}

protocol RunnerLauncher: AnyObject {
    func start(config: LauncherConfig, onEvent: @escaping @Sendable (RunnerStatus) -> Void) throws
    func restart()
    func stop()
}

struct LauncherConfig: Encodable {
    var device_address = "10.7.0.1"
    var pairing_file: String
    var host_name = "Poki"
    var ddi_dir: String
    var runner_bundle: String? = nil
    var wda_port = 8100
    /// Mount the disk image only: Poki automates the phone itself (AutomationPath.inProcess).
    var in_process = false
    /// A file the mounted disk image puts on the phone: in-process, when the loopback refuses the
    /// connection and this file is there, the launcher hands over to Poki's own session (ESP-448).
    var ddi_marker: String? = nil
}

/// On-device wireless pairing (iOS 27, Settings > Privacy & Security > Developer Mode > Pair).
protocol DevicePairing: AnyObject {
    func start(hostName: String, saveTo: URL, onEvent: @escaping @Sendable (PairingEvent) -> Void) throws
    func cancel()
}

enum PairingEvent: Sendable, Equatable {
    case advertising
    case pin(String)
    case paired(URL)
    case failed(String)
}
