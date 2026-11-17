//! Re-signing Poki's IPA for a team.
//!
//! 1. unpack the IPA; 2. give every bundle the team's ids (`nz.zheha.poki.<TEAM>`, extensions
//! under it, the app group `group.nz.zheha.poki.<TEAM>`); 3. drop extensions whose entitlements
//! a team profile cannot carry (the packet tunnel); 4. embed each bundle's profile and merge its
//! entitlements by AltSign's rule; 5. sign everything with apple-codesign; 6. zip it back.
pub mod entitlements;
pub mod profile;

use crate::apple::identity::Identity;
use crate::{Error, Result, Reporter};
use apple_codesign::{SettingsScope, SigningSettings, UnifiedSigner, cryptography::InMemoryPrivateKey};
use x509_certificate::CapturedX509Certificate;
use std::path::{Path, PathBuf};

/// One bundle inside the IPA that needs its own App ID and profile.
#[derive(Debug, Clone)]
pub struct Bundle {
    /// Relative to the .app, "" for the app itself.
    pub rel: String,
    pub path: PathBuf,
    pub name: String,
    pub old_id: String,
    pub new_id: String,
    pub requested: plist::Dictionary,
}

pub struct Unpacked {
    pub work: tempfile::TempDir,
    pub app_dir: PathBuf,
    pub bundles: Vec<Bundle>,
    pub app_group: String,
    pub version: String,
    pub build: String,
    pub dropped_extensions: Vec<String>,
}

/// Bundle id for a team: the released id with the team id appended, extensions under it.
pub fn team_bundle_id(released: &str, team: &str) -> String {
    let base = crate::POKI_BUNDLE_ID;
    // Already this team's (re-signing an installed copy): keep it.
    let teamed = format!("{base}.{team}");
    if released == teamed || released.starts_with(&format!("{teamed}.")) {
        return released.to_string();
    }
    if released == base {
        format!("{base}.{team}")
    } else if let Some(rest) = released.strip_prefix(&format!("{base}.")) {
        format!("{base}.{team}.{rest}")
    } else {
        format!("{released}.{team}")
    }
}

pub fn team_app_group(team: &str) -> String { format!("{}.{}", crate::POKI_APP_GROUP, team) }

/// Unpacks and rewrites ids. `requested` maps a bundle name (Poki, PokiWidgets) to its built
/// entitlements when Poki-signing.zip is at hand.
pub fn unpack(ipa: &Path, team: &str, requested: &std::collections::HashMap<String, plist::Dictionary>, reporter: &Reporter) -> Result<Unpacked> {
    let work = tempfile::Builder::new().prefix("poki-sign-").tempdir()?;
    reporter.part("sign", 0.05, Some("Unpacking".into()));
    unzip(ipa, work.path())?;
    let payload = work.path().join("Payload");
    let app_dir = std::fs::read_dir(&payload)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .find(|p| p.extension().map(|e| e == "app").unwrap_or(false))
        .ok_or_else(|| Error::Sign("the IPA has no Payload/*.app".into()))?;
    let group = team_app_group(team);
    let mut bundles = vec![];
    let mut dropped = vec![];

    // Extensions first: the packet tunnel cannot be signed with a team profile, so it goes.
    let plugins = app_dir.join("PlugIns");
    if plugins.is_dir() {
        for e in std::fs::read_dir(&plugins)? {
            let p = e?.path();
            if p.extension().map(|x| x == "appex").unwrap_or(false) {
                let info = read_info(&p)?;
                let point = info.get("NSExtension").and_then(|n| n.as_dictionary()).and_then(|n| n.get("NSExtensionPointIdentifier")).and_then(|s| s.as_string()).unwrap_or("");
                if point == "com.apple.networkextension.packet-tunnel" {
                    dropped.push(p.file_name().unwrap().to_string_lossy().to_string());
                    std::fs::remove_dir_all(&p)?;
                    continue;
                }
            }
        }
    }
    let (version, build) = {
        let info = read_info(&app_dir)?;
        (info.get("CFBundleShortVersionString").and_then(|s| s.as_string()).unwrap_or("").to_string(), info.get("CFBundleVersion").and_then(|s| s.as_string()).unwrap_or("").to_string())
    };
    let mut paths = vec![app_dir.clone()];
    if plugins.is_dir() {
        let mut ex: Vec<_> = std::fs::read_dir(&plugins)?.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.extension().map(|x| x == "appex").unwrap_or(false)).collect();
        ex.sort();
        paths.extend(ex);
    }
    for p in paths {
        let mut info = read_info(&p)?;
        let old_id = info.get("CFBundleIdentifier").and_then(|s| s.as_string()).unwrap_or("").to_string();
        let new_id = team_bundle_id(&old_id, team);
        info.insert("CFBundleIdentifier".into(), new_id.clone().into());
        // Background task identifiers must start with the bundle id (iOS 26's continued run).
        if let Some(plist::Value::Array(ids)) = info.get_mut("BGTaskSchedulerPermittedIdentifiers") {
            for id in ids.iter_mut() {
                let renamed = id.as_string().and_then(|s| s.strip_prefix(old_id.as_str()))
                    .filter(|rest| rest.is_empty() || rest.starts_with('.'))
                    .map(|rest| format!("{new_id}{rest}"));
                if let Some(renamed) = renamed { *id = renamed.into(); }
            }
        }
        if info.contains_key("PokiAppGroup") {
            info.insert("PokiAppGroup".into(), group.clone().into());
        }
        write_info(&p, &info)?;
        let name = p.file_stem().unwrap().to_string_lossy().to_string();
        let rel = p.strip_prefix(&app_dir).map(|r| r.to_string_lossy().to_string()).unwrap_or_default();
        let mut req = requested.get(&name).cloned().unwrap_or_else(|| entitlements::poki_defaults(crate::POKI_APP_GROUP));
        if let Some(plist::Value::Array(groups)) = req.get_mut("com.apple.security.application-groups") {
            *groups = vec![group.clone().into()];
        }
        bundles.push(Bundle { rel, path: p, name, old_id, new_id, requested: req });
    }
    // Stale signatures from the build (ad-hoc, if any) would confuse nothing, but the old
    // profile would: remove any.
    for b in &bundles {
        let _ = std::fs::remove_file(b.path.join("embedded.mobileprovision"));
    }
    Ok(Unpacked { work, app_dir, bundles, app_group: group, version, build, dropped_extensions: dropped })
}

pub fn read_info(bundle: &Path) -> Result<plist::Dictionary> {
    Ok(plist::from_file(bundle.join("Info.plist")).map_err(|e| Error::Sign(format!("{}: Info.plist: {e}", bundle.display())))?)
}

fn write_info(bundle: &Path, info: &plist::Dictionary) -> Result<()> {
    plist::to_file_binary(bundle.join("Info.plist"), info).map_err(|e| Error::Sign(format!("Info.plist write: {e}")))?;
    Ok(())
}

/// Places profiles and signs the whole app in one pass.
pub fn sign(unpacked: &Unpacked, identity: &Identity, profiles: &[(String, profile::Profile)], reporter: &Reporter) -> Result<Vec<String>> {
    let key = InMemoryPrivateKey::from_pkcs8_der(&identity.key_pkcs8).map_err(|e| Error::Sign(format!("key: {e}")))?;
    let cert = CapturedX509Certificate::from_der(identity.certificate.der.clone()).map_err(|e| Error::Sign(format!("certificate: {e}")))?;
    let mut settings = SigningSettings::default();
    settings.set_signing_key(&key, cert);
    settings.chain_apple_certificates();
    settings.set_team_id(&identity.team_id);
    let mut notes = vec![];
    for b in &unpacked.bundles {
        let (_, prof) = profiles.iter().find(|(id, _)| *id == b.new_id).ok_or_else(|| Error::Sign(format!("no profile for {}", b.new_id)))?;
        std::fs::write(b.path.join("embedded.mobileprovision"), &prof.raw)?;
        let merged = entitlements::merge(&b.requested, &prof.entitlements);
        for d in entitlements::dropped(&b.requested, &merged) {
            notes.push(format!("{}: signed without {d} (this team's profile does not carry it)", b.name));
        }
        let scope = if b.rel.is_empty() { SettingsScope::Main } else { SettingsScope::Path(b.rel.clone()) };
        settings.set_entitlements_xml(scope.clone(), entitlements::to_xml(&merged)).map_err(|e| Error::Sign(e.to_string()))?;
        settings.set_binary_identifier(scope, &b.new_id);
    }
    reporter.part("sign", 0.5, Some("Signing".into()));
    let signer = UnifiedSigner::new(settings);
    signer.sign_path_in_place(&unpacked.app_dir).map_err(|e| Error::Sign(e.to_string()))?;
    Ok(notes)
}

/// Zips Payload/ back into an IPA.
pub fn pack(unpacked: &Unpacked, out: &Path) -> Result<()> {
    let file = std::fs::File::create(out)?;
    let mut zip = zip::ZipWriter::new(file);
    let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated).unix_permissions(0o755);
    let root = unpacked.work.path();
    for entry in walkdir::WalkDir::new(root.join("Payload")).sort_by_file_name() {
        let entry = entry.map_err(|e| Error::Sign(e.to_string()))?;
        let rel = entry.path().strip_prefix(root).unwrap().to_string_lossy().replace('\\', "/");
        if entry.file_type().is_dir() {
            zip.add_directory(format!("{rel}/"), opts).map_err(|e| Error::Sign(e.to_string()))?;
        } else if entry.file_type().is_symlink() {
            let target = std::fs::read_link(entry.path())?;
            zip.add_symlink(rel, target.to_string_lossy(), opts).map_err(|e| Error::Sign(e.to_string()))?;
        } else {
            zip.start_file(rel, opts).map_err(|e| Error::Sign(e.to_string()))?;
            let mut f = std::fs::File::open(entry.path())?;
            std::io::copy(&mut f, &mut zip)?;
        }
    }
    zip.finish().map_err(|e| Error::Sign(e.to_string()))?;
    Ok(())
}

/// Packs an installed .app (Poki's own bundle on the iPhone) as an IPA, so a refresh re-signs
/// exactly the build that is installed. Its old signatures and profiles are replaced by `sign`.
pub fn package_app(app_dir: &Path, out: &Path) -> Result<()> {
    let name = app_dir.file_name().ok_or_else(|| Error::Sign("the app has no name".into()))?.to_string_lossy().to_string();
    let file = std::fs::File::create(out)?;
    let mut zip = zip::ZipWriter::new(file);
    let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored).unix_permissions(0o755);
    zip.add_directory("Payload/", opts).map_err(|e| Error::Sign(e.to_string()))?;
    for entry in walkdir::WalkDir::new(app_dir).sort_by_file_name() {
        let entry = entry.map_err(|e| Error::Sign(e.to_string()))?;
        let inner = entry.path().strip_prefix(app_dir).unwrap().to_string_lossy().replace('\\', "/");
        let rel = if inner.is_empty() { format!("Payload/{name}") } else { format!("Payload/{name}/{inner}") };
        if entry.file_type().is_dir() {
            zip.add_directory(format!("{rel}/"), opts).map_err(|e| Error::Sign(e.to_string()))?;
        } else if entry.file_type().is_symlink() {
            let target = std::fs::read_link(entry.path())?;
            zip.add_symlink(rel, target.to_string_lossy(), opts).map_err(|e| Error::Sign(e.to_string()))?;
        } else {
            zip.start_file(rel, opts).map_err(|e| Error::Sign(e.to_string()))?;
            let mut f = std::fs::File::open(entry.path())?;
            std::io::copy(&mut f, &mut zip)?;
        }
    }
    zip.finish().map_err(|e| Error::Sign(e.to_string()))?;
    Ok(())
}

pub fn unzip(archive: &Path, into: &Path) -> Result<()> {
    let file = std::fs::File::open(archive)?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| Error::Sign(format!("not a zip: {e}")))?;
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| Error::Sign(e.to_string()))?;
        let Some(rel) = entry.enclosed_name() else { continue };
        let out = into.join(rel);
        if entry.is_dir() {
            std::fs::create_dir_all(&out)?;
            continue;
        }
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent)?;
        }
        #[cfg(unix)]
        if entry.unix_mode().map(|m| m & 0o170000 == 0o120000).unwrap_or(false) {
            let mut target = String::new();
            std::io::Read::read_to_string(&mut entry, &mut target)?;
            let _ = std::fs::remove_file(&out);
            std::os::unix::fs::symlink(target, &out)?;
            continue;
        }
        let mut f = std::fs::File::create(&out)?;
        std::io::copy(&mut entry, &mut f)?;
        #[cfg(unix)]
        if let Some(mode) = entry.unix_mode() {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&out, std::fs::Permissions::from_mode(mode & 0o777));
        }
    }
    Ok(())
}

/// Reads the entitlements the app was built with from Poki-signing.zip (`<edition>/<Name>.entitlements`).
pub fn requested_from_signing_zip(zip_path: &Path, edition: &str) -> Result<std::collections::HashMap<String, plist::Dictionary>> {
    let file = std::fs::File::open(zip_path)?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| Error::Sign(format!("signing zip: {e}")))?;
    let mut out = std::collections::HashMap::new();
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| Error::Sign(e.to_string()))?;
        let name = entry.name().to_string();
        let Some(file) = name.strip_suffix(".entitlements") else { continue };
        let parts: Vec<&str> = file.split('/').collect();
        if parts.len() < 2 || parts[parts.len() - 2] != edition {
            continue;
        }
        let mut bytes = vec![];
        std::io::Read::read_to_end(&mut entry, &mut bytes)?;
        if let Ok(d) = plist::from_bytes::<plist::Dictionary>(&bytes) {
            out.insert(parts[parts.len() - 1].to_string(), d);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ids() {
        assert_eq!(team_bundle_id("nz.zheha.poki", "ABC123"), "nz.zheha.poki.ABC123");
        assert_eq!(team_bundle_id("nz.zheha.poki.widgets", "ABC123"), "nz.zheha.poki.ABC123.widgets");
        assert_eq!(team_app_group("ABC123"), "group.nz.zheha.poki.ABC123");
        // Re-signing an installed copy keeps its ids.
        assert_eq!(team_bundle_id("nz.zheha.poki.ABC123", "ABC123"), "nz.zheha.poki.ABC123");
        assert_eq!(team_bundle_id("nz.zheha.poki.ABC123.widgets", "ABC123"), "nz.zheha.poki.ABC123.widgets");
    }

    /// An installed .app packs into an IPA that unpacks with the same ids for the same team.
    #[test]
    fn package_installed_app_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let app = dir.path().join("Poki.app");
        std::fs::create_dir_all(app.join("PlugIns/PokiWidgets.appex")).unwrap();
        let mut info = plist::Dictionary::new();
        info.insert("CFBundleIdentifier".into(), "nz.zheha.poki.ABC123".into());
        info.insert("PokiAppGroup".into(), "group.nz.zheha.poki.ABC123".into());
        info.insert("CFBundleShortVersionString".into(), "0.2.8".into());
        info.insert("CFBundleVersion".into(), "110".into());
        plist::to_file_binary(app.join("Info.plist"), &info).unwrap();
        std::fs::write(app.join("embedded.mobileprovision"), b"old").unwrap();
        let mut w = plist::Dictionary::new();
        w.insert("CFBundleIdentifier".into(), "nz.zheha.poki.ABC123.widgets".into());
        plist::to_file_xml(app.join("PlugIns/PokiWidgets.appex/Info.plist"), &w).unwrap();
        let ipa = dir.path().join("Poki.ipa");
        package_app(&app, &ipa).unwrap();
        let u = unpack(&ipa, "ABC123", &Default::default(), &crate::Reporter::silent()).unwrap();
        let ids: Vec<_> = u.bundles.iter().map(|b| b.new_id.as_str()).collect();
        assert_eq!(ids, ["nz.zheha.poki.ABC123", "nz.zheha.poki.ABC123.widgets"]);
        assert_eq!(u.build, "110");
        assert!(!u.app_dir.join("embedded.mobileprovision").exists());
    }

    /// A fake IPA with an app, a widget and a packet tunnel: ids are rewritten, the tunnel goes,
    /// and the result zips back with the same layout.
    #[test]
    fn unpack_rewrites_and_drops_tunnel() {
        let dir = tempfile::tempdir().unwrap();
        let app = dir.path().join("Payload/Poki.app");
        std::fs::create_dir_all(app.join("PlugIns/PokiWidgets.appex")).unwrap();
        std::fs::create_dir_all(app.join("PlugIns/PokiTunnel.appex")).unwrap();
        let mut info = plist::Dictionary::new();
        info.insert("CFBundleIdentifier".into(), "nz.zheha.poki".into());
        info.insert("PokiAppGroup".into(), "group.nz.zheha.poki".into());
        info.insert("CFBundleShortVersionString".into(), "0.2.7".into());
        info.insert("CFBundleVersion".into(), "70".into());
        info.insert("BGTaskSchedulerPermittedIdentifiers".into(), plist::Value::Array(vec!["nz.zheha.poki.run.*".into(), "nz.zheha.pokiother".into()]));
        plist::to_file_binary(app.join("Info.plist"), &info).unwrap();
        std::fs::write(app.join("Poki"), b"binary").unwrap();
        let mut w = plist::Dictionary::new();
        w.insert("CFBundleIdentifier".into(), "nz.zheha.poki.widgets".into());
        w.insert("PokiAppGroup".into(), "group.nz.zheha.poki".into());
        let mut ext = plist::Dictionary::new();
        ext.insert("NSExtensionPointIdentifier".into(), "com.apple.widgetkit-extension".into());
        w.insert("NSExtension".into(), plist::Value::Dictionary(ext.clone()));
        plist::to_file_xml(app.join("PlugIns/PokiWidgets.appex/Info.plist"), &w).unwrap();
        let mut t = w.clone();
        t.insert("CFBundleIdentifier".into(), "nz.zheha.poki.tunnel".into());
        ext.insert("NSExtensionPointIdentifier".into(), "com.apple.networkextension.packet-tunnel".into());
        t.insert("NSExtension".into(), plist::Value::Dictionary(ext));
        plist::to_file_xml(app.join("PlugIns/PokiTunnel.appex/Info.plist"), &t).unwrap();
        let ipa = dir.path().join("Poki.ipa");
        {
            let f = std::fs::File::create(&ipa).unwrap();
            let mut z = zip::ZipWriter::new(f);
            let o = zip::write::SimpleFileOptions::default();
            for e in walkdir::WalkDir::new(dir.path().join("Payload")) {
                let e = e.unwrap();
                let rel = e.path().strip_prefix(dir.path()).unwrap().to_string_lossy().to_string();
                if e.file_type().is_file() {
                    z.start_file(rel, o).unwrap();
                    std::io::copy(&mut std::fs::File::open(e.path()).unwrap(), &mut z).unwrap();
                }
            }
            z.finish().unwrap();
        }
        let u = unpack(&ipa, "TEAM1", &Default::default(), &Reporter::silent()).unwrap();
        assert_eq!(u.dropped_extensions, vec!["PokiTunnel.appex"]);
        assert_eq!(u.bundles.len(), 2);
        assert_eq!(u.bundles[0].new_id, "nz.zheha.poki.TEAM1");
        assert_eq!(u.bundles[1].new_id, "nz.zheha.poki.TEAM1.widgets");
        assert_eq!(u.bundles[1].rel, "PlugIns/PokiWidgets.appex");
        assert_eq!(u.version, "0.2.7");
        let info = read_info(&u.app_dir).unwrap();
        assert_eq!(info.get("PokiAppGroup").unwrap().as_string(), Some("group.nz.zheha.poki.TEAM1"));
        let ids: Vec<_> = info.get("BGTaskSchedulerPermittedIdentifiers").unwrap().as_array().unwrap().iter().filter_map(|v| v.as_string()).collect();
        assert_eq!(ids, vec!["nz.zheha.poki.TEAM1.run.*", "nz.zheha.pokiother"]);
        assert_eq!(u.bundles[0].requested.get("com.apple.security.application-groups").unwrap().as_array().unwrap()[0].as_string(), Some("group.nz.zheha.poki.TEAM1"));
        let out = dir.path().join("out.ipa");
        pack(&u, &out).unwrap();
        let z = zip::ZipArchive::new(std::fs::File::open(&out).unwrap()).unwrap();
        let names: Vec<_> = z.file_names().collect();
        assert!(names.contains(&"Payload/Poki.app/Info.plist"));
        assert!(!names.iter().any(|n| n.contains("PokiTunnel")));
    }
}

/// Signs an IPA with a throwaway identity and stand-in profiles, exactly as a real install would
/// apart from Apple's part, so a Mac can check the result with `codesign --verify`. Returns notes.
pub fn selftest(ipa: &Path, signing_zip: Option<&Path>, out: &Path, team: &str) -> Result<Vec<String>> {
    let reporter = Reporter::silent();
    let requested = match signing_zip {
        Some(z) => requested_from_signing_zip(z, "external")?,
        None => Default::default(),
    };
    let unpacked = unpack(ipa, team, &requested, &reporter)?;
    let identity = crate::apple::identity::self_signed(team)?;
    let mut profiles = vec![];
    for b in &unpacked.bundles {
        let mut ents = plist::Dictionary::new();
        ents.insert("application-identifier".into(), format!("{team}.{}", b.new_id).into());
        ents.insert("com.apple.developer.team-identifier".into(), team.into());
        ents.insert("get-task-allow".into(), true.into());
        ents.insert("keychain-access-groups".into(), plist::Value::Array(vec![format!("{team}.*").into()]));
        ents.insert("com.apple.security.application-groups".into(), plist::Value::Array(vec![unpacked.app_group.clone().into()]));
        profiles.push((
            b.new_id.clone(),
            profile::Profile { uuid: "00000000-0000-0000-0000-000000000000".into(), name: "Poki Setup Self-Test".into(), team_id: team.into(), app_id: format!("{team}.{}", b.new_id), entitlements: ents, expires_at: 0, raw: b"selftest-profile".to_vec() },
        ));
    }
    let mut notes = sign(&unpacked, &identity, &profiles, &reporter)?;
    pack(&unpacked, out)?;
    notes.insert(0, format!("{} bundles: {}", unpacked.bundles.len(), unpacked.bundles.iter().map(|b| format!("{} -> {}", b.old_id, b.new_id)).collect::<Vec<_>>().join(", ")));
    if !unpacked.dropped_extensions.is_empty() {
        notes.push(format!("left out: {}", unpacked.dropped_extensions.join(", ")));
    }
    Ok(notes)
}
