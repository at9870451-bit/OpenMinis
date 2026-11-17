//! Where secrets go when the host app keeps them itself. Poki on the iPhone installs a vault
//! backed by its Keychain, so the Apple session, the signing key and the anisette identity never
//! touch a file there. Desktop builds install none and keep using the OS keychain and the key files.
use crate::Result;
use std::sync::OnceLock;

pub trait Vault: Send + Sync {
    fn get(&self, name: &str) -> Result<Option<Vec<u8>>>;
    fn set(&self, name: &str, value: &[u8]) -> Result<()>;
    fn delete(&self, name: &str) -> Result<()>;
}

static VAULT: OnceLock<Box<dyn Vault>> = OnceLock::new();

/// Installs the vault for the process. Only the first call counts.
pub fn install(vault: Box<dyn Vault>) -> bool { VAULT.set(vault).is_ok() }

pub fn installed() -> Option<&'static dyn Vault> { VAULT.get().map(|b| b.as_ref()) }

#[cfg(test)]
pub mod memory {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;
    #[derive(Default)]
    pub struct Memory(pub Mutex<HashMap<String, Vec<u8>>>);
    impl Vault for Memory {
        fn get(&self, name: &str) -> Result<Option<Vec<u8>>> { Ok(self.0.lock().unwrap().get(name).cloned()) }
        fn set(&self, name: &str, value: &[u8]) -> Result<()> {
            self.0.lock().unwrap().insert(name.into(), value.to_vec());
            Ok(())
        }
        fn delete(&self, name: &str) -> Result<()> {
            self.0.lock().unwrap().remove(name);
            Ok(())
        }
    }
}
