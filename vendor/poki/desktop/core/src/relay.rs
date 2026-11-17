//! Deploys Poki's relay Worker (`deploy/cf-relay/worker.js`, bundled into this binary) to the
//! person's own Cloudflare account through the API, the same upload DEPLOY.md documents.
//! The API token is kept in the system keychain, so the relay can be updated without pasting it.
use crate::{Error, Result, Reporter};
use serde::{Deserialize, Serialize};

pub const WORKER_JS: &str = include_str!("../../../deploy/cf-relay/worker.js");
pub const SCRIPT_NAME: &str = "poki-relay";
pub const COMPATIBILITY_DATE: &str = "2025-10-01";
const API: &str = "https://api.cloudflare.com/client/v4";

pub const VARS: [(&str, &str); 7] = [
    ("MAX_BODY", "4194304"),
    ("REQ_TIMEOUT_MS", "180000"),
    ("PER_MINUTE", "60"),
    ("CONCURRENT", "4"),
    ("LABEL_DAILY", "5000"),
    ("GLOBAL_DAILY", "8000"),
    ("GLOBAL_DAILY_SECONDS", "80000"),
];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Deployed {
    pub account_id: String,
    pub account_name: String,
    pub address: String,
    pub first_deploy: bool,
    pub deployed_at: i64,
    /// `poki://setup?relay=<address>`, for the QR the phone scans.
    pub phone_link: String,
    /// SHA-256 of the Worker code deployed, to tell when a newer relay is out.
    #[serde(default)]
    pub worker_sha256: Option<String>,
    /// Where that code came from: a release tag, or "built in".
    #[serde(default)]
    pub worker_source: Option<String>,
}

/// The Poki the relay must match: the one this computer installed or renewed most recently.
fn relay_for() -> crate::release::RelayFor {
    let newest = crate::keeper::all().ok().and_then(|all| all.into_iter().max_by_key(|r| r.signed_at));
    match newest {
        Some(r) => crate::release::RelayFor {
            tag: (!r.release_tag.starts_with("local:")).then(|| r.release_tag.clone()),
            version: Some(r.version.clone()),
            build: Some(r.build.clone()),
        },
        None => Default::default(),
    }
}

/// The relay code to deploy: `poki-relay-worker.js` from the release of the Poki on the iPhone
/// (else the newest on the chosen channel), checked against that release's SHA256SUMS; the copy
/// built into this app when no release has one or GitHub can't be reached.
pub async fn worker_code() -> (String, String) {
    let (code, source, _) = worker_code_and_link().await;
    (code, source)
}

/// The relay's source in the release repo, for deploying it by hand.
pub fn source_link() -> String { format!("https://github.com/{}/tree/standalone/deploy/cf-relay", crate::release::repo()) }

/// The code, where it came from, and a link to that exact file (the release asset, or the source).
pub async fn worker_code_and_link() -> (String, String, String) {
    match crate::release::relay_worker(&relay_for()).await {
        Ok(Some((tag, code, url))) => (code, tag, url),
        Ok(None) => (WORKER_JS.to_string(), "built in".into(), source_link()),
        Err(e) => {
            tracing::warn!("relay from releases unavailable, using the built-in copy: {e}");
            (WORKER_JS.to_string(), "built in".into(), source_link())
        }
    }
}

pub fn sha256_hex(s: &str) -> String {
    use sha2::Digest;
    hex::encode(sha2::Sha256::digest(s.as_bytes()))
}

/// Whether the relay you deployed differs from the one Poki Setup would deploy now.
#[derive(Debug, Clone, Serialize)]
pub struct WorkerStatus {
    pub source: String,
    /// The worker.js to deploy by hand (the release's `poki-relay-worker.js`, or the source folder).
    pub download_url: String,
    /// DEPLOY.md, the steps for deploying it by hand.
    pub guide_url: String,
    pub sha256: String,
    pub deployed_sha256: Option<String>,
    pub update_available: bool,
}

pub async fn worker_status() -> Result<WorkerStatus> {
    let (code, source, download_url) = worker_code_and_link().await;
    let sha256 = sha256_hex(&code);
    let at = if source == "built in" { "standalone" } else { source.as_str() };
    let guide_url = format!("https://github.com/{}/blob/{at}/deploy/cf-relay/DEPLOY.md", crate::release::repo());
    let deployed_sha256 = remembered()?.and_then(|d| d.worker_sha256);
    // A relay deployed before Poki Setup recorded hashes counts as older.
    let update_available = remembered()?.is_some() && deployed_sha256.as_deref() != Some(sha256.as_str());
    Ok(WorkerStatus { source, download_url, guide_url, sha256, deployed_sha256, update_available })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Account {
    pub id: String,
    pub name: String,
}

#[derive(Deserialize)]
struct Envelope<T> {
    success: bool,
    #[serde(default)]
    errors: Vec<ApiError>,
    result: Option<T>,
}
#[derive(Deserialize)]
struct ApiError {
    code: i64,
    message: String,
}

pub struct Cloudflare {
    http: reqwest::Client,
    token: String,
}

impl Cloudflare {
    pub fn new(token: &str) -> Result<Self> {
        if token.trim().len() < 20 {
            return Err(Error::msg("That does not look like a Cloudflare API token."));
        }
        Ok(Cloudflare { http: reqwest::Client::builder().timeout(std::time::Duration::from_secs(120)).build()?, token: token.trim().to_string() })
    }

    async fn parse<T: serde::de::DeserializeOwned>(res: reqwest::Response, what: &str) -> Result<T> {
        let status = res.status();
        let text = res.text().await?;
        let env: Envelope<T> = serde_json::from_str(&text).map_err(|_| Error::msg(format!("Cloudflare answered {what} with HTTP {status}: {}", text.chars().take(200).collect::<String>())))?;
        if !env.success {
            let msg = env.errors.iter().map(|e| format!("{} ({})", e.message, e.code)).collect::<Vec<_>>().join("; ");
            return Err(match env.errors.first().map(|e| e.code) {
                Some(10000) | Some(9109) | Some(10001) => Error::msg("Cloudflare rejected the API token. Make a token with the 'Edit Cloudflare Workers' template at dash.cloudflare.com/profile/api-tokens."),
                _ => Error::msg(format!("Cloudflare: {msg}")),
            });
        }
        env.result.ok_or_else(|| Error::msg(format!("Cloudflare gave no result for {what}")))
    }

    pub async fn accounts(&self) -> Result<Vec<Account>> {
        let res = self.http.get(format!("{API}/accounts?per_page=50")).bearer_auth(&self.token).send().await?;
        let list: Vec<Account> = Self::parse(res, "the account list").await?;
        if list.is_empty() {
            return Err(Error::msg("This token sees no Cloudflare account. Give it 'Account: Workers Scripts: Edit' on your account."));
        }
        Ok(list)
    }

    async fn has_secret(&self, account: &str) -> Result<Option<bool>> {
        let res = self.http.get(format!("{API}/accounts/{account}/workers/scripts/{SCRIPT_NAME}/secrets")).bearer_auth(&self.token).send().await?;
        if res.status().as_u16() == 404 {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct S {
            name: String,
        }
        let list: Vec<S> = Self::parse(res, "the secret list").await?;
        Ok(Some(list.iter().any(|s| s.name == "TOKEN_SECRET")))
    }

    async fn migration_tag(&self, account: &str) -> Result<Option<String>> {
        let res = self.http.get(format!("{API}/accounts/{account}/workers/services/{SCRIPT_NAME}")).bearer_auth(&self.token).send().await?;
        if res.status().as_u16() == 404 {
            return Ok(None);
        }
        let v: serde_json::Value = Self::parse(res, "the Worker").await?;
        Ok(Some(v["default_environment"]["script"]["migration_tag"].as_str().unwrap_or("").to_string()))
    }

    /// Uploads the Worker. Keeps an existing TOKEN_SECRET, makes one on the first deploy.
    pub async fn deploy(&self, account: &Account, reporter: &Reporter) -> Result<Deployed> {
        reporter.part("relay", 0.1, Some("Checking the account".into()));
        let existing_secret = self.has_secret(&account.id).await?;
        let tag = self.migration_tag(&account.id).await?;
        let first_deploy = existing_secret.is_none();
        let mut bindings = vec![
            serde_json::json!({"type": "durable_object_namespace", "name": "DEVICE", "class_name": "DeviceRelay"}),
            serde_json::json!({"type": "durable_object_namespace", "name": "BUDGET", "class_name": "Budget"}),
        ];
        for (k, v) in VARS {
            bindings.push(serde_json::json!({"type": "plain_text", "name": k, "text": v}));
        }
        let mut metadata = serde_json::json!({
            "main_module": "index.js",
            "compatibility_date": COMPATIBILITY_DATE,
            "bindings": bindings,
            "observability": {"enabled": false},
        });
        if existing_secret == Some(true) {
            metadata["keep_bindings"] = serde_json::json!(["secret_text"]);
        } else {
            use rand::RngCore;
            let mut raw = [0u8; 32];
            rand::thread_rng().fill_bytes(&mut raw);
            metadata["bindings"].as_array_mut().unwrap().push(serde_json::json!({"type": "secret_text", "name": "TOKEN_SECRET", "text": hex::encode(raw)}));
        }
        match tag.as_deref() {
            None | Some("") => metadata["migrations"] = serde_json::json!({"new_tag": "v1", "new_sqlite_classes": ["DeviceRelay", "Budget"]}),
            Some("v1") => {}
            Some(other) => return Err(Error::msg(format!("The Worker {SCRIPT_NAME} in this account has migration tag {other}, which this version does not know. Deploy it with ./deploy.sh instead."))),
        }
        reporter.part("relay", 0.3, Some("Getting the newest relay".into()));
        let (code, source) = worker_code().await;
        reporter.part("relay", 0.4, Some(format!("Uploading the Worker ({source})")));
        let form = reqwest::multipart::Form::new()
            .part("metadata", reqwest::multipart::Part::text(metadata.to_string()).mime_str("application/json").unwrap())
            .part("index.js", reqwest::multipart::Part::text(code.clone()).file_name("index.js").mime_str("application/javascript+module").unwrap());
        let res = self.http.put(format!("{API}/accounts/{}/workers/scripts/{SCRIPT_NAME}", account.id)).bearer_auth(&self.token).multipart(form).send().await?;
        let _: serde_json::Value = Self::parse(res, "the upload").await?;

        reporter.part("relay", 0.7, Some("Turning on the workers.dev address".into()));
        let res = self.http.post(format!("{API}/accounts/{}/workers/scripts/{SCRIPT_NAME}/subdomain", account.id)).bearer_auth(&self.token).json(&serde_json::json!({"enabled": true, "previews_enabled": false})).send().await?;
        let _: serde_json::Value = Self::parse(res, "the subdomain switch").await?;
        let res = self.http.get(format!("{API}/accounts/{}/workers/subdomain", account.id)).bearer_auth(&self.token).send().await?;
        let sub: serde_json::Value = Self::parse(res, "the subdomain").await?;
        let sub = sub["subdomain"].as_str().ok_or_else(|| Error::msg("This account has no workers.dev subdomain yet. Open Workers & Pages in the dashboard once to pick one, then deploy again."))?;
        let address = format!("https://{SCRIPT_NAME}.{sub}.workers.dev");

        reporter.part("relay", 0.9, Some("Checking the relay answers".into()));
        let mut up = false;
        for _ in 0..10 {
            if crate::mcp::relay_up(&address).await.unwrap_or(false) {
                up = true;
                break;
            }
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        }
        if !up {
            return Err(Error::msg(format!("The Worker is uploaded, but {address} does not answer yet. Wait a minute and check it from Relay → Check.")));
        }
        Ok(Deployed { account_id: account.id.clone(), account_name: account.name.clone(), address: address.clone(), first_deploy, deployed_at: crate::keeper::now(), phone_link: phone_link(&address), worker_sha256: Some(sha256_hex(&code)), worker_source: Some(source) })
    }
}

const TOKEN_NAME: &str = "cloudflare-relay-token";

/// The Cloudflare API token saved in the keychain, if any.
pub fn saved_token() -> Option<String> { crate::apple::store::secret_get(TOKEN_NAME) }
pub fn save_token(token: &str) -> Result<()> { crate::apple::store::secret_set(TOKEN_NAME, token.trim()) }
pub fn forget_token() -> Result<()> { crate::apple::store::secret_delete(TOKEN_NAME) }

/// The token to use: the one given, else the saved one.
pub fn token_or_saved(given: Option<String>) -> Result<String> {
    given.filter(|t| !t.trim().is_empty()).or_else(saved_token).ok_or_else(|| Error::msg("Paste a Cloudflare API token first."))
}

pub fn phone_link(address: &str) -> String { format!("poki://setup?relay={}", urlencode(address)) }

fn path() -> Result<std::path::PathBuf> { Ok(crate::paths::state_dir()?.join("relay.json")) }
pub fn remembered() -> Result<Option<Deployed>> { Ok(std::fs::read_to_string(path()?).ok().and_then(|t| serde_json::from_str(&t).ok())) }
pub fn remember(d: &Deployed) -> Result<()> {
    std::fs::write(path()?, serde_json::to_vec_pretty(d)?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn worker_is_bundled() {
        assert!(super::WORKER_JS.contains("DeviceRelay"));
        assert!(super::WORKER_JS.len() > 10_000);
        assert_eq!(super::phone_link("https://poki-relay.me.workers.dev"), "poki://setup?relay=https%3A%2F%2Fpoki-relay.me.workers.dev");
    }
}

fn urlencode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}
