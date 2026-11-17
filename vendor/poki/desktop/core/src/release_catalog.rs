//! Signed release catalogs. Signatures cover the exact decoded payload bytes.
use crate::{Error, Result};
use base64::{Engine, engine::general_purpose::STANDARD};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;

#[derive(Deserialize)]
pub(crate) struct Source {
    pub url: String,
    pub public_key: String,
}
#[derive(Deserialize)]
struct Envelope { payload: String, signature: String }
#[derive(Deserialize)]
struct Catalog { schema: u32, releases: Vec<Value> }
#[derive(Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
    #[serde(flatten)]
    pin: Pin,
}

/// A file's size and SHA-256 as the signed catalog listed them when a release was read. Downloads
/// are checked against this copy, so one update never mixes two versions of the catalog.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pin {
    pub size: u64,
    pub sha256: String,
}

impl Pin {
    pub fn matches(&self, path: &std::path::Path) -> bool {
        path.is_file() && path.metadata().is_ok_and(|m| m.len() == self.size)
            && crate::release::sha256_file(path).is_ok_and(|s| s.eq_ignore_ascii_case(&self.sha256))
    }
}

fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder().user_agent("PokiSetup")
        .redirect(reqwest::redirect::Policy::none()).build()?)
}

/// One GET to the release source. A redirect is refused, not followed: a file comes from the
/// address the signed catalog names, or not at all.
pub(crate) async fn get(url: &str, timeout: Duration) -> Result<reqwest::Response> {
    let response = client()?.get(url).timeout(timeout).send().await
        .map_err(|_| Error::ReleaseUnavailable("R2 is unavailable. Using GitHub for this update."))?;
    if response.status().is_server_error() || matches!(response.status().as_u16(), 404 | 408 | 429) {
        return Err(Error::ReleaseUnavailable("R2 is unavailable. Using GitHub for this update."));
    }
    if response.status().is_redirection() {
        return Err(Error::msg(format!("The release source answered with a redirect ({}), which Poki does not follow.", response.status().as_u16())));
    }
    Ok(response.error_for_status()?)
}

fn valid_url(value: &str) -> Result<reqwest::Url> {
    let url = reqwest::Url::parse(value).map_err(|_| Error::msg("Invalid release URL"))?;
    let loopback = url.host_str().is_some_and(|h| h == "localhost" || h.trim_matches(['[', ']']).parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback()));
    if !(url.scheme() == "https" || (url.scheme() == "http" && loopback)) || !url.username().is_empty() || url.password().is_some() || url.fragment().is_some() || url.query().is_some() {
        return Err(Error::msg("Release URLs require HTTPS (or loopback HTTP) and no credentials or fragment/query"));
    }
    // URL parsing normalizes dot segments; reject them before accepting any download path.
    let lower = value.to_ascii_lowercase();
    if lower.contains("%2e") || lower.contains("%2f") || lower.contains("%5c") || value.contains('\\') || value.split('/').any(|s| s == "." || s == "..") {
        return Err(Error::msg("Release URL contains an unsafe path"));
    }
    Ok(url)
}

fn source() -> Result<Source> {
    let source: Source = serde_json::from_str(include_str!("../../../config/release-source.json"))?;
    if source.url.is_empty() && source.public_key.is_empty() {
        return Err(Error::ReleaseUnavailable("R2 is not configured in this build. Using GitHub."));
    }
    Ok(source)
}

/// The releases in the configured source's catalog, once its signature and every file entry check out.
pub(crate) async fn read() -> Result<Vec<Value>> { read_from(&source()?).await }

pub(crate) async fn read_from(source: &Source) -> Result<Vec<Value>> {
    if source.url.is_empty() {
        return Err(Error::msg("This release source has no catalog address. Configure config/release-source.json."));
    }
    let base = valid_url(&source.url)?;
    let key_bytes: [u8; 32] = hex::decode(&source.public_key).ok().and_then(|v| v.try_into().ok())
        .ok_or_else(|| Error::msg("The release catalog public key is not configured, so releases cannot be verified. Nothing was downloaded."))?;
    let key = VerifyingKey::from_bytes(&key_bytes).map_err(|_| Error::msg("Invalid catalog public key"))?;
    let mut response = get(base.as_str(), Duration::from_secs(10)).await?;
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| Error::ReleaseUnavailable("R2 download was interrupted. Using GitHub."))? {
        if bytes.len() + chunk.len() > 4 * 1024 * 1024 { return Err(Error::msg("Release catalog is too large")); }
        bytes.extend_from_slice(&chunk);
    }
    let envelope: Envelope = serde_json::from_slice(&bytes)?;
    let payload = STANDARD.decode(envelope.payload).map_err(|_| Error::msg("Invalid catalog encoding"))?;
    let signature = STANDARD.decode(envelope.signature).ok().and_then(|v| Signature::from_slice(&v).ok())
        .ok_or_else(|| Error::msg("Invalid catalog signature encoding"))?;
    key.verify_strict(&payload, &signature).map_err(|_| Error::msg("Release catalog signature does not match"))?;
    let catalog: Catalog = serde_json::from_slice(&payload)?;
    if catalog.schema != 1 { return Err(Error::msg("Unsupported release catalog schema")); }
    let mut seen_tags = std::collections::HashSet::new();
    let mut seen_urls = std::collections::HashMap::new();
    for release in &catalog.releases {
        let tag = release.get("tag_name").and_then(Value::as_str).ok_or_else(|| Error::msg("Missing release tag"))?;
        if !safe_name(tag) || !seen_tags.insert(tag) { return Err(Error::msg("Unsafe or duplicate release tag")); }
        let assets = release.get("assets").and_then(Value::as_array).ok_or_else(|| Error::msg("Missing release assets"))?;
        let mut names = std::collections::HashSet::new();
        for value in assets {
            let asset: Asset = serde_json::from_value(value.clone())?;
            let url = valid_url(&asset.browser_download_url)?;
            if url.origin() != base.origin() || !url.path().starts_with("/releases/") {
                return Err(Error::msg("A catalog file is outside the release source"));
            }
            if !safe_name(&asset.name) || !names.insert(asset.name.clone()) || asset.pin.sha256.len() != 64 || !asset.pin.sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Err(Error::msg("Invalid or duplicate catalog asset"));
            }
            let fingerprint = (asset.pin.sha256.to_ascii_lowercase(), asset.pin.size);
            if let Some(previous) = seen_urls.insert(asset.browser_download_url.clone(), fingerprint.clone()) {
                if previous != fingerprint { return Err(Error::msg("Conflicting integrity metadata for one asset URL")); }
            }
        }
    }
    Ok(catalog.releases)
}

fn safe_name(name: &str) -> bool {
    !name.is_empty() && name != "." && name != ".." && !name.contains(['/', '\\']) && !name.chars().any(char::is_control)
}

#[cfg(test)]
pub(crate) mod fixture {
    use base64::{Engine, engine::general_purpose::STANDARD};
    use ed25519_dalek::{Signer, SigningKey};
    use serde_json::{Value, json};
    use sha2::{Digest, Sha256};
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[derive(Clone)]
    pub enum Reply {
        Body(Vec<u8>),
        Redirect(String),
    }

    /// A release source on loopback: one fixed reply per path, and a log of the paths asked for.
    #[derive(Clone)]
    pub struct Server {
        pub origin: String,
        replies: Arc<Mutex<HashMap<String, Reply>>>,
        asked: Arc<Mutex<Vec<String>>>,
    }

    impl Server {
        pub async fn start() -> Self {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let server = Self { origin: format!("http://{}", listener.local_addr().unwrap()), replies: Default::default(), asked: Default::default() };
            let this = server.clone();
            tokio::spawn(async move {
                while let Ok((mut socket, _)) = listener.accept().await {
                    let this = this.clone();
                    tokio::spawn(async move {
                        let mut request = Vec::new();
                        let mut buf = [0u8; 1024];
                        while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                            match socket.read(&mut buf).await {
                                Ok(n) if n > 0 => request.extend_from_slice(&buf[..n]),
                                _ => return,
                            }
                        }
                        let path = String::from_utf8_lossy(&request).split_whitespace().nth(1).unwrap_or_default().to_string();
                        this.asked.lock().unwrap().push(path.clone());
                        let reply = this.replies.lock().unwrap().get(&path).cloned();
                        let head = match &reply {
                            Some(Reply::Body(body)) => format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()),
                            Some(Reply::Redirect(to)) => format!("HTTP/1.1 302 Found\r\nLocation: {to}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"),
                            None => "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_string(),
                        };
                        let _ = socket.write_all(head.as_bytes()).await;
                        if let Some(Reply::Body(body)) = reply {
                            let _ = socket.write_all(&body).await;
                        }
                        let _ = socket.shutdown().await;
                    });
                }
            });
            server
        }

        pub fn url(&self, path: &str) -> String { format!("{}{path}", self.origin) }

        pub fn put(&self, path: &str, reply: Reply) { self.replies.lock().unwrap().insert(path.to_string(), reply); }

        pub fn asked_at_all(&self) -> usize { self.asked.lock().unwrap().len() }
    }

    fn key() -> SigningKey { SigningKey::from_bytes(&[7; 32]) }

    pub fn public_key() -> String { hex::encode(key().verifying_key().to_bytes()) }

    /// One catalog asset entry whose size and digest describe `bytes`.
    pub fn asset(name: &str, url: &str, bytes: &[u8]) -> Value {
        json!({ "name": name, "browser_download_url": url, "sha256": hex::encode(Sha256::digest(bytes)), "size": bytes.len() })
    }

    pub fn release(tag: &str, assets: Vec<Value>) -> Value {
        json!({ "tag_name": tag, "prerelease": true, "draft": false, "published_at": "2026-11-13T10:00:00Z", "body": "", "assets": assets })
    }

    /// The catalog file as the release source serves it, signed with the fixture key.
    pub fn signed(releases: Vec<Value>) -> Vec<u8> {
        let payload = serde_json::to_vec(&json!({ "schema": 1, "releases": releases })).unwrap();
        let signature = key().sign(&payload);
        serde_json::to_vec(&json!({ "payload": STANDARD.encode(&payload), "signature": STANDARD.encode(signature.to_bytes()) })).unwrap()
    }
}

#[cfg(test)]
mod tests {
    use super::fixture::{Reply, Server, asset, public_key, release, signed};
    use super::*;

    fn at(server: &Server, path: &str, public_key: String) -> Source { Source { url: server.url(path), public_key } }

    async fn refusal(source: &Source) -> String { read_from(source).await.unwrap_err().to_string() }

    #[tokio::test]
    async fn a_source_without_a_public_key_refuses_before_any_request() {
        let server = Server::start().await;
        server.put("/catalog.json", Reply::Body(signed(vec![])));
        let said = refusal(&at(&server, "/catalog.json", String::new())).await;
        assert!(said.contains("public key is not configured"), "{said}");
        assert_eq!(server.asked_at_all(), 0);
    }

    #[tokio::test]
    async fn a_file_on_another_origin_is_refused() {
        let server = Server::start().await;
        let other = Server::start().await;
        server.put("/catalog.json", Reply::Body(signed(vec![release("app-alpha-latest", vec![asset("Poki-signing.zip", &other.url("/releases/1/Poki-signing.zip"), b"zip")])])));
        let said = refusal(&at(&server, "/catalog.json", public_key())).await;
        assert!(said.contains("outside the release source"), "{said}");
    }

    #[tokio::test]
    async fn a_file_path_outside_releases_is_refused() {
        let server = Server::start().await;
        for (path, expected) in [("/other/Poki-signing.zip", "outside the release source"), ("/releases/1/../Poki-signing.zip", "unsafe path")] {
            server.put("/catalog.json", Reply::Body(signed(vec![release("app-alpha-latest", vec![asset("Poki-signing.zip", &server.url(path), b"zip")])])));
            let said = refusal(&at(&server, "/catalog.json", public_key())).await;
            assert!(said.contains(expected), "{path}: {said}");
        }
    }

    #[tokio::test]
    async fn a_redirect_is_refused_for_the_catalog_and_for_a_file() {
        let server = Server::start().await;
        server.put("/moved.json", Reply::Body(signed(vec![])));
        server.put("/catalog.json", Reply::Redirect("/moved.json".into()));
        let said = refusal(&at(&server, "/catalog.json", public_key())).await;
        assert!(said.contains("redirect"), "{said}");

        server.put("/releases/1/moved.zip", Reply::Body(b"zip".to_vec()));
        server.put("/releases/1/Poki-signing.zip", Reply::Redirect("/releases/1/moved.zip".into()));
        let said = get(&server.url("/releases/1/Poki-signing.zip"), Duration::from_secs(5)).await.unwrap_err().to_string();
        assert!(said.contains("redirect"), "{said}");
    }
}
