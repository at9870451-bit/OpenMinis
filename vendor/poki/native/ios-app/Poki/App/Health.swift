import SwiftUI

/// A status word and the colour of its dot.
struct Health {
    var word: String
    var color: Color
    static let off = Color.white.opacity(0.48)

    @MainActor static func relay(_ model: AppModel) -> Health {
        switch model.relayStatus {
        case .ready: Health(word: AppLocalization.text(LocalizedStringResource("Online")), color: Site.ok)
        case .connecting: Health(word: AppLocalization.text(LocalizedStringResource("Connecting")), color: .white)
        case .offline: Health(word: AppLocalization.text(LocalizedStringResource("Offline")), color: Site.bad)
        case .off: Health(word: AppLocalization.text(LocalizedStringResource("Off")), color: off)
        }
    }

    @MainActor static func runner(_ model: AppModel) -> Health {
        guard model.sessionOn else { return Health(word: AppLocalization.text(LocalizedStringResource("Off")), color: off) }
        let runner = model.runner
        let word = AppLocalization.bundle.localizedString(forKey: runner.title, value: runner.title, table: nil)
        if runner.isRunning { return Health(word: word, color: Site.ok) }
        if runner.state == "failed" { return Health(word: word, color: Site.bad) }
        return Health(word: word, color: model.runnerPaused ? off : .white)
    }

    @MainActor static func loopback(_ model: AppModel) -> Health {
        let monitor = model.loopback
        if !monitor.isWorking && model.hasOpenInProcessSession {
            return Health(word: AppLocalization.text(LocalizedStringResource("Local automation ready")), color: off)
        }
        switch monitor.state {
        case .working: return Health(word: AppLocalization.text(LocalizedStringResource("On")), color: Site.ok)
        case .checking: return Health(word: AppLocalization.text(LocalizedStringResource("Checking…")), color: .white)
        case .noAnswer: return Health(word: AppLocalization.text(LocalizedStringResource("No Answer")), color: Site.bad)
        case .off: return Health(word: AppLocalization.text(LocalizedStringResource("Off")), color: Site.bad)
        }
    }
}

/// Something that keeps agents from using the phone, with the one thing the person has to do.
struct Issue: Identifiable {
    enum Fix { case setup, settings, retry, none }
    var id: String
    var title: String
    var text: String
    var fix: Fix

    var button: LocalizedStringKey? {
        switch fix {
        case .setup: "Open Setup"
        case .settings: "Open Settings"
        case .retry: "Try Again"
        case .none: nil
        }
    }

    @MainActor func act(_ model: AppModel, openSetup: () -> Void) {
        switch fix {
        case .setup: openSetup()
        case .settings: if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .retry: model.runnerPaused ? model.wakeRunner() : model.restartRunner()
        case .none: break
        }
    }

    /// Text from PokiCore and the launcher stays as it came; Poki's own sentences are localized.
    private static func local(_ text: String) -> String { AppLocalization.bundle.localizedString(forKey: text, value: text, table: nil) }

    @MainActor static func current(_ model: AppModel) -> [Issue] {
        var out: [Issue] = []
        if model.sessionOn {
            let runner = model.runner
            if runner.state == "failed", model.pairingTrouble == nil {
                let fix = runner.fix ?? ""
                let kind: Fix = switch runner.code {
                case "runner", "pairing", "handshake", "unreachable", "ddi_refused": .setup
                case "developer_mode", "no_cryptexd", "ios_too_old", "runner_blocked": .settings
                default: .retry
                }
                out.append(Issue(id: "runner", title: AppLocalization.text(LocalizedStringResource("The runner stopped")),
                                 text: fix.isEmpty ? (runner.detail.map { "\($0.prefix(1).uppercased())\($0.dropFirst())." } ?? AppLocalization.text(LocalizedStringResource("Poki starts it again on the next agent request."))) : local(fix), fix: kind))
            } else if runner.state == "waiting_network", let fix = runner.fix, fix.contains("internet") {
                out.append(Issue(id: "network", title: AppLocalization.text(LocalizedStringResource("Waiting for the internet")), text: local(fix), fix: .none))
            } else if let trouble = model.localSessionTrouble {
                out.append(Issue(id: "local", title: AppLocalization.text(LocalizedStringResource("Automation did not start")), text: trouble.text, fix: trouble.opensSetup ? .setup : .none))
            } else if model.loopback.cellularRefused {
                // On the mounted image a new task starts without the loopback; only the mount needs Wi-Fi.
                if model.cellularNeedsWiFi, !runner.isRunning {
                    out.append(Issue(id: "cellular", title: AppLocalization.text(LocalizedStringResource("Connect to Wi-Fi first")), text: LoopbackMonitor.needsWiFi, fix: .none))
                }
            } else if !model.hasOpenInProcessSession, !model.canStartTasks, runner.code != "local_ddi",
                      (runner.state == "waiting_network" && runner.code != "pairing_port" && !model.loopback.isWorking)
                      || (!model.loopback.isWorking && model.loopback.state != .checking) {
                out.append(Issue(id: "loopback", title: AppLocalization.text(LocalizedStringResource("Loopback is off")),
                                 text: AppLocalization.text(LocalizedStringResource("Turn on your proxy app with the Poki module, or connect LocalDevVPN.")), fix: .setup))
            }
            if let trouble = model.pairingTrouble {
                out.append(Issue(id: "pairing", title: AppLocalization.text(LocalizedStringResource("Pair this iPhone again")),
                                 text: AppLocalization.text(LocalizedStringResource("The phone no longer accepts Poki’s pairing (\(trouble)). Pair again in Setup; it takes a minute.")), fix: .setup))
            }
            if model.passcodeHint {
                out.append(Issue(id: "passcode", title: AppLocalization.text(LocalizedStringResource("Enter the passcode if the iPhone asks")),
                                 text: model.automationPath == .inProcess
                                    ? AppLocalization.text(LocalizedStringResource("iOS asks for the passcode to allow UI Automation after Poki restarts, or 8 hours after it was last entered. Enter it once; Poki carries on by itself."))
                                    : AppLocalization.text(LocalizedStringResource("iOS asks for the passcode before UI Automation after Poki Runner was force-closed or the iPhone restarted. Enter it once; Poki carries on by itself.")), fix: .none))
            }
            if let text = model.handoffText {
                out.append(Issue(id: "handoff", title: AppLocalization.text(LocalizedStringResource("Your turn")),
                                 text: AppLocalization.text(LocalizedStringResource("\(text). The agent waits and sends nothing until you tap Done on the Live Activity.")), fix: .none))
            }
            if case .offline = model.relayStatus {
                out.append(Issue(id: "relay", title: AppLocalization.text(LocalizedStringResource("Agents can’t reach this iPhone")),
                                 text: AppLocalization.text(LocalizedStringResource("Poki is offline. Check that the phone has internet; Poki reconnects by itself.")), fix: .none))
            }
            if model.background.denied {
                out.append(Issue(id: "location", title: AppLocalization.text(LocalizedStringResource("Poki can’t stay on in the background")),
                                 text: AppLocalization.text(LocalizedStringResource("Allow location access for Poki (Settings › Poki › Location › Always). Poki uses it only to keep running; it never records where you are.")), fix: .settings))
            }
        }
        if !model.sessionOn, model.cellularNeedsWiFi {
            out.append(Issue(id: "cellular", title: AppLocalization.text(LocalizedStringResource("Connect to Wi-Fi first")), text: LoopbackMonitor.needsWiFi, fix: .none))
        }
        if let problem = model.problem {
            out.append(Issue(id: "problem", title: AppLocalization.text(LocalizedStringResource("Needs attention")), text: local(problem), fix: problem.contains("Pair") || problem.contains("disk image") || problem.contains("Setup") ? .setup : .none))
        }
        if let problem = model.activityProblem {
            out.append(Issue(id: "activity", title: AppLocalization.text(LocalizedStringResource("Live Activity is off")), text: local(problem), fix: .settings))
        }
        return out
    }
}
