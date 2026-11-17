//! Anisette: the headers that tell Apple's login which "Mac" is asking. On macOS they come from
//! the system (AOSKit, as AltServer does). Elsewhere a remote anisette v3 server (the SideStore
//! community servers, or one the person runs with Provision) provisions a machine identity once
//! and signs the one-time passwords; the server never sees the Apple ID or its password.
//!
//! Protocol and header set from SideStore's omnisette (MPL-2.0) and Sideloader (GPL-3.0).
//!
//! The client info override (`CLIENT_INFO_OVERRIDE`) and re-provisioning when it changes are taken
//! from AltStore pull request 1853 (https://github.com/altstoreio/AltStore/pull/1853, AGPL-3.0),
//! with the values iloader 2.4.1 uses (https://github.com/nab138/iloader, MIT).
use crate::{Error, Result, paths};
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

pub const DEFAULT_REMOTE: &str = "https://new.ani.sidestore.io";
/// Servers tried in turn when Apple refuses one (ec -80045) or one does not answer. Checked Nov 7 2026: these hand out
/// data that matches their client info; the old ani.sidestore.io does not (Mac info, Android data).
pub const FALLBACK_REMOTES: &[&str] = &["https://new.ani.sidestore.io", "https://mac-ani.jkcoxson.com", "https://ani2.stikstore.app"];
/// Retired: Apple has refused it since October 2026.
const RETIRED_REMOTES: &[&str] = &["https://ani.sidestore.io"];
pub const ROUTING_INFO: &str = "17106176";
/// The client a remote anisette identity is provisioned and used as, in place of the server's own
/// `/v3/client_info`. Since November 2026 Apple refuses the Mac OS X 10.12.6 the SideStore servers
/// report, with -23782 ("A Mac with macOS version 10.13 or later is required"); akd on macOS 27 is
/// accepted. `None` goes back to the server's values once servers report ones Apple accepts.
pub const CLIENT_INFO_OVERRIDE: Option<(&str, &str)> =
    Some(("<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>", "akd/1.0 CFNetwork/811.5.4"));

/// One set of headers, good for about a minute.
#[derive(Debug, Clone)]
pub struct Headers {
    pub map: HashMap<String, String>,
    pub made_at: std::time::Instant,
}

impl Headers {
    pub fn fresh(&self) -> bool { self.made_at.elapsed().as_secs() < 60 }
    pub fn get(&self, key: &str) -> Option<&str> { self.map.get(key).map(|s| s.as_str()) }
    /// The `cpd` dictionary of a GSA request: the headers plus Apple's fixed flags.
    pub fn cpd(&self) -> plist::Dictionary {
        let mut d = plist::Dictionary::new();
        for (k, v) in &self.map {
            // The client description travels as a header only (as AltSign and icloud-auth do).
            if k.eq_ignore_ascii_case("X-Mme-Client-Info") || k.eq_ignore_ascii_case("User-Agent") {
                continue;
            }
            d.insert(k.clone(), plist::Value::String(v.clone()));
        }
        d.insert("bootstrap".into(), true.into());
        d.insert("icscrec".into(), true.into());
        d.insert("loc".into(), self.map.get("X-Apple-Locale").cloned().unwrap_or_else(|| "en_US".into()).into());
        d.insert("pbe".into(), false.into());
        d.insert("prkgen".into(), true.into());
        d.insert("svct".into(), "iCloud".into());
        d
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Source {
    /// macOS only: AOSKit on this Mac.
    System,
    /// An anisette v3 server.
    Remote { url: String },
}

impl Source {
    pub fn default_for_platform() -> Source {
        // macOS 27 no longer hands out AOSKit headers, so a server is the default everywhere;
        // "This Mac" stays available in Settings for older macOS.
        Source::Remote { url: DEFAULT_REMOTE.into() }
    }
}

pub struct Provider {
    source: Source,
    remote: Option<remote::Client>,
    last: Option<Headers>,
    /// `FALLBACK_REMOTES`; a test sets its own.
    fallbacks: Vec<String>,
}

impl Provider {
    pub fn new(source: Source) -> Self {
        let source = match source {
            Source::Remote { url } if RETIRED_REMOTES.contains(&url.trim_end_matches('/')) => Source::Remote { url: DEFAULT_REMOTE.into() },
            other => other,
        };
        Provider { source, remote: None, last: None, fallbacks: FALLBACK_REMOTES.iter().map(|u| u.to_string()).collect() }
    }

    /// Moves to the next fallback server after Apple refused this one or it did not answer. False
    /// when none is left.
    pub fn rotate(&mut self) -> bool {
        let current = match &self.source {
            Source::Remote { url } => url.trim_end_matches('/').to_string(),
            Source::System => String::new(),
        };
        let next = match self.fallbacks.iter().position(|u| *u == current) {
            Some(i) => self.fallbacks.get(i + 1),
            None => self.fallbacks.first(),
        };
        match next.cloned() {
            Some(u) => {
                tracing::warn!("the anisette from {current} did not work; trying {u}");
                self.source = Source::Remote { url: u };
                self.remote = None;
                self.last = None;
                true
            }
            None => false,
        }
    }

    pub fn source(&self) -> &Source { &self.source }

    /// A fresh header set, provisioning the remote identity on first use.
    pub async fn headers(&mut self) -> Result<Headers> {
        if let Some(h) = &self.last {
            if h.fresh() {
                return Ok(h.clone());
            }
        }
        // macOS can refuse to hand out headers (AOSKit gives none on some versions or without an
        // iCloud sign-in). Fall back to the default server then, so sign-in still works.
        if self.source == Source::System {
            match system::headers() {
                Ok(map) => {
                    let h = Headers { map: with_time(map), made_at: std::time::Instant::now() };
                    self.last = Some(h.clone());
                    return Ok(h);
                }
                Err(e) => {
                    tracing::warn!("system anisette failed ({e:#}); using {DEFAULT_REMOTE}");
                    self.source = Source::Remote { url: DEFAULT_REMOTE.into() };
                }
            }
        }
        // A server that does not answer is skipped for the next fallback, as one Apple refuses is.
        let mut silent = Vec::new();
        while self.remote.is_none() {
            let Source::Remote { url } = &self.source else { unreachable!() };
            match remote::Client::new(url.clone()).await {
                Ok(client) => self.remote = Some(client),
                Err(e) => {
                    tracing::warn!("{e}");
                    silent.push(url.trim_end_matches('/').to_string());
                    if !self.rotate() || silent.len() > self.fallbacks.len() {
                        if silent.len() == 1 {
                            return Err(e);
                        }
                        return Err(Error::msg(format!(
                            "None of the anisette servers answered ({}). Check this computer's internet connection, or set another server in Settings. Last error: {e}",
                            silent.join(", ")
                        )));
                    }
                }
            }
        }
        let map = self.remote.as_mut().unwrap().headers().await?;
        let h = Headers { map: with_time(map), made_at: std::time::Instant::now() };
        self.last = Some(h.clone());
        Ok(h)
    }
}

fn with_time(mut map: HashMap<String, String>) -> HashMap<String, String> {
    let now = time::OffsetDateTime::now_utc().replace_nanosecond(0).unwrap();
    map.insert("X-Apple-I-Client-Time".into(), now.format(&time::format_description::well_known::Rfc3339).unwrap_or_default());
    map.entry("X-Apple-I-TimeZone".into()).or_insert_with(|| "UTC".into());
    map.entry("X-Apple-Locale".into()).or_insert_with(|| "en_US".into());
    map.entry("X-Apple-I-SRL-NO".into()).or_insert_with(|| "0".into());
    map.entry("X-Apple-I-MD-RINFO".into()).or_insert_with(|| ROUTING_INFO.into());
    map
}

pub mod remote {
    //! Anisette v3: `GET /v3/client_info`, a one-time provisioning session over WebSocket in which
    //! this computer relays `midStartProvisioning` / `midFinishProvisioning` to Apple, then
    //! `POST /v3/get_headers` with the identifier and the provisioned `adi.pb`.
    use super::*;
    use futures_util::{SinkExt, StreamExt};

    #[derive(Deserialize)]
    struct ClientInfo {
        client_info: String,
        user_agent: String,
    }

    #[derive(Serialize, Deserialize, Default)]
    pub struct State {
        #[serde(with = "b64")]
        pub keychain_identifier: Vec<u8>,
        #[serde(default, with = "b64opt")]
        pub adi_pb: Option<Vec<u8>>,
        /// The client info `adi_pb` was provisioned as. An identity from another client info is
        /// not accepted with this one, so a change provisions a new identity.
        #[serde(default)]
        pub client_info: Option<String>,
    }

    mod b64 {
        use base64::Engine;
        use serde::{Deserialize, Deserializer, Serializer};
        pub fn serialize<S: Serializer>(v: &Vec<u8>, s: S) -> Result<S::Ok, S::Error> {
            s.serialize_str(&base64::engine::general_purpose::STANDARD.encode(v))
        }
        pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
            let s = String::deserialize(d)?;
            base64::engine::general_purpose::STANDARD.decode(s).map_err(serde::de::Error::custom)
        }
    }
    mod b64opt {
        use base64::Engine;
        use serde::{Deserialize, Deserializer, Serializer};
        pub fn serialize<S: Serializer>(v: &Option<Vec<u8>>, s: S) -> Result<S::Ok, S::Error> {
            match v {
                Some(v) => s.serialize_some(&base64::engine::general_purpose::STANDARD.encode(v)),
                None => s.serialize_none(),
            }
        }
        pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Vec<u8>>, D::Error> {
            let s: Option<String> = Option::deserialize(d)?;
            s.map(|s| base64::engine::general_purpose::STANDARD.decode(s).map_err(serde::de::Error::custom)).transpose()
        }
    }

    impl State {
        /// One identity per server: a provisioning from one server is useless on another.
        fn path(url: &str) -> Result<std::path::PathBuf> {
            let tag = hex::encode(&Sha256::digest(url.as_bytes())[..6]);
            Ok(paths::anisette_dir()?.join(format!("state-{tag}.json")))
        }
        fn vault_name(url: &str) -> String { format!("anisette-{}", hex::encode(&Sha256::digest(url.as_bytes())[..6])) }
        fn load_or_new(url: &str) -> Result<State> {
            let text = match crate::vault::installed() {
                Some(v) => v.get(&Self::vault_name(url))?.map(|b| String::from_utf8_lossy(&b).to_string()),
                None => std::fs::read_to_string(Self::path(url)?).ok(),
            };
            if let Some(text) = text {
                if let Ok(s) = serde_json::from_str::<State>(&text) {
                    if s.keychain_identifier.len() == 16 {
                        return Ok(s);
                    }
                }
            }
            use rand::RngCore;
            let mut id = vec![0u8; 16];
            rand::thread_rng().fill_bytes(&mut id);
            Ok(State { keychain_identifier: id, adi_pb: None, client_info: None })
        }
        /// This identity if it was provisioned as `client_info`, else a new one to provision.
        pub(super) fn for_client(self, client_info: &str) -> State {
            if self.adi_pb.is_some() && self.client_info.as_deref() == Some(client_info) {
                return self;
            }
            use rand::RngCore;
            let mut id = vec![0u8; 16];
            rand::thread_rng().fill_bytes(&mut id);
            State { keychain_identifier: id, adi_pb: None, client_info: Some(client_info.to_string()) }
        }
        fn save(&self, url: &str) -> Result<()> {
            if let Some(v) = crate::vault::installed() {
                return v.set(&Self::vault_name(url), &serde_json::to_vec(self)?);
            }
            let path = Self::path(url)?;
            std::fs::write(path, serde_json::to_vec_pretty(self)?)?;
            Ok(())
        }
        fn md_lu(&self) -> String { hex::encode(Sha256::digest(&self.keychain_identifier)) }
        fn device_id(&self) -> String {
            let mut b = [0u8; 16];
            b.copy_from_slice(&self.keychain_identifier);
            uuid::Uuid::from_bytes(b).to_string().to_uppercase()
        }
    }

    pub struct Client {
        url: String,
        info: ClientInfo,
        state: State,
        http: reqwest::Client,
    }

    impl Client {
        pub async fn new(url: String) -> Result<Client> {
            // reqwest and tungstenite pull in both rustls providers; pick one for the process.
            let _ = rustls::crypto::ring::default_provider().install_default();
            let url = url.trim_end_matches('/').to_string();
            let http = crate::apple::with_extra_roots(reqwest::Client::builder()).add_root_certificate(reqwest::Certificate::from_der(crate::apple::APPLE_ROOT_CA)?).http1_title_case_headers().timeout(std::time::Duration::from_secs(30)).build()?;
            let mut info: ClientInfo = http
                .get(format!("{url}/v3/client_info"))
                .send()
                .await
                .map_err(|e| Error::msg(format!("The anisette server {url} did not answer ({e}). Check the address in Settings, or try again later.")))?
                .error_for_status()?
                .json()
                .await?;
            if let Some((client_info, user_agent)) = CLIENT_INFO_OVERRIDE {
                info = ClientInfo { client_info: client_info.into(), user_agent: user_agent.into() };
            }
            let state = State::load_or_new(&url)?.for_client(&info.client_info);
            Ok(Client { url, info, state, http })
        }

        fn apple_request(&self, rb: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
            let now = time::OffsetDateTime::now_utc().replace_nanosecond(0).unwrap();
            rb.header("X-Mme-Client-Info", &self.info.client_info)
                .header("User-Agent", &self.info.user_agent)
                .header("Content-Type", "text/x-xml-plist")
                .header("X-Apple-I-MD-LU", self.state.md_lu())
                .header("X-Mme-Device-Id", self.state.device_id())
                .header("X-Apple-I-Client-Time", now.format(&time::format_description::well_known::Rfc3339).unwrap_or_default())
                .header("X-Apple-I-TimeZone", "UTC")
                .header("X-Apple-Locale", "en_US")
        }

        async fn provision(&mut self) -> Result<()> {
            let bag = self.apple_request(self.http.get("https://gsa.apple.com/grandslam/GsService2/lookup")).send().await?.bytes().await?;
            let bag: plist::Dictionary = plist::from_bytes(&bag)?;
            let urls = bag.get("urls").and_then(|u| u.as_dictionary()).ok_or_else(|| Error::msg("Apple's URL bag has no urls"))?;
            let start = urls.get("midStartProvisioning").and_then(|u| u.as_string()).ok_or_else(|| Error::msg("no midStartProvisioning"))?.to_string();
            let finish = urls.get("midFinishProvisioning").and_then(|u| u.as_string()).ok_or_else(|| Error::msg("no midFinishProvisioning"))?.to_string();
            let ws_url = format!("{}/v3/provisioning_session", self.url).replacen("https://", "wss://", 1).replacen("http://", "ws://", 1);
            let (mut ws, _) = tokio_tungstenite::connect_async_tls_with_config(&ws_url, None, false, Some(ws_connector())).await.map_err(|e| Error::msg(format!("anisette provisioning: {e}")))?;
            #[derive(Deserialize)]
            #[serde(tag = "result")]
            enum Input {
                GiveIdentifier,
                GiveStartProvisioningData,
                GiveEndProvisioningData { cpim: String },
                ProvisioningSuccess { adi_pb: String },
                Error { message: Option<String> },
            }
            let b64 = base64::engine::general_purpose::STANDARD;
            loop {
                let Some(msg) = ws.next().await else { return Err(Error::msg("the anisette server closed the provisioning session")) };
                let msg = msg.map_err(|e| Error::msg(format!("anisette provisioning: {e}")))?;
                let text = match msg {
                    tokio_tungstenite::tungstenite::Message::Text(t) => t.to_string(),
                    tokio_tungstenite::tungstenite::Message::Close(_) => return Err(Error::msg("the anisette server closed the provisioning session")),
                    _ => continue,
                };
                match serde_json::from_str::<Input>(&text)? {
                    Input::GiveIdentifier => {
                        let out = serde_json::json!({ "identifier": b64.encode(&self.state.keychain_identifier) });
                        ws.send(tokio_tungstenite::tungstenite::Message::Text(out.to_string().into())).await.map_err(|e| Error::msg(e.to_string()))?;
                    }
                    Input::GiveStartProvisioningData => {
                        let body = plist_body(plist::Dictionary::new());
                        let res = self.apple_request(self.http.post(&start)).body(body).send().await?.bytes().await?;
                        let res: plist::Dictionary = plist::from_bytes(&res)?;
                        let spim = res.get("Response").and_then(|r| r.as_dictionary()).and_then(|r| r.get("spim")).and_then(|s| s.as_string()).ok_or_else(|| Error::msg("Apple gave no spim"))?;
                        let out = serde_json::json!({ "spim": spim });
                        ws.send(tokio_tungstenite::tungstenite::Message::Text(out.to_string().into())).await.map_err(|e| Error::msg(e.to_string()))?;
                    }
                    Input::GiveEndProvisioningData { cpim } => {
                        let mut req = plist::Dictionary::new();
                        req.insert("cpim".into(), cpim.into());
                        let res = self.apple_request(self.http.post(&finish)).body(plist_body(req)).send().await?.bytes().await?;
                        let res: plist::Dictionary = plist::from_bytes(&res)?;
                        let r = res.get("Response").and_then(|r| r.as_dictionary()).ok_or_else(|| Error::msg("Apple gave no Response"))?;
                        let out = serde_json::json!({ "ptm": r.get("ptm").and_then(|s| s.as_string()).unwrap_or(""), "tk": r.get("tk").and_then(|s| s.as_string()).unwrap_or("") });
                        ws.send(tokio_tungstenite::tungstenite::Message::Text(out.to_string().into())).await.map_err(|e| Error::msg(e.to_string()))?;
                    }
                    Input::ProvisioningSuccess { adi_pb } => {
                        self.state.adi_pb = Some(b64.decode(adi_pb.trim()).map_err(|e| Error::msg(format!("bad adi_pb: {e}")))?);
                        self.state.save(&self.url)?;
                        let _ = ws.close(None).await;
                        return Ok(());
                    }
                    Input::Error { message } => return Err(Error::msg(format!("anisette provisioning failed: {}", message.unwrap_or_default()))),
                }
            }
        }

        pub async fn headers(&mut self) -> Result<HashMap<String, String>> {
            if self.state.adi_pb.is_none() {
                self.provision().await?;
            }
            match self.fetch().await {
                Ok(h) => Ok(h),
                Err(Error::Message(m)) if m.contains("-45061") || m.contains("not provisioned") => {
                    self.state.adi_pb = None;
                    self.provision().await?;
                    self.fetch().await
                }
                Err(e) => Err(e),
            }
        }

        async fn fetch(&self) -> Result<HashMap<String, String>> {
            let b64 = base64::engine::general_purpose::STANDARD;
            #[derive(Deserialize)]
            #[serde(tag = "result")]
            enum Out {
                GetHeadersError { message: String },
                Headers {
                    #[serde(rename = "X-Apple-I-MD-M")]
                    machine_id: String,
                    #[serde(rename = "X-Apple-I-MD")]
                    otp: String,
                    #[serde(rename = "X-Apple-I-MD-RINFO")]
                    rinfo: String,
                },
            }
            let body = serde_json::json!({ "identifier": b64.encode(&self.state.keychain_identifier), "adi_pb": b64.encode(self.state.adi_pb.as_ref().unwrap()) });
            let out: Out = self.http.post(format!("{}/v3/get_headers", self.url)).json(&body).send().await?.json().await?;
            match out {
                Out::GetHeadersError { message } => Err(Error::msg(format!("anisette: {message}"))),
                Out::Headers { machine_id, otp, rinfo } => Ok(HashMap::from([
                    ("X-Apple-I-MD-M".to_string(), machine_id),
                    ("X-Apple-I-MD".to_string(), otp),
                    ("X-Apple-I-MD-RINFO".to_string(), rinfo),
                    ("X-Apple-I-MD-LU".to_string(), self.state.md_lu()),
                    ("X-Mme-Device-Id".to_string(), self.state.device_id()),
                    ("X-Mme-Client-Info".to_string(), self.info.client_info.clone()),
                    // GSA must see the same client the anisette data belongs to (Apple rejects a
                    // mismatch with -80045 since October 2026).
                    ("User-Agent".to_string(), self.info.user_agent.clone()),
                ])),
            }
        }
    }

    /// Web roots plus `SSL_CERT_FILE`, as the HTTP clients use.
    fn ws_connector() -> tokio_tungstenite::Connector {
        let mut roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
        if let Ok(path) = std::env::var("SSL_CERT_FILE") {
            if let Ok(file) = std::fs::File::open(&path) {
                for cert in rustls_pemfile::certs(&mut std::io::BufReader::new(file)).flatten() {
                    let _ = roots.add(cert);
                }
            }
        }
        let config = rustls::ClientConfig::builder().with_root_certificates(roots).with_no_client_auth();
        tokio_tungstenite::Connector::Rustls(std::sync::Arc::new(config))
    }

    fn plist_body(request: plist::Dictionary) -> Vec<u8> {
        let mut root = plist::Dictionary::new();
        root.insert("Header".into(), plist::Value::Dictionary(plist::Dictionary::new()));
        root.insert("Request".into(), plist::Value::Dictionary(request));
        let mut out = Vec::new();
        let _ = plist::to_writer_xml(&mut out, &plist::Value::Dictionary(root));
        out
    }
}

pub mod system {
    //! macOS: the same private frameworks AltServer uses (AOSKit's AOSUtilities, AuthKit's AKDevice).
    use super::*;

    #[cfg(target_os = "macos")]
    pub fn headers() -> Result<HashMap<String, String>> {
        use objc2::{class, msg_send, rc::Retained, runtime::AnyObject};
        use objc2_foundation::NSString;
        unsafe {
            // Load the frameworks; the classes are then visible to the runtime.
            let _aos = libloading::Library::new("/System/Library/PrivateFrameworks/AOSKit.framework/AOSKit").map_err(|e| Error::msg(format!("AOSKit: {e}")))?;
            let _ak = libloading::Library::new("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit").map_err(|e| Error::msg(format!("AuthKit: {e}")))?;
            let utilities = objc2::runtime::AnyClass::get(c"AOSUtilities").ok_or_else(|| Error::msg("AOSUtilities is not available on this Mac"))?;
            let ak_device = objc2::runtime::AnyClass::get(c"AKDevice").ok_or_else(|| Error::msg("AKDevice is not available on this Mac"))?;
            let dsid = NSString::from_str("-2");
            let headers: Option<Retained<AnyObject>> = msg_send![utilities, retrieveOTPHeadersForDSID: &*dsid];
            let headers = headers.ok_or_else(|| Error::msg("macOS gave no anisette headers. Sign in to iCloud on this Mac once, then try again."))?;
            let value = |key: &str| -> Option<String> {
                let k = NSString::from_str(key);
                let v: Option<Retained<NSString>> = msg_send![&*headers, valueForKey: &*k];
                v.map(|s| s.to_string())
            };
            let mut map = HashMap::new();
            map.insert("X-Apple-I-MD".into(), value("X-Apple-MD").ok_or_else(|| Error::msg("no X-Apple-MD from AOSKit"))?);
            map.insert("X-Apple-I-MD-M".into(), value("X-Apple-MD-M").ok_or_else(|| Error::msg("no X-Apple-MD-M from AOSKit"))?);
            let serial: Option<Retained<NSString>> = msg_send![utilities, machineSerialNumber];
            if let Some(s) = serial {
                map.insert("X-Apple-I-SRL-NO".into(), s.to_string());
            }
            let device: Option<Retained<AnyObject>> = msg_send![ak_device, currentDevice];
            if let Some(device) = device {
                let lu: Option<Retained<NSString>> = msg_send![&*device, localUserUUID];
                if let Some(lu) = lu { map.insert("X-Apple-I-MD-LU".into(), lu.to_string()); }
                let desc: Option<Retained<NSString>> = msg_send![&*device, serverFriendlyDescription];
                if let Some(d) = desc { map.insert("X-Mme-Client-Info".into(), d.to_string()); }
                let udid: Option<Retained<NSString>> = msg_send![&*device, uniqueDeviceIdentifier];
                if let Some(u) = udid { map.insert("X-Mme-Device-Id".into(), u.to_string()); }
                let locale: Option<Retained<AnyObject>> = msg_send![&*device, locale];
                if let Some(locale) = locale {
                    let id: Option<Retained<NSString>> = msg_send![&*locale, localeIdentifier];
                    if let Some(id) = id { map.insert("X-Apple-Locale".into(), id.to_string()); }
                }
            }
            let _ = class!(NSObject);
            Ok(map)
        }
    }

    #[cfg(not(target_os = "macos"))]
    pub fn headers() -> Result<HashMap<String, String>> {
        Err(Error::msg("System anisette is only available on macOS. Choose an anisette server in Settings."))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_identity_provisioned_as_another_client_is_provisioned_again() {
        let (client_info, _) = CLIENT_INFO_OVERRIDE.unwrap();
        // Saved before the override: no client_info, an adi.pb from the server's Mac OS X 10.12.6.
        let old: remote::State = serde_json::from_str(r#"{"keychain_identifier":"AAAAAAAAAAAAAAAAAAAAAA==","adi_pb":"AQID"}"#).unwrap();
        let fresh = old.for_client(client_info);
        assert_eq!(fresh.adi_pb, None);
        assert_ne!(fresh.keychain_identifier, vec![0u8; 16]);
        assert_eq!(fresh.client_info.as_deref(), Some(client_info));
        // Provisioned as this client: kept.
        let mut done = fresh;
        done.adi_pb = Some(vec![1, 2, 3]);
        let id = done.keychain_identifier.clone();
        let kept = done.for_client(client_info);
        assert_eq!((kept.keychain_identifier, kept.adi_pb), (id, Some(vec![1, 2, 3])));
    }

    #[tokio::test]
    async fn a_server_that_does_not_answer_is_skipped_for_the_next_fallback() {
        // Three local ports nothing listens on: each connection is refused at once.
        let mut urls = Vec::new();
        for _ in 0..3 {
            let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            urls.push(format!("http://127.0.0.1:{}", l.local_addr().unwrap().port()));
        }
        let mut p = Provider::new(Source::Remote { url: urls[0].clone() });
        p.fallbacks = urls.clone();
        let e = p.headers().await.unwrap_err().to_string();
        assert_eq!(p.source(), &Source::Remote { url: urls[2].clone() });
        assert!(e.starts_with("None of the anisette servers answered"), "{e}");
        assert!(urls.iter().all(|u| e.contains(u.as_str())), "{e}");
    }
}
