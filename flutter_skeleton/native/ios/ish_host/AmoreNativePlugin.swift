//
//  AmoreNativePlugin.swift
//  ISHHost pod — the real implementation behind the `amore/native` channel.
//
//  This is the piece that was missing when the Flutter shell only had the
//  static libraries: it boots the iSH kernel against a rootfs on disk and runs
//  guest commands through ISHShellExecutor.
//

import Flutter
import Foundation

public final class AmoreNativePlugin: NSObject, FlutterPlugin {
    private static let bootLock = NSLock()
    private static var bootAttempted = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "amore/native",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(AmoreNativePlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            result(true)

        case "sandbox.status":
            result(Self.statusPayload())

        case "sandbox.exec":
            guard let args = call.arguments as? [String: Any],
                  let command = args["command"] as? String, !command.isEmpty else {
                result(FlutterError(code: "bad_args", message: "command required", details: nil))
                return
            }
            Self.exec(command, result: result)

        case "fileProvider.register":
            result(nil)

        case "liveActivity.set":
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Rootfs

    /// `Documents/alpine-rootfs` — the layout RootfsManager uses in the app.
    private static var rootfsPath: String {
        let docs = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true
        ).first ?? NSTemporaryDirectory()
        return (docs as NSString).appendingPathComponent("alpine-rootfs")
    }

    private static func rootfsIsInstalled() -> Bool {
        let fm = FileManager.default
        let data = (rootfsPath as NSString).appendingPathComponent("data")
        let meta = (rootfsPath as NSString).appendingPathComponent("meta.db")
        return fm.fileExists(atPath: data) && fm.fileExists(atPath: meta)
    }

    // MARK: - Kernel

    private static func statusPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "available": true,
            "booted": ISHKernel.shared.isBooted,
            "rootfsPath": rootfsPath,
        ]
        if !rootfsIsInstalled() {
            payload["error"] = "rootfs not installed"
        } else if !ISHKernel.shared.isBooted {
            let code = ISHKernel.shared.boot(withRootPath: rootfsPath)
            payload["booted"] = ISHKernel.shared.isBooted
            if code != 0 { payload["error"] = "boot failed (\(code))" }
        }
        return payload
    }

    private static func exec(_ command: String, result: @escaping FlutterResult) {
        bootLock.lock()
        let installed = rootfsIsInstalled()
        if installed && !ISHKernel.shared.isBooted {
            _ = ISHKernel.shared.boot(withRootPath: rootfsPath)
        }
        let booted = ISHKernel.shared.isBooted
        bootLock.unlock()

        guard installed, booted else {
            result(FlutterError(
                code: "sandbox_unavailable",
                message: installed ? "kernel not booted" : "rootfs not installed",
                details: nil
            ))
            return
        }

        // Execute off the main thread; the executor reports back on main.
        DispatchQueue.global(qos: .userInitiated).async {
            let r = ISHShellExecutor.executeCommandSync(command, timeout: 30, lineCallback: nil)
            DispatchQueue.main.async {
                result([
                    "exitCode": Int(r.exitCode),
                    "stdout": r.output,
                    "stderr": r.errorOutput,
                ])
            }
        }
    }
}
