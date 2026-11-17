//! Facts about the phone from lockdown: name, model, iOS version, and whether Developer Mode is on.
use super::Phone;
use crate::Result;
use idevice::{IdeviceService, lockdown::LockdownClient};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Facts {
    pub udid: String,
    pub name: String,
    /// `iPhone18,1`
    pub product_type: String,
    /// `26.1`
    pub ios: String,
    pub build: String,
    pub unique_chip_id: u64,
    pub developer_mode: Option<bool>,
    pub paired_with_this_computer: bool,
    /// iOS 27 and later pair with themselves; earlier versions need this computer.
    pub can_pair_on_device: bool,
    pub wifi_address: Option<String>,
}

impl Facts {
    pub fn ios_major(&self) -> u32 {
        self.ios.split('.').next().and_then(|s| s.parse().ok()).unwrap_or(0)
    }
}

fn string(v: &plist::Dictionary, key: &str) -> String {
    v.get(key).and_then(|x| x.as_string()).unwrap_or_default().to_string()
}

/// Reads the facts. Works before pairing for the public values (name, version); Developer Mode and
/// the Wi-Fi address need a session, so they are `None` until the phone trusts this computer.
pub async fn read(phone: &Phone) -> Result<Facts> {
    let provider = phone.provider()?;
    let mut lockdown = LockdownClient::connect(&*provider).await?;
    let record = super::pairing::saved(&phone.udid)?;
    let mut paired = false;
    if let Some(record) = &record {
        paired = lockdown.start_session(record).await.is_ok();
    } else if let Ok(Some(record)) = super::mux_pairing_record(&phone.udid).await {
        paired = lockdown.start_session(&record).await.is_ok();
    }
    let all = lockdown.get_value(None, None).await?;
    let dict = all.as_dictionary().cloned().unwrap_or_default();
    let developer_mode = if paired {
        match lockdown.get_value(Some("DeveloperModeStatus"), Some("com.apple.security.mac.amfi")).await {
            Ok(v) => v.as_boolean(),
            Err(_) => None,
        }
    } else {
        None
    };
    let wifi_address = if paired {
        lockdown.get_value(Some("WiFiAddress"), None).await.ok().and_then(|v| v.as_string().map(|s| s.to_string()))
    } else {
        None
    };
    let ios = string(&dict, "ProductVersion");
    let major: u32 = ios.split('.').next().and_then(|s| s.parse().ok()).unwrap_or(0);
    Ok(Facts {
        udid: phone.udid.clone(),
        name: string(&dict, "DeviceName"),
        product_type: string(&dict, "ProductType"),
        build: string(&dict, "BuildVersion"),
        unique_chip_id: dict.get("UniqueChipID").and_then(|v| v.as_unsigned_integer()).unwrap_or(0),
        developer_mode,
        paired_with_this_computer: paired,
        can_pair_on_device: major >= 27,
        wifi_address,
        ios,
    })
}
