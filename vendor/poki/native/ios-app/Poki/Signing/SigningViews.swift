import SwiftUI

/// The Apple Account, optional and out of the way (ESP-222): Poki Setup on a Mac signs Poki, and
/// signed in here Poki can also renew itself with no computer. Sections of the Apple Account page's Form.
struct AccountPage: View {
    @Environment(AppModel.self) private var model
    @State private var appleID = ""
    @State private var password = ""
    @State private var keepPassword = true
    @State private var code = ""

    private var signer: SelfSigner { model.signer }

    var body: some View {
        if signer.needsCode {
            Section {
                TextField("Verification Code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button("Verify") { Task { await signer.finishSignIn(code: code); code = "" } }
                    .disabled(code.count != 6 || signer.working != nil)
            } footer: {
                Text("Apple sent a six-digit code to your trusted devices or phone number.")
            }
        } else if signer.signedIn {
            Section {
                LabeledContent("Apple Account", value: signer.status?.apple_id ?? "")
                if let name = signer.status?.name, name != signer.status?.apple_id { LabeledContent("Name", value: name) }
                if signer.teams.count > 1 {
                    Picker("Team", selection: Binding(get: { signer.status?.team_id ?? "" }, set: { id in
                        if let team = signer.teams.first(where: { $0.team_id == id }) { Task { await signer.choose(team: team) } }
                    })) {
                        ForEach(signer.teams) { team in Text(team.is_free ? "\(team.name) (Free)" : team.name).tag(team.team_id) }
                    }
                } else if let team = signer.teams.first {
                    LabeledContent("Team", value: team.is_free ? "\(team.name) (Free, 7-day signing)" : team.name)
                }
            } footer: {
                Text(signer.status?.keeps_password == true
                     ? "Poki keeps the password in this iPhone’s Keychain to sign itself again every week."
                     : "Poki signs in again when its signing is due, and asks you for the password then.")
            }
            .task { if signer.teams.isEmpty { await signer.loadTeams() } }
            Section { Button("Sign Out", role: .destructive) { Task { await signer.signOut() } } }
        } else {
            Section {
                TextField("Apple ID", text: $appleID)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Toggle("Keep Me Signed In", isOn: $keepPassword)
            } footer: {
                Text("A free Apple Account works: Poki signs itself for 7 days at a time and gets ready to sign again before then. Your Apple ID and password go only to Apple. The anisette server Poki asks for its device headers never sees them.")
            }
            Section {
                Button("Sign In") { Task { await signer.signIn(appleID: appleID, password: password, keepPassword: keepPassword); password = "" } }
                    .disabled(appleID.isEmpty || password.isEmpty || signer.working != nil)
            }
        }
        SignerActivityRows(signer: signer)
    }
}

/// What the signer is doing, or why it stopped.
struct SignerActivityRows: View {
    let signer: SelfSigner
    var body: some View {
        if let working = signer.working {
            Section {
                if let f = signer.fraction { ProgressView(value: f) { Text(working) } } else { LabeledContent { ProgressView() } label: { Text(working) } }
            }
        }
        if let error = signer.lastError {
            // The signer's words are English; those the strings table knows are shown in the owner's language.
            Section { Label(Bundle.main.localizedString(forKey: error, value: error, table: nil), systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        }
        if let error = signer.updateCheckError {
            Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        } else if let notice = signer.latest?.source_notice {
            Section { Label(notice, systemImage: "info.circle") }
        }
    }
}

/// The Setup page's signing section: when Poki stops opening, the build that is ready, and Install.
struct SigningSection: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(AppModel.self) private var model
    private var signer: SelfSigner { model.signer }

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: "\(signer.installedVersion) (\(signer.installedBuild))")
            } label: {
                Label("Poki Version", systemImage: "info.circle")
            }
            LabeledContent {
                if let expiry = signer.expiry {
                    // The date and its countdown stay readable when the row needs more room.
                    (Text(expiry, format: .dateTime.month(.abbreviated).day().year()) + Text(verbatim: " · ") + Text(expiry, style: .relative).foregroundStyle(countdownColor))
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No Profile").foregroundStyle(Color(.secondaryLabel))
                }
            } label: {
                Label("Signed Until", systemImage: "signature")
            }
            // A newer build that isn't downloaded yet shows even when a refresh (or an older update) is
            // ready, so it is never hidden behind it.
            if signer.updateNotReady, let latest = signer.latest {
                LabeledContent { Text(verbatim: "\(latest.version) (\(latest.build))") } label: { Label("Update Available", systemImage: "sparkles") }
            } else if let next = signer.next {
                LabeledContent {
                    Text(next.kind == "update" ? "\(next.version) (\(next.build))" : "Until \(next.expires.formatted(.dateTime.month(.abbreviated).day().year().locale(AppLocalization.locale)))")
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Label(next.kind == "update" ? "Update Ready" : "Refresh Ready", systemImage: "checkmark.seal")
                }
            }
            NavigationLink { SigningOptionsPage() } label: {
                Label("Signing Options", systemImage: "slider.horizontal.3")
            }
            // The actions last, under what they act on. A newer build not yet downloaded comes first:
            // one tap downloads and installs it (or, without an Apple Account, opens the sign-in).
            if signer.updateNotReady {
                if signer.signedIn {
                    SignerAction(signer: signer, title: "Download and Install Update", systemImage: "arrow.down.circle") { await signer.downloadAndInstallUpdate() }
                } else {
                    SignInToUpdateLink()
                }
            } else if let next = signer.next {
                // Idle is partly time (a minute since the last agent step), which nothing observes, so
                // the row looks again every few seconds instead of staying as it was first drawn.
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    SignerAction(signer: signer, title: next.kind == "update" ? "Install Update" : "Install Refresh", systemImage: "arrow.down.app") { await signer.install() }
                }
            }
            if signer.needsCode {
                Button {
                    signer.presentCodeSheet()
                } label: {
                    Label("Enter Verification Code…", systemImage: "lock.shield")
                }
            }
            if signer.signedIn {
                SignerAction(signer: signer, title: "Prepare Refresh Now", systemImage: "arrow.clockwise") { await signer.prepare(kind: "refresh") }
            }
        } header: {
            Text("Signing")
        } footer: {
            Text(footer)
        }
        SignerActivityRows(signer: signer)
    }

    private var countdownColor: Color {
        guard let days = signer.daysLeft else { return .secondary }
        return days <= 1 ? .red : days <= SelfSigner.refreshWithDaysLeft ? .orange : .secondary
    }

    private var footer: String {
        if let blocker = signer.updateBlocker { return blocker }
        if !signer.signedIn { return AppLocalization.text(LocalizedStringResource("Poki Setup on your Mac renews Poki when this iPhone is connected.")) }
        if signer.next != nil {
            return model.signingIdle
                ? AppLocalization.text(LocalizedStringResource("Installing closes Poki for a moment. Your chats and setup stay."))
                : (model.signingBusyReason ?? "") + " " + AppLocalization.text(LocalizedStringResource("Install is available when Poki isn’t running a task."))
        }
        return AppLocalization.text(LocalizedStringResource("Poki gets the next build ready by itself, \(Int(SelfSigner.refreshWithDaysLeft)) days before it expires or when your channel has an update. It installs only when you tap Install."))
    }
}

/// What the Signing page offers under Status when the channel has a newer Poki (ESP-387).
enum UpdateStep: Equatable {
    /// One tap downloads it, signs it and installs it.
    case download
    /// A signed copy of it is ready.
    case install
    /// No Apple Account: sign in here, or install it with Poki Setup on a Mac.
    case signIn

    init?(updateAvailable: Bool, copyReady: Bool, signedIn: Bool) {
        guard updateAvailable else { return nil }
        self = copyReady ? .install : signedIn ? .download : .signIn
    }
}

/// One signer action row, disabled while the signer works.
struct SignerAction: View {
    let signer: SelfSigner
    let title: LocalizedStringKey
    let systemImage: String
    let work: () async -> Void

    var body: some View {
        Button(title, systemImage: systemImage) { Task { await work() } }
            .disabled(signer.working != nil)
    }
}

/// Without an Apple Account, the way to one that downloads the update.
struct SignInToUpdateLink: View {
    var body: some View {
        NavigationLink {
            Form { AccountPage() }
                .navigationTitle(AppLocalization.text("Apple Account"))
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            Label("Sign In to Download the Update", systemImage: "person.crop.circle.badge.plus")
        }
    }
}

/// Home's warning that the installed Poki stops opening soon (ESP-222). Renewing happens on the Mac:
/// it installs a build with a new profile, so a renewed Poki has a later expiry and no warning.
struct ExpiryWarning {
    let expiry: Date

    init?(expiry: Date?, now: Date = .now) {
        guard let expiry, expiry.timeIntervalSince(now) <= SelfSigner.warnWithDaysLeft * 86_400 else { return nil }
        self.expiry = expiry
    }

    var message: String {
        let when = expiry.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLocalization.locale))
        return AppLocalization.text(LocalizedStringResource("Poki stops opening after \(when). Connect this iPhone to your Mac and ask your agent to renew it."))
    }
}

struct ExpiryWarningSection: View {
    let warning: ExpiryWarning

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Poki’s signing ends soon").font(Prominent.font(.headline, .semibold))
                    Text(warning.message).font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                }
            } icon: {
                Image(systemName: "clock.badge.exclamationmark.fill").foregroundStyle(.orange)
            }
        }
    }
}

/// The release channel, the anisette server, and the optional Apple Account.
struct SigningOptionsPage: View {
    @Environment(AppModel.self) private var model
    @State private var anisette = ""
    /// The channel's newest build has been looked up (found or not) since the page opened.
    @State private var checked = false
    private var signer: SelfSigner { model.signer }

    var body: some View {
        Form {
            Section {
                LabeledContent("Updates") { Text(verbatim: "Beta") }
            }
            Section {
                LabeledContent("Installed") { Text(verbatim: "\(signer.installedVersion) (\(signer.installedBuild))") }
                LabeledContent("Newest Beta") {
                    if let latest = signer.latest {
                        Text(verbatim: "\(latest.version) (\(latest.build))")
                    } else {
                        (checked ? Text("Not Found") : Text("Checking…")).foregroundStyle(Color(.secondaryLabel))
                    }
                }
                if let latest = signer.latest {
                    LabeledContent("Status") { signer.isNewer(latest) ? Text("Update Available") : Text("Up to Date") }
                }
                // The way to the update from here, under the status that announces it.
                switch signer.updateStep {
                case .download:
                    SignerAction(signer: signer, title: "Download and Install Update", systemImage: "arrow.down.circle") { await signer.downloadAndInstallUpdate() }
                case .install:
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        SignerAction(signer: signer, title: "Install Update", systemImage: "arrow.down.app") { await signer.install() }
                    }
                case .signIn:
                    Text("Sign in to your Apple Account to update here. Or update with Set up Poki or Renew in Poki Setup on your Mac.")
                        .font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                    SignInToUpdateLink()
                case nil:
                    EmptyView()
                }
            } header: {
                Text("Version")
            }
            .task(id: signer.status?.channel) {
                checked = false
                await signer.checkLatest()
                checked = true
            }
            Section {
                TextField("https://new.ani.sidestore.io", text: $anisette)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await signer.setAnisette(anisette) } }
                Button("Use Default Server") { anisette = ""; Task { await signer.setAnisette("") } }
            } header: {
                Text("Anisette Server")
            } footer: {
                Text("Apple’s sign-in needs device headers that only Apple hardware makes. Poki gets them from this anisette server. It never sees your Apple ID or password.")
            }
            Section {
                if signer.needsCode {
                    Button {
                        signer.presentCodeSheet()
                    } label: {
                        Label("Enter Verification Code…", systemImage: "lock.shield")
                    }
                }
                NavigationLink {
                    Form { AccountPage() }
                        .navigationTitle(AppLocalization.text("Apple Account"))
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent {
                        if signer.signedIn { Text(verbatim: signer.status?.apple_id ?? "") }
                        else { Text("Optional").foregroundStyle(Color(.secondaryLabel)) }
                    } label: {
                        Label("Apple Account", systemImage: "person.crop.circle")
                    }
                }
            } footer: {
                Text("Optional. To renew Poki without a Mac, sign in to your Apple Account here.")
            }
            SignerActivityRows(signer: signer)
        }
        .navigationTitle(AppLocalization.text("Signing"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { anisette = signer.status?.anisette ?? "" }
    }
}

extension EnvironmentValues {
    @Entry var pokiDetailsOpen = false
}

/// Six-digit 2FA verification sheet shown when renewing a saved-password Apple session requires a code.
struct VerificationCodeSheet: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""

    private var signer: SelfSigner { model.signer }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("6-Digit Code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .onChange(of: code) { _, new in
                            let digits = String(new.filter(\.isNumber).prefix(6))
                            if digits != new { code = digits }
                            if digits.count == 6, signer.working == nil {
                                submit()
                            }
                        }
                } header: {
                    Text("Two-Factor Authentication")
                } footer: {
                    Text("Enter the 6-digit verification code sent to your trusted devices or phone number.")
                }
                SignerActivityRows(signer: signer)
            }
            .navigationTitle(AppLocalization.text("Verification Code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { signer.dismissCodeSheet() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Verify") { submit() }
                        .disabled(code.count != 6 || signer.working != nil)
                }
            }
        }
    }

    private func submit() {
        let entered = code
        code = ""
        Task { await signer.finishSignIn(code: entered) }
    }
}
