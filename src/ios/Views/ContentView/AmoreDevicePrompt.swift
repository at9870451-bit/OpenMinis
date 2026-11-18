import SwiftUI
import AmoreDeviceKit

struct AmoreDeviceApprovalRequest: Identifiable {
    let id: String
    let text: String
}

@MainActor
final class AmoreDevicePromptStore: ObservableObject {
    static let shared = AmoreDevicePromptStore()
    @Published var request: AmoreDeviceApprovalRequest?
    private init() {
        AmoreDeviceServices.observeApprovals { [weak self] id in
            self?.request = id.map { AmoreDeviceApprovalRequest(id: $0, text: AmoreDeviceServices.approvalText(id: $0) ?? "") }
        }
    }
    func resolve(_ id: String, approved: Bool) {
        AmoreDeviceServices.resolveApproval(id: id, approved: approved)
        if request?.id == id { request = nil }
    }
}

struct AmoreDevicePrompts: ViewModifier {
    @StateObject private var store = AmoreDevicePromptStore.shared
    @ObservedObject private var appLock = SessionLockStore.shared
    func body(content: Content) -> some View {
        content.alert(AppLocalized("Allow device action?"), isPresented: Binding(
            get: { !appLock.appIsLocked && store.request != nil },
            set: { shown in if !shown, !appLock.appIsLocked, let id = store.request?.id { store.resolve(id, approved: false) } }
        ), presenting: store.request) { request in
            Button(AppLocalized("Don’t Allow"), role: .cancel) { store.resolve(request.id, approved: false) }
            Button(AppLocalized("Allow")) { store.resolve(request.id, approved: true) }
        } message: { request in Text(request.text) }
    }
}
