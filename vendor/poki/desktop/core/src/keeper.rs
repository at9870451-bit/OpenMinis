//! The phones this computer set up, and when each needs Poki signed again. A free team's
//! profile lasts 7 days; a paid team's a year. Renewal is due with 2 days left.
use crate::{Result, paths};
use serde::{Deserialize, Serialize};

pub const RENEW_WITH_DAYS_LEFT: i64 = 2;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Record {
    pub udid: String,
    pub phone_name: String,
    pub ios: String,
    pub apple_id: String,
    pub team_id: String,
    pub team_name: String,
    pub team_is_free: bool,
    pub bundle_id: String,
    pub app_group: String,
    pub version: String,
    pub build: String,
    pub release_tag: String,
    /// Unix seconds.
    pub signed_at: i64,
    pub profile_expires_at: i64,
    pub last_checked_at: Option<i64>,
    pub last_error: Option<String>,
    /// The phone's last known Wi-Fi address, for renewals without the cable.
    pub wifi_address: Option<String>,
    pub pairing_handed_off: bool,
}

impl Record {
    pub fn days_left(&self) -> i64 { (self.profile_expires_at - now()) / 86_400 }
    pub fn is_due(&self) -> bool { self.days_left() <= RENEW_WITH_DAYS_LEFT }
    pub fn is_expired(&self) -> bool { self.profile_expires_at <= now() }
}

pub fn now() -> i64 { time::OffsetDateTime::now_utc().unix_timestamp() }

fn path() -> Result<std::path::PathBuf> { Ok(paths::state_dir()?.join("phones.json")) }

pub fn all() -> Result<Vec<Record>> {
    Ok(std::fs::read_to_string(path()?).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default())
}

pub fn get(udid: &str) -> Result<Option<Record>> { Ok(all()?.into_iter().find(|r| r.udid == udid)) }

pub fn put(record: Record) -> Result<()> {
    let mut list = all()?;
    list.retain(|r| r.udid != record.udid);
    list.push(record);
    list.sort_by(|a, b| a.phone_name.cmp(&b.phone_name));
    std::fs::write(path()?, serde_json::to_vec_pretty(&list)?)?;
    Ok(())
}

pub fn remove(udid: &str) -> Result<()> {
    let mut list = all()?;
    list.retain(|r| r.udid != udid);
    std::fs::write(path()?, serde_json::to_vec_pretty(&list)?)?;
    Ok(())
}

pub fn note_check(udid: &str, error: Option<String>) -> Result<()> {
    if let Some(mut r) = get(udid)? {
        r.last_checked_at = Some(now());
        r.last_error = error;
        put(r)?;
    }
    Ok(())
}

pub fn due() -> Result<Vec<Record>> { Ok(all()?.into_iter().filter(|r| r.is_due()).collect()) }

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn due_and_store() {
        let (_lock, _dir) = crate::paths::test_home();
        let mk = |udid: &str, days: i64| Record {
            udid: udid.into(),
            phone_name: "Phone".into(),
            ios: "26.1".into(),
            apple_id: "a@b".into(),
            team_id: "T".into(),
            team_name: "T".into(),
            team_is_free: true,
            bundle_id: "nz.zheha.poki.T".into(),
            app_group: "group.nz.zheha.poki.T".into(),
            version: "0.2.7".into(),
            build: "70".into(),
            release_tag: "ios-v0.2.7".into(),
            signed_at: now(),
            profile_expires_at: now() + days * 86_400,
            last_checked_at: None,
            last_error: None,
            wifi_address: None,
            pairing_handed_off: false,
        };
        put(mk("A", 7)).unwrap();
        put(mk("B", 1)).unwrap();
        assert_eq!(all().unwrap().len(), 2);
        let d = due().unwrap();
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].udid, "B");
        remove("A").unwrap();
        assert_eq!(all().unwrap().len(), 1);
    }
}
