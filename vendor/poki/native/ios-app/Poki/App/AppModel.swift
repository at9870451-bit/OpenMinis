import PokiNative
import CryptoKit
import PokiCore
import SwiftUI
import UIKit
import UserNotifications

/// The app's state and the glue between PokiCore, PokiLauncher, the loopback, the Live Activity and
/// approvals. One instance, owned by PokiApp.
@MainActor
@Observable
final class AppModel {
    var setup = SetupState.load() { didSet { setup.save() } }
    let identity = RelayIdentity()
    /// The person's own relay (Connect). Poki has no default relay and sends nothing until one is set.
    private(set) var relayAddress = RelayAddress.saved
    /// The relay on or off (Agents > MCP Relay). On by default, and turned on when an address is set;
    /// off, Poki makes no relay connection and only its own chat agent can use the phone.
    private(set) var relayEnabled = UserDefaults.standard.object(forKey: "relayEnabled") as? Bool ?? true
    /// The relay Poki connects to: the address, while the relay is on.
    var activeRelay: RelayAddress? { relayEnabled ? relayAddress : nil }

    func setRelayEnabled(_ on: Bool) {
        guard on != relayEnabled, relayAddress != nil || !on else { return }
        relayEnabled = on
        UserDefaults.standard.set(on, forKey: "relayEnabled")
        log.add("relay", on ? "turned on" : "turned off")
        guard sessionOn else { return }
        if on, let relayAddress { core.start(relay: relayAddress) } else { core.stop() }
    }
    let loopback = LoopbackMonitor()
    let tunnel = LoopbackTunnel()
    let background = BackgroundKeeper()
    let diskImage = DiskImageStore()
    /// Poki keeps its own signing: the Apple Account, the next build ready ahead of time, Install.
    let signer = SelfSigner()
    let voice: VoiceModel
    private(set) var runner = RunnerStatus.idle
    private(set) var relayStatus = RelayStatus.off
    private(set) var sessionOn = false
    private(set) var activityText = "Idle"
    private(set) var lastAction: String?
    private(set) var approvals: [PendingApproval] = []
    private(set) var pairing: PairingEvent?
    private(set) var problem: String?
    /// The text the local connection last put in `problem` (another VPN is on), so only that is cleared.
    private var tunnelAttention: String?
    /// The agent's recent actions, newest last, for the home screen.
    private(set) var recentSteps: [RecentStep] = []
    /// The app the agent is in, from its last step.
    private(set) var currentApp: String?
    /// What the core last saw of the screen: the small picture it already makes of every look (the Live
    /// Activity's), for the task card of the task under way. Kept in memory only, and dropped when a
    /// task or an agent's session begins or ends, so one task never shows another's screen.
    private(set) var lastShot: UIImage?
    /// The runner is stopped until the next agent request (idle, or the owner tapped Stop runner).
    private(set) var runnerPaused = false
    /// The owner paused Poki (Pause, the Hands switch, Stop on the Live Activity), as opposed to the
    /// runner standing by on its own after the idle time. The bear sleeps and Hands reads off only for
    /// this one: standing by after a quiet minute is still ready. Cleared when the runner starts again.
    private(set) var ownerPaused = false
    /// What the in-process session does when Poki stands by between tasks (idle, the end of a task, Poki
    /// coming to the front, a hand-off). Closing it ends the iOS session, and the next one asks for the
    /// passcode again.
    enum IdleSessionPolicy: Equatable {
        case close, pauseAutomation
        /// iOS 18 to 26 run Poki on an XCTest session, and iOS asks for the passcode again for each new
        /// one, so there the session stays and only Automation Mode goes off. iOS 27 keeps closing it.
        static func forSystem(_ version: OperatingSystemVersion) -> IdleSessionPolicy {
            version.majorVersion >= 27 ? .close : .pauseAutomation
        }
    }
    let idleSessionPolicy: IdleSessionPolicy
    /// Agents › Approvals: how the owner is asked, or never. The saved choice (`ApprovalClassifier.mode`)
    /// is the one copy: the pages here show it, and PokiCore's rules and each approval's route read it
    /// at every step, so a change counts from the next step.
    var approvalMode: ApprovalClassifier.Mode {
        get {
            access(keyPath: \.approvalMode)
            return ApprovalClassifier.mode
        }
        set {
            withMutation(keyPath: \.approvalMode) {
                // The first choice here saves the sensitivity Rules shows with it: beside a saved way of asking a
                // sensitivity counts as chosen, and one left from 0.3.1 or 0.3.0 would move it behind the slider.
                if ApprovalClassifier.Mode(rawValue: UserDefaults.standard.string(forKey: ApprovalClassifier.modeKey) ?? "") == nil {
                    UserDefaults.standard.set(classifierLevel.rawValue, forKey: ApprovalClassifier.levelKey)
                }
                UserDefaults.standard.set(newValue.rawValue, forKey: ApprovalClassifier.modeKey)
            }
            log.add("approval", "ask before sensitive steps: \(newValue.rawValue)")
            for observer in approvalModeObservers { observer() }
        }
    }
    /// Whether a sensitive step waits for the owner now.
    var asksBeforeSensitiveSteps: Bool { approvalMode != .off }
    private var approvalModeObservers: [() -> Void] = []
    func addApprovalModeObserver(_ observer: @escaping () -> Void) { approvalModeObservers.append(observer) }
    private var stopAskingObservers: [() -> Void] = []
    /// Called when Don’t Ask Again turned approvals off, for the chat to say so.
    func addStopAskingObserver(_ observer: @escaping () -> Void) { stopAskingObservers.append(observer) }
    var classifierLevel: ApprovalClassifier.Level = ApprovalClassifier.Level.saved {
        didSet {
            UserDefaults.standard.set(classifierLevel.rawValue, forKey: ApprovalClassifier.levelKey); log.add("approval", "sensitivity: \(classifierLevel.rawValue)")
            // Likewise the way of asking Rules shows, so the sensitivity counts as chosen here.
            if ApprovalClassifier.Mode(rawValue: UserDefaults.standard.string(forKey: ApprovalClassifier.modeKey) ?? "") == nil {
                UserDefaults.standard.set(approvalMode.rawValue, forKey: ApprovalClassifier.modeKey)
            }
        }
    }
    /// Lists ask_poki for outside agents. Testing only, off.
    var askPokiTool: Bool = UserDefaults.standard.bool(forKey: AskPoki.onKey) {
        didSet { UserDefaults.standard.set(askPokiTool, forKey: AskPoki.onKey); log.add("chat", "ask_poki tool: \(askPokiTool ? "on" : "off")"); AskPoki.refresh() }
    }
    var idleStopSeconds: Int = UserDefaults.standard.object(forKey: "idleStopSeconds.v4") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(idleStopSeconds, forKey: "idleStopSeconds.v4"); log.add("runner", "idle stop set to \(idleStopSeconds) s") }
    }
    /// Poki was on when it last ran; it turns itself on again at launch. Poki Setup's install turns it
    /// on the first time (see `init`).
    private(set) var wantsOn: Bool {
        get { UserDefaults.standard.bool(forKey: "wantsOn") }
        set { UserDefaults.standard.set(newValue, forKey: "wantsOn") }
    }
    /// The setup step the Live Activity is guiding, if any.
    private(set) var guiding: SetupStep?
    /// The pairing file, if it is really there. The path is never stored: the app's container moves
    /// when Poki is installed again, and a stored path then points at nothing.
    var pairingPath: String? {
        _ = pairingFileSeen
        if FileManager.default.fileExists(atPath: AppFiles.phonePairingFile.path) { return AppFiles.phonePairingFile.path }
        return FileManager.default.fileExists(atPath: AppFiles.pairingFile.path) ? AppFiles.pairingFile.path : nil
    }
    /// Whether the pairing file was there at the last look. Poki Setup on a computer writes it into
    /// Poki's container after an install, while Poki may be running: setting this redraws what depends
    /// on `pairingPath` (the file itself is not observed).
    private var pairingFileSeen = FileManager.default.fileExists(atPath: AppFiles.pairingFile.path)
    /// Looks for a pairing file Poki Setup put in the container (at launch, on coming to the front,
    /// and every few seconds on the pairing step).
    func lookForHandedPairing() {
        let there = FileManager.default.fileExists(atPath: AppFiles.pairingFile.path)
        guard there != pairingFileSeen else { return }
        pairingFileSeen = there
        // A pairing made here writes the same file just before it reports `paired`, which handles it.
        guard there, !pairingUnderWay else { return }
        try? (AppFiles.pairingFile as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        setup.pairingFile = AppFiles.pairingFile.path
        SetupVault.mirrorPairingFromContainer()
        pairingTrouble = nil; pairingVerifiedAt = nil
        log.add("pairing", "pairing file from Poki Setup found")
    }
    /// Why the phone refused the pairing the last time the runner started, until it is accepted again.
    private(set) var pairingTrouble: String?
    /// When the phone last accepted the pairing (the runner got past the pairing step).
    private(set) var pairingVerifiedAt: Date?
    /// The loopback took the connection, but the phone's remote pairing service did not answer through
    /// it (GitHub issue 69). The loopback probe only connects, so it still reads Working; the
    /// Loopback page says so. false once the phone answers again.
    private(set) var servicesSilent = false
    private var loopbackDropped = false
    /// The runner has been launching for a while: iOS may be asking for the passcode.
    private(set) var passcodeHint = false
    /// Turning on now will probably bring up iOS's passcode screen (no automation has started since
    /// this iPhone last restarted, or ever): the owner is told first (`passcodeHeadsUp`).
    var passcodeExpected: Bool { UserDefaults.standard.double(forKey: Self.automationBootKey) != BootClock.current }
    var passcodeHeadsUp = false
    private(set) var passcodeConfirmationPending = false
    static let passcodeConfirmationMessage: LocalizedStringResource = "To turn on automation, open Settings › Connection and tap Continue."
    /// The note's text (PokiApp's alert). Its translations are looked up by this exact English key.
    static let passcodeHeadsUpMessage: LocalizedStringResource = "This is the first time Poki starts automation since your iPhone restarted, so iOS will ask for your passcode. It may ask only when Poki first operates the phone. That screen belongs to iOS. Poki can’t see or read what you enter, and it asks only once until the next restart."
    private var passcodeHeadsUpReconnect = true
    private var passcodeHeadsUpSeen = 0.0
    private static let automationBootKey = "automationStartedBoot"
    /// Automation started in this boot: iOS will not ask again until the next restart.
    private func automationStarted() {
        InProcessWDA.gate.withLock { $0.startedThisBoot = true }
        guard UserDefaults.standard.double(forKey: Self.automationBootKey) != BootClock.current else { return }
        UserDefaults.standard.set(BootClock.current, forKey: Self.automationBootKey)
    }
    /// Continue on the note: Poki turns on, and iOS's passcode screen comes next.
    func continueAfterPasscodeHeadsUp() {
        guard passcodeConfirmationPending else { return }
        passcodeConfirmationPending = false
        passcodeHeadsUp = false
        passcodeHeadsUpSeen = BootClock.current
        if let why = passcodeHeldOpen {
            passcodeHeldOpen = nil
            warmInProcess(why)
            return
        }
        startSession(reconnectLocal: passcodeHeadsUpReconnect)
    }
    func cancelPasscodeHeadsUp() {
        passcodeConfirmationPending = false
        passcodeHeadsUp = false
        passcodeHeldOpen = nil
    }
    /// The in-process open waiting for Continue on the passcode note: its reason.
    private var passcodeHeldOpen: String?
    /// The hand-off the agent asked the owner for, while it waits (shown on the home screen too).
    private(set) var handoffText: String?
    private var launchingSince: Date?
    private var endCheck = 0
    /// Not set at launch: a fresh launch has run nothing, so Install is available at once.
    private var lastAgentActivity = Date.distantPast
    private var chatTaskActive = false
    /// The last agent step (a tool call, a hand-off), for Install's wait. Turning on or waking the
    /// runner is not a step: lastAgentActivity counts those for the idle stop, this does not.
    private var lastStepAt = Date.distantPast
    /// The agent's step now running (its label and start), for the foreground check above.
    private var stepUnderWay: (summary: String, started: Date)?
    /// When the last approval ended, so a Stop landing on the Live Activity right after is not taken.
    private var lastApprovalAnswered: Date?
    private var idleTimer: Timer?
    private var launcherConfig: LauncherConfig?

    let host = AppCoreHost()
    /// Poki Runner or Poki's own process, fixed for this launch (Debug tab).
    let automationPath = AutomationPath.current
    private let core: LiveCore
    private let launcher: RunnerLauncher
    private let pairer: DevicePairing
    private let pairingKeepAlive = KeepAlive()
    private let activity: ActivityController
    private var activitySplitViewSession: String?

    /// Presentation-only refresh: no session, runner, approval or conversation is restarted.
    func languageChanged() {
        ApprovalNotice.registerActions()
        activity.languageChanged()
    }

    /// The Live Activity during a talk with Poki: what the talk is doing, and End.
    private var talkActivity: TalkActivity?
    let log = AppLog.shared
    private var eventsTask: Task<Void, Never>?
    private var handoffTimer: Timer?
    private var sessionStartTask: Task<Void, Never>?
    private(set) var sessionStarting = false
    private var pendingPrepareForTask = false
    private let requiresDiskImageCheck: Bool

    /// No task is running, so an install (which ends Poki) disturbs nothing: no agent step under way,
    /// no approval waiting, and a minute since the agent last did something.
    var signingIdle: Bool { signingBusyReason == nil }

    /// Why Install waits, or nil when nothing is under way. A step whose end never arrived (the
    /// session was turned off mid-step, or the call hung) stops counting after two minutes, so a
    /// lost event cannot keep Install off for good.
    var signingBusyReason: String? {
        if !approvals.isEmpty { return AppLocalization.text(LocalizedStringResource("An approval is waiting for you.")) }
        if sessionStarting { return AppLocalization.text(LocalizedStringResource("Poki is turning on.")) }
        if let step = stepUnderWay, sessionOn, Date().timeIntervalSince(step.started) < 120 {
            return AppLocalization.text(LocalizedStringResource("The agent is doing a step, \(step.summary)."))
        }
        let since = Date().timeIntervalSince(lastStepAt)
        if since < 60 { return AppLocalization.text(LocalizedStringResource("The agent acted \(Int(since)) s ago. Install opens a minute after its last step.")) }
        return nil
    }

    /// Hands the signer the phone's own services and starts it (at launch).
    func startSigner() {
        signer.phone = { [weak self] in
            guard let self, let path = self.pairingPath, self.loopback.isWorking else { return nil }
            return ["device_address": "10.7.0.1", "pairing_file": path, "host_name": "Poki"]
        }
        signer.isIdle = { [weak self] in self?.signingIdle ?? false }
        signer.whyUnreachable = { [weak self] in self?.signerUnreachable ?? .loopback }
        signer.busyReason = { [weak self] in self?.signingBusyReason }
        signer.beforeExit = { [weak self] in await self?.windDownForUpdate() }
        signer.start()
    }

    var connectionInUse: Bool {
        if sessionOn || sessionStarting { return true }
        return pairingUnderWay
    }

    var connectionMethod: SetupState.Loopback {
        if setup.loopback != .none { return setup.loopback }
        // The external app is the way (ESP-168); the built-in connection is only ever chosen.
        return .proxy
    }

    /// look, do or status run here as a relay call would be (the Debug probe's end-to-end check).
    /// The probe opened the in-process session itself (on the simulator there is no launcher), so
    /// PokiCore may act now.
    func inProcessReadyForProbe() { inProcessSession = .open; host.update(runner: .running); probeDriven = true }

    func phoneTool(_ name: String, arguments: String) async -> (text: String, isError: Bool) {
        if let message = signer.installMessage { return (message, true) }
        let result = await core.tool(name, arguments: arguments)
        return (result.text, result.isError)
    }

    /// The same call with its picture, for the gym scorecard (the Debug probe's `gym` mode).
    func phoneToolWithPicture(_ name: String, arguments: String) async -> PokiCore.ToolAnswer {
        await core.callTool(name, arguments: arguments)
    }

    /// The chats watch the steps and approvals of the task they run (the in-app chat and an outside
    /// agent's hand-off each have one).
    private var shellObservers: [(ShellEvent) -> Void] = []
    /// Told when an approval the model would not allow goes on to the owner's card, by id.
    private var approvalObservers: [(String) -> Void] = []
    func addApprovalObserver(_ observer: @escaping (String) -> Void) { approvalObservers.append(observer) }
    /// Approvals the chat model is checking, or that needed nobody; `approvals` are the owner's.
    private var checking: [PendingApproval] = []
    func addShellObserver(_ observer: @escaping (ShellEvent) -> Void) { shellObservers.append(observer) }
    /// A Debug probe drives PokiCore on the simulator without a runner session (the chat's end-to-end check).
    private(set) var probeDriven = false
    /// The app's MCP tools (ask_poki), set by AskPoki.
    func setHostTools(_ tools: [HostTool]) { core.setHostTools(tools) }
    /// The gym probe answers approvals itself: with no session on, `handle` keeps them off the screen.
    var onProbeApproval: ((PendingApproval) -> Void)?

    var canPlanSplitView: Bool {
        (sessionOn || probeDriven) && automationPath == .inProcess && (probeDriven || PKInProcess.canUseDuoSplitView())
    }

    /// The outside agent driving the phone now: its MCP session's client, or the agent that handed
    /// a task to Poki. nil while Poki's own chat drives it.
    var currentCaller: String? {
        let store = SessionStore.shared
        if let id = store.activeSessionID, let client = store.session(id)?.client { return client }
        return ChatModel.delegatedBusy
    }

    init(launcher: RunnerLauncher = RustLauncher(), pairer: DevicePairing = RustPairing(),
         automation: InProcessAutomation = PKInProcess.shared(), transport: HTTPTransport? = nil,
         systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
         requiresDiskImageCheck: Bool? = nil) {
        ActivityController.endAll()
        self.activity = ActivityController()
        self.automation = automation
        self.idleSessionPolicy = .forSystem(systemVersion)
        self.requiresDiskImageCheck = requiresDiskImageCheck ?? !Self.onSimulator
        // A reinstall emptied the container: the pairing file comes back from the Keychain (and the
        // setup state did the same in `SetupState.load`), so the owner is not sent through setup again.
        if SetupVault.restorePairingIfMissing() { AppLog.shared.add("pairing", "pairing file restored from the Keychain after a reinstall") }
        else { SetupVault.mirrorPairingFromContainer() }
        let core = LiveCore(host: host, transport: transport ?? (automationPath == .inProcess ? InProcessWDA() : URLSessionTransport()))
        self.core = core
        // Voice taps get the same rules and approval card as an agent's `do`.
        voice = VoiceModel(clearTap: { text, bundle, name in await core.clearTap(on: text, inApp: bundle, named: name, waiting: VoiceModel.approvalWait) },
                           phoneTool: { name, arguments in
                               #if DEBUG && targetEnvironment(simulator)
                               if TalkRehearsal.asked { return await TalkRehearsal.step() }
                               #endif
                               let result = await core.tool(name, arguments: arguments)
                               return (result.text, result.isError)
                           },
                           holdMicrophone: { [background] on in on ? background.pauseAudio() : background.resumeAudio() },
                           connection: VoiceModel.connection)
        self.launcher = launcher
        self.pairer = pairer
        // inFront starts true before the first scene callback, including a background launch.
        self.activity.canStart = { [weak self] in self?.inFront == true && UIApplication.shared.applicationState == .active }
        host.update(key: identity.signingKey, hashes: identity.accessHashes)
        host.onConsent { [weak self] client, callback, connector in
            await self?.askToConnect(client: client, callback: callback, connector: connector) ?? false
        }
        // PokiCore asks for a restart after two silent requests in a row. A slow gesture can be one of
        // them while the runner is fine, so the runner is asked first; only a runner that does not
        // answer is started again (each restart costs seconds and flashes the automation banner).
        host.onRestart { [weak self, automationPath] in
            // Keep an active in-process session through the task; an initial failed open can retry.
            guard automationPath == .runner else {
                Task { @MainActor in
                    guard let self else { return }
                    self.log.add("runner", "PokiCore asked for a restart: keeping the in-process session through this task")
                    self.warmInProcess("PokiCore's restart")
                }
                return
            }
            Task.detached {
                let answers = await RunnerProbe.answers()
                await MainActor.run { AppLog.shared.add("runner", answers ? "PokiCore asked for a restart; the runner answers, so it was kept" : "PokiCore asked for a restart; the runner does not answer: restarting it") }
                if !answers { launcher.restart() }
            }
        }
        host.onWake { [weak self] in Task { @MainActor in self?.wakeRunner() } }
        host.onWarmUp { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.automationPath == .runner { _ = self.host.runnerState() }
                else { self.prepareForTask() }
            }
        }
        if automationPath == .inProcess {
            host.onRetry { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.wakeRunner()
                    if self.sessionOn { self.host.update(runner: self.coreState(of: self.runner)) }
                }
            }
        }
        // Allow and Deny on the Live Activity run in this process and come straight here.
        ApprovalIntentBridge.install { [weak self] decision in
            guard let self else { return false }
            self.decide(decision)
            return true
        }
        // The same answers from the approval notification's own buttons.
        ApprovalNotice.registerActions()
        listenForApprovals()
        talkActivity = TalkActivity(voice: voice, activity: self.activity, deviceName: { UIDevice.current.name },
                                    keepsActivity: { [weak self] in self?.sessionOn == true })
        // One pump for the app's whole life. Cancelling a task that reads an AsyncStream ends the
        // stream for good, so a pump per session would go silent after the first Turn off (no steps,
        // no approvals, no relay state in the log, which is what happened on the phone).
        eventsTask = Task { [weak self, core] in
            for await event in core.events { self?.handle(event) }
        }
        loopback.onChange = { [weak self] old, new in self?.loopbackChanged(from: old, to: new) }
        loopback.onPairingPort = { [weak self] port in self?.pairingPortFound(port) }
        loopback.onPairingPortSearchEnded = { [weak self] in self?.pairingPortSearchEnded() }
        // A built-in tunnel that fails or drops while Poki is on dials again by itself; the loopback
        // check that follows lets `loopbackChanged` start the runner, as for any other recovery.
        tunnel.wanted = { [weak self] in self?.sessionOn == true && self?.setup.loopback == .builtIn }
        tunnel.onReconnected = { [weak self] in self?.loopback.check() }
        // When Poki detects the owner's own VPN it stops: the tunnel says so here, and the problem clears when it is back.
        tunnel.onAttention = { [weak self] text in
            guard let self else { return }
            if let text { problem = text; tunnelAttention = text }
            else if problem == tunnelAttention { problem = nil; tunnelAttention = nil }
        }
        Task { [weak self] in
            guard let self else { return }
            await self.diskImage.ensureChecked()
            // Amore: DDI download begins only from the original explicit setup button.
        }
        // Just installed by Poki Setup on a computer (its signing key still waits in the container, and
        // the owner never turned Poki on or off): Poki turns on by itself, so it does not stand at Off.
        if UserDefaults.standard.object(forKey: "wantsOn") == nil, FileManager.default.fileExists(atPath: SelfSigner.handedIdentity.path) {
            wantsOn = true
            log.add("session", "installed by Poki Setup: Poki turns on by itself")
        }
        // The installer on the Mac reads the hello and may leave a sealed model key while Poki is in front.
        handoffTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.inFront == true { self?.handoffTick() } }
        }
        // An agent whose session began before this launch is named from its connector.
        SessionStore.shared.connectorAgent = { [identity] hash in
            identity.secrets.first { $0.hash == hash }.map { $0.named ? $0.name : ($0.agent ?? $0.name) }
        }
        if UserDefaults.standard.string(forKey: "pokiSample") != nil { loadSample() }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillTerminate() }
        }
        // Installed over the local-VPN build (both use one bundle ID): this build has only external
        // connections, so a saved built-in choice becomes the external one. Otherwise Setup showed the
        // step done while Turn on said this build has no local VPN.
        if setup.loopback == .builtIn, !tunnel.available {
            setup.loopback = .proxy
            setup.save()
            log.add("loopback", "this build has no built-in connection: the saved choice is now an external one")
        }
    }

    /// The in-process session as prepare last answered it in this process (ESP-152).
    private var inProcessSession = InProcessSession.idle
    var developerToolsFailure: LocalizedStringResource? {
        if case .failed("developer_framework_unavailable", _) = inProcessSession {
            return DiskImageStore.loadFailureMessage
        }
        return nil
    }
    /// Automation works through Poki's own session, whether or not the loopback answers (ESP-448).
    var hasOpenInProcessSession: Bool {
        automationPath == .inProcess && sessionOn && inProcessSession == .open
    }
    var preparingPhone: Bool {
        guard automationPath == .inProcess, sessionOn else { return false }
        switch inProcessSession {
        case .opening, .closing(reopen: true), .failed("open_under_way", _), .failed("open_poki_first", _): return true
        default: return false
        }
    }
    /// Poki's own automation session (ESP-152); a fake in tests.
    private let automation: InProcessAutomation
    private var inProcessWarming = false
    private var inProcessOpensInFlight = 0
    /// A failed local open went back to the loopback once since it last answered.
    private var retriedLocalDDIOnLoopback = false
    /// iOS is asking the owner for the passcode to allow automation (in-process): the open under way
    /// has been inside iOS's own "allow automation" call for `passcodeEvidence` seconds. A session
    /// that is merely slow to open or to read is not that (issue 347 showed the passcode prompt for
    /// one). The Live Activity and Poki's home ask the owner, and the agent reads that the owner has
    /// to enter it.
    private var inProcessPasscode = false
    /// When the open under way began: one that has not answered in `staleOpen` seconds no longer
    /// holds the next one back (seen on the phone: the banner up, the session open, and every look
    /// answered "still starting" because an open that never answered blocked all the others).
    private var inProcessWarmStarted = Date.distantPast
    private static let staleOpen: TimeInterval = 15
    private static let passcodeEvidence: TimeInterval = 3
    /// Counts closes, so an open that began before one is not taken as the state after it.
    private var inProcessEpoch = 0
    private var inProcessWarmToken = 0
    /// Standing by kept the session with Automation Mode off: the
    /// next open resumes it instead of making a new one, and a resume that fails is closed and opened again.
    private var sessionKept = false
    private var afterInProcessClose: [@MainActor () -> Void] = []
    private var pendingInProcessClose: String?
    /// A close of the in-process session once iOS has answered it: what it was for, and whether a
    /// session was open. The lifecycle check waits for this, not for the state to say closing.
    struct InProcessClose { let number: Int; let why: String; let closed: Bool; let seconds: Double }
    private(set) var lastInProcessClose: InProcessClose?

    func closeInProcess(_ why: String, keepingSession: Bool = false, then: (@MainActor () -> Void)? = nil) {
        guard automationPath == .inProcess else { return }
        if let then { afterInProcessClose.append(then) }
        if case .closing = inProcessSession {
            if !keepingSession { pendingInProcessClose = why }
            return
        }
        inProcessSession = .closing(reopen: false)
        inProcessEpoch += 1
        inProcessWarming = false
        inProcessOpensInFlight = 0
        retriedLocalDDIOnLoopback = false
        endPasscodeWait(opened: false)
        DispatchQueue.global(qos: .userInitiated).async { [automation] in
            var result = keepingSession ? automation.pauseAutomation() : automation.close()
            let kept = keepingSession && result["paused"] as? Bool == true && result["how"] as? String != "no session"
            if keepingSession, !kept { result = automation.close() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let reopen: Bool
                if case .closing(let requested) = self.inProcessSession { reopen = requested } else { reopen = false }
                self.inProcessSession = .idle
                self.sessionKept = kept
                let pendingClose = self.pendingInProcessClose
                self.pendingInProcessClose = nil
                if kept, let pendingClose {
                    self.closeInProcess(pendingClose)
                    if reopen { self.inProcessSession = .closing(reopen: true) }
                    return
                }
                if keepingSession, !kept { self.log.add("runner", "Automation Mode could not pause for \(why): closing the session instead") }
                self.log.add("runner", kept
                    ? "Automation Mode pause for \(why): \(result["paused"] as? Bool == true ? "paused" : "unavailable")"
                    : "in-process session close for \(why): \(result["closed"] as? Bool == true ? "closed" : "already closed")")
                self.lastInProcessClose = InProcessClose(number: (self.lastInProcessClose?.number ?? 0) + 1, why: why,
                                                         closed: !kept && result["closed"] as? Bool == true,
                                                         seconds: result["seconds"] as? Double ?? 0)
                let callbacks = self.afterInProcessClose
                self.afterInProcessClose.removeAll()
                for callback in callbacks { callback() }
                if reopen, self.sessionOn { self.wakeRunner(asked: "a phone step arrived while closing") }
            }
        }
    }

    /// Mounting developer services does not enable Automation Mode. A probe-driven model already
    /// has the session the probe opened, so it starts no other.
    func prepareForTask() {
        guard automationPath == .inProcess, setup.loopback != .none, !probeDriven else { return }
        if !sessionOn {
            pendingPrepareForTask = true
            startSession()
        }
        guard sessionOn, runnerPaused else { return }
        pendingPrepareForTask = false
        runnerPaused = false
        host.setPaused(false)
        launchRunner()
    }

    func warmInProcess(_ why: String) {
        guard automationPath == .inProcess, sessionOn, runner.isRunning,
              inProcessSession != .idle, inProcessSession != .open else { return }
        if case .closing = inProcessSession { return }
        if InProcessWDA.automationDeclined || passcodeConfirmationPending { return }
        // The first open since the iPhone restarted is what brings up iOS's passcode screen: with
        // Poki in front, the owner is told just before it (Continue opens; elsewhere the Live
        // Activity asks for it once iOS has held its "allow automation" call for `passcodeEvidence` seconds).
        if passcodeExpected, passcodeHeadsUpSeen != BootClock.current, inFront, !Self.onSimulator, !inProcessWarming {
            passcodeHeldOpen = why
            passcodeConfirmationPending = true
            passcodeHeadsUp = true
            log.add("runner", "first automation since this iPhone restarted: requested notice that iOS will ask for the passcode")
            return
        }
        if inProcessWarming {
            guard Date().timeIntervalSince(inProcessWarmStarted) > Self.staleOpen else { return }
            log.add("runner", "the in-process open under way has not answered in \(Int(Self.staleOpen)) s: asking again for \(why)")
        }
        log.add("session-timing", String(format: "session_requested uptime=%.6f", ProcessInfo.processInfo.systemUptime))
        inProcessWarming = true
        inProcessOpensInFlight += 1
        inProcessWarmStarted = Date()
        inProcessWarmToken += 1
        let epoch = inProcessEpoch, token = inProcessWarmToken
        let resuming = sessionKept
        if inProcessSession != .open, inProcessSession != .opening, inProcessSession != .waitingForPasscode {
            inProcessSession = .opening
            host.update(runner: coreState(of: runner))
        }
        DispatchQueue.global(qos: .userInitiated).async { [automation] in
            var result = InProcessWDA.openThroughGate { automation.prepare() }
            var resumeFailure: String?
            if resuming, Self.shouldOpenNewSessionAfterFailedResume(result) {
                resumeFailure = "\(result["code"] ?? "unknown")"
                _ = automation.close()
                result = InProcessWDA.openThroughGate { automation.prepare() }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard epoch == self.inProcessEpoch else {
                    self.log.add("runner", "an in-process open for \(why) answered after the session was closed: not taken")
                    return
                }
                let ok = (result["ok"] as? Bool) == true
                // The latest open's answer is always taken. An older one that answers late is taken
                // only when it is ready and nothing has been concluded since (the newer open is still
                // waiting, or was only told that this one was under way): it never replaces a
                // failure or a cancelled passcode that a newer open found, and its own failure never
                // undoes what a newer one is doing.
                let undecided: Bool
                switch self.inProcessSession {
                case .opening, .waitingForPasscode, .failed("open_under_way", _): undecided = true
                default: undecided = false
                }
                let accepted = token == self.inProcessWarmToken || (ok && undecided)
                if !accepted {
                    self.log.add("runner", "an older in-process open for \(why) answered late (\(ok ? "ready" : "not ready")): not taken")
                }
                self.inProcessOpensInFlight -= 1
                defer {
                    let retrying = self.retryLocalDDIOverLoopbackIfNeeded()
                    if self.sessionOn, accepted || retrying { self.host.update(runner: self.coreState(of: self.runner)) }
                }
                guard accepted else { return }
                if token == self.inProcessWarmToken { self.inProcessWarming = false }
                self.sessionKept = false
                if let resumeFailure {
                    self.log.add("runner", "the kept session could not resume (\(resumeFailure)): it was closed and a new one opened for \(why)")
                }
                let waitedForPasscode = self.inProcessPasscode
                self.endPasscodeWait(opened: ok)
                let seconds = String(format: "%.2f", result["seconds"] as? Double ?? 0)
                let warm = (result["warm_seconds"] as? Double).map { $0 > 0 ? String(format: ", first snapshot and screenshot %.2f s", $0) : "" } ?? ""
                self.log.add("runner", ok ? "in-process session ready for \(why) (generation \(result["generation"] ?? 0), \((result["reused"] as? Bool) == true ? "already open" : "opened"), \(seconds) s\(warm))"
                                          : "in-process session not ready for \(why): \(result["code"] ?? "unknown") after \(seconds) s")
                if ok {
                    self.log.add("session-timing", String(format: "session_ready uptime=%.6f", ProcessInfo.processInfo.systemUptime))
                    self.automationStarted()
                    // An open session proves both, also when the launcher only found the image mounted.
                    if !self.setup.developerMode || !self.setup.uiAutomation {
                        var confirmed = self.setup
                        confirmed.developerMode = true
                        confirmed.uiAutomation = true
                        self.setup = confirmed
                    }
                }
                let detail = result["detail"] as? String ?? ""
                // iOS gives up on the passcode after a minute and says only that enabling timed out.
                // A session that was allowed and then could not read is not a missed passcode.
                let unreadable = "\(result["code"] ?? "")" == "session_unreadable"
                let passcodeMissed = !unreadable && (waitedForPasscode || detail.localizedCaseInsensitiveContains("enabling automation mode"))
                // Cancelled (or left) iOS's passcode screen: Poki does not open it again by itself.
                if !ok, passcodeMissed {
                    InProcessWDA.gate.withLock { $0.declined = true }
                    self.log.add("runner", "the passcode for automation was not entered: Poki will not ask again until it is turned on again")
                }
                self.inProcessSession = ok ? .open : passcodeMissed ? .passcodeMissed : .failed(code: "\(result["code"] ?? "unknown")", detail: detail)
            }
        }
    }

    /// A kept session that does not come back is replaced. Not when the open was refused before it began, nor
    /// when the owner let iOS's passcode screen time out: that is the owner's answer, and a new session
    /// would put the same screen up again.
    private static func shouldOpenNewSessionAfterFailedResume(_ result: [String: Any]) -> Bool {
        guard result["ok"] as? Bool != true else { return false }
        if ["passcode_declined", "open_poki_first", "open_under_way"].contains("\(result["code"] ?? "")") { return false }
        return !("\(result["detail"] ?? "")".localizedCaseInsensitiveContains("enabling automation mode"))
    }

    /// A local open failed after the launcher found only the mounted image: once the loopback answers,
    /// the launcher goes the normal way, once until the loopback drops and comes back.
    private func retryLocalDDIOverLoopbackIfNeeded() -> Bool {
        guard automationPath == .inProcess, sessionOn, !runnerPaused, runner.isRunning, runner.code == "local_ddi",
              loopback.isWorking, inProcessOpensInFlight == 0, !retriedLocalDDIOnLoopback,
              !InProcessWDA.automationDeclined, case .failed(let code, _) = inProcessSession,
              code != "open_poki_first", code != "open_under_way" else { return false }
        retriedLocalDDIOnLoopback = true
        // No agent wakes the old local state before the launcher reports again.
        runner = RunnerStatus(state: "connecting")
        inProcessSession = .opening
        log.add("runner", "the local automation session did not open; trying again over the loopback")
        launcher.restart()
        return true
    }

    /// iOS has held its "allow automation" call for a few seconds: it is asking for the passcode before
    /// it allows automation (after Poki restarts, and 8 hours after the last time). Asked as the
    /// runner path's launcher asks.
    private func beginPasscodeWait(waited: Double) {
        inProcessPasscode = true
        passcodeHint = true
        log.add("runner", String(format: "iOS has been asked to allow automation for %.1f s: asking the owner for the passcode on the Live Activity", waited))
        inProcessSession = .waitingForPasscode
        host.update(runner: coreState(of: runner))
        activity.update { $0.phase = .handoff; $0.handoff = .init(id: Self.runnerPasscodeHandoff, kind: .automationPasscode, text: nil, app: nil, since: Date()) }
    }

    private func endPasscodeWait(opened: Bool) {
        guard inProcessPasscode else { return }
        inProcessPasscode = false
        passcodeHint = false
        log.add("runner", opened ? "iOS allowed automation after asking the owner: the in-process session is open" : "the in-process session did not open while iOS asked for the passcode")
        if activity.state.handoff?.id == Self.runnerPasscodeHandoff {
            activity.update { $0.handoff = nil; $0.phase = .idle; if opened { $0.headline = "Ready for the agent" } }
        }
    }

    /// Poki came to the front: turn on again if it was on, check the loopback live, and finish a
    /// setup step the person just did in Settings.
    func becameActive() {
        inFront = true
        guard signer.installFinish == .idle else { return }
        InProcessWDA.gate.withLock { $0.inFront = true }
        cameToFront = Date()
        // A pairing file and disk image Poki Setup put in the container while Poki was running (or
        // since it last came to the front) count at once: mirrored to the Keychain, the disk image
        // checked again, and the pairing checked as soon as the loopback answers.
        SetupVault.mirrorPairingFromContainer()
        lookForHandedPairing()
        handoffTick()
        diskImage.notice()
        warmInProcess("Poki came to the front")
        openWhileInFront("Poki came to the front")
        closeBecausePokiOpened()
        loopback.resume()
        // Swiped away, ended by iOS, or Poki turned on from the background (where iOS starts none):
        // the Live Activity comes back while Poki is on, so the next thing that needs the owner pops up.
        if sessionOn, !activity.isRunning {
            activity.start(deviceName: deviceName)
            if activity.isRunning { log.add("activity", "Live Activity started again (Poki came to the front)") }
        }
        // Poki in front while an agent's step is under way: nobody opened it on purpose. A tap near the
        // top of the screen hit the expanded Dynamic Island (iOS opens the activity's app), or the agent
        // tapped the activity's own label in the tree. Logged so the phone log shows it; PokiCore sends
        // the agent back to the app it was in.
        if sessionOn, let step = stepUnderWay, Date().timeIntervalSince(step.started) < 20 {
            log.add("app", "Poki came to the front during a step (\(step.summary)): a tap hit the Live Activity")
        }
        turnOnIfWanted()
        if let step = guiding, isDone(step) { stopGuide() }
    }

    /// Turns on when Poki was on (or Poki Setup just installed it) and the pairing and disk image are there.
    private func turnOnIfWanted() {
        Task {
            await tunnel.refresh()
            await diskImage.ensureChecked()
            if wantsOn, !sessionOn, pairingPath != nil, diskImage.hasFiles { startSession(reconnectLocal: false) }
        }
    }

    // MARK: Hand-off with the installer on the Mac (PokiHandoff)

    /// Takes a model key the installer sealed to this phone, then tells the installer how Poki is.
    /// A key that just came may be what Poki needed to turn on.
    func handoffTick() {
        if let what = PokiHandoff.takeSealedKey() {
            log.add("setup", what)
            turnOnIfWanted()
        }
        PokiHandoff.writeHello(loopbackWorking: loopback.isWorking, loopbackSay: loopback.isWorking ? nil : loopbackSentence)
    }

    /// The one thing to do for the local connection, for the person, as the installer says it.
    var loopbackSentence: String {
        if tunnel.available { return "In Poki, open Setup > Connect to this iPhone and turn on Poki's own connection." }
        guard let app = ProxyApps.all.first(where: \.isInstalled) else {
            return "Install the free LocalDevVPN from the App Store and tap Connect in it. Another VPN app that can reach 10.7.0.1 also works, such as Karing, Surge, Loon or Shadowrocket: in Poki, open Setup > Connect to this iPhone and follow the line for it."
        }
        switch app.install {
        case .url: return "In Poki, open Setup > Connect to this iPhone > \(app.name), tap Install, then confirm in \(app.name)."
        case .toggle(let setting): return "In \(app.name), set \(setting), and keep \(app.name) connected."
        case .snippet: return "In Poki, open Setup > Connect to this iPhone > \(app.name) and add the lines it shows to \(app.name)."
        }
    }

    /// In the background the loopback is still watched while Poki is on (the agent's runner depends on
    /// it): every 6 s, light enough for the location-kept background time.
    func wentToBackground() {
        inFront = false
        InProcessWDA.gate.withLock { $0.inFront = false }
        // The idle time counts from here: Poki in front was not idle (it stands by only away from it).
        if sessionOn { lastAgentActivity = max(lastAgentActivity, Date()) }
        sessionOn ? loopback.resume(every: 6) : loopback.pause()
        if pairingUnderWay { log.add("pairing", "Poki in the background while pairing; keep-alive \(pairingKeepAlive.isOn ? "playing" : "off")") }
    }
    private var inFront = true
    private var cameToFront = Date()

    /// Poki is being closed: end the runner now (the launcher kills its process) instead of leaving
    /// iOS's automation banner up for half a minute. iOS gives a few seconds for this.
    private func appWillTerminate() {
        // The Live Activity goes with the app; the pause below gives its end time to reach iOS.
        ActivityController.endAll()
        guard sessionOn else { Thread.sleep(forTimeInterval: 0.5); return }
        log.add("app", "Poki is closing: ending the runner")
        if automationPath == .inProcess { _ = automation.close() }
        launcher.stop()
        Thread.sleep(forTimeInterval: 2.5)
    }

    var deviceName: String { UIDevice.current.name }

    /// `-pokiSample B` (YES is B), `C` or `PIN`: the home screen states of ESP-139 board 01 with sample
    /// steps and an approval, only for the build's screenshots. Nothing is started: B and D look like a
    /// session at work, C like one standing by (the loopback check stays live, so a simulator shows it
    /// off). A sample relay address (not saved) and, on a simulator, two agents are added when there are none.
    private func loadSample() {
        let scene = UserDefaults.standard.string(forKey: "pokiSample")?.uppercased() ?? "B"
        // PIN: setup's pairing page with a sample code, as if Settings had asked for one.
        if scene == "PIN" { pairing = .pin("482913"); return }
        let now = Date()
        let messages = AppLocalization.text(LocalizedStringResource("Messages"))
        // The sample relay is not saved. Sample agents go into the keychain, so only a simulator gets them.
        if relayAddress == nil { relayAddress = RelayAddress("https://your-relay.example") }
        #if targetEnvironment(simulator)
        if identity.secrets.isEmpty {
            _ = addConnector(name: "")
            _ = addConnector(name: "")
        }
        #endif
        Thumbnail.previewImage = ActivityPreview.sampleScreen()
        AppIconFile.preview = { AppIconStore.shared.icon($0) }
        sessionOn = true
        relayStatus = .ready
        currentApp = messages
        if scene == "C" {
            runnerPaused = true
            runner = RunnerStatus(state: "standby", detail: "It starts when an agent asks.")
            recentSteps = (0..<12).map { i in
                RecentStep(text: AppLocalization.text(LocalizedStringResource("Tap “Send”")), app: messages, at: now.addingTimeInterval(Double(i - 11) * 84 / 11 - 300))
            }
            return
        }
        runner = RunnerStatus(state: "running")
        recentSteps = [
            RecentStep(text: AppLocalization.text(LocalizedStringResource("Open Messages")), app: AppLocalization.text(LocalizedStringResource("Home Screen")), at: now.addingTimeInterval(-70)),
            RecentStep(text: AppLocalization.text(LocalizedStringResource("Tap the chat with Mom")), app: messages, at: now.addingTimeInterval(-52)),
            RecentStep(text: AppLocalization.text(LocalizedStringResource("Type “On my way”")), app: messages, at: now.addingTimeInterval(-41)),
            RecentStep(text: "Tap at 212, 640", app: messages, failure: "failed: nothing changed", at: now.addingTimeInterval(-30)),
        ]
        activityText = AppLocalization.text(LocalizedStringResource("Tap “Send”"))
        approvals = [PendingApproval(id: "sample", app: messages, summary: AppLocalization.text(LocalizedStringResource("Send “On my way” to Mom")),
                                     reason: "sending a message (\"send\")", expires: now.addingTimeInterval(25))]
    }

    // MARK: Session

    func chooseConnection(_ method: SetupState.Loopback) {
        guard !connectionInUse, !tunnel.busy else { return }
        if method == .proxy { tunnel.disconnect() }
        setup.loopback = method
        setup.proxyApp = nil
        loopback.check()
    }

    /// A sign-in from a client outside the relay's known list, waiting for the owner (an alert in the
    /// app and a notification). The relay gives up after 90 s, and so does this.
    struct ConnectionAsk: Identifiable {
        let id = UUID()
        let client: String
        let callback: String
        let connector: String
    }
    private(set) var connectionAsk: ConnectionAsk?
    private var connectionAnswer: CheckedContinuation<Bool, Never>?

    func askToConnect(client: String, callback: String, connector: String) async -> Bool {
        answerConnection(false) // one at a time: an older ask is declined
        let name = identity.secrets.first { $0.hash == connector }?.name ?? AppLocalization.text(LocalizedStringResource("a connector"))
        let ask = ConnectionAsk(client: client, callback: callback, connector: name)
        log.add("relay", "\(client) at \(callback) asks to sign in through \(name): waiting for the owner")
        ConnectionNotice.post(ask)
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            connectionAsk = ask
            connectionAnswer = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(88))
                if self?.connectionAsk?.id == ask.id { self?.answerConnection(false) }
            }
        }
        log.add("relay", ok ? "the owner allowed \(client) at \(callback)" : "\(client) at \(callback) was not allowed")
        return ok
    }

    func answerConnection(_ ok: Bool) {
        guard let answer = connectionAnswer else { return }
        connectionAnswer = nil
        if let ask = connectionAsk { ConnectionNotice.clear(ask) }
        connectionAsk = nil
        answer.resume(returning: ok)
    }

    private var pairingCheck: Task<Bool, Never>?

    /// Asks the phone's own services, over the loopback, whether they still take this pairing file:
    /// the same handshake the runner makes, a second or two, so a refused pairing shows on Setup and
    /// the home page before an agent or a chat needs the phone. true when it was accepted (or could
    /// not be checked now: the loopback is down, or the simulator).
    /// A lockdown pairing record (from a computer: HostID, certificates), not an RPPairing file.
    static func isLockdownRecord(_ path: String) -> Bool {
        pairingRecord(at: path)?["HostID"] != nil
    }

    private static func pairingRecord(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The way to the phone's developer services when a check or the runner fails, for the log:
    /// whether Wi-Fi is up and which loopback carries it.
    private var networkNote: String {
        "loopback \(setup.loopback.rawValue), local VPN \(tunnel.state), Wi-Fi \(loopback.onWiFi ? "on" : "off")\(loopback.cellularOnly ? ", cellular only" : ""), path \(loopback.pathSummary)"
    }

    @discardableResult
    func verifyPairing(force: Bool = false) async -> Bool {
        if Self.onSimulator {
            if loopback.isWorking { servicesSilent = false }
            return true
        }
        guard let path = pairingPath, loopback.isWorking else { return true }
        if !force, pairingTrouble == nil, !servicesSilent, let at = pairingVerifiedAt, Date().timeIntervalSince(at) < 600 { return true }
        if let pairingCheck { return await pairingCheck.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return true }
            defer { self.pairingCheck = nil }
            do {
                _ = try await SignerBridge.call(["op": "udid", "device_address": "10.7.0.1", "pairing_file": path, "host_name": "Poki"])
                if self.pairingTrouble != nil { self.log.add("pairing", "check: accepted again") }
                self.pairingTrouble = nil
                self.servicesSilent = false
                self.pairingVerifiedAt = Date()
                return true
            } catch {
                let text = error.localizedDescription
                let code = (error as? SignerError)?.code
                if code == "pairing" {
                    if self.pairingTrouble == nil { self.log.add("pairing", "check: refused: \(text)") }
                    self.pairingTrouble = text.replacingOccurrences(of: " Pair again in Poki's setup.", with: "")
                    return false
                }
                // iOS 27 and later take only a pairing made on the phone over the loopback: a lockdown
                // record from a computer (Poki Setup) fails its TLS session here every time.
                if SetupStep.onDevicePairing, text.contains("device socket io failed"), Self.isLockdownRecord(path) {
                    if self.pairingTrouble == nil { self.log.add("pairing", "check: the computer's pairing file does not open the loopback on this iOS; pair on this iPhone") }
                    self.pairingTrouble = AppLocalization.text(LocalizedStringResource("the pairing file from a computer does not work over the loopback on this iOS version. Pair this iPhone here once; the pairing stays."))
                    return false
                }
                self.log.add("pairing", "check could not finish: \(text) [\(self.networkNote)]")
                if code == "handshake" { self.servicesSilent = true }
                return true
            }
        }
        pairingCheck = task
        return await task.value
    }

    func startSession(reconnectLocal: Bool = true) {
        guard !passcodeConfirmationPending, !sessionOn, !sessionStarting else { return }
        diskImage.refreshAvailability()
        // Turning on is the owner asking for automation again, after a cancelled passcode screen too.
        InProcessWDA.gate.withLock { $0.declined = false }
        // The first automation after a restart (or ever) brings up iOS's own passcode screen. With
        // Poki in front, the owner is told first that it is expected and that Poki cannot see it.
        // Start asks for everything at once: the note now, and on Continue the session's first open
        // (warmInProcess, as soon as the launcher is ready), which brings up iOS's passcode screen.
        if automationPath == .runner, passcodeExpected, passcodeHeadsUpSeen != BootClock.current, inFront, !Self.onSimulator {
            passcodeHeadsUpReconnect = reconnectLocal
            passcodeConfirmationPending = true
            passcodeHeadsUp = true
            log.add("runner", "no automation since this iPhone restarted: requested notice that iOS will ask for the passcode")
            return
        }
        if setup.loopback == .none {
            problem = "Choose and enable a local connection first (Setup)."
            return
        }
        if setup.loopback == .builtIn, !tunnel.connected {
            guard reconnectLocal else {
                problem = "The local connection is off. Turn Poki on to reconnect, or choose an external connection in Setup."
                return
            }
            sessionStarting = true
            sessionStartTask = Task {
                defer { sessionStarting = false; sessionStartTask = nil }
                do {
                    try await tunnel.connect()
                    try Task.checkCancellation()
                    loopback.check()
                    if !(await verifyPairing()) {
                        problem = "The phone refused the pairing (\(pairingTrouble ?? "")). Pair again in Setup."
                        return
                    }
                    guard await ensureDiskImageForSession(), !Task.isCancelled else { return }
                    beginSession()
                } catch is CancellationError { }
                catch { problem = error.localizedDescription }
            }
        } else if loopback.isWorking, !Self.onSimulator, pairingPath != nil {
            // Check the pairing first, so a refused one stops here with its fix instead of failing
            // under the first agent's call.
            sessionStarting = true
            sessionStartTask = Task {
                defer { sessionStarting = false; sessionStartTask = nil }
                guard await verifyPairing(), !Task.isCancelled else {
                    if let pairingTrouble { problem = "The phone refused the pairing (\(pairingTrouble)). Pair again in Setup." }
                    return
                }
                guard await ensureDiskImageForSession(), !Task.isCancelled else { return }
                beginSession()
            }
        } else if requiresDiskImageCheck {
            guard checkSessionStartPreconditions() != nil else { return }
            sessionStarting = true
            sessionStartTask = Task {
                defer { sessionStarting = false; sessionStartTask = nil }
                guard await ensureDiskImageForSession(), !Task.isCancelled else { return }
                beginSession()
            }
        } else { beginSession() }
    }

    private func checkSessionStartPreconditions() -> (pairing: String, relay: RelayAddress?)? {
        guard !sessionOn else { return nil }
        problem = nil
        #if targetEnvironment(simulator)
        // A simulator has no pairing, disk image or launcher: the runner is WebDriverAgent started on
        // the Mac (see `launchRunner`).
        let pairing = pairingPath ?? ""
        #else
        guard let pairing = pairingPath else { problem = "Pair this iPhone first (Setup)."; return nil }
        #endif
        // The chat's own model loop needs no relay; agents on a computer do.
        let relay = activeRelay
        guard relay != nil || ModelKeys.hasUsableKey else { problem = Self.noRelay; return nil }
        return (pairing, relay)
    }

    private func ensureDiskImageForSession() async -> Bool {
        if !requiresDiskImageCheck { return true }
        let verified: Bool
        if diskImage.isChecking || !diskImage.hasFiles {
            await diskImage.ensureChecked()
            verified = diskImage.hasFiles
        } else {
            verified = await diskImage.recheckInBackground()
        }
        guard !Task.isCancelled else { return false }
        if !verified {
            problem = "The developer disk image is not downloaded yet (Setup > Pair). It is needed once."
            Task { await diskImage.download() }
            return false
        }
        return true
    }

    private func beginSession() {
        guard let (pairing, relay) = checkSessionStartPreconditions() else { return }
        if !inFront { loopback.resume(every: 6) }
        log.add("session", "turned on")
        background.start()
        ApprovalNotice.requestPermission()
        stopGuide()
        activity.start(deviceName: deviceName)
        log.add("activity", activity.isRunning ? "Live Activity started" : "Live Activity not running: \(activity.lastError ?? "unknown reason")")
        sessionOn = true
        wantsOn = true
        launcherConfig = LauncherConfig(pairing_file: pairing, ddi_dir: AppFiles.ddiDirectory.path, in_process: automationPath == .inProcess, ddi_marker: Self.ddiMarker)
        lastAgentActivity = Date()
        // Away from Poki the runner (and with it iOS's automation banner) starts only when an agent asks.
        standBy(reason: nil)
        if pendingPrepareForTask, automationPath == .inProcess, runnerPaused, !probeDriven {
            pendingPrepareForTask = false
            runnerPaused = false
            host.setPaused(false)
            launchRunner()
        }
        if let relay { core.start(relay: relay) }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkIdle() } }
        openWhileInFront("turned on with Poki in front")
    }

    /// The separate Runner path keeps its existing foreground startup behavior.
    private func openWhileInFront(_ why: String) {
        guard automationPath == .runner, sessionOn, runnerPaused, !ownerPaused, inFront, UIApplication.shared.applicationState == .active, !Self.onSimulator,
              !InProcessWDA.automationDeclined else { return }
        wakeRunner(asked: why)
    }

    /// Turned on again after a session of this launch was closed: Poki starts over as a new process
    /// (the only way to a session that reads the screen) and comes back on by itself. A notice reopens
    /// it; `wantsOn` turns it on when it does.
    /// Off by hand, in-process: Poki leaves for the Home Screen and exits, so the next turn-on is a
    /// fresh launch whose session can read the screen; the notice brings the owner back.
    private func exitAfterStop() {
        guard !Self.onSimulator, !sessionOn, !exitingAfterStop else { return }
        exitingAfterStop = true
        log.add("session", "turned off: Poki exits, and opening it again starts the next task")
        let content = UNMutableNotificationContent()
        content.title = AppLocalization.text(LocalizedStringResource("Open Poki Again to Start Another Task"))
        content.body = AppLocalization.text(LocalizedStringResource("Poki closed after you stopped it. Open it to turn it on again."))
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["poki_link": "poki://chat"]
        content.sound = .default
        // Shown at once (the delegate shows banners while Poki is open too); Poki leaves only after
        // iOS has taken the notification, so an exit cannot drop it.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nz.zheha.poki.stopped", content: content, trigger: nil)) { error in
            Task { @MainActor [weak self] in
                self?.log.add("session", error.map { "the reopen notice was not posted: \($0.localizedDescription)" } ?? "reopen notice posted")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    UIApplication.shared.perform(NSSelectorFromString("suspend"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
                }
            }
        }
    }
    private var exitingAfterStop = false

    /// The note before Poki exits to turn on again (Continue exits).
    var relaunchNotice = false
    func continueRelaunch() {
        relaunchNotice = false
        relaunchForFreshSession()
    }

    private func relaunchForFreshSession() {
        log.add("session", "turning on after the automation session was closed: Poki restarts so agents can see the screen")
        wantsOn = true
        let content = UNMutableNotificationContent()
        content.title = AppLocalization.text(LocalizedStringResource("Tap to Open Poki"))
        content.body = AppLocalization.text(LocalizedStringResource("Poki restarted so agents can see the screen again. It turns on when it opens."))
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["poki_link": "poki://chat"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nz.zheha.poki.relaunch", content: content,
                                                                      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            UIApplication.shared.perform(NSSelectorFromString("suspend"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exit(0) }
        }
    }

    /// The update is accepted by iOS. Keep the loopback and wantsOn for the replacement app.
    func windDownForUpdate() async {
        sessionStartTask?.cancel()
        pendingPrepareForTask = false
        idleTimer?.invalidate(); idleTimer = nil
        sessionOn = false
        background.stop()
        voice.stop()
        pairer.cancel()
        pairingKeepAlive.stop()
        background.releasePairing()
        if automationPath == .inProcess {
            await withCheckedContinuation { continuation in
                closeInProcess("the update") { continuation.resume() }
            }
        } else if !Self.onSimulator {
            await RunnerProbe.shutdown()
        }
        core.stop()
        launcher.stop()
        await activity.end(dismissalPolicy: .immediate)?.value
        AttentionNotice.clear()
        log.add("signing", "update runtime stopped")
    }

    func stopSession() {
        sessionStartTask?.cancel()
        pendingPrepareForTask = false
        wantsOn = false
        if AskPoki.app === self, let chat = AskPoki.chat, chat.isRunningInSplitView { chat.stop() }
        guard sessionOn else {
            if setup.loopback == .builtIn { tunnel.disconnect() }
            return
        }
        if !inFront { loopback.pause() }
        log.add("session", automationPath == .inProcess ? "turned off: closing the in-process session" : "turned off: ending the runner")
        // The session closes and Poki stays: the next turn-on opens a new one in this same launch.
        if automationPath == .inProcess { closeInProcess("turned off") }
        core.stop()
        launcher.stop()
        if setup.loopback == .builtIn { tunnel.disconnect() }
        if automationPath == .runner {
            if !Self.onSimulator { Task { await RunnerProbe.shutdown() } }
            confirmRunnerEnded()
        }
        idleTimer?.invalidate(); idleTimer = nil
        runnerPaused = false; host.setPaused(false)
        ownerPaused = false
        background.stop()
        activity.end()
        sessionOn = false
        chatTaskActive = false
        stepUnderWay = nil
        runner = .idle
        relayStatus = .off
        activityText = "Idle"
    }

    func restartRunner() { launcher.restart() }

    #if targetEnvironment(simulator)
    static let onSimulator = true
    #else
    static let onSimulator = false
    #endif

    private func launchRunner() {
        #if targetEnvironment(simulator)
        // On a simulator, WebDriverAgent runs from Xcode on the Mac (`xcodebuild test` of
        // WebDriverAgentRunner, as in .github/workflows/ios-core.yml) and answers on 127.0.0.1:8100.
        Task { [weak self] in
            let up = await RunnerProbe.answers()
            self?.runnerChanged(up ? RunnerStatus(state: "running") :
                RunnerStatus(state: "failed", detail: "WebDriverAgent is not answering on 127.0.0.1:8100", fix: "Start WebDriverAgentRunner on this simulator from Xcode"))
        }
        return
        #else
        guard let launcherConfig else { return }
        do {
            try launcher.start(config: launcherConfig) { [weak self] status in Task { @MainActor in self?.runnerChanged(status) } }
        } catch { runnerChanged(RunnerStatus(state: "failed", detail: "\(error)")) }
        #endif
    }

    /// Stops the runner, and with it iOS's automation banner, while the relay stays connected; the
    /// next agent request starts it again. From the Stop runner button, the Live Activity, or idle.
    func pauseRunner(reason: String = "Stopped", byOwner: Bool = true) {
        let splitChat = byOwner && AskPoki.app === self && AskPoki.chat?.isRunningInSplitView == true ? AskPoki.chat : nil
        splitChat?.stop()
        guard sessionOn, !runnerPaused || byOwner else { return }
        // Allow on the Live Activity is followed by its layout changing under the finger: a Stop
        // that lands within a few seconds of an answered approval is that same tap (build 144: an
        // Allow, then "Stopped from the Live Activity" 0.7 s after the approval ended). A running
        // Split View task still needs an immediate Stop, including during and just after approval.
        if splitChat == nil, reason == "Stopped from the Live Activity", let answered = lastApprovalAnswered, Date().timeIntervalSince(answered) < 4 {
            log.add("runner", "a Stop from the Live Activity right after an approval was ignored")
            return
        }
        guard approvals.isEmpty || splitChat != nil else { return }
        ownerPaused = byOwner
        if runnerPaused {
            if automationPath == .inProcess { closeInProcess("stopped by the owner") }
            return
        }
        if automationPath == .inProcess {
            Task { [core] in _ = await core.finishTask(switching: false) }
            // The owner's own Stop ends the session; standing by on its own keeps it where the policy says so.
            closeInProcess("standing by", keepingSession: !byOwner && idleSessionPolicy == .pauseAutomation)
            standBy(reason: reason)
            return
        }
        log.add("runner", "stopping: \(reason)")
        // The task ends with the runner; a client ending its session later sends nothing to it.
        Task { [core] in _ = await core.finishTask(switching: false) }
        // The runner is asked to shut itself down (it ends its test and exits) and the launcher's
        // session is closed; the launcher also ends the process through the developer services.
        if !Self.onSimulator { Task { await RunnerProbe.shutdown() } }
        launcher.stop()
        standBy(reason: reason)
        confirmRunnerEnded()
    }

    /// After a stop, watches the runner until it really ends (and with it the automation banner):
    /// once a second for 30 s. The log says how long it took. If it is still there after 10 s, the
    /// home screen says so, and the notice goes away by itself the moment the runner is gone.
    func confirmRunnerEnded() {
        // A simulator's runner belongs to Xcode on the Mac and stays up.
        guard !Self.onSimulator else { return }
        endCheck += 1
        let check = endCheck
        Task { [weak self] in
            for second in 1...30 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.endCheck == check else { return }
                // An agent asked for the runner again in the meantime: nothing to watch.
                if self.sessionOn, !self.runnerPaused { self.clearStuckNotice(); return }
                if !(await RunnerProbe.answers()) {
                    self.log.add("runner", "ended \(second) s after Stop")
                    self.clearStuckNotice()
                    return
                }
                // Still up: the shutdown may have queued behind a long read in the runner, or the
                // developer connection the launcher kills through was gone. Ask again.
                if second == 4 || second == 12 || second == 20 {
                    self.log.add("runner", "still answering \(second) s after Stop: asking again")
                    await RunnerProbe.shutdown()
                    self.launcher.stop()
                }
                if second == 10 {
                    self.log.add("runner", "still answering 10 s after Stop")
                    self.problem = Self.stuckNotice
                }
            }
            guard let self, self.endCheck == check else { return }
            self.log.add("runner", "still answering 30 s after Stop")
        }
    }

    private static let stuckNotice = "Poki Runner is still running after Stop. Swipe it away in the app switcher; the banner goes with it."
    private func clearStuckNotice() { if problem == Self.stuckNotice { problem = nil } }

    func pauseByOwner() {
        guard sessionOn else { return }
        if runnerPaused {
            ownerPaused = true
            if automationPath == .inProcess { closeInProcess("stopped by the owner") }
        } else { pauseRunner() }
    }

    /// The runner is off and starts on the next agent request.
    private func standBy(reason: String?, keepingDone: Bool = false) {
        runnerPaused = true
        runner = RunnerStatus(state: "standby", detail: reason.map { "\($0). It starts again when an agent asks." } ?? "It starts when an agent asks.")
        host.update(runner: .starting(automationPath == .inProcess ? "opening the automation session" : "starting the runner"))
        host.setPaused(true)
        activityText = "Idle"
        activity.update { state in
            state.runnerPaused = true
            // A task that just ended keeps its finished Live Activity, and one waiting on the owner
            // keeps what it asks.
            if keepingDone, state.phase == .done || state.handoff != nil || state.approval != nil { return }
            state.phase = .idle; state.headline = "Runner asleep"; state.since = nil
        }
    }

    /// A task ended (the chat's turn, or an agent ended its session): the automation session, and
    /// with it iOS's banner, closes at once rather than after the idle time. The next phone step
    /// opens a new one. Not while another task, an approval or a hand-off still needs the session.
    /// Poki opened in front of the owner while a session is open (the task came back to ask them
    /// something, it ended here, or they opened Poki themselves): automation stops at once, as nothing
    /// is done in Poki. Not during a step (a tap that landed on the Live Activity brings Poki forward,
    /// and the core takes the agent back), nor while a session is still opening (iOS's own passcode
    /// screen hands the front back to Poki). The next phone step opens a new session.
    /// Task endings whose return to the app the task began in is still under way: that return needs
    /// the session, so Poki coming forward because of it does not close the session under it.
    private var endingTasks = 0

    private func closeBecausePokiOpened() {
        guard automationPath == .inProcess, sessionOn, !runnerPaused, inProcessSession == .open, !inProcessWarming,
              stepUnderWay == nil, approvals.isEmpty, !probeDriven, endingTasks == 0 else { return }
        log.add("runner", "Poki is in front: closing the automation session at once; the banner goes with it")
        closeInProcess("Poki in front", keepingSession: idleSessionPolicy == .pauseAutomation)
        standBy(reason: nil, keepingDone: true)
    }

    /// The outside agents whose steps ran on this iPhone since the owner was last told, by MCP
    /// session id (the id the core's events carry, whichever saved conversation shows the steps).
    private var outsideAgentsAtWork: [String: String] = [:]

    /// An outside agent's task is over (it ended its session, or went quiet for the idle time): the
    /// owner is told that it used the iPhone, in a notification that breaks through, wherever they
    /// are. Who, and nothing of what it did: that is in Poki.
    private func tellOwnerAgentsWereHere() {
        let agents = Set(outsideAgentsAtWork.values).sorted()
        outsideAgentsAtWork.removeAll()
        for agent in agents { tellOwner(agentWasHere: agent) }
    }

    private func tellOwner(agentWasHere agent: String) {
        log.add("notice", "telling the owner that \(agent) used the iPhone")
        let content = UNMutableNotificationContent()
        content.title = "Poki"
        content.body = AppLocalization.text(LocalizedStringResource("\(agent) used this iPhone through Poki. Open Poki to see what it did."))
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["poki_link": "poki://chat"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "poki-agent-done-\(agent)", content: content, trigger: nil))
    }

    /// The agent handed a screen to the owner: while it is the owner's turn nothing is automated, so
    /// the session and the banner go once the step that handed over is through. The agent's next
    /// look or step opens a new one.
    private func closeForHandoff() {
        guard automationPath == .inProcess, sessionOn, !runnerPaused, inProcessSession == .open, approvals.isEmpty, !probeDriven else { return }
        log.add("runner", "the owner's turn: closing the automation session; the banner goes with it")
        closeInProcess("the owner's turn", keepingSession: idleSessionPolicy == .pauseAutomation)
        standBy(reason: nil, keepingDone: true)
    }

    private func closeAfterTask(_ why: String) {
        guard automationPath == .inProcess, sessionOn, !runnerPaused, !chatTaskActive, approvals.isEmpty,
              handoffText == nil, activityText == "Idle" else { return }
        log.add("runner", "\(why): closing the automation session at once; the banner goes with it")
        ownerPaused = false
        closeInProcess("the end of the task", keepingSession: idleSessionPolicy == .pauseAutomation)
        standBy(reason: nil, keepingDone: true)
    }

    /// Starts a paused runner again (the next agent request, or the owner).
    func wakeRunner(asked: String = "an agent asked") {
        ownerPaused = false
        guard sessionOn else { return }
        if automationPath == .inProcess {
            if case .closing = inProcessSession {
                inProcessSession = .closing(reopen: true)
                return
            }
            if inProcessSession == .idle { inProcessSession = .opening }
            if !runnerPaused { warmInProcess(asked); return }
        }
        guard sessionOn, runnerPaused else { return }
        runnerPaused = false
        host.setPaused(false)
        lastAgentActivity = Date()
        log.add("runner", automationPath == .inProcess ? "\(asked): opening the automation session again" : "\(asked): starting the runner")
        activity.update { $0.runnerPaused = false; $0.phase = .working; $0.headline = "Starting the runner"; $0.since = Date() }
        if automationPath == .inProcess, runner.isRunning { warmInProcess(asked); return }
        launchRunner()
    }

    func checkIdle(now: Date = Date()) {
        if automationPath == .inProcess, inProcessWarming, !inProcessPasscode {
            let waited = automation.authorizationWaitSeconds()
            if waited > Self.passcodeEvidence { beginPasscodeWait(waited: waited) }
        }
        passcodeHint = inProcessPasscode || runner.state == "launching" && launchingSince.map { now.timeIntervalSince($0) > 10 } == true
        guard canStandByWhenIdle, now.timeIntervalSince(lastAgentActivity) >= Double(idleStopSeconds) else { return }
        let activityAtIdle = lastAgentActivity
        let reason = "Stopped after \(idleStopSeconds / 60 > 0 ? "\(idleStopSeconds / 60) min" : "\(idleStopSeconds) s") without agent activity"
        Task { [weak self, core] in
            guard let self, self.canStandByWhenIdle, self.lastAgentActivity == activityAtIdle else { return }
            // Returning to Poki activates its scene before the runner answers the activation.
            // Keep that foreground callback from closing the session underneath the return.
            self.endingTasks += 1
            let line = await core.finishTask(ifNoLocalWorkspace: true)
            self.endingTasks -= 1
            if let line { self.log.add("runner", line) }
            guard self.canStandByWhenIdle, self.lastAgentActivity == activityAtIdle else { return }
            self.pauseRunner(reason: reason, byOwner: false)
            self.tellOwnerAgentsWereHere()
        }
    }

    /// The in-process session stands by when idle with Poki in front too: it opens again on the next
    /// phone step. Never during the chat's task, or while Split View work is under way.
    private var canStandByWhenIdle: Bool {
        sessionOn && !runnerPaused && (automationPath == .inProcess || !inFront) && idleStopSeconds > 0 && approvals.isEmpty
            && activityText == "Idle" && !chatTaskActive && endingTasks == 0
            && !(AskPoki.app === self && AskPoki.chat?.isRunningInSplitView == true)
    }

    /// iOS had moved the remote pairing service off the port Poki used, and Poki found it. The page
    /// may have said Working all along (lockdown answered), so no change of state starts things
    /// again: the launcher tries at once, and the pairing is checked on the port that answers.
    func pairingPortFound(_ port: UInt16) {
        let starts = sessionOn && !runner.isRunning && !runnerPaused
        log.add("loopback", "using remote pairing port \(port) from now on" + (starts ? "; starting the runner now" : ""))
        if starts { launcher.restart() }
        Task { await verifyPairing(force: true) }
        signer.maintain()
    }

    /// The looks for a moved remote pairing port ended without one, or the network changed: a refused
    /// connection is handled as before again (on a mounted disk image, Poki's own session), so the
    /// launcher tries at once instead of waiting out its backoff.
    func pairingPortSearchEnded() {
        let starts = sessionOn && !runner.isRunning && !runnerPaused
        log.add("loopback", "stopped looking for a moved remote pairing port" + (starts ? "; starting the runner now" : ""))
        if starts { launcher.restart() }
    }

    private var hasStaleLoopbackFailure: Bool {
        if runner.state == "waiting_network" {
            return runner.code != "network" && runner.code != "ddi_timeout"
        }
        return runner.state == "failed" && ["loopback", "handshake", "unreachable"].contains(runner.code)
    }

    /// The loopback came or went. Going: logged with the time, and the agent's status says so instead
    /// of "Checking pairing". Back: the launcher tries at once instead of waiting out its backoff
    /// (the runner dies with the tunnel, so every drop costs a restart).
    func loopbackChanged(from old: LoopbackMonitor.State, to new: LoopbackMonitor.State) {
        let wasWorking = old.isWorking
        // 10.7.0.1 answers with no connection chosen in Setup: something outside Poki (a proxy app set
        // up before, or by Poki Setup) provides it. The external connection is the recorded choice, so
        // Setup's loopback step is done and Turn on does not ask to choose one (0.2.8 build 91: the step
        // never let the owner continue although the loopback was on).
        if loopback.isWorking, setup.loopback == .none {
            setup.loopback = .proxy
            log.add("loopback", "10.7.0.1 answers already: the external connection is the recorded choice")
        }
        if !loopback.isWorking, new != .checking {
            loopbackDropped = true
        }
        if wasWorking, !loopback.isWorking {
            retriedLocalDDIOnLoopback = false
            log.add("loopback", "dropped: 10.7.0.1 stopped answering (\(loopback.state)); the runner cannot survive this")
        } else if !wasWorking, loopback.isWorking {
            let wasSilent = servicesSilent
            servicesSilent = false
            let recovered = old != .checking || loopbackDropped || hasStaleLoopbackFailure
            loopbackDropped = false
            if recovered {
                let starts = sessionOn && !runner.isRunning && !runnerPaused
                log.add("loopback", "back: 10.7.0.1 answers again" + (starts ? "; starting the runner now" : ""))
                if hasStaleLoopbackFailure {
                    if starts {
                        runnerChanged(RunnerStatus(state: "connecting"))
                    } else if runnerPaused {
                        runner = RunnerStatus(state: "standby", detail: "It starts when an agent asks.")
                    } else if !sessionOn {
                        runner = .idle
                    }
                }
                if starts { launcher.restart() }
            }
            // The loopback answers: a failed local open goes the normal way, and the pairing is checked
            // now, before anything needs it.
            _ = retryLocalDDIOverLoopbackIfNeeded()
            Task { await verifyPairing(force: wasSilent) }
            // The signer's check at launch ran before the loopback was up and skipped the download: it
            // looks again now that it can reach the phone.
            signer.maintain()
        }
        if sessionOn { host.update(runner: coreState(of: runner)) }
    }

    /// The runner's state as the agent reads it. While the loopback is down, every pre-launch state
    /// is the same thing: waiting for the tunnel, said with the time it went and what to do.
    func coreState(of status: RunnerStatus) -> RunnerState {
        // In-process, a running launcher only mounted the disk image; tools wait for the session.
        if automationPath == .inProcess, status.state == "running", inProcessSession != .open {
            return inProcessSession.agentState
        }
        if status.code == "passcode" {
            return .starting("the phone is asking the owner for the passcode (iOS does this once before the first automation after a restart or a force quit); the Live Activity tells the owner; the runner starts the moment it is entered. Call again in about 10 s; nothing is lost and no action is needed from you")
        }
        let preLaunch = ["connecting", "pairing", "tunnel", "waiting_network", "standby", "idle"].contains(status.state)
        if preLaunch, !loopback.isWorking, loopback.state != .checking || status.state == "waiting_network" {
            if loopback.cellularRefused {
                let since = loopback.droppedAt.map { " since \(Self.clock.string(from: $0))" } ?? ""
                return .starting(cellularNeedsWiFi
                    ? "waiting for the local developer connection\(since): the phone has only cellular, and the developer disk image is not mounted. Mounting it (once after each iPhone restart) needs Wi-Fi. Ask the owner to connect to Wi-Fi; Poki carries on by itself"
                    : "the phone has only cellular\(since): Poki is opening its own automation session on the mounted developer disk image. Call again in about 10 s; nothing is lost and no action is needed from you")
            }
            return .waitingForLoopback(since: loopback.droppedAt.map(Self.clock.string(from:)),
                                       tunnelWithoutAnswer: loopback.state == .noAnswer,
                                       connection: setup.loopback == .builtIn ? .builtIn : .external)
        }
        return status.coreState
    }
    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    func runnerChanged(_ status: RunnerStatus) {
        if status != runner { log.add("runner", "\(status.state)\(status.detail.map { ": \($0)" } ?? "")\(status.state == "failed" && runner.state != "failed" ? " [\(networkNote)]" : "")") }
        // Events from a launcher that was stopped for idle are old news.
        guard !runnerPaused else { return }
        switch status.state {
        case "running" where status.code == "local_ddi":
            servicesSilent = false
            // Only the mounted image was found: nothing reached the phone, so the pairing and the
            // setup steps stay as they were until the session opens (warmInProcess).
            log.add("runner", "the loopback did not answer; using the mounted developer disk image")
        case "launching", "running":
            // The phone accepted the pairing.
            if pairingTrouble != nil { log.add("pairing", "accepted again") }
            pairingTrouble = nil
            servicesSilent = false
            pairingVerifiedAt = Date()
            // The disk image mounted and the runner is starting, so Developer Mode is on; a running
            // runner means UI Automation is on too. Setup's confirm steps tick themselves (a pairing
            // file from Poki Setup then needs nothing more on the phone).
            if !setup.developerMode { setup.developerMode = true; log.add("setup", "Developer Mode is on (the runner started)") }
            if status.state == "running", !setup.uiAutomation { setup.uiAutomation = true; log.add("setup", "UI Automation is on (the runner runs)") }
            if status.state == "running", automationPath == .runner { automationStarted() }
            if status.state == "launching", runner.state != "launching" { launchingSince = Date() }
        case "failed" where status.code == "handshake":
            servicesSilent = true
        case "failed" where status.code == "pairing":
            if pairingTrouble == nil { log.add("pairing", "refused: \(status.detail ?? "")") }
            pairingTrouble = status.detail ?? "The phone refused the pairing."
        default: break
        }
        if status.state != "launching" { launchingSince = nil; passcodeHint = inProcessPasscode }
        if status.code == "passcode", runner.code != "passcode" {
            // iOS is asking for the passcode before the first UI automation after a restart. The
            // launcher waits minutes for it; the person is asked on the Live Activity, and the agent
            // reads a plain "starting" meanwhile (coreState).
            passcodeHint = true
            log.add("runner", "the runner has not answered for 12 s: asking the owner for the passcode on the Live Activity")
            activity.update { $0.phase = .handoff; $0.handoff = .init(id: Self.runnerPasscodeHandoff, kind: .runnerPasscode, text: nil, app: nil, since: Date()) }
        }
        if status.isRunning, activity.state.handoff?.id == Self.runnerPasscodeHandoff {
            activity.update { $0.handoff = nil; $0.phase = .idle; $0.headline = "Ready for the agent" }
        }
        if status.code == "ddi_bad", runner.code != "ddi_bad" {
            log.add("ddi", "the phone would not install the disk image: downloading it again")
            diskImage.redownload()
        }
        runner = status
        host.update(runner: coreState(of: status))
        // Readiness can satisfy an outstanding phone step; preparation alone leaves it idle.
        if status.state == "running" {
            diskImage.refreshAvailability()
            warmInProcess("the launcher is ready")
        }
        if status.state == "failed" {
            let title = Self.problemText(code: status.code, fix: status.fix ?? status.detail ?? "The runner stopped")
            activity.update { $0.phase = .problem; $0.label = "Runner Stopped"; $0.headline = title }
        } else if activity.state.approval != nil || activity.state.handoff != nil {
            // Runner readiness must not replace a decision waiting for the owner.
        } else if let step = stepUnderWay {
            activity.update { $0.phase = .working; $0.headline = step.summary; $0.since = step.started; $0.runnerPaused = false }
        } else if !status.isRunning {
            activity.update { $0.phase = .idle; $0.headline = status.title }
        } else if activity.state.phase == .problem || activity.state.phase == .idle || activity.state.headline == "Starting the runner" || activity.state.headline == "Starting native services" {
            activity.update { $0.phase = .idle; $0.headline = "Waiting for agent" }
        }
    }

    private func handle(_ event: ShellEvent) {
        if case .approvalRequested(let approval) = event, let probe = onProbeApproval { probe(approval) }
        // Every outside agent's session and step goes into the Sessions list, on or off.
        SessionStore.shared.observe(event, approvals: approvals)
        // The first agent through a connector names it (unless the owner did) and gives it its icon.
        if case .session(.started(_, let client, _, let connector?)) = event {
            identity.noteAgent(hash: connector, client: AgentName.pretty(client))
        }
        // Events after Turn off (the core's own "stopped") are not for the screen. An approval is
        // the exception: a call that asks one (the on-device chat, the gym probe) waits on the
        // owner's answer whether or not Poki is on, and dropping it left that call waiting for the
        // whole approval time.
        switch event {
        case .approvalRequested, .approvalEnded: break
        default: guard sessionOn || probeDriven else { return }
        }
        for observer in shellObservers { observer(event) }
        switch event {
        case .session(let signal):
            lastShot = nil
            if case .ended(let id) = signal {
                // Only that session's own task ends: the core returns the phone to where it began
                // (nothing happens when another session holds the task), and the automation session
                // closes only when no other agent is at work.
                let agent = outsideAgentsAtWork.removeValue(forKey: id)
                endingTasks += 1
                Task { [weak self, core] in
                    _ = await core.finishTask(session: id)
                    guard let self else { return }
                    self.endingTasks -= 1
                    if self.outsideAgentsAtWork.isEmpty { self.closeAfterTask("an agent ended its session") }
                    if let agent { self.tellOwner(agentWasHere: agent) }
                }
            }
        case .relay(let status):
            if status != relayStatus { log.add("relay", "\(status)") }
            relayStatus = status
        case .toolStarted(_, let summary, let session):
            // A step of an outside agent's own session (not the chat's): the owner is told when it is through.
            if let session, let client = SessionStore.shared.outsideClient(ofMCPSession: session) { outsideAgentsAtWork[session] = client }
            if !chatTaskActive { log.add("session-timing", String(format: "phone_step_received uptime=%.6f", ProcessInfo.processInfo.systemUptime)) }
            lastAgentActivity = Date(); lastStepAt = Date()
            if summary == "Look at the screen", AskPoki.chat?.waitingForSplitView == true { return }
            stepUnderWay = (summary, Date())
            activityText = summary
            log.add("agent", "started: \(summary)")
            if problem?.hasPrefix("An approval ran out") == true { problem = nil }
            let caller = currentCaller
            activity.update { state in
                if state.approval == nil {
                    if state.phase != .working || state.since == nil { state.since = Date() }
                    state.phase = .working
                }
                state.headline = summary
                state.caller = caller
            }
        case .toolFinished(let summary, let delivery, let app, let thumbnail, let error, _):
            lastAgentActivity = Date(); lastStepAt = Date()
            if summary == "Look at the screen", AskPoki.chat?.waitingForSplitView == true { return }
            stepUnderWay = nil
            lastAction = "\(summary), \(delivery)"
            activityText = "Idle"
            if handoffText != nil { closeForHandoff() }
            let failed = delivery.hasPrefix("failed")
            log.add("agent", "\(failed ? "failed" : "done"): \(summary) · \(delivery.prefix(160))" + (error.map { " · \($0)" } ?? ""))
            if let app { currentApp = app }
            recentSteps.append(RecentStep(text: summary, app: app, failure: failed ? delivery : nil, at: Date()))
            // The owner's own record of every action, with the run it came from.
            let chat = AskPoki.chat
            ActionLog.shared.add(summary, app: app, ok: !failed,
                                 session: SessionStore.shared.activeSessionID ?? (chat?.running == true ? chat?.sessionID : nil),
                                 caller: currentCaller)
            if recentSteps.count > 20 { recentSteps.removeFirst(recentSteps.count - 20) }
            activity.record(step: summary, ok: !failed)
            activity.update { state in state.app = app ?? state.app }
            activity.setThumbnail(thumbnail)
            if let thumbnail, let image = UIImage(data: thumbnail) { lastShot = image }
        case .approvalRequested(let approval):
            switch ApprovalClassifier.route(approval, voiceOn: voice.isOn) {
            case .allow:
                // The rules were on when Poki started and asking has been turned off since.
                checking.append(approval)
                log.add("approval", "requested \(approval.id) in \(approval.app): \(approval.summary); asking is off, allowed")
                core.resolveApproval(id: approval.id, approved: true)
            case .model(let reply):
                // The chat model checks it first: no Live Activity card, no notification, no tap. The chat shows it.
                checking.append(approval)
                log.add("approval", "requested \(approval.id) in \(approval.app): \(approval.summary); asking the auto-classifier")
                Task { [weak self] in
                    let verdict = await ApprovalClassifier.decide(approval, level: ApprovalClassifier.Level.saved, voice: self?.voice.lines ?? [])
                    guard let self, self.checking.contains(where: { $0.id == approval.id }) else { return }
                    self.log.add("approval", "auto-classifier \(verdict.allowed ? "allowed" : "refused") \(approval.id): \(verdict.reason)")
                    if verdict.allowed || reply {
                        self.core.resolveApproval(id: approval.id, approved: verdict.allowed)
                    } else {
                        // With Confirmation: what the model would not allow is the owner's to answer.
                        self.checking.removeAll { $0.id == approval.id }
                        ApprovalClassifier.handToOwner(approval.id)
                        for observer in self.approvalObservers { observer(approval.id) }
                        self.askOwner(approval)
                    }
                }
            case .owner:
                askOwner(approval)
            }
        case .approvalEnded(let id, let approved):
            lastApprovalAnswered = Date()
            if let approval = approvals.first(where: { $0.id == id }) {
                record(approval, approved: approved)
            } else if let approval = checking.first(where: { $0.id == id }) {
                record(approval, approved: approved)
            }
            approvals.removeAll { $0.id == id }
            checking.removeAll { $0.id == id }
            log.add("approval", "ended \(id): \(approved.map { $0 ? "approved" : "denied" } ?? "expired or replaced")")
            if approved == nil, !ApprovalClassifier.modelAnswered(id) { problem = "An approval ran out before you answered, so that step was not done. The agent can ask again." }
            ApprovalNotice.clear(id)
            activity.update { state in
                if state.approval?.id == id { state.approval = nil; state.phase = .working; state.headline = approved == true ? "Continuing" : "Step skipped" }
            }
        case .handoffRequested(let id, let kind, let text, let app):
            lastAgentActivity = Date(); lastStepAt = Date()
            let shown = PokiActivityAttributes.Handoff.Kind(rawValue: kind) ?? .other
            handoffText = text ?? Self.handoffWording(shown)
            log.add("handoff", "the agent handed over \(id) (\(kind))\(app.map { " in \($0)" } ?? ""): \(handoffText ?? "")")
            activity.update { state in
                state.phase = .handoff
                state.handoff = .init(id: id, kind: shown, text: text, app: app, since: Date())
                state.headline = "Your turn"
                state.app = app ?? state.app
            }
        case .handoffEnded(let id, let how):
            lastAgentActivity = Date(); lastStepAt = Date()
            log.add("handoff", "ended \(id): \(how)")
            handoffText = nil
            activity.update { state in
                if state.handoff?.id == id {
                    state.handoff = nil
                    if !state.runnerPaused {
                        state.phase = .working
                        state.headline = switch how {
                        case "done": "Carrying on"
                        case "taskEnded": "Finishing"
                        default: "The agent carried on by itself"
                        }
                    }
                }
            }
        }
    }

    // MARK: The chat's tools

    /// A tool call from the chat's model loop. Poki turns on first when it is off (the runner then starts
    /// on this call, like for an agent's first request); when it cannot, the answer says why.
    /// The chat's turn ended: the phone goes back to the app the task began in, and the log says how.
    func finishTask(then: (@MainActor () -> Void)? = nil) {
        if chatTaskActive { lastAgentActivity = Date() }
        chatTaskActive = false
        lastShot = nil
        // The phone goes back to where the task began first: that still needs the session.
        endingTasks += 1
        Task { [weak self, core, log] in
            if let line = await core.finishTask() { log.add("runner", line) }
            self?.endingTasks -= 1
            self?.closeAfterTask("the task ended")
            then?()
        }
    }

    func finishSplitViewTask(localSession: String, pairConfirmed: Bool = true, cancelled: () -> Bool = { false }) async {
        _ = await core.settle(timeout: 30)
        if let line = await core.finishTask(switching: pairConfirmed, localSession: localSession) { log.add("runner", line) }
        // The Split View task is over: as at the end of any task, the automation session closes.
        if chatTaskActive { lastAgentActivity = Date() }
        chatTaskActive = false
        closeAfterTask("the Split View task ended")
        guard activitySplitViewSession == localSession else { return }
        activitySplitViewSession = nil
        lastAgentActivity = Date()
        activity.setChatOwnsCompletion(false)
        if cancelled() { activity.endStoppedRun() }
    }

    func reserveSplitViewWorkspace(session: String) async -> Bool {
        await core.prepareWorkspace(session: session)
    }

    func clearSplitViewPaneForSetup(session: String) async -> Bool {
        await core.clearWorkspacePaneForSetup(session: session)
    }

    func openSplitViewLauncherItem(labels: [String], menu: Bool, session: String) async throws -> Bool {
        lastAgentActivity = Date()
        let request: JSON = ["labels": .array(labels.map(JSON.string)), "menu": .bool(menu)]
        return try await core.workspaceLauncherStep(session: session, request: request).bool == true
    }

    // MARK: The chat's task

    /// The chat's task began (Poki is in front): the Live Activity is there for it, with no old plan.
    func chatTaskBegan(splitViewSession: String? = nil) {
        log.add("session-timing", String(format: "task_submitted uptime=%.6f", ProcessInfo.processInfo.systemUptime))
        chatTaskActive = automationPath == .inProcess
        if chatTaskActive { lastAgentActivity = Date() }
        lastShot = nil
        activitySplitViewSession = splitViewSession
        activity.setChatOwnsCompletion(splitViewSession != nil)
        // The owner sees at once that Poki took the task: the Live Activity (started here, while
        // Poki is in front) and iOS's background line say so before the model's first answer.
        if sessionOn {
            activity.update { state in
                state.plan = nil
                guard state.approval == nil, state.handoff == nil, state.phase == .idle || state.phase == .done else { return }
                state.phase = .working
                state.headline = "Thinking"
                state.since = Date()
            }
            if !activity.isRunning, inFront { activity.start(deviceName: deviceName) }
        } else {
            activity.update { $0.plan = nil }
        }
    }

    /// The chat's model published its plan: the Live Activity counts the same steps as the chat and
    /// says the one under way in the plan's words. A later report_plan that leaves out the title or
    /// the recipient keeps the first one's.
    func chatPlan(steps: [String], current: Int, title: String?, to: String?) {
        activity.update { state in
            let old = state.plan
            state.plan = .init(steps: steps.map { String($0.prefix(60)) }, current: current, title: title ?? old?.title, to: to ?? old?.to)
        }
    }

    func chatWaitingForSplitView(_ waiting: Bool) {
        if waiting { lastShot = nil }
        activity.update { state in
            guard state.phase == .working, state.approval == nil, state.handoff == nil else { return }
            if waiting { state.headline = "Waiting for Split View" }
            else if state.headline == "Waiting for Split View" { state.headline = "Continuing" }
        }
    }

    /// End the task, return to Poki and finish its Live Activity.
    func chatTaskEnded(reply: String?, session: String, acted: Bool, inSplitView: Bool = false) {
        lastShot = nil
        guard acted else {
            if !inSplitView { finishTask() }
            // A turn that never touched the phone: nothing ran, so nothing is left showing as working.
            activity.update { state in
                state.plan = nil
                guard state.phase == .working, state.stepCount == 0, state.approval == nil, state.handoff == nil else { return }
                state.phase = .idle; state.headline = "Waiting for agent"; state.since = nil
            }
            // The owner's own reply still reaches them when they are elsewhere (a task sent from a shortcut).
            if !inFront, let reply, session == AskPoki.chat?.sessionID { postReply(reply) }
            return
        }
        // On a Dynamic Island the activity's own pop-up says the task is over: no banner on top of it.
        let islandTold = activity.finishNow(alert: true)
        if !inSplitView {
            finishTask { [weak self] in
                guard !islandTold else { return }
                // A task ends in Poki or with a notice that breaks through: when the phone could not be
                // brought back to Poki, the owner is told where they are.
                Task { @MainActor [weak self] in
                    // Coming forward takes a moment after the return is answered.
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let self, UIApplication.shared.applicationState != .active else { return }
                    self.log.add("chat", "the task ended away from Poki: time-sensitive notification sent")
                    // The result stays in Poki: a reply can hold what the task just read on the screen.
                    self.postReply(AppLocalization.text(LocalizedStringResource("The task has ended. Open Poki to see the result.")), timeSensitive: true)
                }
            }
        }
    }

    /// A reply that touched no phone, while Poki is not in front (Send Task to Poki from a shortcut): the
    /// notification is where the owner reads it. A tap opens Poki.
    private func postReply(_ reply: String, timeSensitive: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = "Poki"
        content.body = reply
        content.sound = .default
        if timeSensitive {
            content.interruptionLevel = .timeSensitive
            content.userInfo = ["poki_link": "poki://chat"]
        }
        content.threadIdentifier = "chat"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "poki-reply", content: content, trigger: nil))
    }

    func runTool(_ name: String, arguments: String, localSession: String? = nil, expectedApps: Set<String>? = nil) async -> PokiCore.ToolAnswer {
        if name == "status" || name == "routines" { return await core.callTool(name, arguments: arguments, localSession: localSession) }
        if probeDriven { return await core.callTool(name, arguments: arguments, localSession: localSession, expectedApps: expectedApps) }
        if !sessionOn {
            if !sessionStarting { startSession() }
            if let task = sessionStartTask { await task.value }
        }
        if passcodeConfirmationPending {
            return PokiCore.ToolAnswer(text: "not_sent: \(AppLocalization.text(Self.passcodeConfirmationMessage)) Nothing was sent.", jpeg: nil, isError: true)
        }
        guard sessionOn else {
            let why = problem ?? "Poki is off."
            return PokiCore.ToolAnswer(text: "not_sent: Poki could not turn on: \(why) Nothing was sent. Tell the owner what to fix.", jpeg: nil, isError: true)
        }
        lastAgentActivity = Date(); lastStepAt = Date()
        return await core.callTool(name, arguments: arguments, localSession: localSession, expectedApps: expectedApps)
    }

    /// After Stop: waits until the phone has finished the action a stopped call had already sent.
    func phoneSettles(within seconds: Double) async -> Bool { await core.settle(timeout: seconds) }

    // MARK: Approvals

    /// Approvals from the app's own screen (the same path as the Live Activity's buttons).
    /// An approval's answer in the Activity Log: what was asked, who answered, and the model's reason.
    private func record(_ approval: PendingApproval, approved: Bool?) {
        let detail: String
        if ApprovalClassifier.modelAnswered(approval.id), let verdict = ApprovalClassifier.verdicts[approval.id] {
            detail = (approved == true ? AppLocalization.text(LocalizedStringResource("Allowed automatically")) : AppLocalization.text(LocalizedStringResource("Not allowed automatically"))) + (verdict.reason.isEmpty ? "" : ": \(verdict.reason)")
        } else if ApprovalClassifier.mode == .off, !ApprovalClassifier.requiresOwner(approval) {
            detail = AppLocalization.text(LocalizedStringResource("Allowed, asking is off"))

        } else {
            switch approved {
            case true?: detail = AppLocalization.text(LocalizedStringResource("You allowed it"))
            case false?: detail = AppLocalization.text(LocalizedStringResource("You did not allow it"))
            case nil: detail = AppLocalization.text(LocalizedStringResource("Ran out before an answer"))
            }
        }
        let chat = AskPoki.chat
        ActionLog.shared.add(approval.summary, app: approval.app, ok: approved == true,
                             session: SessionStore.shared.activeSessionID ?? (chat?.running == true ? chat?.sessionID : nil),
                             caller: currentCaller, kind: .approval, detail: detail, why: approval.reason)
    }

    /// Each request is answered by the owner on the Live Activity, or on a notification when there is none.
    private func askOwner(_ approval: PendingApproval) {
        approvals.append(approval)
        log.add("approval", "requested \(approval.id) in \(approval.app): \(approval.summary); Live Activity \(activity.isRunning ? "running" : "NOT running: \(activity.lastError ?? "no error")")")
        let caller = currentCaller
        activity.update { $0.phase = .approval; $0.approval = approval; $0.headline = "Allow this step?"; $0.caller = caller }
        // One surface per approval. With a Live Activity, its alert is the ask (Allow and Don't Allow
        // on the expanded island and the Lock Screen card): a banner on top of it put two asks over the
        // top of the screen, and a tap on the banner opens Poki in the middle of the task. The
        // time-sensitive notification is for when there is no Live Activity to pop up: off in
        // Settings, dismissed, or Poki turned on from the background, where iOS starts none.
        if activity.isRunning {
            log.add("approval", "asked on the Live Activity only, no notification")
        } else {
            ApprovalNotice.post(approval, caller: caller)
        }
    }

    func resolve(_ approval: PendingApproval, approved: Bool) {
        core.resolveApproval(id: approval.id, approved: approved)
    }

    /// Don’t Ask Again on an approval's card: this step goes through and approvals are off from now on.
    func stopAsking(_ approval: PendingApproval) {
        turnApprovalsOff()
        core.resolveApproval(id: approval.id, approved: true)
    }

    private func turnApprovalsOff() {
        guard approvalMode != .off else { return }
        approvalMode = .off
        for observer in stopAskingObservers { observer() }
    }

    private func listenForApprovals() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in model.drainApprovals() }
        }, ApprovalMailbox.notification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in model.pauseRunner(reason: "Stopped from the Live Activity") }
        }, ApprovalMailbox.stopRunner as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in model.handoffDone() }
        }, ApprovalMailbox.handoffDone as CFString, nil, .deliverImmediately)
    }

    /// The person tapped "Continue" on the Live Activity's "Your turn" card.
    func handoffDone() {
        guard let id = ApprovalMailbox.drainHandoffDone() else { return }
        handoffDone(id: id)
    }

    /// The same answer from the chat's "Your turn" card, while Poki is in front.
    func handoffDoneInApp() {
        guard let id = activity.state.handoff?.id else { return }
        handoffDone(id: id)
    }

    private func handoffDone(id: String) {
        log.add("handoff", "done by the owner: \(id)")
        if id == Self.runnerPasscodeHandoff {
            // The runner's own launch: the launcher notices by itself when the runner answers.
            activity.update { $0.handoff = nil; $0.phase = runner.isRunning ? .idle : .working; $0.headline = runner.isRunning ? "Ready for the agent" : "Starting the runner" }
        } else {
            activity.update { $0.handoff = nil; $0.phase = .working; $0.headline = "Carrying on" }
            core.handoffDone(id: id)
        }
    }
    static let runnerPasscodeHandoff = "runner-passcode"

    /// What the owner is asked to do, when the model gave no words of its own.
    static func handoffWording(_ kind: PokiActivityAttributes.Handoff.Kind) -> String {
        switch kind {
        case .runnerPasscode: "The phone asks for your passcode so the runner can start"
        case .automationPasscode: "The phone asks for your passcode to allow automation"
        case .passcode: "The screen asks for your passcode"
        case .password: "The screen asks for a password"
        case .verification: "The screen asks for a verification step"
        case .payment: "The screen asks you to confirm a payment"
        case .other: "The agent cannot act on this screen, please do this step"
        }
    }

    /// Decisions an intent left in the App Group mailbox because it ran outside the app.
    func drainApprovals() {
        for decision in ApprovalMailbox.drain() { decide(decision) }
    }

    /// A decision from the Live Activity. The card shows the answer at once (Allowing, Denying).
    /// Allow is tapped on the expanded Dynamic Island, which takes about a second to collapse; input
    /// sent at once can land on it (iOS then opens Poki). So the Live Activity's decisions reach
    /// PokiCore after a short pause, the app's own buttons at once.
    func decide(_ decision: ApprovalDecision) {
        // Don’t Ask Again is the owner's word about all later steps too, so it counts for a card whose
        // approval has already ended.
        if decision.stopAsking { turnApprovalsOff() }
        // A tap on an approval that already ended (answered in the app, or timed out) does nothing.
        guard approvals.contains(where: { $0.id == decision.approvalID }) else { return }
        log.add("approval", "\(decision.approved ? "allowed" : "denied") \(decision.approvalID) on the Live Activity\(decision.stopAsking ? ", asking off" : "")")
        activity.update { state in
            guard state.approval?.id == decision.approvalID else { return }
            state.phase = .deciding
            state.decision = decision.approved
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.islandCollapse))
            core.resolveApproval(id: decision.approvalID, approved: decision.approved)
        }
    }

    /// How long the expanded island takes to fold after a tap on its button.
    static let islandCollapse: TimeInterval = 1.5

    /// A launcher failure as the Live Activity's content line, in English (the face words it in the
    /// system's language). The codes the launcher sends (native/launcher/src/device.rs, ddi.rs,
    /// launch.rs) have names of a few words; a failure without one gives the first part of its fix.
    /// What to do is in the app, which shows the whole fix.
    nonisolated static func problemText(code: String?, fix: String) -> String {
        let short = [
            "loopback": "Loopback Off",
            "pairing_port": "Finding Pairing Port",
            "network": "No Internet",
            "ddi_timeout": "No Internet",
            "ddi_refused": "Disk Image Outdated",
            "ddi_bad": "Fetching Disk Image",
            "pairing": "Pairing Refused",
            "handshake": "Loopback or Pairing",
            "unreachable": "Can’t Reach iPhone",
            "developer_mode": "Developer Mode Off",
            "no_cryptexd": "Check Developer Mode",
            "ios_too_old": "Update iOS",
            "runner": "Poki Runner Missing",
            "runner_blocked": "Poki Runner Didn’t Start",
        ]
        return code.flatMap { short[$0] } ?? firstPart(fix)
    }

    /// A text up to its first colon or the end of its first sentence, capitalised.
    nonisolated static func firstPart(_ text: String) -> String {
        let mark = [": ", ". "].compactMap { text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        let part = mark.map { String(text[..<$0.lowerBound]) } ?? text
        return part.prefix(1).uppercased() + part.dropFirst()
    }

    // MARK: Pairing

    func importPairingFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try importPairingFile(try Data(contentsOf: url), how: "imported")
    }

    /// A pairing file as bytes: from Files, AirDrop, a `poki://pairing` link or Poki Setup on a computer.
    func importPairingFile(_ data: Data, how: String) throws {
        // A lockdown pairing plist or an RPPairing file; both are property lists.
        _ = try PropertyListSerialization.propertyList(from: data, format: nil)
        try data.write(to: AppFiles.pairingFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Chosen by hand: it replaces the phone's own pairing as well.
        try? FileManager.default.removeItem(at: AppFiles.phonePairingFile)
        pairingFileSeen = true
        SetupVault.storePairing(data)
        setup.pairingFile = AppFiles.pairingFile.path
        pairingTrouble = nil; pairingVerifiedAt = nil
        pairingNote = AppLocalization.text(LocalizedStringResource("Pairing file received."))
        log.add("pairing", "pairing file \(how)")
    }

    /// What the last pairing link or file did, for the pairing page.
    var pairingNote: String?

    /// A link Poki was opened with. `poki://pairing?url=…[&sha256=…]` fetches a pairing file (Poki
    /// Setup serves it on the local network and shows the link as a code); `poki://pairing?data=…`
    /// carries one in base64url; `poki://setup?relay=…` sets the relay. A file URL is a pairing file
    /// opened from AirDrop or Files. Returns the setup step to show, or nil when the link was none of these.
    func open(link url: URL) -> SetupStep? {
        if url.isFileURL {
            do { try importPairingFile(from: url) } catch { pairingNote = AppLocalization.text(LocalizedStringResource("Invalid Pairing File. \(error.localizedDescription)")) }
            try? FileManager.default.removeItem(at: url)
            return .pairing
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.host() {
        case "pairing":
            if let text = item("data"), let data = Data(base64URL: text) {
                do { try importPairingFile(data, how: "received by link") } catch { pairingNote = AppLocalization.text(LocalizedStringResource("Invalid Pairing File. \(error.localizedDescription)")) }
            } else if let from = item("url").flatMap(URL.init(string:)), ["http", "https"].contains(from.scheme ?? "") {
                let expected = item("sha256")?.lowercased()
                pairingNote = AppLocalization.text(LocalizedStringResource("Fetching the pairing file from \(from.host() ?? AppLocalization.text("your computer"))…"))
                Task {
                    do {
                        let (data, _) = try await URLSession.shared.data(from: from)
                        if let expected, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() != expected {
                            throw NSError(domain: "poki", code: 1, userInfo: [NSLocalizedDescriptionKey: AppLocalization.text(LocalizedStringResource("the file does not match the link"))])
                        }
                        try importPairingFile(data, how: "fetched from \(from.host() ?? "?")")
                    } catch { pairingNote = AppLocalization.text(LocalizedStringResource("Could not get the pairing file. \(error.localizedDescription)")) }
                }
            } else {
                pairingNote = AppLocalization.text(LocalizedStringResource("The pairing link carried no file."))
            }
            return .pairing
        case "setup" where item("step") != nil:
            // The Live Activity's link to a setup step (pairing).
            return item("step").flatMap(SetupStep.init(rawValue:))
        case "setup":
            // Poki Setup hands over the relay it configured (the Cloudflare proxy); the chat shows it.
            if let relay = item("relay") { log.add("relay", setRelay(relay) ? "set by link" : "link carried no relay address") }
            return nil
        default: return nil
        }
    }

    func startPairing() {
        guard loopback.isWorking else {
            pairing = .failed("Enable a local connection in Setup and wait for the connection check to pass, then try pairing again.")
            return
        }
        pairing = .advertising
        // The code also comes as a banner (PairingNotice): ask for notifications now, while in front.
        ApprovalNotice.requestPermission()
        // Started now, while Poki is in front: the PIN arrives while the person is in Settings, when
        // iOS no longer lets Poki start a Live Activity.
        activity.start(deviceName: deviceName)
        activity.update { $0.phase = .pairing; $0.pin = nil; $0.headline = "Pair in Settings" }
        // The person completes pairing in Settings. Keep the listener and Bonjour publication alive
        // there, before a regular Poki session can be started. Without it (audio can be busy, as in a
        // call) pairing still starts, as it did before the keep-alive.
        // Location keeps Poki running in Settings as well (While Using is enough, started here in front).
        background.holdForPairing()
        log.add("pairing", "staying on with location (\(background.allowed ? "allowed" : "not allowed yet")) and silent audio")
        do { try pairingKeepAlive.start() }
        catch { log.add("pairing", "keep-alive did not start (\(error.localizedDescription)); iOS may stop the pairing while Settings is open") }
        do {
            try pairer.start(hostName: "Poki", saveTo: AppFiles.pairingFile) { [weak self] event in
                Task { @MainActor in self?.pairingChanged(event) }
            }
        } catch { pairingChanged(.failed("\(error)")) }
    }

    func cancelPairing() {
        if pairingUnderWay { log.add("pairing", "stopped") }
        pairer.cancel()
        pairingKeepAlive.stop()
        background.releasePairing()
        pairing = nil
        activity.update { $0.pin = nil }
        if !sessionOn { stopGuide(); activity.end() }
    }

    /// Waiting for Settings or showing a PIN: the listener, Bonjour and the keep-alive are running.
    var pairingUnderWay: Bool {
        switch pairing {
        case .advertising?, .pin?: true
        default: false
        }
    }

    /// The person left the pairing step in Poki (another tab, or another step): the pairing stops at
    /// once, and with it the background keep-alive. Going to Settings is not leaving.
    func leftPairing() {
        guard pairingUnderWay else { return }
        // Only a move inside Poki counts. iOS can take pages down while Poki is in the background
        // (the person is in Settings typing the code) or while it comes back; that is not leaving.
        guard inFront, UIApplication.shared.applicationState == .active, Date().timeIntervalSince(cameToFront) > 2 else {
            log.add("pairing", "pairing page went away while Poki was not in front; the pairing goes on")
            return
        }
        log.add("pairing", "cancelled: the pairing step was left")
        cancelPairing()
    }

    private func pairingChanged(_ event: PairingEvent) {
        pairing = event
        switch event {
        case .pin(let pin):
            // The PIN goes in the Live Activity, so it is visible while the user is in Settings.
            activity.start(deviceName: deviceName)
            activity.update { $0.phase = .pairing; $0.pin = pin; $0.headline = "Pairing code" }
            // A banner with the code as well: it drops down over Settings by itself, also when the Live
            // Activity is off, was dismissed, or iOS holds back its alert.
            PairingNotice.post(pin: pin)
            log.add("pairing", "code ready\(activity.isRunning ? "" : " (no Live Activity: \(activity.lastError ?? "unknown reason"))")")
        case .paired(let url):
            PairingNotice.clear()
            pairingKeepAlive.stop()
            background.releasePairing()
            try? (url as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
            setup.pairingFile = url.path
            if let data = try? Data(contentsOf: url) {
                SetupVault.storePairing(data)
                try? data.write(to: AppFiles.phonePairingFile, options: .completeFileProtectionUntilFirstUserAuthentication)
            }
            pairingTrouble = nil; pairingVerifiedAt = nil
            log.add("pairing", "paired on the phone")
            activity.update { $0.phase = .idle; $0.pin = nil; $0.headline = "Paired" }
            if !sessionOn { Task { try? await Task.sleep(for: .seconds(4)); if !self.sessionOn { self.activity.end() } } }
        case .failed(let why):
            PairingNotice.clear()
            pairingKeepAlive.stop()
            background.releasePairing()
            activity.update { $0.phase = .problem; $0.pin = nil; $0.label = "Pairing Failed"; $0.headline = Self.firstPart(why) }
            if !sessionOn { Task { try? await Task.sleep(for: .seconds(8)); if !self.sessionOn { self.activity.end() } } }
        case .advertising: break
        }
    }

    // MARK: Setup guide

    /// The person is going to Settings for a setup step: the Live Activity shows the step and what to
    /// tap, so it stays in view there. Ended when they come back and the step is done.
    func guide(_ step: SetupStep) {
        guiding = step
        guard !sessionOn else { return }
        activity.start(deviceName: deviceName)
        let steps = SetupStep.shown
        activity.update {
            $0.phase = .setup
            $0.headline = "Setting up Poki"
            $0.guide = .init(number: (steps.firstIndex(of: step) ?? 0) + 1, count: steps.count, title: step.activityTitle)
        }
    }

    func stopGuide() {
        guard guiding != nil else { return }
        guiding = nil
        activity.update { $0.guide = nil }
        if !sessionOn, activity.state.phase == .setup { activity.end() }
    }

    func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .runner: setup.runnerInstalled
        case .developerMode: setup.developerMode
        // A loopback that answers is the step done, whichever app provides it: one set up before Poki
        // (or by Poki Setup on a computer) has no row tapped here, and `loopbackChanged` records it.
        // Poki's own session open on the mounted image does the step's job without it (ESP-448).
        case .loopback: loopback.isWorking || hasOpenInProcessSession
        // The disk image downloads by itself (and is checked again when Poki turns on): it does not hold the step open.
        case .pairing: pairingPath != nil && pairingTrouble == nil
        case .automation: setup.uiAutomation
        case .background: background.allowed
        }
    }

    var setupComplete: Bool { SetupStep.shown.allSatisfy(isDone) }

    /// A step as Home, the tab badge and the status pill show it: the loopback's first check after
    /// launch (a connection was chosen before) counts as done until it says otherwise, so Poki shows
    /// Ready rather than Paused and a warning for the second it takes. The Setup page keeps isDone.
    func looksDone(_ step: SetupStep) -> Bool {
        if step == .loopback, loopback.state == .checking, setup.loopback != .none { return true }
        return isDone(step)
    }
    var setupLooksComplete: Bool { SetupStep.shown.allSatisfy(looksDone) }

    func stepReadyForUse(_ step: SetupStep) -> Bool {
        step == .loopback && canStartTasks ? true : looksDone(step)
    }
    var setupReadyForUse: Bool { SetupStep.shown.allSatisfy(stepReadyForUse) }

    /// A setup step is still to do. The loopback counts as done once a connection is chosen: whether it
    /// answers right now is checked live and is off whenever Poki is (the built-in connection), which is
    /// not a step left for the owner.
    var setupStepsLeft: Bool {
        SetupStep.shown.contains { $0 == .loopback ? setup.loopback == .none : !isDone($0) }
    }

    /// Home offers Start although the loopback is not answering: the image is mounted and the
    /// pairing is Poki's own, so a new task can open Poki's session on cellular (ESP-448).
    var canStartFromHome: Bool { canStartFromHome(localDDIAvailable: diskImage.isReady && Self.localDDIMounted) }

    /// Poki can start a task: setup looks complete, or on cellular the mounted image stands in for the
    /// loopback, because the launcher already handed a task to it or Home can start one there (ESP-448).
    var canStartTasks: Bool { runner.code == "local_ddi" || canStartFromHome }

    func canStartFromHome(localDDIAvailable: @autoclosure () -> Bool) -> Bool {
        if setupLooksComplete { return true }
        guard automationPath == .inProcess, setup.loopback != .none, !setupStepsLeft,
              let pairingPath, let record = Self.pairingRecord(at: pairingPath),
              record["identifier"] is String,
              (record["public_key"] as? Data)?.count == 32,
              (record["private_key"] as? Data)?.count == 32 else { return false }
        return localDDIAvailable()
    }

    /// A file the mounted developer disk image puts on the phone (the XCTest framework Poki loads).
    static let ddiMarker = "/System/Developer/Library/Frameworks/XCUIAutomation.framework/XCUIAutomation"

    /// The developer disk image is mounted, as the launcher checks it (`ddi_marker`).
    static var localDDIMounted: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: ddiMarker, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Poki's own session did not open after the launcher found only the mounted image (ESP-448):
    /// what Home says instead of the loopback's trouble, which it showed before the hand-over. Nil
    /// while the session opens or is open.
    var localSessionTrouble: (text: String, opensSetup: Bool)? {
        guard sessionOn, runner.isRunning, runner.code == "local_ddi" else { return nil }
        switch inProcessSession {
        // Waiting its turn: Poki not in front, or another open asking for the passcode.
        case .idle, .closing, .opening, .open, .waitingForPasscode, .failed("open_poki_first", _), .failed("open_under_way", _):
            return nil
        case .passcodeMissed, .failed("passcode_declined", _):
            return (AppLocalization.text(LocalizedStringResource("iOS asked for the iPhone passcode to allow automation, but it was not entered. Turn Poki off and on, then enter the passcode.")), false)
        case .failed(let code, _) where loopback.cellularOnly:
            return (AppLocalization.text(LocalizedStringResource("Poki could not open its own automation session (\(code)). Connect to Wi-Fi and try again.")), false)
        case .failed(let code, _):
            return (AppLocalization.text(LocalizedStringResource("Poki could not open its own automation session (\(code)), and the loopback refused the connection. Check the loopback in Setup, then try again.")), true)
        }
    }

    /// Why the signer cannot reach the phone: the pairing comes first; on cellular the loopback it
    /// needs waits for Wi-Fi (ESP-448).
    var signerUnreachable: SelfSigner.Unreachable {
        if pairingPath == nil { return .unpaired }
        return loopback.cellularOnly && !loopback.isWorking ? .cellular : .loopback
    }

    /// On cellular a new task can still start on the mounted image; otherwise it waits for Wi-Fi.
    var cellularNeedsWiFi: Bool {
        loopback.cellularRefused && !hasOpenInProcessSession && !(automationPath == .inProcess && Self.localDDIMounted)
    }

    var activityProblem: String? { activity.lastError }
    var activitiesEnabled: Bool { activity.enabled }

    // MARK: Relay and connectors

    static let noRelay = "Enter your relay’s address first in Settings › Agents › Address. Poki has no default relay."

    /// Saves the relay address the person entered; false when it is not one. A running session moves
    /// to the new relay at once.
    func setRelay(_ text: String) -> Bool {
        guard let address = RelayAddress(text) else { return false }
        guard address != relayAddress else { return true }
        RelayAddress.saved = address
        let first = relayAddress == nil
        relayAddress = address
        log.add("relay", "address set to \(address.origin.host() ?? "?")")
        if problem == Self.noRelay { problem = nil }
        // A relay just set is on.
        if first || !relayEnabled { relayEnabled = true; UserDefaults.standard.set(true, forKey: "relayEnabled") }
        if sessionOn {
            core.stop()
            core.start(relay: address)
        }
        return true
    }

    /// The MCP address for a connector, on the person's relay; nil until a relay is set.
    func connectorURL(for secret: ConnectorSecret) -> URL? {
        relayAddress.map { identity.url(for: secret, relay: $0) }
    }

    func addConnector(name: String) -> ConnectorSecret {
        let secret = identity.addSecret(name: name)
        accessChanged()
        return secret
    }
    func revoke(_ secret: ConnectorSecret) { identity.revoke(secret); accessChanged() }
    func rename(_ secret: ConnectorSecret, to name: String) { identity.rename(secret, to: name) }
    private func accessChanged() {
        host.update(key: identity.signingKey, hashes: identity.accessHashes)
        core.accessChanged()
    }
}

/// Whether WebDriverAgent answers /status right now (2 s at most).
enum RunnerProbe {
    /// Asks the runner to shut itself down: it ends its test and exits, which takes the automation
    /// banner with it. Nothing happens when it is not running.
    static func shutdown() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        func send(_ method: String, _ path: String) async -> Data? {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:8100\(path)")!, timeoutInterval: 2)
            request.httpMethod = method
            return try? await session.data(for: request).0
        }
        // The shutdown request waits in WDA's queue behind a slow tree read; ending the session first
        // voids whatever is queued, so the shutdown is handled at once.
        if let status = await send("GET", "/status"),
           let json = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
           let id = json["sessionId"] as? String, !id.isEmpty {
            _ = await send("DELETE", "/session/\(id)")
        }
        _ = await send("GET", "/wda/shutdown")
    }

    static func answers() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8100/status")!, timeoutInterval: 2)
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        guard let (_, response) = try? await URLSession(configuration: configuration).data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// When this iPhone last started (kern.boottime, seconds): iOS asks for the passcode before the first
/// automation after each start.
enum BootClock {
    static let current: Double = {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return Double(boot.tv_sec)
    }()
}
