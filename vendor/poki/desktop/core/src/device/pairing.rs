//! Lockdown pairing over USB (the Trust This Computer dance) and the records it leaves behind.
//!
//! The record is what Poki on the phone needs to talk to its own developer services through the
//! loopback, so it is saved on this computer (`paths::pairings_dir`), given to usbmuxd, and handed
//! to the phone with [`crate::pairshare`].
use super::{LABEL, Phone};
use crate::{Error, Progress, Reporter, Result, paths};
use idevice::{IdeviceService, lockdown::LockdownClient, pairing_file::PairingFile, usbmuxd::UsbmuxdConnection};
use std::{path::PathBuf, time::Duration};

pub const HOST_NAME: &str = "Poki Setup";

pub fn record_path(udid: &str) -> Result<PathBuf> {
    Ok(paths::pairings_dir()?.join(format!("{udid}.plist")))
}

/// The record saved on this computer for `udid`, if any.
pub fn saved(udid: &str) -> Result<Option<PairingFile>> {
    let path = record_path(udid)?;
    if !path.exists() {
        return Ok(None);
    }
    Ok(Some(PairingFile::read_from_file(&path)?))
}

/// The saved record's bytes, as Poki wants them (a lockdown pairing plist, UDID included).
pub fn saved_bytes(udid: &str) -> Result<Option<Vec<u8>>> {
    let path = record_path(udid)?;
    if !path.exists() {
        return Ok(None);
    }
    Ok(Some(std::fs::read(path)?))
}

/// Whether the saved record still opens a session with the phone.
pub async fn verify(phone: &Phone) -> Result<bool> {
    let Some(record) = saved(&phone.udid)? else { return Ok(false) };
    let provider = phone.provider()?;
    let mut lockdown = LockdownClient::connect(&*provider).await?;
    match lockdown.start_session(&record).await {
        Ok(_) => Ok(true),
        Err(idevice::IdeviceError::InvalidHostID) => Ok(false),
        Err(e) => Err(e.into()),
    }
}

/// Pairs over USB. Waits for the person to tap Trust and enter the passcode (up to `wait`), then
/// tests the record, saves it on this computer and with usbmuxd. Returns the record's bytes.
pub async fn pair(phone: &Phone, reporter: &Reporter, wait: Duration) -> Result<Vec<u8>> {
    if !phone.is_usb() {
        return Err(Error::device("Pairing needs the cable. Plug the iPhone in with a data cable."));
    }
    reporter.step("pair", "Pairing with the iPhone");
    let mut mux = UsbmuxdConnection::default().await?;
    let buid = mux.get_buid().await?;
    let provider = phone.provider()?;
    let mut lockdown = LockdownClient::connect(&*provider).await?;

    // A record this computer or usbmuxd already holds is kept when it still works: the phone then
    // shows no dialog, and Poki keeps the identity it knows.
    if let Some(existing) = saved(&phone.udid)? {
        if lockdown.start_session(&existing).await.is_ok() {
            reporter.note("pair", "This iPhone already trusts this computer.");
            reporter.done("pair", None);
            return Ok(std::fs::read(record_path(&phone.udid)?)?);
        }
        let mut lockdown2 = LockdownClient::connect(&*provider).await?;
        std::mem::swap(&mut lockdown, &mut lockdown2);
    } else if let Ok(Some(existing)) = super::mux_pairing_record(&phone.udid).await {
        if lockdown.start_session(&existing).await.is_ok() {
            let mut existing = existing;
            existing.udid = Some(phone.udid.clone());
            let bytes = existing.serialize()?;
            std::fs::write(record_path(&phone.udid)?, &bytes)?;
            reporter.note("pair", "Using the trust this computer already has with the iPhone.");
            reporter.done("pair", None);
            return Ok(bytes);
        }
        let mut lockdown2 = LockdownClient::connect(&*provider).await?;
        std::mem::swap(&mut lockdown, &mut lockdown2);
    }

    let host_id = uuid::Uuid::new_v4().to_string().to_uppercase();
    reporter.waiting("pair", "On the iPhone: tap Trust, then enter the passcode.");
    let pairing = tokio::time::timeout(wait, lockdown.pair(host_id, buid, Some(HOST_NAME)))
        .await
        .map_err(|_| Error::NeedsPerson("The iPhone did not answer the Trust dialog in time. Unlock it, plug it in again and tap Trust.".into()))??;
    let mut record = pairing;
    record.udid = Some(phone.udid.clone());

    // Test it before anything is saved.
    let mut check = LockdownClient::connect(&*provider).await?;
    check.start_session(&record).await?;

    let bytes = record.clone().serialize()?;
    std::fs::write(record_path(&phone.udid)?, &bytes)?;
    if let Err(e) = mux.save_pair_record(&phone.udid, bytes.clone()).await {
        tracing::warn!("usbmuxd did not keep the pairing record: {e}");
    }
    reporter.done("pair", Some("Paired.".into()));
    reporter.emit(Progress::Note { id: "pair".into(), text: format!("Record saved for {}.", phone.udid) });
    Ok(bytes)
}

/// Forgets the record on this computer and asks the phone to forget this host.
pub async fn unpair(phone: &Phone) -> Result<()> {
    if let Some(record) = saved(&phone.udid)? {
        let provider = phone.provider()?;
        let mut lockdown = LockdownClient::connect(&*provider).await?;
        let _ = lockdown.start_session(&record).await;
        let _ = lockdown.unpair(record.host_id.clone()).await;
    }
    let path = record_path(&phone.udid)?;
    if path.exists() {
        std::fs::remove_file(path)?;
    }
    let _ = LABEL;
    Ok(())
}


/// Lets the iPhone accept this pairing over the network as well as the cable
/// (`com.apple.mobile.wireless_lockdown` / `EnableWifiConnections`). Poki talks to the phone's
/// own services over the loopback, which lockdown treats as a network connection: without this,
/// the record works over USB only and Poki's connections fail with "device socket io failed".
pub async fn enable_network(phone: &Phone) -> Result<()> {
    let record = saved(&phone.udid)?.ok_or_else(|| Error::device("Pair the iPhone first."))?;
    let provider = phone.provider()?;
    let mut lockdown = idevice::lockdown::LockdownClient::connect(&*provider).await?;
    lockdown.start_session(&record).await?;
    lockdown.set_value("EnableWifiConnections", true.into(), Some("com.apple.mobile.wireless_lockdown")).await?;
    Ok(())
}

// Remote pairing (RPPairing).
//
// Since iOS 26.4 the phone hangs up on lockdown records over the loopback Poki uses to reach its
// own developer services; a Remote Pairing record (the kind the phone makes for itself, or that
// idevice_pair makes over USB) is accepted there. Poki Setup makes one over the cable, through
// remotepairingdeviced, right after the lockdown pairing, and that is what Poki gets.

/// The plist key Poki reads for the host name to send with an RPPairing record.
pub const SENDING_HOST_KEY: &str = "sending_host";

pub fn remote_record_path(udid: &str) -> Result<PathBuf> {
    Ok(paths::pairings_dir()?.join(format!("{udid}.rppairing.plist")))
}

/// Whether `bytes` is an RPPairing record (public_key, private_key, identifier) rather than a
/// lockdown pairing plist.
pub fn is_remote_record(bytes: &[u8]) -> bool {
    idevice::remote_pairing::RpPairingFile::from_bytes(bytes).is_ok()
}

/// The saved RPPairing record for `udid`, as Poki wants it.
pub fn saved_remote_bytes(udid: &str) -> Result<Option<Vec<u8>>> {
    let path = remote_record_path(udid)?;
    if !path.exists() {
        return Ok(None);
    }
    Ok(Some(std::fs::read(path)?))
}

/// The record to give Poki: the RPPairing record when there is one, else the lockdown record.
pub fn for_poki(udid: &str) -> Result<Option<Vec<u8>>> {
    Ok(match saved_remote_bytes(udid)? {
        Some(b) => Some(b),
        None => saved_bytes(udid)?,
    })
}

/// Whether the iOS version string is one where the phone needs an RPPairing record for the
/// loopback (26.4 and later).
pub fn needs_remote_record(ios: &str) -> bool {
    let mut parts = ios.split('.').map(|p| p.parse::<u32>().unwrap_or(0));
    let major = parts.next().unwrap_or(0);
    let minor = parts.next().unwrap_or(0);
    (major, minor) >= (26, 4)
}

/// Makes (or reuses) an RPPairing record over USB. The lockdown pairing must already exist (the
/// service is reached through lockdown). The iPhone may ask to trust this computer again; it has
/// to be unlocked, ideally on the Home Screen. Returns the record's bytes.
pub async fn pair_remote(phone: &Phone, reporter: &Reporter, wait: Duration) -> Result<Vec<u8>> {
    use idevice::remote_pairing::{RemotePairingLockdownService, RpPairingFile};
    if !phone.is_usb() {
        return Err(Error::device("Remote pairing needs the cable. Plug the iPhone in with a data cable."));
    }
    let provider = phone.provider()?;
    let path = remote_record_path(&phone.udid)?;

    // A record that still verifies is kept: Poki may already be using it.
    if let Ok(bytes) = std::fs::read(&path) {
        if let Ok(mut file) = RpPairingFile::from_bytes(&bytes) {
            let ok = async {
                let service = RemotePairingLockdownService::connect(&*provider).await?;
                let mut client = service.into_client(HOST_NAME)?;
                client.attempt_pair_verify().await?;
                client.validate_pairing(&mut file).await
            };
            match tokio::time::timeout(Duration::from_secs(15), ok).await {
                Ok(Ok(_)) => return Ok(bytes),
                Ok(Err(e)) => tracing::info!("saved RPPairing record no longer verifies: {e}"),
                Err(_) => tracing::info!("verifying the saved RPPairing record timed out"),
            }
        }
    }

    reporter.waiting("pair", "On the iPhone: stay on the Home Screen, unlocked. If it asks, tap Trust and enter the passcode.");
    let mut file = RpPairingFile::generate(HOST_NAME);
    let made = async {
        let service = RemotePairingLockdownService::connect(&*provider).await?;
        let mut client = service.into_client(HOST_NAME)?;
        client.connect(&mut file, || async { "000000".to_string() }).await
    };
    tokio::time::timeout(wait, made)
        .await
        .map_err(|_| Error::NeedsPerson("The iPhone did not finish remote pairing in time. Unlock it, stay on the Home Screen and try again.".into()))??;

    let bytes = with_sending_host(&file.to_bytes(), HOST_NAME)?;
    std::fs::write(&path, &bytes)?;
    Ok(bytes)
}

/// Adds the `sending_host` key Poki reads, so it identifies itself by the name the record was
/// made with.
fn with_sending_host(bytes: &[u8], host: &str) -> Result<Vec<u8>> {
    let mut dict: plist::Dictionary = plist::from_bytes(bytes).map_err(|e| Error::msg(format!("RPPairing record: {e}")))?;
    dict.insert(SENDING_HOST_KEY.into(), plist::Value::String(host.into()));
    let mut out = Vec::new();
    plist::to_writer_xml(&mut out, &dict).map_err(|e| Error::msg(format!("RPPairing record: {e}")))?;
    Ok(out)
}

#[cfg(test)]
mod remote_tests {
    use super::*;

    #[test]
    fn cutoff_is_26_4() {
        assert!(!needs_remote_record("26.3.1"));
        assert!(needs_remote_record("26.4"));
        assert!(needs_remote_record("27.3"));
        assert!(!needs_remote_record("18.6"));
    }

    #[test]
    fn sending_host_survives_and_record_still_reads() {
        let f = idevice::remote_pairing::RpPairingFile::generate(HOST_NAME);
        let b = with_sending_host(&f.to_bytes(), HOST_NAME).unwrap();
        assert!(is_remote_record(&b));
        let d: plist::Dictionary = plist::from_bytes(&b).unwrap();
        assert_eq!(d.get(SENDING_HOST_KEY).and_then(|v| v.as_string()), Some(HOST_NAME));
        assert!(!is_remote_record(b"<plist><dict><key>HostID</key><string>x</string></dict></plist>"));
    }
}
