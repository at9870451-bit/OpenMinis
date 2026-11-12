//
//  NativeBridge.swift
//  Amore — method channel used by the Flutter UI layer.
//
//  This file is NOT compiled into the bare Flutter runner. It is the contract
//  to drop into the retained OpenMinis Swift project (the host that still owns
//  iSH, FileProvider, Share, Widget and Live Activity) once the Flutter shell
//  replaces the SwiftUI screens.
//
//  Channel: "amore/native"
//  Every method must answer even when the subsystem is not ready — the Dart
//  side treats an exception as "unavailable", never as a crash.
//

import Flutter
import UIKit

public final class NativeBridge: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "amore/native",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(NativeBridge(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            result(true)

        case "sandbox.status":
            // Wire to RootfsManager / ISHKernel in the host project.
            result([
                "available": true,
                "booted": false,
                "rootfsPath": NSSearchPathForDirectoriesInDomains(
                    .documentDirectory, .userDomainMask, true
                ).first.map { "\($0)/alpine-rootfs" } as Any,
            ])

        case "sandbox.exec":
            guard let args = call.arguments as? [String: Any],
                  let command = args["command"] as? String else {
                result(FlutterError(code: "bad_args", message: "command required", details: nil))
                return
            }
            // Wire to ISHExecutionCoordinator exactly as the SwiftUI composer did.
            result("not implemented yet: \(command)")

        case "fileProvider.register":
            // Wire to NSFileProviderManager.add(domain) from MinisApp.swift.
            result(nil)

        case "liveActivity.set":
            // Wire to the ActivityKit controller.
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
