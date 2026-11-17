//! Poki Setup's core behind a pipe, for the native macOS app (SwiftUI).
//!
//! One JSON object per line on stdin: `{"id": 1, "cmd": "account", "args": {...}}`.
//! One JSON object per line on stdout:
//! - `{"id": 1, "ok": <result>}` or `{"id": 1, "err": {"kind": "...", "message": "..."}}`
//! - `{"event": "progress", "data": {"job": "install", "kind": "step", ...}}`
//! - `{"event": "log_lines", "data": ["...", ...]}`
//!
//! Requests run concurrently; the Apple account is behind one lock, as in the Tauri shell.
//! Logs go to stderr. The process ends when stdin closes.
use poki_setup_core::apple::anisette::Source;
use poki_setup_core::{Error, Progress, Reporter, device, keeper, mcp, pairshare, relay, release, setup, support};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::sync::{Mutex, mpsc};

#[derive(Deserialize)]
struct Request {
    id: u64,
    cmd: String,
    #[serde(default)]
    args: Value,
}

#[derive(Serialize)]
struct Failure {
    kind: &'static str,
    message: String,
}

impl From<Error> for Failure {
    fn from(e: Error) -> Self { Failure { kind: e.kind(), message: e.to_string() } }
}
impl From<String> for Failure {
    fn from(s: String) -> Self { Failure { kind: "message", message: s } }
}
impl From<&str> for Failure {
    fn from(s: &str) -> Self { Failure { kind: "message", message: s.to_string() } }
}
impl From<serde_json::Error> for Failure {
    fn from(e: serde_json::Error) -> Self { Failure { kind: "bad_request", message: e.to_string() } }
}

type R = Result<Value, Failure>;

/// Where Poki keeps its agent backup, inside its container.
const AGENT_BACKUP: &str = "Documents/AgentBackup/poki-agent-backup.json";

/// The files Poki and the installer (bin/install-iphone.mjs) hand each other in Poki's container:
/// Poki's hello (its version, a public key and how its connection is) and a model key sealed to that
/// key. Only these names, so the commands cannot reach anything else in Poki's sandbox.
const HANDOFF_FILES: [&str; 2] = ["poki-hello.json", "model-key.json"];

fn handoff_path(name: &str) -> Result<String, Failure> {
    if !HANDOFF_FILES.contains(&name) {
        return Err(Failure { kind: "bad_request", message: format!("not a Poki hand-off file: {name}") });
    }
    Ok(format!("Documents/PokiSetup/{name}"))
}

fn time_stamp() -> String {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    secs.to_string()
}

#[derive(Default)]
struct Shared {
    signer: Mutex<Option<setup::Signer>>,
    pending: Mutex<Option<poki_setup_core::apple::gsa::Pending>>,
    handoff: Mutex<Option<pairshare::Server>>,
    logs: Mutex<Option<tokio::task::JoinHandle<()>>>,
    busy: Mutex<bool>,
    update: Mutex<Option<poki_setup_core::update::Prepared>>,
}

#[derive(Clone)]
struct Out(mpsc::UnboundedSender<String>);

impl Out {
    fn send(&self, v: Value) { let _ = self.0.send(v.to_string()); }
    fn reporter(&self, job: &str) -> Reporter {
        let out = self.clone();
        let job = job.to_string();
        Reporter::new(move |p: Progress| {
            let mut data = serde_json::to_value(&p).unwrap_or(Value::Null);
            if let Value::Object(m) = &mut data {
                m.insert("job".into(), Value::String(job.clone()));
            }
            out.send(json!({ "event": "progress", "data": data }));
        })
    }
}

fn ok<T: Serialize>(v: T) -> R { Ok(serde_json::to_value(v)?) }

fn arg<T: for<'de> Deserialize<'de>>(args: &Value, key: &str) -> Result<T, Failure> {
    serde_json::from_value(args.get(key).cloned().unwrap_or(Value::Null)).map_err(|e| Failure { kind: "bad_request", message: format!("{key}: {e}") })
}

async fn with_signer<T>(state: &Shared, f: impl AsyncFnOnce(&mut setup::Signer) -> poki_setup_core::Result<T>) -> Result<T, Failure> {
    let mut guard = state.signer.lock().await;
    if guard.is_none() {
        *guard = Some(setup::Signer::open()?);
    }
    match f(guard.as_mut().unwrap()).await {
        Ok(v) => Ok(v),
        Err(Error::NeedsCode(pending)) => {
            let msg = Error::NeedsCode(pending.clone()).to_string();
            *state.pending.lock().await = Some(*pending);
            Err(Failure { kind: "needs_code", message: msg })
        }
        Err(e) => Err(e.into()),
    }
}

#[tokio::main]
async fn main() {
    // Log to stderr (the app's Helper Log) and to the log file the Support Bundle collects.
    let file = poki_setup_core::paths::log_dir().ok().and_then(|d| std::fs::OpenOptions::new().create(true).append(true).open(d.join("poki-setup.log")).ok());
    use tracing_subscriber::fmt::writer::MakeWriterExt;
    let writer = std::io::stderr.and(std::sync::Mutex::new(FileOrSink(file)));
    tracing_subscriber::fmt().with_writer(writer).with_ansi(false).with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "poki_setup_core=info".into())).init();
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    let out = Out(tx);
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(line) = rx.recv().await {
            if stdout.write_all(line.as_bytes()).await.is_err() || stdout.write_all(b"\n").await.is_err() || stdout.flush().await.is_err() {
                break;
            }
        }
    });
    out.send(json!({ "event": "ready", "data": { "version": poki_setup_core::full_version() } }));
    let state = Arc::new(Shared::default());
    let mut lines = tokio::io::BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        let req: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                out.send(json!({ "id": Value::Null, "err": { "kind": "bad_request", "message": e.to_string() } }));
                continue;
            }
        };
        let state = state.clone();
        let out = out.clone();
        tokio::spawn(async move {
            let id = req.id;
            let reply = match dispatch(&state, &out, &req.cmd, &req.args).await {
                Ok(v) => json!({ "id": id, "ok": v }),
                Err(f) => json!({ "id": id, "err": f }),
            };
            out.send(reply);
        });
    }
    drop(out);
    let _ = writer.await;
}

#[derive(Serialize)]
struct PhoneRow {
    phone: device::Phone,
    facts: Option<device::info::Facts>,
    error: Option<String>,
    record: Option<keeper::Record>,
}

async fn dispatch(state: &Shared, out: &Out, cmd: &str, a: &Value) -> R {
    match cmd {
        "app_info" => ok(json!({
            "version": poki_setup_core::full_version(),
            "update_only": 1,
            "os": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
            "data_dir": poki_setup_core::paths::data_dir().display().to_string(),
            "can_use_system_anisette": cfg!(target_os = "macos"),
            "default_anisette": poki_setup_core::apple::anisette::DEFAULT_REMOTE,
            "anisette_servers": poki_setup_core::apple::anisette::FALLBACK_REMOTES,
        })),
        "phones" => {
            let list = match device::Phone::list().await {
                Ok(l) => l,
                Err(Error::Device(m)) if m.contains("usbmuxd") => return Err(Failure { kind: "usbmuxd", message: m }),
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
            ok(rows)
        }
        "pair" => {
            let udid: String = arg(a, "udid")?;
            let phone = setup::pick_phone(Some(&udid)).await?;
            device::pairing::pair(&phone, &out.reporter("pair"), std::time::Duration::from_secs(120)).await?;
            ok(true)
        }
        "share_pairing" => {
            let udid: String = arg(a, "udid")?;
            let record = device::pairing::for_poki(&udid)?.ok_or_else(|| Error::msg("Pair with the iPhone first."))?;
            let mut guard = state.handoff.lock().await;
            if let Some(old) = guard.take() {
                old.stop();
            }
            let server = pairshare::serve(record).await?;
            let h = server.handoff.clone();
            *guard = Some(server);
            ok(h)
        }
        "approve_certificate_replacement" => ok(poki_setup_core::apple::identity::approve_replacement()?),
        "stop_sharing" => {
            if let Some(s) = state.handoff.lock().await.take() {
                s.stop();
            }
            ok(true)
        }
        "devmode" => {
            let udid: String = arg(a, "udid")?;
            let phone = setup::pick_phone(Some(&udid)).await?;
            let r = out.reporter("devmode");
            if !device::devmode::enable(&phone, &r).await? {
                device::devmode::wait_until_on(&udid, &r, std::time::Duration::from_secs(600)).await?;
            }
            ok(true)
        }
        "account" => {
            let pending = state.pending.lock().await.as_ref().map(|p| p.via);
            with_signer(state, async |s| {
                Ok(json!({
                    "signed_in": s.signed_in(),
                    "apple_id": s.account.apple_id(),
                    "name": s.account.display_name(),
                    "team_id": s.account.team_id,
                    "password_kept": s.account.password.is_some(),
                    "anisette": s.account.anisette.clone().unwrap_or_else(Source::default_for_platform),
                    "pending_factor": pending,
                }))
            })
            .await
        }
        "sign_in" => {
            let apple_id: String = arg(a, "apple_id")?;
            let password: String = arg(a, "password")?;
            let keep: bool = arg::<Option<bool>>(a, "keep_password")?.unwrap_or(true);
            let pending = with_signer(state, async |s| s.sign_in(&apple_id, &password, keep).await).await?;
            let via = pending.as_ref().map(|p| p.via);
            *state.pending.lock().await = pending;
            ok(json!({ "needs_code": via.is_some(), "via": via }))
        }
        "finish_sign_in" => {
            let code: String = arg(a, "code")?;
            let pending = state.pending.lock().await.take().ok_or_else(|| Error::msg("Start the sign-in again."))?;
            let keep = pending.clone();
            match with_signer(state, async |s| s.finish_sign_in(pending, &code).await).await {
                Ok(()) => ok(true),
                Err(f) => {
                    // A wrong code: keep the pending sign-in so the person can type it again.
                    *state.pending.lock().await = Some(keep);
                    Err(f)
                }
            }
        }
        "sign_out" => {
            *state.pending.lock().await = None;
            with_signer(state, async |s| s.sign_out()).await?;
            ok(true)
        }
        "teams" => ok(with_signer(state, async |s| s.teams().await).await?),
        "choose_team" => {
            let team_id: String = arg(a, "team_id")?;
            with_signer(state, async |s| s.choose_team(&team_id)).await?;
            ok(true)
        }
        "set_anisette" => {
            let source: Source = arg(a, "source")?;
            with_signer(state, async |s| s.set_anisette(source)).await?;
            ok(true)
        }
        "install" => {
            {
                let mut busy = state.busy.lock().await;
                if *busy {
                    return Err("Another setup is running.".into());
                }
                *busy = true;
            }
            let udid: Option<String> = arg(a, "udid")?;
            let ipa: Option<String> = arg(a, "ipa")?;
            let hand_off: bool = arg::<Option<bool>>(a, "hand_off")?.unwrap_or(false);
            let r = out.reporter("install");
            // Poki counts pairing as done only with the disk image in place, so it goes in with the pairing file.
            let seed_ddi: bool = arg::<Option<bool>>(a, "seed_ddi")?.unwrap_or(true);
            let opts = setup::Options { udid, ipa: ipa.map(Into::into), signing_zip: None, wait: None, hand_off, seed_ddi };
            let result = with_signer(state, async |s| setup::run(s, opts, &r).await).await;
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
            ok(json!({ "record": done.record, "notes": done.notes, "handoff": handoff }))
        }
        "sign_ipa" => {
            // Re-sign an IPA for the chosen team without a phone (no device registered).
            let ipa: String = arg(a, "ipa")?;
            let out_path: String = arg(a, "out")?;
            let r = out.reporter("sign");
            let built = with_signer(state, async |s| {
                let team = s.team().await?;
                let beside = std::path::Path::new(&ipa).with_file_name("Poki-signing.zip");
                let zipp = beside.is_file().then_some(beside);
                setup::sign_for_team(s, &team, None, std::path::Path::new(&ipa), zipp.as_deref(), std::path::Path::new(&out_path), &r).await
            })
            .await?;
            ok(json!({ "ipa": built.ipa, "bundle_id": built.bundle_id, "version": built.version, "build": built.build, "profile_expires_at": built.profile_expires_at }))
        }
        "records" => ok(keeper::all()?),
        "update_inspect" => {
            let udid: Option<String> = arg(a, "udid")?;
            let reporter = Reporter::silent();
            let plan = with_signer(state, async |s| poki_setup_core::update::prepare(s, udid.as_deref(), &reporter).await).await?;
            let summary = plan.summary();
            *state.update.lock().await = Some(plan);
            ok(summary)
        }
        "update_readback" => {
            let udid: String = arg(a, "udid")?;
            let app = poki_setup_core::update::readback(&udid).await?;
            ok(json!({"version": app.version, "build": app.build}))
        }
        "renew" => {
            let udid: String = arg(a, "udid")?;
            let r = out.reporter("renew");
            if arg::<Option<bool>>(a, "update_only")?.unwrap_or(false) {
                let expected = arg(a, "expected")?;
                let plan = state.update.lock().await.take().ok_or_else(|| Error::UpdateCheck("No verified update is prepared; rerun update-only before installation."))?;
                ok(with_signer(state, async |s| plan.renew(s, &udid, &expected, &r).await).await?)
            } else {
                ok(with_signer(state, async |s| setup::renew(s, &udid, &r).await).await?)
            }
        }
        "renew_due" => {
            let r = out.reporter("renew");
            let results = with_signer(state, async |s| Ok(setup::renew_due(s, &r).await)).await?;
            let mut rows = Vec::with_capacity(results.len());
            for (udid, res) in results {
                match res {
                    Ok(_) => rows.push(json!({ "udid": udid, "ok": true, "error": Value::Null })),
                    Err(Error::NeedsCode(pending)) => {
                        let msg = Error::NeedsCode(pending.clone()).to_string();
                        *state.pending.lock().await = Some(*pending);
                        rows.push(json!({ "udid": udid, "ok": false, "error": msg, "kind": "needs_code" }));
                    }
                    Err(e) => rows.push(json!({ "udid": udid, "ok": false, "error": e.to_string() })),
                }
            }
            ok(rows)
        }
        "forget_phone" => {
            let udid: String = arg(a, "udid")?;
            keeper::remove(&udid)?;
            ok(true)
        }
        // The agent's memory (routines, notes, non-secret settings) as Poki exports it.
        "backup_agent" => {
            let udid: String = arg(a, "udid")?;
            let out_dir: String = arg(a, "out_dir")?;
            let rec = keeper::get(&udid)?.ok_or_else(|| Error::msg("Set up Poki on this iPhone with Poki Setup first."))?;
            let phone = setup::pick_phone(Some(&udid)).await?;
            let bytes = device::container::read_file(&phone, &rec.bundle_id, AGENT_BACKUP).await.map_err(|e| Error::msg(format!("Poki has not exported a backup yet. Open Poki once, then try again. ({e})")))?;
            let stamp = time_stamp();
            let path = std::path::Path::new(&out_dir).join(format!("poki-agent-backup-{}-{stamp}.json", rec.phone_name.replace(['/', ':'], "-")));
            std::fs::write(&path, &bytes).map_err(Error::from)?;
            ok(json!({ "path": path.display().to_string(), "bytes": bytes.len() }))
        }
        "restore_agent" => {
            let udid: String = arg(a, "udid")?;
            let file: String = arg(a, "file")?;
            let rec = keeper::get(&udid)?.ok_or_else(|| Error::msg("Set up Poki on this iPhone with Poki Setup first."))?;
            let bytes = std::fs::read(&file).map_err(Error::from)?;
            let v: Value = serde_json::from_slice(&bytes).map_err(|e| Error::msg(format!("That file is not a Poki agent backup: {e}")))?;
            if !v.get("schema").and_then(|s| s.as_str()).map(|s| s.starts_with("poki.agent-backup/")).unwrap_or(false) {
                return Err("That file is not a Poki agent backup (no poki.agent-backup schema).".into());
            }
            let phone = setup::pick_phone(Some(&udid)).await?;
            device::container::write_file(&phone, &rec.bundle_id, AGENT_BACKUP, &bytes).await?;
            ok(true)
        }
        "container_read" => {
            use base64::Engine;
            let udid: String = arg(a, "udid")?;
            let path = handoff_path(&arg::<String>(a, "name")?)?;
            let rec = keeper::get(&udid)?.ok_or_else(|| Error::msg("Set up Poki on this iPhone with Poki Setup first."))?;
            let phone = setup::pick_phone(Some(&udid)).await?;
            let bytes = device::container::read_file(&phone, &rec.bundle_id, &path).await?;
            ok(base64::engine::general_purpose::STANDARD.encode(bytes))
        }
        "container_write" => {
            use base64::Engine;
            let udid: String = arg(a, "udid")?;
            let path = handoff_path(&arg::<String>(a, "name")?)?;
            let bytes = base64::engine::general_purpose::STANDARD.decode(arg::<String>(a, "data")?).map_err(|e| Failure { kind: "bad_request", message: format!("data: {e}") })?;
            let rec = keeper::get(&udid)?.ok_or_else(|| Error::msg("Set up Poki on this iPhone with Poki Setup first."))?;
            let phone = setup::pick_phone(Some(&udid)).await?;
            device::container::write_file(&phone, &rec.bundle_id, &path, &bytes).await?;
            ok(true)
        }
        "latest_release" => ok(release::latest().await?),
        // Every channel with its newest release, the chosen one marked (Settings' picker).
        "channels" => ok(release::channels().await?),
        "set_channel" => {
            let channel: String = arg(a, "channel")?;
            release::set_channel(channel.parse()?)?;
            ok(release::channels().await?)
        }
        "relay_state" => ok(relay::remembered()?),
        "relay_worker" => ok(relay::worker_status().await?),
        "relay_token_saved" => ok(relay::saved_token().is_some()),
        "relay_forget_token" => ok(relay::forget_token()?),
        "relay_accounts" => {
            let token = relay::token_or_saved(a.get("token").and_then(|v| v.as_str()).map(String::from))?;
            ok(relay::Cloudflare::new(&token)?.accounts().await?)
        }
        "relay_deploy" => {
            let token = relay::token_or_saved(a.get("token").and_then(|v| v.as_str()).map(String::from))?;
            let account_id: String = arg(a, "account_id")?;
            let cf = relay::Cloudflare::new(&token)?;
            let acct = cf.accounts().await?.into_iter().find(|x| x.id == account_id).ok_or_else(|| Error::msg("That account is not visible to this token."))?;
            let d = cf.deploy(&acct, &out.reporter("relay")).await?;
            relay::remember(&d)?;
            if let Err(e) = relay::save_token(&token) { tracing::warn!("could not keep the Cloudflare token: {e}"); }
            ok(d)
        }
        "relay_check" => {
            let address: String = arg(a, "address")?;
            ok(mcp::relay_up(address.trim_end_matches('/')).await.unwrap_or(false))
        }
        "connectors" => ok(mcp::all()?),
        "connector_add" => {
            let name: String = arg(a, "name")?;
            let url: String = arg(a, "url")?;
            ok(mcp::add(&name, &url)?)
        }
        "connector_forget" => {
            let url: String = arg(a, "url")?;
            mcp::forget(&url)?;
            ok(true)
        }
        "connector_check" => {
            let url: String = arg(a, "url")?;
            let k = mcp::check(&url).await?;
            let _ = mcp::record_check(&url, &k);
            ok(k)
        }
        "connector_snippets" => {
            let url: String = arg(a, "url")?;
            mcp::parse(&url)?;
            ok(mcp::snippets(&url).into_iter().map(|(name, text)| json!({ "name": name, "text": text })).collect::<Vec<_>>())
        }
        "logs_start" => {
            let udid: String = arg(a, "udid")?;
            let filter: Option<String> = arg(a, "filter")?;
            if let Some(h) = state.logs.lock().await.take() {
                h.abort();
            }
            let phone = setup::pick_phone(Some(&udid)).await?;
            let (tx, mut rx) = mpsc::channel::<String>(512);
            let out2 = out.clone();
            let handle = tokio::spawn(async move {
                let stream = tokio::spawn(async move { device::logs::syslog(&phone, filter, tx).await });
                let mut batch = vec![];
                let mut tick = tokio::time::interval(std::time::Duration::from_millis(250));
                loop {
                    tokio::select! {
                        line = rx.recv() => match line {
                            Some(l) => batch.push(l),
                            None => break,
                        },
                        _ = tick.tick() => if !batch.is_empty() {
                            out2.send(json!({ "event": "log_lines", "data": std::mem::take(&mut batch) }));
                        }
                    }
                }
                if !batch.is_empty() {
                    out2.send(json!({ "event": "log_lines", "data": batch }));
                }
                if let Ok(Err(e)) = stream.await {
                    out2.send(json!({ "event": "log_lines", "data": [format!("[Poki Setup] The log stream ended: {e}")] }));
                }
            });
            *state.logs.lock().await = Some(handle);
            ok(true)
        }
        "logs_stop" => {
            if let Some(h) = state.logs.lock().await.take() {
                h.abort();
            }
            ok(true)
        }
        "mount_ddi" => {
            let udid: String = arg(a, "udid")?;
            let phone = setup::pick_phone(Some(&udid)).await?;
            device::ddi::mount(&phone, &out.reporter("ddi")).await?;
            ok(true)
        }
        "support_bundle" => {
            let udid: Option<String> = arg(a, "udid")?;
            let out_dir: String = arg(a, "out_dir")?;
            let phone = match udid {
                Some(u) => setup::pick_phone(Some(&u)).await.ok(),
                None => None,
            };
            let b = support::build(phone.as_ref(), std::path::Path::new(&out_dir)).await?;
            ok(b.path.display().to_string())
        }
        "check_update" => check_update().await,
        "install_update" => ok(release::install_desktop_update(&out.reporter("update")).await?),
        "agent_prompt" => ok(json!({ "prompt": poki_setup_core::agent::prompt_for(poki_setup_core::agent::cli_path().as_deref()) })),
        "agent_next" => ok(poki_setup_core::agent::next(None).await),
        "ping" => ok("pong"),
        other => Err(Failure { kind: "bad_request", message: format!("unknown command {other}") }),
    }
}

async fn check_update() -> R { ok(release::desktop_update().await?) }

/// The log file, or nowhere when it could not be opened.
struct FileOrSink(Option<std::fs::File>);

impl std::io::Write for FileOrSink {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match &mut self.0 {
            Some(f) => f.write(buf),
            None => Ok(buf.len()),
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        match &mut self.0 {
            Some(f) => f.flush(),
            None => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::handoff_path;

    #[test]
    fn the_container_commands_reach_only_the_two_hand_off_files() {
        assert_eq!(handoff_path("poki-hello.json").ok().as_deref(), Some("Documents/PokiSetup/poki-hello.json"));
        assert_eq!(handoff_path("model-key.json").ok().as_deref(), Some("Documents/PokiSetup/model-key.json"));
        for name in ["signing-identity.json", "../Library/Application Support/Poki/pairing.plist", "/etc/passwd", "", "poki-hello.json/.."] {
            assert!(handoff_path(name).is_err(), "{name} is refused");
        }
    }
}
