//! The developer disk image. The phone offers testmanagerd and dtservicehub only while it is mounted;
//! it stays mounted until the phone restarts. Either way Apple's signing server (TSS) personalizes
//! it, so the first mount after a restart needs the internet.
//!
//! iOS 26.4 and later take it as a Cryptex1 cryptex through cryptexd. Earlier iOS (17.4 to 26.3)
//! has no such install: there the personalized image goes through the image mounter, as StikDebug
//! and pymobiledevice3 do. The app downloads the image for the iOS it runs on into `ddi_dir`
//! (BuildManifest.plist, Image.dmg, Image.dmg.trustcache, and for a cryptex its info and root hash).

use crate::device::{DDI_BAD_FIX, DDI_PROXY_FIX, DDI_REFUSED_FIX, DEVELOPER_MODE_FIX, Device, Failure, NETWORK_FIX, Result};
use idevice::IdeviceError;
use idevice::cryptexd::{Cryptex1Assets, CryptexdError, install_ddi};
use idevice::lockdown::LockdownClient;
use idevice::mobile_image_mounter::ImageMounter;
use sha2::{Digest, Sha384};
use std::path::Path;

/// Present only while a developer disk image is mounted.
pub const MOUNTED_MARKERS: [&str; 2] = ["com.apple.instruments.dtservicehub", "com.apple.dt.testmanagerd.remote"];
const CRYPTEXD: &str = "com.apple.security.cryptexd.remote";
const IMAGE_MOUNTER: &str = "com.apple.mobile.mobile_image_mounter.shim.remote";
/// What only a cryptex has; the app removes them when it downloads the personalized image.
const CRYPTEX_ONLY_FILES: [&str; 2] = ["Image.dmg.cryptex_info", "Image.dmg.root_hash"];
const DDI_WRONG_KIND_FIX: &str = "The developer disk image in Poki is for another iOS version. Open Poki and let it download the image again.";

/// How this iOS takes the developer disk image.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    /// A Cryptex1 cryptex installed through cryptexd: iOS 26.4 and later.
    Cryptex,
    /// The personalized image through the image mounter: iOS 17.4 to 26.3.
    Personalized,
}

/// The method for an iOS version ("18.7.7"). The same rule the app downloads by, and the one
/// StikDebug uses. None when the version cannot be read.
pub fn method_for(ios: &str) -> Option<Method> {
    let mut parts = ios.trim().split('.');
    let major: u32 = parts.next()?.parse().ok()?;
    let minor: u32 = parts.next().and_then(|p| p.parse().ok()).unwrap_or(0);
    Some(if (major, minor) >= (26, 4) { Method::Cryptex } else { Method::Personalized })
}

/// The method the files in `dir` are for, for when the phone did not say its iOS version.
pub fn method_of_files(dir: &str) -> Method {
    if CRYPTEX_ONLY_FILES.iter().all(|name| Path::new(dir).join(name).is_file()) { Method::Cryptex } else { Method::Personalized }
}
pub const DDI_FILES: [&str; 2] = ["BuildManifest.plist", "Image.dmg"];

pub fn mounted(device: &Device) -> bool {
    MOUNTED_MARKERS.iter().all(|name| device.rsd.services.contains_key(*name))
}

pub fn files_present(dir: &str) -> bool {
    !dir.is_empty() && DDI_FILES.iter().all(|name| Path::new(dir).join(name).is_file())
}

/// Mounts the image. The services list of this tunnel was fixed when it opened, so the caller opens
/// a new tunnel afterwards to use the services.
pub async fn mount(device: &mut Device, dir: &str) -> Result<()> {
    let ios = device.ios_version().await.unwrap_or_default();
    match method_for(&ios).unwrap_or_else(|| method_of_files(dir)) {
        Method::Cryptex => mount_cryptex(device, dir).await,
        Method::Personalized => mount_personalized(device, dir, &ios).await,
    }
}

fn not_downloaded() -> Failure {
    Failure::new("the developer disk image has not been downloaded").fix("Open Poki and let it download the developer disk image (about 20 MB), once.")
}

async fn mount_cryptex(device: &mut Device, dir: &str) -> Result<()> {
    if !device.rsd.services.contains_key(CRYPTEXD) {
        return Err(without_cryptexd(device.developer_mode().await));
    }
    if !files_present(dir) {
        return Err(not_downloaded());
    }
    let assets = Cryptex1Assets::load(dir).await.map_err(|e| Failure::new(format!("the developer disk image in the app is unreadable: {e}")).fix("Open Poki and download the developer disk image again."))?;
    install_ddi(&mut device.adapter, &mut device.rsd, &assets).await.map_err(|e| classify(&e))?;
    Ok(())
}

/// The personalized image through the image mounter: Apple signs a ticket for this phone's chip and
/// nonce, the image is uploaded, and the phone mounts it with its trust cache.
async fn mount_personalized(device: &mut Device, dir: &str, ios: &str) -> Result<()> {
    if !device.rsd.services.contains_key(IMAGE_MOUNTER) {
        return Err(without_image_mounter(device.developer_mode().await, ios));
    }
    if !files_present(dir) {
        return Err(not_downloaded());
    }
    let read = |name: &'static str| async move {
        tokio::fs::read(Path::new(dir).join(name)).await.map_err(|e| Failure::new(format!("the developer disk image in the app is unreadable: {name}: {e}")).fix("Open Poki and download the developer disk image again.").code("ddi_bad"))
    };
    let manifest = read("BuildManifest.plist").await?;
    let image = read("Image.dmg").await?;
    let trust_cache = read("Image.dmg.trustcache").await?;
    // A cryptex image left from another iOS would only fail on the phone, with an error that names
    // nothing: say it here, with the code the app downloads again on.
    if !personalized_image_matches(&manifest, &image) {
        return Err(Failure::new(format!("the developer disk image in the app is not the personalized image iOS {ios} takes")).fix(DDI_WRONG_KIND_FIX).code("ddi_bad"));
    }
    let chip = {
        let mut lockdown: LockdownClient = device.connect().await.map_err(|e| classify(&e))?;
        lockdown.get_value(Some("UniqueChipID"), None).await.map_err(|e| classify(&e))?.as_unsigned_integer()
            .ok_or_else(|| Failure::new("mounting the developer disk image failed: the phone did not give its chip identifier").code("ddi_mount"))?
    };
    let mut mounter: ImageMounter = device.connect().await.map_err(|e| classify(&e))?;
    mounter.mount_personalized_rsd(&mut device.adapter, &mut device.rsd, image, trust_cache, &manifest, None, chip).await.map_err(|e| classify(&e))?;
    Ok(())
}

/// Whether `image` is the `PersonalizedDMG` of a build identity in `manifest` (by its SHA-384).
pub fn personalized_image_matches(manifest: &[u8], image: &[u8]) -> bool {
    let Ok(manifest) = plist::from_bytes::<plist::Dictionary>(manifest) else { return false };
    let digest = Sha384::digest(image);
    manifest.get("BuildIdentities").and_then(|v| v.as_array()).is_some_and(|identities| {
        identities.iter().any(|identity| {
            identity.as_dictionary()
                .and_then(|i| i.get("Manifest")).and_then(|m| m.as_dictionary())
                .and_then(|m| m.get("PersonalizedDMG")).and_then(|e| e.as_dictionary())
                .and_then(|e| e.get("Digest")).and_then(|d| d.as_data())
                .is_some_and(|d| d == digest.as_slice())
        })
    })
}

/// The phone's services list has no image mounter, with what the phone said about Developer Mode.
pub(crate) fn without_image_mounter(developer_mode: Option<bool>, ios: &str) -> Failure {
    match developer_mode {
        Some(false) => Failure::new("the phone does not offer the image mounter: it says Developer Mode is off").fix(DEVELOPER_MODE_FIX).code("developer_mode"),
        Some(true) => Failure::new(format!("the phone does not offer the image mounter with Developer Mode on (iOS {ios}): it needs iOS 17.4 or later")).fix("Update iOS to 17.4 or later.").code("ios_too_old"),
        None => Failure::new("the phone does not offer the image mounter, and it did not say whether Developer Mode is on").fix("Check that Developer Mode is on (Settings → Privacy & Security → Developer Mode) and that iOS is 17.4 or later.").code("no_cryptexd"),
    }
}

/// The phone's services list has no cryptexd, with what the phone said about Developer Mode.
pub(crate) fn without_cryptexd(developer_mode: Option<bool>) -> Failure {
    match developer_mode {
        Some(false) => Failure::new("the phone does not offer cryptexd: it says Developer Mode is off").fix(DEVELOPER_MODE_FIX).code("developer_mode"),
        Some(true) => Failure::new("the phone does not offer cryptexd with Developer Mode on: it needs iOS 17.4 or later").fix("Update iOS to 17.4 or later.").code("ios_too_old"),
        None => Failure::new("the phone does not offer cryptexd, and it did not say whether Developer Mode is on").fix("Check that Developer Mode is on (Settings → Privacy & Security → Developer Mode) and that iOS is 17.4 or later.").code("no_cryptexd"),
    }
}

/// What went wrong with an install, and the one thing to do about it.
pub fn classify(error: &IdeviceError) -> Failure {
    let failure = Failure::new(format!("mounting the developer disk image failed: {error}"));
    match error {
        // Apple's signing server answered with STATUS=94: this image is not eligible for this iOS.
        IdeviceError::UnexpectedResponse(text)
            if idevice::tss::tss_error_status(text) == Some(idevice::tss::TSS_STATUS_NOT_ELIGIBLE) =>
        {
            failure.fix(DDI_REFUSED_FIX).code("ddi_refused")
        }
        // The phone could not install what it was given: the files are bad.
        IdeviceError::Cryptexd(CryptexdError::RoutineFailed { .. } | CryptexdError::BadDdiBundle(_)) => failure.fix(DDI_BAD_FIX).code("ddi_bad"),
        // Connected over HTTP, but a proxy or captive portal answered instead of Apple's TSS.
        IdeviceError::Http(text) if idevice::tss::is_non_apple_tss_reply(text) => {
            failure.fix(DDI_PROXY_FIX).code("ddi_proxy")
        }
        IdeviceError::Http(_) => failure.fix(NETWORK_FIX).code("network"),
        IdeviceError::DeveloperModeNotEnabled => failure.fix(DEVELOPER_MODE_FIX).code("developer_mode"),
        // The device tunnel failed during the mount exchange. The I/O kind can
        // distinguish EOF from a reset without logging any request or device data.
        IdeviceError::Socket(io) => Failure::new(format!(
            "mounting the developer disk image failed: {error} ({:?})",
            io.kind()
        ))
        .fix("Check the local developer connection in Poki Setup → Loopback. Poki retries automatically.")
        .code("ddi_socket"),
        _ => failure
            .fix("Check the developer disk image status in Poki Setup → Pairing. Poki retries automatically.")
            .code("ddi_mount"),
    }
}
