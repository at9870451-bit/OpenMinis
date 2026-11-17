//! Launching the runner: find the installed runner app, start its test session through testmanagerd
//! and dtservicehub (run_over_rsd), and wait until WebDriverAgent answers.

use crate::device::{DEVELOPER_MODE_FIX, Device, Failure, Result};
use idevice::{
    ReadWrite,
    dvt::{device_info::DeviceInfoClient, process_control::ProcessControlClient, remote_server::RemoteServerClient},
    dvt::xctest::{TestConfig, listener::XCUITestListener, run_over_rsd},
};
use std::{
    net::SocketAddr,
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    task::JoinHandle,
};

struct Quiet;
impl XCUITestListener for Quiet {}

/// Environment owned by the on-phone launcher. WebDriverAgent listens on every network interface
/// when USE_IP is absent, so the standalone path must pin both its HTTP and MJPEG listeners to the
/// phone's loopback. A Mac that deliberately launches its own WDA is a separate path and controls
/// that process's environment itself.
pub(crate) fn secure_runner_environment(environment: &mut plist::Dictionary) {
    environment.insert("POKI_LAUNCHER".into(), "1".into());
    // Override, rather than preserve, a value inherited from the installed runner's test config.
    environment.insert("USE_IP".into(), "127.0.0.1".into());
}

/// The runner's session started after the disk image mounted, so Developer Mode is on.
pub const RUNNER_BLOCKED_FIX: &str = "Poki Runner did not start. In Settings → Developer, turn on UI Automation; in Settings → General → VPN & Device Management, trust the developer of Poki Runner.";

pub const RUNNER_FIX: &str = "Install Poki Runner (poki-runner-unsigned.ipa) with the same signing tool and Apple ID as Poki, then trust its developer in Settings → General → VPN & Device Management.";

/// The runner: the configured bundle, else the installed user app whose id names a WebDriverAgent
/// runner (AltStore and Sideloadly rename bundles, for example by adding the team id).
pub async fn find_runner(device: &mut Device, configured: Option<&str>) -> Result<String> {
    if let Some(bundle) = configured {
        return Ok(bundle.to_string());
    }
    let mut proxy = device.installation_proxy().await?;
    let apps = proxy.get_apps(Some("User"), None).await?;
    let mut ids: Vec<String> = apps.keys().filter(|id| id.contains("WebDriverAgentRunner") && id.contains("xctrunner")).cloned().collect();
    ids.sort();
    ids.into_iter().next().ok_or_else(|| Failure::new("Poki Runner is not installed").fix(RUNNER_FIX).code("runner"))
}

pub type Session = JoinHandle<std::result::Result<(), idevice::IdeviceError>>;

/// Starts the runner's test session. The session lives as long as the returned task and `device`.
pub async fn start(device: &mut Device, bundle: &str, ios: &str) -> Result<Session> {
    let major: u8 = ios.split('.').next().and_then(|v| v.parse().ok()).unwrap_or(17);
    let mut proxy = device.installation_proxy().await?;
    let mut config = TestConfig::from_installation_proxy(&mut proxy, bundle, None)
        .await
        .map_err(|e| Failure::new(format!("cannot read the runner's install info: {e}")).fix(RUNNER_FIX).code("runner"))?;
    // The runner checks POKI_LAUNCHER: opened any other way, it does nothing and sends people to
    // Poki. USE_IP keeps this standalone, on-phone path off the LAN; pinned WebDriverAgent applies
    // it to both the HTTP listener and its MJPEG screenshot listener.
    let mut env = config.runner_env.take().unwrap_or_default();
    secure_runner_environment(&mut env);
    config.runner_env = Some(env);
    let mut adapter = device.adapter.clone();
    let handshake = device.rsd.clone();
    Ok(tokio::spawn(async move {
        let mut listener = Quiet;
        run_over_rsd(&mut adapter, &handshake, major, config, &mut listener, None).await
    }))
}

/// Waits until WebDriverAgent answers /status at `wda`, or the session ends, or `limit` passes.
/// After `slow` without an answer, `on_slow` is called once: the usual cause is iOS asking the
/// owner for the passcode (once after a restart or a force quit), which can take minutes, so the
/// limit is long and the caller tells the owner rather than starting over (a new prompt each time).
pub async fn wait_ready(session: &mut Session, wda: SocketAddr, limit: Duration, slow: Duration, on_slow: impl FnOnce()) -> Result<()> {
    let started = Instant::now();
    let until = started + limit;
    let mut on_slow = Some(on_slow);
    loop {
        if started.elapsed() > slow {
            if let Some(f) = on_slow.take() { f(); }
        }
        if session.is_finished() {
            let result = session.await.map_err(|e| Failure::new(e.to_string()))?;
            return Err(ended_before_ready(result));
        }
        if status(wda, Duration::from_secs(2)).await {
            return Ok(());
        }
        if Instant::now() > until {
            session.abort();
            return Err(Failure::new(format!("WebDriverAgent did not answer on port {} within {} s", wda.port(), limit.as_secs())));
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
}

/// The runner's test session ended before WebDriverAgent answered.
pub(crate) fn ended_before_ready(result: std::result::Result<(), idevice::IdeviceError>) -> Failure {
    match result {
        Ok(()) => Failure::new("the runner's test session ended before WebDriverAgent answered").fix(RUNNER_BLOCKED_FIX).code("runner_blocked"),
        Err(e @ idevice::IdeviceError::DeveloperModeNotEnabled) => Failure::new(format!("the runner did not start: {e}")).fix(DEVELOPER_MODE_FIX).code("developer_mode"),
        Err(e) => Failure::new(format!("the runner did not start: {e}")).fix(RUNNER_BLOCKED_FIX).code("runner_blocked"),
    }
}

/// One GET /status; true when WebDriverAgent answers 200.
pub async fn status(wda: SocketAddr, timeout: Duration) -> bool {
    let attempt = async {
        let mut stream = TcpStream::connect(wda).await.ok()?;
        stream.write_all(b"GET /status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n").await.ok()?;
        let mut head = [0u8; 16];
        let n = stream.read(&mut head).await.ok()?;
        Some(head[..n].starts_with(b"HTTP/1.1 200") || head[..n].starts_with(b"HTTP/1.0 200"))
    };
    matches!(tokio::time::timeout(timeout, attempt).await, Ok(Some(true)))
}

/// Ends every runner process (WebDriverAgentRunner-Runner). Returns how many were asked to end.
pub async fn end(device: &mut Device) -> std::result::Result<usize, idevice::IdeviceError> {
    let mut server: RemoteServerClient<Box<dyn ReadWrite>> = device.connect().await?;
    let pids: Vec<u64> = {
        let mut info = DeviceInfoClient::new(&mut server).await?;
        info.running_processes()
            .await?
            .into_iter()
            .filter(|p| p.name.contains("WebDriverAgentRunner") || p.real_app_name.contains("WebDriverAgentRunner"))
            .map(|p| p.pid as u64)
            .collect()
    };
    let mut control = ProcessControlClient::new(&mut server).await?;
    for pid in &pids {
        control.kill_app(*pid).await?;
    }
    Ok(pids.len())
}
