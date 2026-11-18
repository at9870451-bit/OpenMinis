import Foundation
import SwiftUI

/// Shared by Node installation and destructive rootfs UI actions. A disabled
/// button alone cannot protect a confirmation dialog already on screen.
final class RootfsOperationGate: @unchecked Sendable {
    static let shared = RootfsOperationGate()
    private let lock = NSLock()
    private var busy = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }

    func end() {
        lock.lock()
        busy = false
        lock.unlock()
    }
}

/// No bundled packages, staging, version pins, or implicit installation.
/// Only the confirmed AOJIT action calls this service.
@MainActor
final class NodeOnlineRuntime: ObservableObject {
    static let shared = NodeOnlineRuntime()
    @Published private(set) var isInstalling = false
    @Published private(set) var isReady = false

    func install() async throws -> String {
        guard !isInstalling, RootfsOperationGate.shared.begin() else {
            throw Self.failure(AppLocalized("Another container operation is running."))
        }
        isInstalling = true
        isReady = false
        defer {
            isInstalling = false
            RootfsOperationGate.shared.end()
        }
        guard ISHKernel.shared.isBooted, !RootfsManager.shared.didResetWhileBooted else {
            throw Self.failure(AppLocalized("The Shell Container is not running yet. Open the terminal once, then try again."))
        }
        let mirrors = MirrorSpeedTestViewModel.shared
        if mirrors.isActive(for: .alpine), !mirrors.applyMirror(for: .alpine) {
            throw Self.failure(AppLocalized("Could not apply the selected Alpine mirror. Nothing was installed."))
        }
        // Existing trusted APK keys and the effective, selected repositories
        // are authoritative. Do not bypass signature checks or force changes.
        let command = """
        set -eu
        apk update
        apk add nodejs npm
        node --version
        npm --version
        npx --version
        node -e 'const a=require("node:assert/strict"); a.equal(2+2,4); a.equal(require("node:crypto").createHash("sha256").update("amore").digest("hex").length,64)'
        printf '\\nAMORE_NODE_ONLINE_READY\\n'
        """
        let (executionOK, exitCode, log) = await Task.detached(priority: .userInitiated) {
            let result = ISHShellExecutor.executeCommandSync(command + " 2>&1", timeout: 900, lineCallback: nil)
            let log = result.output + (result.errorOutput.isEmpty ? "" : "\n" + result.errorOutput)
            return (result.error == .none, result.exitCode, log)
        }.value
        guard executionOK, exitCode == 0,
              log.split(separator: "\n").contains("AMORE_NODE_ONLINE_READY") else {
            throw Self.failure(AppLocalized("Online Node installation or runtime verification failed.") + "\n" + String(log.suffix(2400)))
        }
        isReady = true
        return AppLocalized("Node.js, npm and npx ran successfully. AOJIT build matching is checked separately.") + "\n" + String(log.suffix(1600))
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Amore.NodeOnlineRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
