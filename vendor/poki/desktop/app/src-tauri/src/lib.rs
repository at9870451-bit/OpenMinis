//! The Poki Setup window: Tauri over poki-setup-core. Commands are thin: each one calls the core
//! and turns its `Progress` into events the page draws.
mod commands;

use std::sync::Arc;
use tauri::{Emitter, Manager};
use tokio::sync::Mutex;

/// What lives for the whole app: the signed-in account, a sign-in waiting for its code, the
/// pairing hand-off server, the log stream.
pub struct State {
    pub signer: Mutex<Option<poki_setup_core::setup::Signer>>,
    pub pending: Mutex<Option<poki_setup_core::apple::gsa::Pending>>,
    pub handoff: Mutex<Option<poki_setup_core::pairshare::Server>>,
    pub logs: Mutex<Option<tokio::task::JoinHandle<()>>>,
    pub busy: Mutex<bool>,
}

pub type Shared = Arc<State>;

pub fn run() {
    let state: Shared = Arc::new(State { signer: Mutex::new(None), pending: Mutex::new(None), handoff: Mutex::new(None), logs: Mutex::new(None), busy: Mutex::new(false) });
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(
            tauri_plugin_log::Builder::new()
                .level(log::LevelFilter::Info)
                .target(tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Folder { path: poki_setup_core::paths::log_dir().unwrap_or_else(|_| std::env::temp_dir()), file_name: Some("poki-setup".into()) }))
                .target(tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Stdout))
                .build(),
        )
        .manage(state.clone())
        .setup(move |app| {
            let _window = app.get_webview_window("main").expect("main window");
            #[cfg(target_os = "macos")]
            {
                use window_vibrancy::{NSVisualEffectMaterial, NSVisualEffectState, apply_vibrancy};
                let _ = apply_vibrancy(&_window, NSVisualEffectMaterial::Sidebar, Some(NSVisualEffectState::Active), None);
            }
            #[cfg(target_os = "windows")]
            {
                let _ = window_vibrancy::apply_mica(&_window, None).or_else(|_| window_vibrancy::apply_acrylic(&_window, Some((10, 60, 160, 160))));
            }
            tray(app)?;
            keeper_loop(app.handle().clone(), state.clone());
            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the window keeps the app (and the weekly renewal) alive in the menu bar / tray.
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let _ = window.hide();
                api.prevent_close();
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::app_info,
            commands::phones,
            commands::pair,
            commands::share_pairing,
            commands::stop_sharing,
            commands::approve_certificate_replacement,
            commands::devmode,
            commands::account,
            commands::sign_in,
            commands::finish_sign_in,
            commands::sign_out,
            commands::teams,
            commands::choose_team,
            commands::set_anisette,
            commands::install,
            commands::records,
            commands::renew,
            commands::forget_phone,
            commands::latest_release,
            commands::relay_state,
            commands::relay_worker,
            commands::relay_token_saved,
            commands::relay_forget_token,
            commands::relay_accounts,
            commands::relay_deploy,
            commands::relay_check,
            commands::connectors,
            commands::connector_add,
            commands::connector_forget,
            commands::connector_check,
            commands::connector_snippets,
            commands::logs_start,
            commands::logs_stop,
            commands::mount_ddi,
            commands::support_bundle,
            commands::agent_prompt,
            commands::check_update,
            commands::install_update,
            commands::channels,
            commands::set_channel,
            commands::qr_svg,
        ])
        .run(tauri::generate_context!())
        .expect("Poki Setup could not start");
}

fn tray(app: &tauri::App) -> tauri::Result<()> {
    use tauri::menu::{MenuBuilder, MenuItemBuilder};
    use tauri::tray::TrayIconBuilder;
    let open = MenuItemBuilder::with_id("open", "Open Poki Setup").build(app)?;
    let renew = MenuItemBuilder::with_id("renew", "Renew Poki now").build(app)?;
    let quit = MenuItemBuilder::with_id("quit", "Quit Poki Setup").build(app)?;
    let menu = MenuBuilder::new(app).item(&open).item(&renew).separator().item(&quit).build()?;
    let mut builder = TrayIconBuilder::with_id("main").menu(&menu).tooltip("Poki Setup").show_menu_on_left_click(true);
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    #[cfg(target_os = "macos")]
    {
        builder = builder.icon_as_template(false);
    }
    builder
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main(app),
            "renew" => {
                let _ = app.emit("renew-requested", ());
                show_main(app);
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    Ok(())
}

fn show_main(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

/// Every six hours: when a phone is due and the account can sign without a person, renew it.
fn keeper_loop(app: tauri::AppHandle, state: Shared) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(30)).await;
        loop {
            let due = poki_setup_core::keeper::due().unwrap_or_default();
            if !due.is_empty() {
                let _ = app.emit("keeper", serde_json::json!({ "due": due.iter().map(|r| r.udid.clone()).collect::<Vec<_>>() }));
                if !*state.busy.lock().await {
                    let mut guard = state.signer.lock().await;
                    if guard.is_none() {
                        *guard = poki_setup_core::setup::Signer::open().ok();
                    }
                    if let Some(signer) = guard.as_mut() {
                        if signer.account.password.is_some() {
                            let reporter = commands::reporter(&app, "keeper");
                            for (udid, res) in poki_setup_core::setup::renew_due(signer, &reporter).await {
                                let _ = app.emit("keeper-result", serde_json::json!({ "udid": udid, "ok": res.is_ok(), "error": res.err().map(|e| e.to_string()) }));
                            }
                        }
                    }
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(6 * 3600)).await;
        }
    });
}
