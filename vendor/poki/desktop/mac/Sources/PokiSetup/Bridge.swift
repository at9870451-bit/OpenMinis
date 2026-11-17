import Foundation

/// An error from the core: `kind` is stable (`apple`, `needs_person`, `usbmuxd`, `device`, ...),
/// `message` is for people.
struct CoreError: LocalizedError, Equatable {
    var kind: String
    var message: String
    var errorDescription: String? { message }
}

/// Talks to `poki-setup-bridge`, the Rust core behind a pipe. One JSON object per line each way.
@MainActor
final class Bridge {
    static let shared = Bridge()

    /// Progress events, as the core sends them (`job`, `kind`, `id`, ...).
    var onProgress: ((ProgressEvent) -> Void)?
    var onLogLines: (([String]) -> Void)?
    var onNeedsCode: (() -> Void)?
    /// The helper's own log (stderr), for the Debug page.
    private(set) var helperLog: [String] = []

    private var process: Process?
    private var input: FileHandle?
    private var nextID: UInt64 = 1
    private var waiting: [UInt64: CheckedContinuation<Data, Error>] = [:]
    private var outBuffer = Data()
    private var errBuffer = Data()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// The helper sits next to the app's executable; `POKI_SETUP_BRIDGE` overrides it for development.
    private func helperURL() -> URL? {
        if let path = ProcessInfo.processInfo.environment["POKI_SETUP_BRIDGE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        if let url = Bundle.main.url(forAuxiliaryExecutable: "poki-setup-bridge") {
            return url
        }
        let beside = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("poki-setup-bridge")
        if let beside, FileManager.default.isExecutableFile(atPath: beside.path) {
            return beside
        }
        return nil
    }

    private func ensureRunning() throws {
        if let p = process, p.isRunning { return }
        guard let url = helperURL() else {
            throw CoreError(kind: "bridge", message: "Poki Setup is missing its helper (poki-setup-bridge). Reinstall the app.")
        }
        let p = Process()
        p.executableURL = url
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            // The main queue keeps chunks in order (a Task per chunk might not).
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consumeOut(data) } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consumeErr(data) } }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.helperEnded(status) }
        }
        try p.run()
        process = p
        input = inPipe.fileHandleForWriting
    }

    private func helperEnded(_ status: Int32) {
        process = nil
        input = nil
        let pending = waiting
        waiting = [:]
        for (_, c) in pending {
            c.resume(throwing: CoreError(kind: "bridge", message: "Poki Setup's helper stopped (status \(status)). Try again."))
        }
        helperLog.append("[helper ended with status \(status)]")
    }

    private func consumeErr(_ data: Data) {
        guard !data.isEmpty else { return }
        errBuffer.append(data)
        while let nl = errBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: errBuffer[errBuffer.startIndex..<nl], as: UTF8.self)
            errBuffer.removeSubrange(errBuffer.startIndex...nl)
            helperLog.append(line)
            if helperLog.count > 2000 { helperLog.removeFirst(helperLog.count - 2000) }
        }
    }

    private func consumeOut(_ data: Data) {
        guard !data.isEmpty else { return }
        outBuffer.append(data)
        while let nl = outBuffer.firstIndex(of: 0x0A) {
            let line = Data(outBuffer[outBuffer.startIndex..<nl])
            outBuffer.removeSubrange(outBuffer.startIndex...nl)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let event = obj["event"] as? String {
            switch event {
            case "progress":
                if let d = obj["data"], let raw = try? JSONSerialization.data(withJSONObject: d), let p = try? decoder.decode(ProgressEvent.self, from: raw) {
                    onProgress?(p)
                }
            case "log_lines":
                if let lines = obj["data"] as? [String] { onLogLines?(lines) }
            default:
                break
            }
            return
        }
        guard let idNum = obj["id"] as? NSNumber else { return }
        let id = idNum.uint64Value
        guard let c = waiting.removeValue(forKey: id) else { return }
        if let err = obj["err"] as? [String: Any] {
            let kind = err["kind"] as? String ?? "error"
            let message = err["message"] as? String ?? "Something went wrong."
            if kind == "needs_code" { onNeedsCode?() }
            c.resume(throwing: CoreError(kind: kind, message: message))
        } else {
            let value = obj["ok"] ?? NSNull()
            let raw = (try? JSONSerialization.data(withJSONObject: ["v": value])) ?? Data("{\"v\":null}".utf8)
            c.resume(returning: raw)
        }
    }

    private struct Wrapped<T: Decodable>: Decodable { let v: T }

    /// Runs a core command. `args` values may be `nil` (left out).
    func call<T: Decodable>(_ cmd: String, _ args: [String: Any?] = [:], as type: T.Type = T.self) async throws -> T {
        try ensureRunning()
        let id = nextID
        nextID += 1
        var clean: [String: Any] = [:]
        for (k, v) in args {
            if let v { clean[k] = v }
        }
        let req: [String: Any] = ["id": id, "cmd": cmd, "args": clean]
        var line = try JSONSerialization.data(withJSONObject: req)
        line.append(0x0A)
        let raw: Data = try await withCheckedThrowingContinuation { c in
            waiting[id] = c
            do {
                try input?.write(contentsOf: line)
            } catch {
                waiting.removeValue(forKey: id)
                c.resume(throwing: CoreError(kind: "bridge", message: "Could not reach Poki Setup's helper: \(error.localizedDescription)"))
            }
        }
        do {
            return try decoder.decode(Wrapped<T>.self, from: raw).v
        } catch {
            throw CoreError(kind: "bridge", message: "Poki Setup could not read the helper's answer to \(cmd): \(error)")
        }
    }

    /// For commands whose answer does not matter.
    func run(_ cmd: String, _ args: [String: Any?] = [:]) async throws {
        _ = try await call(cmd, args, as: AnyDecodable?.self)
    }
}

/// Decodes anything and keeps nothing.
struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}
