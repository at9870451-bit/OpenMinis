import Foundation
import Combine
import AmorePluginArchive

struct AmorePendingPluginImport: Identifiable, Sendable {
    let id = UUID()
    let prepared: PreparedPluginArchive
    let manifest: AmorePluginManifest
}

/// Owns the import's effects; Views only present the picker and permission sheet.
@MainActor
final class AmorePluginImportStore: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var phaseText = ""
    @Published private(set) var installed: [AmoreInstalledPlugin] = []
    @Published var pending: AmorePendingPluginImport?
    @Published var resultMessage: String?
    @Published private(set) var failed = false
    private var importTask: Task<Void, Never>?
    private var confirmedSelection: AmorePendingPluginImport?

    func selected(_ url: URL, folder: Bool) {
        guard !isWorking else { return }
        isWorking = true
        failed = false
        phaseText = AppLocalized("Reading and validating plugin…")
        importTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try PluginArchive.prepare(from: url, folder: folder)
                }.value
                do {
                    let manifest = try JSONDecoder().decode(AmorePluginManifest.self, from: prepared.manifestData)
                    _ = try AmorePluginValidation.validate(manifest)
                    self.pending = AmorePendingPluginImport(prepared: prepared, manifest: manifest)
                } catch {
                    await Task.detached { PluginArchive.discard(prepared) }.value
                    throw error
                }
            } catch {
                failed = true
                resultMessage = Self.userMessage(for: error)
            }
            isWorking = false
        }
    }

    func confirm() {
        guard let selection = pending, !isWorking else { return }
        confirmedSelection = selection
        pending = nil
    }

    func confirmationDismissed() {
        guard let selection = confirmedSelection else { return }
        confirmedSelection = nil
        isWorking = true
        phaseText = AppLocalized("Installing plugin…")
        Task {
            do {
                let record = try await AmorePluginInstaller.shared.installPrepared(
                    selection.prepared, approvedPermissions: selection.manifest.permissions)
                installed = try await AmorePluginInstaller.shared.installedPlugins()
                failed = false
                resultMessage = AppLocalized("Installed") + ": " + record.id + " " + record.version
                    + "\n" + AppLocalized("Installed disabled. No plugin code was executed.")
            } catch {
                failed = true
                resultMessage = Self.userMessage(for: error)
            }
            await Task.detached { PluginArchive.discard(selection.prepared) }.value
            isWorking = false
        }
    }

    func cancel() {
        guard let selection = pending else { return }
        pending = nil
        Task { await Task.detached { PluginArchive.discard(selection.prepared) }.value }
    }

    func pickerFailed(_ error: Error) {
        failed = true
        resultMessage = error.localizedDescription
    }

    func refreshInstalled() async {
        do { installed = try await AmorePluginInstaller.shared.installedPlugins() }
        catch { failed = true; resultMessage = error.localizedDescription }
    }

    func uninstall(_ record: AmoreInstalledPlugin) {
        Task {
            do {
                try await AmorePluginInstaller.shared.uninstall(id: record.id)
                await refreshInstalled()
            } catch {
                failed = true
                resultMessage = error.localizedDescription
            }
        }
    }

    private static func userMessage(for error: Error) -> String {
        if case DecodingError.keyNotFound(let key, _) = error {
            return AppLocalized("Invalid manifest.json. Missing field") + ": " + key.stringValue
        }
        if error is DecodingError { return AppLocalized("manifest.json does not match the Amore plugin format.") }
        guard let archive = error as? PluginArchiveError else { return error.localizedDescription }
        switch archive {
        case .missingManifest: return AppLocalized("No manifest.json found in this plugin package.")
        case .multipleManifests: return AppLocalized("Multiple plugins found. Import one plugin package at a time.")
        case .tooLarge: return AppLocalized("Plugin package exceeds 10 MB.")
        case .tooManyFiles: return AppLocalized("Plugin package exceeds 500 files.")
        case .unsafePath(let path): return AppLocalized("Unsafe path in plugin package") + ": " + path
        case .checksum(let path): return AppLocalized("ZIP checksum failed") + ": " + path
        case .invalid(let detail):
            if detail == "Selected file is not a ZIP archive" { return AppLocalized("Selected file is not a ZIP archive") }
            if detail == "Choose a ZIP file or a plugin folder" { return AppLocalized("Choose a ZIP file or a plugin folder") }
            return AppLocalized("Invalid plugin package") + ": " + detail
        }
    }
}
