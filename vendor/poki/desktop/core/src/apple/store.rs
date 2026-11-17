//! Where the Apple session lives between runs: the OS keychain (macOS Keychain, Windows
//! Credential Manager, Secret Service on Linux). The password is kept only when the person
//! turns on "Keep me signed in for weekly re-signing"; otherwise only the session tokens are.
use super::anisette::Source;
use super::gsa::{AppToken, Session};
#[cfg_attr(not(feature = "os-keychain"), allow(unused_imports))]
use crate::{Error, Result, paths};
use serde::{Deserialize, Serialize};

#[cfg(feature = "os-keychain")]
const SERVICE: &str = "nz.zheha.poki.setup";
#[cfg(any(feature = "os-keychain", test))]
const ACCOUNT_V1: &str = "apple-account";
#[cfg(any(feature = "os-keychain", test))]
const ACCOUNT_V2: &str = "apple-account-v2";

#[cfg(any(feature = "os-keychain", test))]
fn secret_key_v2(name: &str) -> String { format!("{name}-v2") }

#[cfg(any(feature = "os-keychain", test))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum KeychainErr {
    NoEntry,
    Failure(String),
}

#[cfg(any(feature = "os-keychain", test))]
pub(crate) trait KeychainBackend {
    fn get(&self, key: &str) -> std::result::Result<String, KeychainErr>;
    fn set(&self, key: &str, value: &str) -> std::result::Result<(), KeychainErr>;
    fn delete(&self, key: &str) -> std::result::Result<(), KeychainErr>;
}

#[cfg(feature = "os-keychain")]
struct OsKeychain;

#[cfg(feature = "os-keychain")]
impl OsKeychain {
    fn map_err(e: keyring::Error) -> KeychainErr {
        match e {
            keyring::Error::NoEntry => KeychainErr::NoEntry,
            other => KeychainErr::Failure(other.to_string()),
        }
    }
    fn entry(key: &str) -> std::result::Result<keyring::Entry, KeychainErr> {
        keyring::Entry::new(SERVICE, key).map_err(Self::map_err)
    }
}

#[cfg(feature = "os-keychain")]
impl KeychainBackend for OsKeychain {
    fn get(&self, key: &str) -> std::result::Result<String, KeychainErr> {
        Self::entry(key)?.get_password().map_err(Self::map_err)
    }
    fn set(&self, key: &str, value: &str) -> std::result::Result<(), KeychainErr> {
        Self::entry(key)?.set_password(value).map_err(Self::map_err)
    }
    fn delete(&self, key: &str) -> std::result::Result<(), KeychainErr> {
        match Self::entry(key)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(Self::map_err(e)),
        }
    }
}

#[cfg(any(feature = "os-keychain", test))]
fn keychain_read_error(detail: &str) -> Error {
    Error::Keychain(format!("Could not read the saved Apple Account from the keychain ({detail}). Enter your Mac login password and choose Always Allow, then retry."))
}

#[cfg(any(feature = "os-keychain", test))]
fn keychain_write_error(detail: &str) -> Error {
    Error::Keychain(format!("Could not write the keychain: {detail}"))
}

#[cfg(any(feature = "os-keychain", test))]
pub(crate) fn load_with_keychain(kc: &dyn KeychainBackend) -> Result<Account> {
    match kc.get(ACCOUNT_V2) {
        Ok(json) => Ok(serde_json::from_str(&json).unwrap_or_default()),
        Err(KeychainErr::NoEntry) => match kc.get(ACCOUNT_V1) {
            Ok(json) => {
                kc.set(ACCOUNT_V2, &json).map_err(|e| match e {
                    KeychainErr::NoEntry => keychain_write_error("no entry"),
                    KeychainErr::Failure(m) => keychain_write_error(&m),
                })?;
                if let Err(KeychainErr::Failure(m)) = kc.delete(ACCOUNT_V1) {
                    tracing::warn!("could not delete legacy keychain account entry: {m}");
                }
                Ok(serde_json::from_str(&json).unwrap_or_default())
            }
            Err(KeychainErr::NoEntry) => Ok(Account::default()),
            Err(KeychainErr::Failure(m)) => Err(keychain_read_error(&m)),
        },
        Err(KeychainErr::Failure(m)) => Err(keychain_read_error(&m)),
    }
}

#[cfg(any(feature = "os-keychain", test))]
pub(crate) fn save_with_keychain(kc: &dyn KeychainBackend, account: &Account) -> Result<()> {
    let json = serde_json::to_string(account)?;
    kc.set(ACCOUNT_V2, &json).map_err(|e| match e {
        KeychainErr::NoEntry => keychain_write_error("no entry"),
        KeychainErr::Failure(m) => keychain_write_error(&m),
    })
}

#[cfg(any(feature = "os-keychain", test))]
pub(crate) fn clear_with_keychain(kc: &dyn KeychainBackend) -> Result<()> {
    for key in [ACCOUNT_V2, ACCOUNT_V1] {
        if let Err(KeychainErr::Failure(m)) = kc.delete(key) {
            return Err(Error::Keychain(format!("keychain: {m}")));
        }
    }
    Ok(())
}

#[cfg(any(feature = "os-keychain", test))]
pub(crate) fn secret_get_with_keychain(kc: &dyn KeychainBackend, name: &str) -> Option<String> {
    let v2 = secret_key_v2(name);
    match kc.get(&v2) {
        Ok(val) => (!val.is_empty()).then_some(val),
        Err(KeychainErr::NoEntry) => match kc.get(name) {
            Ok(val) if !val.is_empty() => {
                if kc.set(&v2, &val).is_ok() {
                    let _ = kc.delete(name);
                }
                Some(val)
            }
            _ => None,
        },
        Err(KeychainErr::Failure(_)) => None,
    }
}

#[cfg(any(feature = "os-keychain", test))]
pub(crate) fn secret_set_with_keychain(kc: &dyn KeychainBackend, name: &str, value: &str) -> Result<()> {
    kc.set(&secret_key_v2(name), value).map_err(|e| match e {
        KeychainErr::NoEntry => Error::Keychain("keychain: no entry".into()),
        KeychainErr::Failure(m) => Error::Keychain(format!("keychain: {m}")),
    })
}

#[cfg(any(feature = "os-keychain", test))]
pub(crate) fn secret_delete_with_keychain(kc: &dyn KeychainBackend, name: &str) -> Result<()> {
    for key in [secret_key_v2(name), name.to_string()] {
        if let Err(KeychainErr::Failure(m)) = kc.delete(&key) {
            return Err(Error::Keychain(format!("keychain: {m}")));
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Account {
    pub session: Option<Session>,
    pub xcode_token: Option<AppToken>,
    pub password: Option<String>,
    pub team_id: Option<String>,
    pub anisette: Option<Source>,
}

impl Account {
    pub fn apple_id(&self) -> Option<&str> { self.session.as_ref().map(|s| s.apple_id.as_str()) }
    pub fn display_name(&self) -> Option<String> {
        self.session.as_ref().map(|s| {
            let n = format!("{} {}", s.first_name, s.last_name).trim().to_string();
            if n.is_empty() { s.apple_id.clone() } else { n }
        })
    }
}

/// The host's vault (Poki on the iPhone) holds the account under this name.
const VAULT_NAME: &str = "apple-account";

/// A secret of Poki Setup's own: the host's vault when one is installed, else the system keychain
/// (macOS Keychain, Windows Credential Manager), or a 0600 file in file mode.
pub fn secret_get(name: &str) -> Option<String> {
    if let Some(v) = crate::vault::installed() {
        return v.get(name).ok().flatten().and_then(|b| String::from_utf8(b).ok()).filter(|s| !s.is_empty());
    }
    if file_mode() {
        return std::fs::read_to_string(paths::state_dir().ok()?.join(format!("{name}.secret"))).ok().filter(|s| !s.is_empty());
    }
    #[cfg(not(feature = "os-keychain"))]
    unreachable!("file_mode is always on without the OS keychain");
    #[cfg(feature = "os-keychain")]
    secret_get_with_keychain(&OsKeychain, name)
}

pub fn secret_set(name: &str, value: &str) -> Result<()> {
    if let Some(v) = crate::vault::installed() {
        return v.set(name, value.as_bytes());
    }
    if file_mode() {
        let p = paths::state_dir()?.join(format!("{name}.secret"));
        std::fs::write(&p, value)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600))?;
        }
        return Ok(());
    }
    #[cfg(not(feature = "os-keychain"))]
    unreachable!("file_mode is always on without the OS keychain");
    #[cfg(feature = "os-keychain")]
    secret_set_with_keychain(&OsKeychain, name, value)
}

pub fn secret_delete(name: &str) -> Result<()> {
    if let Some(v) = crate::vault::installed() {
        return v.delete(name);
    }
    if file_mode() {
        let _ = std::fs::remove_file(paths::state_dir()?.join(format!("{name}.secret")));
        return Ok(());
    }
    #[cfg(not(feature = "os-keychain"))]
    unreachable!("file_mode is always on without the OS keychain");
    #[cfg(feature = "os-keychain")]
    secret_delete_with_keychain(&OsKeychain, name)
}

/// Tests and headless machines: POKI_SETUP_FILE_SECRETS=1 keeps the account in a 0600 file.
fn file_mode() -> bool { !cfg!(feature = "os-keychain") || std::env::var("POKI_SETUP_FILE_SECRETS").map(|v| v == "1").unwrap_or(false) }

fn file_path() -> Result<std::path::PathBuf> { Ok(paths::state_dir()?.join("account.json")) }

pub fn load() -> Result<Account> {
    if let Some(v) = crate::vault::installed() {
        return Ok(v.get(VAULT_NAME)?.and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default());
    }
    if file_mode() {
        return Ok(std::fs::read_to_string(file_path()?).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default());
    }
    #[cfg(not(feature = "os-keychain"))]
    unreachable!("file_mode is always on without the OS keychain");
    #[cfg(feature = "os-keychain")]
    load_with_keychain(&OsKeychain)
}

pub fn save(account: &Account) -> Result<()> {
    let json = serde_json::to_string(account)?;
    if let Some(v) = crate::vault::installed() {
        return v.set(VAULT_NAME, json.as_bytes());
    }
    if file_mode() {
        let p = file_path()?;
        std::fs::write(&p, &json)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600))?;
        }
        return Ok(());
    }
    #[cfg(not(feature = "os-keychain"))]
    unreachable!("file_mode is always on without the OS keychain");
    #[cfg(feature = "os-keychain")]
    save_with_keychain(&OsKeychain, account)
}

pub fn clear() -> Result<()> {
    if let Some(v) = crate::vault::installed() {
        return v.delete(VAULT_NAME);
    }
    if file_mode() {
        let _ = std::fs::remove_file(file_path()?);
        return Ok(());
    }
    #[cfg(not(feature = "os-keychain"))]
    unreachable!("file_mode is always on without the OS keychain");
    #[cfg(feature = "os-keychain")]
    clear_with_keychain(&OsKeychain)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    #[derive(Default)]
    struct MemoryKeychain {
        entries: Mutex<HashMap<String, String>>,
    }

    impl KeychainBackend for MemoryKeychain {
        fn get(&self, key: &str) -> std::result::Result<String, KeychainErr> {
            self.entries.lock().unwrap().get(key).cloned().ok_or(KeychainErr::NoEntry)
        }
        fn set(&self, key: &str, value: &str) -> std::result::Result<(), KeychainErr> {
            self.entries.lock().unwrap().insert(key.to_string(), value.to_string());
            Ok(())
        }
        fn delete(&self, key: &str) -> std::result::Result<(), KeychainErr> {
            self.entries.lock().unwrap().remove(key);
            Ok(())
        }
    }

    #[test]
    fn file_round_trip() {
        let (_lock, _dir) = crate::paths::test_home();
        unsafe { std::env::set_var("POKI_SETUP_FILE_SECRETS", "1") };
        assert!(load().unwrap().session.is_none());
        let mut a = Account::default();
        a.team_id = Some("ABC".into());
        save(&a).unwrap();
        assert_eq!(load().unwrap().team_id.as_deref(), Some("ABC"));
        clear().unwrap();
        assert!(load().unwrap().team_id.is_none());
    }

    #[test]
    fn old_entries_migrate_to_v2_keys() {
        let kc = MemoryKeychain::default();
        let legacy_account = Account { team_id: Some("OLDTEAM".into()), password: Some("pw".into()), ..Default::default() };
        kc.set(ACCOUNT_V1, &serde_json::to_string(&legacy_account).unwrap()).unwrap();
        kc.set("cloudflare-token", "cf-secret").unwrap();

        let loaded = load_with_keychain(&kc).unwrap();
        assert_eq!(loaded.team_id.as_deref(), Some("OLDTEAM"));
        assert_eq!(loaded.password.as_deref(), Some("pw"));
        assert!(kc.get(ACCOUNT_V2).is_ok());
        assert_eq!(kc.get(ACCOUNT_V1), Err(KeychainErr::NoEntry));

        assert_eq!(secret_get_with_keychain(&kc, "cloudflare-token").as_deref(), Some("cf-secret"));
        assert_eq!(kc.get("cloudflare-token-v2").as_deref(), Ok("cf-secret"));
        assert_eq!(kc.get("cloudflare-token"), Err(KeychainErr::NoEntry));
    }
}
