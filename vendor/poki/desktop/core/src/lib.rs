//! Poki Setup's core: everything the desktop app and the `poki-setup` command do, with no UI in it.
//!
//! - [`device`]: the iPhone over USB (usbmuxd) or Wi-Fi (the pairing record): pairing, facts,
//!   Developer Mode, installing, the app container, the developer disk image, logs.
//! - [`pairshare`]: hands the pairing file to Poki on the phone over the local network, as the
//!   `poki://pairing?url=…&sha256=…` link Poki opens from a QR code.
//! - [`apple`]: the Apple account (GSA login with SRP and 2FA, anisette) and the developer portal
//!   (teams, devices, certificates, App IDs, app groups, profiles).
//! - [`sign`]: takes Poki's release IPA and signs it for a team: bundle ids, app groups,
//!   entitlements, profiles, every nested bundle, with the pure-Rust apple-codesign.
//! - [`release`]: Poki's release IPAs from GitHub, checked against their digests.
//! - [`keeper`]: the phones this computer set up, their expiry, what is due.
//! - [`mcp`]: connector links, client snippets, and a `tools/list` check.
//! - [`relay`]: deploys `deploy/cf-relay` to the person's own Cloudflare account.
//! - [`support`]: a diagnostic archive for private review before sharing.
//!
//! Licences: this crate is AGPL-3.0-only like the rest of Poki. The GSA login follows Apple's
//! protocol as implemented in SideStore's icloud-auth (MPL-2.0) and Dadoum's Sideloader
//! (GPL-3.0); the entitlement rule is AltSign's (AGPL-3.0). See THIRD_PARTY_NOTICES.md.

#[cfg(feature = "device")]
pub mod agent;
pub mod apple;
#[cfg(feature = "device")]
pub mod device;
pub mod error;
pub mod keeper;
pub mod mcp;
#[cfg(feature = "device")]
pub mod pairshare;
pub mod paths;
pub mod progress;
pub mod relay;
pub mod release;
mod release_catalog;
pub mod setup;
pub mod sign;
#[cfg(feature = "device")]
pub mod support;
pub mod vault;
#[cfg(feature = "device")]
pub mod update;

pub use error::{Error, Result};
pub use progress::{Progress, Reporter};

/// The app's own version, for the About screen and the support bundle.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
/// The build number baked in by the build scripts (the commit count), when there is one.
pub const BUILD: Option<&str> = option_env!("POKI_SETUP_BUILD");

/// `0.2.2-320`: the version and build as update checks compare them and release file names carry
/// them. People see [`display_version`] instead.
pub fn full_version() -> String {
    match BUILD.filter(|b| !b.is_empty()) {
        Some(b) => format!("{VERSION}-{b}"),
        None => VERSION.to_string(),
    }
}
/// `0.2.2-320` as people read it, `0.2.2 (320)`, the way Poki shows its own version.
pub fn display_version(v: &str) -> String {
    match v.rsplit_once('-') {
        Some((ver, build)) if !build.is_empty() && build.chars().all(|c| c.is_ascii_digit()) => format!("{ver} ({build})"),
        _ => v.to_string(),
    }
}

#[cfg(test)]
mod version_tests {
    #[test]
    fn shows_the_build_in_brackets() {
        assert_eq!(super::display_version("0.2.2-320"), "0.2.2 (320)");
        assert_eq!(super::display_version("0.2.2"), "0.2.2");
    }
}

/// Poki's bundle id as released; a free team gets `<id>.<team>`.
pub const POKI_BUNDLE_ID: &str = "nz.zheha.poki";
/// Poki's app group as released.
pub const POKI_APP_GROUP: &str = "group.nz.zheha.poki";
