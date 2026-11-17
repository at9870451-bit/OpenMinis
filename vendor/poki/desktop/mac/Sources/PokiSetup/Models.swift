import Foundation

// The shapes the core answers with (snake_case on the wire, camelCase here).

struct AppInfo: Decodable {
    var version: String
    var os: String
    var arch: String
    var dataDir: String
    var canUseSystemAnisette: Bool
    var defaultAnisette: String
    var anisetteServers: [String]
}

struct AnisetteSource: Codable, Equatable {
    var kind: String
    var url: String?

    static func remote(_ url: String) -> AnisetteSource { AnisetteSource(kind: "remote", url: url) }
    static let system = AnisetteSource(kind: "system", url: nil)

    var wire: [String: Any] {
        var d: [String: Any] = ["kind": kind]
        if let url { d["url"] = url }
        return d
    }
}

struct AccountState: Decodable {
    var signedIn: Bool
    var appleId: String?
    var name: String?
    var teamId: String?
    var passwordKept: Bool
    var anisette: AnisetteSource
    var pendingFactor: String?
}

struct SignInAnswer: Decodable {
    var needsCode: Bool
    var via: String?
}

struct Team: Decodable, Identifiable, Hashable {
    var teamId: String
    var name: String
    var kind: String
    var isFree: Bool
    var id: String { teamId }
}

struct PhoneRef: Decodable {
    var udid: String
}

struct Facts: Decodable, Equatable {
    var udid: String
    var name: String
    var productType: String
    var ios: String
    var build: String
    var developerMode: Bool?
    var pairedWithThisComputer: Bool
    var canPairOnDevice: Bool
    var wifiAddress: String?
}

struct Record: Decodable, Identifiable, Equatable {
    var udid: String
    var phoneName: String
    var ios: String
    var appleId: String
    var teamId: String
    var teamName: String
    var teamIsFree: Bool
    var bundleId: String
    var appGroup: String
    var version: String
    var build: String
    var releaseTag: String
    var signedAt: Int
    var profileExpiresAt: Int
    var lastCheckedAt: Int?
    var lastError: String?
    var wifiAddress: String?
    var pairingHandedOff: Bool
    var id: String { udid }

    var expires: Date { Date(timeIntervalSince1970: TimeInterval(profileExpiresAt)) }
    var daysLeft: Int { Int(floor(expires.timeIntervalSinceNow / 86_400)) }
    var isExpired: Bool { expires <= Date() }
}

struct PhoneRow: Decodable, Identifiable {
    var phone: PhoneRef
    var facts: Facts?
    var error: String?
    var record: Record?
    var id: String { phone.udid }
    var title: String { facts?.name ?? "iPhone" }
}

struct Handoff: Decodable, Equatable {
    var link: String
    var inlineLink: String
    var url: String
    var host: String
    var port: Int
}

struct InstallAnswer: Decodable {
    var record: Record
    var notes: [String]
    var handoff: Handoff?
}

struct Deployed: Decodable, Equatable {
    var accountId: String
    var accountName: String
    var address: String
    var firstDeploy: Bool
    var deployedAt: Int
    var phoneLink: String
    var workerSha256: String? = nil
    var workerSource: String? = nil
}

/// Which relay Poki Setup deploys now, and whether yours is older (`relay_worker`).
struct WorkerStatus: Decodable {
    var source: String
    var downloadUrl: String
    var guideUrl: String
    var sha256: String
    var deployedSha256: String?
    var updateAvailable: Bool
}

struct CloudflareAccount: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
}

struct Check: Decodable, Equatable {
    var at: Int
    var ok: Bool
    var relayOk: Bool
    var phoneOnline: Bool
    var tools: [String]
    var detail: String
}

struct Connector: Decodable, Identifiable, Equatable {
    var name: String
    var url: String
    var addedAt: Int
    var lastCheck: Check?
    var id: String { url }
}

struct Snippet: Decodable, Identifiable {
    var name: String
    var text: String
    var id: String { name }
}

struct UpdateInfo: Decodable {
    var current: String
    var latest: String?
    var url: String?
    var newer: Bool
}

struct Installed: Decodable {
    var path: String
    var relaunching: Bool
}

struct Release: Decodable {
    var tag: String
    var version: String
    var build: String
    var ipaName: String
    /// "stable", "beta", "alpha" or "pre-alpha".
    var channel: String? = nil
}

/// A release channel and its newest release (`channels`, `set_channel`).
struct ChannelInfo: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var selected: Bool
    var latest: Release?

    static func == (a: ChannelInfo, b: ChannelInfo) -> Bool { a.id == b.id && a.selected == b.selected && a.latest?.tag == b.latest?.tag }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// One progress event from a long job (`install`, `pair`, `renew`, `relay`, ...).
struct ProgressEvent: Decodable {
    var job: String
    var kind: String
    var id: String
    var title: String?
    var fraction: Double?
    var detail: String?
    var text: String?
}

/// A step of a long job, as the UI shows it.
struct StepItem: Identifiable, Equatable {
    enum State: Equatable { case running, waiting, done, failed }
    var id: String
    var title: String
    var state: State = .running
    var fraction: Double?
    var detail: String?
    var notes: [String] = []
}
