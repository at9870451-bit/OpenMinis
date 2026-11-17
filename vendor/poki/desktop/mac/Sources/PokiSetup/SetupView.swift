import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var ipa: URL?
    @State private var choosingIPA = false
    @State private var handOff = false
    @State private var result: InstallAnswer?
    @State private var failed: String?
    /// Set when the Apple Account is at its certificate limit: the question to put to the person.
    @State private var certificateQuestion: String?
    @State private var checking = false
    @State private var channelError: String?

    private var installing: Bool { model.busyJobs.contains("install") }

    var body: some View {
        Form {
            HeroSection {
                PageHero(symbol: nil, title: "Set Up Poki", subtitle: "Poki Setup signs Poki with your Apple Account, installs it on your iPhone and keeps it signed.")
            }
            phoneSection
            accountSection
            appSection
            if let steps = model.steps["install"], !steps.isEmpty {
                Section("Progress") { StepsView(steps: steps) }
            }
            if let result { resultSection(result) }
        }
        .pokiPage()
        .task { await model.refreshChannels() }
        .alert("Replace the Certificate?", isPresented: Binding(get: { certificateQuestion != nil }, set: { if !$0 { certificateQuestion = nil } })) {
            Button("Replace Certificate", role: .destructive) {
                Task {
                    do {
                        try await model.approveCertificateReplacement()
                        await install()
                    } catch { model.report(error) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(certificateQuestion ?? "")
        }
        .fileImporter(isPresented: $choosingIPA, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { r in
            if case .success(let url) = r { ipa = url }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await install() }
                } label: {
                    Label("Install Poki", systemImage: "arrow.down.app")
                }
                .disabled(!canInstall)
                .help("Sign Poki with your Apple Account and install it on the iPhone")
            }
        }
    }

    // MARK: iPhone

    @ViewBuilder private var phoneSection: some View {
        Section {
            if let err = model.phonesError {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Poki Setup can't see iPhones right now")
                        Text(err.message).font(.callout).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "cable.connector.slash").foregroundStyle(.orange)
                }
            } else if model.phones.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Color.pokiBlue)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connect your iPhone").font(.headline)
                        Text("Use a cable, unlock the iPhone and tap Trust when it asks.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProgressView().controlSize(.small)
                }
                .padding(.vertical, 4)
            } else {
                if model.phones.count > 1 {
                    Picker("iPhone", selection: Binding(get: { model.selectedPhone?.id ?? "" }, set: { model.selectedUDID = $0 })) {
                        ForEach(model.phones) { Text($0.title).tag($0.id) }
                    }
                }
                if let row = model.selectedPhone { phoneRows(row) }
            }
        } header: {
            Text("iPhone")
        }
    }

    @ViewBuilder private func phoneRows(_ row: PhoneRow) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.pokiBlue)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.headline)
                if let f = row.facts {
                    Text("iOS \(f.ios) · \(f.productType)").font(.callout).foregroundStyle(.secondary)
                } else if let e = row.error {
                    Text(e).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        if let f = row.facts {
            LabeledContent("Trusts This Mac") {
                if f.pairedWithThisComputer {
                    statusText("Yes", .green)
                } else {
                    Button("Pair") { Task { await run { try await model.pair(udid: f.udid) } } }
                        .disabled(model.busyJobs.contains("pair"))
                }
            }
            LabeledContent("Developer Mode") {
                switch f.developerMode {
                case .some(true): statusText("On", .green)
                case .some(false):
                    Button("Turn On…") { Task { await run { try await model.enableDeveloperMode(udid: f.udid) } } }
                        .disabled(model.busyJobs.contains("devmode"))
                case .none: Text("Checked during setup").foregroundStyle(.secondary)
                }
            }
            if let s = model.steps["devmode"], !s.isEmpty, model.busyJobs.contains("devmode") { StepsView(steps: s) }
            if let s = model.steps["pair"], !s.isEmpty, model.busyJobs.contains("pair") { StepsView(steps: s) }
            if let r = row.record {
                LabeledContent("Poki") {
                    statusText("\(r.version) · \(relativeDays(r))", r.daysLeft <= 2 ? .orange : .green)
                }
            }
        }
    }

    private func statusText(_ s: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(s).foregroundStyle(.secondary)
        }
    }

    // MARK: Account

    @ViewBuilder private var accountSection: some View {
        Section("Apple Account") {
            if let a = model.account, a.signedIn {
                LabeledContent("Signed In As") { Text(a.name ?? a.appleId ?? "").foregroundStyle(.secondary) }
                if model.teams.count > 1 {
                    Picker("Team", selection: Binding(get: { a.teamId ?? model.teams.first?.teamId ?? "" }, set: { id in
                        if let t = model.teams.first(where: { $0.teamId == id }) { Task { await model.chooseTeam(t) } }
                    })) {
                        ForEach(model.teams) { t in Text(t.isFree ? "\(t.name) (free)" : t.name).tag(t.teamId) }
                    }
                } else if let t = model.teams.first {
                    LabeledContent("Team") { Text(t.isFree ? "\(t.name), free (7-day apps)" : t.name).foregroundStyle(.secondary) }
                }
                if model.account?.pendingFactor != nil {
                    Button("Enter 6-Digit Verification Code…") { model.needsCode = true }
                }
            } else if let err = model.accountError {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Could not read your saved Apple Account")
                            Text("When macOS asks for keychain access, enter your Mac login password and choose “Always Allow”, then retry.")
                                .font(.callout).foregroundStyle(.secondary)
                            Text(err.message)
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } icon: {
                        Image(systemName: "key.slash").foregroundStyle(.orange)
                    }
                    HStack {
                        Spacer()
                        Button("Retry") { Task { await model.refreshAccount() } }
                    }
                }
            } else {
                LabeledContent("Sign in with the Apple Account Poki is signed for") {
                    Button("Sign In…") { model.page = .account }
                }
            }
        }
    }

    // MARK: Channel and updates

    private var channelChoice: Binding<String> {
        Binding(
            get: { model.channel?.id ?? "stable" },
            set: { id in
                Task {
                    do {
                        try await model.setChannel(id)
                        model.update = nil
                        channelError = nil
                    } catch { channelError = error.localizedDescription }
                }
            }
        )
    }

    /// Downloads the newer Poki Setup, puts it in place of this one and restarts.
    private func installUpdate() async {
        do { try await model.installUpdate() } catch { channelError = error.localizedDescription }
    }

    private func checkForUpdates() async {
        checking = true
        defer { checking = false }
        await model.refreshChannels()
        await model.refreshLatest()
        do {
            model.update = try await model.bridge.call("check_update")
            channelError = nil
        } catch { channelError = error.localizedDescription }
    }

    // MARK: App

    @ViewBuilder private var appSection: some View {
        Section {
            // What gets installed: the channel, with the release under it (or the IPA file picked).
            Picker(selection: channelChoice) {
                ForEach(model.channels) { c in Text(c.title).tag(c.id) }
            } label: {
                Text("Poki")
                Text(installLine)
            }
            .disabled(ipa != nil)
            // Poki Setup itself.
            LabeledContent {
                if let u = model.update, u.newer {
                    Button(model.installingUpdate ? "Updating…" : "Restart to Update") { Task { await installUpdate() } }
                        .disabled(model.installingUpdate)
                } else {
                    Button(checking ? "Checking…" : "Check for Updates") { Task { await checkForUpdates() } }
                        .disabled(checking)
                }
            } label: {
                Text("Poki Setup")
                Text(setupLine)
            }
            HStack {
                Menu {
                    Button(ipa == nil ? "Install from an IPA File…" : "Choose Another IPA File…") { choosingIPA = true }
                    if ipa != nil { Button("Use the Release Instead") { ipa = nil } }
                    Divider()
                    Toggle("Also Show a QR Code for Wi-Fi Pairing", isOn: $handOff)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More install options")
                Spacer()
                Button {
                    Task { await install() }
                } label: {
                    Text(installing ? "Installing…" : "Install Poki").frame(minWidth: 140)
                }
                .pokiProminentButton()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canInstall)
            }
            if let message = failed ?? channelError {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: {
            Text("Poki")
        } footer: {
            if let f = footer { Text(f).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    /// The line under "Poki": what Install will put on the iPhone.
    private var installLine: String {
        if let ipa { return "From \(ipa.lastPathComponent)" }
        if let latest = model.latest { return buildLine(latest) }
        return "No release published yet"
    }

    /// The line under "Poki Setup": its version, or what the last check found.
    private var setupLine: String {
        let version = displayVersion(model.info?.version ?? "")
        guard let update = model.update else { return version }
        return update.newer ? "\(version), \(displayVersion(update.latest ?? "")) is available" : "\(version), up to date"
    }

    /// The release Install will use; says so when the chosen channel has none and a less stable one stands in.
    private func buildLine(_ r: Release) -> String {
        let id = r.channel ?? model.channel?.id ?? ""
        let title = model.channels.first(where: { $0.id == id })?.title ?? id.capitalized
        if let chosen = model.channel, !id.isEmpty, chosen.id != id {
            return "\(title) \(r.version) (\(r.build)), no \(chosen.title) release yet"
        }
        return "\(r.version) (\(r.build))"
    }

    /// Why Install is not available yet, if it is not.
    private var footer: String? {
        if model.accountError != nil { return "Unlock your keychain and choose “Always Allow”, then tap Retry above." }
        if model.account?.signedIn != true { return "Sign in first. Your Apple Account password goes to Apple only." }
        if ipa == nil && model.latest == nil { return "No Poki release is published yet. Use ⋯ to install from the Poki IPA you downloaded (the “external” one)." }
        return nil
    }

    private var canInstall: Bool {
        !installing && model.selectedPhone?.facts != nil && model.account?.signedIn == true && (ipa != nil || model.latest != nil)
    }

    @ViewBuilder private func resultSection(_ r: InstallAnswer) -> some View {
        Section("Done") {
            Label("Poki \(r.record.version) is on \(r.record.phoneName). It stays signed until \(r.record.expires.formatted(date: .abbreviated, time: .shortened)).", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.primary)
            ForEach(Array(r.notes.enumerated()), id: \.offset) { _, n in
                Text(n).font(.callout).foregroundStyle(.secondary)
            }
            Text("On the iPhone: open Settings › General › VPN & Device Management, trust your Apple Account, then open Poki.")
                .font(.callout)
            if let h = r.handoff {
                HStack(alignment: .top, spacing: 16) {
                    QRCode(text: h.link, size: 150)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scan with the iPhone's Camera").font(.headline)
                        Text("Keep the iPhone on the same Wi-Fi as this Mac. Poki opens and saves its pairing file.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Copy Link") { copyToPasteboard(h.link) }
                    }
                }
            }
        }
    }

    private func install() async {
        guard let phone = model.selectedPhone else { return }
        failed = nil
        result = nil
        do {
            result = try await model.install(udid: phone.id, ipa: ipa, handOff: handOff)
        } catch let e as CoreError where e.kind == "certificate_limit" {
            failed = e.message
            certificateQuestion = e.message
        } catch {
            failed = error.localizedDescription
        }
    }

    private func run(_ body: () async throws -> Void) async {
        do { try await body() } catch { model.report(error) }
    }
}
