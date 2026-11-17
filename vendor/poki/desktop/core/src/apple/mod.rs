//! The Apple account and the developer portal.
//!
//! [`gsa`] signs in (SRP, 2FA) and gets the Xcode app token; [`portal`] talks to
//! developerservices2 with it; [`identity`] makes the signing key and matches Apple's certificate
//! to it; [`anisette`] provides the "this is a Mac" headers both need; [`store`] keeps the session
//! in the OS keychain.
pub mod anisette;
pub mod gsa;
pub mod identity;
pub mod portal;
pub mod srp;
pub mod store;

/// Apple's 2006 root, added to the web roots for gsa.apple.com and developerservices2.apple.com.
pub const APPLE_ROOT_CA: &[u8] = include_bytes!("../../certs/AppleRootCA.der");

/// Also trust the certificates in `SSL_CERT_FILE` when it is set, so the app works behind a
/// company proxy that re-signs TLS (and in CI containers).
pub fn with_extra_roots(mut b: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
    if let Ok(path) = std::env::var("SSL_CERT_FILE") {
        if let Ok(pem) = std::fs::read(&path) {
            let text = String::from_utf8_lossy(&pem);
            let mut added = 0;
            for block in text.split("-----END CERTIFICATE-----") {
                if let Some(start) = block.find("-----BEGIN CERTIFICATE-----") {
                    let one = format!("{}-----END CERTIFICATE-----\n", &block[start..]);
                    if let Ok(c) = reqwest::Certificate::from_pem(one.as_bytes()) {
                        b = b.add_root_certificate(c);
                        added += 1;
                    }
                }
            }
            tracing::debug!("trusting {added} extra roots from {path}");
        }
    }
    b
}

pub fn http_client() -> crate::Result<reqwest::Client> {
    Ok(with_extra_roots(reqwest::Client::builder())
        .add_root_certificate(reqwest::Certificate::from_der(APPLE_ROOT_CA)?)
        .user_agent("Xcode")
        .http1_title_case_headers()
        .timeout(std::time::Duration::from_secs(60))
        .build()?)
}

/// What Xcode sends: the app Apple's GSA issues tokens for, and its version headers.
pub const XCODE_APP_ID: &str = "com.apple.gs.xcode.auth";
pub const XCODE_VERSION: &str = "16.2 (16C5032a)";
