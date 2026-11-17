//! A verified renewal of an existing installation, without setup or credential handoffs.
use crate::{Error, Reporter, Result, device, keeper, release, setup, sign};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Installed {
    pub schema: String,
    pub nonce: String,
    pub version: String,
    pub build: String,
    pub channel: release::Channel,
    pub team: String,
    pub bundle_id: String,
    pub app_group: String,
    pub certificate_sha256: String,
    pub extensions: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Target {
    pub version: String,
    pub build: String,
}

pub struct Prepared {
    phone: device::Phone,
    record: keeper::Record,
    installed: Installed,
    release: release::Release,
    unpacked: sign::Unpacked,
    team: crate::apple::portal::Team,
}

fn stop(message: &'static str) -> Error { Error::UpdateCheck(message) }

fn check_installed(installed: &Installed, app: &device::install::InstalledApp, record: &keeper::Record) -> Result<()> {
    if installed.schema != "poki.update/1" || installed.version != app.version || installed.build != app.build || installed.bundle_id != app.bundle_id {
        return Err(stop("Poki's update information is missing or stale; open the installed Poki and retry update-only."));
    }
    if installed.team.is_empty() || app.team.as_deref() != Some(installed.team.as_str()) || installed.team != record.team_id || installed.bundle_id != record.bundle_id {
        return Err(stop("The installed app and this computer have different signing teams; keep Poki installed and use the original signing computer."));
    }
    if installed.app_group != sign::team_app_group(&record.team_id) || installed.certificate_sha256.len() != 64 || !installed.certificate_sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(stop("Poki's app group or public signing identity cannot be verified; keep Poki installed and use its original update method."));
    }
    Ok(())
}

fn check_target(installed: &Installed, unpacked: &sign::Unpacked, channel: release::Channel) -> Result<Target> {
    let old = installed.build.parse::<u64>().ok();
    let new = unpacked.build.parse::<u64>().ok();
    if old.is_none() || new.is_none() || new <= old {
        return Err(stop("The target build is not newer than the installed build; keep Poki installed and wait for a newer build on the same channel."));
    }
    if channel != release::Channel::Beta {
        return Err(stop("The selected release is not a Beta update; keep Poki installed and check for a Beta release."));
    }
    if unpacked.bundles.first().map(|b| b.new_id.as_str()) != Some(installed.bundle_id.as_str()) || unpacked.app_group != installed.app_group {
        return Err(stop("The target app identifier or app group differs from the installed app; keep Poki installed and use its original update method."));
    }
    if installed.extensions.iter().any(|id| !unpacked.bundles.iter().skip(1).any(|b| &b.new_id == id)) {
        return Err(stop("The target cannot preserve every installed extension; keep Poki installed and obtain an update that preserves those extensions."));
    }
    Ok(Target { version: unpacked.version.clone(), build: unpacked.build.clone() })
}

pub async fn readback(udid: &str) -> Result<device::install::InstalledApp> {
    let record = keeper::get(udid)?.ok_or_else(|| stop("This computer has no original installation record; use the original signing computer."))?;
    let phone = setup::pick_phone(Some(udid)).await?;
    installed_app(&phone, &record).await
}

async fn installed_app(phone: &device::Phone, record: &keeper::Record) -> Result<device::install::InstalledApp> {
    device::install::find_apps(phone, crate::POKI_BUNDLE_ID).await?.into_iter().find(|app| app.bundle_id == record.bundle_id)
        .ok_or_else(|| stop("The recorded Poki is not installed on this iPhone; check the selected phone and use first-install only if it has no existing Poki data."))
}

async fn public_snapshot(phone: &device::Phone, bundle: &str) -> Result<Installed> {
    const HELLO: &str = "Documents/PokiSetup/poki-hello.json";
    let read = async || -> Result<serde_json::Value> {
        let bytes = device::container::read_file(phone, bundle, HELLO).await?;
        Ok(serde_json::from_slice(&bytes)?)
    };
    let before = read().await.map_err(|_| stop("Poki has no public update information; open a Poki build with update-only support and retry without reinstalling it."))?;
    if before["update"]["schema"] != "poki.update/1" {
        return Err(stop("This Poki build cannot report its signing identity and extensions; keep it installed and use its existing update method."));
    }
    let nonce = uuid::Uuid::new_v4().to_string();
    let request = serde_json::to_vec(&serde_json::json!({"nonce": nonce}))?;
    device::container::write_file(phone, bundle, "Documents/PokiSetup/update-request.json", &request).await?;
    let wait = async {
        loop {
            if let Ok(hello) = read().await {
                if hello["update"]["nonce"].as_str() == Some(&nonce) {
                    return serde_json::from_value(hello["update"].clone()).map_err(|_| stop("Poki's public update information is incomplete; keep it installed and ask for help with this build."));
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }
    };
    tokio::time::timeout(std::time::Duration::from_secs(10), wait).await
        .map_err(|_| stop("Poki did not answer the update check; open Poki on the unlocked iPhone and retry update-only."))?
}

pub async fn prepare(signer: &mut setup::Signer, udid: Option<&str>, reporter: &Reporter) -> Result<Prepared> {
    let phone = setup::pick_phone(udid).await?;
    let record = keeper::get(&phone.udid)?.ok_or_else(|| stop("This computer has no original installation record; use the original signing computer."))?;
    if !device::pairing::verify(&phone).await? {
        return Err(stop("This iPhone does not trust the original signing computer; restore that connection before retrying update-only."));
    }
    let app = installed_app(&phone, &record).await?;
    let installed = public_snapshot(&phone, &app.bundle_id).await?;
    check_installed(&installed, &app, &record)?;
    if signer.account.team_id.as_deref().is_some_and(|id| id != record.team_id) {
        return Err(stop("The computer selected a different signing team; use the original signing setup without changing the phone."));
    }
    let team = signer.teams().await?.into_iter().find(|t| t.team_id == record.team_id)
        .ok_or_else(|| stop("The signed-in account cannot use the original team; sign in on the original signing computer and retry."))?;
    signer.check_update_identity(&record.team_id, &installed.certificate_sha256).await?;
    let rel = release::latest_in(installed.channel).await?;
    let (ipa, signing_zip) = release::fetch(&rel, reporter).await?;
    let requested = match signing_zip {
        Some(z) => sign::requested_from_signing_zip(&z, "external")?,
        None => Default::default(),
    };
    let unpacked = sign::unpack(&ipa, &record.team_id, &requested, reporter)?;
    check_target(&installed, &unpacked, rel.channel)?;
    Ok(Prepared { phone, record, installed, release: rel, unpacked, team })
}

impl Prepared {
    pub fn summary(&self) -> serde_json::Value {
        serde_json::json!({
            "udid": self.phone.udid,
            "installed": {"version": self.installed.version, "build": self.installed.build, "channel": self.installed.channel},
            "target": {"version": self.unpacked.version, "build": self.unpacked.build},
        })
    }

    pub async fn renew(self, signer: &mut setup::Signer, udid: &str, expected: &Target, reporter: &Reporter) -> Result<keeper::Record> {
        if udid != self.phone.udid || expected != &check_target(&self.installed, &self.unpacked, self.release.channel)? {
            return Err(stop("The prepared update no longer matches the requested target; rerun update-only to inspect it again."));
        }
        let current = installed_app(&self.phone, &self.record).await?;
        let installed = public_snapshot(&self.phone, &self.record.bundle_id).await?;
        check_installed(&installed, &current, &self.record)?;
        check_target(&installed, &self.unpacked, self.release.channel)?;
        if installed.certificate_sha256 != self.installed.certificate_sha256 {
            return Err(stop("The installed signing identity changed during preparation; keep Poki installed and rerun update-only."));
        }
        let out = crate::paths::cache_dir()?.join(format!("update-{}.ipa", uuid::Uuid::new_v4()));
        let built = signer.sign_update(&self.team, self.unpacked, &self.installed.certificate_sha256, &out, &Reporter::silent()).await
            .map_err(|e| match e {
                Error::UpdateCheck(_) | Error::NeedsCode(_) => e,
                _ => stop("The original signing identity could not prepare this update; keep Poki installed and check the original signing computer."),
            })?;
        device::install::install_profiles(&self.phone, &built.profiles, reporter).await?;
        device::install::install_ipa(&self.phone, &built.ipa, true, reporter).await?;
        let record = keeper::Record { version: built.version, build: built.build, release_tag: self.release.tag, signed_at: keeper::now(), profile_expires_at: built.profile_expires_at, last_checked_at: Some(keeper::now()), last_error: None, ..self.record };
        keeper::put(record.clone())?;
        Ok(record)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn installed() -> Installed {
        Installed {
            schema: "poki.update/1".into(), nonce: "fresh-request".into(), version: "0.4.0".into(), build: "100".into(),
            channel: release::Channel::Alpha, team: "TESTTEAM".into(), bundle_id: "nz.zheha.poki.TESTTEAM".into(),
            app_group: "group.nz.zheha.poki.TESTTEAM".into(), certificate_sha256: "a".repeat(64),
            extensions: vec!["nz.zheha.poki.TESTTEAM.widgets".into()],
        }
    }

    fn target(build: &str) -> sign::Unpacked {
        let dir = tempfile::tempdir().unwrap();
        let app = dir.path().join("Poki.app");
        let widget = app.join("PlugIns/PokiWidgets.appex");
        std::fs::create_dir_all(&widget).unwrap();
        let info = serde_json::json!({"CFBundleIdentifier": "nz.zheha.poki", "CFBundleShortVersionString": "0.4.2", "CFBundleVersion": build, "PokiAppGroup": "group.nz.zheha.poki"});
        plist::to_file_xml(app.join("Info.plist"), &info).unwrap();
        plist::to_file_xml(widget.join("Info.plist"), &serde_json::json!({"CFBundleIdentifier": "nz.zheha.poki.widgets"})).unwrap();
        let ipa = dir.path().join("target.ipa");
        sign::package_app(&app, &ipa).unwrap();
        sign::unpack(&ipa, "TESTTEAM", &Default::default(), &Reporter::silent()).unwrap()
    }

    #[test]
    fn target_preserves_build_channel_and_extensions() {
        let installed = installed();
        let target = target("101");
        for version in ["0.4.0", "0.4.1"] {
            for channel in release::Channel::ALL {
                let mut old = installed.clone();
                old.version = version.into();
                old.channel = channel;
                assert_eq!(check_target(&old, &target, release::Channel::Beta).unwrap(), Target { version: "0.4.2".into(), build: "101".into() });
            }
        }
        for build in ["101", "102", "unknown"] {
            let mut changed = installed.clone();
            changed.build = build.into();
            assert!(check_target(&changed, &target, release::Channel::Beta).unwrap_err().to_string().contains("not newer"));
        }
        assert!(check_target(&installed, &target, release::Channel::Alpha).unwrap_err().to_string().contains("Beta"));
        let mut changed = installed.clone();
        changed.extensions.push("nz.zheha.poki.TESTTEAM.tunnel".into());
        assert!(check_target(&changed, &target, release::Channel::Beta).unwrap_err().to_string().contains("every installed extension"));
        let mut changed = installed.clone();
        changed.app_group = "group.custom".into();
        assert!(check_target(&changed, &target, release::Channel::Beta).unwrap_err().to_string().contains("app group"));
        let mut changed = installed;
        changed.bundle_id = "custom.poki".into();
        assert!(check_target(&changed, &target, release::Channel::Beta).unwrap_err().to_string().contains("app identifier"));
    }

    #[test]
    fn installed_facts_must_match_phone_and_original_record() {
        let installed = installed();
        let app = device::install::InstalledApp { bundle_id: installed.bundle_id.clone(), name: "Poki".into(), version: "0.4.0".into(), build: "100".into(), team: Some("TESTTEAM".into()), path: None };
        let record: keeper::Record = serde_json::from_value(serde_json::json!({
            "udid": "fake-phone", "phone_name": "Fixture", "ios": "27.0", "apple_id": "fixture@example.invalid",
            "team_id": "TESTTEAM", "team_name": "Fixture", "team_is_free": true,
            "bundle_id": "nz.zheha.poki.TESTTEAM", "app_group": "group.nz.zheha.poki.TESTTEAM",
            "version": "0.3.0", "build": "90", "release_tag": "app-alpha-latest", "signed_at": 0,
            "profile_expires_at": 0, "pairing_handed_off": true,
        })).unwrap();
        check_installed(&installed, &app, &record).unwrap();
        let mut changed = app.clone();
        changed.team = Some("OTHERTEAM".into());
        assert!(check_installed(&installed, &changed, &record).unwrap_err().to_string().contains("different signing teams"));
        changed.team = None;
        assert!(check_installed(&installed, &changed, &record).is_err());
        let mut changed = app;
        changed.build = "99".into();
        assert!(check_installed(&installed, &changed, &record).unwrap_err().to_string().contains("stale"));
        changed.build = "100".into();
        for channel in release::Channel::ALL {
            let mut old = installed.clone();
            old.channel = channel;
            check_installed(&old, &changed, &record).unwrap();
        }
    }
}
