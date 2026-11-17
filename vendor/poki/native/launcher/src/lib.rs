//! PokiLauncher: gets the WebDriverAgent runner up on the phone it runs on, keeps it up, and pairs
//! the phone with itself. A C ABI for the Poki app (include/poki_launcher.h); docs/ios-core.md §3.

pub mod ax;
pub mod ddi;
pub mod device;
pub mod history;
pub mod launch;
pub mod pair;
pub mod remote;
pub mod signer;
pub mod supervisor;

use serde_json::Value;
use std::{
    ffi::{CStr, CString, c_char, c_void},
    sync::{Arc, OnceLock},
};

pub use supervisor::{Config, Launcher};

/// One runtime for everything the library does, on two worker threads.
/// aws-lc as the process's rustls provider, before anything makes a TLS connection. idevice's
/// lockdown and tunnel sessions use it; the signer's anisette client would otherwise install ring for
/// the whole process (it ignores the error when one is already set), and the phone's lockdown TLS then
/// fails with "device socket io failed".
pub(crate) fn pin_crypto_provider() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    });
}

pub(crate) fn runtime() -> &'static tokio::runtime::Runtime {
    pin_crypto_provider();
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("poki-launcher")
            .enable_all()
            .build()
            .expect("the launcher's runtime")
    })
}

fn pair_runtime() -> &'static tokio::runtime::Runtime {
    pin_crypto_provider();
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("poki-pairing")
            .enable_all()
            .build()
            .expect("the pairing runtime")
    })
}

pub type EventCallback = extern "C" fn(context: *mut c_void, event_json: *const c_char);

/// The app's callback and its context pointer, callable from any thread.
#[derive(Clone, Copy)]
struct Callback {
    function: EventCallback,
    context: *mut c_void,
}
unsafe impl Send for Callback {}
unsafe impl Sync for Callback {}

impl Callback {
    fn call(&self, value: &Value) {
        if let Ok(text) = CString::new(value.to_string()) {
            (self.function)(self.context, text.as_ptr());
        }
    }
}

unsafe fn read_str(text: *const c_char) -> Option<String> {
    if text.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(text) }.to_str().ok().map(String::from)
}

pub struct PokiLauncher {
    inner: Arc<Launcher>,
}

/// Makes a launcher from its JSON config; null when the config is unreadable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn poki_launcher_new(config_json: *const c_char, cb: EventCallback, context: *mut c_void) -> *mut PokiLauncher {
    pin_crypto_provider();
    let Some(text) = (unsafe { read_str(config_json) }) else { return std::ptr::null_mut() };
    let Ok(config) = serde_json::from_str::<Config>(&text) else { return std::ptr::null_mut() };
    let callback = Callback { function: cb, context };
    let launcher = Launcher::new(config, Box::new(move |event| callback.call(&event)));
    Box::into_raw(Box::new(PokiLauncher { inner: Arc::new(launcher) }))
}

/// Starts keeping the runner up; 0 when started (or already running).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn poki_launcher_start(launcher: *mut PokiLauncher) -> i32 {
    let Some(launcher) = (unsafe { launcher.as_ref() }) else { return -1 };
    launcher.inner.clone().start();
    0
}

/// Drops the session and launches again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn poki_launcher_restart(launcher: *mut PokiLauncher) {
    if let Some(launcher) = unsafe { launcher.as_ref() } {
        launcher.inner.restart();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn poki_launcher_stop(launcher: *mut PokiLauncher) {
    if let Some(launcher) = unsafe { launcher.as_ref() } {
        launcher.inner.stop();
    }
}

/// The latest state as JSON; free it with poki_string_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn poki_launcher_status(launcher: *mut PokiLauncher) -> *mut c_char {
    let Some(launcher) = (unsafe { launcher.as_ref() }) else { return std::ptr::null_mut() };
    CString::new(launcher.inner.status().to_string()).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn poki_launcher_free(launcher: *mut PokiLauncher) {
    if !launcher.is_null() {
        let launcher = unsafe { Box::from_raw(launcher) };
        launcher.inner.stop();
    }
}

/// The phone's remote pairing port, as the app found it in Bonjour (`_remotepairing._tcp`). Every
/// later connection of the launcher, the pairing check and the signer goes there. 0 means 49152.
#[unsafe(no_mangle)]
pub extern "C" fn poki_set_remote_pairing_port(port: u16) {
    remote::set_port(port);
}

/// The app is looking for a moved remote pairing port in Bonjour (true) or has stopped (false).
/// While it looks, a refused connection waits for the port (code `pairing_port`); otherwise it is
/// handled as before (on a mounted disk image, Poki's own session; else the loopback's fix).
#[unsafe(no_mangle)]
pub extern "C" fn poki_set_pairing_port_search(searching: bool) {
    remote::set_searching(searching);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn poki_string_free(text: *mut c_char) {
    if !text.is_null() {
        drop(unsafe { CString::from_raw(text) });
    }
}

pub struct PokiPairing {
    task: tokio::task::JoinHandle<()>,
}

/// Starts one on-device pairing. config_json: {"host_name": "Poki", "out_path": "...",
/// "identity_path": "..."}. Events: advertise {service_type, instance, port, txt}, pin {pin},
/// paired {path}, failed {detail}. Null when the config is unreadable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn poki_pair_start(config_json: *const c_char, cb: EventCallback, context: *mut c_void) -> *mut PokiPairing {
    pin_crypto_provider();
    let Some(text) = (unsafe { read_str(config_json) }) else { return std::ptr::null_mut() };
    let Ok(value) = serde_json::from_str::<Value>(&text) else { return std::ptr::null_mut() };
    let Some(out_path) = value["out_path"].as_str() else { return std::ptr::null_mut() };
    let config = pair::PairConfig {
        host_name: value["host_name"].as_str().unwrap_or("Poki").to_string(),
        out_path: out_path.into(),
        identity_path: value["identity_path"].as_str().map(Into::into),
    };
    let callback = Callback { function: cb, context };
    // Its own runtime: the signer (downloads, re-signing) and the launcher share the main one, and a
    // pairing must answer Settings at once, whatever else is running.
    let task = pair_runtime().spawn(pair::run(config, move |event| callback.call(&event)));
    Box::into_raw(Box::new(PokiPairing { task }))
}

/// Stops a pairing (if still running) and frees it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn poki_pair_cancel(pairing: *mut PokiPairing) {
    if !pairing.is_null() {
        let pairing = unsafe { Box::from_raw(pairing) };
        pairing.task.abort();
    }
}

/// The app's Keychain, as three callbacks. get returns a malloc'd, NUL-terminated base64 string
/// (Rust frees it with free) or null when there is no item; set and delete return 0 on success.
pub type VaultGet = extern "C" fn(context: *mut c_void, name: *const c_char) -> *mut c_char;
pub type VaultSet = extern "C" fn(context: *mut c_void, name: *const c_char, value_base64: *const c_char) -> i32;
pub type VaultDelete = extern "C" fn(context: *mut c_void, name: *const c_char) -> i32;

unsafe extern "C" {
    fn free(pointer: *mut c_void);
}

struct KeychainVault {
    get: VaultGet,
    set: VaultSet,
    delete: VaultDelete,
    context: *mut c_void,
}
unsafe impl Send for KeychainVault {}
unsafe impl Sync for KeychainVault {}

impl poki_setup_core::vault::Vault for KeychainVault {
    fn get(&self, name: &str) -> poki_setup_core::Result<Option<Vec<u8>>> {
        use base64::Engine;
        let name = CString::new(name).map_err(|e| poki_setup_core::Error::msg(e.to_string()))?;
        let raw = (self.get)(self.context, name.as_ptr());
        if raw.is_null() {
            return Ok(None);
        }
        let text = unsafe { CStr::from_ptr(raw) }.to_string_lossy().to_string();
        unsafe { free(raw.cast()) };
        base64::engine::general_purpose::STANDARD.decode(text.trim()).map(Some).map_err(|e| poki_setup_core::Error::msg(format!("keychain item {name:?}: {e}")))
    }
    fn set(&self, name: &str, value: &[u8]) -> poki_setup_core::Result<()> {
        use base64::Engine;
        let name_c = CString::new(name).map_err(|e| poki_setup_core::Error::msg(e.to_string()))?;
        let value = CString::new(base64::engine::general_purpose::STANDARD.encode(value)).unwrap();
        match (self.set)(self.context, name_c.as_ptr(), value.as_ptr()) {
            0 => Ok(()),
            code => Err(poki_setup_core::Error::msg(format!("Could not write {name} to the Keychain ({code})."))),
        }
    }
    fn delete(&self, name: &str) -> poki_setup_core::Result<()> {
        let name_c = CString::new(name).map_err(|e| poki_setup_core::Error::msg(e.to_string()))?;
        match (self.delete)(self.context, name_c.as_ptr()) {
            0 => Ok(()),
            code => Err(poki_setup_core::Error::msg(format!("Could not delete {name} from the Keychain ({code})."))),
        }
    }
}

/// Installs the Keychain for the signer, once per process; 0 when installed, 1 when one already was.
#[unsafe(no_mangle)]
pub extern "C" fn poki_signer_set_vault(get: VaultGet, set: VaultSet, delete: VaultDelete, context: *mut c_void) -> i32 {
    pin_crypto_provider();
    if poki_setup_core::vault::install(Box::new(KeychainVault { get, set, delete, context })) { 0 } else { 1 }
}

/// Runs one signer request (signer.rs) on the launcher's runtime. Events: {"event":"progress",
/// "progress":{...}} while it runs, then exactly one {"event":"result","ok":true,"value":...} or
/// {"event":"result","ok":false,"error":"...","code":"..."}. -1 when the request is unreadable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn poki_signer_call(request_json: *const c_char, cb: EventCallback, context: *mut c_void) -> i32 {
    pin_crypto_provider();
    let Some(text) = (unsafe { read_str(request_json) }) else { return -1 };
    let Ok(request) = serde_json::from_str::<Value>(&text) else { return -1 };
    let callback = Callback { function: cb, context };
    runtime().spawn(async move {
        let result = signer::handle(request, move |event| callback.call(&event)).await;
        let event = match result {
            Ok(value) => serde_json::json!({"event": "result", "ok": true, "value": value}),
            Err(e) => serde_json::json!({"event": "result", "ok": false, "error": e.message, "code": e.code}),
        };
        callback.call(&event);
    });
    0
}

/// Runs one iPhone History test (history.rs) on the launcher's runtime, on a tunnel of its own.
/// Events: {"event":"progress","progress":{...}} for every read of a run, then exactly one
/// {"event":"result","ok":true,"value":...} or {"event":"result","ok":false,"error":"...","fix":"...",
/// "code":"..."}. -1 when the request is unreadable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn poki_history_call(request_json: *const c_char, cb: EventCallback, context: *mut c_void) -> i32 {
    pin_crypto_provider();
    let Some(text) = (unsafe { read_str(request_json) }) else { return -1 };
    let Ok(request) = serde_json::from_str::<Value>(&text) else { return -1 };
    let callback = Callback { function: cb, context };
    runtime().spawn(async move {
        let result = history::handle(request, move |line| callback.call(&serde_json::json!({"event": "progress", "progress": line}))).await;
        let event = match result {
            Ok(value) => serde_json::json!({"event": "result", "ok": true, "value": value}),
            Err(e) => serde_json::json!({"event": "result", "ok": false, "error": e.detail, "fix": e.fix, "code": e.code}),
        };
        callback.call(&event);
    });
    0
}

/// Ends the history run in progress, if any; it then answers with what it measured so far.
#[unsafe(no_mangle)]
pub extern "C" fn poki_history_cancel() {
    history::cancel();
}

#[cfg(test)]
mod tests;
