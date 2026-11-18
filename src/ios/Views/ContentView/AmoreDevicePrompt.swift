import SwiftUI
import AmoreDeviceKit

@MainActor
final class AmoreDevicePromptStore: ObservableObject {
    static let shared = AmoreDevicePromptStore()
    @Published var approvalID: String?
    private init() {
        AmoreDeviceServices.observeApprovals { [weak self] id in self?.approvalID = id }
    }
    func resolve(_ approved: Bool) { AmoreDeviceServices.resolveCurrentApproval(approved); approvalID = nil }
}

struct AmoreDevicePrompts: ViewModifier {
    @StateObject private var store = AmoreDevicePromptStore.shared
    @ObservedObject private var appLock = SessionLockStore.shared
    func body(content: Content) -> some View {
        content.alert(AppLocalized("Allow device action?"), isPresented: Binding(
            get: { !appLock.appIsLocked && store.approvalID != nil }, set: { shown in if !shown, !appLock.appIsLocked, store.approvalID != nil { store.resolve(false) } }
        )) {
            Button(AppLocalized("Don’t Allow"), role: .cancel) { store.resolve(false) }
            Button(AppLocalized("Allow")) { store.resolve(true) }
        } message: { Text(AmoreDeviceServices.currentApprovalText() ?? "") }
    }
}
