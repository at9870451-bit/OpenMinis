import CryptoKit
import LocalAuthentication
import Security
import SwiftUI
import UIKit

/// The lock in front of iPhone History (the owner, 2026-11-14): its pages open only after Face ID or
/// Touch ID, with no fall back to the iPhone's passcode, or after a PIN that belongs to Poki alone.
/// Either one can be turned off, but never both.
@MainActor
final class HistoryLock: ObservableObject {
    static let shared = HistoryLock()

    @Published private(set) var unlocked = false
    @Published private(set) var hasPIN: Bool
    /// The owner's choice. Whether it can be used also depends on the iPhone (`biometricsReady`).
    @Published private(set) var biometricsOn: Bool
    @Published private(set) var failures = 0
    @Published private(set) var blockedUntil: Date?

    private static let service = "nz.zheha.poki.history-lock"
    private static let account = "pin"

    private init() {
        hasPIN = Self.stored() != nil
        biometricsOn = UserDefaults.standard.object(forKey: "history.lock.biometrics") as? Bool ?? true
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
    }

    // MARK: Biometrics

    /// Face ID or Touch ID is set up on this iPhone and allowed for Poki.
    var biometricsReady: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    var usesBiometrics: Bool { biometricsOn && biometricsReady }

    /// "Face ID", "Touch ID" or "Optic ID", as this iPhone has it.
    var biometricsName: String {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Face ID"
        }
    }

    /// The same name in Poki's language.
    var biometricsLabel: String { AppLocalization.bundle.localizedString(forKey: biometricsName, value: nil, table: nil) }

    /// Nothing can unlock history yet: a PIN has to be made first.
    var needsSetup: Bool { !usesBiometrics && !hasPIN }

    func unlockWithBiometrics() async {
        guard usesBiometrics, !unlocked else { return }
        let context = LAContext()
        // No "Enter Passcode" button: the iPhone's passcode does not open history.
        context.localizedFallbackTitle = ""
        let reason = AppLocalization.text("Unlock Screen History")
        let passed = (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
        if passed { opened() }
    }

    /// Asks for Face ID or Touch ID again, for something that cannot be undone. The page stays as it is.
    func confirm(_ reason: String) async -> Bool {
        guard usesBiometrics else { return false }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        return (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
    }

    // MARK: PIN

    private static func stored() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func digest(_ pin: String, salt: Data) -> Data {
        var hash = Data(SHA256.hash(data: salt + Data(pin.utf8)))
        // Stretched, so the short PIN is slow to try from a copy of the stored value.
        for _ in 0..<20_000 { hash = Data(SHA256.hash(data: salt + hash)) }
        return hash
    }

    static func valid(_ pin: String) -> Bool { (4...8).contains(pin.count) && pin.allSatisfy(\.isNumber) }

    /// Keeps a new PIN. Allowed while history is unlocked, or when nothing can unlock it yet.
    @discardableResult
    func setPIN(_ pin: String) -> Bool {
        guard Self.valid(pin), unlocked || needsSetup else { return false }
        var salt = Data(count: 16)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else { return false }
        let value = salt + Self.digest(pin, salt: salt)
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
        SecItemDelete(match as CFDictionary)
        var add = match
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        hasPIN = true
        opened()
        return true
    }

    func unlock(pin: String) -> Bool {
        if let until = blockedUntil, until > Date() { return false }
        guard let value = Self.stored(), value.count > 16 else { return false }
        let salt = value.prefix(16)
        if Self.digest(pin, salt: Data(salt)) == value.dropFirst(16) {
            opened()
            return true
        }
        failures += 1
        // Five wrong tries in a row, then a wait that doubles: 30 s, 1 min, 2 min, up to an hour.
        if failures >= 5 { blockedUntil = Date().addingTimeInterval(min(3600, 30 * pow(2, Double(failures - 5)))) }
        return false
    }

    /// Removes the PIN. Refused unless Face ID or Touch ID stays as the way in.
    @discardableResult
    func removePIN() -> Bool {
        guard unlocked, usesBiometrics else { return false }
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
        SecItemDelete(match as CFDictionary)
        hasPIN = false
        return true
    }

    /// Turns Face ID or Touch ID on or off for history. Turning it off is refused without a PIN.
    @discardableResult
    func setBiometrics(_ on: Bool) -> Bool {
        guard unlocked, on || hasPIN else { return false }
        biometricsOn = on
        UserDefaults.standard.set(on, forKey: "history.lock.biometrics")
        return true
    }

    // MARK: State

    private func opened() {
        unlocked = true
        failures = 0
        blockedUntil = nil
    }

    func lock() { unlocked = false }
}

/// Shows its content only while iPhone History is unlocked.
struct HistoryGate<Content: View>: View {
    @ObservedObject var lock = HistoryLock.shared
    @ViewBuilder var content: () -> Content

    var body: some View {
        if lock.unlocked { content() } else { HistoryLockedPage() }
    }
}

/// The lock on a page of its own.
private struct HistoryLockedPage: View {
    var body: some View {
        BacktapeLockScreen()
            .navigationTitle(AppLocalization.text("Screen History"))
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// What Backtape shows before it is unlocked (the owner, 2026-11-15: a screen that says an unlock is
/// needed to view, with the Face ID prompt or a password pad). Face ID or Touch ID is asked for as the
/// page opens and again from its button; with a PIN, the pad is on the page. Nothing of the tape is
/// drawn behind it. An iPhone with neither yet gets the list that makes a PIN.
struct BacktapeLockScreen: View {
    @ObservedObject private var lock = HistoryLock.shared
    @State private var pin = ""
    @State private var wrong = 0
    @State private var now = Date()

    private var waiting: Bool { lock.blockedUntil.map { $0 > now } ?? false }

    var body: some View {
        if lock.needsSetup {
            List { HistoryUnlockSections() }.settingsPage()
        } else {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: lock.usesBiometrics ? (lock.biometricsName == "Touch ID" ? "touchid" : "faceid") : "lock.fill")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(Tint.blue)
                        .padding(.top, 36)
                        .accessibilityHidden(true)
                    VStack(spacing: 6) {
                        Text("Screen History Is Locked").font(.title2.weight(.semibold))
                        Text("Unlock to view what Screen History kept on this iPhone.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    if lock.usesBiometrics {
                        Button { Task { await lock.unlockWithBiometrics() } } label: {
                            Text(verbatim: String(format: AppLocalization.text("Unlock with %@"), lock.biometricsLabel))
                                .padding(.horizontal, 6)
                        }
                        .glassButton(prominent: true)
                        .controlSize(.large)
                    }
                    if lock.hasPIN { pad }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color(.systemGroupedBackground))
            .task { await lock.unlockWithBiometrics() }
            .task(id: lock.blockedUntil) {
                // The wait's end shows by itself.
                while let until = lock.blockedUntil, until > Date() {
                    try? await Task.sleep(for: .seconds(1))
                    now = Date()
                }
                now = Date()
            }
            .sensoryFeedback(.error, trigger: wrong)
        }
    }

    /// Poki's own PIN, 4 to 8 digits: the dots, then the keys.
    private var pad: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ForEach(0..<max(4, pin.count), id: \.self) { index in
                    Circle().fill(index < pin.count ? Color(.label) : Color(.tertiaryLabel).opacity(0.5)).frame(width: 11, height: 11)
                }
            }
            .frame(height: 20)
            .accessibilityLabel(Text("PIN"))
            .accessibilityValue(Text(verbatim: "\(pin.count)"))
            Group {
                if waiting, let until = lock.blockedUntil {
                    Text(verbatim: String(format: AppLocalization.text("Too many wrong tries. Try again at %@."), until.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(AppLocalization.locale))))
                } else if wrong > 0, pin.isEmpty {
                    Text("That PIN is not right.")
                } else {
                    Text(verbatim: " ")
                }
            }
            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            Grid(horizontalSpacing: 22, verticalSpacing: 14) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(1..<4, id: \.self) { column in key("\(row * 3 + column)") }
                    }
                }
                GridRow {
                    symbolKey("delete.left", label: "Delete") { if !pin.isEmpty { pin.removeLast() } }
                    key("0")
                    symbolKey("arrow.right", label: "Unlock") { enter() }
                        .disabled(!HistoryLock.valid(pin))
                }
            }
            .disabled(waiting)
            .glassGroup(spacing: 8)
        }
        .padding(.top, 6)
    }

    private func key(_ digit: String) -> some View {
        Button {
            guard pin.count < 8 else { return }
            pin += digit
        } label: {
            Text(verbatim: digit).font(.title.weight(.regular)).frame(width: 72, height: 72).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassSurface(in: Circle(), interactive: true)
        .sensoryFeedback(.selection, trigger: pin)
    }

    private func symbolKey(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2).frame(width: 72, height: 72).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func enter() {
        if !lock.unlock(pin: pin) { wrong += 1 }
        pin = ""
        now = Date()
    }
}

/// The way in, as sections of a list: Face ID or Touch ID, the PIN, or making a PIN when the iPhone
/// has neither set up.
struct HistoryUnlockSections: View {
    @ObservedObject private var lock = HistoryLock.shared
    @State private var pin = ""
    @State private var again = ""
    @State private var wrong = false

    private var waiting: Bool { lock.blockedUntil.map { $0 > Date() } ?? false }

    var body: some View {
        Group {
            if lock.needsSetup {
                Section {
                    SecureField("New PIN", text: $pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    SecureField("Repeat PIN", text: $again).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    Button("Set PIN") {
                        wrong = !(pin == again && lock.setPIN(pin))
                        if wrong { again = "" }
                    }
                    .disabled(!HistoryLock.valid(pin) || again.isEmpty)
                } header: {
                    Text("Make a PIN for Screen History")
                } footer: {
                    Text(LocalizedStringKey(wrong ? "The two PINs did not match. Try again." : "Screen History is locked with a PIN of 4 to 8 digits that belongs to Poki alone. The iPhone's passcode does not open it."))
                }
            } else {
                if lock.usesBiometrics {
                    Section {
                        Button { Task { await lock.unlockWithBiometrics() } } label: {
                            Text(verbatim: String(format: AppLocalization.text("Unlock with %@"), lock.biometricsLabel))
                        }
                    } header: {
                        Text("Screen History Is Locked")
                    }
                }
                if lock.hasPIN {
                    Section {
                        SecureField("PIN", text: $pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        Button("Unlock") {
                            wrong = !lock.unlock(pin: pin)
                            pin = ""
                        }
                        .disabled(pin.isEmpty || waiting)
                    } footer: {
                        if waiting, let until = lock.blockedUntil {
                            Text(verbatim: String(format: AppLocalization.text("Too many wrong tries. Try again at %@."), until.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(AppLocalization.locale))))
                        } else if wrong {
                            Text("That PIN is not right.")
                        }
                    }
                }
            }
        }
        .task { await lock.unlockWithBiometrics() }
    }
}

/// History's lock settings: Face ID or Touch ID, and Poki's own PIN. One of the two always stays on.
struct HistoryLockSettings: View {
    @ObservedObject private var lock = HistoryLock.shared
    @State private var pin = ""
    @State private var again = ""
    @State private var mismatch = false

    var body: some View {
        List {
            if lock.biometricsReady {
                Section {
                    Toggle(isOn: Binding(get: { lock.biometricsOn }, set: { lock.setBiometrics($0) })) {
                        Text(verbatim: lock.biometricsLabel)
                    }
                    .disabled(lock.biometricsOn && !lock.hasPIN)
                } footer: {
                    Text("The iPhone's passcode never opens history. To turn this off, set a PIN first.")
                }
            }
            Section {
                SecureField(LocalizedStringKey(lock.hasPIN ? "New PIN" : "PIN"), text: $pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
                SecureField("Repeat PIN", text: $again).keyboardType(.numberPad).textContentType(.oneTimeCode)
                Button(LocalizedStringKey(lock.hasPIN ? "Change PIN" : "Set PIN")) {
                    mismatch = !(pin == again && lock.setPIN(pin))
                    pin = ""
                    again = ""
                }
                .disabled(!HistoryLock.valid(pin) || again.isEmpty)
                if lock.hasPIN {
                    Button("Remove PIN", role: .destructive) { lock.removePIN() }.disabled(!lock.usesBiometrics)
                }
            } header: {
                Text("Poki PIN")
            } footer: {
                Text(LocalizedStringKey(mismatch ? "The two PINs did not match. Try again." : "A PIN of 4 to 8 digits that belongs to Poki alone. One of the two ways in always stays on."))
            }
        }
        .navigationTitle(AppLocalization.text("Screen History Lock"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
