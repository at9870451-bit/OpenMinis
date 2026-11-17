//! For agents on this computer (Claude Code, Codex and the like): the prompt a person hands them,
//! and `next`, which reads this computer's state and says what is done, what comes next and who
//! has to act. The command line (`poki-setup next`), the bridge and the app all use it.
use crate::{device, keeper, release, setup};
use serde::Serialize;

/// The prompt people paste into their agent. `poki-setup` paths in it are the default install
/// places; [`prompt_for`] puts the real path of this copy in.
pub const PROMPT: &str = include_str!("../../AGENT-PROMPT.md");

/// The prompt with this copy's own command line tool named first, when it is known.
pub fn prompt_for(cli: Option<&std::path::Path>) -> String {
    match cli {
        Some(p) => format!("{PROMPT}\nOn this computer the tool is at: \"{}\"\n", p.display()),
        None => PROMPT.to_string(),
    }
}

/// The command line tool that ships next to this program (the app bundle's or the install
/// folder's `poki-setup`), when there is one.
pub fn cli_path() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let name = if cfg!(windows) { "poki-setup.exe" } else { "poki-setup" };
    if exe.file_name().map(|n| n == name).unwrap_or(false) {
        return Some(exe);
    }
    let p = exe.parent()?.join(name);
    p.exists().then_some(p)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Who {
    Agent,
    Person,
}

/// One thing left to do.
#[derive(Debug, Clone, Serialize)]
pub struct Step {
    /// Stable: `sign_in`, `connect`, `trust`, `developer_mode`, `install`, `renew`, `update`.
    pub id: &'static str,
    pub who: Who,
    /// What to run, ready to paste, when the agent can do it (or start it).
    pub command: Option<String>,
    /// What to tell the person, in one or two sentences.
    pub say: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct PhoneState {
    pub udid: String,
    pub name: Option<String>,
    pub ios: Option<String>,
    pub paired: bool,
    pub developer_mode: Option<bool>,
    /// Poki as this computer installed it, if it did.
    pub poki: Option<PokiState>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PokiState {
    pub version: String,
    pub build: String,
    pub days_left: i64,
    pub due: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct Next {
    /// Poki is installed, signed and nothing is waiting.
    pub ready: bool,
    pub poki_setup: String,
    pub channel: String,
    pub signed_in: bool,
    pub account: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_error: Option<String>,
    pub phones: Vec<PhoneState>,
    /// A newer Poki Setup on the channel, when there is one.
    pub update: Option<String>,
    /// What is left, in order. The first one is the one to do now.
    pub steps: Vec<Step>,
    /// One sentence on where things stand.
    pub summary: String,
}

fn cmd(cli: &str, rest: &str) -> Option<String> { Some(format!("\"{cli}\" {rest}")) }

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AccountCheck {
    SignedIn,
    SignedOut,
    Unavailable(String),
}

/// Reads this computer's state (account, phones, what it installed, updates) without changing
/// anything, and lists what is left. `udid` narrows it to one phone.
pub async fn next(udid: Option<&str>) -> Next {
    let cli = cli_path().map(|p| p.display().to_string()).unwrap_or_else(|| "poki-setup".into());
    let mut phones = vec![];
    for p in device::Phone::list().await.unwrap_or_default() {
        if udid.map(|u| u != p.udid).unwrap_or(false) {
            continue;
        }
        let facts = device::info::read(&p).await.ok();
        let poki = keeper::get(&p.udid).ok().flatten().map(|r| PokiState { version: r.version.clone(), build: r.build.clone(), days_left: r.days_left(), due: r.is_due() });
        phones.push(PhoneState {
            udid: p.udid.clone(),
            name: facts.as_ref().map(|f| f.name.clone()),
            ios: facts.as_ref().map(|f| f.ios.clone()),
            paired: facts.as_ref().map(|f| f.paired_with_this_computer).unwrap_or(false),
            developer_mode: facts.as_ref().and_then(|f| f.developer_mode),
            poki,
        });
    }
    let update = release::desktop_update().await.ok().filter(|u| u.newer).and_then(|u| u.latest);
    let channel = release::channel().title().to_string();
    build_next(&cli, setup::Signer::open(), phones, update, channel)
}

fn build_next(cli: &str, open: crate::Result<setup::Signer>, phones: Vec<PhoneState>, update: Option<String>, channel: String) -> Next {
    let (signed_in, account, account_error, account_check) = match open {
        Ok(s) => {
            let signed_in = s.signed_in();
            let check = if signed_in { AccountCheck::SignedIn } else { AccountCheck::SignedOut };
            (signed_in, s.account.apple_id().map(str::to_string), None, check)
        }
        Err(e) => {
            let msg = e.to_string();
            (false, None, Some(msg.clone()), AccountCheck::Unavailable(msg))
        }
    };
    let steps = plan_with_account(cli, &account_check, &phones, update.as_deref());
    let ready = account_error.is_none() && steps.iter().all(|s| s.id == "update");
    let summary = match (ready, phones.first().and_then(|p| p.poki.as_ref())) {
        (true, Some(p)) => format!("Poki {} ({}) is installed and signed for {} more days. Poki Setup renews it while this computer is on.", p.version, p.build, p.days_left),
        _ => steps.first().map(|s| s.say.clone()).unwrap_or_default(),
    };
    Next { ready, poki_setup: crate::display_version(&crate::full_version()), channel, signed_in, account, account_error, phones, update, steps, summary }
}

/// The steps left, from what [`next`] read. Kept apart so it can be tested without a phone.
pub fn plan(cli: &str, signed_in: bool, phones: &[PhoneState], update: Option<&str>) -> Vec<Step> {
    let check = if signed_in { AccountCheck::SignedIn } else { AccountCheck::SignedOut };
    plan_with_account(cli, &check, phones, update)
}

pub fn plan_with_account(cli: &str, account: &AccountCheck, phones: &[PhoneState], update: Option<&str>) -> Vec<Step> {
    let mut steps = vec![];
    match account {
        AccountCheck::SignedIn => {}
        AccountCheck::SignedOut => {
            steps.push(Step {
                id: "sign_in",
                who: Who::Person,
                command: cmd(cli, "login <apple-id-email> --keep-password"),
                say: "Poki Setup needs your Apple Account to sign Poki. Run the command in your own terminal window: it asks for your password and the code Apple sends you. Your password stays on this computer.".into(),
            });
        }
        AccountCheck::Unavailable(err) => {
            steps.push(Step {
                id: "unlock_keychain",
                who: Who::Person,
                command: None,
                say: format!("{err} Unlock your Mac login keychain and choose Always Allow if prompted, then run `{cli} next` again."),
            });
        }
    }
    match phones.first() {
        None => steps.push(Step { id: "connect", who: Who::Person, command: None, say: "Plug your iPhone or iPad into this computer with a cable and unlock it.".into() }),
        Some(p) => {
            let u = &p.udid;
            if !p.paired {
                steps.push(Step { id: "trust", who: Who::Agent, command: cmd(cli, &format!("pair --udid {u} --json")), say: "Unlock the phone. When it asks whether to trust this computer, tap Trust and enter your passcode.".into() });
            }
            if p.developer_mode != Some(true) {
                steps.push(Step { id: "developer_mode", who: Who::Agent, command: cmd(cli, &format!("devmode --udid {u} --json")), say: "Developer Mode is needed. If the phone has a passcode, open Settings > Privacy & Security > Developer Mode, turn it on and tap Restart; after the restart, tap Turn On and enter your passcode.".into() });
            }
            match &p.poki {
                None => steps.push(Step { id: "install", who: Who::Agent, command: cmd(cli, &format!("install --udid {u} --json")), say: "Poki Setup now signs Poki for your Apple Account and installs it. Keep the phone plugged in and unlocked. With a free Apple Account, trust the developer afterwards in Settings > General > VPN & Device Management, then open Poki once. When Poki first opens it asks for Automation Mode: tap Continue and enter the iPhone passcode on iOS's screen. If you cancel, Poki asks again only after you turn it on again.".into() }),
                Some(k) if k.due => steps.push(Step { id: "renew", who: Who::Agent, command: cmd(cli, &format!("renew --udid {u} --json")), say: format!("Poki's signature ends in {} days; Poki Setup signs it again now.", k.days_left.max(0)) }),
                Some(_) => {}
            }
        }
    }
    if let Some(v) = update {
        steps.push(Step { id: "update", who: Who::Agent, command: cmd(cli, "update --json"), say: format!("Poki Setup {} is available; it updates itself and restarts.", crate::display_version(v)) });
    }
    steps
}

#[cfg(test)]
mod tests {
    use super::*;

    fn phone(paired: bool, dev: Option<bool>, poki: Option<(i64, bool)>) -> PhoneState {
        PhoneState { udid: "U1".into(), name: Some("iPhone".into()), ios: Some("26.1".into()), paired, developer_mode: dev, poki: poki.map(|(d, due)| PokiState { version: "0.2.8".into(), build: "501".into(), days_left: d, due }) }
    }

    #[test]
    fn steps_follow_the_setup_order() {
        let ids = |s: Vec<Step>| s.into_iter().map(|s| s.id).collect::<Vec<_>>();
        assert_eq!(ids(plan("p", false, &[], None)), ["sign_in", "connect"]);
        assert_eq!(ids(plan("p", true, &[phone(false, None, None)], None)), ["trust", "developer_mode", "install"]);
        assert_eq!(ids(plan("p", true, &[phone(true, Some(true), None)], None)), ["install"]);
        assert_eq!(ids(plan("p", true, &[phone(true, Some(true), Some((2, true)))], None)), ["renew"]);
        assert!(plan("p", true, &[phone(true, Some(true), Some((6, false)))], None).is_empty());
        assert_eq!(ids(plan("p", true, &[phone(true, Some(true), Some((6, false)))], Some("0.2.1-320"))), ["update"]);
        let s = plan("/A B/poki-setup", true, &[phone(true, Some(false), None)], None);
        assert_eq!(s[0].command.as_deref(), Some("\"/A B/poki-setup\" devmode --udid U1 --json"));
        assert_eq!(s[0].who, Who::Agent);
    }

    #[test]
    fn prompt_names_the_tool() {
        assert!(PROMPT.contains("poki-setup next --json"));
        assert!(prompt_for(Some(std::path::Path::new("/x/poki-setup"))).ends_with("\"/x/poki-setup\"\n"));
    }

    #[test]
    fn keychain_error_is_not_treated_as_signed_out() {
        struct DeniedKeychain;
        impl crate::apple::store::KeychainBackend for DeniedKeychain {
            fn get(&self, _key: &str) -> std::result::Result<String, crate::apple::store::KeychainErr> {
                Err(crate::apple::store::KeychainErr::Failure("User canceled the operation.".into()))
            }
            fn set(&self, _key: &str, _value: &str) -> std::result::Result<(), crate::apple::store::KeychainErr> { Ok(()) }
            fn delete(&self, _key: &str) -> std::result::Result<(), crate::apple::store::KeychainErr> { Ok(()) }
        }

        let err = crate::apple::store::load_with_keychain(&DeniedKeychain).unwrap_err();
        assert_eq!(err.kind(), "keychain");
        let next = build_next("p", Err(err), vec![], None, "Beta".into());
        assert!(!next.ready);
        assert!(next.account_error.is_some());
        assert!(!next.steps.iter().any(|s| s.id == "sign_in"));
        assert_eq!(next.steps.first().map(|s| s.id), Some("unlock_keychain"));
    }
}
