//! Beta releases from a signed R2 catalog, with GitHub as the network-failure fallback.
//! Poki Setup installs the external edition because a team profile cannot sign its built-in tunnel.
use crate::{Error, Result, Reporter, paths};
pub use crate::release_catalog::Pin;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::PathBuf;

pub const DEFAULT_REPO: &str = "JosssphZhou/poki";

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReleaseSource {
    R2,
    #[default]
    Github,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Release {
    pub tag: String,
    pub version: String,
    pub build: String,
    pub published_at: String,
    pub prerelease: bool,
    #[serde(default)]
    pub channel: Channel,
    pub ipa_url: String,
    pub ipa_name: String,
    pub signing_url: Option<String>,
    pub sums_url: Option<String>,
    pub notes: String,
    #[serde(default)]
    pub source: ReleaseSource,
    #[serde(default)]
    pub source_notice: Option<String>,
    #[serde(default)]
    pub ipa_pin: Option<Pin>,
    #[serde(default)]
    pub signing_pin: Option<Pin>,
}

#[derive(Deserialize, Clone)]
struct GhRelease {
    tag_name: String,
    prerelease: bool,
    draft: bool,
    published_at: Option<String>,
    body: Option<String>,
    #[serde(default)]
    html_url: Option<String>,
    assets: Vec<GhAsset>,
    #[serde(skip)]
    source: ReleaseSource,
    #[serde(skip)]
    source_notice: Option<String>,
}
#[derive(Deserialize, Clone)]
struct GhAsset {
    name: String,
    browser_download_url: String,
    #[serde(flatten)]
    pin: Option<Pin>,
}

pub fn repo() -> String { std::env::var("POKI_RELEASE_REPO").unwrap_or_else(|_| DEFAULT_REPO.into()) }

/// Historical release stages retained for tags and serialized state. Clients select Beta.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Channel {
    /// Full releases recognized by older clients.
    Stable,
    /// The same tags published as prereleases.
    Beta,
    /// `ios-alpha-X.Y.Z-N` / `desktop-alpha-*` early test builds, picked by hand.
    Alpha,
    /// `ios-prealpha-X.Y.Z-N` / `desktop-prealpha-*` snapshots.
    PreAlpha,
}

impl Default for Channel {
    fn default() -> Self { Channel::Stable }
}

impl Channel {
    pub const ALL: [Channel; 4] = [Channel::Stable, Channel::Beta, Channel::Alpha, Channel::PreAlpha];

    pub fn id(self) -> &'static str {
        match self {
            Channel::Stable => "stable",
            Channel::Beta => "beta",
            Channel::Alpha => "alpha",
            Channel::PreAlpha => "pre-alpha",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Channel::Stable => "Stable",
            Channel::Beta => "Beta",
            Channel::Alpha => "Alpha",
            Channel::PreAlpha => "Pre-alpha",
        }
    }

    pub fn parse(s: &str) -> Option<Channel> {
        match s.trim().to_ascii_lowercase().replace(['_', ' '], "-").as_str() {
            "stable" => Some(Channel::Stable),
            "beta" => Some(Channel::Beta),
            "alpha" => Some(Channel::Alpha),
            "pre-alpha" | "prealpha" => Some(Channel::PreAlpha),
            _ => None,
        }
    }

    /// This channel, then each less stable one in turn: where to look when this one has nothing yet.
    pub fn fallbacks(self) -> impl Iterator<Item = Channel> { Channel::ALL.into_iter().filter(move |c| *c >= self) }

    /// Whether a release of channel `of` is offered to someone on this channel.
    pub fn includes(self, of: Channel) -> bool { of <= self }

    /// The channel a release belongs to, for a product prefix (`ios` or `desktop`), or None when the
    /// tag is not one of that product's.
    pub fn of_tag(product: &str, tag: &str, prerelease: bool) -> Option<Channel> {
        let rest = tag.strip_prefix(product)?.strip_prefix('-')?;
        if rest.starts_with("prealpha-") {
            Some(Channel::PreAlpha)
        } else if rest.starts_with("alpha-") {
            Some(Channel::Alpha)
        } else if rest.starts_with("beta-") {
            Some(Channel::Beta)
        } else if rest.starts_with('v') {
            Some(if prerelease { Channel::Beta } else { Channel::Stable })
        } else {
            None
        }
    }
}

impl Channel {
    /// The channel of an `app-*` release (Poki's tags from Nov 2026 on): `app-0.2.9-prealpha.640`
    /// and `app-prealpha-latest`, `app-0.2.9-alpha.640` and `app-alpha-latest`, `app-0.3.0-beta.1`,
    /// and `app-0.3.0` (Stable, or Beta while it is marked prerelease). None for any other tag.
    pub fn of_app_tag(tag: &str, prerelease: bool) -> Option<Channel> {
        let rest = tag.strip_prefix("app-")?;
        match rest {
            "prealpha-latest" => return Some(Channel::PreAlpha),
            "alpha-latest" => return Some(Channel::Alpha),
            _ => {}
        }
        if !rest.starts_with(|c: char| c.is_ascii_digit()) {
            return None;
        }
        Some(match rest.split_once('-').map(|(_, s)| s) {
            None => if prerelease { Channel::Beta } else { Channel::Stable },
            Some(s) if s.starts_with("prealpha.") => Channel::PreAlpha,
            Some(s) if s.starts_with("alpha.") => Channel::Alpha,
            // beta.N, and rc.N or any other pre-release suffix.
            Some(_) => Channel::Beta,
        })
    }

    /// The channel of a release of Poki itself, under either scheme (`ios-*` or `app-*`).
    pub fn of_app_release(tag: &str, prerelease: bool) -> Option<Channel> {
        Channel::of_tag("ios", tag, prerelease).or_else(|| Channel::of_app_tag(tag, prerelease))
    }
}

impl std::str::FromStr for Channel {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self> { Channel::parse(s).ok_or_else(|| Error::msg(format!("Unknown channel “{s}”. Use beta."))) }
}

#[derive(Serialize, Deserialize, Default)]
struct ChannelFile {
    channel: Channel,
}

fn channel_file() -> Result<PathBuf> { Ok(paths::state_dir()?.join("channel.json")) }

/// Historical channel preferences converge to Beta without changing signing or account data.
pub fn channel() -> Channel { Channel::Beta }

pub fn set_channel(_channel: Channel) -> Result<()> {
    let p = channel_file()?;
    let tmp = p.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(&ChannelFile { channel: Channel::Beta })?)?;
    std::fs::rename(tmp, p)?;
    Ok(())
}

fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder().user_agent(format!("PokiSetup/{}", crate::VERSION)).timeout(std::time::Duration::from_secs(600)).build()?)
}

async fn github_list() -> Result<Vec<GhRelease>> {
    let mut list: Vec<GhRelease> = client()?
        .get(format!("https://api.github.com/repos/{}/releases?per_page=100", repo()))
        .header("Accept", "application/vnd.github+json")
        .timeout(std::time::Duration::from_secs(30))
        .send()
        .await?
        .error_for_status()
        .map_err(|e| Error::msg(format!("Could not read Poki's releases from GitHub ({e}). Check the connection and try again.")))?
        .json()
        .await?;
    list.retain(|r| !r.draft);
    // Newest first by publication, whatever order GitHub lists them in.
    list.sort_by(|a, b| b.published_at.cmp(&a.published_at));
    Ok(list)
}

async fn list() -> Result<Vec<GhRelease>> {
    let (mut list, source, notice) = match crate::release_catalog::read().await {
        Ok(releases) => (releases.into_iter().map(serde_json::from_value).collect::<std::result::Result<Vec<GhRelease>, _>>()?, ReleaseSource::R2, None),
        Err(Error::ReleaseUnavailable(notice)) => (github_list().await?, ReleaseSource::Github, Some(notice.to_string())),
        Err(error) => return Err(error),
    };
    list.retain(|r| !r.draft && release_channel(r) == Some(Channel::Beta));
    if list.is_empty() {
        return Err(Error::msg(format!("{}No Beta releases are available. Try again later.", notice.as_deref().map(|n| format!("{n} ")).unwrap_or_default())));
    }
    for release in &mut list {
        release.source = source;
        release.source_notice = notice.clone();
    }
    list.sort_by(|a, b| b.published_at.cmp(&a.published_at));
    Ok(list)
}

/// An installable Poki release (one with the external IPA) from GitHub's answer.
fn installable(r: &GhRelease) -> Option<(Channel, Release)> {
    let channel = Channel::of_app_release(&r.tag_name, r.prerelease)?;
    let ipa = r.assets.iter().find(|a| a.name.starts_with("Poki-external-") && a.name.ends_with(".ipa"))?;
    // Poki-external-<version>-<build>.ipa; the tag names the version too for ios-v* releases.
    let stem = ipa.name.trim_start_matches("Poki-external-").trim_end_matches(".ipa");
    let (version, build) = match stem.rsplit_once('-') {
        Some((v, b)) if !v.is_empty() => (v.to_string(), b.to_string()),
        _ => (r.tag_name.trim_start_matches("app-").trim_start_matches("ios-v").trim_start_matches("ios-prealpha-").trim_start_matches("ios-alpha-").trim_start_matches("ios-beta-").to_string(), String::new()),
    };
    Some((
        channel,
        Release {
            tag: r.tag_name.clone(),
            version,
            build,
            published_at: r.published_at.clone().unwrap_or_default(),
            prerelease: r.prerelease,
            channel,
            ipa_url: ipa.browser_download_url.clone(),
            ipa_name: ipa.name.clone(),
            signing_url: r.assets.iter().find(|a| a.name == "Poki-signing.zip").map(|a| a.browser_download_url.clone()),
            sums_url: r.assets.iter().find(|a| a.name == "SHA256SUMS").map(|a| a.browser_download_url.clone()),
            notes: r.body.clone().unwrap_or_default(),
            source: r.source,
            source_notice: r.source_notice.clone(),
            ipa_pin: ipa.pin.clone(),
            signing_pin: r.assets.iter().find(|a| a.name == "Poki-signing.zip").and_then(|a| a.pin.clone()),
        },
    ))
}

/// The highest version and build the channel offers, whatever order GitHub lists releases in
/// (rolling ios-*-latest releases keep their first creation date while their files change).
/// On a tie the channel's own release wins, then the later published one.
fn pick_exact(list: &[GhRelease], channel: Channel) -> Option<Release> {
    list.iter()
        .filter_map(installable)
        .filter(|(c, _)| channel.includes(*c))
        .max_by(|(ca, a), (cb, b)| {
            let key = |c: &Channel, r: &Release| (version_key(&full(&r.version, &r.build)), *c == channel, r.published_at.clone());
            key(ca, a).cmp(&key(cb, b))
        })
        .map(|(_, r)| r)
}

/// The newest release the channel offers; when it has none yet, the next less stable channel's,
/// one step at a time (Stable, then Beta, then Alpha, then Pre-alpha).
fn pick(list: &[GhRelease], channel: Channel) -> Option<Release> {
    channel.fallbacks().find_map(|c| pick_exact(list, c))
}

pub async fn latest() -> Result<Release> { latest_in(Channel::Beta).await }

pub async fn latest_in(_channel: Channel) -> Result<Release> {
    pick(&list().await?, Channel::Beta).ok_or_else(|| Error::msg("No Beta release with an installable IPA is available. Try again later."))
}

/// Update information in the legacy channel-list response format.
#[derive(Debug, Clone, Serialize)]
pub struct ChannelInfo {
    pub id: Channel,
    pub title: &'static str,
    pub selected: bool,
    pub latest: Option<Release>,
}

/// The single Beta row, retaining the bridge response format.
pub async fn channels() -> Result<Vec<ChannelInfo>> {
    let list = list().await?;
    Ok(vec![ChannelInfo { id: Channel::Beta, title: "Beta", selected: true, latest: pick(&list, Channel::Beta) }])
}

/// Poki Setup's own update on the chosen channel. Any release on the channel can carry it (an
/// `ios-*` release with the desktop apps attached, or a `desktop-*` one): the asset for this
/// platform, `PokiSetup-<version>-<build>-macos.dmg` or `PokiSetup-<version>-<build>-windows-x64-setup.exe`.
#[derive(Debug, Clone, Serialize)]
pub struct UpdateInfo {
    pub current: String,
    pub latest: Option<String>,
    /// The release page.
    pub url: Option<String>,
    /// The installer for this computer.
    pub asset_url: Option<String>,
    pub asset_name: Option<String>,
    pub newer: bool,
    pub channel: Channel,
    /// The release's SHA256SUMS-desktop.txt, to check the download against.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sums_url: Option<String>,
    pub source: ReleaseSource,
    pub source_notice: Option<String>,
    pub tag: Option<String>,
    pub asset_pin: Option<Pin>,
}

/// The installer name suffix for this platform.
fn platform_suffix() -> &'static str {
    if cfg!(target_os = "macos") { "-macos.dmg" } else { "-windows-x64-setup.exe" }
}

/// The version in a Poki Setup installer's name, for this platform.
fn desktop_asset_version(name: &str, suffix: &str) -> Option<String> {
    let v = name.strip_prefix("PokiSetup-")?.strip_suffix(suffix)?;
    (!v.is_empty() && v.chars().next()?.is_ascii_digit()).then(|| v.to_string())
}

fn release_channel(r: &GhRelease) -> Option<Channel> {
    Channel::of_tag("desktop", &r.tag_name, r.prerelease).or_else(|| Channel::of_app_release(&r.tag_name, r.prerelease))
}

/// The newest Poki Setup installer a channel offers (stepping down like Poki's own releases).
fn pick_desktop<'a>(list: &'a [GhRelease], channel: Channel, suffix: &str) -> Option<(&'a GhRelease, &'a GhAsset, String)> {
    channel.fallbacks().find_map(|want| {
        list.iter()
            .filter(|r| release_channel(r).map(|c| want.includes(c)).unwrap_or(false))
            .flat_map(|r| r.assets.iter().filter_map(move |a| desktop_asset_version(&a.name, suffix).map(|v| (r, a, v))))
            .max_by(|a, b| version_key(&a.2).cmp(&version_key(&b.2)))
    })
}

pub async fn desktop_update() -> Result<UpdateInfo> {
    let channel = channel();
    let current = crate::full_version();
    let list = list().await?;
    let found = pick_desktop(&list, channel, platform_suffix());
    let newer = found.as_ref().map(|(_, _, v)| version_key(v) > version_key(&current)).unwrap_or(false);
    Ok(match found {
        Some((r, a, v)) => {
            let sums_url = r.assets.iter().find(|a| a.name == "SHA256SUMS-desktop.txt").map(|a| a.browser_download_url.clone());
            UpdateInfo { current, latest: Some(v), url: r.html_url.clone(), asset_url: Some(a.browser_download_url.clone()), asset_name: Some(a.name.clone()), newer, channel, sums_url, source: r.source, source_notice: r.source_notice.clone(), tag: Some(r.tag_name.clone()), asset_pin: a.pin.clone() }
        }
        None => UpdateInfo { current, latest: None, url: None, asset_url: None, asset_name: None, newer, channel, sums_url: None, source: list[0].source, source_notice: list[0].source_notice.clone(), tag: None, asset_pin: None },
    })
}

/// What installing an update did.
#[derive(Debug, Clone, Serialize)]
pub struct Installed {
    /// The downloaded installer.
    pub path: PathBuf,
    /// The new Poki Setup is in place (or its installer is running) and starts by itself once
    /// this one quits: the app should quit now.
    pub relaunching: bool,
}

/// Downloads and verifies the selected installer without running it.
pub async fn fetch_desktop_update(info: UpdateInfo, reporter: &Reporter) -> Result<PathBuf> {
    if let Some(notice) = &info.source_notice { reporter.note("update", notice); }
    let (Some(url), Some(name), true) = (info.asset_url, info.asset_name, info.newer) else {
        return Err(Error::msg("Poki Setup is up to date."));
    };
    let dir = paths::cache_dir()?.join("updates");
    std::fs::create_dir_all(&dir)?;
    let to = dir.join(&name);
    if info.source == ReleaseSource::R2 {
        let pin = info.asset_pin.as_ref().ok_or_else(|| Error::msg("Installer integrity metadata is missing"))?;
        if !pin.matches(&to) {
            download_pinned(&url, pin, info.tag.as_deref().ok_or_else(|| Error::msg("Installer release tag is missing"))?, &name, &to, reporter).await?;
        }
    } else {
        let sums_url = info.sums_url.as_deref().ok_or_else(|| Error::msg("The installer has no checksum file"))?;
        let sums = client()?.get(sums_url).send().await?.error_for_status()?.text().await?;
        let expected = sum_for(&sums, &name).ok_or_else(|| Error::msg("The installer is missing its checksum"))?;
        if !to.is_file() || sha256_file(&to)? != expected {
            let part = dir.join(format!("{name}.part"));
            download(&url, &part, reporter, "update").await?;
            if sha256_file(&part)? != expected {
                let _ = std::fs::remove_file(&part);
                return Err(Error::msg("The downloaded update did not match its checksum. Try again."));
            }
            std::fs::rename(&part, &to)?;
        }
    }
    Ok(to)
}

pub async fn install_desktop_update(reporter: &Reporter) -> Result<Installed> {
    let to = fetch_desktop_update(desktop_update().await?, reporter).await?;
    match install_in_place(&to) {
        Ok(()) => Ok(Installed { path: to, relaunching: true }),
        Err(e) => {
            tracing::warn!("update not installed in place ({e}); opening the installer");
            open_installer(&to)?;
            Ok(Installed { path: to, relaunching: false })
        }
    }
}

fn sum_for(sums: &str, name: &str) -> Option<String> {
    sums.lines().find_map(|l| {
        let mut parts = l.split_whitespace();
        let hash = parts.next()?;
        (parts.next()?.trim_start_matches('*') == name).then(|| hash.to_lowercase())
    })
}

#[cfg(target_os = "macos")]
fn install_in_place(dmg: &std::path::Path) -> Result<()> {
    use std::process::Command;
    // This process is Poki Setup.app/Contents/MacOS/<exe>.
    let exe = std::env::current_exe()?;
    let bundle = exe.ancestors().nth(3).filter(|p| p.extension().map(|e| e == "app").unwrap_or(false))
        .ok_or_else(|| Error::msg("Poki Setup is not running from an app bundle."))?.to_path_buf();
    let mount = std::env::temp_dir().join(format!("poki-setup-update-{}", std::process::id()));
    std::fs::create_dir_all(&mount)?;
    let st = Command::new("/usr/bin/hdiutil").args(["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint"]).arg(&mount).arg(dmg).status()?;
    if !st.success() {
        return Err(Error::msg("Could not open the update's disk image."));
    }
    let result = (|| -> Result<()> {
        let new_app = std::fs::read_dir(&mount)?.filter_map(|e| e.ok()).map(|e| e.path())
            .find(|p| p.extension().map(|e| e == "app").unwrap_or(false))
            .ok_or_else(|| Error::msg("The update's disk image has no app in it."))?;
        verify_mac_app(&new_app)?;
        let staged = bundle.with_extension("app.new");
        let old = bundle.with_extension("app.old");
        let _ = std::fs::remove_dir_all(&staged);
        let _ = std::fs::remove_dir_all(&old);
        if !Command::new("/usr/bin/ditto").arg(&new_app).arg(&staged).status()?.success() {
            let _ = std::fs::remove_dir_all(&staged);
            return Err(Error::msg("Could not copy the new Poki Setup next to this one."));
        }
        // Swap: a running app keeps its open files after its bundle is renamed.
        std::fs::rename(&bundle, &old)?;
        if let Err(e) = std::fs::rename(&staged, &bundle) {
            let _ = std::fs::rename(&old, &bundle);
            return Err(e.into());
        }
        let _ = std::fs::remove_dir_all(&old);
        Ok(())
    })();
    let _ = Command::new("/usr/bin/hdiutil").args(["detach", "-quiet"]).arg(&mount).status();
    let _ = std::fs::remove_dir(&mount);
    result?;
    // Opens the new app once this one has quit (the app quits when told `relaunching`).
    let pid = std::process::id();
    let script = format!("while kill -0 {pid} 2>/dev/null; do sleep 0.3; done; sleep 0.5; /usr/bin/open \"$0\"");
    use std::os::unix::process::CommandExt;
    Command::new("/bin/sh").arg("-c").arg(script).arg(&bundle).process_group(0)
        .stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null())
        .spawn()?;
    Ok(())
}

/// The new app must carry a valid signature from the same team as this one (Developer ID,
/// notarized builds only), so a swapped download can never replace Poki Setup with something else.
#[cfg(target_os = "macos")]
fn verify_mac_app(app: &std::path::Path) -> Result<()> {
    use std::process::Command;
    let ok = Command::new("/usr/bin/codesign").args(["--verify", "--deep", "--strict"]).arg(app).status()?.success();
    if !ok {
        return Err(Error::msg("The update's signature did not check out."));
    }
    let team = |p: &std::path::Path| -> Option<String> {
        let out = Command::new("/usr/bin/codesign").args(["-dv"]).arg(p).output().ok()?;
        let text = String::from_utf8_lossy(&out.stderr).to_string();
        text.lines().find_map(|l| l.strip_prefix("TeamIdentifier=")).map(|t| t.trim().to_string()).filter(|t| t != "not set")
    };
    let exe = std::env::current_exe()?;
    let mine = exe.ancestors().nth(3).and_then(team);
    let theirs = team(app);
    match (mine, theirs) {
        (Some(a), Some(b)) if a == b => Ok(()),
        (None, _) => Err(Error::msg("This Poki Setup is not signed with a Developer ID, so it does not update itself.")),
        (Some(a), b) => Err(Error::msg(format!("The update is signed by another team ({}), not {a}.", b.unwrap_or_else(|| "none".into())))),
    }
}

#[cfg(windows)]
fn install_in_place(setup: &std::path::Path) -> Result<()> {
    // Tauri's NSIS installer: /P passive (progress only, no questions), /R starts the app again.
    std::process::Command::new(setup).args(["/P", "/R"]).spawn()?;
    Ok(())
}

#[cfg(not(any(target_os = "macos", windows)))]
fn install_in_place(_: &std::path::Path) -> Result<()> { Err(Error::msg("Updates install by themselves on macOS and Windows only.")) }

fn open_installer(path: &std::path::Path) -> Result<()> {
    #[cfg(target_os = "macos")]
    std::process::Command::new("/usr/bin/open").arg(path).spawn()?;
    #[cfg(windows)]
    std::process::Command::new(path).spawn()?;
    #[cfg(not(any(target_os = "macos", windows)))]
    let _ = path;
    Ok(())
}

/// One dot-separated part of a suffix: numbers compare as numbers and sort before words.
#[derive(Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Ident {
    Num(u64),
    Text(String),
}

/// How a version compares, SemVer-like with Poki's build numbers:
/// `0.3.0-beta.1` < `0.3.0-beta.2` < `0.3.0` < `0.3.0-700` < `0.3.1`. The numbers before the
/// first `-` compare in order; then a pre-release suffix (any part that is not a number, like
/// `beta.1` or `rc.2`) sorts below the plain version, and a build number (`-700`) above it.
type VersionKey = (Vec<u64>, u8, Vec<Ident>);

fn version_key(s: &str) -> VersionKey {
    let (core, suffix) = s.split_once('-').unwrap_or((s, ""));
    let core = core.split('.').map(|x| x.parse::<u64>().unwrap_or(0)).collect();
    if suffix.is_empty() {
        return (core, 1, vec![]);
    }
    let parts: Vec<Ident> = suffix.split(['.', '-']).map(|x| x.parse::<u64>().map(Ident::Num).unwrap_or_else(|_| Ident::Text(x.to_ascii_lowercase()))).collect();
    let build = parts.iter().all(|p| matches!(p, Ident::Num(_)));
    (core, if build { 2 } else { 0 }, parts)
}

/// A release's version and build as one string for [`version_key`]: `0.3.0`, `0.3.0-beta.1`, `0.2.9-630`.
fn full(version: &str, build: &str) -> String {
    if build.is_empty() { version.to_string() } else { format!("{version}-{build}") }
}

/// Downloads the IPA (and the signing zip) into the cache, checks SHA-256 against SHA256SUMS.
pub async fn fetch(release: &Release, reporter: &Reporter) -> Result<(PathBuf, Option<PathBuf>)> {
    let dir = paths::cache_dir()?.join(&release.tag);
    std::fs::create_dir_all(&dir)?;
    let ipa = dir.join(&release.ipa_name);
    if let Some(notice) = &release.source_notice { reporter.note("release", notice); }
    if release.source == ReleaseSource::R2 {
        let pin = release.ipa_pin.as_ref().ok_or_else(|| Error::msg("IPA integrity metadata is missing"))?;
        if !pin.matches(&ipa) {
            download_pinned(&release.ipa_url, pin, &release.tag, &release.ipa_name, &ipa, reporter).await?;
        }
        let signing = if let Some(url) = &release.signing_url {
            let pin = release.signing_pin.as_ref().ok_or_else(|| Error::msg("Signing archive integrity metadata is missing"))?;
            let path = dir.join("Poki-signing.zip");
            if !pin.matches(&path) { download_pinned(url, pin, &release.tag, "Poki-signing.zip", &path, reporter).await?; }
            Some(path)
        } else { None };
        return Ok((ipa, signing));
    }
    let sums_url = release.sums_url.as_deref().ok_or_else(|| Error::msg("The IPA has no checksum file"))?;
    let sums = client()?.get(sums_url).send().await?.error_for_status()?.text().await?;
    let expected = sum_for(&sums, &release.ipa_name).ok_or_else(|| Error::msg("The IPA is missing its checksum"))?;
    if !ipa.is_file() || sha256_file(&ipa)? != expected {
        let part = dir.join(format!("{}.part", release.ipa_name));
        download(&release.ipa_url, &part, reporter, "release").await?;
        if sha256_file(&part)? != expected {
            let _ = std::fs::remove_file(&part);
            return Err(Error::msg("The downloaded IPA does not match the release's checksum. Try again."));
        }
        std::fs::rename(&part, &ipa)?;
    }
    let signing = match &release.signing_url {
        Some(u) => {
            let p = dir.join("Poki-signing.zip");
            if !p.is_file() {
                download(u, &p, reporter, "release").await?;
            }
            Some(p)
        }
        None => None,
    };
    Ok((ipa, signing))
}

const RELAY_ASSET: &str = "poki-relay-worker.js";

/// Which Poki the relay has to match: the release it was installed from, or its version and build
/// (for an IPA file picked by hand, found by the release's `Poki-external-<version>-<build>.ipa`).
#[derive(Debug, Clone, Default)]
pub struct RelayFor {
    pub tag: Option<String>,
    pub version: Option<String>,
    pub build: Option<String>,
}

/// The relay Worker (`poki-relay-worker.js`) of the release matching that Poki, checked against
/// the release's SHA256SUMS. Without a match (or with nothing to match), the newest one on the
/// chosen channel, stepping down like Poki's own releases. None when no release carries one.
pub async fn relay_worker(want: &RelayFor) -> Result<Option<(String, String, String)>> {
    let list = list().await?;
    let has = |r: &&GhRelease| r.assets.iter().any(|a| a.name == RELAY_ASSET);
    let by_tag = want.tag.as_deref().and_then(|t| list.iter().filter(has).find(|r| r.tag_name == t));
    let by_build = match (&want.version, &want.build) {
        (Some(v), Some(b)) => {
            let ipa = format!("Poki-external-{v}-{b}.ipa");
            list.iter().filter(has).find(|r| r.assets.iter().any(|a| a.name == ipa))
        }
        _ => None,
    };
    let found = by_tag.or(by_build).or_else(|| {
        channel().fallbacks().find_map(|c| list.iter().filter(has).find(|r| release_channel(r).map(|rc| c.includes(rc)).unwrap_or(false)))
    });
    let Some(r) = found else { return Ok(None) };
    let url = &r.assets.iter().find(|a| a.name == RELAY_ASSET).unwrap().browser_download_url;
    if r.source == ReleaseSource::R2 {
        let asset = r.assets.iter().find(|a| a.name == RELAY_ASSET).unwrap();
        let pin = asset.pin.as_ref().ok_or_else(|| Error::msg("Relay integrity metadata is missing"))?;
        let dir = tempfile::tempdir()?;
        let path = dir.path().join(RELAY_ASSET);
        download_pinned(url, pin, &r.tag_name, RELAY_ASSET, &path, &Reporter::silent()).await?;
        return Ok(Some((r.tag_name.clone(), std::fs::read_to_string(path)?, url.clone())));
    }
    let sums_url = r.assets.iter().find(|a| a.name == "SHA256SUMS").map(|a| a.browser_download_url.clone())
        .ok_or_else(|| Error::msg(format!("Release {} has the relay but no SHA256SUMS to check it against.", r.tag_name)))?;
    let http = client()?;
    let sums = http.get(&sums_url).timeout(std::time::Duration::from_secs(30)).send().await?.error_for_status()?.text().await?;
    let expected = sums.lines().find(|l| l.split_whitespace().last().map(|n| n.trim_start_matches('*')) == Some(RELAY_ASSET)).and_then(|l| l.split_whitespace().next()).map(|h| h.to_lowercase())
        .ok_or_else(|| Error::msg(format!("Release {}'s SHA256SUMS does not list {RELAY_ASSET}.", r.tag_name)))?;
    let body = http.get(url).timeout(std::time::Duration::from_secs(60)).send().await?.error_for_status()?.text().await?;
    let got = hex::encode(Sha256::digest(body.as_bytes()));
    if got != expected {
        return Err(Error::msg(format!("The relay in release {} does not match its SHA256SUMS. Try again; if it repeats, the download is being altered on the way.", r.tag_name)));
    }
    Ok(Some((r.tag_name.clone(), body, url.clone())))
}

async fn download_pinned(url: &str, pin: &Pin, tag: &str, name: &str, to: &std::path::Path, reporter: &Reporter) -> Result<()> {
    let temp = tempfile::NamedTempFile::new_in(to.parent().ok_or_else(|| Error::msg("Download has no parent directory"))?)?;
    let path = temp.path();
    let result = download_r2(url, pin, path, reporter).await;
    match result {
        Err(Error::ReleaseUnavailable(notice)) => {
            reporter.note("release", notice);
            let mut mirror = reqwest::Url::parse(&format!("https://github.com/{}/releases/download/", repo())).map_err(|_| Error::msg("Invalid release repository"))?;
            mirror.path_segments_mut().map_err(|_| Error::msg("Invalid release repository"))?.pop_if_empty().push(tag).push(name);
            download(mirror.as_str(), path, reporter, "release").await?;
        }
        Err(error) => return Err(error),
        Ok(()) => {},
    }
    if !pin.matches(path) { return Err(Error::msg("Download does not match the signed release catalog")); }
    temp.persist(to).map_err(|e| Error::Io(e.error))?;
    Ok(())
}

async fn download_r2(url: &str, pin: &Pin, to: &std::path::Path, reporter: &Reporter) -> Result<()> {
    use futures_util::StreamExt;
    let response = crate::release_catalog::get(url, std::time::Duration::from_secs(600)).await?;
    let mut stream = response.bytes_stream();
    let mut file = tokio::fs::File::create(to).await?;
    let mut got = 0;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| Error::ReleaseUnavailable("R2 download was interrupted. Using GitHub."))?;
        got += chunk.len() as u64;
        if got > pin.size { return Err(Error::msg("Download exceeds the signed size")); }
        tokio::io::AsyncWriteExt::write_all(&mut file, &chunk).await?;
        if pin.size > 0 { reporter.part("release", got as f64 / pin.size as f64, None); }
    }
    tokio::io::AsyncWriteExt::flush(&mut file).await?;
    Ok(())
}

pub async fn download(url: &str, to: &std::path::Path, reporter: &Reporter, step: &str) -> Result<()> {
    use futures_util::StreamExt;
    let res = client()?.get(url).send().await?.error_for_status()?;
    let total = res.content_length();
    let tmp = to.with_extension("part");
    let mut file = tokio::fs::File::create(&tmp).await?;
    let mut stream = res.bytes_stream();
    let mut got: u64 = 0;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        tokio::io::AsyncWriteExt::write_all(&mut file, &chunk).await?;
        got += chunk.len() as u64;
        if let Some(t) = total {
            reporter.part(step, got as f64 / t as f64, Some(format!("{:.1} of {:.1} MB", got as f64 / 1e6, t as f64 / 1e6)));
        }
    }
    tokio::io::AsyncWriteExt::flush(&mut file).await?;
    drop(file);
    std::fs::rename(&tmp, to)?;
    Ok(())
}

pub fn sha256_file(path: &std::path::Path) -> Result<String> {
    let mut f = std::fs::File::open(path)?;
    let mut h = Sha256::new();
    std::io::copy(&mut f, &mut h)?;
    Ok(hex::encode(h.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn signed_update_keeps_its_snapshot_and_preserves_existing_files_on_corruption() {
        use crate::release_catalog::{Source, fixture::{Reply, Server, asset, public_key, release, signed}};
        let (_guard, _home) = paths::test_home();
        let server = Server::start().await;
        let ipa_name = "Poki-external-0.4.2-700.ipa";
        let ipa_url = server.url("/releases/700/Poki-external-0.4.2-700.ipa");
        let zip_url = server.url("/releases/700/Poki-signing.zip");
        let entries = vec![release("app-0.4.2-beta.700", vec![asset(ipa_name, &ipa_url, b"ipa"), asset("Poki-signing.zip", &zip_url, b"zip")])];
        server.put("/catalog.json", Reply::Body(signed(entries)));
        server.put("/releases/700/Poki-external-0.4.2-700.ipa", Reply::Body(b"ipa".to_vec()));
        server.put("/releases/700/Poki-signing.zip", Reply::Body(b"zip".to_vec()));
        let entries = crate::release_catalog::read_from(&Source { url: server.url("/catalog.json"), public_key: public_key() }).await.unwrap();
        let mut entry: GhRelease = serde_json::from_value(entries[0].clone()).unwrap();
        entry.source = ReleaseSource::R2;
        let (_, selected) = installable(&entry).unwrap();
        server.put("/catalog.json", Reply::Body(signed(vec![])));
        let (ipa, signing) = fetch(&selected, &Reporter::silent()).await.unwrap();
        assert_eq!(std::fs::read(&ipa).unwrap(), b"ipa");
        assert_eq!(std::fs::read(signing.unwrap()).unwrap(), b"zip");
        server.put("/releases/700/Poki-external-0.4.2-700.ipa", Reply::Body(b"bad".to_vec()));
        let output = ipa.with_file_name("existing.ipa");
        std::fs::write(&output, b"keep this file").unwrap();
        let error = download_pinned(&ipa_url, selected.ipa_pin.as_ref().unwrap(), &selected.tag, ipa_name, &output, &Reporter::silent()).await.unwrap_err();
        assert!(error.to_string().contains("does not match"));
        assert_eq!(std::fs::read(output).unwrap(), b"keep this file");
    }

    #[tokio::test]
    async fn github_updates_require_checksums_before_using_cached_files() {
        use crate::release_catalog::fixture::{Reply, Server};
        let (_guard, _home) = paths::test_home();
        let server = Server::start().await;
        server.put("/file", Reply::Body(b"new bytes".to_vec()));
        let mut entry = gh("app-0.4.2-beta.700", true, "", Some("Poki-external-0.4.2-700.ipa"));
        entry.assets[0].browser_download_url = server.url("/file");
        let (_, selected) = installable(&entry).unwrap();
        let dir = paths::cache_dir().unwrap().join(&selected.tag);
        std::fs::create_dir_all(&dir).unwrap();
        let ipa = dir.join(&selected.ipa_name);
        std::fs::write(&ipa, b"existing IPA").unwrap();
        let ipa_result = fetch(&selected, &Reporter::silent()).await;
        let dir = paths::cache_dir().unwrap().join("updates");
        std::fs::create_dir_all(&dir).unwrap();
        let installer = dir.join("PokiSetup-0.3.0-700-macos.dmg");
        std::fs::write(&installer, b"existing installer").unwrap();
        let info = UpdateInfo { current: "0.2.2-1".into(), latest: Some("0.3.0-700".into()), url: None,
            asset_url: Some(server.url("/file")), asset_name: Some("PokiSetup-0.3.0-700-macos.dmg".into()),
            newer: true, channel: Channel::Beta, sums_url: None, source: ReleaseSource::Github,
            source_notice: None, tag: Some(selected.tag), asset_pin: None };
        let desktop_result = fetch_desktop_update(info, &Reporter::silent()).await;
        assert!(ipa_result.unwrap_err().to_string().contains("checksum"));
        assert!(desktop_result.unwrap_err().to_string().contains("checksum"));
        assert_eq!(std::fs::read(ipa).unwrap(), b"existing IPA");
        assert_eq!(std::fs::read(installer).unwrap(), b"existing installer");
    }

    fn gh(tag: &str, pre: bool, at: &str, ipa: Option<&str>) -> GhRelease {
        GhRelease {
            tag_name: tag.into(),
            prerelease: pre,
            draft: false,
            published_at: Some(at.into()),
            body: None,
            html_url: None,
            source: ReleaseSource::Github,
            source_notice: None,
            assets: ipa.map(|n| vec![GhAsset { name: n.into(), browser_download_url: format!("https://x/{n}"), pin: None }]).unwrap_or_default(),
        }
    }

    #[test]
    fn tags_map_to_channels() {
        assert_eq!(Channel::of_tag("ios", "ios-v0.2.7", false), Some(Channel::Stable));
        assert_eq!(Channel::of_tag("ios", "ios-v0.2.7", true), Some(Channel::Beta));
        assert_eq!(Channel::of_tag("ios", "ios-prealpha-0.2.7-252", true), Some(Channel::PreAlpha));
        assert_eq!(Channel::of_tag("ios", "ios-alpha-0.2.8-110", true), Some(Channel::Alpha));
        assert_eq!(Channel::of_tag("ios", "ios-alpha-latest", true), Some(Channel::Alpha));
        assert_eq!(Channel::of_tag("ios", "ios-prealpha-latest", true), Some(Channel::PreAlpha));
        assert_eq!(Channel::of_tag("ios", "ios-beta-0.3.0-600", true), Some(Channel::Beta));
        assert_eq!(Channel::of_tag("desktop", "desktop-beta-0.3.0-9", true), Some(Channel::Beta));
        assert_eq!(Channel::of_tag("desktop", "desktop-alpha-0.2.1-3", true), Some(Channel::Alpha));
        assert!(Channel::PreAlpha.includes(Channel::Alpha) && Channel::Alpha.includes(Channel::Beta) && !Channel::Beta.includes(Channel::Alpha));
        assert_eq!(Channel::parse("alpha"), Some(Channel::Alpha));
        assert_eq!(Channel::of_tag("ios", "v0.1.1", false), None);
        assert_eq!(Channel::of_tag("ios", "desktop-v0.2.0", false), None);
        assert_eq!(Channel::of_tag("desktop", "desktop-prealpha-0.2.1-9", true), Some(Channel::PreAlpha));
        assert_eq!(Channel::parse("Pre-alpha"), Some(Channel::PreAlpha));
        assert_eq!(serde_json::to_string(&Channel::PreAlpha).unwrap(), "\"pre-alpha\"");
    }

    #[test]
    fn channels_include_the_ones_above() {
        let mut list = vec![
            gh("ios-prealpha-0.2.8-260", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.8-260.ipa")),
            gh("ios-v0.2.7", true, "2026-11-07T05:00:00Z", Some("Poki-external-0.2.7-12.ipa")),
            gh("ios-v0.2.6", false, "2026-11-06T05:00:00Z", Some("Poki-external-0.2.6-9.ipa")),
            gh("v0.1.1", false, "2026-11-08T06:00:00Z", None),
        ];
        list.sort_by(|a, b| b.published_at.cmp(&a.published_at));
        let p = pick(&list, Channel::PreAlpha).unwrap();
        assert_eq!((p.version.as_str(), p.build.as_str(), p.channel), ("0.2.8", "260", Channel::PreAlpha));
        assert_eq!(pick(&list, Channel::Beta).unwrap().tag, "ios-v0.2.7");
        assert_eq!(pick(&list, Channel::Stable).unwrap().tag, "ios-v0.2.6");
        // Sorted: v0.1.1, prealpha, v0.2.7 (beta), v0.2.6. Without a Stable release, Stable steps
        // down to Beta; with only a Pre-alpha one it takes that; with no ios-* release, nothing.
        assert_eq!(pick(&list[..3], Channel::Stable).unwrap().tag, "ios-v0.2.7");
        assert_eq!(pick(&list[..2], Channel::Stable).unwrap().tag, "ios-prealpha-0.2.8-260");
        assert!(pick(&list[..1], Channel::Stable).is_none());
        assert_eq!(Channel::default(), Channel::Stable);
    }

    #[test]
    fn rolling_release_wins_by_build_not_list_order() {
        // Rolling releases keep their first date; a Beta made later sits above them in the list.
        let list = vec![
            gh("ios-beta-0.2.9-520", true, "2026-11-10T05:00:00Z", Some("Poki-external-0.2.9-520.ipa")),
            gh("ios-prealpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.9-540.ipa")),
            gh("ios-alpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.9-530.ipa")),
        ];
        assert_eq!(pick(&list, Channel::PreAlpha).unwrap().build, "540");
        assert_eq!(pick(&list, Channel::Alpha).unwrap().build, "530");
        assert_eq!(pick(&list, Channel::Beta).unwrap().tag, "ios-beta-0.2.9-520");
        // Same build on two channels: Pre-alpha users get their own channel's release.
        let tie = vec![
            gh("ios-alpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.8-501.ipa")),
            gh("ios-prealpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.8-501.ipa")),
        ];
        assert_eq!(pick(&tie, Channel::PreAlpha).unwrap().tag, "ios-prealpha-latest");
        assert_eq!(pick(&tie, Channel::Alpha).unwrap().tag, "ios-alpha-latest");
    }

    #[test]
    fn saved_channels_converge_to_beta() {
        let (_g, _d) = paths::test_home();
        assert_eq!(channel(), Channel::Beta);
        for historical in Channel::ALL {
            std::fs::write(channel_file().unwrap(), serde_json::to_vec(&ChannelFile { channel: historical }).unwrap()).unwrap();
            assert_eq!(channel(), Channel::Beta);
            set_channel(historical).unwrap();
            let saved: ChannelFile = serde_json::from_slice(&std::fs::read(channel_file().unwrap()).unwrap()).unwrap();
            assert_eq!(saved.channel, Channel::Beta);
        }
    }

    #[test]
    fn desktop_installer_found_on_any_release() {
        let mut ios = gh("ios-prealpha-0.2.8-441", true, "2026-11-08T08:00:00Z", Some("Poki-external-0.2.8-441.ipa"));
        ios.assets.push(GhAsset { name: "PokiSetup-0.2.1-300-macos.dmg".into(), browser_download_url: "https://x/dmg".into(), pin: None });
        ios.assets.push(GhAsset { name: "PokiSetup-0.2.1-300-windows-x64-setup.exe".into(), browser_download_url: "https://x/exe".into(), pin: None });
        let list = vec![ios];
        let (_, a, v) = pick_desktop(&list, Channel::Stable, "-macos.dmg").unwrap();
        assert_eq!((a.name.as_str(), v.as_str()), ("PokiSetup-0.2.1-300-macos.dmg", "0.2.1-300"));
        assert_eq!(pick_desktop(&list, Channel::Beta, "-windows-x64-setup.exe").unwrap().2, "0.2.1-300");
        assert!(version_key("0.2.1-300") > version_key("0.2.1-296"));
        assert!(version_key("0.2.1-300") > version_key("0.2.0"));
    }

    #[test]
    fn build_suffix_sorts_after_version() {
        assert!(version_key("0.2.1-5") > version_key("0.2.1"));
        assert!(version_key("0.2.2") > version_key("0.2.1-5"));
    }

    #[test]
    fn betas_sort_below_their_stable_and_by_number() {
        let order = ["0.2.9-630", "0.3.0-beta.1", "0.3.0-beta.2", "0.3.0-rc.1", "0.3.0", "0.3.0-700", "0.3.1-beta.1"];
        for w in order.windows(2) {
            assert!(version_key(w[0]) < version_key(w[1]), "{} < {}", w[0], w[1]);
        }
        assert!(version_key("0.3.0-beta.10") > version_key("0.3.0-beta.9"));
        assert_eq!(Channel::of_tag("ios", "ios-v0.3.0-beta.1", true), Some(Channel::Beta));
        assert_eq!(Channel::of_tag("ios", "ios-v0.3.0", false), Some(Channel::Stable));
        assert_eq!(Channel::of_tag("desktop", "desktop-v0.3.0-beta.1", true), Some(Channel::Beta));
        assert_eq!(Channel::of_tag("desktop", "desktop-v0.3.0", false), Some(Channel::Stable));
    }

    #[test]
    fn app_tags_map_to_channels() {
        let c = |t: &str, pre: bool| Channel::of_app_release(t, pre);
        assert_eq!(c("app-0.2.9-prealpha.640", true), Some(Channel::PreAlpha));
        assert_eq!(c("app-prealpha-latest", true), Some(Channel::PreAlpha));
        assert_eq!(c("app-0.2.9-alpha.640", true), Some(Channel::Alpha));
        assert_eq!(c("app-alpha-latest", true), Some(Channel::Alpha));
        assert_eq!(c("app-0.3.0-beta.1", true), Some(Channel::Beta));
        assert_eq!(c("app-0.3.0", false), Some(Channel::Stable));
        assert_eq!(c("app-0.3.0", true), Some(Channel::Beta));
        assert_eq!(c("app-latest", false), None);
        assert_eq!(c("desktop-v0.3.0", false), None);
        // The ios-* rules stay as they were.
        assert_eq!(c("ios-prealpha-latest", true), Some(Channel::PreAlpha));
        assert_eq!(c("ios-alpha-0.2.8-501", true), Some(Channel::Alpha));
        assert_eq!(c("ios-v0.3.0-beta.1", true), Some(Channel::Beta));
    }

    #[test]
    fn app_and_ios_releases_are_read_together() {
        let list = vec![
            gh("app-0.3.0", false, "2026-11-14T05:00:00Z", Some("Poki-external-0.3.0.ipa")),
            gh("app-0.3.0-beta.1", true, "2026-11-12T05:00:00Z", Some("Poki-external-0.3.0-beta.1.ipa")),
            gh("app-alpha-latest", true, "2026-11-09T06:00:00Z", Some("Poki-external-0.2.9-650.ipa")),
            gh("app-prealpha-latest", true, "2026-11-09T06:00:00Z", Some("Poki-external-0.2.9-660.ipa")),
            gh("ios-alpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.9-650.ipa")),
            gh("ios-prealpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.9-660.ipa")),
        ];
        let p = pick(&list, Channel::Stable).unwrap();
        assert_eq!((p.tag.as_str(), p.version.as_str(), p.build.as_str()), ("app-0.3.0", "0.3.0", ""));
        assert_eq!(pick(&list[1..], Channel::Beta).unwrap().tag, "app-0.3.0-beta.1");
        // The mirrors carry the same build: either release is fine, the build is what counts.
        assert_eq!(pick(&list[2..], Channel::Alpha).unwrap().build, "650");
        assert_eq!(pick(&list[2..], Channel::PreAlpha).unwrap().build, "660");
        assert_eq!(pick(&list[4..], Channel::PreAlpha).unwrap().tag, "ios-prealpha-latest");

        let mut app = gh("app-alpha-latest", true, "2026-11-09T06:00:00Z", None);
        app.assets.push(GhAsset { name: "PokiSetup-0.2.2-640-macos.dmg".into(), browser_download_url: "https://x/a".into(), pin: None });
        assert_eq!(pick_desktop(&[app], Channel::Alpha, "-macos.dmg").unwrap().2, "0.2.2-640");
    }

    #[test]
    fn stable_wins_over_its_betas_on_every_channel() {
        let list = vec![
            gh("ios-v0.3.0-beta.2", true, "2026-11-12T05:00:00Z", Some("Poki-external-0.3.0-beta.2.ipa")),
            gh("ios-v0.3.0-beta.1", true, "2026-11-11T05:00:00Z", Some("Poki-external-0.3.0-beta.1.ipa")),
            gh("ios-v0.3.0", false, "2026-11-10T05:00:00Z", Some("Poki-external-0.3.0.ipa")),
            gh("ios-alpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.3.0-700.ipa")),
            gh("ios-prealpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.9-630.ipa")),
        ];
        let p = pick(&list, Channel::Stable).unwrap();
        assert_eq!((p.tag.as_str(), p.version.as_str(), p.build.as_str()), ("ios-v0.3.0", "0.3.0", ""));
        assert_eq!(pick(&list, Channel::Beta).unwrap().tag, "ios-v0.3.0");
        assert_eq!(pick(&list[..2], Channel::Beta).unwrap().tag, "ios-v0.3.0-beta.2");
        assert_eq!(pick(&list, Channel::Alpha).unwrap().build, "700");
        // Pre-alpha includes every channel: the Alpha 0.3.0-700 is above its own 0.2.9-630.
        assert_eq!(pick(&list, Channel::PreAlpha).unwrap().build, "700");

        let mut beta = gh("desktop-v0.3.0-beta.1", true, "2026-11-11T05:00:00Z", None);
        beta.assets.push(GhAsset { name: "PokiSetup-0.3.0-beta.1-macos.dmg".into(), browser_download_url: "https://x/b".into(), pin: None });
        let mut stable = gh("desktop-v0.3.0", false, "2026-11-10T05:00:00Z", None);
        stable.assets.push(GhAsset { name: "PokiSetup-0.3.0-macos.dmg".into(), browser_download_url: "https://x/s".into(), pin: None });
        let desk = vec![beta, stable];
        assert_eq!(pick_desktop(&desk, Channel::Beta, "-macos.dmg").unwrap().2, "0.3.0");
        assert!(version_key("0.3.0") > version_key("0.3.0-beta.1"));
        assert!(version_key("0.3.0-beta.1") > version_key("0.2.2-618"));
    }
}

#[cfg(test)]
mod update_tests {
    #[test]
    fn checksum_line_for_a_file() {
        let sums = "aa11  PokiSetup-0.2.1-307-macos.dmg\nBB22 *PokiSetup-0.2.1-307-windows-x64-setup.exe\n";
        assert_eq!(super::sum_for(sums, "PokiSetup-0.2.1-307-macos.dmg").as_deref(), Some("aa11"));
        assert_eq!(super::sum_for(sums, "PokiSetup-0.2.1-307-windows-x64-setup.exe").as_deref(), Some("bb22"));
        assert_eq!(super::sum_for(sums, "other"), None);
    }
}
