//! Progress the shell shows while a long step runs. Every long function takes a [`Reporter`];
//! the UI turns the events into the step list, the CLI prints them.
use serde::Serialize;
use std::sync::Arc;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Progress {
    /// A step began: `id` is stable (`pair`, `sign`, `install`), `title` is for people.
    Step { id: String, title: String },
    /// Part of the current step, 0 to 1, with an optional line.
    Part { id: String, fraction: f64, detail: Option<String> },
    /// A line worth showing under the step (what was found, what was chosen).
    Note { id: String, text: String },
    /// The person has to do something on the phone or in a dialog before the step goes on.
    Waiting { id: String, text: String },
    /// The step is done.
    Done { id: String, detail: Option<String> },
}

/// Where progress goes. Clone it freely; it is an `Arc` inside.
#[derive(Clone)]
pub struct Reporter(Arc<dyn Fn(Progress) + Send + Sync>);

impl Reporter {
    pub fn new(f: impl Fn(Progress) + Send + Sync + 'static) -> Self { Reporter(Arc::new(f)) }
    /// Drops everything; for tests and for calls that have no UI.
    pub fn silent() -> Self { Reporter(Arc::new(|_| {})) }
    /// Prints one line per event, for the CLI.
    pub fn stderr() -> Self {
        Reporter(Arc::new(|p| match p {
            Progress::Step { title, .. } => eprintln!("▸ {title}"),
            Progress::Part { fraction, detail, .. } => {
                if let Some(d) = detail { eprintln!("  {:>3}% {d}", (fraction * 100.0) as u32) }
            }
            Progress::Note { text, .. } => eprintln!("  · {text}"),
            Progress::Waiting { text, .. } => eprintln!("  ⏸ {text}"),
            Progress::Done { detail, .. } => eprintln!("  ✓ {}", detail.unwrap_or_default()),
        }))
    }
    pub fn emit(&self, p: Progress) { (self.0)(p) }
    pub fn step(&self, id: &str, title: &str) {
        tracing::info!(step = id, "{title}");
        self.emit(Progress::Step { id: id.into(), title: title.into() })
    }
    pub fn part(&self, id: &str, fraction: f64, detail: Option<String>) { self.emit(Progress::Part { id: id.into(), fraction, detail }) }
    pub fn note(&self, id: &str, text: impl Into<String>) {
        let text = text.into();
        tracing::info!(step = id, "{text}");
        self.emit(Progress::Note { id: id.into(), text })
    }
    pub fn waiting(&self, id: &str, text: impl Into<String>) { self.emit(Progress::Waiting { id: id.into(), text: text.into() }) }
    pub fn done(&self, id: &str, detail: Option<String>) {
        tracing::info!(step = id, detail = detail.as_deref().unwrap_or(""), "done");
        self.emit(Progress::Done { id: id.into(), detail })
    }
}

impl std::fmt::Debug for Reporter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str("Reporter") }
}
