//! Poki keeps its own signing: Poki Setup's core (desktop/core) on the phone. It signs in to the
//! Apple account with remote anisette, asks the developer portal for the certificate and the 7-day
//! profiles, re-signs Poki (the installed copy for a refresh, the channel's release for an update)
//! ahead of time, and installs it over the loopback when the person says so.
//!
//! Secrets never touch a file: the app installs a [`Vault`] backed by its Keychain before the
//! first call (poki_signer_set_vault). One request at a time; see include/poki_launcher.h.
use crate::device::{Device, Pairing};
use idevice::{lockdown::LockdownClient, misagent::MisagentClient, utils::installation};
use poki_setup_core::{
    self as core, Progress, Reporter,
    apple::{anisette::Source, gsa::Pending, identity},
    release::{self, Channel},
    setup::{self, Signer},
    sign,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    net::IpAddr,
    path::{Path, PathBuf},
    sync::Mutex,
    time::Duration,
};

/// Signed in and pending state, shared by the calls.
struct State {
    signer: Option<Signer>,
    pending: Option<Pending>,
}

static STATE: tokio::sync::Mutex<State> = tokio::sync::Mutex::const_new(State { signer: None, pending: None });
static HOME: Mutex<Option<PathBuf>> = Mutex::new(None);

#[derive(Debug)]
pub struct Failure {
    pub message: String,
    pub code: &'static str,
}

impl From<core::Error> for Failure {
    fn from(e: core::Error) -> Self {
        let code = match &e {
            core::Error::NeedsCode(_) => "needs_code",
            core::Error::NeedsPerson(_) => "needs_person",
            core::Error::Apple { .. } => "apple",
            _ => e.kind(),
        };
        Failure { message: e.to_string(), code }
    }
}

impl From<crate::device::Failure> for Failure {
    fn from(e: crate::device::Failure) -> Self {
        let message = match e.fix {
            Some(fix) => format!("{} {}", e.detail, fix),
            None => e.detail,
        };
        Failure { message, code: e.code.unwrap_or("device") }
    }
}

impl From<idevice::IdeviceError> for Failure {
    fn from(e: idevice::IdeviceError) -> Self { Failure { message: e.to_string(), code: "device" } }
}

impl From<std::io::Error> for Failure {
    fn from(e: std::io::Error) -> Self { Failure { message: e.to_string(), code: "io" } }
}

fn fail(message: impl Into<String>, code: &'static str) -> Failure { Failure { message: message.into(), code } }

type Out = std::result::Result<Value, Failure>;

/// The phone's own services, as the launcher reaches them.
#[derive(Deserialize, Clone)]
struct Phone {
    device_address: String,
    pairing_file: String,
    #[serde(default)]
    host_name: Option<String>,
}

impl Phone {
    async fn open(&self) -> std::result::Result<Device, Failure> {
        let address: IpAddr = self.device_address.parse().map_err(|_| fail(format!("{} is not an address", self.device_address), "config"))?;
        let mut pairing = Pairing::read(Path::new(&self.pairing_file), self.host_name.as_deref())?;
        Ok(Device::open(address, &mut pairing, Duration::from_secs(20)).await?)
    }
}

fn str_of<'a>(v: &'a Value, key: &str) -> std::result::Result<&'a str, Failure> {
    v[key].as_str().filter(|s| !s.is_empty()).ok_or_else(|| fail(format!("{key} is missing"), "config"))
}

fn home() -> std::result::Result<PathBuf, Failure> {
    HOME.lock().unwrap().clone().ok_or_else(|| fail("the signer is not configured", "config"))
}

async fn signer(state: &mut State) -> std::result::Result<&mut Signer, Failure> {
    if core::vault::installed().is_none() {
        return Err(fail("the Keychain vault is not installed", "config"));
    }
    if state.signer.is_none() {
        state.signer = Some(Signer::open()?);
    }
    Ok(state.signer.as_mut().unwrap())
}

fn channels() -> Value {
    Value::Array([Channel::Beta].iter().map(|c| json!({"id": c.id(), "title": c.title()})).collect())
}

/// Deliberately independent of Phone, pairing files, HOME, STATE and the vault.
fn pairing_probe_config(request: &Value) -> std::result::Result<(IpAddr, u16, Duration), Failure> {
    if request["device_address"].as_str() != Some("10.7.0.1") {
        return Err(fail("pairing_probe device_address must be 10.7.0.1", "config"));
    }
    let port = request["port"].as_u64().filter(|port| (1..=65535).contains(port))
        .ok_or_else(|| fail("pairing_probe port must be an integer in 1..65535", "config"))? as u16;
    let timeout_ms = match request.get("timeout_ms") {
        None => 3000,
        Some(value) => {
            if let Some(ms) = value.as_u64() {
                ms.clamp(500, 6000)
            } else if let Some(ms) = value.as_i64() {
                ms.clamp(500, 6000) as u64
            } else {
                return Err(fail("pairing_probe timeout_ms must be an integer", "config"));
            }
        }
    };
    Ok((std::net::Ipv4Addr::new(10, 7, 0, 1).into(), port, Duration::from_millis(timeout_ms)))
}

async fn pairing_probe(request: &Value) -> Out {
    let (host, port, timeout) = pairing_probe_config(request)?;
    let probe = crate::remote::probe_handshake(host, port, timeout).await
        .map_err(|error| fail(error.to_string(), "config"))?;
    Ok(pairing_probe_response(probe))
}

fn pairing_probe_response(probe: crate::remote::HandshakeProbe) -> Value {
    // Keep this bridge schema fixed for SignerBridge.decode. Network failures
    // remain successful bridge results, with the failing stage in the payload.
    json!({
        "tcp_connected": probe.tcp_connected,
        "handshake_ok": probe.handshake_ok,
        "stage": probe.stage,
        "detail": probe.detail,
        "port": probe.port,
        "elapsed_ms": probe.elapsed_ms,
        "host": probe.host,
    })
}

/// Runs one request. `emit` gets progress events while it runs.
pub async fn handle(request: Value, emit: impl Fn(Value) + Send + Sync + 'static) -> Out {
    let op = request["op"].as_str().unwrap_or("");
    let reporter = Reporter::new(move |p: Progress| emit(json!({"event": "progress", "progress": p})));
    match op {
        "pairing_probe" => pairing_probe(&request).await,
        "configure" => {
            // Where the core keeps its non-secret files (release cache, channel, machine id).
            let dir = PathBuf::from(str_of(&request, "home")?);
            std::fs::create_dir_all(&dir)?;
            // SAFETY: set once, before any request reads them; the app makes this call at launch.
            unsafe {
                std::env::set_var("POKI_SETUP_HOME", &dir);
                if let Some(name) = request["device_name"].as_str() {
                    std::env::set_var("POKI_DEVICE_NAME", name);
                }
            }
            *HOME.lock().unwrap() = Some(dir);
            Ok(json!({}))
        }
        "status" => {
            let mut state = STATE.lock().await;
            let pending = state.pending.is_some();
            let s = signer(&mut state).await?;
            let source = match s.account.anisette.clone().unwrap_or_else(Source::default_for_platform) {
                Source::Remote { url } => url,
                Source::System => "system".into(),
            };
            Ok(json!({
                "signed_in": s.signed_in(),
                "needs_code": pending,
                "apple_id": s.account.apple_id(),
                "name": s.account.display_name(),
                "team_id": s.account.team_id,
                "keeps_password": s.account.password.is_some(),
                "anisette": source,
                "channel": release::channel().id(),
                "channels": channels(),
            }))
        }
        "sign_in" => {
            let mut state = STATE.lock().await;
            let (id, pw) = (str_of(&request, "apple_id")?.to_string(), str_of(&request, "password")?.to_string());
            let keep = request["keep_password"].as_bool().unwrap_or(true);
            let pending = signer(&mut state).await?.sign_in(&id, &pw, keep).await?;
            let needs_code = pending.is_some();
            state.pending = pending;
            Ok(json!({"needs_code": needs_code}))
        }
        "finish_sign_in" => {
            let mut state = STATE.lock().await;
            let code = str_of(&request, "code")?.to_string();
            let pending = state.pending.take().ok_or_else(|| fail("Sign in again. The verification step has expired.", "needs_person"))?;
            let keep = pending.clone();
            let result = signer(&mut state).await?.finish_sign_in(pending, &code).await;
            if let Err(e) = result {
                // A wrong code: keep the waiting sign-in so the code can be typed again. Starting
                // over would ask Apple for another code, which replaces this one.
                state.pending = Some(keep);
                return Err(e.into());
            }
            Ok(json!({}))
        }
        "sign_out" => {
            let mut state = STATE.lock().await;
            state.pending = None;
            signer(&mut state).await?.sign_out()?;
            Ok(json!({}))
        }
        "teams" => {
            let mut state = STATE.lock().await;
            let s = signer(&mut state).await?;
            match s.teams().await {
                Ok(teams) => Ok(Value::Array(teams.into_iter().map(|t| json!({"team_id": t.team_id, "name": t.name, "kind": t.kind, "is_free": t.is_free})).collect())),
                Err(core::Error::NeedsCode(pending)) => {
                    let msg = core::Error::NeedsCode(pending.clone()).to_string();
                    state.pending = Some(*pending);
                    Err(fail(msg, "needs_code"))
                }
                Err(e) => Err(e.into()),
            }
        }
        "choose_team" => {
            let mut state = STATE.lock().await;
            signer(&mut state).await?.choose_team(str_of(&request, "team_id")?)?;
            Ok(json!({}))
        }
        "set_anisette" => {
            let mut state = STATE.lock().await;
            let url = request["url"].as_str().map(str::trim).filter(|u| !u.is_empty()).unwrap_or(core::apple::anisette::DEFAULT_REMOTE);
            if !url.starts_with("https://") {
                return Err(fail("The anisette server address starts with https://.", "needs_person"));
            }
            signer(&mut state).await?.set_anisette(Source::Remote { url: url.to_string() })?;
            Ok(json!({"anisette": url}))
        }
        "set_channel" => {
            let channel = Channel::parse(str_of(&request, "channel")?).ok_or_else(|| fail("unknown channel", "config"))?;
            release::set_channel(channel)?;
            Ok(json!({"channel": release::channel().id()}))
        }
        "import_identity" => import_identity(&request).await,
        "check_update" => {
            let r = release::latest().await?;
            Ok(json!({"tag": r.tag, "version": r.version, "build": r.build, "channel": r.channel.id(), "published_at": r.published_at, "notes": r.notes, "source": r.source, "source_notice": r.source_notice}))
        }
        "udid" => {
            let phone: Phone = serde_json::from_value(request.clone()).map_err(|e| fail(e.to_string(), "config"))?;
            let mut device = phone.open().await?;
            Ok(json!({"udid": udid(&mut device).await?}))
        }
        "prepare" => prepare(&request, &reporter).await,
        "install" => install(&request, &reporter).await,
        other => Err(fail(format!("unknown request {other:?}"), "config")),
    }
}

async fn udid(device: &mut Device) -> std::result::Result<String, Failure> {
    let mut lockdown: LockdownClient = device.connect().await?;
    let v = lockdown.get_value(Some("UniqueDeviceID"), None).await?;
    v.as_string().map(String::from).filter(|s| !s.is_empty()).ok_or_else(|| fail("the phone did not say its UDID", "device"))
}

/// Takes the signing key Poki Setup left in the container (Documents/PokiSetup/signing-identity.json),
/// keeps it in the Keychain and deletes the file, so the phone and the computer share one
/// certificate (a free team allows one).
async fn import_identity(request: &Value) -> Out {
    let path = PathBuf::from(str_of(request, "path")?);
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(json!({"imported": false})),
        Err(e) => return Err(e.into()),
    };
    let v: Value = serde_json::from_str(&text).map_err(|e| fail(format!("signing-identity.json: {e}"), "config"))?;
    if v["schema"].as_str() != Some("poki.signing-identity/1") {
        return Err(fail("signing-identity.json has an unknown schema", "config"));
    }
    let team = str_of(&v, "team_id")?.to_string();
    identity::import_key(&team, str_of(&v, "key_pkcs8_pem")?)?;
    let mut state = STATE.lock().await;
    let s = signer(&mut state).await?;
    if s.account.team_id.is_none() {
        s.choose_team(&team)?;
    }
    std::fs::remove_file(&path)?;
    Ok(json!({"imported": true, "team_id": team, "apple_id": v["apple_id"]}))
}

/// Builds the next signed Poki ahead of time. kind "refresh" re-signs the installed app
/// (`app_path`, Bundle.main); kind "update" takes the newest release on the chosen channel.
/// The result lands in `<home>/ready/<kind>/` with a manifest; nothing is installed.
async fn prepare(request: &Value, reporter: &Reporter) -> Out {
    let kind = request["kind"].as_str().unwrap_or("refresh");
    let phone: Phone = serde_json::from_value(request.clone()).map_err(|e| fail(e.to_string(), "config"))?;
    let out_dir = home()?.join("ready").join(kind);
    let _ = std::fs::remove_dir_all(&out_dir);
    std::fs::create_dir_all(&out_dir)?;

    reporter.step("phone", "Checking this iPhone");
    let (udid, name) = match request["udid"].as_str() {
        Some(u) if !u.is_empty() => (u.to_string(), request["device_name"].as_str().unwrap_or("iPhone").to_string()),
        _ => {
            let mut device = phone.open().await?;
            (udid(&mut device).await?, request["device_name"].as_str().unwrap_or("iPhone").to_string())
        }
    };
    reporter.done("phone", Some(udid.clone()));

    let (ipa, signing_zip, tag) = match kind {
        "refresh" => {
            reporter.step("release", "Packing the installed Poki");
            let app = PathBuf::from(str_of(request, "app_path")?);
            let ipa = out_dir.join("installed.ipa");
            let (a, i) = (app.clone(), ipa.clone());
            tokio::task::spawn_blocking(move || sign::package_app(&a, &i)).await.map_err(|e| fail(e.to_string(), "io"))??;
            reporter.done("release", None);
            (ipa, None, "installed".to_string())
        }
        "update" => {
            reporter.step("release", "Getting the newest Poki");
            let rel = release::latest().await?;
            let (ipa, zip) = release::fetch(&rel, reporter).await?;
            reporter.done("release", Some(rel.tag.clone()));
            (ipa, zip, rel.tag)
        }
        other => return Err(fail(format!("unknown kind {other:?}"), "config")),
    };

    let mut state = STATE.lock().await;
    let s = signer(&mut state).await?;
    if !s.signed_in() {
        return Err(fail("Sign in with your Apple Account in Setup first.", "needs_person"));
    }
    let team = match s.team().await {
        Ok(team) => team,
        Err(core::Error::NeedsCode(pending)) => {
            let msg = core::Error::NeedsCode(pending.clone()).to_string();
            state.pending = Some(*pending);
            return Err(fail(msg, "needs_code"));
        }
        Err(e) => return Err(e.into()),
    };
    let out = out_dir.join("Poki-signed.ipa");
    // Unpacking, signing and packing run synchronously inside; block_in_place moves the runtime's
    // other work (the runner's launcher) to another thread meanwhile instead of stalling it.
    let handle = tokio::runtime::Handle::current();
    let built = match tokio::task::block_in_place(|| handle.block_on(setup::sign_for_team(s, &team, Some((&udid, &name)), &ipa, signing_zip.as_deref(), &out, reporter))) {
        Ok(built) => built,
        Err(core::Error::NeedsCode(pending)) => {
            let msg = core::Error::NeedsCode(pending.clone()).to_string();
            state.pending = Some(*pending);
            return Err(fail(msg, "needs_code"));
        }
        Err(e) => return Err(e.into()),
    };
    let _ = std::fs::remove_file(out_dir.join("installed.ipa"));
    let mut profiles = vec![];
    for (i, p) in built.profiles.iter().enumerate() {
        let path = out_dir.join(format!("profile-{i}.mobileprovision"));
        std::fs::write(&path, p)?;
        profiles.push(path.to_string_lossy().to_string());
    }
    let manifest = json!({
        "kind": kind,
        "ipa": built.ipa.to_string_lossy(),
        "profiles": profiles,
        "bundle_id": built.bundle_id,
        "version": built.version,
        "build": built.build,
        "tag": tag,
        "team_id": team.team_id,
        "team_name": team.name,
        "team_is_free": team.is_free,
        "profile_expires_at": built.profile_expires_at,
        "prepared_at": core::keeper::now(),
        "notes": built.notes,
    });
    std::fs::write(out_dir.join("manifest.json"), serde_json::to_vec_pretty(&manifest).unwrap_or_default())?;
    Ok(manifest)
}

/// Installs a prepared build: its profiles through misagent, then the app as an upgrade through
/// installation_proxy (Poki's data stays). iOS ends Poki when the new copy lands.
async fn install(request: &Value, reporter: &Reporter) -> Out {
    let phone: Phone = serde_json::from_value(request.clone()).map_err(|e| fail(e.to_string(), "config"))?;
    let manifest_path = PathBuf::from(str_of(request, "manifest")?);
    let manifest: Value = serde_json::from_slice(&std::fs::read(&manifest_path)?).map_err(|e| fail(e.to_string(), "config"))?;
    let ipa = PathBuf::from(str_of(&manifest, "ipa")?);
    let mut device = phone.open().await?;

    reporter.step("profiles", "Installing the provisioning profiles");
    let profiles: Vec<String> = manifest["profiles"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
    {
        let mut misagent: MisagentClient = device.connect().await?;
        for (i, p) in profiles.iter().enumerate() {
            misagent.install(std::fs::read(p)?).await.map_err(|e| fail(format!("The iPhone refused a provisioning profile: {e}"), "device"))?;
            reporter.part("profiles", (i + 1) as f64 / profiles.len().max(1) as f64, None);
        }
    }
    reporter.done("profiles", None);

    reporter.step("install", "Updating Poki");
    let r = reporter.clone();
    let cb = move |(percent, _): (u64, ())| {
        let r = r.clone();
        async move { r.part("install", percent as f64 / 100.0, None) }
    };
    let work = installation::upgrade_package_with_callback_rsd(&mut device.adapter, &mut device.rsd, &ipa, None, cb, ());
    match tokio::time::timeout(Duration::from_secs(600), work).await {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            let text = e.to_string();
            let message = if text.contains("ApplicationVerificationFailed") {
                "The iPhone did not accept the new signature. Check that Developer Mode is on, then prepare the build again.".to_string()
            } else {
                format!("The update did not install: {text}")
            };
            return Err(fail(message, "device"));
        }
        Err(_) => return Err(fail("The iPhone stopped answering while installing. Try again.", "device")),
    }
    reporter.done("install", None);
    Ok(json!({"installed": true}))
}

#[cfg(test)]
mod probe_tests {
    use super::*;

    fn request() -> Value {
        // No pairing_file, host_name, home, account or vault setup is needed.
        json!({"op": "pairing_probe", "device_address": "10.7.0.1", "port": 49152})
    }

    #[test]
    fn probe_config_is_loopback_only_and_clamps_one_deadline() {
        let (host, port, timeout) = pairing_probe_config(&request()).unwrap();
        assert_eq!(host.to_string(), "10.7.0.1");
        assert_eq!(port, 49152);
        assert_eq!(timeout, Duration::from_millis(3000));
        for (input, expected) in [(-100, 500), (0, 500), (499, 500), (500, 500), (3000, 3000), (6000, 6000), (6001, 6000)] {
            let mut value = request();
            value["timeout_ms"] = json!(input);
            assert_eq!(pairing_probe_config(&value).unwrap().2, Duration::from_millis(expected));
        }
        let mut value = request();
        value["timeout_ms"] = json!(u64::MAX);
        assert_eq!(pairing_probe_config(&value).unwrap().2, Duration::from_millis(6000));
        for port in [1, 65535] {
            value["port"] = json!(port);
            assert_eq!(pairing_probe_config(&value).unwrap().1, port);
        }
    }

    #[test]
    fn probe_config_rejects_redirects_bad_ports_and_wrong_types() {
        for address in ["10.7.1.1", "127.0.0.1", "::1", "example.com", "10.7.0.1 ", ""] {
            let mut value = request();
            value["device_address"] = json!(address);
            assert_eq!(pairing_probe_config(&value).unwrap_err().code, "config");
        }
        for port in [json!(0), json!(-1), json!(65536), json!(1.5), json!("49152"), Value::Null] {
            let mut value = request();
            value["port"] = port;
            assert_eq!(pairing_probe_config(&value).unwrap_err().code, "config");
        }
        for timeout in [json!(1.5), json!("3000"), json!(true), Value::Null] {
            let mut value = request();
            value["timeout_ms"] = timeout;
            assert_eq!(pairing_probe_config(&value).unwrap_err().code, "config");
        }
        for missing in ["device_address", "port"] {
            let mut value = request();
            value.as_object_mut().unwrap().remove(missing);
            assert_eq!(pairing_probe_config(&value).unwrap_err().code, "config");
        }
    }

    #[tokio::test]
    async fn probe_handle_bad_request_is_config_not_unknown_or_vault_error() {
        let mut value = request();
        value["device_address"] = json!("10.7.1.1");
        let failure = handle(value, |_| panic!("probe must not emit signing progress")).await.unwrap_err();
        assert_eq!(failure.code, "config");
        assert!(failure.message.contains("device_address must be 10.7.0.1"));
    }

    #[test]
    fn probe_bridge_has_exact_seven_fields_for_success_and_network_failure() {
        for (stage, tcp_connected, handshake_ok, code) in [
            ("connect", false, false, "io"),
            ("handshake", true, false, "io"),
            ("handshake", true, false, "timeout"),
            ("ready", true, true, "ok"),
        ] {
            let value = pairing_probe_response(crate::remote::HandshakeProbe {
                tcp_connected,
                handshake_ok,
                stage,
                code,
                detail: format!("[{code}] mock; after 52 ms"),
                port: 49153,
                elapsed_ms: 52,
                host: std::net::Ipv4Addr::new(10, 7, 0, 1).into(),
            });
            assert_eq!(value.as_object().unwrap().len(), 7);
            assert_eq!(value, json!({
                "tcp_connected": tcp_connected,
                "handshake_ok": handshake_ok,
                "stage": stage,
                "detail": format!("[{code}] mock; after 52 ms"),
                "port": 49153,
                "elapsed_ms": 52,
                "host": "10.7.0.1"
            }));
        }
    }
}
