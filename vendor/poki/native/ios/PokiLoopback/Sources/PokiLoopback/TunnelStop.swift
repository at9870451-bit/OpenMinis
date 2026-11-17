import NetworkExtension

/// What the tunnel tells the app when iOS stops it, so the app can tell the owner's choice (or another
/// VPN taking over) from a failure it should dial again after.
public enum TunnelStop {
    /// True when the owner, or another VPN, ended the connection: Poki must not turn it on again.
    public static func isOnPurpose(_ reason: NEProviderStopReason) -> Bool {
        switch reason {
        case .userInitiated, .superceded, .providerDisabled, .configurationDisabled, .configurationRemoved, .authenticationCanceled, .userLogout, .userSwitch: true
        default: false
        }
    }
}
