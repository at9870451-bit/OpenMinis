//! A support bundle: this app's logs, the phones it knows, the app and OS versions, and the
//! phone's Poki logs when it is connected. Review the archive before sharing. It can contain
//! device identifiers, local paths, relay addresses, and raw logs.
use crate::{Result, paths};
use std::io::Write;

pub fn mask_email(s: &str) -> String {
    match s.split_once('@') {
        Some((u, d)) => format!("{}…@{d}", u.chars().take(2).collect::<String>()),
        None => "…".into(),
    }
}

pub struct Bundle {
    pub path: std::path::PathBuf,
    pub entries: Vec<String>,
}

pub async fn build(phone: Option<&crate::device::Phone>, out_dir: &std::path::Path) -> Result<Bundle> {
    let stamp = time::OffsetDateTime::now_utc().format(&time::macros::format_description!("[year][month][day]-[hour][minute][second]")).unwrap_or_default();
    let path = out_dir.join(format!("poki-setup-support-{stamp}.zip"));
    let file = std::fs::File::create(&path)?;
    let mut zip = zip::ZipWriter::new(file);
    let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    let mut entries = vec![];
    let mut add = |zip: &mut zip::ZipWriter<std::fs::File>, name: &str, bytes: &[u8]| -> Result<()> {
        zip.start_file(name, opts).map_err(|e| crate::Error::msg(e.to_string()))?;
        zip.write_all(bytes)?;
        entries.push(name.to_string());
        Ok(())
    };

    let account = crate::apple::store::load().unwrap_or_default();
    let summary = serde_json::json!({
        "poki_setup": crate::VERSION,
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "made_at": crate::keeper::now(),
        "apple_id": account.apple_id().map(mask_email),
        "team_id": account.team_id,
        "anisette": account.anisette,
        "xcode_token_valid": account.xcode_token.as_ref().map(|t| t.valid_for(0)),
        "relay": crate::relay::remembered().ok().flatten().map(|r| r.address),
        "connectors": crate::mcp::all().unwrap_or_default().iter().map(|c| serde_json::json!({"name": c.name, "url": crate::mcp::redact(&c.url), "last_check": c.last_check})).collect::<Vec<_>>(),
    });
    add(&mut zip, "summary.json", serde_json::to_string_pretty(&summary)?.as_bytes())?;
    let phones: Vec<_> = crate::keeper::all()?.into_iter().map(|mut r| {
        r.apple_id = mask_email(&r.apple_id);
        r
    }).collect();
    add(&mut zip, "phones.json", serde_json::to_string_pretty(&phones)?.as_bytes())?;
    if let Ok(dir) = paths::log_dir() {
        if let Ok(rd) = std::fs::read_dir(dir) {
            for e in rd.flatten() {
                if let Ok(bytes) = std::fs::read(e.path()) {
                    add(&mut zip, &format!("logs/{}", e.file_name().to_string_lossy()), &bytes)?;
                }
            }
        }
    }
    if let Some(phone) = phone {
        match crate::device::info::read(phone).await {
            Ok(facts) => add(&mut zip, "phone/facts.json", serde_json::to_string_pretty(&facts)?.as_bytes())?,
            Err(e) => add(&mut zip, "phone/facts-error.txt", e.to_string().as_bytes())?,
        }
        if let Ok(Some(rec)) = crate::keeper::get(&phone.udid) {
            if let Ok(files) = crate::device::logs::poki_log_files(phone, &rec.bundle_id).await {
                for (name, bytes) in files {
                    add(&mut zip, &format!("phone/poki-logs/{name}"), &bytes)?;
                }
            }
        }
        if let Ok(names) = crate::device::logs::poki_crash_reports(phone).await {
            for name in names.iter().take(5) {
                if let Ok(bytes) = crate::device::logs::pull_crash_report(phone, name).await {
                    add(&mut zip, &format!("phone/crashes/{name}"), &bytes)?;
                }
            }
        }
    }
    zip.finish().map_err(|e| crate::Error::msg(e.to_string()))?;
    Ok(Bundle { path, entries })
}

#[cfg(test)]
mod tests {
    #[test]
    fn masks() {
        assert_eq!(super::mask_email("someone@example.com"), "so…@example.com");
    }
}
