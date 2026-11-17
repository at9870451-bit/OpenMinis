//! Downloads through the updater without installing or contacting Apple.
use poki_setup_core::{release, Reporter};

#[tokio::main]
async fn main() {
    let result = async {
        let selected = release::latest().await?;
        if std::env::args().any(|arg| arg == "--metadata-only") {
            return Ok(serde_json::json!({"mode": "metadata-only", "source": selected.source,
                "source_notice": selected.source_notice, "version": selected.version,
                "build": selected.build, "channel": selected.channel}));
        }
        let (ipa, signing) = release::fetch(&selected, &Reporter::stderr()).await?;
        let desktop = release::fetch_desktop_update(release::desktop_update().await?, &Reporter::stderr()).await?;
        let relay = release::relay_worker(&release::RelayFor {
            tag: Some(selected.tag.clone()), version: Some(selected.version.clone()), build: Some(selected.build.clone()),
        }).await?;
        Ok::<_, poki_setup_core::Error>(serde_json::json!({
            "mode": "downloads-only", "source": selected.source, "source_notice": selected.source_notice,
            "version": selected.version, "build": selected.build, "channel": selected.channel,
            "ipa_saved": ipa.is_file(), "signing_saved": signing.is_some_and(|p| p.is_file()),
            "installer_saved": desktop.is_file(), "relay_verified": relay.is_some(),
        }))
    }.await;
    match result {
        Ok(record) => println!("{record}"),
        Err(error) => {
            eprintln!("Update source verification failed ({})", error.kind());
            std::process::exit(1);
        }
    }
}
