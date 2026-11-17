//! AltSign's rule (AGPL-3.0): the signed entitlements are the profile's, kept only where the app
//! asks for the key, plus the identity keys Apple always wants.
use plist::{Dictionary, Value};

const ALWAYS: &[&str] = &["application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "keychain-access-groups"];

/// `requested` is what the app was built asking for (from Poki-signing.zip or the defaults);
/// `profile` is the profile's Entitlements dictionary.
pub fn merge(requested: &Dictionary, profile: &Dictionary) -> Dictionary {
    let mut out = Dictionary::new();
    for (k, v) in profile {
        if ALWAYS.contains(&k.as_str()) || requested.contains_key(k) {
            out.insert(k.clone(), v.clone());
        }
    }
    // Keys the app asks for that the profile does not carry are dropped: signing with them would
    // make the app refuse to launch. The caller reports what was dropped.
    out
}

pub fn dropped<'a>(requested: &'a Dictionary, merged: &Dictionary) -> Vec<&'a str> {
    requested.keys().filter(|k| !merged.contains_key(*k)).map(|k| k.as_str()).collect()
}

pub fn to_xml(d: &Dictionary) -> String {
    let mut out = Vec::new();
    plist::to_writer_xml(&mut out, &Value::Dictionary(d.clone())).expect("plist xml");
    String::from_utf8(out).expect("utf8")
}

/// What Poki asks for when no entitlements export is at hand.
pub fn poki_defaults(app_group: &str) -> Dictionary {
    let mut d = Dictionary::new();
    d.insert("com.apple.security.application-groups".into(), Value::Array(vec![app_group.into()]));
    d
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn keeps_identity_and_requested_only() {
        let mut profile = Dictionary::new();
        profile.insert("application-identifier".into(), "T.nz.zheha.poki.T".into());
        profile.insert("com.apple.developer.team-identifier".into(), "T".into());
        profile.insert("get-task-allow".into(), true.into());
        profile.insert("keychain-access-groups".into(), Value::Array(vec!["T.*".into()]));
        profile.insert("com.apple.security.application-groups".into(), Value::Array(vec!["group.nz.zheha.poki.T".into()]));
        profile.insert("com.apple.developer.associated-domains".into(), "*".into());
        let requested = poki_defaults("group.nz.zheha.poki");
        let merged = merge(&requested, &profile);
        assert_eq!(merged.len(), 5);
        assert!(!merged.contains_key("com.apple.developer.associated-domains"));
        assert!(dropped(&requested, &merged).is_empty());
        let mut asks_more = requested.clone();
        asks_more.insert("com.apple.developer.networking.networkextension".into(), Value::Array(vec![]));
        let merged = merge(&asks_more, &profile);
        assert_eq!(dropped(&asks_more, &merged), vec!["com.apple.developer.networking.networkextension"]);
    }
}
