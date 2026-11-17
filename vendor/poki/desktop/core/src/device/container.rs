//! Files inside Poki's container, through house_arrest. A development-signed app lets its
//! whole sandbox be vended (`VendContainer`), so Poki's `Library/Application Support/Poki/` is
//! reachable: that is where it keeps `pairing.plist` and the `ddi/` folder. Used as a fallback
//! when the QR hand-off (`pairshare`) is not possible, and to pull Poki's logs.
use super::Phone;
use crate::{Error, Result};
use idevice::{IdeviceService, afc::{AfcClient, opcode::AfcFopenMode}, house_arrest::HouseArrestClient};

pub const SUPPORT_DIR: &str = "Library/Application Support/Poki";

async fn afc_for(phone: &Phone, bundle_id: &str) -> Result<AfcClient> {
    let provider = phone.provider()?;
    let ha = HouseArrestClient::connect(&*provider).await?;
    ha.vend_container(bundle_id).await.map_err(|e| match e {
        idevice::IdeviceError::NotFound | idevice::IdeviceError::InstallationProxy(_) => {
            Error::device(format!("Poki ({bundle_id}) is not installed on the iPhone, or iOS does not let this computer open its files."))
        }
        other => other.into(),
    })
}

async fn mkdir_p(afc: &mut AfcClient, path: &str) -> Result<()> {
    let mut so_far = String::new();
    for part in path.split('/').filter(|p| !p.is_empty()) {
        if !so_far.is_empty() {
            so_far.push('/');
        }
        so_far.push_str(part);
        let _ = afc.mk_dir(so_far.clone()).await;
    }
    Ok(())
}

/// Writes `bytes` to `relative` (relative to the container root) inside Poki's sandbox.
pub async fn write_file(phone: &Phone, bundle_id: &str, relative: &str, bytes: &[u8]) -> Result<()> {
    let mut afc = afc_for(phone, bundle_id).await?;
    if let Some((dir, _)) = relative.rsplit_once('/') {
        mkdir_p(&mut afc, dir).await?;
    }
    let mut file = afc.open(relative, AfcFopenMode::WrOnly).await?;
    file.write_entire(bytes).await?;
    file.close().await?;
    Ok(())
}

pub async fn read_file(phone: &Phone, bundle_id: &str, relative: &str) -> Result<Vec<u8>> {
    let mut afc = afc_for(phone, bundle_id).await?;
    let mut file = afc.open(relative, AfcFopenMode::RdOnly).await?;
    let bytes = file.read_entire().await?;
    file.close().await?;
    Ok(bytes)
}

pub async fn list(phone: &Phone, bundle_id: &str, relative: &str) -> Result<Vec<String>> {
    let mut afc = afc_for(phone, bundle_id).await?;
    Ok(afc.list_dir(relative).await?.into_iter().filter(|n| n != "." && n != "..").collect())
}

/// Puts the pairing record where Poki reads it: `Library/Application Support/Poki/pairing.plist`.
/// Never replaces a pairing Poki already has (for example one it made on the phone itself):
/// returns false then, true when the record was written or was already the same.
pub async fn place_pairing_file(phone: &Phone, bundle_id: &str, record: &[u8]) -> Result<bool> {
    let path = format!("{SUPPORT_DIR}/pairing.plist");
    if let Ok(existing) = read_file(phone, bundle_id, &path).await {
        // Never replace a pairing Poki made itself. A lockdown record (an earlier hand-off from
        // this computer) does give way to an RPPairing record, which is what the loopback needs.
        let upgrade = super::pairing::is_remote_record(record) && !super::pairing::is_remote_record(&existing);
        if !existing.is_empty() && !upgrade {
            return Ok(existing == record);
        }
    }
    write_file(phone, bundle_id, &path, record).await?;
    Ok(true)
}
