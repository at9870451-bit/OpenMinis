// Standalone, opt-in: swift scripts/Amore135AvatarPipelineTests.swift [repo-root]
// No UIKit build, model/API call, UserDefaults write, photos, or network.
// Pure logic is extracted from SHIPPING source and compiled in a child Swift
// process (not a mirrored implementation). This script is not wired into CI.
import Foundation

var failures = 0
func check(_ name: String, _ passes: Bool) {
    print("\(passes ? "PASS" : "FAIL") \(name)")
    if !passes { failures += 1 }
}
let root = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
func read(_ relative: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
}
func between(_ source: String, _ start: String, _ end: String) -> String {
    guard let a = source.range(of: start),
          let b = source.range(of: end, range: a.upperBound..<source.endIndex) else {
        check("source markers: \(start)", false); return ""
    }
    return String(source[a.upperBound..<b.lowerBound])
}
func ordered(_ source: String, _ needles: [String]) -> Bool {
    var remaining = source.startIndex..<source.endIndex
    for needle in needles {
        guard let range = source.range(of: needle, range: remaining) else { return false }
        remaining = range.upperBound..<source.endIndex
    }
    return true
}
let soul = try read("src/ios/Agent/Session/SoulStore.swift")
let settings = try read("src/ios/Views/Settings/SoulSettingsView.swift")
let config = try read("src/ios/Shared/Config/ConfigRegistry+Builtins.swift")
let bridge = try read("src/ios/NativeOffloads/ConfigOffloadBridge.swift")
let prompt = try read("src/ios/Agent/Chat/AIChatViewModel+SystemPrompt.swift")
let help = try read("src/ios/NativeOffloads/ModelUseOffload.m")
let models = try read("src/ios/NativeOffloads/ModelUseOffloadBridge.swift")

check("resolve → confirm → approve → field write", ordered(bridge, [
    "SoulIconSource.resolveToDataURI(rawIcon)",
    "ConfigConfirmationGate.shared.requestConfirmation(pending)",
    "case .approved(let approvedRows):", "try field.write(newValue)"
]))
check("failure and cancellation are explicit", ["validation_failed", "user_rejected", "timeout", "permission_denied"].allSatisfy { bridge.contains($0) })
check("confirmation/audit redact image bytes", bridge.contains("auditNewValue = .string(\"<image>\")") && bridge.contains("displayNew = \"<image>\""))
check("icon remains a sensitive, non-revertable SoulStore field", between(config, "path: \"soul.icon\",", "path: \"soul.lang\",").contains("risk: .sensitive") && between(config, "path: \"soul.icon\",", "path: \"soul.lang\",").contains("revertable: false"))
check("write uses single SoulStore + notification after disk write", ordered(soul, ["static func save(_ file: SoulFile)", "persistIconSidecar(file.metadata.icon)", "try text.data(using: .utf8)?.write", "cachedMetadata = file.metadata", "post(name: .soulMdChanged"]))
check("bounded sources and canonical PNG retain existing limits", ["maxSourceBytes = 8 * 1024 * 1024", "maxStoredChars = 64 * 1024", "renderPoints: CGFloat = 32", "storedPixels: CGFloat = renderPoints * 3", "downloadTimeout: TimeInterval = 15", "SoulIconImage.encode(image)"].allSatisfy { soul.contains($0) })
check("initial URL and redirects share gate BEFORE following", ordered(soul, ["try validateRemoteURL(url)", "session.bytes(for: req, delegate: delegate)", "willPerformHTTPRedirection", "SoulIconSource.validateRemoteURL(url)", "completionHandler(nil)", "completionHandler(request)"]))
check("download caps headers and streamed bytes, not post-buffer only", soul.contains("response.expectedContentLength <= Int64(maxSourceBytes)") && soul.contains("data.count < maxSourceBytes") && !soul.contains("session.data(for: req)"))
check("ephemeral download has no ambient credentials/cookies/cache", ["URLSessionConfiguration.ephemeral", "cfg.httpCookieStorage = nil", "cfg.httpShouldSetCookies = false", "cfg.urlCredentialStorage = nil", "cfg.urlCache = nil"].allSatisfy { soul.contains($0) })
check("minis URL containment also resolves symlinks", between(soul, "private static func readMinisURL", "private static func readLocalPath").contains("containingAllowedRoot(for: fileURL)") && soul.contains("standardizedFileURL.resolvingSymlinksInPath()"))
check("public-looking host limit honestly discloses DNS limitation", config.contains("not complete DNS-rebinding protection"))
check("mode uses one AppStorage string enum and confirmation", config.contains("path: \"appearance.companionMode\"") && config.contains("userDefaultsKey: AmoreCompanionMode.storageKey") && config.contains("cases: AmoreCompanionMode.allCases.map") && settings.contains("@AppStorage(AmoreCompanionMode.storageKey)"))
check("design action only posts editable prompt, never writes", between(settings, "private func requestAvatarDesign()", "private var personalityEditor").contains("post(name: .amoreRequestAvatarDesign") && !between(settings, "private func requestAvatarDesign()", "private var personalityEditor").contains("SoulStore.save"))
check("public notification and String payload contract", soul.contains("Notification.Name(\"AmoreRequestAvatarDesign\")") && soul.contains("static let promptKey = \"prompt\"") && settings.contains("userInfo: [AmoreAvatarDesignRequest.promptKey: AmoreAvatarDesignRequest.prompt]"))
check("manual picker and live preview remain explicit", settings.contains(".photosPicker(isPresented: $showPhotoPicker") && settings.contains("SoulIconView(icon: icon") && settings.contains("AmoreAvatarPreview(side:") && settings.contains("icon = parsed.metadata.icon"))
check("picker source size gate matches Agent limit", settings.contains("data.count <= SoulIconSource.maxSourceBytes"))
check("Agent/help advertise only configured image-output models + native gate", [prompt, help, config].allSatisfy { $0.contains("image_output") && $0.contains("minis://settings/model-groups") && $0.contains("soul.icon") && $0.contains("confirmation") })
check("image output extension is modality checked before request", ordered(models, ["Self.isImageExtension(outputExt0) && !modalities.contains(.imageOutput)", "required: \"image_output\"", "let wantsImageOutput = modalities.contains(.imageOutput)"]))

// Compile the actual host gate, URL validation, mode and request value.
let hostBody = between(soul, "static func isBlockedHost(_ host: String) -> Bool {", "    private static func isProbablyBareBase64")
let remoteBody = between(soul, "static func validateRemoteURL(_ url: URL) throws {", "    private final class DownloadDelegate")
let modeBody = between(soul, "enum AmoreCompanionMode: String, CaseIterable {", "/// Settings emits only an editable chat request")
let requestBody = between(soul, "enum AmoreAvatarDesignRequest {", "extension Notification.Name {")
let pure = """
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
var failed = 0
func check(_ label: String, _ ok: Bool) {
    print("\\(ok ? "PASS" : "FAIL") pure: \\(label)")
    if !ok { failed += 1 }
}
enum Gate {
    enum SourceError: Error { case badURL(String), blockedHost(String) }
    static func isBlockedHost(_ host: String) -> Bool {
\(hostBody)
    static func validateRemoteURL(_ url: URL) throws {
\(remoteBody)
}
enum AmoreCompanionMode: String, CaseIterable {
\(modeBody)
enum AmoreAvatarDesignRequest {
\(requestBody)
for host in ["localhost", "LOCALHOST.", "x.local", "x.localhost", "service.internal", "router.home.arpa", "intranet", "127.0.0.1", "127.1", "2130706433", "0177.0.0.1", "0x7f000001", "0.0.0.0", "10.0.0.1", "172.16.0.1", "192.168.0.1", "169.254.169.254", "100.64.1.1", "198.18.0.1", "224.0.0.1", "255.255.255.255", "::", "::1", "[::1]", "::ffff:127.0.0.1", "::ffff:c0a8:1", "fe80::1", "fd00::1", "ff02::1", "64:ff9b::7f00:1", "2002:7f00:1::", "2001:0000::1"] {
    check("blocks \\(host)", Gate.isBlockedHost(host))
}
for host in ["example.com", "cdn.example.org", "fc-assets.example.com", "8.8.8.8", "1.1.1.1", "172.32.0.1", "2606:4700:4700::1111", "2001:4860:4860::8888"] {
    check("allows \\(host)", !Gate.isBlockedHost(host))
}
for text in ["https://localhost/icon.png", "https://127.1/icon.png", "https://user:pass@example.com/a.png", "file:///tmp/a.png", "ftp://example.com/a.png"] {
    let accepted = URL(string: text).map { (try? Gate.validateRemoteURL($0)) != nil } ?? false
    check("rejects URL \\(text)", !accepted)
}
check("allows ordinary HTTPS URL", (try? Gate.validateRemoteURL(URL(string: "https://example.com/a.png")!)) != nil)
check("mode default and invalid fallback", AmoreCompanionMode.resolved("bad") == .auto)
check("mode key", AmoreCompanionMode.storageKey == "amore.companion.mode")
for mode in AmoreCompanionMode.allCases {
    check("empty icon falls back in \\(mode)", !mode.usesCustomIcon(""))
    check("saved icon respects \\(mode)", mode.usesCustomIcon("data:image/png;base64,abc") == (mode != .robot))
}
check("prompt is nonempty and guarded", AmoreAvatarDesignRequest.promptKey == "prompt" && AmoreAvatarDesignRequest.prompt.contains("image_output") && AmoreAvatarDesignRequest.prompt.contains("minis-config set soul.icon"))
exit(failed == 0 ? 0 : 1)
"""
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Amore135Avatar-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let pureFile = temp.appendingPathComponent("Pure.swift")
try pure.write(to: pureFile, atomically: true, encoding: .utf8)
let child = Process()
child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
child.arguments = ["swift", pureFile.path]
try child.run()
child.waitUntilExit()
check("shipping pure-source logic compiles and passes", child.terminationStatus == 0)
print("Avatar pipeline: \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
exit(failures == 0 ? 0 : 1)
