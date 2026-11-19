import SwiftUI
import AmoreDeviceKit

/// Device approval actions are unavailable while Amore is locked. This wraps
/// the real upstream-backed pages; it does not cache an actionable request.
struct AmoreProtectedDevicePage: View {
    let approvals: Bool
    @ObservedObject private var lock = SessionLockStore.shared
    var body: some View {
        Group {
            if lock.appIsLocked {
                ContentUnavailableView(AppLocalized("Unlock Amore to view device controls"), systemImage: "lock.shield")
            } else if approvals {
                AmoreApprovalsPage()
            } else {
                AmoreDeviceStatusView()
            }
        }
        .amoreSettingsGlass()
    }
}
