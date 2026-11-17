import AppKit
import Foundation
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case setup, phones, account, relay, debug
    var id: String { rawValue }
    var title: String {
        switch self {
        case .setup: "Set Up"
        case .phones: "iPhones"
        case .account: "Apple Account"
        case .relay: "Relay"
        case .debug: "Diagnostics"
        }
    }
    var symbol: String {
        switch self {
        case .setup: "sparkles"
        case .phones: "iphone.gen3"
        case .account: "person.crop.circle"
        case .relay: "point.3.connected.trianglepath.dotted"
        case .debug: "stethoscope"
        }
    }
}

/// Everything the windows show. All calls go through the bridge; nothing here talks to Apple.
@MainActor
final class AppModel: ObservableObject {
    @Published var page: Page = .setup
    @Published var info: AppInfo?
    @Published var account: AccountState?
    @Published var accountError: CoreError?
    @Published var teams: [Team] = []
    @Published var phones: [PhoneRow] = []
    @Published var phonesError: CoreError?
    @Published var selectedUDID: String?
    @Published var records: [Record] = []
    @Published var relay: Deployed?
    @Published var latest: Release?
    /// What the channel offers for Poki Setup itself; checked at launch and every six hours.
    @Published var update: UpdateInfo?
    @Published var installingUpdate = false
    /// The newer version the person was asked about (asked once per version).
    @Published var updatePrompt: String?
    private var updateTask: Task<Void, Never>?
    private var askedAbout: String?
    @Published var latestError: String?
    @Published var channels: [ChannelInfo] = []

    // Sign-in
    @Published var needsCode = false
    @Published var codeVia: String?

    // Jobs
    @Published var steps: [String: [StepItem]] = [:]
    @Published var busyJobs: Set<String> = []
    @Published var logLines: [String] = []

    /// A short message at the bottom of the window.
    @Published var banner: String?

    let bridge = Bridge.shared
    private var pollTask: Task<Void, Never>?
    private var keeperTask: Task<Void, Never>?
    let demo = ProcessInfo.processInfo.environment["POKI_SETUP_DEMO"] == "1"

    /// The one model, for the CI snapshot walk.
    static weak var current: AppModel?

    init() {
        AppModel.current = self
        bridge.onProgress = { [weak self] e in self?.apply(e) }
        bridge.onLogLines = { [weak self] lines in
            guard let self else { return }
            self.logLines.append(contentsOf: lines)
            if self.logLines.count > 5000 { self.logLines.removeFirst(self.logLines.count - 5000) }
        }
        bridge.onNeedsCode = { [weak self] in
            Task { @MainActor in await self?.promptForCode() }
        }
    }

    var selectedPhone: PhoneRow? {
        if let id = selectedUDID, let row = phones.first(where: { $0.id == id }) { return row }
        return phones.first
    }

    func start() {
        if demo {
            loadDemo()
            return
        }
        Task {
            info = try? await bridge.call("app_info")
            await refreshAccount()
            await refreshRecords()
            await refreshLatest()
            await refreshChannels()
            relay = try? await bridge.call("relay_state", as: Deployed?.self) ?? nil
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPhones()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        // Poki Setup's own updates: at launch and every six hours.
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self?.checkForUpdate(prompt: true)
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
        // Keep Poki signed: every six hours, renew what is due (needs the kept password).
        keeperTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.renewDue()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    // MARK: Poki Setup updates

    func checkForUpdate(prompt: Bool = false) async {
        if demo { return }
        guard let u: UpdateInfo = try? await bridge.call("check_update") else { return }
        update = u
        if prompt, u.newer, let v = u.latest, askedAbout != v {
            askedAbout = v
            updatePrompt = v
        }
    }

    /// Downloads the update, checks it, puts it in place of this app and quits; the new one opens
    /// by itself. When that is not possible the disk image opens in Finder instead.
    func installUpdate() async throws {
        installingUpdate = true
        defer { installingUpdate = false }
        let done: Installed = try await bridge.call("install_update")
        if done.relaunching {
            NSApp.terminate(nil)
        } else {
            banner = "Poki Setup could not replace itself here, so its update is open in Finder. Quit Poki Setup, then drag the new one into Applications."
        }
    }

    // MARK: Refresh

    func refreshAccount() async {
        if demo { return }
        do {
            let state: AccountState = try await bridge.call("account")
            account = state
            accountError = nil
            if state.pendingFactor != nil {
                codeVia = state.pendingFactor
                needsCode = true
            }
            if state.signedIn, teams.isEmpty {
                do {
                    teams = try await bridge.call("teams")
                } catch let e as CoreError where e.kind == "needs_code" {
                    await promptForCode()
                } catch {}
            }
        } catch let e as CoreError {
            accountError = e
        } catch {
            accountError = CoreError(kind: "error", message: error.localizedDescription)
        }
    }

    func promptForCode() async {
        guard !demo else { return }
        if let state: AccountState = try? await bridge.call("account") {
            account = state
            accountError = nil
            codeVia = state.pendingFactor
        }
        needsCode = true
    }

    func refreshPhones() async {
        if demo { return }
        if busyJobs.contains("install") || busyJobs.contains("pair") || busyJobs.contains("devmode") { return }
        do {
            let rows: [PhoneRow] = try await bridge.call("phones")
            if rows.map(\.id) != phones.map(\.id) || rows.map(\.facts) != phones.map(\.facts) {
                phones = rows
            }
            phonesError = nil
            if let id = selectedUDID, !rows.contains(where: { $0.id == id }) { selectedUDID = nil }
        } catch let e as CoreError {
            phonesError = e
            phones = []
        } catch {}
    }

    func refreshRecords() async {
        if demo { return }
        records = (try? await bridge.call("records")) ?? []
    }

    func refreshLatest() async {
        if demo { return }
        do {
            latest = try await bridge.call("latest_release")
            latestError = nil
        } catch {
            latest = nil
            latestError = error.localizedDescription
        }
    }

    var channel: ChannelInfo? { channels.first(where: \.selected) }

    func refreshChannels() async {
        if demo { return }
        if let c: [ChannelInfo] = try? await bridge.call("channels") { channels = c }
    }

    /// Saves the channel; installs, renewals and update checks follow it from now on.
    func setChannel(_ id: String) async throws {
        channels = try await bridge.call("set_channel", ["channel": id])
        await refreshLatest()
    }

    // MARK: Account

    func signIn(appleID: String, password: String, keep: Bool) async throws {
        let answer: SignInAnswer = try await bridge.call("sign_in", ["apple_id": appleID, "password": password, "keep_password": keep])
        if answer.needsCode {
            codeVia = answer.via
            needsCode = true
        } else {
            needsCode = false
            teams = []
            await refreshAccount()
        }
    }

    func finishSignIn(code: String) async throws {
        try await bridge.run("finish_sign_in", ["code": code])
        needsCode = false
        teams = []
        await refreshAccount()
    }

    func signOut() async {
        do {
            try await bridge.run("sign_out")
            teams = []
            needsCode = false
            await refreshAccount()
        } catch { report(error) }
    }

    func chooseTeam(_ team: Team) async {
        do {
            try await bridge.run("choose_team", ["team_id": team.teamId])
            await refreshAccount()
        } catch { report(error) }
    }

    func setAnisette(_ source: AnisetteSource) async throws {
        try await bridge.run("set_anisette", ["source": source.wire])
        await refreshAccount()
    }

    // MARK: Jobs

    private func apply(_ e: ProgressEvent) {
        var list = steps[e.job] ?? []
        func index() -> Int? { list.firstIndex(where: { $0.id == e.id }) }
        switch e.kind {
        case "step":
            for i in list.indices where list[i].state == .running || list[i].state == .waiting { list[i].state = .done }
            if let i = index() {
                list[i].state = .running
                list[i].title = e.title ?? list[i].title
            } else {
                list.append(StepItem(id: e.id, title: e.title ?? e.id))
            }
        case "part":
            if let i = index() {
                list[i].fraction = e.fraction
                if let d = e.detail { list[i].detail = d }
            }
        case "note":
            if let i = index(), let t = e.text { list[i].notes.append(t) }
        case "waiting":
            if let i = index() {
                list[i].state = .waiting
                list[i].detail = e.text
            } else {
                list.append(StepItem(id: e.id, title: e.text ?? e.id, state: .waiting))
            }
        case "done":
            if let i = index() {
                list[i].state = .done
                list[i].fraction = nil
                if let d = e.detail { list[i].detail = d }
            }
        default:
            break
        }
        steps[e.job] = list
    }

    /// Runs a long job: clears its steps, marks it busy, and marks the running step failed on error.
    func job<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        steps[name] = []
        busyJobs.insert(name)
        defer { busyJobs.remove(name) }
        do {
            return try await body()
        } catch {
            if var list = steps[name], let i = list.lastIndex(where: { $0.state != .done }) {
                list[i].state = .failed
                list[i].detail = error.localizedDescription
                steps[name] = list
            }
            throw error
        }
    }

    func install(udid: String, ipa: URL?, handOff: Bool) async throws -> InstallAnswer {
        let answer: InstallAnswer = try await job("install") {
            try await bridge.call("install", ["udid": udid, "ipa": ipa?.path, "hand_off": handOff])
        }
        await refreshRecords()
        await refreshPhones()
        return answer
    }

    func pair(udid: String) async throws {
        try await job("pair") { try await bridge.run("pair", ["udid": udid]) }
        await refreshPhones()
    }

    func enableDeveloperMode(udid: String) async throws {
        try await job("devmode") { try await bridge.run("devmode", ["udid": udid]) }
        await refreshPhones()
    }

    func renew(udid: String) async throws {
        let _: Record = try await job("renew") { try await bridge.call("renew", ["udid": udid]) }
        await refreshRecords()
    }

    func renewDue() async {
        guard !demo, account?.passwordKept == true else { return }
        let results = (try? await bridge.call("renew_due", as: [RenewResult].self)) ?? []
        if results.contains(where: { $0.kind == "needs_code" }) {
            await promptForCode()
        }
        await refreshRecords()
    }

    struct RenewResult: Decodable { var udid: String; var ok: Bool; var error: String?; var kind: String? }

    struct AgentPrompt: Decodable { var prompt: String }

    /// Puts the instructions for an agent on this Mac (Claude Code, Codex and the like) on the
    /// pasteboard; they name the command line tool inside this app.
    func copyAgentPrompt() async {
        do {
            let p: AgentPrompt = try await bridge.call("agent_prompt")
            copyToPasteboard(p.prompt)
            banner = "Copied. Paste it into your agent (Claude Code, Codex or another one that runs on this Mac)."
        } catch { report(error) }
    }

    /// The person chose Replace Certificate: the next install revokes the certificate the core
    /// named, and only that one.
    func approveCertificateReplacement() async throws {
        try await bridge.run("approve_certificate_replacement")
    }

    func forget(udid: String) async {
        do {
            try await bridge.run("forget_phone", ["udid": udid])
            await refreshRecords()
        } catch { report(error) }
    }

    func report(_ error: Error) {
        banner = error.localizedDescription
    }

    // MARK: Demo data (screenshots only: POKI_SETUP_DEMO=1)

    private func loadDemo() {
        info = AppInfo(version: "0.2.0", os: "macos", arch: "aarch64", dataDir: "~/Library/Application Support/nz.zheha.poki.setup", canUseSystemAnisette: true, defaultAnisette: "https://new.ani.sidestore.io", anisetteServers: ["https://new.ani.sidestore.io", "https://mac-ani.jkcoxson.com", "https://ani2.stikstore.app"])
        account = AccountState(signedIn: true, appleId: "jane.appleseed@icloud.com", name: "Jane Appleseed", teamId: "A1B2C3D4E5", passwordKept: true, anisette: .remote("https://new.ani.sidestore.io"), pendingFactor: nil)
        teams = [Team(teamId: "A1B2C3D4E5", name: "Jane Appleseed (Personal Team)", kind: "Individual", isFree: true)]
        let facts = Facts(udid: "00008150-000829EA2183C01C", name: "Jane's iPhone", productType: "iPhone18,1", ios: "26.1", build: "23B85", developerMode: true, pairedWithThisComputer: true, canPairOnDevice: false, wifiAddress: "192.168.1.23")
        let now = Int(Date().timeIntervalSince1970)
        let rec = Record(udid: facts.udid, phoneName: facts.name, ios: facts.ios, appleId: "jane.appleseed@icloud.com", teamId: "A1B2C3D4E5", teamName: "Jane Appleseed (Personal Team)", teamIsFree: true, bundleId: "nz.zheha.poki.A1B2C3D4E5", appGroup: "group.nz.zheha.poki.A1B2C3D4E5", version: "0.2.8", build: "64", releaseTag: "local:Poki-0.2.8-external-unsigned.ipa", signedAt: now - 2 * 86_400, profileExpiresAt: now + 5 * 86_400, lastCheckedAt: now - 3600, lastError: nil, wifiAddress: "192.168.1.23", pairingHandedOff: false)
        phones = [PhoneRow(phone: PhoneRef(udid: facts.udid), facts: facts, error: nil, record: rec)]
        records = [rec]
        relay = Deployed(accountId: "abc", accountName: "Jane's account", address: "https://poki-relay.jane.workers.dev", firstDeploy: false, deployedAt: now - 86_400, phoneLink: "poki://setup?relay=https://poki-relay.jane.workers.dev")
        latest = Release(tag: "ios-v0.2.8", version: "0.2.8", build: "64", ipaName: "Poki-external-0.2.8-64.ipa", channel: "beta")
        channels = [
            ChannelInfo(id: "stable", title: "Stable", selected: true, latest: nil),
            ChannelInfo(id: "beta", title: "Beta", selected: false, latest: latest),
            ChannelInfo(id: "alpha", title: "Alpha", selected: false, latest: Release(tag: "ios-alpha-0.2.8-110", version: "0.2.8", build: "110", ipaName: "Poki-external-0.2.8-110.ipa", channel: "alpha")),
            ChannelInfo(id: "pre-alpha", title: "Pre-alpha", selected: false, latest: Release(tag: "ios-prealpha-0.2.8-260", version: "0.2.8", build: "260", ipaName: "Poki-external-0.2.8-260.ipa", channel: "pre-alpha")),
        ]
        steps["install"] = [
            StepItem(id: "phone", title: "Finding the iPhone", state: .done, detail: facts.name),
            StepItem(id: "pair", title: "Pairing with the iPhone", state: .done),
            StepItem(id: "account", title: "Checking the Apple Account", state: .done, detail: "Personal Team"),
            StepItem(id: "sign", title: "Signing Poki for Jane Appleseed", state: .running, fraction: 0.62, detail: "Signing PokiWidgets.appex"),
        ]
    }
}
