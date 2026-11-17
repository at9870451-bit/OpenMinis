use crate::Shared;
use poki_setup_core::apple::anisette::Source;
use poki_setup_core::{Progress, Reporter, device, keeper, mcp, pairshare, relay, release, setup, support};
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};

/// Errors cross to the page as `{kind, message}`.
#[derive(Serialize)]
pub struct Failure {
    kind: &'static str,
    message: String,
}
impl From<poki_setup_core::Error> for Failure {
    fn from(e: poki_setup_core::Error) -> Self { Failure { kind: e.kind(), message: e.to_string() } }
}
impl From<String> for Failure {
    fn from(s: String) -> Self { Failure { kind: "message", message: s } }
}
type R<T> = Result<T, Failure>;

#[derive(Serialize, Clone)]
struct Event<'a> {
    job: &'a str,
    #[serde(flatten)]
    progress: Progress,
}

/// A reporter that emits `progress` events tagged with the job name.
pub fn reporter(app: &AppHandle, job: &str) -> Reporter {
    let app = app.clone();
    let job = job.to_string();
    Reporter::new(move |p| {
        let _ = app.emit("progress", Event { job: &job, progress: p });
    })
}

async fn with_signer<T>(state: &Shared, f: impl AsyncFnOnce(&mut setup::Signer) -> poki_setup_core::Result<T>) -> R<T> {
    let mut guard = state.signer.lock().await;
    if guard.is_none() {
        *guard = Some(setup::Signer::open()?);
    }
    match f(guard.as_mut().unwrap()).await {
        Ok(v) => Ok(v),
        Err(poki_setup_core::Error::NeedsCode(pending)) => {
            let msg = poki_setup_core::Error::NeedsCode(pending.clone()).to_string();
            *state.pending.lock().await = Some(*pending);
            Err(Failure { kind: "needs_code", message: msg })
        }
        Err(e) => Err(e.into()),
    }
}

#[derive(Serialize)]
pub struct AppInfo {
    version: String,
    os: &'static str,
    arch: &'static str,
    data_dir: String,
    can_use_system_anisette: bool,
}

#[tauri::command]
pub fn app_info() -> AppInfo {
    AppInfo { version: poki_setup_core::full_version(), os: std::env::consts::OS, arch: std::env::consts::ARCH, data_dir: poki_setup_core::paths::data_dir().display().to_string(), can_use_system_anisette: cfg!(target_os = "macos") }
}

#[derive(Serialize)]
pub struct PhoneRow {
    phone: device::Phone,
    facts: Option<device::info::Facts>,
    error: Option<String>,
    record: Option<keeper::Record>,
}

#[tauri::command]
pub async fn phones() -> R<Vec<PhoneRow>> {
    let list = match device::Phone::list().await {
        Ok(l) => l,
        Err(poki_setup_core::Error::Device(m)) if m.contains("usbmuxd") => return Err(Failure { kind: "usbmuxd", message: m }),
        Err(e) => return Err(e.into()),
    };
    let mut rows = vec![];
    for p in list {
        let (facts, error) = match device::info::read(&p).await {
            Ok(f) => (Some(f), None),
            Err(e) => (None, Some(e.to_string())),
        };
        let record = keeper::get(&p.udid).ok().flatten();
        rows.push(PhoneRow { phone: p, facts, error, record });
    }
    Ok(rows)
}

#[tauri::command]
pub async fn pair(app: AppHandle, udid: String) -> R<()> {
    let phone = setup::pick_phone(Some(&udid)).await?;
    device::pairing::pair(&phone, &reporter(&app, "pair"), std::time::Duration::from_secs(120)).await?;
    Ok(())
}

#[tauri::command]
pub async fn share_pairing(state: State<'_, Shared>, udid: String) -> R<pairshare::Handoff> {
    let record = device::pairing::for_poki(&udid)?.ok_or_else(|| poki_setup_core::Error::msg("Pair with the iPhone first."))?;
    let mut guard = state.handoff.lock().await;
    if let Some(old) = guard.take() {
        old.stop();
    }
    let server = pairshare::serve(record).await?;
    let handoff = server.handoff.clone();
    *guard = Some(server);
    Ok(handoff)
}

/// The person chose Replace Certificate: the next install revokes the certificate it asked about.
#[tauri::command]
pub async fn approve_certificate_replacement() -> R<usize> { Ok(poki_setup_core::apple::identity::approve_replacement()?) }

#[tauri::command]
pub async fn stop_sharing(state: State<'_, Shared>) -> R<()> {
    if let Some(s) = state.handoff.lock().await.take() {
        s.stop();
    }
    Ok(())
}

#[tauri::command]
pub async fn devmode(app: AppHandle, udid: String) -> R<bool> {
    let phone = setup::pick_phone(Some(&udid)).await?;
    let r = reporter(&app, "devmode");
    if device::devmode::enable(&phone, &r).await? {
        return Ok(true);
    }
    device::devmode::wait_until_on(&udid, &r, std::time::Duration::from_secs(600)).await?;
    Ok(true)
}

#[derive(Serialize)]
pub struct AccountView {
    signed_in: bool,
    apple_id: Option<String>,
    name: Option<String>,
    team_id: Option<String>,
    password_kept: bool,
    anisette: Source,
    pending_factor: Option<poki_setup_core::apple::gsa::Factor>,
}

#[tauri::command]
pub async fn account(state: State<'_, Shared>) -> R<AccountView> {
    let pending = state.pending.lock().await.as_ref().map(|p| p.via);
    with_signer(&state, async |s| {
        Ok(AccountView {
            signed_in: s.signed_in(),
            apple_id: s.account.apple_id().map(|a| a.to_string()),
            name: s.account.display_name(),
            team_id: s.account.team_id.clone(),
            password_kept: s.account.password.is_some(),
            anisette: s.account.anisette.clone().unwrap_or_else(Source::default_for_platform),
            pending_factor: pending,
        })
    })
    .await
}

/// Returns the factor when a code is needed, else null.
#[tauri::command]
pub async fn sign_in(state: State<'_, Shared>, apple_id: String, password: String, keep_password: bool) -> R<Option<poki_setup_core::apple::gsa::Factor>> {
    let pending = with_signer(&state, async |s| s.sign_in(&apple_id, &password, keep_password).await).await?;
    let via = pending.as_ref().map(|p| p.via);
    *state.pending.lock().await = pending;
    Ok(via)
}

#[tauri::command]
pub async fn finish_sign_in(state: State<'_, Shared>, code: String) -> R<()> {
    let pending = state.pending.lock().await.take().ok_or_else(|| poki_setup_core::Error::msg("Start the sign-in again."))?;
    let keep = pending.clone();
    let result = with_signer(&state, async |s| s.finish_sign_in(pending, &code).await).await;
    if result.is_err() {
        // A wrong code: keep the waiting sign-in so the person can type the code again. Starting
        // over would ask Apple for another code, which replaces this one and counts toward its limit.
        *state.pending.lock().await = Some(keep);
    }
    result
}

#[tauri::command]
pub async fn sign_out(state: State<'_, Shared>) -> R<()> {
    *state.pending.lock().await = None;
    with_signer(&state, async |s| s.sign_out()).await
}

#[tauri::command]
pub async fn teams(state: State<'_, Shared>) -> R<Vec<poki_setup_core::apple::portal::Team>> { with_signer(&state, async |s| s.teams().await).await }

#[tauri::command]
pub async fn choose_team(state: State<'_, Shared>, team_id: String) -> R<()> { with_signer(&state, async |s| s.choose_team(&team_id)).await }

#[tauri::command]
pub async fn set_anisette(state: State<'_, Shared>, source: Source) -> R<()> { with_signer(&state, async |s| s.set_anisette(source)).await }

#[derive(Serialize)]
pub struct InstallResult {
    record: keeper::Record,
    notes: Vec<String>,
    handoff: Option<pairshare::Handoff>,
}

#[tauri::command]
pub async fn install(app: AppHandle, state: State<'_, Shared>, udid: Option<String>, ipa: Option<String>, hand_off: bool) -> R<InstallResult> {
    {
        let mut busy = state.busy.lock().await;
        if *busy {
            return Err("Another setup is running.".to_string().into());
        }
        *busy = true;
    }
    let r = reporter(&app, "install");
    let opts = setup::Options { udid, ipa: ipa.map(Into::into), signing_zip: None, wait: None, hand_off, seed_ddi: true };
    let result = with_signer(&state, async |s| setup::run(s, opts, &r).await).await;
    *state.busy.lock().await = false;
    let done = result?;
    let handoff = done.handoff.as_ref().map(|s| s.handoff.clone());
    if let Some(server) = done.handoff {
        let mut guard = state.handoff.lock().await;
        if let Some(old) = guard.take() {
            old.stop();
        }
        *guard = Some(server);
    }
    Ok(InstallResult { record: done.record, notes: done.notes, handoff })
}

#[tauri::command]
pub fn records() -> R<Vec<keeper::Record>> { Ok(keeper::all()?) }

#[tauri::command]
pub async fn renew(app: AppHandle, state: State<'_, Shared>, udid: String) -> R<keeper::Record> {
    let r = reporter(&app, "renew");
    with_signer(&state, async |s| setup::renew(s, &udid, &r).await).await
}

#[tauri::command]
pub fn forget_phone(udid: String) -> R<()> { Ok(keeper::remove(&udid)?) }

#[tauri::command]
pub async fn latest_release() -> R<release::Release> { Ok(release::latest().await?) }

#[tauri::command]
pub fn relay_state() -> R<Option<relay::Deployed>> { Ok(relay::remembered()?) }

/// Whether a newer relay than the deployed one is out.
#[tauri::command]
pub async fn relay_worker() -> R<relay::WorkerStatus> { Ok(relay::worker_status().await?) }

#[tauri::command]
pub async fn relay_accounts(token: Option<String>) -> R<Vec<relay::Account>> {
    let token = relay::token_or_saved(token)?;
    Ok(relay::Cloudflare::new(&token)?.accounts().await?)
}

#[tauri::command]
pub fn relay_token_saved() -> bool { relay::saved_token().is_some() }

#[tauri::command]
pub fn relay_forget_token() -> R<()> { Ok(relay::forget_token()?) }

#[tauri::command]
pub async fn relay_deploy(app: AppHandle, token: Option<String>, account_id: String) -> R<relay::Deployed> {
    let token = relay::token_or_saved(token)?;
    let cf = relay::Cloudflare::new(&token)?;
    let acct = cf.accounts().await?.into_iter().find(|a| a.id == account_id).ok_or_else(|| poki_setup_core::Error::msg("That account is not visible to this token."))?;
    let d = cf.deploy(&acct, &reporter(&app, "relay")).await?;
    relay::remember(&d)?;
    let _ = relay::save_token(&token);
    Ok(d)
}

#[tauri::command]
pub async fn relay_check(address: String) -> R<bool> { Ok(mcp::relay_up(address.trim_end_matches('/')).await.unwrap_or(false)) }

#[tauri::command]
pub fn connectors() -> R<Vec<mcp::Connector>> { Ok(mcp::all()?) }

#[tauri::command]
pub fn connector_add(name: String, url: String) -> R<mcp::Connector> { Ok(mcp::add(&name, &url)?) }

#[tauri::command]
pub fn connector_forget(url: String) -> R<()> { Ok(mcp::forget(&url)?) }

#[tauri::command]
pub async fn connector_check(url: String) -> R<mcp::Check> {
    let k = mcp::check(&url).await?;
    let _ = mcp::record_check(&url, &k);
    Ok(k)
}

#[tauri::command]
pub fn connector_snippets(url: String) -> R<Vec<(String, String)>> {
    mcp::parse(&url)?;
    Ok(mcp::snippets(&url))
}

#[tauri::command]
pub async fn logs_start(app: AppHandle, state: State<'_, Shared>, udid: String, filter: Option<String>) -> R<()> {
    logs_stop(state.clone()).await?;
    let phone = setup::pick_phone(Some(&udid)).await?;
    let (tx, mut rx) = tokio::sync::mpsc::channel::<String>(512);
    let app2 = app.clone();
    let handle = tokio::spawn(async move {
        let stream = tokio::spawn(async move { device::logs::syslog(&phone, filter, tx).await });
        let mut batch = vec![];
        let mut tick = tokio::time::interval(std::time::Duration::from_millis(200));
        loop {
            tokio::select! {
                line = rx.recv() => match line {
                    Some(l) => batch.push(l),
                    None => break,
                },
                _ = tick.tick() => if !batch.is_empty() {
                    let _ = app2.emit("log-lines", std::mem::take(&mut batch));
                }
            }
        }
        if !batch.is_empty() {
            let _ = app2.emit("log-lines", batch);
        }
        if let Ok(Err(e)) = stream.await {
            let _ = app2.emit("log-lines", vec![format!("[poki-setup] log stream ended: {e}")]);
        }
    });
    *state.logs.lock().await = Some(handle);
    Ok(())
}

#[tauri::command]
pub async fn logs_stop(state: State<'_, Shared>) -> R<()> {
    if let Some(h) = state.logs.lock().await.take() {
        h.abort();
    }
    Ok(())
}

#[tauri::command]
pub async fn mount_ddi(app: AppHandle, udid: String) -> R<()> {
    let phone = setup::pick_phone(Some(&udid)).await?;
    device::ddi::mount(&phone, &reporter(&app, "ddi")).await?;
    Ok(())
}

#[tauri::command]
pub async fn support_bundle(udid: Option<String>, out_dir: String) -> R<String> {
    let phone = match udid {
        Some(u) => setup::pick_phone(Some(&u)).await.ok(),
        None => None,
    };
    let b = support::build(phone.as_ref(), std::path::Path::new(&out_dir)).await?;
    Ok(b.path.display().to_string())
}

/// Poki Setup's own update on the chosen channel.
#[tauri::command]
pub async fn check_update() -> R<release::UpdateInfo> { Ok(release::desktop_update().await?) }

/// The instructions to hand an agent on this computer; they name the poki-setup.exe installed
/// next to this app.
#[tauri::command]
pub fn agent_prompt() -> String { poki_setup_core::agent::prompt_for(poki_setup_core::agent::cli_path().as_deref()) }

/// Downloads the newer Poki Setup and starts its installer in passive mode; the installer
/// starts Poki Setup again, so this one quits.
#[tauri::command]
pub async fn install_update(app: AppHandle) -> R<release::Installed> {
    let done = release::install_desktop_update(&reporter(&app, "update")).await?;
    if done.relaunching {
        let a = app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(600)).await;
            a.exit(0);
        });
    }
    Ok(done)
}

/// Every channel with its newest release, the chosen one marked.
#[tauri::command]
pub async fn channels() -> R<Vec<release::ChannelInfo>> { Ok(release::channels().await?) }

#[tauri::command]
pub async fn set_channel(channel: String) -> R<Vec<release::ChannelInfo>> {
    release::set_channel(channel.parse()?)?;
    Ok(release::channels().await?)
}

#[tauri::command]
pub fn qr_svg(text: String) -> R<String> { Ok(pairshare::qr_svg(&text)?) }
