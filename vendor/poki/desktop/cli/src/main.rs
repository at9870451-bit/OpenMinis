//! `poki-setup`: the command line over Poki Setup's core. Same steps as the app, for maintainers,
//! scripts and anyone without a window system.
use anyhow::{Context, Result, anyhow};
use clap::{Parser, Subcommand};
use poki_setup_core::apple::anisette::Source;
use poki_setup_core::{Reporter, agent, device, keeper, mcp, pairshare, relay, release, setup, support};
use std::path::PathBuf;
use std::time::Duration;

#[derive(Parser)]
#[command(name = "poki-setup", version, about = "Install Poki on an iPhone, keep it signed, and manage the relay and connector links.", after_help = "For agents: start with `poki-setup next --json`, and `poki-setup prompt` prints the full instructions. With --json, results go to stdout, progress to stderr as JSON lines. Exit codes: 0 done, 1 failed, 2 a person has to act, 3 waiting for the Apple sign-in code.")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
    /// JSON for agents and scripts: the result on stdout, progress on stderr as one JSON object
    /// per line, and errors as {"ok": false, "error": {"kind", "message"}}.
    #[arg(long, global = true)]
    json: bool,
}

#[derive(Subcommand)]
enum Cmd {
    /// What is done and what is next, with who has to act and the command to run. Changes nothing.
    Next {
        #[arg(long)]
        udid: Option<String>,
    },
    /// The instructions to hand an agent on this computer (Claude Code, Codex and the like).
    Prompt,
    /// Update Poki Setup itself to the newest version on the channel.
    Update {
        /// Only say whether there is one.
        #[arg(long)]
        check: bool,
    },
    /// List the iPhones this computer can reach.
    Phones,
    /// Pair with the iPhone (Trust This Computer) and save the pairing file.
    Pair {
        #[arg(long)]
        udid: Option<String>,
        /// Seconds to wait for the Trust tap.
        #[arg(long, default_value_t = 120)]
        wait: u64,
        /// After pairing, serve the file on the LAN and print the QR for Poki to scan.
        #[arg(long)]
        share: bool,
    },
    /// Turn on Developer Mode (the iPhone restarts and asks once).
    Devmode {
        #[arg(long)]
        udid: Option<String>,
    },
    /// Sign in with an Apple ID. Asks for the password and the code. Without a terminal (agents):
    /// `--password-stdin`, then `login --code <code>` in a second run when Apple asks for one.
    Login {
        /// Not needed with --code.
        apple_id: Option<String>,
        /// Read the password from the first line of stdin instead of asking.
        #[arg(long)]
        password_stdin: bool,
        /// Finish a sign-in that is waiting for Apple's six-digit code.
        #[arg(long)]
        code: Option<String>,
        /// Keep the password in the keychain so weekly re-signing needs no one.
        #[arg(long)]
        keep_password: bool,
        /// `system` (macOS) or an anisette v3 server URL.
        #[arg(long)]
        anisette: Option<String>,
    },
    /// Forget the Apple session on this computer.
    Logout,
    /// List the teams, or choose one.
    Teams {
        #[arg(long = "use")]
        use_team: Option<String>,
    },
    /// The whole setup: pair, Developer Mode, get Poki, sign it for your team, install it, give it the pairing file.
    Install {
        #[arg(long)]
        udid: Option<String>,
        /// A local IPA instead of the latest release.
        #[arg(long)]
        ipa: Option<PathBuf>,
        #[arg(long)]
        signing_zip: Option<PathBuf>,
        /// Also serve the pairing file for the phone's QR.
        #[arg(long)]
        hand_off: bool,
        /// Pre-seed the developer disk image into Poki's container.
        #[arg(long)]
        seed_ddi: bool,
        #[arg(long, default_value_t = 120)]
        wait: u64,
        /// When the Apple Account is at its certificate limit, replace the Poki certificate the
        /// last attempt named. Every app it signed stops opening until it is installed again.
        #[arg(long)]
        replace_certificate: bool,
    },
    /// Sign an IPA for a team without installing it.
    Sign {
        #[arg(long)]
        ipa: PathBuf,
        #[arg(long)]
        out: PathBuf,
        #[arg(long)]
        team: Option<String>,
        /// Register this phone with the team first.
        #[arg(long)]
        udid: Option<String>,
        #[arg(long)]
        signing_zip: Option<PathBuf>,
    },
    /// Check the signing pipeline without an Apple Account: signs with a throwaway self-signed
    /// identity and stand-in profiles. The result does not install; verify it with `codesign`.
    #[command(hide = true)]
    SelftestSign {
        #[arg(long)]
        ipa: PathBuf,
        #[arg(long)]
        out: PathBuf,
        #[arg(long)]
        signing_zip: Option<PathBuf>,
        #[arg(long, default_value = "SELFTEST01")]
        team: String,
    },
    /// For support: the team's development certificates as Apple lists them.
    #[command(hide = true)]
    DebugCerts,
    /// Sign Poki again and reinstall it on a phone this computer set up.
    Renew {
        #[arg(long)]
        udid: Option<String>,
        /// Every phone whose profile is due.
        #[arg(long)]
        due: bool,
        /// As for install: replace the Poki certificate the last attempt named.
        #[arg(long)]
        replace_certificate: bool,
    },
    /// The phones this computer set up and when each needs signing again.
    Status,
    /// Mount the developer disk image (proof the phone is ready for automation).
    Ddi {
        #[arg(long)]
        udid: Option<String>,
    },
    /// Stream the iPhone's system log.
    Logs {
        #[arg(long)]
        udid: Option<String>,
        /// Only lines containing this text.
        #[arg(long)]
        filter: Option<String>,
    },
    /// Save a support bundle. Review identifiers, paths and raw logs before sharing.
    Support {
        #[arg(long)]
        udid: Option<String>,
        #[arg(long)]
        out: Option<PathBuf>,
    },
    /// The relay Worker on your Cloudflare account.
    Relay {
        #[command(subcommand)]
        cmd: RelayCmd,
    },
    /// Connector links (made on the phone; kept and checked here).
    Mcp {
        #[command(subcommand)]
        cmd: McpCmd,
    },
    /// The latest Poki release on the chosen channel, or every channel with --all.
    Release {
        /// List every channel and its newest release.
        #[arg(long)]
        all: bool,
    },
    /// Show the Beta update channel. Historical channel arguments also resolve to Beta.
    Channel {
        /// A legacy channel argument, normalized to Beta.
        set: Option<String>,
    },
}

#[derive(Subcommand)]
enum RelayCmd {
    /// Deploy or update the Worker. Reads CLOUDFLARE_API_TOKEN or asks.
    Deploy {
        #[arg(long)]
        account: Option<String>,
    },
    /// Is a relay answering at this address?
    Check { address: String },
    /// The QR that tells Poki on the phone which relay to use.
    Qr {
        address: Option<String>,
        #[arg(long)]
        svg: Option<PathBuf>,
    },
}

#[derive(Subcommand)]
enum McpCmd {
    List,
    Add { name: String, url: String },
    Forget { url: String },
    /// OAuth round and tools/list through the phone.
    Check { url: String },
    /// Client setups for the link.
    Snippets { url: String },
}

fn qr_text(text: &str) -> String {
    use qrcode::render::unicode;
    qrcode::QrCode::new(text.as_bytes()).map(|c| c.render::<unicode::Dense1x2>().quiet_zone(true).build()).unwrap_or_default()
}

fn out<T: serde::Serialize>(json: bool, value: &T, text: impl FnOnce(&T)) -> Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(value)?);
    } else {
        text(value);
    }
    Ok(())
}

async fn phone(udid: Option<&str>) -> Result<device::Phone> { Ok(setup::pick_phone(udid).await?) }

/// Exit codes agents can act on.
const EXIT_FAILED: i32 = 1;
const EXIT_PERSON: i32 = 2;
const EXIT_NEEDS_CODE: i32 = 3;

/// A sign-in that stopped at Apple's code: the second run (`login --code`) finishes it.
struct NeedsCode(String);
impl std::fmt::Display for NeedsCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str(&self.0) }
}
impl std::fmt::Debug for NeedsCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str(&self.0) }
}
impl std::error::Error for NeedsCode {}

/// The error's kind for agents, and the exit code that goes with it.
fn classify(e: &anyhow::Error) -> (&'static str, i32) {
    if e.downcast_ref::<NeedsCode>().is_some() {
        return ("needs_code", EXIT_NEEDS_CODE);
    }
    match e.downcast_ref::<poki_setup_core::Error>() {
        Some(poki_setup_core::Error::NeedsCode(_)) => ("needs_code", EXIT_NEEDS_CODE),
        Some(poki_setup_core::Error::NeedsPerson(_)) => ("needs_person", EXIT_PERSON),
        Some(poki_setup_core::Error::Keychain(_)) => ("keychain", EXIT_PERSON),
        Some(poki_setup_core::Error::CertificateLimit(_)) => ("certificate_limit", EXIT_PERSON),
        Some(poki_setup_core::Error::Apple { .. }) => ("apple", EXIT_FAILED),
        Some(poki_setup_core::Error::Device(_)) => ("device", EXIT_FAILED),
        Some(poki_setup_core::Error::Http(_)) => ("network", EXIT_FAILED),
        Some(poki_setup_core::Error::Sign(_)) => ("sign", EXIT_FAILED),
        _ => ("error", EXIT_FAILED),
    }
}

fn main() {
    let json = std::env::args().any(|a| a == "--json");
    let rt = tokio::runtime::Runtime::new().expect("tokio");
    if let Err(e) = rt.block_on(run()) {
        let (kind, code) = classify(&e);
        if json {
            println!("{}", serde_json::json!({ "ok": false, "error": { "kind": kind, "message": format!("{e:#}") } }));
        } else {
            eprintln!("Error: {e:#}");
        }
        std::process::exit(code);
    }
}

/// Progress as one JSON object per line on stderr, for agents.
fn json_reporter() -> Reporter { Reporter::new(|p| eprintln!("{}", serde_json::to_string(&p).unwrap_or_default())) }

/// The final result of a command that changes something: JSON for agents, a line for people.
fn finish(json: bool, value: serde_json::Value, text: impl AsRef<str>) -> Result<()> {
    if json {
        let mut v = value;
        if let Some(o) = v.as_object_mut() {
            o.insert("ok".into(), true.into());
        }
        println!("{v}");
    } else {
        println!("{}", text.as_ref());
    }
    Ok(())
}

const PENDING: &str = "pending-sign-in";

fn read_password(from_stdin: bool) -> Result<String> {
    if let Ok(p) = std::env::var("POKI_SETUP_PASSWORD") {
        if !p.is_empty() {
            return Ok(p);
        }
    }
    use std::io::{BufRead, IsTerminal};
    if from_stdin || !std::io::stdin().is_terminal() {
        let mut line = String::new();
        std::io::stdin().lock().read_line(&mut line)?;
        let p = line.trim_end_matches(['\r', '\n']).to_string();
        if p.is_empty() {
            return Err(poki_setup_core::Error::NeedsPerson("No password on stdin. Ask the person to run `poki-setup login <email>` in their own terminal.".into()).into());
        }
        return Ok(p);
    }
    Ok(rpassword::prompt_password("Apple ID password: ")?)
}

async fn run() -> Result<()> {
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::from_default_env()).with_writer(std::io::stderr).init();
    let cli = Cli::parse();
    let reporter = if cli.json { json_reporter() } else { Reporter::stderr() };
    match cli.cmd {
        Cmd::Next { udid } => {
            let n = agent::next(udid.as_deref()).await;
            out(cli.json, &n, |n| {
                println!("{}", n.summary);
                for (i, s) in n.steps.iter().enumerate() {
                    println!("{}. [{}] {}{}", i + 1, if s.who == agent::Who::Person { "you" } else { "agent" }, s.say, s.command.as_ref().map(|c| format!("\n   {c}")).unwrap_or_default());
                }
            })
        }
        Cmd::Prompt => {
            let text = agent::prompt_for(agent::cli_path().as_deref());
            out(cli.json, &serde_json::json!({ "prompt": text }), |_| print!("{text}"))
        }
        Cmd::Update { check } => {
            let info = release::desktop_update().await?;
            if check || !info.newer {
                return out(cli.json, &info, |i| match (&i.latest, i.newer) {
                    (Some(v), true) => println!("Poki Setup {} is available (this is {}). Run `poki-setup update`.", poki_setup_core::display_version(v), poki_setup_core::display_version(&i.current)),
                    _ => println!("Poki Setup {} is up to date on the {} channel.", poki_setup_core::display_version(&i.current), i.channel.title()),
                });
            }
            let done = release::install_desktop_update(&reporter).await?;
            finish(cli.json, serde_json::json!({ "installed": done.path, "relaunching": done.relaunching, "version": info.latest }), format!("Installed Poki Setup {} at {}.", poki_setup_core::display_version(&info.latest.unwrap_or_default()), done.path.display()))
        }
        Cmd::Phones => {
            let phones = device::Phone::list().await?;
            let mut rows = vec![];
            for p in phones {
                let facts = device::info::read(&p).await.ok();
                rows.push(serde_json::json!({ "udid": p.udid, "link": p.link, "facts": facts }));
            }
            out(cli.json, &rows, |rows| {
                if rows.is_empty() {
                    println!("No iPhone found. Plug it in with a cable and unlock it.");
                }
                for r in rows {
                    let f = &r["facts"];
                    println!("{}  {}  iOS {}  {}  dev mode: {}  paired: {}", r["udid"].as_str().unwrap_or(""), f["name"].as_str().unwrap_or("(locked or not paired)"), f["ios"].as_str().unwrap_or("?"), r["link"]["kind"].as_str().unwrap_or(""), f["developer_mode"], f["paired_with_this_computer"]);
                }
            })
        }
        Cmd::Pair { udid, wait, share } => {
            let p = phone(udid.as_deref()).await?;
            let record = device::pairing::pair(&p, &reporter, Duration::from_secs(wait)).await?;
            let path = device::pairing::record_path(&p.udid)?;
            if !share {
                return finish(cli.json, serde_json::json!({ "udid": p.udid, "pairing_file": path }), format!("Paired. Pairing file: {}", path.display()));
            }
            println!("Paired. Pairing file: {}", path.display());
            if share {
                let server = pairshare::serve(record).await?;
                println!("\nIn Poki on the iPhone, scan this (same Wi-Fi), or open {}\n", server.handoff.link);
                println!("{}", qr_text(&server.handoff.link));
                if server.wait_fetched(Duration::from_secs(600)).await {
                    println!("Poki fetched the pairing file.");
                } else {
                    println!("Nobody fetched it in ten minutes; run again when ready.");
                }
            }
            Ok(())
        }
        Cmd::Devmode { udid } => {
            let p = phone(udid.as_deref()).await?;
            if !device::devmode::enable(&p, &reporter).await? {
                device::devmode::wait_until_on(&p.udid, &reporter, Duration::from_secs(600)).await?;
            }
            finish(cli.json, serde_json::json!({ "udid": p.udid, "developer_mode": true }), "Developer Mode is on.")
        }
        Cmd::Login { apple_id, password_stdin, code, keep_password, anisette } => {
            let mut signer = setup::Signer::open()?;
            if let Some(code) = code {
                let saved = poki_setup_core::apple::store::secret_get(PENDING).ok_or_else(|| anyhow!("No sign-in is waiting for a code. Run `poki-setup login <email>` first."))?;
                let pending: poki_setup_core::apple::gsa::Pending = serde_json::from_str(&saved)?;
                signer.finish_sign_in(pending, &code).await?;
                let _ = poki_setup_core::apple::store::secret_delete(PENDING);
            } else {
                let apple_id = apple_id.ok_or_else(|| anyhow!("Give the Apple Account email: poki-setup login you@example.com"))?;
                if let Some(a) = anisette {
                    signer.set_anisette(if a == "system" { Source::System } else { Source::Remote { url: a } })?;
                }
                let password = read_password(password_stdin)?;
                if let Some(pending) = signer.sign_in(&apple_id, &password, keep_password).await? {
                    let via = match pending.via {
                        poki_setup_core::apple::gsa::Factor::TrustedDevice => "your Apple devices",
                        poki_setup_core::apple::gsa::Factor::Sms => "a text message",
                    };
                    use std::io::IsTerminal;
                    if cli.json || password_stdin || !std::io::stdin().is_terminal() {
                        poki_setup_core::apple::store::secret_set(PENDING, &serde_json::to_string(&pending)?)?;
                        return Err(NeedsCode(format!("Apple sent a six-digit code to {via}. Ask the person for it, then run: poki-setup login --code <code>")).into());
                    }
                    let code = rpassword::prompt_password(format!("Apple sent a code to {via}. Code: "))?;
                    signer.finish_sign_in(pending, &code).await?;
                }
            }
            let team = signer.team().await?;
            let name = signer.account.display_name().unwrap_or_default();
            finish(cli.json, serde_json::json!({ "signed_in": true, "account": name, "team": team.name, "team_id": team.team_id, "free": team.is_free }), format!("Signed in as {name}. Team: {} ({}){}", team.name, team.team_id, if team.is_free { ", free: Poki is signed for 7 days at a time" } else { "" }))
        }
        Cmd::Logout => {
            let mut signer = setup::Signer::open()?;
            signer.sign_out()?;
            println!("Signed out.");
            Ok(())
        }
        Cmd::DebugCerts => {
            let mut signer = setup::Signer::open()?;
            for line in signer.diagnose_certificates().await? {
                println!("{line}");
            }
            Ok(())
        }
        Cmd::Teams { use_team } => {
            let mut signer = setup::Signer::open()?;
            if let Some(t) = use_team {
                signer.choose_team(&t)?;
            }
            let teams = signer.teams().await?;
            let chosen = signer.account.team_id.clone();
            out(cli.json, &teams, |teams| {
                for t in teams {
                    println!("{} {}  {}  {}{}", if chosen.as_deref() == Some(&t.team_id) { "*" } else { " " }, t.team_id, t.name, t.kind, if t.is_free { " (free)" } else { "" });
                }
            })
        }
        Cmd::Install { udid, ipa, signing_zip, hand_off, seed_ddi, wait, replace_certificate } => {
            if replace_certificate && poki_setup_core::apple::identity::approve_replacement()? == 0 {
                return Err(anyhow!("No certificate is waiting to be replaced. Run install without --replace-certificate first; it names the certificate if your account is at its limit."));
            }
            let mut signer = setup::Signer::open()?;
            if !signer.signed_in() {
                return Err(anyhow!("Sign in first: poki-setup login you@example.com"));
            }
            let done = setup::run(&mut signer, setup::Options { udid, ipa, signing_zip, wait: Some(Duration::from_secs(wait)), hand_off, seed_ddi }, &reporter).await?;
            for n in &done.notes {
                reporter.note("install", n.clone());
            }
            let line = format!("Poki {} ({}) is installed on {} as {}; signed until {} days from now.", done.record.version, done.record.build, done.record.phone_name, done.record.bundle_id, done.record.days_left());
            if done.handoff.is_none() {
                return finish(cli.json, serde_json::json!({ "installed": &done.record, "notes": &done.notes, "days_left": done.record.days_left() }), line);
            }
            println!("{line}");
            if let Some(server) = done.handoff {
                println!("\nOpen Poki on the iPhone and scan this to give it the pairing file:\n{}\n{}", server.handoff.link, qr_text(&server.handoff.link));
                server.wait_fetched(Duration::from_secs(600)).await;
            }
            Ok(())
        }
        Cmd::Sign { ipa, out: out_path, team, udid, signing_zip } => {
            let mut signer = setup::Signer::open()?;
            if let Some(t) = team {
                signer.choose_team(&t)?;
            }
            let team = signer.team().await?;
            let phone = udid.as_deref().map(|u| (u, "iPhone"));
            let built = setup::sign_for_team(&mut signer, &team, phone, &ipa, signing_zip.as_deref(), &out_path, &reporter).await?;
            for n in &built.notes {
                eprintln!("  · {n}");
            }
            println!("{} → {} ({}) as {}, profile good for {} days", out_path.display(), built.version, built.build, built.bundle_id, (built.profile_expires_at - keeper::now()) / 86_400);
            Ok(())
        }
        Cmd::SelftestSign { ipa, out: out_path, signing_zip, team } => {
            for n in poki_setup_core::sign::selftest(&ipa, signing_zip.as_deref(), &out_path, &team)? {
                eprintln!("  · {n}");
            }
            println!("{}", out_path.display());
            Ok(())
        }
        Cmd::Renew { udid, due, replace_certificate } => {
            if replace_certificate && poki_setup_core::apple::identity::approve_replacement()? == 0 {
                return Err(anyhow!("No certificate is waiting to be replaced. Run renew without --replace-certificate first; it names the certificate if your account is at its limit."));
            }
            let mut signer = setup::Signer::open()?;
            if due {
                for (udid, r) in setup::renew_due(&mut signer, &reporter).await {
                    match r {
                        Ok(rec) => println!("{udid}: renewed, {} days", rec.days_left()),
                        Err(e) => println!("{udid}: {e}"),
                    }
                }
                return Ok(());
            }
            let udid = match udid {
                Some(u) => u,
                None => phone(None).await?.udid,
            };
            let rec = setup::renew(&mut signer, &udid, &reporter).await?;
            finish(cli.json, serde_json::json!({ "renewed": &rec, "days_left": rec.days_left() }), format!("{} renewed: Poki {} ({}) signed for {} more days.", rec.phone_name, rec.version, rec.build, rec.days_left()))
        }
        Cmd::Status => {
            let all = keeper::all()?;
            out(cli.json, &all, |all| {
                if all.is_empty() {
                    println!("No iPhone set up from this computer yet.");
                }
                for r in all {
                    println!("{}  {}  Poki {} ({})  team {}{}  {} days left{}{}", r.udid, r.phone_name, r.version, r.build, r.team_name, if r.team_is_free { " (free)" } else { "" }, r.days_left(), if r.is_due() { "  DUE" } else { "" }, r.last_error.as_ref().map(|e| format!("  last error: {e}")).unwrap_or_default());
                }
            })
        }
        Cmd::Ddi { udid } => {
            let p = phone(udid.as_deref()).await?;
            device::ddi::mount(&p, &reporter).await?;
            finish(cli.json, serde_json::json!({ "udid": p.udid, "mounted": true }), "Developer disk image mounted.")
        }
        Cmd::Logs { udid, filter } => {
            let p = phone(udid.as_deref()).await?;
            let (tx, mut rx) = tokio::sync::mpsc::channel::<String>(256);
            let task = tokio::spawn(async move { device::logs::syslog(&p, filter, tx).await });
            while let Some(line) = rx.recv().await {
                println!("{line}");
            }
            task.await??;
            Ok(())
        }
        Cmd::Support { udid, out: out_dir } => {
            let p = match udid {
                Some(u) => phone(Some(&u)).await.ok(),
                None => phone(None).await.ok(),
            };
            let dir = out_dir.unwrap_or(std::env::current_dir()?);
            let b = support::build(p.as_ref(), &dir).await?;
            finish(cli.json, serde_json::json!({ "bundle": b.path, "files": b.entries.len() }), format!("{} ({} files)", b.path.display(), b.entries.len()))
        }
        Cmd::Relay { cmd } => match cmd {
            RelayCmd::Deploy { account } => {
                let token = match std::env::var("CLOUDFLARE_API_TOKEN") {
                    Ok(t) if !t.is_empty() => t,
                    _ => rpassword::prompt_password("Cloudflare API token (Edit Cloudflare Workers template): ")?,
                };
                let cf = relay::Cloudflare::new(&token)?;
                let accounts = cf.accounts().await?;
                let acct = match account {
                    Some(id) => accounts.into_iter().find(|a| a.id == id || a.name == id).ok_or_else(|| anyhow!("no account {id} for this token"))?,
                    None if accounts.len() == 1 => accounts.into_iter().next().unwrap(),
                    None => {
                        for a in &accounts {
                            println!("{}  {}", a.id, a.name);
                        }
                        return Err(anyhow!("This token sees several accounts; pass --account <id>."));
                    }
                };
                let d = cf.deploy(&acct, &reporter).await?;
                relay::remember(&d)?;
                println!("Your relay: {}\nIn Poki, open Connect → Relay address and enter it, or scan:\n{}", d.address, qr_text(&d.phone_link));
                Ok(())
            }
            RelayCmd::Check { address } => {
                let origin = address.trim_end_matches('/').to_string();
                let up = mcp::relay_up(&origin).await.unwrap_or(false);
                println!("{origin}: {}", if up { "answering" } else { "no relay answers here" });
                if !up { std::process::exit(1) }
                Ok(())
            }
            RelayCmd::Qr { address, svg } => {
                let address = address.or_else(|| relay::remembered().ok().flatten().map(|d| d.address)).ok_or_else(|| anyhow!("no relay address; pass one or deploy first"))?;
                let link = relay::phone_link(&address);
                if let Some(p) = svg {
                    std::fs::write(&p, pairshare::qr_svg(&link)?)?;
                    println!("{}", p.display());
                } else {
                    println!("{link}\n{}", qr_text(&link));
                }
                Ok(())
            }
        },
        Cmd::Mcp { cmd } => match cmd {
            McpCmd::List => {
                let all = mcp::all()?;
                out(cli.json, &all, |all| {
                    for c in all {
                        println!("{}  {}  {}", c.name, mcp::redact(&c.url), c.last_check.as_ref().map(|k| k.detail.clone()).unwrap_or_else(|| "not checked".into()));
                    }
                })
            }
            McpCmd::Add { name, url } => {
                mcp::add(&name, &url)?;
                println!("Kept {name}: {}", mcp::redact(&url));
                Ok(())
            }
            McpCmd::Forget { url } => {
                mcp::forget(&url)?;
                Ok(())
            }
            McpCmd::Check { url } => {
                let k = mcp::check(&url).await?;
                let _ = mcp::record_check(&url, &k);
                out(cli.json, &k, |k| {
                    println!("{}", k.detail);
                    if !k.tools.is_empty() {
                        println!("tools: {}", k.tools.join(", "));
                    }
                })?;
                if !k.ok { std::process::exit(1) }
                Ok(())
            }
            McpCmd::Snippets { url } => {
                mcp::parse(&url).context("not a connector link")?;
                for (title, body) in mcp::snippets(&url) {
                    println!("## {title}\n{body}\n");
                }
                Ok(())
            }
        },
        Cmd::Release { all: false } => {
            let r = release::latest().await?;
            out(cli.json, &r, |r| println!("{}  Poki {} ({})  {}  {}", r.tag, r.version, r.build, r.published_at, r.ipa_url))
        }
        Cmd::Release { all: true } | Cmd::Channel { set: None } => {
            let list = release::channels().await?;
            out(cli.json, &list, |list| {
                for c in list {
                    let latest = c.latest.as_ref().map(|r| format!("Poki {} ({})  {}", r.version, r.build, r.tag)).unwrap_or_else(|| "nothing published".into());
                    println!("{} {:<10} {}", if c.selected { "*" } else { " " }, c.title, latest);
                }
            })
        }
        Cmd::Channel { set: Some(name) } => {
            release::set_channel(name.parse()?)?;
            println!("Channel: {}", release::channel().title());
            Ok(())
        }
    }
}
