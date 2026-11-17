//! iPhone History, first tests (GitHub issue 356): what is on screen, read as text through the
//! accessibility audit service (ax.rs) over the loopback and the pairing. Nothing here opens an
//! XCTest session, so a read is not automation and should not raise the "Automation Running" banner;
//! the tests exist to learn on a real iPhone whether that holds, how long a read takes, and whether
//! reads keep coming while Poki is in the background.
//!
//! Two requests, each on a tunnel of its own (never the launcher's):
//! - `read_once`: one read. Answers with the seconds it took, the apps on screen and the number of
//!   elements. The screen's text is counted, and returned only when `include_text` is set.
//! - `watch`: one subscription kept open for `seconds`. Answers with every tree dump as it arrived.
//! - `run`: a read every `interval_ms` for `duration_s`. Reports each read as it is made, then the
//!   reads made, the failures and the longest gap between two reads.
//!
//! Nothing is stored. Password fields and keyboard keys are left out of the text before it is counted.

use crate::{
    ax,
    device::{Device, Failure, Pairing},
};
use serde_json::{Value, json};
use std::{
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
    net::IpAddr,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant, SystemTime},
};

/// UIAccessibility's private secure text field trait (AXTraitSecureTextField in idb's AXTraits.h).
const SECURE_TRAIT: u64 = 1 << 24;
/// A key of the on-screen keyboard.
const KEY_TRAIT: u64 = 1 << 5;
/// UIAccessibilityTraitHeader.
const HEADER_TRAIT: u64 = 1 << 16;

const OPEN_WITHIN: Duration = Duration::from_secs(20);
/// Apps iOS keeps listing among those on screen while the phone is unlocked and something else is in
/// front (the Sleep screen, during and after Sleep Focus). History does not read a locked phone, so
/// their elements are never the screen the owner is looking at.
const LOCK_SCREEN_ONLY: [&str; 1] = ["com.apple.SleepLockScreen"];

fn lock_screen_only(app: &Value) -> bool {
    app["bundle_id"].as_str().is_some_and(|id| LOCK_SCREEN_ONLY.contains(&id))
}

/// One subscription of a run's read.
const DEFAULT_READ_WITHIN: Duration = Duration::from_secs(10);

/// The run in progress. A new run, or `cancel`, moves it on, and the older run ends at its next look.
static RUN: AtomicU64 = AtomicU64::new(0);

/// Ends the background run, if one is going. It answers with what it measured so far.
pub fn cancel() {
    RUN.fetch_add(1, Ordering::SeqCst);
}

struct Target {
    address: IpAddr,
    pairing_file: PathBuf,
    host_name: Option<String>,
}

impl Target {
    fn from(request: &Value) -> Result<Self, Failure> {
        let address = request["device_address"].as_str().unwrap_or("10.7.0.1");
        let address = address.parse().map_err(|_| Failure::new(format!("{address} is not an address")).code("config"))?;
        let pairing_file = request["pairing_file"].as_str().ok_or_else(|| Failure::new("this iPhone is not paired yet").fix(crate::device::PAIRING_FIX).code("pairing"))?;
        Ok(Self { address, pairing_file: pairing_file.into(), host_name: request["host_name"].as_str().map(String::from) })
    }

    async fn open(&self) -> Result<Device, Failure> {
        let mut pairing = Pairing::read(&self.pairing_file, self.host_name.as_deref())?;
        let device = Device::open(self.address, &mut pairing, OPEN_WITHIN).await?;
        if !device.rsd.services.contains_key(ax::SERVICE) {
            return Err(Failure::new("this iPhone does not list the accessibility audit service")
                .fix("The service comes with the developer disk image. Open Setup and wait until the image is ready, then try again.")
                .code("no_service"));
        }
        Ok(device)
    }
}

fn milliseconds(duration: Duration) -> u64 {
    duration.as_millis() as u64
}

/// No subscription gave a tree: the last one's own error, or what it counted.
fn no_tree(attempts: &[ax::Attempt]) -> Failure {
    let detail = match attempts.last() {
        Some(last) => match &last.error {
            Some(error) => error.clone(),
            None => format!("no tree in {} subscriptions; the last got {} messages, {} dumps, {} roots, {} nodes", attempts.len(), last.messages, last.dumps, last.roots, last.nodes),
        },
        None => "no subscription was made".into(),
    };
    Failure::new(detail).code("read")
}

/// Runs one request. `emit` gets a line for every read of a run.
pub async fn handle(request: Value, emit: impl Fn(Value) + Send + Sync + 'static) -> Result<Value, Failure> {
    match request["op"].as_str().unwrap_or("") {
        "read_once" => read_once(&request).await,
        "watch" => watch(&request).await,
        "run" => run(&request, emit).await,
        other => Err(Failure::new(format!("unknown history request \"{other}\"")).code("config")),
    }
}

/// The waits of one read's subscriptions. The reader on a computer gives each subscription two
/// seconds and then makes a new one. On the phone itself, with no automation session, accessibility
/// may first have to start, so a short wait is tried twice and then a long one.
const READ_WINDOWS: [Duration; 3] = [Duration::from_secs(2), Duration::from_secs(2), Duration::from_secs(15)];

fn windows(request: &Value) -> Vec<Duration> {
    match request["windows_ms"].as_array() {
        Some(list) if !list.is_empty() => list.iter().filter_map(Value::as_u64).map(|ms| Duration::from_millis(ms.clamp(200, 60_000))).take(8).collect(),
        _ => READ_WINDOWS.to_vec(),
    }
}

/// The accessibility services this iPhone lists, for a read that got no tree.
fn accessibility_services(device: &Device) -> Vec<&String> {
    let mut names: Vec<&String> = device.rsd.services.keys().filter(|name| name.to_lowercase().contains("accessib") || name.contains("axAudit")).collect();
    names.sort();
    names
}

async fn read_once(request: &Value) -> Result<Value, Failure> {
    let target = Target::from(request)?;
    let windows = windows(request);
    let include_text = request["include_text"].as_bool().unwrap_or(false);
    let asked = Instant::now();
    let mut device = target.open().await?;
    let connect_ms = milliseconds(asked.elapsed());
    let asked = Instant::now();
    let (tree, attempts) = ax::read_tree_traced(&mut device.adapter, &device.rsd, false, &windows).await;
    let read_ms = milliseconds(asked.elapsed());
    let Some(tree) = tree else {
        // Not a failure of the request: what the phone did send is the answer the test is for.
        return Ok(json!({"tree": false, "connect_ms": connect_ms, "read_ms": read_ms, "attempts": attempts, "services": accessibility_services(&device)}));
    };
    // A second read on the open tunnel: what a read costs once the connection is up, as a loop pays.
    let asked = Instant::now();
    let (again, second) = ax::read_tree_traced(&mut device.adapter, &device.rsd, false, &windows).await;
    let again_ms = again.is_some().then(|| milliseconds(asked.elapsed()));
    let mut answer = summarize(&tree, include_text);
    answer["tree"] = true.into();
    answer["connect_ms"] = connect_ms.into();
    answer["read_ms"] = read_ms.into();
    answer["second_read_ms"] = json!(again_ms);
    answer["attempts"] = json!(attempts);
    answer["second_attempts"] = json!(second);
    Ok(answer)
}

/// One subscription kept open for `seconds`, whatever arrives: the answer is how the tree grew.
async fn watch(request: &Value) -> Result<Value, Failure> {
    let target = Target::from(request)?;
    let seconds = request["seconds"].as_u64().unwrap_or(30).clamp(2, 300);
    let asked = Instant::now();
    let mut device = target.open().await?;
    let connect_ms = milliseconds(asked.elapsed());
    let (tree, attempts) = ax::read_tree_held(&mut device.adapter, &device.rsd, false, &[Duration::from_secs(seconds)], true).await;
    let mut answer = match tree {
        Some(tree) => summarize(&tree, false),
        None => json!({}),
    };
    answer["tree"] = answer.get("elements").is_some().into();
    answer["connect_ms"] = connect_ms.into();
    answer["attempts"] = json!(attempts);
    answer["services"] = json!(accessibility_services(&device));
    Ok(answer)
}

async fn run(request: &Value, emit: impl Fn(Value)) -> Result<Value, Failure> {
    let target = Target::from(request)?;
    let interval = Duration::from_millis(request["interval_ms"].as_u64().unwrap_or(5000).clamp(1000, 600_000));
    let duration = Duration::from_secs(request["duration_s"].as_u64().unwrap_or(1800).clamp(10, 86_400));
    let windows = match request["windows_ms"].as_array() {
        Some(_) => windows(request),
        None => vec![DEFAULT_READ_WITHIN],
    };
    let me = RUN.fetch_add(1, Ordering::SeqCst) + 1;
    let mut stats = RunStats::default();
    let mut device: Option<Device> = None;
    // Wall time, not the runtime's clock: a suspended app's time must show up as a gap.
    let started = SystemTime::now();
    let since_start = || SystemTime::now().duration_since(started).unwrap_or_default();
    let mut last_good: Option<Duration> = None;
    let mut last_text: Option<u64> = None;
    let points: Option<Vec<(f64, f64)>> = request["direct_points"].as_array().map(|points| points.iter().filter_map(|point| Some((point[0].as_f64()?, point[1].as_f64()?))).collect());
    let mut direct: Option<ax::direct::Direct> = None;
    let include_text = request["include_text"].as_bool().unwrap_or(false);
    let include_tree = request["include_tree"].as_bool().unwrap_or(false);
    let mut ended = "finished";
    loop {
        if RUN.load(Ordering::SeqCst) != me {
            ended = "stopped";
            break;
        }
        let at = since_start();
        if at >= duration {
            break;
        }
        let asked = Instant::now();
        let mut line = json!({"n": stats.reads + stats.failures + 1, "at_s": at.as_secs()});
        let result = async {
            if device.is_none() {
                device = Some(target.open().await?);
                stats.connections += 1;
            }
            let open = device.as_mut().unwrap();
            // With points to hit test, the app is found the way the screen shows it and read whole;
            // the service's own dump can name the wrong app.
            if let Some(points) = &points {
                // One subscription serves every read of the run; a read that fails ends it.
                let mut trace = ax::direct::Trace::default();
                if direct.is_none() {
                    trace.stage = "subscribe";
                    direct = Some(ax::direct::Direct::connect(&mut open.adapter, &open.rsd).await.map_err(|error| Failure::new(format!("no tree at subscribe: {error}")).code("read"))?);
                }
                return direct.as_mut().unwrap().front(points, &mut trace).await.map_err(|error| Failure::new(format!("no tree at {}: {error}", trace.stage)).code("read"));
            }
            let (tree, attempts) = ax::read_tree_traced(&mut open.adapter, &open.rsd, false, &windows).await;
            tree.ok_or_else(|| no_tree(&attempts))
        }
        .await;
        let took = milliseconds(asked.elapsed());
        match result {
            Ok(tree) => {
                let summary = summarize(&tree, true);
                let text = hash_of(&summary["text"]);
                let changed = last_text != Some(text);
                last_text = Some(text);
                let now = since_start();
                stats.good(took, now.saturating_sub(last_good.unwrap_or(now)), changed);
                last_good = Some(now);
                line["ok"] = true.into();
                line["ms"] = took.into();
                line["elements"] = summary["elements"].clone();
                line["app"] = front_name(&summary);
                line["changed"] = changed.into();
                // The capture loop asks for the text itself, and gets it only for a screen that changed.
                if include_text && changed {
                    line["text"] = summary["text"].clone();
                    line["title"] = title_of(&tree);
                }
                // The tree itself, compact, when the capture keeps trees: only for a changed screen.
                if include_tree && changed {
                    line["tree"] = compact(&tree);
                }
            }
            Err(failure) => {
                // A screen that shows no app (locked or off) is an answer, and the connection stays.
                // Any other failure ends the tunnel; the next read opens a new one.
                if !failure.detail.contains("no point of the screen") {
                    if let Some(mut old) = direct.take() {
                        let _ = tokio::time::timeout(Duration::from_secs(1), old.close()).await;
                    }
                    device = None;
                }
                stats.failures += 1;
                stats.last_error = Some(failure.detail.clone());
                line["ok"] = false.into();
                line["ms"] = took.into();
                line["error"] = failure.detail.into();
                line["code"] = json!(failure.code);
            }
        }
        emit(line);
        // Waits in short pieces, so Stop is answered at once.
        while asked.elapsed() < interval && RUN.load(Ordering::SeqCst) == me {
            tokio::time::sleep(interval.saturating_sub(asked.elapsed()).min(Duration::from_millis(250))).await;
        }
    }
    if let Some(mut open) = direct.take() {
        let _ = tokio::time::timeout(Duration::from_secs(1), open.close()).await;
    }
    let mut answer = stats.json();
    answer["ended"] = ended.into();
    answer["ran_s"] = since_start().as_secs().into();
    answer["interval_ms"] = milliseconds(interval).into();
    // The time since the last read counts too: a run that stopped reading ends with a long gap.
    if let Some(last) = last_good {
        let tail = milliseconds(since_start().saturating_sub(last));
        if tail > answer["longest_gap_ms"].as_u64().unwrap_or(0) {
            answer["longest_gap_ms"] = tail.into();
        }
    }
    Ok(answer)
}

#[derive(Default)]
pub(crate) struct RunStats {
    pub reads: u64,
    pub failures: u64,
    pub changed: u64,
    pub connections: u64,
    pub longest_gap_ms: u64,
    pub total_ms: u64,
    pub slowest_ms: u64,
    pub last_error: Option<String>,
}

impl RunStats {
    pub(crate) fn good(&mut self, took_ms: u64, gap: Duration, changed: bool) {
        self.reads += 1;
        self.total_ms += took_ms;
        self.slowest_ms = self.slowest_ms.max(took_ms);
        self.longest_gap_ms = self.longest_gap_ms.max(milliseconds(gap));
        if changed {
            self.changed += 1;
        }
    }

    pub(crate) fn json(&self) -> Value {
        json!({
            "reads": self.reads,
            "failures": self.failures,
            "changed": self.changed,
            "connections": self.connections,
            "longest_gap_ms": self.longest_gap_ms,
            "average_ms": if self.reads == 0 { 0 } else { self.total_ms / self.reads },
            "slowest_ms": self.slowest_ms,
            "last_error": self.last_error,
        })
    }
}

fn hash_of(value: &Value) -> u64 {
    let mut hasher = DefaultHasher::new();
    value.to_string().hash(&mut hasher);
    hasher.finish()
}

fn front_name(summary: &Value) -> Value {
    let app = if summary["front"].is_object() { &summary["front"] } else { &summary["applications"][0] };
    app["bundle_id"]
        .as_str()
        .filter(|id| {
            id.contains('.') && id.split('.').all(|part| !part.is_empty() && part.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-'))
        })
        .map(Value::from)
        .unwrap_or(Value::Null)
}

/// The screen's title: its first heading that is not a password field.
fn title_of(tree: &Value) -> Value {
    let empty = vec![];
    tree["elements"]
        .as_array()
        .unwrap_or(&empty)
        .iter()
        .filter(|element| element["traits"].as_u64().unwrap_or(0) & HEADER_TRAIT != 0 && !is_secure(element))
        .find_map(|element| element["label"].as_str().map(str::trim).filter(|label| !label.is_empty()))
        .map(Value::from)
        .unwrap_or(Value::Null)
}

/// Words that name a secret, in an element's label or identifier.
const SECRET_NAMES: [&str; 8] = ["password", "passcode", "verification code", "one-time code", "密码", "密碼", "验证码", "驗證碼"];

/// A password field, by its role or trait, or any element with a value whose name says it holds a
/// secret. A direct read carries no element type, and a web page's password field or a password
/// shown in clear may not set the trait, so the name is checked too.
fn is_secure(element: &Value) -> bool {
    if element["role"] == "SecureTextField" || element["traits"].as_u64().unwrap_or(0) & SECURE_TRAIT != 0 {
        return true;
    }
    let has_value = element["value"].as_str().is_some_and(|value| !value.trim().is_empty());
    has_value
        && ["label", "identifier"].iter().any(|field| {
            let name = element[*field].as_str().unwrap_or("").to_lowercase();
            SECRET_NAMES.iter().any(|secret| name.contains(secret))
        })
}

fn is_key(element: &Value) -> bool {
    element["role"] == "Key" || element["traits"].as_u64().unwrap_or(0) & KEY_TRAIT != 0
}

/// What a read holds, without the tree itself: the apps on screen, the one in front when the tree
/// names a single app, the number of elements, and the screen's text in reading order. Password
/// fields and keyboard keys give no text. The text is returned only when asked for.
pub fn summarize(tree: &Value, include_text: bool) -> Value {
    let empty = vec![];
    let all = tree["elements"].as_array().unwrap_or(&empty);
    // Elements come in reading order with their depth, so an app's own elements follow it, deeper.
    let mut elements: Vec<&Value> = vec![];
    let mut hidden_below: Option<u64> = None;
    for element in all {
        let depth = element["depth"].as_u64().unwrap_or(0);
        if hidden_below.is_some_and(|below| depth > below) {
            continue;
        }
        hidden_below = (element["role"] == "Application" && lock_screen_only(element)).then_some(depth);
        if hidden_below.is_none() {
            elements.push(element);
        }
    }
    let mut lines: Vec<String> = vec![];
    let mut secure = 0;
    for element in &elements {
        if is_secure(element) {
            secure += 1;
            continue;
        }
        if is_key(element) || element["role"] == "Application" {
            continue;
        }
        for field in ["label", "value"] {
            let Some(text) = element[field].as_str().map(str::trim).filter(|text| !text.is_empty()) else { continue };
            if lines.last().map(String::as_str) != Some(text) {
                lines.push(text.to_string());
            }
        }
    }
    let applications: Vec<Value> = tree["applications"]
        .as_array()
        .unwrap_or(&empty)
        .iter()
        .filter(|app| !lock_screen_only(app))
        .map(|app| json!({"name": app["name"], "bundle_id": app["bundle_id"], "pid": app["pid"]}))
        .collect();
    // In front: the one app left on screen once the lock screen's own are set aside.
    let front = match applications.as_slice() {
        [app] => app.clone(),
        _ => Value::Null,
    };
    let mut answer = json!({
        "elements": elements.len(),
        "applications": applications,
        "front": front,
        "text_lines": lines.len(),
        "text_characters": lines.iter().map(|line| line.chars().count()).sum::<usize>(),
        "secure_fields_left_out": secure,
    });
    if include_text {
        answer["text"] = json!(lines);
    }
    answer
}

/// The tree as the capture keeps it: one row per element in reading order,
/// `[depth, role, label, value, x, y, width, height]`, numbers rounded to whole points. What
/// `summarize` leaves out is left out here too: elements under an app that only the lock screen
/// shows, keyboard keys, and the value of a password field (its row stays, without label or value).
pub fn compact(tree: &Value) -> Value {
    let empty = vec![];
    let all = tree["elements"].as_array().unwrap_or(&empty);
    let mut rows: Vec<Value> = vec![];
    let mut hidden_below: Option<u64> = None;
    for element in all {
        let depth = element["depth"].as_u64().unwrap_or(0);
        if hidden_below.is_some_and(|below| depth > below) {
            continue;
        }
        hidden_below = (element["role"] == "Application" && lock_screen_only(element)).then_some(depth);
        if hidden_below.is_some() || is_key(element) {
            continue;
        }
        let secure = is_secure(element);
        let text = |field: &str| if secure { "" } else { element[field].as_str().map(str::trim).unwrap_or("") };
        let number = |field: &str| element["frame"][field].as_f64().map(|n| n.round() as i64).unwrap_or(0);
        rows.push(json!([
            depth,
            element["role"].as_str().unwrap_or(""),
            text("label"),
            text("value"),
            number("x"),
            number("y"),
            number("width"),
            number("height"),
        ]));
    }
    Value::Array(rows)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree() -> Value {
        json!({
            "source": "accessibility",
            "applications": [{"object_id": "o1", "name": "Notes", "bundle_id": "com.apple.mobilenotes", "pid": 412}],
            "foreground_app": {"object_id": "o1", "name": "Notes", "bundle_id": "com.apple.mobilenotes", "pid": 412},
            "elements": [
                {"role": "Application", "label": "Notes"},
                {"role": "StaticText", "label": "Shopping list", "traits": 1u64 << 16},
                {"role": "TextView", "label": "Note", "value": "Milk\nEggs"},
                {"role": "StaticText", "label": "Shopping list"},
                {"role": "StaticText", "label": "Shopping list"},
                {"role": "SecureTextField", "label": "Password", "value": "hunter2"},
                {"role": "TextField", "label": "Passcode", "value": "1234", "traits": SECURE_TRAIT},
                {"role": "Key", "label": "q"},
                {"role": "Other", "label": "w", "traits": KEY_TRAIT},
                {"role": "Button", "label": "  "},
                {"role": "Button", "label": "Done"},
            ],
        })
    }

    #[test]
    fn a_compact_tree_keeps_structure_and_leaves_out_secrets_and_keys() {
        let rows = compact(&tree());
        let rows = rows.as_array().unwrap();
        // Eleven elements, less the two keyboard keys.
        assert_eq!(rows.len(), 9);
        assert_eq!(rows[2], json!([0, "TextView", "Note", "Milk\nEggs", 0, 0, 0, 0]));
        assert_eq!(rows[5], json!([0, "SecureTextField", "", "", 0, 0, 0, 0]));
        assert_eq!(rows[6], json!([0, "TextField", "", "", 0, 0, 0, 0]));
        assert!(!rows.iter().any(|row| row[3] == "hunter2" || row[3] == "1234"));
    }

    #[test]
    fn a_summary_counts_the_screen_and_keeps_the_text_out_unless_asked() {
        let summary = summarize(&tree(), false);
        assert_eq!(summary["elements"], 11);
        assert_eq!(summary["front"]["bundle_id"], "com.apple.mobilenotes");
        assert_eq!(summary["applications"].as_array().unwrap().len(), 1);
        assert!(summary.get("text").is_none());
        assert_eq!(summary["text_lines"], 5);
    }

    #[test]
    fn a_value_named_as_a_secret_gives_no_text_without_the_password_trait() {
        let tree = json!({"elements": [
            {"role": "Other", "label": "Verification Code", "value": "482913"},
            {"label": "密码", "value": "s3cret"},
            {"role": "StaticText", "label": "Password"},
        ]});
        let summary = summarize(&tree, true);
        assert_eq!(summary["text"], json!(["Password"]));
        assert_eq!(summary["secure_fields_left_out"], 2);
        let rows = compact(&tree).to_string();
        assert!(!rows.contains("482913") && !rows.contains("s3cret"));
    }

    #[test]
    fn password_fields_and_keyboard_keys_give_no_text() {
        let summary = summarize(&tree(), true);
        let text: Vec<&str> = summary["text"].as_array().unwrap().iter().map(|line| line.as_str().unwrap()).collect();
        assert_eq!(text, ["Shopping list", "Note", "Milk\nEggs", "Shopping list", "Done"]);
        assert_eq!(summary["secure_fields_left_out"], 2);
        let all = summary.to_string();
        assert!(!all.contains("hunter2") && !all.contains("1234"));
    }

    #[test]
    fn an_app_identity_never_falls_back_to_a_display_name_or_pid() {
        for app in [
            json!({"name": "com.example.bank", "pid": 412}),
            json!({"pid": 412}),
            json!({"bundle_id": "", "name": "Notes"}),
            json!({"bundle_id": "Notes"}),
            json!({"bundle_id": "no app name, pid 412"}),
            json!({"bundle_id": "com.example bank"}),
            json!({"bundle_id": "com..bank"}),
            json!({"bundle_id": ".com.bank"}),
            json!({"bundle_id": "com.bank."}),
            json!({"bundle_id": "com.bank/app"}),
            json!({"bundle_id": "com.b\u{e4}nk"}),
        ] {
            for summary in [json!({"front": app}), json!({"applications": [app]})] {
                assert_eq!(front_name(&summary), Value::Null, "{summary}");
            }
        }
        assert_eq!(front_name(&json!({"front": {"bundle_id": "com.example.Bank-2"}})), "com.example.Bank-2");
    }

    #[test]
    fn several_apps_on_screen_leave_the_front_one_unnamed() {
        let mut tree = tree();
        tree["foreground_app"] = Value::Null;
        tree["applications"] = json!([{"name": "SpringBoard", "bundle_id": "com.apple.springboard", "pid": 60}, {"name": "Notes", "bundle_id": "com.apple.mobilenotes", "pid": 412}]);
        let summary = summarize(&tree, false);
        assert!(summary["front"].is_null());
        assert_eq!(front_name(&summary), "com.apple.springboard");
    }

    #[test]
    fn the_sleep_screen_behind_an_app_is_not_part_of_the_screen() {
        let tree = json!({
            "applications": [{"name": "Sleep", "bundle_id": "com.apple.SleepLockScreen", "pid": 90}, {"name": "Notes", "bundle_id": "com.apple.mobilenotes", "pid": 412}],
            "foreground_app": null,
            "elements": [
                {"role": "Application", "label": "Sleep", "bundle_id": "com.apple.SleepLockScreen", "depth": 0},
                {"role": "StaticText", "label": "Good night", "depth": 1},
                {"role": "Button", "label": "Dismiss", "depth": 2},
                {"role": "Application", "label": "Notes", "bundle_id": "com.apple.mobilenotes", "depth": 0},
                {"role": "StaticText", "label": "Shopping list", "depth": 1},
            ],
        });
        let summary = summarize(&tree, true);
        assert_eq!(summary["elements"], 2);
        assert_eq!(summary["text"], json!(["Shopping list"]));
        assert_eq!(summary["front"]["bundle_id"], "com.apple.mobilenotes");
        assert_eq!(summary["applications"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn an_empty_or_unexpected_tree_is_an_empty_summary() {
        let summary = summarize(&json!({}), true);
        assert_eq!(summary["elements"], 0);
        assert_eq!(summary["text_lines"], 0);
        assert!(front_name(&summary).is_null());
    }

    #[test]
    fn a_read_without_a_tree_says_what_the_last_subscription_got() {
        let quiet = ax::Attempt { messages: 2, ..Default::default() };
        assert!(no_tree(&[quiet.clone(), quiet]).detail.contains("no tree in 2 subscriptions; the last got 2 messages"));
        let broken = ax::Attempt { error: Some("connection reset".into()), ..Default::default() };
        assert_eq!(no_tree(&[broken]).detail, "connection reset");
        assert_eq!(windows(&json!({})), READ_WINDOWS.to_vec());
        assert_eq!(windows(&json!({"windows_ms": [50, 3000]})), [Duration::from_millis(200), Duration::from_secs(3)]);
        let line = serde_json::to_value(ax::Attempt::default()).unwrap();
        assert_eq!(line["answered"], false);
    }

    #[test]
    fn the_title_is_the_first_heading() {
        assert_eq!(title_of(&tree()), "Shopping list");
        assert_eq!(title_of(&json!({"elements": [{"label": "Plain"}]})), Value::Null);
    }

    #[test]
    fn run_statistics_keep_the_longest_gap_and_the_average() {
        let mut stats = RunStats::default();
        stats.good(400, Duration::ZERO, true);
        stats.good(600, Duration::from_secs(5), false);
        stats.good(500, Duration::from_secs(42), true);
        stats.failures = 1;
        let json = stats.json();
        assert_eq!(json["reads"], 3);
        assert_eq!(json["changed"], 2);
        assert_eq!(json["longest_gap_ms"], 42_000);
        assert_eq!(json["average_ms"], 500);
        assert_eq!(json["slowest_ms"], 600);
        assert_eq!(RunStats::default().json()["average_ms"], 0);
    }

    #[tokio::test]
    async fn a_request_without_a_pairing_or_with_an_unknown_name_is_refused() {
        let unpaired = handle(json!({"op": "read_once"}), |_| {}).await.unwrap_err();
        assert_eq!(unpaired.code, Some("pairing"));
        let unknown = handle(json!({"op": "record"}), |_| {}).await.unwrap_err();
        assert_eq!(unknown.code, Some("config"));
    }

    #[tokio::test]
    async fn a_run_reports_failed_reads_and_ends_when_stopped() {
        let lines = std::sync::Arc::new(std::sync::Mutex::new(vec![]));
        let seen = lines.clone();
        let (first, reported) = tokio::sync::oneshot::channel();
        let first = std::sync::Mutex::new(Some(first));
        let run = tokio::spawn(handle(json!({"op": "run", "pairing_file": "/nonexistent/pairing.plist"}), move |line| {
            seen.lock().unwrap().push(line);
            if let Some(first) = first.lock().unwrap().take() {
                let _ = first.send(());
            }
        }));
        // Stopped once the run has reported its first read, not after a guessed wait.
        reported.await.expect("the run reports its first read");
        cancel();
        let answer = tokio::time::timeout(Duration::from_secs(2), run).await.expect("the run ends when stopped").unwrap().unwrap();
        assert_eq!(answer["ended"], "stopped");
        assert_eq!(answer["reads"], 0);
        assert_eq!(answer["failures"], 1);
        let lines = lines.lock().unwrap();
        assert_eq!(lines[0]["ok"], false);
        assert_eq!(lines[0]["code"], "pairing");
    }
}
