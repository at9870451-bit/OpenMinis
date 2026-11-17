import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.page }, set: { if let p = $0 { model.page = p } })) {
                Section {
                    ForEach([Page.setup, .phones, .account]) { p in
                        Label(p.title, systemImage: p.symbol).tag(p)
                    }
                }
                Section("Advanced") {
                    ForEach([Page.relay, .debug]) { p in
                        Label(p.title, systemImage: p.symbol).tag(p)
                    }
                }
            }
            .listStyle(.sidebar)
            .noTopEdgeFade()
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            Group {
                switch model.page {
                case .setup: SetupView()
                case .phones: PhonesView()
                case .account: AccountView()
                case .relay: RelayView()
                case .debug: DiagnosticsView()
                }
            }
            .navigationTitle(model.page.title)
        }
        .overlay(alignment: .bottom) {
            if let text = model.banner {
                Banner(text: text) { model.banner = nil }
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.banner)
        .sheet(isPresented: $model.needsCode) { VerificationCodeSheet() }
        .alert("Poki Setup \(displayVersion(model.updatePrompt ?? "")) is available", isPresented: Binding(get: { model.updatePrompt != nil }, set: { if !$0 { model.updatePrompt = nil } })) {
            Button("Restart to Update") {
                Task {
                    do { try await model.installUpdate() } catch { model.banner = error.localizedDescription }
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Later", role: .cancel) {}
        } message: {
            Text("Poki Setup downloads the update, checks its signature and restarts.")
        }
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject var model: AppModel

    private var signedIn: Bool { model.account?.signedIn == true }
    private var hasKeychainError: Bool { !signedIn && model.accountError != nil }

    var body: some View {
        HStack(spacing: 10) {
            AccountBadge(name: model.account?.name, appleID: model.account?.appleId, signedIn: signedIn)
            VStack(alignment: .leading, spacing: 1) {
                Text(signedIn ? (model.account?.name ?? "Signed In") : hasKeychainError ? "Keychain Locked" : "Not Signed In")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(signedIn ? (model.account?.appleId ?? "") : hasKeychainError ? "Choose “Always Allow” and retry" : "Sign in to set up Poki")
                    .font(.caption)
                    .foregroundStyle(hasKeychainError ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { model.page = .account }
    }
}

private struct VerificationCodeSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(Color.pokiBlue)
            Text("Two-Factor Authentication").font(.title2.weight(.semibold))
            Text(model.codeVia == "sms" ? "Enter the code Apple sent to your phone number." : "Enter the verification code shown on your other Apple devices.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("6-digit code", text: $code)
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { Task { await verify() } }
                .onChange(of: code) { _, new in
                    let digits = new.filter(\.isNumber)
                    if digits != new { code = digits }
                    if digits.count == 6 { Task { await verify() } }
                }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") {
                    model.needsCode = false
                    code = ""
                    error = nil
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Verify") { Task { await verify() } }
                    .pokiProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count != 6 || working)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func verify() async {
        guard !working, code.count == 6 else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await model.finishSignIn(code: code)
            code = ""
        } catch {
            self.error = error.localizedDescription
            code = ""
        }
    }
}

/// The Apple Account's picture: this Mac's account photo when the Mac is signed in to the same
/// Apple Account (the photo the Apple Account uses), otherwise initials on flat Poki blue.
struct AccountBadge: View {
    var name: String?
    var appleID: String? = nil
    var signedIn: Bool
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            if signedIn, let photo = AccountPhoto.shared.photo(for: appleID) {
                Image(nsImage: photo).resizable().scaledToFill()
            } else {
                Circle().fill(signedIn ? Color.pokiBlue : Color.secondary.opacity(0.25))
                if signedIn, let initials = initials {
                    Text(initials).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Image(systemName: "person.fill").font(.system(size: size * 0.46)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String? {
        guard let name, !name.contains("@") else { return nil }
        let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? nil : String(parts)
    }
}

private struct Banner: View {
    var text: String
    var close: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .buttonStyle(.borderless)
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .frame(maxWidth: 560)
        .pokiGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
