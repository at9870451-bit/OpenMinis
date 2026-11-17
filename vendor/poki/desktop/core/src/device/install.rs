//! Installing the signed IPA: profiles through misagent, the app through installation_proxy.
use super::Phone;
use crate::{Error, Reporter, Result};
use idevice::{IdeviceService, installation_proxy::InstallationProxyClient, misagent::MisagentClient, utils::installation};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstalledApp {
    pub bundle_id: String,
    pub name: String,
    pub version: String,
    pub build: String,
    /// `TeamIdentifier` from the app's signing, when iOS reports it.
    pub team: Option<String>,
    pub path: Option<String>,
}

/// Installs every profile the signer produced. A profile that is already there is replaced.
pub async fn install_profiles(phone: &Phone, profiles: &[Vec<u8>], reporter: &Reporter) -> Result<()> {
    if profiles.is_empty() {
        return Ok(());
    }
    reporter.step("profiles", "Installing the provisioning profiles");
    tracing::info!(count = profiles.len(), "installing provisioning profiles");
    let provider = phone.provider()?;
    let mut misagent = within(30, "connecting to the iPhone's profile service", MisagentClient::connect(&*provider)).await??;
    for (i, p) in profiles.iter().enumerate() {
        within(60, "installing a provisioning profile", misagent.install(p.clone()))
            .await?
            .map_err(|e| Error::device(format!("The iPhone refused a provisioning profile: {e}. On a free team the phone must be registered on the Apple ID; sign in again.")))?;
        tracing::info!(profile = i + 1, "profile installed");
        reporter.part("profiles", (i + 1) as f64 / profiles.len() as f64, None);
    }
    reporter.done("profiles", None);
    Ok(())
}

/// Installs or upgrades the IPA at `ipa`. An upgrade keeps the app's data; iOS treats an install
/// of a bundle id that is already there as an upgrade too, when the team matches.
pub async fn install_ipa(phone: &Phone, ipa: &Path, upgrade: bool, reporter: &Reporter) -> Result<()> {
    reporter.step("install", if upgrade { "Updating Poki on the iPhone" } else { "Installing Poki on the iPhone" });
    let size = std::fs::metadata(ipa).map(|m| m.len()).unwrap_or(0);
    tracing::info!(upgrade, bytes = size, ipa = %ipa.display(), "uploading and installing the app");
    let provider = phone.provider()?;
    let r = reporter.clone();
    let cb = move |(percent, _): (u64, ())| {
        let r = r.clone();
        async move {
            tracing::info!(percent, "install progress");
            r.part("install", percent as f64 / 100.0, None)
        }
    };
    // iOS reports progress while it installs; ten minutes covers a slow cable and a big app.
    let work = async {
        if upgrade {
            installation::upgrade_package_with_callback(&*provider, ipa, None, cb, ()).await
        } else {
            installation::install_package_with_callback(&*provider, ipa, None, cb, ()).await
        }
    };
    let result = within(600, "installing Poki (unlock the iPhone, check it for a prompt, then try again)", work).await?;
    tracing::info!(ok = result.is_ok(), "install finished");
    result.map_err(install_error)?;
    reporter.done("install", None);
    Ok(())
}

fn install_error(e: idevice::IdeviceError) -> Error {
    match e {
        idevice::IdeviceError::InstallationProxy(idevice::services::installation_proxy::InstallationProxyError::OperationFailed(ref text)) if text.contains("ApplicationVerificationFailed") => Error::device(
            "The iPhone did not accept the app's signature. Make sure this iPhone is registered on the Apple ID's team and Developer Mode is on, then try again.",
        ),
        idevice::IdeviceError::InstallationProxy(idevice::services::installation_proxy::InstallationProxyError::OperationFailed(ref text)) if text.contains("MismatchedApplicationIdentifierEntitlement") => Error::device(
            "The installed Poki has a different application signing identity. Keep Poki installed to preserve its data, and update it using the original signing identity on the original computer.",
        ),
        other => Error::device(format!("Install failed: {other}")),
    }
}

/// Runs `fut`, or fails with a readable error after `secs` seconds.
async fn within<T>(secs: u64, what: &str, fut: impl std::future::Future<Output = T>) -> Result<T> {
    match tokio::time::timeout(std::time::Duration::from_secs(secs), fut).await {
        Ok(v) => Ok(v),
        Err(_) => {
            tracing::warn!(secs, what, "timed out");
            Err(Error::device(format!("The iPhone stopped answering while {what}. Unplug it, plug it in again and unlock it, then try again.")))
        }
    }
}

pub async fn uninstall(phone: &Phone, bundle_id: &str) -> Result<()> {
    let provider = phone.provider()?;
    let mut ip = InstallationProxyClient::connect(&*provider).await?;
    ip.uninstall(bundle_id, None).await?;
    Ok(())
}

/// The user apps on the phone whose bundle id starts with `prefix` (Poki under any team).
pub async fn find_apps(phone: &Phone, prefix: &str) -> Result<Vec<InstalledApp>> {
    let provider = phone.provider()?;
    let mut ip = within(30, "listing apps", InstallationProxyClient::connect(&*provider)).await??;
    let apps = within(60, "listing apps", ip.get_apps(Some("User"), None)).await??;
    let mut out = Vec::new();
    for (id, v) in apps {
        if !id.starts_with(prefix) {
            continue;
        }
        let d = v.as_dictionary().cloned().unwrap_or_default();
        let s = |k: &str| d.get(k).and_then(|x| x.as_string()).map(|x| x.to_string());
        out.push(InstalledApp {
            bundle_id: id,
            name: s("CFBundleDisplayName").or_else(|| s("CFBundleName")).unwrap_or_default(),
            version: s("CFBundleShortVersionString").unwrap_or_default(),
            build: s("CFBundleVersion").unwrap_or_default(),
            team: s("TeamIdentifier").or_else(|| s("ApplicationDSID")),
            path: s("Path"),
        });
    }
    out.sort_by(|a, b| a.bundle_id.cmp(&b.bundle_id));
    Ok(out)
}

#[cfg(test)]
mod tests {
    #[test]
    fn identity_mismatch_keeps_the_existing_app_and_its_data() {
        let failure = idevice::IdeviceError::InstallationProxy(
            idevice::services::installation_proxy::InstallationProxyError::OperationFailed(
                "MismatchedApplicationIdentifierEntitlement".into(),
            ),
        );
        let message = super::install_error(failure).to_string();
        assert!(message.contains("Keep Poki installed"), "{message}");
        assert!(message.contains("original signing identity"), "{message}");
        assert!(!message.contains("Delete it"), "{message}");
    }
}
