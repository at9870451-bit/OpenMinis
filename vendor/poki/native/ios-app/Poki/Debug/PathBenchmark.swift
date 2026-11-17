import PokiNative
import Foundation
import PokiCore
import UIKit

/// The same requests through Poki Runner and through Poki's own process, interleaved round by round:
/// tap the probe field, type the sample, swipe, read (tree and screenshot). Each is timed from the
/// request to its answer, with PokiCore's `Runner` as the client on both sides, and checked: the tap
/// by the field taking the focus, the text by reading the field, the read by the field being in the
/// tree and a picture coming back. The swipe is only timed. Results go to Poki's log, the system log
/// and Documents/path-benchmark.json.
extension InProcessProbe {
    struct Sample {
        var path: String
        var action: String
        var ms: Double
        var ok: Bool
        var note: String
    }

    func benchmark(model: AppModel, rounds: Int) async {
        guard begin("compare paths, \(rounds) rounds") else { return }
        defer { end() }
        guard await prepare(), let field else { return }
        var paths: [(String, Runner)] = [("in-process", Runner(url: URL(string: "http://127.0.0.1:8100")!, transport: InProcessWDA()))]
        if model.automationPath == .runner {
            if !model.runner.isRunning { model.wakeRunner() }
            let by = Date().addingTimeInterval(60)
            while !model.runner.isRunning, Date() < by { try? await Task.sleep(for: .seconds(0.5)) }
            if model.runner.isRunning {
                paths.insert(("runner", Runner(url: URL(string: "http://127.0.0.1:8100")!)), at: 0)
            } else {
                note("runner: not running after 60 s (\(model.runner.title)); only the in-process path is measured", ["step": "runner_missing"])
            }
        } else {
            note("Poki started with the in-process path, so the runner is not measured", ["step": "runner_skipped"])
        }
        var samples: [Sample] = []
        for round in 1...rounds {
            for (name, runner) in paths {
                for sample in await onePass(name, runner, field) {
                    samples.append(sample)
                    note("\(round) \(sample.path) \(sample.action): \(Int(sample.ms.rounded())) ms, \(sample.ok ? "ok" : "failed")\(sample.note.isEmpty ? "" : " (\(sample.note))")",
                         ["step": "sample", "round": round, "path": sample.path, "action": sample.action, "ms": sample.ms, "ok": sample.ok, "note": sample.note])
                }
            }
        }
        for (name, _) in paths {
            for action in ["tap", "type", "swipe", "read"] {
                let mine = samples.filter { $0.path == name && $0.action == action }
                let times = mine.map(\.ms).sorted()
                let median = times.isEmpty ? 0 : (times.count % 2 == 1 ? times[times.count / 2] : (times[times.count / 2 - 1] + times[times.count / 2]) / 2)
                let failed = mine.filter { !$0.ok }.count
                note("summary \(name) \(action): median \(Int(median.rounded())) ms, \(mine.count - failed)/\(mine.count) ok, \(times.map { String(Int($0.rounded())) }.joined(separator: " ")) ms",
                     ["step": "summary", "path": name, "action": action, "median_ms": median, "ok": mine.count - failed, "count": mine.count, "ms": times])
            }
        }
    }

    /// The front app's tree read once by Poki Runner and once by Poki's own process, a moment apart and
    /// with the same request, kept as Documents/inprocess-source.xml and Documents/runner-source.xml; a second
/// in-process read after the runner's shows whether the screen changed in between.
    func sourceBothPaths(model: AppModel) async {
        guard begin("source through both paths") else { return }
        defer { end() }
        guard await prepare() else { return }
        guard model.automationPath == .runner else {
            note("Poki started with the in-process path; start it with -automationPath runner to read through the runner too", ["step": "runner_skipped"])
            return
        }
        if !model.runner.isRunning { model.wakeRunner() }
        let by = Date().addingTimeInterval(60)
        while !model.runner.isRunning, Date() < by { try? await Task.sleep(for: .seconds(0.5)) }
        guard model.runner.isRunning else {
            note("runner: not running after 60 s (\(model.runner.title))", ["step": "runner_missing"])
            return
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "In-process probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        let seconds = Double(delay) ?? 8
        note("runner up; waiting \(Int(seconds)) s; bring the app to read to the front", ["step": "wait", "seconds": seconds])
        try? await Task.sleep(for: .seconds(seconds))
        let url = URL(string: "http://127.0.0.1:8100")!
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let own = Runner(url: url, transport: InProcessWDA())
        for (name, runner) in [("inprocess", own), ("runner", Runner(url: url)), ("inprocess-after", own)] {
            let front = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in queue.async { c.resume(returning: PKInProcess.shared().frontApp()) } }
            note("before \(name): front \(front["bundleId"] as? String ?? "?"), Poki \(UIApplication.shared.applicationState == .active ? "in front" : "in the background")",
                 ["step": "front", "path": name, "bundle": front["bundleId"] as? String ?? "", "active": UIApplication.shared.applicationState == .active])
            var xml = ""
            let (ms, error) = await timed {
                xml = try await runner.call("GET", "/source?format=xml&excluded_attributes=visible,accessible,enabled,index", timeout: 30).string ?? ""
            }
            try? xml.write(to: documents.appendingPathComponent("\(name)-source.xml"), atomically: true, encoding: .utf8)
            note("\(name) source: \(xml.count) characters in \(Int(ms.rounded())) ms\(error.map { " (\($0))" } ?? "")",
                 ["step": "source", "path": name, "characters": xml.count, "ms": ms, "error": error ?? ""])
        }
    }

    private func timed(_ work: () async throws -> Void) async -> (Double, String?) {
        let start = ProcessInfo.processInfo.systemUptime
        do { try await work(); return ((ProcessInfo.processInfo.systemUptime - start) * 1000, nil) }
        catch { return ((ProcessInfo.processInfo.systemUptime - start) * 1000, "\(error)") }
    }

    private func onePass(_ name: String, _ runner: Runner, _ field: UITextField) async -> [Sample] {
        var out: [Sample] = []
        field.text = ""
        field.resignFirstResponder()
        try? await Task.sleep(for: .seconds(0.5))
        let frame = field.convert(field.bounds, to: nil)

        let (tapMs, tapError) = await timed { _ = try await runner.call("POST", "/wda/tap", ["x": .number(Double(frame.midX)), "y": .number(Double(frame.midY))], timeout: 5) }
        try? await Task.sleep(for: .seconds(0.6))
        out.append(Sample(path: name, action: "tap", ms: tapMs, ok: tapError == nil && field.isFirstResponder, note: tapError ?? (field.isFirstResponder ? "" : "field not focused")))

        let text = Self.sample
        let (typeMs, typeError) = await timed { _ = try await runner.call("POST", "/wda/keys", ["value": .array(text.map { .string(String($0)) })], timeout: 8) }
        try? await Task.sleep(for: .seconds(0.5))
        let same = field.text == text
        out.append(Sample(path: name, action: "type", ms: typeMs, ok: typeError == nil && same, note: typeError ?? (same ? "" : "field holds \(field.text?.count ?? 0) characters")))
        field.resignFirstResponder()
        try? await Task.sleep(for: .seconds(0.4))

        // Finger down from near the top: the list is at its top, so it springs back.
        let (swipeMs, swipeError) = await timed {
            _ = try await runner.call("POST", "/wda/pressAndDragWithVelocity", ["fromX": 201, "fromY": 300, "toX": 201, "toY": 480, "pressDuration": 0, "holdDuration": 0.1, "velocity": 800], timeout: 5, countsAsMiss: false)
        }
        try? await Task.sleep(for: .seconds(0.8))
        out.append(Sample(path: name, action: "swipe", ms: swipeMs, ok: swipeError == nil, note: swipeError ?? ""))

        var found = false, pictureBytes = 0
        let (readMs, readError) = await timed {
            async let tree = runner.call("GET", "/source?format=xml&excluded_attributes=visible,accessible,enabled,index", timeout: 8)
            async let picture = runner.raw("GET", "/screenshot", timeout: 8)
            let (t, p) = try await (tree, picture)
            found = t.string?.contains("inprocess-field") == true
            pictureBytes = p.string.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }?.count ?? 0
        }
        out.append(Sample(path: name, action: "read", ms: readMs, ok: readError == nil && found && pictureBytes > 0, note: readError ?? "tree has the field: \(found), picture \(pictureBytes) bytes"))
        return out
    }
}
