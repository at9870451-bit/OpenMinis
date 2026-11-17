import PokiNative
import Foundation
import PokiCore

/// The developer disk image the launcher mounts, kept in the app's container. PokiCore's
/// DeveloperDiskImage downloads it once from the public mirror and checks every file against the
/// SHA-384 digests in its BuildManifest.plist; this tracks the state for the setup screen.
@MainActor
@Observable
final class DiskImageStore {
    enum State: Equatable { case missing, downloading(String), downloaded(String), ready(String), failed(String) }
    private(set) var state: State = .missing
    private(set) var isChecking = false
    private var checkTask: Task<Void, Never>?
    private var checkToken = UUID()
    static let unavailableMessage: LocalizedStringResource = "The disk image is downloaded, but its developer tools are not available on this iPhone. Try turning Automation on. If it still fails, connect to a computer and prepare this iPhone again in Poki Setup."
    static let loadFailureMessage: LocalizedStringResource = "Poki could not load the developer tools. Connect this iPhone to a computer and prepare it again in Poki Setup, then reopen Poki and turn Automation on."
    static let downloadFailureMessage: LocalizedStringResource = "Failed to download the developer disk image. Make sure your network can reach GitHub (turn on a proxy or a global VPN), then tap Download Again. You can also write it from Poki Setup on your computer."

    init(verifySynchronously: Bool = false) {
        if verifySynchronously {
            if let build = try? DeveloperDiskImage.verify(AppFiles.ddiDirectory) { record(build) }
        } else {
            startCheck(clearIfMissing: false)
        }
    }

    private func startCheck(clearIfMissing: Bool) {
        let token = UUID()
        checkToken = token
        isChecking = true
        checkTask = Task { [weak self] in
            await self?.verifyInBackground(token: token, clearIfMissing: clearIfMissing)
        }
    }

    func ensureChecked() async {
        if let checkTask {
            await checkTask.value
            return
        }
        if case .missing = state {
            startCheck(clearIfMissing: false)
            await checkTask?.value
        }
    }

    func recheckInBackground() async -> Bool {
        if let checkTask {
            await checkTask.value
            return hasFiles
        }
        startCheck(clearIfMissing: true)
        await checkTask?.value
        return hasFiles
    }

    private func verifyInBackground(token: UUID, clearIfMissing: Bool) async {
        defer {
            if checkToken == token {
                checkTask = nil
                isChecking = false
            }
        }
        let dir = AppFiles.ddiDirectory
        let result = await Task.detached(priority: .userInitiated) { () -> (build: String, ready: Bool)? in
            guard let build = try? DeveloperDiskImage.verify(dir) else { return nil }
            let ready = PKInProcess.shared().developerFrameworksAvailable()
            return (build, ready)
        }.value
        guard !Task.isCancelled, checkToken == token else { return }
        if case .downloading = state { return }
        if let result {
            state = result.ready ? .ready(result.build) : .downloaded(result.build)
        } else if clearIfMissing || hasFiles {
            state = .missing
        }
    }

    /// Files that appeared since (Poki Setup puts them in the container): counted without downloading.
    func notice() {
        if case .ready = state { return }
        if case .downloading = state { return }
        guard checkTask == nil, !isChecking else { return }
        startCheck(clearIfMissing: false)
    }

    func refreshAvailability() {
        guard case .downloaded(let build) = state else { return }
        Task { [weak self] in
            let ready = await Task.detached(priority: .userInitiated) {
                PKInProcess.shared().developerFrameworksAvailable()
            }.value
            guard let self, case .downloaded(let current) = self.state, current == build, ready else { return }
            self.state = .ready(build)
        }
    }

    private func record(_ build: String) {
        state = PKInProcess.shared().developerFrameworksAvailable() ? .ready(build) : .downloaded(build)
    }

    /// Checks the files again (they can be damaged or removed); false starts a fresh download.
    func recheck() -> Bool {
        if let build = try? DeveloperDiskImage.verify(AppFiles.ddiDirectory) { record(build); return true }
        state = .missing
        Task { await download() }
        return false
    }

    /// The phone would not install the image: delete it and download it again.
    func redownload() {
        if case .downloading = state { return }
        checkTask?.cancel()
        checkTask = nil
        checkToken = UUID()
        isChecking = false
        try? FileManager.default.removeItem(at: AppFiles.ddiDirectory)
        state = .missing
        Task { await download() }
    }

    var isReady: Bool { if case .ready = state { return true } else { return false } }
    var hasFiles: Bool {
        switch state {
        case .ready, .downloaded: true
        default: false
        }
    }

    func download() async {
        if case .downloading = state { return }
        await ensureChecked()
        if hasFiles { return }
        if case .downloading = state { return }
        state = .downloading("Starting…")
        do {
            let build = try await DeveloperDiskImage.ensure(in: AppFiles.ddiDirectory) { step in
                Task { @MainActor [weak self] in if case .downloading = self?.state { self?.state = .downloading(step) } }
            }
            let ready = await Task.detached(priority: .userInitiated) {
                PKInProcess.shared().developerFrameworksAvailable()
            }.value
            state = ready ? .ready(build) : .downloaded(build)
        } catch {
            state = .failed(AppLocalization.text(Self.downloadFailureMessage))
        }
    }
}
