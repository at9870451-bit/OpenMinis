import Foundation
import Combine
import AmorePluginArchive

struct AmorePendingPluginImport: Identifiable, Sendable {
    let id = UUID()
    let prepared: PreparedPluginArchive
    let manifest: AmorePluginManifest
}

struct AmorePluginConfigurationSelection: Identifiable, Sendable {
    let id = UUID()
    let inspected: InspectedPluginArchive
}

/// Owns import effects. JSON is configuration data, not executable JavaScript.
@MainActor
final class AmorePluginImportStore: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var phaseText = ""
    @Published private(set) var installed: [AmoreInstalledPlugin] = []
    @Published var configurations: AmorePluginConfigurationSelection?
    @Published var pending: AmorePendingPluginImport?
    @Published var resultMessage: String?
    @Published private(set) var failed = false
    private var importTask: Task<Void, Never>?
    private var chosenConfiguration: (InspectedPluginArchive, PluginConfigurationCandidate)?
    private var confirmedSelection: AmorePendingPluginImport?

    func selected(_ url: URL, folder: Bool) {
        guard !isWorking else { return }
        isWorking = true
        failed = false
        phaseText = AppLocalized("Reading and validating plugin…")
        importTask = Task { [weak self] in
            guard let self else { return }
            do {
                let inspected = try await Task.detached(priority: .userInitiated) {
                    try PluginArchive.inspect(from: url, folder: folder)
                }.value
                if inspected.candidates.count > 1 {
                    configurations = AmorePluginConfigurationSelection(inspected: inspected)
                } else if let candidate = inspected.candidates.first {
                    await prepareConfiguration(inspected, candidate: candidate)
                } else {
                    await Task.detached { PluginArchive.discard(inspected) }.value
                    throw PluginArchiveError.missingManifest
                }
            } catch { report(error) }
            isWorking = false
        }
    }

    func chooseConfiguration(_ candidate: PluginConfigurationCandidate) {
        guard let selection = configurations, !isWorking else { return }
        chosenConfiguration = (selection.inspected, candidate)
        configurations = nil
    }

    func configurationDismissed() {
        guard let (inspected, candidate) = chosenConfiguration else { return }
        chosenConfiguration = nil
        isWorking = true
        Task {
            await prepareConfiguration(inspected, candidate: candidate)
            isWorking = false
        }
    }

    func cancelConfiguration() {
        guard let selection = configurations else { return }
        configurations = nil
        Task { await Task.detached { PluginArchive.discard(selection.inspected) }.value }
    }

    private func prepareConfiguration(_ inspected: InspectedPluginArchive,
                                      candidate: PluginConfigurationCandidate) async {
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try PluginArchive.prepare(inspected, configuration: candidate)
            }.value
            let manifest = try JSONDecoder().decode(AmorePluginManifest.self, from: prepared.manifestData)
            _ = try AmorePluginValidation.validate(manifest)
            pending = AmorePendingPluginImport(prepared: prepared, manifest: manifest)
        } catch {
            await Task.detached { PluginArchive.discard(inspected) }.value
            report(error)
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
            } catch { report(error) }
            await Task.detached { PluginArchive.discard(selection.prepared) }.value
            isWorking = false
        }
    }

    func cancel() {
        guard let selection = pending else { return }
        pending = nil
        Task { await Task.detached { PluginArchive.discard(selection.prepared) }.value }
    }

    func pickerFailed(_ error: Error) { report(error) }

    func refreshInstalled() async {
        do { installed = try await AmorePluginInstaller.shared.installedPlugins() }
        catch { report(error) }
    }

    func uninstall(_ record: AmoreInstalledPlugin) {
        Task {
            do {
                try await AmorePluginInstaller.shared.uninstall(id: record.id)
                await refreshInstalled()
            } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        failed = true
        resultMessage = Self.userMessage(for: error)
    }

    static func userMessage(for error: Error) -> String {
        if case DecodingError.keyNotFound(let key, _) = error {
            return AppLocalized("Invalid plugin JSON. Missing field") + ": " + key.stringValue
        }
        if error is DecodingError { return AppLocalized("The selected JSON does not match the Amore plugin format.") }
        guard let archive = error as? PluginArchiveError else { return error.localizedDescription }
        switch archive {
        case .unsupportedPackage(let name, let runtime):
            return AppLocalized("Incompatible plugin package") + ": " + name + "\n"
                + AppLocalized("Required host or runtime") + ": " + runtime + "\n"
                + AppLocalized("Amore JavaScriptCore cannot run Node.js, Cordis or browser plugins. An Amore port is required.")
        case .missingManifest:
            return AppLocalized("No compatible plugin configuration was found among the JSON files.")
        case .multipleManifests:
            return AppLocalized("Multiple plugin configurations found. Choose one to continue.")
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
