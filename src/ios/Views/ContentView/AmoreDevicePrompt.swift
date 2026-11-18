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
    func body(content: Content) -> some View {
        content.alert(AppLocalized("Allow device action?"), isPresented: Binding(
            get: { store.approvalID != nil }, set: { shown in if !shown, store.approvalID != nil { store.resolve(false) } }
        )) {
            Button(AppLocalized("Don’t Allow"), role: .cancel) { store.resolve(false) }
            Button(AppLocalized("Allow")) { store.resolve(true) }
        } message: { Text(AmoreDeviceServices.currentApprovalText() ?? "") }
    }
}
