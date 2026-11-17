//! The phone's logs: live syslog lines, Poki's own log files from its container, crash reports.
use super::Phone;
use crate::Result;
use idevice::{IdeviceService, crashreportcopymobile::CrashReportCopyMobileClient, syslog_relay::SyslogRelayClient};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

/// Streams syslog lines into `tx`, stopping when the receiver is dropped or `filter` is given and
/// a line does not contain it (lines are only sent when they match).
pub async fn syslog(phone: &Phone, filter: Option<String>, tx: mpsc::Sender<String>) -> Result<()> {
    let provider = phone.provider()?;
    let mut relay = SyslogRelayClient::connect(&*provider).await?;
    loop {
        let line = relay.next().await?;
        if let Some(f) = &filter {
            if !line.contains(f.as_str()) {
                continue;
            }
        }
        if tx.send(line).await.is_err() {
            break;
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrashReport {
    pub name: String,
    pub bytes: usize,
}

/// Crash reports whose names mention Poki (`Poki-…ips`, `PokiTunnel-…`).
pub async fn poki_crash_reports(phone: &Phone) -> Result<Vec<String>> {
    let provider = phone.provider()?;
    let mut crashes = CrashReportCopyMobileClient::connect(&*provider).await?;
    let names = crashes.ls(None).await?;
    Ok(names.into_iter().filter(|n| n.starts_with("Poki")).collect())
}

pub async fn pull_crash_report(phone: &Phone, name: &str) -> Result<Vec<u8>> {
    let provider = phone.provider()?;
    let mut crashes = CrashReportCopyMobileClient::connect(&*provider).await?;
    Ok(crashes.pull(name).await?)
}

/// Poki's log files from its container (`Library/Application Support/Poki/logs` and `Documents`).
pub async fn poki_log_files(phone: &Phone, bundle_id: &str) -> Result<Vec<(String, Vec<u8>)>> {
    let mut out = Vec::new();
    for dir in [format!("{}/logs", super::container::SUPPORT_DIR), "Documents".to_string(), super::container::SUPPORT_DIR.to_string()] {
        let Ok(names) = super::container::list(phone, bundle_id, &dir).await else { continue };
        for name in names {
            if name.ends_with(".log") || name.ends_with(".txt") || name.ends_with(".jsonl") {
                if let Ok(bytes) = super::container::read_file(phone, bundle_id, &format!("{dir}/{name}")).await {
                    out.push((format!("{dir}/{name}"), bytes));
                }
            }
        }
    }
    Ok(out)
}
