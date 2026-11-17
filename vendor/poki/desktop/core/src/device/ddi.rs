//! The personalized developer disk image (iOS 17 and later). Poki downloads it itself on the
//! phone, from the same mirror; this module has it on the computer too, to mount it once as a
//! proof that automation can start, and to pre-seed Poki's container so the phone skips the
//! download. Files are checked against the SHA-384 digests in `BuildManifest.plist`, as Poki does.
use super::Phone;
use crate::{Error, Reporter, Result, paths};
use idevice::{IdeviceService, lockdown::LockdownClient, mobile_image_mounter::ImageMounter};
use sha2::{Digest, Sha384};
use std::path::{Path, PathBuf};

const MIRROR_BASE: &str = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages";

/// Which image a phone takes. iOS 26.4 and later install a Cryptex1 cryptex; earlier iOS mounts the
/// personalized image through the image mounter. Poki on the phone picks by the same rule.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Cryptex,
    Personalized,
}

impl Kind {
    /// The image for an iOS version ("18.7.7"); the cryptex when the version cannot be read.
    pub fn for_ios(ios: &str) -> Self {
        let mut parts = ios.trim().split('.');
        let Some(major) = parts.next().and_then(|p| p.parse::<u32>().ok()) else { return Kind::Cryptex };
        let minor = parts.next().and_then(|p| p.parse::<u32>().ok()).unwrap_or(0);
        if (major, minor) >= (26, 4) { Kind::Cryptex } else { Kind::Personalized }
    }

    pub fn mirror(self) -> String {
        format!("{MIRROR_BASE}/{}", if self == Kind::Cryptex { "Xcode_iOS_DDI_Cryptex" } else { "Xcode_iOS_DDI_Personalized" })
    }

    pub fn files(self) -> &'static [&'static str] {
        match self {
            Kind::Cryptex => &["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache", "Image.dmg.cryptex_info", "Image.dmg.root_hash"],
            Kind::Personalized => &["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"],
        }
    }

    fn payload_keys(self) -> &'static [&'static str] {
        match self {
            Kind::Cryptex => &["Cryptex1,GenericDmg", "Cryptex1,GenericTrustCache", "Cryptex1,CryptexInfoPlist", "Cryptex1,GenericVolume"],
            Kind::Personalized => &["PersonalizedDMG", "LoadableTrustCache"],
        }
    }
}

/// The image this phone takes, by the iOS version lockdown reports.
pub async fn kind_of(phone: &Phone) -> Kind {
    let ios = async {
        let provider = phone.provider().ok()?;
        let mut lockdown = LockdownClient::connect(&*provider).await.ok()?;
        lockdown.get_value(Some("ProductVersion"), None).await.ok()?.as_string().map(str::to_string)
    }
    .await;
    Kind::for_ios(ios.as_deref().unwrap_or(""))
}

pub fn dir(kind: Kind) -> Result<PathBuf> {
    Ok(paths::cache_dir()?.join(if kind == Kind::Cryptex { "ddi" } else { "ddi-personalized" }))
}

/// Checks one build identity's payloads against the files in `dir`.
fn check(entries: &plist::Dictionary, keys: &[&str], dir: &Path) -> Result<()> {
    for key in keys {
        let entry = entries.get(key).and_then(|e| e.as_dictionary());
        let path = entry
            .and_then(|e| e.get("Info"))
            .and_then(|i| i.as_dictionary())
            .and_then(|i| i.get("Path"))
            .and_then(|p| p.as_string())
            .filter(|p| !p.is_empty() && !p.starts_with('/') && !p.split('/').any(|s| s == ".."))
            .ok_or_else(|| Error::msg(format!("BuildManifest.plist gives no usable path for {key}")))?;
        let digest = entry.and_then(|e| e.get("Digest")).and_then(|d| d.as_data()).ok_or_else(|| Error::msg(format!("no digest for {key}")))?;
        let bytes = std::fs::read(dir.join(path)).map_err(|_| Error::msg(format!("{path} is missing")))?;
        if Sha384::digest(&bytes).as_slice() != digest {
            return Err(Error::msg(format!("{path} does not match its SHA-384 digest")));
        }
    }
    Ok(())
}

/// Checks every payload in `dir` against the manifest; returns the image's build. The cryptex
/// manifest is checked by its first identity. The personalized manifest lists the same file names
/// with different digests for different chips, so the files must match any one identity whole.
pub fn verify(dir: &Path, kind: Kind) -> Result<String> {
    let manifest: plist::Dictionary = plist::from_file(dir.join("BuildManifest.plist"))
        .map_err(|_| Error::msg("BuildManifest.plist is missing or unreadable"))?;
    let keys = kind.payload_keys();
    let identities = manifest.get("BuildIdentities").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    let candidates: Vec<&plist::Dictionary> = identities
        .iter()
        .filter_map(|v| v.as_dictionary())
        .filter_map(|id| id.get("Manifest").and_then(|m| m.as_dictionary()))
        .filter(|m| keys.iter().all(|k| m.contains_key(*k)))
        .collect();
    let mut first = None;
    for entries in candidates.iter().take(if kind == Kind::Cryptex { 1 } else { usize::MAX }) {
        match check(entries, keys, dir) {
            Ok(()) => return Ok(manifest.get("ProductBuildVersion").and_then(|v| v.as_string()).unwrap_or("unknown").to_string()),
            Err(e) => first = first.or(Some(e)),
        }
    }
    Err(first.unwrap_or_else(|| Error::msg("BuildManifest.plist has no build identity for this kind of image")))
}

/// Makes sure the image is on this computer, downloading it when it is not. Returns its build.
pub async fn ensure(reporter: &Reporter, kind: Kind) -> Result<(PathBuf, String)> {
    let dir = dir(kind)?;
    let (files, mirror) = (kind.files(), kind.mirror());
    if let Ok(build) = verify(&dir, kind) {
        return Ok((dir, build));
    }
    reporter.step("ddi", "Downloading the developer disk image");
    let partial = dir.with_extension("partial");
    let _ = std::fs::remove_dir_all(&partial);
    std::fs::create_dir_all(&partial)?;
    let client = reqwest::Client::builder().user_agent(concat!("PokiSetup/", env!("CARGO_PKG_VERSION"))).build()?;
    for (i, name) in files.iter().enumerate() {
        reporter.part("ddi", i as f64 / files.len() as f64, Some(format!("Downloading {name}")));
        let res = client.get(format!("{mirror}/{name}")).send().await?;
        if !res.status().is_success() {
            let _ = std::fs::remove_dir_all(&partial);
            return Err(Error::msg(format!("downloading {name} failed with HTTP {}", res.status())));
        }
        std::fs::write(partial.join(name), res.bytes().await?)?;
    }
    let build = verify(&partial, kind).inspect_err(|_| {
        let _ = std::fs::remove_dir_all(&partial);
    })?;
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::rename(&partial, &dir)?;
    reporter.done("ddi", Some(format!("Image build {build}.")));
    Ok((dir, build))
}

/// Whether a personalized image is mounted right now.
pub async fn mounted(phone: &Phone) -> Result<bool> {
    let provider = phone.provider()?;
    let mut mounter = ImageMounter::connect(&*provider).await?;
    let images = mounter.copy_devices().await?;
    Ok(images.iter().any(|i| {
        i.as_dictionary()
            .and_then(|d| d.get("DiskImageType"))
            .and_then(|t| t.as_string())
            .is_some_and(|t| t == "Personalized")
    }))
}

/// Mounts the image from this computer (needs internet for Apple's TSS signature). Poki mounts it
/// again by itself after every restart; this is the proof that the phone accepts it.
pub async fn mount(phone: &Phone, reporter: &Reporter) -> Result<()> {
    if mounted(phone).await? {
        reporter.note("mount", "The developer disk image is already mounted.");
        return Ok(());
    }
    let (dir, _) = ensure(reporter, kind_of(phone).await).await?;
    reporter.step("mount", "Mounting the developer disk image");
    let provider = phone.provider()?;
    let mut lockdown = LockdownClient::connect(&*provider).await?;
    let record = super::pairing::saved(&phone.udid)?.ok_or_else(|| Error::device("Pair the iPhone first."))?;
    lockdown.start_session(&record).await?;
    let chip = lockdown.get_value(Some("UniqueChipID"), None).await?.as_unsigned_integer().ok_or_else(|| Error::device("no UniqueChipID"))?;
    let mut mounter = ImageMounter::connect(&*provider).await?;
    let image = tokio::fs::read(dir.join("Image.dmg")).await?;
    let trust_cache = tokio::fs::read(dir.join("Image.dmg.trustcache")).await?;
    let manifest = tokio::fs::read(dir.join("BuildManifest.plist")).await?;
    let r = reporter.clone();
    mounter
        .mount_personalized_with_callback(&*provider, image, trust_cache, &manifest, None, chip, move |((n, d), _)| {
            let r = r.clone();
            async move { r.part("mount", if d == 0 { 0.0 } else { n as f64 / d as f64 }, None) }
        }, ())
        .await
        .map_err(|e| match e {
            idevice::IdeviceError::DeveloperModeNotEnabled => Error::NeedsPerson("Turn on Developer Mode on the iPhone first.".into()),
            other => Error::device(format!("Mounting failed: {other}. Apple's signing service must be reachable, and the phone must be unlocked.")),
        })?;
    reporter.done("mount", None);
    Ok(())
}

/// Copies the image into Poki's container so the phone does not download it.
pub async fn seed_container(phone: &Phone, bundle_id: &str, reporter: &Reporter) -> Result<()> {
    let kind = kind_of(phone).await;
    let (dir, _) = ensure(reporter, kind).await?;
    let files = kind.files();
    reporter.step("seed", "Copying the disk image into Poki");
    for (i, name) in files.iter().enumerate() {
        let bytes = std::fs::read(dir.join(name))?;
        super::container::write_file(phone, bundle_id, &format!("{}/ddi/{name}", super::container::SUPPORT_DIR), &bytes).await?;
        reporter.part("seed", (i + 1) as f64 / files.len() as f64, Some(name.to_string()));
    }
    reporter.done("seed", None);
    Ok(())
}
