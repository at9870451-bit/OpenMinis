import Foundation

/// What the user has done in setup, kept across launches.
struct SetupState: Codable, Equatable {
    /// `inProcess` uses an already-mounted DDI without a VPN; `builtIn` uses the
    /// app's NetworkExtension tunnel, and `proxy` keeps external compatibility.
    enum Loopback: String, Codable { case none, builtIn, proxy, inProcess }
    var pairingFile: String?
    var developerMode = false
    var uiAutomation = false
    var passcodeNoted = false
    var loopback: Loopback = .none
    var proxyApp: String?
    var runnerInstalled = false

    init() {}
    // Field by field, so a setup saved by an older version keeps what it has.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairingFile = try c.decodeIfPresent(String.self, forKey: .pairingFile)
        developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
        uiAutomation = try c.decodeIfPresent(Bool.self, forKey: .uiAutomation) ?? false
        passcodeNoted = try c.decodeIfPresent(Bool.self, forKey: .passcodeNoted) ?? false
        loopback = (try? c.decodeIfPresent(Loopback.self, forKey: .loopback)) ?? Loopback.none
        proxyApp = try c.decodeIfPresent(String.self, forKey: .proxyApp)
        runnerInstalled = try c.decodeIfPresent(Bool.self, forKey: .runnerInstalled) ?? (pairingFile != nil)
    }

    /// Preferences first; after a reinstall (a sideloaded app that was deleted and installed again,
    /// or a signing tool that could not keep the container), the copy in the Keychain, which outlives
    /// the app's container as long as the same team signs it. See `SetupVault`.
    static func load() -> SetupState {
        if let data = UserDefaults.standard.data(forKey: "setup"), let state = try? JSONDecoder().decode(SetupState.self, from: data) { return state }
        if let data = SetupVault.readSetup(), let state = try? JSONDecoder().decode(SetupState.self, from: data) {
            UserDefaults.standard.set(data, forKey: "setup")
            return state
        }
        return SetupState()
    }
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: "setup")
        SetupVault.storeSetup(data)
    }
}

/// Copies of the pairing file and the setup state in the Keychain, so an update, a reinstall or a
/// re-sign by a sideloading tool does not send the owner through setup again. Keychain items stay
/// when the app is deleted; they are readable only by an app signed by the same team, and only on
/// this device (`ThisDeviceOnly`, never in a backup that moves to another phone).
enum SetupVault {
    private static let pairingAccount = "setup.pairing"
    private static let setupAccount = "setup.state"

    static func storeSetup(_ data: Data) { try? Keychain.write(data, account: setupAccount) }
    static func readSetup() -> Data? { try? Keychain.read(setupAccount) }

    static func storePairing(_ data: Data) { try? Keychain.write(data, account: pairingAccount) }

    /// The pairing file is back in the container when the container lost it and the Keychain has it.
    /// Returns true when it was restored.
    @discardableResult static func restorePairingIfMissing() -> Bool {
        let file = AppFiles.pairingFile
        guard !FileManager.default.fileExists(atPath: file.path), let data = try? Keychain.read(pairingAccount), !data.isEmpty else { return false }
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }

    /// A pairing file put in the container from outside (Poki Setup on a computer writes it there
    /// over house_arrest) is mirrored too, so it survives a reinstall like one Poki took itself.
    static func mirrorPairingFromContainer() {
        guard let data = try? Data(contentsOf: AppFiles.pairingFile), !data.isEmpty else { return }
        if (try? Keychain.read(pairingAccount)) != data { storePairing(data) }
    }

    static func forget() { Keychain.delete(pairingAccount); Keychain.delete(setupAccount) }
}

enum AppFiles {
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AmorePoki", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// The pairing file lives in the app's container with complete-until-first-unlock protection, so
    /// the launcher can read it in the background after the first unlock.
    static var pairingFile: URL { support.appendingPathComponent("pairing.plist") }
    /// A copy of the pairing made on this iPhone (RPPairing). Poki Setup's hand-off writes its own
    /// lockdown record over pairing.plist, and on iOS 27 that record does not open the loopback; this
    /// copy is used first.
    static var phonePairingFile: URL { support.appendingPathComponent("pairing-phone.plist") }
    static var ddiDirectory: URL {
        let url = support.appendingPathComponent("ddi", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// The setup steps, in the order a new user does them. The Apple Account is not one (ESP-222): Poki
/// Setup on a Mac signs and installs Poki, so signing in on the phone is optional, in Signing Options.
enum SetupStep: String, CaseIterable, Identifiable {
    case runner, developerMode, loopback, pairing, automation, background
    var id: String { rawValue }

    /// The steps this launch shows: the in-process path has no Poki Runner to install.
    /// Poki automates the phone itself (ESP-152): step text names Poki, not Poki Runner.
    static var inProcess: Bool { AutomationPath.current == .inProcess }

    static var shown: [SetupStep] { AutomationPath.current == .inProcess ? allCases.filter { $0 != .runner } : Array(allCases) }

    /// Pairing on the phone itself (Settings > Privacy & Security > Developer Mode > Pair) exists from
    /// iOS 27. Earlier versions get their pairing file from a computer (Poki Setup), by AirDrop, a
    /// link or Files; the pairing step shows only what this iPhone can do.
    static var onDevicePairing: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    var title: String {
        switch self {
        case .runner: "Install Poki Runner"
        case .developerMode: "Turn on Developer Mode"
        case .loopback: "Connect to this iPhone"
        case .pairing: "Pair this iPhone"
        case .automation: "Allow UI Automation"
        case .background: "Let Poki stay on"
        }
    }

    var symbol: String {
        switch self {
        case .runner: "square.and.arrow.down.on.square"
        case .developerMode: "hammer"
        case .loopback: "arrow.triangle.2.circlepath"
        case .pairing: "link"
        case .automation: "hand.tap"
        case .background: "location"
        }
    }

    var summary: String {
        switch self {
        case .runner: "The helper app that taps and types for your agent. Poki starts it; you never open it."
        case .developerMode: Self.inProcess ? "Lets Poki use this iPhone’s developer services." : "Lets this iPhone run Poki Runner."
        case .loopback: "Use Poki's local connection, or a compatible VPN app you already have."
        case .pairing: Self.onDevicePairing ? "Gives Poki its own key to this iPhone. Made and kept on the phone, no computer needed." : "Gives Poki its own key to this iPhone. On this iOS version the key is made on a computer with Poki Setup, then sent here."
        case .automation: Self.inProcess ? "Lets Poki use other apps." : "Lets Poki Runner use other apps."
        case .background: "Keeps Poki connected while it is in the background, and shows what it does on the Lock Screen."
        }
    }

    /// One line for the Live Activity while the person is in Settings.
    var hint: String {
        switch self {
        case .runner: "Install Poki Runner, then trust it: Settings > General > VPN & Device Management."
        case .developerMode: "Settings > Privacy & Security > Developer Mode. Turn it on, restart, then tap Turn On."
        case .loopback: "In Poki's Setup, enable the local connection or choose an external connection."
        case .pairing: Self.onDevicePairing ? "Settings > Privacy & Security > Developer Mode > Pair with Poki, then type the code shown here." : "Pair from Poki Setup on your computer, then send the pairing file to this iPhone."
        case .automation: "Settings > Developer > Enable UI Automation."
        case .background: "Allow location While Using the App, and keep Live Activities on."
        }
    }
}

extension SetupStep {
    /// The step as the Live Activity's content line, in English (the face words it in the system's
    /// language): a name, not what to do, which the setup screen says.
    var activityTitle: String {
        switch self {
        case .runner: "Poki Runner"
        case .developerMode: "Developer Mode"
        case .loopback: "Loopback"
        case .pairing: "Pairing"
        case .automation: "UI Automation"
        case .background: "Background"
        }
    }
}

/// One of the agent's recent actions, for the home screen.
struct RecentStep: Identifiable, Equatable {
    let id = UUID()
    var text: String
    /// The app it happened in, as PokiCore names it.
    var app: String?
    /// Why it did not go through: PokiCore's delivery, "failed: nothing changed".
    var failure: String?
    var ok: Bool { failure == nil }
    var at: Date
}
