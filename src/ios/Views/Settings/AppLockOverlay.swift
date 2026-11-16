import SwiftUI

struct AppLockOverlay: View {
    @ObservedObject private var store = SessionLockStore.shared
    @State private var isAuthenticating = false

    var body: some View {
        if store.appIsLocked {
            ZStack {
                PokiTheme.background
                    .ignoresSafeArea()

                VStack(spacing: 24) {
                    Image(systemName: BiometricAuth.biometryIconName)
                        .font(.system(size: 48))
                        .foregroundStyle(PokiTheme.secondaryText)

                    Text("Minis is Locked")
                        .font(.title2.bold())
                        .foregroundStyle(PokiTheme.primaryText)

                    Text("Tap to unlock with \(BiometricAuth.biometryDisplayName)")
                        .font(.subheadline)
                        .foregroundStyle(PokiTheme.secondaryText)

                    Button {
                        authenticate()
                    } label: {
                        Label("Unlock", systemImage: BiometricAuth.biometryIconName)
                            .font(.headline)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(PokiTheme.primaryButton, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(PokiTheme.primaryButtonText)
                    }
                    .disabled(isAuthenticating)
                }
            }
            .transition(.opacity)
            .onAppear {
                authenticate()
            }
        } else if store.showPrivacyScreen {
            PokiTheme.background
                .ignoresSafeArea()
        }
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task { @MainActor in
            let reason = AppLocalized("Unlock Minis")
            let ok = await BiometricAuth.authenticate(reason: reason)
            if ok {
                withAnimation(.easeOut(duration: 0.25)) {
                    store.noteAppUnlock()
                }
            }
            isAuthenticating = false
        }
    }
}
