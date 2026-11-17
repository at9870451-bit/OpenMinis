//! A `.mobileprovision` is a CMS SignedData whose content is a plist.
use crate::{Error, Result};
use der::Decode;

#[derive(Debug, Clone)]
pub struct Profile {
    pub uuid: String,
    pub name: String,
    pub team_id: String,
    pub app_id: String,
    pub entitlements: plist::Dictionary,
    pub expires_at: i64,
    pub raw: Vec<u8>,
}

pub fn parse(raw: &[u8]) -> Result<Profile> {
    let ci = cms::content_info::ContentInfo::from_der(raw).map_err(|e| Error::Sign(format!("profile is not CMS: {e}")))?;
    let sd: cms::signed_data::SignedData = ci.content.decode_as().map_err(|e| Error::Sign(format!("profile SignedData: {e}")))?;
    let any = sd.encap_content_info.econtent.ok_or_else(|| Error::Sign("profile has no content".into()))?;
    let octets: der::asn1::OctetString = any.decode_as().map_err(|e| Error::Sign(format!("profile content: {e}")))?;
    let plist_bytes = octets.as_bytes();
    let dict: plist::Dictionary = plist::from_bytes(plist_bytes)?;
    let s = |k: &str| dict.get(k).and_then(|v| v.as_string()).unwrap_or("").to_string();
    let ents = dict.get("Entitlements").and_then(|e| e.as_dictionary()).cloned().unwrap_or_default();
    let app_id = ents.get("application-identifier").and_then(|v| v.as_string()).unwrap_or("").to_string();
    let team_id = dict
        .get("TeamIdentifier")
        .and_then(|t| t.as_array())
        .and_then(|a| a.first())
        .and_then(|v| v.as_string())
        .map(|s| s.to_string())
        .or_else(|| app_id.split('.').next().map(|s| s.to_string()))
        .unwrap_or_default();
    let expires_at = dict.get("ExpirationDate").and_then(|d| d.as_date()).map(|d| std::time::SystemTime::from(d).duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)).unwrap_or(0);
    Ok(Profile { uuid: s("UUID"), name: s("Name"), team_id, app_id, entitlements: ents, expires_at, raw: raw.to_vec() })
}
