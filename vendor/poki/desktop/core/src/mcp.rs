//! Connector links. The phone makes and revokes them (the secret never leaves it); this computer
//! keeps the ones the person pastes, checks them end to end with an OAuth round and a
//! `tools/list`, and writes the client snippets.
use crate::{Error, Result, paths};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Connector {
    pub name: String,
    /// `https://<relay>/v1/<label>/<secret>/mcp`
    pub url: String,
    pub added_at: i64,
    pub last_check: Option<Check>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Check {
    pub at: i64,
    pub ok: bool,
    pub relay_ok: bool,
    pub phone_online: bool,
    pub tools: Vec<String>,
    pub detail: String,
}

#[derive(Debug, Clone)]
pub struct Parts {
    pub origin: String,
    pub label: String,
    pub secret: String,
}

pub fn parse(url: &str) -> Result<Parts> {
    let u = reqwest::Url::parse(url.trim()).map_err(|_| Error::msg("That is not a web address."))?;
    if u.scheme() != "https" {
        return Err(Error::msg("A connector link starts with https://."));
    }
    let segs: Vec<&str> = u.path_segments().map(|s| s.collect()).unwrap_or_default();
    if segs.len() != 4 || segs[0] != "v1" || segs[3] != "mcp" {
        return Err(Error::msg("A connector link looks like https://<relay>/v1/<label>/<secret>/mcp. Copy it from Poki's Connect tab."));
    }
    let label = segs[1];
    if label.len() != 52 || !label.chars().all(|c| matches!(c, 'a'..='z' | '2'..='7')) {
        return Err(Error::msg("The label in that link is not one Poki makes (52 lowercase base32 characters)."));
    }
    Ok(Parts { origin: u.origin().ascii_serialization(), label: label.into(), secret: segs[2].into() })
}

/// The link with the secret hidden, for screens and logs.
pub fn redact(url: &str) -> String {
    match parse(url) {
        Ok(p) => format!("{}/v1/{}…/{}/mcp", p.origin, &p.label[..8], "•".repeat(6)),
        Err(_) => "(not a connector link)".into(),
    }
}

fn path() -> Result<std::path::PathBuf> { Ok(paths::state_dir()?.join("connectors.json")) }

pub fn all() -> Result<Vec<Connector>> {
    Ok(std::fs::read_to_string(path()?).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default())
}

pub fn add(name: &str, url: &str) -> Result<Connector> {
    parse(url)?;
    let mut list = all()?;
    list.retain(|c| c.url != url);
    let c = Connector { name: name.trim().to_string(), url: url.trim().to_string(), added_at: crate::keeper::now(), last_check: None };
    list.push(c.clone());
    save(&list)?;
    Ok(c)
}

pub fn forget(url: &str) -> Result<()> {
    let mut list = all()?;
    list.retain(|c| c.url != url);
    save(&list)
}

fn save(list: &[Connector]) -> Result<()> {
    let p = path()?;
    std::fs::write(&p, serde_json::to_vec_pretty(list)?)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

/// Is the relay up? Stateless metadata answers 200 for any well-formed link.
pub async fn relay_up(origin: &str) -> Result<bool> {
    let probe = format!("{origin}/.well-known/oauth-protected-resource/v1/{}/{}/mcp", "a".repeat(52), "a".repeat(43));
    let res = reqwest::Client::builder().timeout(std::time::Duration::from_secs(15)).build()?.get(probe).send().await?;
    Ok(res.status().is_success())
}

/// The whole path a Claude connector takes: metadata, registration, authorize (the phone must
/// be online and know the secret), token, then `tools/list` through the phone.
pub async fn check(url: &str) -> Result<Check> {
    check_connector(url, parse(url)?).await
}

async fn check_connector(url: &str, parts: Parts) -> Result<Check> {
    let http = reqwest::Client::builder().timeout(std::time::Duration::from_secs(60)).redirect(reqwest::redirect::Policy::none()).build()?;
    let base = format!("{}/v1/{}/{}", parts.origin, parts.label, parts.secret);
    let at = crate::keeper::now();
    let fail = |relay_ok: bool, phone_online: bool, detail: String| Check { at, ok: false, relay_ok, phone_online, tools: vec![], detail };

    if !relay_up(&parts.origin).await.unwrap_or(false) {
        return Ok(fail(false, false, "The relay did not answer. Is the Worker deployed at this address?".into()));
    }
    // Register a client.
    let reg = http
        .post(format!("{base}/register"))
        .json(&serde_json::json!({ "client_name": "Poki Setup check", "redirect_uris": ["http://127.0.0.1/poki-setup"], "token_endpoint_auth_method": "none", "grant_types": ["authorization_code"], "response_types": ["code"] }))
        .send()
        .await?;
    if !reg.status().is_success() {
        return Ok(fail(true, false, format!("The relay refused to register a client (HTTP {}).", reg.status())));
    }
    let reg: serde_json::Value = reg.json().await?;
    let client_id = reg["client_id"].as_str().unwrap_or("").to_string();
    // PKCE.
    use base64::Engine;
    use rand::RngCore;
    use sha2::Digest;
    let mut v = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut v);
    let verifier = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(v);
    let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(verifier.as_bytes()));
    // The relay can wait 90 seconds for phone consent. Allow extra transport time only here.
    let auth = http
        .get(format!("{base}/authorize"))
        .timeout(std::time::Duration::from_secs(105))
        .query(&[("response_type", "code"), ("client_id", client_id.as_str()), ("redirect_uri", "http://127.0.0.1/poki-setup"), ("code_challenge", challenge.as_str()), ("code_challenge_method", "S256"), ("state", "x")])
        .send()
        .await?;
    let code = match auth.status().as_u16() {
        302 | 303 | 307 => {
            let loc = auth.headers().get("location").and_then(|l| l.to_str().ok()).unwrap_or("").to_string();
            let u = reqwest::Url::parse(&loc).ok();
            let code = u.as_ref().and_then(|u| u.query_pairs().find(|(k, _)| k == "code").map(|(_, v)| v.to_string()));
            match code {
                Some(c) => c,
                None => {
                    let err = u.as_ref().and_then(|u| u.query_pairs().find(|(k, _)| k == "error").map(|(_, v)| v.to_string())).unwrap_or_default();
                    return Ok(fail(true, true, if err == "access_denied" { "Authorization was not granted. Open Poki and approve the connection when prompted. If no prompt appears, check that the connector link is still valid.".into() } else { format!("Authorization failed: {err}") }));
                }
            }
        }
        503 => return Ok(fail(true, false, "The relay is up, but the phone is not connected to it. Open Poki on the iPhone and check Connect.".into())),
        s => return Ok(fail(true, false, format!("Authorization answered HTTP {s}."))),
    };
    let tok = http
        .post(format!("{base}/token"))
        .form(&[("grant_type", "authorization_code"), ("code", code.as_str()), ("redirect_uri", "http://127.0.0.1/poki-setup"), ("client_id", client_id.as_str()), ("code_verifier", verifier.as_str())])
        .send()
        .await?;
    if !tok.status().is_success() {
        return Ok(fail(true, true, format!("The token step failed (HTTP {}).", tok.status())));
    }
    let tok: serde_json::Value = tok.json().await?;
    let access = tok["access_token"].as_str().unwrap_or("").to_string();
    let init = http
        .post(url)
        .bearer_auth(&access)
        .header("Accept", "application/json, text/event-stream")
        .header("MCP-Protocol-Version", "2025-06-18")
        .json(&serde_json::json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": { "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": { "name": "Poki Setup", "version": crate::VERSION } } }))
        .send()
        .await?;
    let session = init.headers().get("mcp-session-id").and_then(|v| v.to_str().ok()).map(|s| s.to_string());
    if !init.status().is_success() {
        return Ok(fail(true, true, format!("The phone answered initialize with HTTP {}.", init.status())));
    }
    let mut list = http
        .post(url)
        .bearer_auth(&access)
        .header("Accept", "application/json, text/event-stream")
        .header("MCP-Protocol-Version", "2025-06-18")
        .json(&serde_json::json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {} }));
    if let Some(s) = &session {
        list = list.header("Mcp-Session-Id", s);
    }
    let res = list.send().await?;
    let status = res.status();
    let body: serde_json::Value = res.json().await.unwrap_or(serde_json::Value::Null);
    let tools: Vec<String> = body["result"]["tools"].as_array().map(|a| a.iter().filter_map(|t| t["name"].as_str().map(|s| s.to_string())).collect()).unwrap_or_default();
    if let Some(s) = &session {
        let _ = http.delete(url).bearer_auth(&access).header("Mcp-Session-Id", s).send().await;
    }
    if !status.is_success() || tools.is_empty() {
        return Ok(fail(true, true, format!("tools/list answered HTTP {status} with no tools.")));
    }
    let detail = format!("Working: {} tools through the phone.", tools.len());
    Ok(Check { at, ok: true, relay_ok: true, phone_online: true, tools, detail })
}

pub fn record_check(url: &str, check: &Check) -> Result<()> {
    let mut list = all()?;
    for c in list.iter_mut().filter(|c| c.url == url) {
        c.last_check = Some(check.clone());
    }
    save(&list)
}

/// Ready-to-paste client setups for one link.
pub fn snippets(url: &str) -> Vec<(String, String)> {
    vec![
        ("Claude.ai".into(), "Settings → Connectors → Add custom connector → paste the link → Connect. Keep Poki online and approve the connection on the phone when prompted.".into()),
        ("Claude Code".into(), format!("claude mcp add --transport http poki \"{url}\"")),
        ("Claude Desktop (claude_desktop_config.json)".into(), serde_json::to_string_pretty(&serde_json::json!({ "mcpServers": { "poki": { "type": "http", "url": url } } })).unwrap_or_default()),
        ("Cursor (.cursor/mcp.json)".into(), serde_json::to_string_pretty(&serde_json::json!({ "mcpServers": { "poki": { "url": url } } })).unwrap_or_default()),
        ("ChatGPT".into(), "Settings → Connectors → Advanced → Developer mode → Create → paste the link as the MCP server URL, authentication OAuth.".into()),
        ("curl".into(), format!("curl -sS -X POST \"{url}\" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \\\n  -H \"Authorization: Bearer $TOKEN\" -d '{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}}'")),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    // A loopback relay exercises Setup's real HTTP request timeouts and OAuth response handling.
    async fn serve_check(approve: bool, consent_wait: std::time::Duration) -> (String, Parts, tokio::task::JoinHandle<()>) {
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let parts = Parts {
            origin: format!("http://{}", listener.local_addr().unwrap()),
            label: "a".repeat(52),
            secret: "s".repeat(43),
        };
        let url = format!("{}/v1/{}/{}/mcp", parts.origin, parts.label, parts.secret);
        let server = tokio::spawn(async move {
            let routes = [
                ("/.well-known/", "200 OK", "", "{}"),
                ("/register ", "201 Created", "", r#"{"client_id":"fixture"}"#),
                ("/authorize?", "302 Found", if approve {
                    "Location: http://127.0.0.1/poki-setup?code=synthetic\r\n"
                } else {
                    "Location: http://127.0.0.1/poki-setup?error=access_denied\r\n"
                }, ""),
                ("/token ", "200 OK", "", r#"{"access_token":"synthetic"}"#),
                ("/mcp ", "200 OK", "", "{}"),
                ("/mcp ", "200 OK", "", r#"{"result":{"tools":[{"name":"echo"}]}}"#),
            ];
            for (path, status, headers, body) in routes.into_iter().take(if approve { 6 } else { 3 }) {
                let (stream, _) = listener.accept().await.unwrap();
                let mut stream = BufReader::new(stream);
                let mut line = String::new();
                stream.read_line(&mut line).await.unwrap();
                assert!(line.contains(path), "expected {path}");
                loop {
                    line.clear();
                    let n = stream.read_line(&mut line).await.unwrap();
                    if n == 0 || line == "\r\n" { break; }
                }
                if path == "/authorize?" { tokio::time::sleep(consent_wait).await; }
                let response = format!("HTTP/1.1 {status}\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n{headers}\r\n{body}", body.len());
                stream.get_mut().write_all(response.as_bytes()).await.unwrap();
            }
        });
        (url, parts, server)
    }

    #[tokio::test]
    async fn setup_check_accepts_approval_after_old_timeout() {
        let (url, parts, server) = serve_check(true, std::time::Duration::from_secs(61)).await;
        let result = check_connector(&url, parts).await.unwrap();
        assert!(result.ok, "{}", result.detail);
        assert_eq!(result.tools, ["echo"]);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn setup_check_reports_refusal_as_ungranted_authorization() {
        let (url, parts, server) = serve_check(false, std::time::Duration::ZERO).await;
        let result = check_connector(&url, parts).await.unwrap();
        assert!(!result.ok && result.phone_online && result.relay_ok);
        assert!(result.tools.is_empty());
        assert!(result.detail.contains("Authorization was not granted"));
        assert!(!result.detail.contains("revoked"));
        server.await.unwrap();
    }

    #[test]
    fn parse_and_redact() {
        let label = "a".repeat(52);
        let url = format!("https://poki-relay.me.workers.dev/v1/{label}/{}/mcp", "s".repeat(43));
        let p = parse(&url).unwrap();
        assert_eq!(p.origin, "https://poki-relay.me.workers.dev");
        assert_eq!(p.label, label);
        assert!(redact(&url).contains("aaaaaaaa…"));
        assert!(!redact(&url).contains("sss"));
        assert!(parse("http://x/v1/a/b/mcp").is_err());
        assert!(parse("https://x/v1/short/b/mcp").is_err());
    }
}
