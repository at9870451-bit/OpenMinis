//! Where Poki Setup keeps its files: the app's own data directory per platform.
use std::path::PathBuf;

/// `~/Library/Application Support/Poki Setup` on macOS, `%APPDATA%\Poki\Poki Setup` on Windows,
/// `$XDG_DATA_HOME/poki-setup` on Linux. `POKI_SETUP_HOME` overrides it (tests, CI).
pub fn data_dir() -> PathBuf {
    if let Ok(p) = std::env::var("POKI_SETUP_HOME") {
        return PathBuf::from(p);
    }
    directories::ProjectDirs::from("nz", "Poki", "Poki Setup")
        .map(|d| d.data_dir().to_path_buf())
        .unwrap_or_else(|| std::env::temp_dir().join("poki-setup"))
}

pub fn ensure(dir: PathBuf) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// Pairing records, one per UDID.
pub fn pairings_dir() -> std::io::Result<PathBuf> { ensure(data_dir().join("pairings")) }
/// Downloaded release IPAs and developer disk images.
pub fn cache_dir() -> std::io::Result<PathBuf> { ensure(data_dir().join("cache")) }
/// The keeper's records and the app's settings.
pub fn state_dir() -> std::io::Result<PathBuf> { ensure(data_dir().join("state")) }
/// Signing keys (PEM, mode 0600 where the platform has modes) per Apple ID hash.
pub fn keys_dir() -> std::io::Result<PathBuf> { ensure(data_dir().join("keys")) }
/// Anisette state for the remote provider.
pub fn anisette_dir() -> std::io::Result<PathBuf> { ensure(data_dir().join("anisette")) }
/// The app's log file.
pub fn log_dir() -> std::io::Result<PathBuf> { ensure(data_dir().join("logs")) }

/// Tests that point POKI_SETUP_HOME at a temp dir take this lock so they do not race.
#[cfg(test)]
pub fn test_home() -> (std::sync::MutexGuard<'static, ()>, tempfile::TempDir) {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().expect("tempdir");
    unsafe { std::env::set_var("POKI_SETUP_HOME", dir.path()) };
    (guard, dir)
}
