//! The whole setup, step by step, and the pieces the shell calls on their own: sign in, pick a
//! team, sign Poki for it, install it, hand the pairing file over, remember the phone.
use crate::apple::anisette::{Provider, Source};
use crate::apple::gsa::{self, AppToken, Outcome as SignInOutcome, Pending};
use crate::apple::portal::{FEATURE_APP_GROUPS, Portal, Team};
use crate::apple::{identity, store};
#[cfg(feature = "device")]
use crate::device::{self, Phone};
#[cfg(feature = "device")]
use crate::{keeper, pairshare, release};
use crate::{Error, Reporter, Result, sign};
use std::path::{Path, PathBuf};
#[cfg(feature = "device")]
use std::time::Duration;

/// The signed-in account with a live GSA client.
pub struct Signer {
    pub account: store::Account,
    client: gsa::Client,
}

impl Signer {
    pub fn open() -> Result<Signer> {
        let account = store::load()?;
        let source = account.anisette.clone().unwrap_or_else(Source::default_for_platform);
        Ok(Signer { account, client: gsa::Client::new(Provider::new(source))? })
    }

    pub fn set_anisette(&mut self, source: Source) -> Result<()> {
        self.account.anisette = Some(source.clone());
        self.client = gsa::Client::new(Provider::new(source))?;
        store::save(&self.account)
    }

    pub fn signed_in(&self) -> bool { self.account.session.is_some() }

    /// Keeps the anisette server that worked (the client may have moved to a fallback).
    fn remember_anisette(&mut self) {
        let used = self.client.anisette().source().clone();
        if self.account.anisette.as_ref() != Some(&used) {
            self.account.anisette = Some(used);
        }
    }

    /// Starts a sign-in. `keep_password` lets the keeper re-sign without asking again.
    pub async fn sign_in(&mut self, apple_id: &str, password: &str, keep_password: bool) -> Result<Option<Pending>> {
        match self.client.sign_in(apple_id.trim(), password).await? {
            SignInOutcome::SignedIn(session) => {
                self.remember_anisette();
                self.account.session = Some(session);
                self.account.password = keep_password.then(|| password.to_string());
                self.account.xcode_token = None;
                store::save(&self.account)?;
                Ok(None)
            }
            SignInOutcome::NeedsCode(p) => {
                // The code is checked with the anisette identity that asked for it. Keep the server
                // that answered (the client may have moved to a fallback), so a second run
                // (`poki-setup login --code`) checks the code as the same "Mac".
                let saved_password = self.account.password.clone();
                self.remember_anisette();
                store::save(&store::Account { password: saved_password, ..self.account.clone() })?;
                self.account.password = keep_password.then(|| password.to_string());
                Ok(Some(p))
            }
        }
    }

    pub async fn finish_sign_in(&mut self, pending: Pending, code: &str) -> Result<()> {
        let session = self.client.finish(pending, code).await?;
        self.remember_anisette();
        self.account.session = Some(session);
        self.account.xcode_token = None;
        store::save(&self.account)?;
        Ok(())
    }

    pub fn sign_out(&mut self) -> Result<()> {
        self.account = store::Account { anisette: self.account.anisette.clone(), ..Default::default() };
        store::clear()?;
        store::save(&self.account)
    }

    /// A token good for at least ten minutes, refreshed from the session or, when the
    /// session is gone and the password is kept, from a fresh sign-in.
    pub async fn token(&mut self) -> Result<AppToken> {
        if let Some(t) = &self.account.xcode_token {
            if t.valid_for(600) {
                return Ok(t.clone());
            }
        }
        let session = self.account.session.clone().ok_or_else(|| Error::NeedsPerson("Sign in with your Apple ID first.".into()))?;
        let fresh = match self.client.xcode_token(&session).await {
            Ok(t) => t,
            Err(Error::NeedsPerson(_)) | Err(Error::Apple { .. }) if self.account.password.is_some() => {
                let (id, pw) = (session.apple_id.clone(), self.account.password.clone().unwrap());
                match self.client.sign_in(&id, &pw).await? {
                    SignInOutcome::SignedIn(s) => {
                        let t = self.client.xcode_token(&s).await?;
                        self.account.session = Some(s);
                        t
                    }
                    SignInOutcome::NeedsCode(pending) => {
                        self.remember_anisette();
                        let _ = store::save(&self.account);
                        return Err(Error::NeedsCode(Box::new(pending)));
                    }
                }
            }
            Err(e) => return Err(e),
        };
        self.account.xcode_token = Some(fresh.clone());
        store::save(&self.account)?;
        Ok(fresh)
    }

    pub async fn teams(&mut self) -> Result<Vec<Team>> {
        let token = self.token().await?;
        let session = self.account.session.clone().unwrap();
        let mut portal = Portal::new(&session, &token, self.client.anisette())?;
        portal.teams().await
    }

    /// The team to use: the chosen one, or the only one, or the first free one.
    pub async fn team(&mut self) -> Result<Team> {
        let teams = self.teams().await?;
        if let Some(id) = &self.account.team_id {
            if let Some(t) = teams.iter().find(|t| &t.team_id == id) {
                return Ok(t.clone());
            }
        }
        let pick = if teams.len() == 1 { teams[0].clone() } else { teams.iter().find(|t| !t.is_free).or(teams.first()).cloned().unwrap() };
        self.account.team_id = Some(pick.team_id.clone());
        store::save(&self.account)?;
        Ok(pick)
    }

    #[cfg(feature = "device")]
    pub(crate) async fn check_update_identity(&mut self, team: &str, certificate: &str) -> Result<()> {
        let token = self.token().await?;
        let session = self.account.session.clone().ok_or_else(|| Error::UpdateCheck("Sign in on the original signing computer, then retry update-only."))?;
        let mut portal = Portal::new(&session, &token, self.client.anisette())?;
        identity::update_certificate(&mut portal, team, certificate).await?;
        Ok(())
    }

    #[cfg(feature = "device")]
    pub(crate) async fn sign_update(&mut self, team: &Team, unpacked: sign::Unpacked, certificate: &str, out: &Path, reporter: &Reporter) -> Result<SignedBuild> {
        let token = self.token().await?;
        let session = self.account.session.clone().ok_or_else(|| Error::msg("Sign in on the original signing computer, then retry update-only."))?;
        let mut portal = Portal::new(&session, &token, self.client.anisette())?;
        let ident = identity::existing_for_update(&mut portal, &team.team_id, certificate).await?;
        sign_prepared(&mut portal, team, unpacked, ident, out, reporter, true).await
    }

    /// For support: the chosen team's development certificates as Apple lists them.
    pub async fn diagnose_certificates(&mut self) -> Result<Vec<String>> {
        let team = self.team().await?;
        let token = self.token().await?;
        let session = self.account.session.clone().unwrap();
        let mut portal = Portal::new(&session, &token, self.client.anisette())?;
        identity::diagnose(&mut portal, &team.team_id).await
    }

    pub fn choose_team(&mut self, team_id: &str) -> Result<()> {
        self.account.team_id = Some(team_id.to_string());
        store::save(&self.account)
    }
}

pub struct SignedBuild {
    pub ipa: PathBuf,
    pub bundle_id: String,
    pub app_group: String,
    pub version: String,
    pub build: String,
    pub profile_expires_at: i64,
    pub profiles: Vec<Vec<u8>>,
    pub notes: Vec<String>,
    /// The key and certificate Poki was signed with, handed to Poki so it can re-sign itself.
    pub identity: identity::Identity,
}

/// Where Poki looks for the signing identity Poki Setup hands over (inside its container).
pub const SIGNING_IDENTITY_PATH: &str = "Documents/PokiSetup/signing-identity.json";

/// `poki.signing-identity/1`: what Poki needs to renew its own signature on the phone.
pub fn signing_identity_json(ident: &identity::Identity, apple_id: &str) -> Result<Vec<u8>> {
    use base64::Engine;
    use rsa::pkcs8::{DecodePrivateKey, EncodePrivateKey};
    let key = rsa::RsaPrivateKey::from_pkcs8_der(&ident.key_pkcs8).map_err(|e| Error::msg(e.to_string()))?;
    let pem = key.to_pkcs8_pem(rsa::pkcs8::LineEnding::LF).map_err(|e| Error::msg(e.to_string()))?;
    Ok(serde_json::to_vec_pretty(&serde_json::json!({
        "schema": "poki.signing-identity/1",
        "team_id": ident.team_id,
        "key_pkcs8_pem": pem.as_str(),
        "certificate_serial": ident.certificate.serial_number,
        "certificate_id": ident.certificate.certificate_id,
        "certificate_der_b64": base64::engine::general_purpose::STANDARD.encode(&ident.certificate.der),
        "apple_id": apple_id,
    }))?)
}

/// Writes the signing identity into Poki's container. Failing is not fatal: Poki then needs the
/// computer for renewals, as before.
#[cfg(feature = "device")]
async fn hand_signing_identity(phone: &device::Phone, built: &SignedBuild, apple_id: &str, reporter: &Reporter) {
    let res = async {
        let bytes = signing_identity_json(&built.identity, apple_id)?;
        device::container::write_file(phone, &built.bundle_id, SIGNING_IDENTITY_PATH, &bytes).await
    }
    .await;
    match res {
        Ok(()) => reporter.note("pairing_file", "Gave Poki its signing identity, so it can renew itself"),
        Err(e) => reporter.note("pairing_file", format!("Could not give Poki its signing identity ({e}); renewals stay on this computer.")),
    }
}

/// Signs an IPA for a team: device, identity, App IDs, group, profiles, signature.
pub async fn sign_for_team(signer: &mut Signer, team: &Team, phone: Option<(&str, &str)>, ipa: &Path, signing_zip: Option<&Path>, out: &Path, reporter: &Reporter) -> Result<SignedBuild> {
    reporter.step("sign", &format!("Signing Poki for {}", team.name));
    let token = signer.token().await?;
    let session = signer.account.session.clone().unwrap();
    let mut portal = Portal::new(&session, &token, signer.client.anisette())?;
    if let Some((udid, name)) = phone {
        reporter.part("sign", 0.02, Some("Registering the iPhone with the team".into()));
        portal.ensure_device(&team.team_id, udid, name).await?;
    }
    let ident = identity::ensure(&mut portal, &team.team_id, reporter).await?;
    let requested = match signing_zip {
        Some(z) => sign::requested_from_signing_zip(z, "external").unwrap_or_default(),
        None => Default::default(),
    };
    let unpacked = sign::unpack(ipa, &team.team_id, &requested, reporter)?;
    sign_prepared(&mut portal, team, unpacked, ident, out, reporter, false).await
}

async fn sign_prepared(portal: &mut Portal<'_>, team: &Team, unpacked: sign::Unpacked, ident: identity::Identity, out: &Path, reporter: &Reporter, preserve_group: bool) -> Result<SignedBuild> {
    let group = portal.ensure_app_group(&team.team_id, &unpacked.app_group, "Poki").await?;
    let mut profiles = vec![];
    let mut raw_profiles = vec![];
    let mut expires = i64::MAX;
    for (i, b) in unpacked.bundles.iter().enumerate() {
        reporter.part("sign", 0.1 + 0.3 * (i as f64 / unpacked.bundles.len() as f64), Some(format!("App ID and profile for {}", b.name)));
        let name = if b.rel.is_empty() { "Poki".to_string() } else { format!("Poki {}", b.name.trim_start_matches("Poki")) };
        let app_id = portal.ensure_app_id(&team.team_id, &b.new_id, &name).await?;
        portal.enable_feature(&team.team_id, &app_id, FEATURE_APP_GROUPS).await?;
        portal.assign_app_group(&team.team_id, &app_id, &group).await?;
        let p = portal.profile(&team.team_id, &app_id).await?;
        let parsed = sign::profile::parse(&p.data)?;
        if preserve_group {
            let merged = sign::entitlements::merge(&b.requested, &parsed.entitlements);
            let groups = merged.get("com.apple.security.application-groups").and_then(|v| v.as_array());
            if !groups.is_some_and(|groups| groups.iter().any(|v| v.as_string() == Some(unpacked.app_group.as_str()))) {
                return Err(Error::UpdateCheck("The signing profile cannot preserve the installed app group; keep Poki installed and use the original signing setup."));
            }
        }
        expires = expires.min(parsed.expires_at);
        raw_profiles.push(p.data.clone());
        profiles.push((b.new_id.clone(), parsed));
    }
    let notes = sign::sign(&unpacked, &ident, &profiles, reporter)?;
    reporter.part("sign", 0.9, Some("Packing".into()));
    sign::pack(&unpacked, out)?;
    reporter.done("sign", Some(format!("Poki {} ({}) signed for {}", unpacked.version, unpacked.build, team.name)));
    let mut all_notes = notes;
    for d in &unpacked.dropped_extensions {
        all_notes.push(format!("{d} left out: a team profile cannot carry the packet-tunnel entitlement, so Poki uses your proxy app's loopback instead."));
    }
    Ok(SignedBuild { ipa: out.to_path_buf(), bundle_id: unpacked.bundles[0].new_id.clone(), app_group: unpacked.app_group.clone(), version: unpacked.version.clone(), build: unpacked.build.clone(), profile_expires_at: expires, profiles: raw_profiles, notes: all_notes, identity: ident })
}

#[cfg(feature = "device")]
#[derive(Debug, Clone, Default)]
pub struct Options {
    pub udid: Option<String>,
    pub ipa: Option<PathBuf>,
    pub signing_zip: Option<PathBuf>,
    /// How long to wait for Trust This Computer / the Developer Mode restart.
    pub wait: Option<Duration>,
    /// Also serve the pairing file on the LAN for the phone's QR (for later, Wi-Fi-only use).
    pub hand_off: bool,
    /// Pre-seed the developer disk image into Poki's container.
    pub seed_ddi: bool,
}

#[cfg(feature = "device")]
pub struct Done {
    pub record: keeper::Record,
    pub handoff: Option<pairshare::Server>,
    pub notes: Vec<String>,
}

#[cfg(feature = "device")]
/// Picks the phone: the one asked for, else the one USB phone.
pub async fn pick_phone(udid: Option<&str>) -> Result<Phone> {
    let phones = Phone::list().await?;
    if let Some(u) = udid {
        if let Some(p) = phones.into_iter().find(|p| p.udid == u) {
            return Ok(p);
        }
        if let Some(rec) = keeper::get(u)? {
            if let Some(addr) = rec.wifi_address.and_then(|a| a.parse().ok()) {
                return Ok(Phone::over_wifi(u, addr));
            }
        }
        return Err(Error::device("That iPhone is not connected. Plug it in with a cable."));
    }
    let usb: Vec<_> = phones.iter().filter(|p| p.is_usb()).cloned().collect();
    match usb.len() {
        0 if phones.is_empty() => Err(Error::device("No iPhone found. Plug it in with a cable and unlock it.")),
        0 => Ok(phones[0].clone()),
        1 => Ok(usb[0].clone()),
        _ => Err(Error::device("More than one iPhone is plugged in. Choose one.")),
    }
}

#[cfg(feature = "device")]
/// The one-click setup.
pub async fn run(signer: &mut Signer, opts: Options, reporter: &Reporter) -> Result<Done> {
    let wait = opts.wait.unwrap_or(Duration::from_secs(120));
    reporter.step("phone", "Finding the iPhone");
    let phone = pick_phone(opts.udid.as_deref()).await?;
    reporter.done("phone", Some(phone.udid.clone()));

    reporter.step("pair", "Pairing with the iPhone");
    let lockdown_record = device::pairing::pair(&phone, reporter, wait).await?;
    if let Err(e) = device::pairing::enable_network(&phone).await {
        reporter.note("pair", format!("Could not let the iPhone use this pairing over the network ({e}); Poki may need to pair on the phone."));
    }
    let facts = device::info::read(&phone).await?;
    // iOS 26.4 and later only accept an RPPairing record over the loopback Poki uses.
    let needs_remote = device::pairing::needs_remote_record(&facts.ios);
    let record = match device::pairing::pair_remote(&phone, reporter, wait).await {
        Ok(r) => Some(r),
        Err(e) if needs_remote => {
            reporter.note("pair", format!("Remote pairing did not finish ({e}). Poki can pair on the iPhone instead."));
            None
        }
        Err(e) => {
            tracing::info!("remote pairing not made, using the lockdown record: {e}");
            Some(lockdown_record)
        }
    };
    reporter.done("pair", Some(format!("{} · iOS {}", facts.name, facts.ios)));

    reporter.step("devmode", "Developer Mode");
    if facts.developer_mode != Some(true) {
        let already = device::devmode::enable(&phone, reporter).await?;
        if !already {
            device::devmode::wait_until_on(&phone.udid, reporter, wait).await?;
        }
    }
    reporter.done("devmode", Some("on".into()));

    reporter.step("account", "Apple account");
    let team = signer.team().await?;
    reporter.done("account", Some(format!("{} ({})", team.name, if team.is_free { "free, 7-day signing" } else { "paid" })));

    reporter.step("release", "Getting Poki");
    let (ipa, signing_zip, tag) = match &opts.ipa {
        Some(p) => {
            let beside = p.with_file_name("Poki-signing.zip");
            let zipp = opts.signing_zip.clone().or_else(|| beside.is_file().then_some(beside));
            (p.clone(), zipp, format!("local:{}", p.file_name().unwrap_or_default().to_string_lossy()))
        }
        None => {
            let rel = release::latest().await?;
            let (ipa, zipp) = release::fetch(&rel, reporter).await?;
            (ipa, zipp, rel.tag)
        }
    };
    reporter.done("release", Some(tag.clone()));

    let out = crate::paths::cache_dir()?.join(format!("Poki-{}-{}.ipa", team.team_id, phone.udid));
    let built = sign_for_team(signer, &team, Some((&phone.udid, &facts.name)), &ipa, signing_zip.as_deref(), &out, reporter).await?;

    reporter.step("install", "Installing");
    device::install::install_profiles(&phone, &built.profiles, reporter).await?;
    let existing = device::install::find_apps(&phone, crate::POKI_BUNDLE_ID).await.unwrap_or_default();
    let upgrade = existing.iter().any(|a| a.bundle_id == built.bundle_id);
    device::install::install_ipa(&phone, &built.ipa, upgrade, reporter).await?;

    reporter.step("pairing_file", "Giving Poki its pairing file");
    let mut handed = false;
    match &record {
        None => reporter.done("pairing_file", Some("Poki pairs on the iPhone itself".into())),
        Some(record) => {
            // Right after an install the phone sometimes drops the first container connection; try again.
            let mut placed = device::container::place_pairing_file(&phone, &built.bundle_id, record).await;
            for _ in 0..2 {
                if placed.is_ok() { break; }
                tokio::time::sleep(Duration::from_secs(2)).await;
                placed = device::container::place_pairing_file(&phone, &built.bundle_id, record).await;
            }
            match placed {
                Ok(true) => {
                    handed = true;
                    reporter.done("pairing_file", Some("placed in Poki's container".into()));
                }
                Ok(false) => {
                    handed = true;
                    reporter.done("pairing_file", Some("Poki already has its own pairing; kept it".into()));
                }
                Err(e) => reporter.note("pairing_file", format!("Could not write into Poki's container ({e}); the QR hand-off below does it instead.")),
            }
        }
    }
    let apple_id = signer.account.apple_id().unwrap_or("").to_string();
    hand_signing_identity(&phone, &built, &apple_id, reporter).await;
    if opts.seed_ddi {
        if let Err(e) = device::ddi::seed_container(&phone, &built.bundle_id, reporter).await {
            reporter.note("pairing_file", format!("Developer disk image not pre-seeded ({e}); Poki downloads it itself."));
        }
    }
    let handoff = if let (true, Some(record)) = (opts.hand_off || !handed, &record) {
        let server = pairshare::serve(record.clone()).await?;
        reporter.waiting("pairing_file", format!("Scan the code with the iPhone's Camera, or open {} on the iPhone", server.handoff.link));
        Some(server)
    } else {
        None
    };

    let rec = keeper::Record {
        udid: phone.udid.clone(),
        phone_name: facts.name.clone(),
        ios: facts.ios.clone(),
        apple_id: signer.account.apple_id().unwrap_or("").to_string(),
        team_id: team.team_id.clone(),
        team_name: team.name.clone(),
        team_is_free: team.is_free,
        bundle_id: built.bundle_id.clone(),
        app_group: built.app_group.clone(),
        version: built.version.clone(),
        build: built.build.clone(),
        release_tag: tag,
        signed_at: keeper::now(),
        profile_expires_at: built.profile_expires_at,
        last_checked_at: Some(keeper::now()),
        last_error: None,
        wifi_address: facts.wifi_address.clone(),
        pairing_handed_off: handed,
    };
    keeper::put(rec.clone())?;
    reporter.done("all", Some(format!("Poki {} is on {}", built.version, facts.name)));
    Ok(Done { record: rec, handoff, notes: built.notes })
}

#[cfg(feature = "device")]
/// Signs Poki again for a phone this computer set up and reinstalls it (an upgrade keeps data).
pub async fn renew(signer: &mut Signer, udid: &str, reporter: &Reporter) -> Result<keeper::Record> {
    let rec = keeper::get(udid)?.ok_or_else(|| Error::msg("This computer did not set up that iPhone."))?;
    let result: Result<keeper::Record> = async {
        let phone = pick_phone(Some(udid)).await?;
        if !device::pairing::verify(&phone).await? {
            return Err(Error::device("The iPhone no longer trusts this computer. Plug it in and tap Trust."));
        }
        let facts = device::info::read(&phone).await?;
        let teams = signer.teams().await?;
        let team = teams.into_iter().find(|t| t.team_id == rec.team_id).ok_or_else(|| Error::msg(format!("The Apple ID signed in is not on team {} any more.", rec.team_name)))?;
        let rel = release::latest().await?;
        let (ipa, zipp) = release::fetch(&rel, reporter).await?;
        let out = crate::paths::cache_dir()?.join(format!("Poki-{}-{}.ipa", team.team_id, udid));
        let built = sign_for_team(signer, &team, Some((udid, &facts.name)), &ipa, zipp.as_deref(), &out, reporter).await?;
        device::install::install_profiles(&phone, &built.profiles, reporter).await?;
        device::install::install_ipa(&phone, &built.ipa, true, reporter).await?;
        let apple_id = signer.account.apple_id().unwrap_or("").to_string();
        hand_signing_identity(&phone, &built, &apple_id, reporter).await;
        Ok(keeper::Record { version: built.version, build: built.build, release_tag: rel.tag, signed_at: keeper::now(), profile_expires_at: built.profile_expires_at, last_checked_at: Some(keeper::now()), last_error: None, wifi_address: facts.wifi_address.clone().or(rec.wifi_address.clone()), ..rec.clone() })
    }
    .await;
    match result {
        Ok(r) => {
            keeper::put(r.clone())?;
            Ok(r)
        }
        Err(e) => {
            keeper::note_check(udid, Some(e.to_string()))?;
            Err(e)
        }
    }
}

#[cfg(feature = "device")]
/// Renews every phone that is due. Returns (udid, result) pairs.
pub async fn renew_due(signer: &mut Signer, reporter: &Reporter) -> Vec<(String, Result<keeper::Record>)> {
    let mut out = vec![];
    for r in keeper::due().unwrap_or_default() {
        let res = renew(signer, &r.udid, reporter).await;
        out.push((r.udid.clone(), res));
    }
    out
}
