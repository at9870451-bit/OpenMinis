import Foundation

// MARK: - JS sandbox (JavaScriptCore)

import JavaScriptCore

enum AmoreJSPluginError: LocalizedError {
    case notLoaded
    case toolNotFound(String)
    case permissionDenied(String)
    case timedOut
    case disabledAfterTimeouts
    case thrown(String)
    case badResult

    var errorDescription: String? {
        switch self {
        case .notLoaded: return AppLocalized("Plugin is not loaded")
        case .toolNotFound(let n): return "\(AppLocalized("Plugin has no tool named")): \(n)"
        case .permissionDenied(let p): return "\(AppLocalized("Permission denied")): \(p)"
        case .timedOut: return AppLocalized("Plugin timed out")
        case .disabledAfterTimeouts: return AppLocalized("Plugin disabled after repeated timeouts")
        case .thrown(let m): return m
        case .badResult: return AppLocalized("Plugin returned an unexpected value")
        }
    }
}

/// One VM + one context per plugin. `eval`/`Function` are removed before the
/// plugin body runs, and the host object exposes only what the manifest asked
/// for. Calls are main-actor bound because JSContext is not thread safe.
@MainActor
final class AmoreJSPluginHost {
    struct Limits {
        var callTimeout: TimeInterval = 30
        var maxConsecutiveTimeouts = 3
        var maxHTTPBodyBytes = 5 * 1024 * 1024
    }

    let pluginID: String
    private let permissions: Set<String>
    private let limits: Limits
    private let vm = JSVirtualMachine()
    private var context: JSContext?
    private(set) var consecutiveTimeouts = 0
    private(set) var isDisabled = false

    init(pluginID: String, permissions: [String], limits: Limits = Limits()) {
        self.pluginID = pluginID
        self.permissions = Set(permissions)
        self.limits = limits
    }

    /// Loads the IIFE bundle. Returns the tool names it declared.
    @discardableResult
    func load(source: String) throws -> [String] {
        guard let ctx = JSContext(virtualMachine: vm) else { throw AmoreJSPluginError.notLoaded }
        ctx.exceptionHandler = { _, exception in
            NSLog("[plugin:%@] uncaught: %@", self.pluginID as NSString, (exception?.toString() ?? "?") as NSString)
        }
        // Sandbox hardening: no dynamic code execution.
        ctx.evaluateScript("""
        delete globalThis.eval;
        delete globalThis.Function;
        globalThis.amore = globalThis.amore || {};
        """)
        installHostBridge(into: ctx)
        ctx.evaluateScript(source)
        if let exception = ctx.exception {
            throw AmoreJSPluginError.thrown(exception.toString() ?? "load failed")
        }
        context = ctx
        let names = ctx.evaluateScript("Object.keys(globalThis.plugin && globalThis.plugin.tools || {})")
        return names?.toArray() as? [String] ?? []
    }

    func call(tool: String, argumentsJSON: String) throws -> String {
        guard !isDisabled else { throw AmoreJSPluginError.disabledAfterTimeouts }
        guard let ctx = context else { throw AmoreJSPluginError.notLoaded }
        guard let tools = ctx.evaluateScript("Object.keys(globalThis.plugin && globalThis.plugin.tools || {})")?.toArray() as? [String],
              tools.contains(tool) else {
            throw AmoreJSPluginError.toolNotFound(tool)
        }

        let started = Date()
        ctx.setObject(argumentsJSON as NSString, forKeyedSubscript: "__amore_args" as NSString)
        ctx.setObject(tool as NSString, forKeyedSubscript: "__amore_tool" as NSString)
        let result = ctx.evaluateScript("""
        (function () {
          var plugin = globalThis.plugin;
          if (!plugin || !plugin.tools || !plugin.tools[__amore_tool]) { throw new Error("missing tool"); }
          var args = JSON.parse(__amore_args || "{}");
          var out = plugin.tools[__amore_tool](args, { pluginId: "\(pluginID)" });
          return JSON.stringify(out === undefined ? null : out);
        })()
        """)
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > limits.callTimeout {
            // JS cannot be preempted from Swift; drop the VM so the runaway
            // script can never run again, and count it as a timeout.
            context = nil
            consecutiveTimeouts += 1
            if consecutiveTimeouts >= limits.maxConsecutiveTimeouts {
                isDisabled = true
            }
            throw AmoreJSPluginError.timedOut
        }
        consecutiveTimeouts = 0
        if let exception = ctx.exception {
            throw AmoreJSPluginError.thrown(exception.toString() ?? "runtime error")
        }
        guard let value = result?.toString() else { throw AmoreJSPluginError.badResult }
        return value
    }

    // MARK: Host bridge

    private func installHostBridge(into ctx: JSContext) {
        // log
        let logBlock: @convention(block) (String, String) -> Void = { level, message in
            NSLog("[plugin:%@][%@] %@", self.pluginID as NSString, level as NSString, message as NSString)
        }
        ctx.setObject(logBlock, forKeyedSubscript: "__amore_log" as NSString)
        ctx.evaluateScript("""
        globalThis.amore = globalThis.amore || {};
        globalThis.amore.log = {
          info: function (m) { __amore_log("info", String(m)); },
          error: function (m) { __amore_log("error", String(m)); }
        };
        """)

        // storage (isolated per plugin, 1 MB quota)
        let storageDir = AmorePluginInstaller.shared.pluginsRoot
            .appendingPathComponent(pluginID, isDirectory: true)
            .appendingPathComponent("storage", isDirectory: true)
        let storageBlock: @convention(block) (String, String, String) -> String = { op, key, value in
            AmoreJSPluginStorage.perform(op: op, key: key, value: value, directory: storageDir)
        }
        ctx.setObject(storageBlock, forKeyedSubscript: "__amore_storage" as NSString)
        ctx.evaluateScript("""
        globalThis.amore.storage = {
          get: function (k) { return __amore_storage("get", String(k), ""); },
          set: function (k, v) { return __amore_storage("set", String(k), String(v)); },
          remove: function (k) { return __amore_storage("remove", String(k), ""); }
        };
        """)

        // network: https only, host must be in network:<host> allow-list
        let allowedHosts = permissions.compactMap { permission -> String? in
            guard permission.hasPrefix("network:") else { return nil }
            return String(permission.dropFirst("network:".count)).lowercased()
        }
        let netBlock: @convention(block) (String) -> String = { urlString in
            guard let url = URL(string: urlString),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  allowedHosts.contains(host)
            else { return "" }
            return AmoreJSPluginHTTP.fetchSync(url: url, maxBytes: 5 * 1024 * 1024)
        }
        ctx.setObject(netBlock, forKeyedSubscript: "__amore_fetch" as NSString)
        ctx.evaluateScript("""
        globalThis.amore.http = {
          fetch: function (url) {
            var body = __amore_fetch(String(url));
            if (!body) { throw new Error("network denied or empty response"); }
            return body;
          }
        };
        """)
    }
}

/// Key/value store for plugin data: one JSON file per plugin, hard-capped.
enum AmoreJSPluginStorage {
    static let maxBytes = 1024 * 1024

    static func perform(op: String, key: String, value: String, directory: URL) -> String {
        guard !key.isEmpty else { return "" }
        let fm = FileManager.default
        let file = directory.appendingPathComponent("store.json")
        var dict: [String: String] = [:]
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            dict = decoded
        }
        switch op {
        case "get":
            return dict[key] ?? ""
        case "set":
            var candidate = dict
            candidate[key] = value
            let encoded = (try? JSONEncoder().encode(candidate)) ?? Data()
            guard encoded.count <= maxBytes else { return "" }
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? encoded.write(to: file, options: .atomic)
            dict = candidate
            return "ok"
        case "remove":
            dict.removeValue(forKey: key)
            if let encoded = try? JSONEncoder().encode(dict) {
                try? encoded.write(to: file, options: .atomic)
            }
            return "ok"
        default:
            return ""
        }
    }
}

/// Minimal synchronous HTTPS GET used by the JS bridge.
enum AmoreJSPluginHTTP {
    static func fetchSync(url: URL, maxBytes: Int) -> String {
        var payload: String = ""
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "GET"
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data, data.count <= maxBytes,
                  let text = String(data: data, encoding: .utf8) else { return }
            payload = text
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return payload
    }
}
