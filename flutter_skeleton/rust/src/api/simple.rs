//! Stage-1 bridge surface: proves the Dart -> Rust -> Dart round trip and
//! carries one piece of real business logic (session digest) that the Flutter
//! UI will use in stage 3.

use serde::{Deserialize, Serialize};

/// Synchronous smoke-test call. The Flutter test asserts on this exact string,
/// so a green CI run means the bridge is genuinely wired end to end.
#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    format!("Hello, {name}! — from Rust")
}

/// Digest of a chat session, computed in Rust from the same JSON the iOS app
/// stores locally.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SessionDigest {
    pub title: String,
    pub message_count: i32,
    pub char_count: i32,
}

#[derive(Deserialize)]
struct RawSession {
    title: Option<String>,
    messages: Option<Vec<RawMessage>>,
}

#[derive(Deserialize)]
struct RawMessage {
    content: Option<String>,
}

/// Parse a session JSON blob and summarise it. Pure logic, no IO — exactly the
/// kind of work that belongs in the Rust core rather than Dart.
pub fn digest_session(json: String) -> Result<SessionDigest, String> {
    let raw: RawSession = serde_json::from_str(&json).map_err(|e| e.to_string())?;
    let messages = raw.messages.unwrap_or_default();
    let char_count = messages
        .iter()
        .filter_map(|m| m.content.as_ref())
        .map(|c| c.chars().count() as i32)
        .sum();
    Ok(SessionDigest {
        title: raw.title.unwrap_or_else(|| "Untitled".to_string()),
        message_count: messages.len() as i32,
        char_count,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greet_is_stable() {
        assert_eq!(greet("Amore".into()), "Hello, Amore! — from Rust");
    }

    #[test]
    fn digest_counts_messages_and_chars() {
        let json = r#"{"title":"迁移测试","messages":[{"content":"你好"},{"content":"hello"},{}]}"#;
        let d = digest_session(json.into()).unwrap();
        assert_eq!(d.title, "迁移测试");
        assert_eq!(d.message_count, 3);
        assert_eq!(d.char_count, 7); // 2 CJK + 5 ASCII
    }

    #[test]
    fn digest_defaults_title() {
        let d = digest_session(r#"{"messages":[]}"#.into()).unwrap();
        assert_eq!(d.title, "Untitled");
        assert_eq!(d.message_count, 0);
    }
}
