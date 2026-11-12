//! Provider catalog + request building.
//!
//! This is the logic that used to live in 81 Swift files. It belongs in Rust:
//! pure, testable, and shared by every caller instead of being re-implemented
//! per screen.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum Protocol {
    /// `POST {base}/v1/chat/completions` (or `/chat/completions`), Bearer auth.
    OpenAiChat,
    /// `POST {base}/v1/messages`, `x-api-key` + `anthropic-version`.
    AnthropicMessages,
    /// `POST {base}/v1beta/models/{model}:streamGenerateContent?alt=sse&key=`.
    GeminiGenerate,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProviderInfo {
    pub id: String,
    pub name: String,
    pub base_url: String,
    pub protocol: Protocol,
    /// Whether `base_url` may be overridden (self-hosted / proxy endpoints).
    pub allows_custom_base_url: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HeaderPair {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RequestSpec {
    pub url: String,
    pub headers: Vec<HeaderPair>,
    pub body_json: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ChatTurn {
    pub role: String,
    pub content: String,
}

/// Built-in providers, mirroring the Swift `ProviderType` set that the app
/// ships with (endpoints taken from `ProviderConfigStore` / `LLMProviderFactory`).
pub fn list_providers() -> Vec<ProviderInfo> {
    fn p(
        id: &str,
        name: &str,
        base_url: &str,
        protocol: Protocol,
        custom: bool,
    ) -> ProviderInfo {
        ProviderInfo {
            id: id.into(),
            name: name.into(),
            base_url: base_url.into(),
            protocol,
            allows_custom_base_url: custom,
        }
    }

    vec![
        p("openAI", "OpenAI", "https://api.openai.com", Protocol::OpenAiChat, false),
        p("anthropic", "Anthropic", "https://api.anthropic.com", Protocol::AnthropicMessages, false),
        p("gemini", "Google Gemini", "https://generativelanguage.googleapis.com", Protocol::GeminiGenerate, false),
        p("openRouter", "OpenRouter", "https://openrouter.ai/api", Protocol::OpenAiChat, true),
        p("deepSeek", "DeepSeek", "https://api.deepseek.com", Protocol::OpenAiChat, true),
        p("kimi", "Kimi (Coding)", "https://api.kimi.com/coding", Protocol::OpenAiChat, true),
        p("xai", "xAI Grok", "https://api.x.ai/v1", Protocol::OpenAiChat, true),
        p("dashscope", "DashScope (Qwen)", "https://dashscope.aliyuncs.com/compatible-mode", Protocol::OpenAiChat, true),
        p("custom", "Custom (OpenAI compatible)", "https://api.openai.com", Protocol::OpenAiChat, true),
    ]
}

fn trim_base(base: &str) -> &str {
    base.trim_end_matches('/')
}

/// Build the HTTP request for a chat completion.
///
/// `stream` only changes the body flag for OpenAI-style protocols; Anthropic
/// and Gemini always stream in the app.
pub fn build_chat_request(
    provider_id: String,
    base_url_override: Option<String>,
    api_key: String,
    model: String,
    turns: Vec<ChatTurn>,
    stream: bool,
) -> Result<RequestSpec, String> {
    if api_key.trim().is_empty() {
        return Err("missing API key".into());
    }
    if model.trim().is_empty() {
        return Err("missing model".into());
    }

    let provider = list_providers()
        .into_iter()
        .find(|p| p.id == provider_id)
        .ok_or_else(|| format!("unknown provider: {provider_id}"))?;

    let base = trim_base(
        base_url_override
            .as_deref()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(&provider.base_url),
    );

    let mut headers = vec![HeaderPair {
        name: "Content-Type".into(),
        value: "application/json".into(),
    }];

    let body = match provider.protocol {
        Protocol::OpenAiChat => {
            headers.push(HeaderPair {
                name: "Authorization".into(),
                value: format!("Bearer {}", api_key.trim()),
            });
            let msgs: Vec<serde_json::Value> = turns
                .iter()
                .map(|t| serde_json::json!({"role": t.role, "content": t.content}))
                .collect();
            serde_json::json!({"model": model, "messages": msgs, "stream": stream})
        }
        Protocol::AnthropicMessages => {
            headers.push(HeaderPair {
                name: "x-api-key".into(),
                value: api_key.trim().into(),
            });
            headers.push(HeaderPair {
                name: "anthropic-version".into(),
                value: "2023-06-01".into(),
            });
            let msgs: Vec<serde_json::Value> = turns
                .iter()
                .filter(|t| t.role != "system")
                .map(|t| serde_json::json!({"role": t.role, "content": t.content}))
                .collect();
            serde_json::json!({
                "model": model,
                "max_tokens": 4096,
                "messages": msgs,
                "stream": true
            })
        }
        Protocol::GeminiGenerate => {
            let contents: Vec<serde_json::Value> = turns
                .iter()
                .map(|t| {
                    serde_json::json!({
                        "role": if t.role == "assistant" { "model" } else { "user" },
                        "parts": [{"text": t.content}]
                    })
                })
                .collect();
            serde_json::json!({"contents": contents})
        }
    };

    let url = match provider.protocol {
        Protocol::OpenAiChat => {
            if base.ends_with("/v1") {
                format!("{base}/chat/completions")
            } else {
                format!("{base}/v1/chat/completions")
            }
        }
        Protocol::AnthropicMessages => format!("{base}/v1/messages"),
        Protocol::GeminiGenerate => format!(
            "{base}/v1beta/models/{model}:streamGenerateContent?alt=sse&key={}",
            api_key.trim()
        ),
    };

    Ok(RequestSpec {
        url,
        headers,
        body_json: body.to_string(),
    })
}

/// Extract a text delta from one SSE line. Returns `None` for keep-alives,
/// `[DONE]`, and provider-specific envelope noise.
pub fn parse_stream_delta(provider_id: String, line: String) -> Option<String> {
    let line = line.trim();
    if line.is_empty() || line.starts_with(':') || line == "data: [DONE]" {
        return None;
    }
    let payload = line.strip_prefix("data:").unwrap_or(line).trim();
    if payload.is_empty() || payload == "[DONE]" {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(payload).ok()?;

    match provider_id.as_str() {
        "anthropic" => {
            if v.get("type")?.as_str()? == "content_block_delta" {
                v.get("delta")?.get("text")?.as_str().map(|s| s.to_string())
            } else {
                None
            }
        }
        "gemini" => v
            .get("candidates")?
            .as_array()?
            .first()?
            .get("content")?
            .get("parts")?
            .as_array()?
            .first()?
            .get("text")?
            .as_str()
            .map(|s| s.to_string()),
        _ => v
            .get("choices")?
            .as_array()?
            .first()?
            .get("delta")?
            .get("content")?
            .as_str()
            .map(|s| s.to_string()),
    }
}

/// Human-readable, actionable error text. Never leaks the API key.
pub fn map_http_error(status: i32, body: String) -> String {
    let snippet: String = body.chars().take(200).collect();
    match status {
        401 | 403 => "Authentication failed — check the API key.".to_string(),
        404 => "Endpoint or model not found — check the base URL and model name.".to_string(),
        429 => "Rate limited by the provider — retry shortly.".to_string(),
        500..=599 => format!("Provider is unavailable (HTTP {status}). Retry."),
        _ => format!("Request failed (HTTP {status}): {snippet}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn turns() -> Vec<ChatTurn> {
        vec![ChatTurn { role: "user".into(), content: "hi".into() }]
    }

    #[test]
    fn catalog_has_core_providers() {
        let ids: Vec<String> = list_providers().into_iter().map(|p| p.id).collect();
        for expected in ["openAI", "anthropic", "gemini", "openRouter", "deepSeek"] {
            assert!(ids.contains(&expected.to_string()), "missing {expected}");
        }
    }

    #[test]
    fn openai_request_shape() {
        let r = build_chat_request(
            "openAI".into(), None, "sk-test".into(), "gpt-4o".into(), turns(), true,
        ).unwrap();
        assert_eq!(r.url, "https://api.openai.com/v1/chat/completions");
        assert!(r.headers.iter().any(|h| h.name == "Authorization" && h.value == "Bearer sk-test"));
        let v: serde_json::Value = serde_json::from_str(&r.body_json).unwrap();
        assert_eq!(v["model"], "gpt-4o");
        assert_eq!(v["stream"], true);
    }

    #[test]
    fn anthropic_uses_x_api_key_and_version() {
        let r = build_chat_request(
            "anthropic".into(), None, "sk-ant".into(), "claude-3-7-sonnet".into(), turns(), true,
        ).unwrap();
        assert_eq!(r.url, "https://api.anthropic.com/v1/messages");
        assert!(r.headers.iter().any(|h| h.name == "x-api-key"));
        assert!(r.headers.iter().any(|h| h.name == "anthropic-version"));
        assert!(!r.headers.iter().any(|h| h.name == "Authorization"));
    }

    #[test]
    fn gemini_puts_model_and_key_in_url() {
        let r = build_chat_request(
            "gemini".into(), Some("https://generativelanguage.googleapis.com".into()),
            "AIza-key".into(), "gemini-2.5-pro".into(), turns(), true,
        ).unwrap();
        assert!(r.url.contains("models/gemini-2.5-pro:streamGenerateContent"));
        assert!(r.url.contains("key=AIza-key"));
    }

    #[test]
    fn custom_base_url_is_respected() {
        let r = build_chat_request(
            "openRouter".into(), Some("https://proxy.example.com/v1/".into()),
            "k".into(), "m".into(), turns(), true,
        ).unwrap();
        assert_eq!(r.url, "https://proxy.example.com/v1/chat/completions");
    }

    #[test]
    fn parses_openai_delta() {
        let line = r#"data: {"choices":[{"delta":{"content":"你好"}}]}"#;
        assert_eq!(parse_stream_delta("openAI".into(), line.into()), Some("你好".into()));
        assert_eq!(parse_stream_delta("openAI".into(), "data: [DONE]".into()), None);
        assert_eq!(parse_stream_delta("openAI".into(), ": keep-alive".into()), None);
    }

    #[test]
    fn parses_anthropic_delta() {
        let line = r#"data: {"type":"content_block_delta","delta":{"text":"Hi"}}"#;
        assert_eq!(parse_stream_delta("anthropic".into(), line.into()), Some("Hi".into()));
    }

    #[test]
    fn error_mapping_is_actionable() {
        assert!(map_http_error(401, "".into()).contains("API key"));
        assert!(map_http_error(429, "".into()).contains("Rate limited"));
        assert!(map_http_error(503, "".into()).contains("503"));
    }
}
