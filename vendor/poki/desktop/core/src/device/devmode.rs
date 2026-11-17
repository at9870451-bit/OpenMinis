//! Developer Mode (iOS 16 and later), through the amfi lockdown service. Turning it on restarts
//! the phone; after the restart iOS asks the person to confirm and enter the passcode.
use super::Phone;
use crate::{Error, Reporter, Result};
use idevice::{IdeviceService, amfi::AmfiClient};
use std::time::Duration;

/// amfid answers one request per connection and then closes it, so every request gets its own
/// connection; a second request on the same one fails with "device socket io failed".
async fn amfi(phone: &Phone) -> Result<AmfiClient> {
    let provider = phone.provider()?;
    Ok(AmfiClient::connect(&*provider).await?)
}

pub async fn status(phone: &Phone) -> Result<bool> {
    Ok(amfi(phone).await?.get_developer_mode_status().await?)
}

/// Turns Developer Mode on. Returns `Ok(true)` when it was already on, `Ok(false)` when the phone
/// is restarting and the person has to confirm there. The phone must have no passcode-locked
/// screen for the second step; iOS asks for the passcode itself.
pub async fn enable(phone: &Phone, reporter: &Reporter) -> Result<bool> {
    reporter.step("devmode", "Turning on Developer Mode");
    if status(phone).await? {
        reporter.done("devmode", Some("Developer Mode is already on.".into()));
        return Ok(true);
    }
    // Shows the switch in Settings > Privacy & Security first, so the person can also do it by hand.
    if let Ok(mut c) = amfi(phone).await {
        let _ = c.reveal_developer_mode_option_in_ui().await;
    }
    match amfi(phone).await?.enable_developer_mode().await {
        Ok(()) => {}
        // The phone restarts at once and can drop the connection before it answers.
        Err(idevice::IdeviceError::Socket(_)) => {}
        // iOS only turns it on remotely when the device has no passcode. The switch is shown in
        // Settings now (the reveal above), so the person turns it on there.
        Err(e) if e.to_string().to_lowercase().contains("passcode") => {
            reporter.waiting("devmode", "Developer Mode is now available on your iPhone or iPad. Open Settings > Privacy & Security > Developer Mode, turn it on and tap Restart. After the restart, tap Turn On and enter your passcode. Poki Setup carries on by itself once it is on.");
            return Ok(false);
        }
        Err(idevice::IdeviceError::PasswordProtected) | Err(idevice::IdeviceError::DeviceLocked) => {
            return Err(Error::NeedsPerson("Unlock the iPhone or iPad, then try Developer Mode again. iOS only turns it on from an unlocked phone.".into()));
        }
        Err(e) => return Err(e.into()),
    }
    reporter.waiting("devmode", "The iPhone or iPad restarts. When it is back, tap Turn On and enter the passcode.");
    Ok(false)
}

/// After the restart: waits until the phone is back and Developer Mode reads on, up to `wait`.
pub async fn wait_until_on(udid: &str, reporter: &Reporter, wait: Duration) -> Result<()> {
    let deadline = tokio::time::Instant::now() + wait;
    loop {
        if tokio::time::Instant::now() > deadline {
            return Err(Error::NeedsPerson("Developer Mode is still off. On the iPhone or iPad, open Settings > Privacy & Security > Developer Mode and turn it on.".into()));
        }
        if let Ok(phones) = Phone::list().await {
            if let Some(phone) = phones.into_iter().find(|p| p.udid == udid) {
                if let Ok(true) = status(&phone).await {
                    // Settings may still show the "Turn on Developer Mode?" sheet; accept it when asked.
                    if let Ok(mut c) = amfi(&phone).await {
                        let _ = c.accept_developer_mode().await;
                    }
                    reporter.done("devmode", Some("Developer Mode is on.".into()));
                    return Ok(());
                }
            }
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}
