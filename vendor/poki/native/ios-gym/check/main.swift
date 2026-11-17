// The Poki Gym scorecard on the runner path: GymScorecard (one file with the in-process path in the
// app) driven through PokiCore's MCP handler, as the agent calls it, against a real WebDriverAgent
// on the iOS Simulator. Built in CI as an executable target of the PokiCore package (the gym
// workflow copies check/*.swift in).
import Foundation
#if os(macOS)
import PokiCore
import ImageIO
import UniformTypeIdentifiers

setvbuf(stdout, nil, _IOLBF, 0)

/// Runs a shell command and returns its output (simctl, the WDA restart script).
@discardableResult func sh(_ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

let environment = ProcessInfo.processInfo.environment
let url = URL(string: environment["POKI_WDA_URL"] ?? "http://127.0.0.1:8100")!
let udid = environment["UDID"] ?? "booted"

final class Host: CoreHost, @unchecked Sendable {
    struct NoKey: Error {}
    func signingKey() throws -> RelayKey { throw NoKey() }
    func accessHashes() -> [String] { [] }
    func jpeg(fromPNG png: Data, width: Int, quality: Double) throws -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: width * 3] as CFDictionary) else { throw NoKey() }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw NoKey() }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return out as Data
    }
    func runnerState() -> RunnerState { .running }
    /// The simulator's own screenshot, as the launcher's DVT screenshot on a phone: a path to a
    /// picture that a wedged app cannot block.
    func screenshotWithoutRunner() async -> Data? {
        let path = NSTemporaryDirectory() + "poki-gym-\(UUID().uuidString).png"
        let began = Date()
        sh(["xcrun", "simctl", "io", udid, "screenshot", path])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let data = FileManager.default.contents(atPath: path)
        print("host: simctl screenshot \(data.map { "\($0.count / 1024) KB" } ?? "nothing") in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
        return data
    }
    /// As the app's launcher: PokiCore asks once the runner stops answering; the start script brings
    /// WebDriverAgent back (POKI_WDA_START), at most once every 20 s.
    private let lock = NSLock()
    private var lastRestart = Date.distantPast
    func restartRunner() {
        guard let script = environment["POKI_WDA_START"] else { return }
        let due = lock.withLock { () -> Bool in
            guard Date().timeIntervalSince(lastRestart) > 20 else { return false }
            lastRestart = Date(); return true
        }
        guard due else { return }
        print("host: restarting the runner with \(script)")
        DispatchQueue.global().async { print(sh(["bash", script])) }
    }
}

let core = PokiCore(config: CoreConfig(runnerURL: url), host: Host())
var session: String?

/// One MCP request to PokiCore's handler, exactly as the relay delivers an agent's.
@MainActor func rpc(_ method: String, _ params: JSON) async -> JSON? {
    let body: JSON = ["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params]
    let reply = await core.handle(RelayRequest(id: "1", method: "POST", headers: session.map { ["mcp-session-id": $0] } ?? [:], body: body.serialized()))
    if session == nil { session = reply.headers["mcp-session-id"] }
    return try? JSON.parse(reply.body)
}

@MainActor func makeScorecard() -> GymScorecard {
    let approver = GymApprover { id, approved in core.resolveApproval(id: id, approved: approved) }
    // The owner's side of approvals: the Live Activity's buttons, here answered by the approver.
    Task { @MainActor in
        for await event in core.events {
            if case .approvalRequested(let approval) = event {
                print("host: approval asked: \(approval.summary) (\(approval.reason))")
                approver.requested(id: approval.id)
            }
        }
    }
    var env = GymEnvironment(call: { name, args in
        let reply = await rpc("tools/call", ["name": .string(name), "arguments": args])
        guard let reply else { return ("no answer", []) }
        let text = reply["result"]?["content"]?[0]?["text"]?.string ?? "no answer: \(reply.serialized())"
        let pictures = (reply["result"]?["content"]?.array ?? []).filter { $0["type"]?.string == "image" }.compactMap { $0["data"]?.string.flatMap { Data(base64Encoded: $0) } }
        return (text, pictures)
    }, log: { print($0) })
    env.pictures = environment["POKI_PICTURES"].map { URL(fileURLWithPath: $0) }
    env.shell = { args in await Task.detached { sh(args) }.value }
    env.udid = udid
    env.runnerBundle = environment["WDA_BUNDLE"] ?? "com.facebook.WebDriverAgentRunner.xctrunner"
    env.canRestartRunner = environment["POKI_WDA_START"] != nil
    env.rawTree = {
        guard let raw = try? await URLSession.shared.data(from: url.appendingPathComponent("source").appending(queryItems: [URLQueryItem(name: "format", value: "xml")])).0 else { return nil }
        return (try? JSON.parse(raw))?["value"]?.string
    }
    env.installed = { bundle in await Task.detached { sh(["xcrun", "simctl", "listapps", udid]).contains("\"\(bundle)\"") }.value }
    env.approveNext = { approver.next($0) }
    env.path = "runner"
    return GymScorecard(env: env)
}

let scorecard = await makeScorecard()

_ = await rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": .object([:]), "clientInfo": ["name": "poki-gym-check", "version": "1"]])
await scorecard.run()
let report = await scorecard.report
print(report)
exit(await scorecard.failures.isEmpty ? 0 : 1)
#else
print("the gym scorecard runs on macOS")
#endif
