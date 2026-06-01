//! Anthropic `/v1/messages` request → SAP-shape Bedrock `InvokeModel` body.
//!
//! Claude Code in Anthropic mode (no `CLAUDE_CODE_USE_BEDROCK` env) sends
//! POSTs to `/v1/messages` with a body of the shape:
//!
//! ```json
//! { "model": "claude-opus-4.7",
//!   "messages": [...],
//!   "max_tokens": 1024,
//!   "stream": true }
//! ```
//!
//! SAP AI Core's deployed Bedrock endpoints expect the
//! Bedrock-`InvokeModel` body shape under
//! `/v2/inference/deployments/{id}/{invoke|invoke-with-response-stream}`:
//!
//! ```json
//! { "anthropic_version": "bedrock-2023-05-31",
//!   "messages": [...],
//!   "max_tokens": 1024 }
//! ```
//!
//! Conversion rules:
//! - `"model"` → consumed (used for deployment lookup), removed from body.
//! - `"stream"` → consumed (drives URL suffix decision), removed from body.
//! - `"anthropic_version"` → injected if absent (Bedrock contract requires
//!   it; Anthropic-shape clients don't send it).
//! - Anthropic-only fields not in the Bedrock InvokeModel schema are
//!   stripped. SAP's gateway runs strict Pydantic-style validation and
//!   rejects unknown fields with `Extra inputs are not permitted`.
//!   See [`STRIP_FIELDS`].
//! - All remaining fields are preserved verbatim.

use serde_json::Value;

/// Output of [`translate`]: the model id from the inbound body, the
/// streaming flag, and the outbound JSON body bytes ready for SAP.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Translated {
    pub model: String,
    pub stream: bool,
    pub body: Vec<u8>,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum TranslateError {
    #[error("request body is not valid JSON")]
    NotJson,
    #[error("request body must be a JSON object")]
    NotObject,
    #[error("missing required field 'model'")]
    MissingModel,
    #[error("'model' must be a non-empty string")]
    InvalidModel,
}

const ANTHROPIC_VERSION: &str = "bedrock-2023-05-31";

/// Anthropic-only `/v1/messages` body fields rejected by SAP's deployed
/// Bedrock endpoint. SAP's API gateway uses strict Pydantic validation
/// (`Extra inputs are not permitted`), so these must be removed before
/// the body is forwarded.
///
/// Each entry shipped because we observed it in real Claude Code 2.x
/// traffic and got a 400 from SAP. Add more as Anthropic / Claude Code
/// introduces them. This is a denylist rather than an allowlist because
/// Bedrock's accepted set already covers the common Anthropic fields
/// (max_tokens, messages, system, tools, tool_choice, temperature,
/// top_p, top_k, stop_sequences, metadata) and we don't want to break
/// when Anthropic adds a *new* compatible field.
const STRIP_FIELDS: &[&str] = &[
    // Claude Code 2.1+ context-management feature.
    "context_management",
    // Claude Code MCP-server config (per-request override).
    "mcp_servers",
    // Anthropic API client sometimes adds these; not part of the
    // Bedrock InvokeModel schema.
    "service_tier",
    "container",
];

pub fn translate(input: &[u8]) -> Result<Translated, TranslateError> {
    let mut value: Value = serde_json::from_slice(input).map_err(|_| TranslateError::NotJson)?;
    let obj = value.as_object_mut().ok_or(TranslateError::NotObject)?;

    let model = match obj.remove("model") {
        Some(Value::String(s)) if !s.is_empty() => s,
        Some(_) => return Err(TranslateError::InvalidModel),
        None => return Err(TranslateError::MissingModel),
    };

    let stream = matches!(obj.remove("stream"), Some(Value::Bool(true)));

    for f in STRIP_FIELDS {
        obj.remove(*f);
    }

    obj.entry("anthropic_version")
        .or_insert_with(|| Value::String(ANTHROPIC_VERSION.to_string()));

    let body = serde_json::to_vec(&value).expect("JSON value re-serializes");
    Ok(Translated {
        model,
        stream,
        body,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn extracts_model_and_drops_stream_field() {
        let inbound = json!({
            "model": "claude-opus-4.7",
            "messages": [{"role": "user", "content": "hi"}],
            "max_tokens": 32,
            "stream": false
        })
        .to_string();
        let out = translate(inbound.as_bytes()).unwrap();
        assert_eq!(out.model, "claude-opus-4.7");
        assert!(!out.stream);

        let parsed: Value = serde_json::from_slice(&out.body).unwrap();
        assert!(parsed.get("model").is_none(), "model must be stripped");
        assert!(parsed.get("stream").is_none(), "stream must be stripped");
        assert_eq!(parsed["anthropic_version"], "bedrock-2023-05-31");
        assert_eq!(parsed["max_tokens"], 32);
        assert_eq!(parsed["messages"][0]["role"], "user");
    }

    #[test]
    fn streaming_flag_set_when_body_says_stream_true() {
        let inbound = json!({
            "model": "claude-haiku-4.5",
            "messages": [],
            "stream": true
        })
        .to_string();
        let out = translate(inbound.as_bytes()).unwrap();
        assert_eq!(out.model, "claude-haiku-4.5");
        assert!(out.stream);
    }

    #[test]
    fn missing_stream_defaults_to_non_streaming() {
        let inbound = json!({
            "model": "claude-opus-4.7",
            "messages": []
        })
        .to_string();
        let out = translate(inbound.as_bytes()).unwrap();
        assert!(!out.stream);
    }

    #[test]
    fn preserves_existing_anthropic_version_if_caller_supplied() {
        let inbound = json!({
            "model": "claude-opus-4.7",
            "anthropic_version": "custom-2099-01-01",
            "messages": []
        })
        .to_string();
        let out = translate(inbound.as_bytes()).unwrap();
        let parsed: Value = serde_json::from_slice(&out.body).unwrap();
        assert_eq!(parsed["anthropic_version"], "custom-2099-01-01");
    }

    #[test]
    fn rejects_non_json() {
        assert_eq!(translate(b"not json").unwrap_err(), TranslateError::NotJson);
    }

    #[test]
    fn rejects_non_object() {
        assert_eq!(
            translate(br#"["model","claude-opus-4.7"]"#).unwrap_err(),
            TranslateError::NotObject
        );
    }

    #[test]
    fn rejects_missing_model() {
        let inbound = json!({"messages": []}).to_string();
        assert_eq!(
            translate(inbound.as_bytes()).unwrap_err(),
            TranslateError::MissingModel
        );
    }

    #[test]
    fn rejects_empty_model() {
        let inbound = json!({"model": "", "messages": []}).to_string();
        assert_eq!(
            translate(inbound.as_bytes()).unwrap_err(),
            TranslateError::InvalidModel
        );
    }

    #[test]
    fn rejects_non_string_model() {
        let inbound = json!({"model": 42, "messages": []}).to_string();
        assert_eq!(
            translate(inbound.as_bytes()).unwrap_err(),
            TranslateError::InvalidModel
        );
    }

    #[test]
    fn strips_anthropic_only_fields_that_break_sap() {
        // Real-world Claude Code 2.x request shape — context_management
        // is what triggered "Extra inputs are not permitted" from SAP.
        let inbound = json!({
            "model": "claude-opus-4.7",
            "messages": [{"role": "user", "content": "hi"}],
            "max_tokens": 32,
            "context_management": {"strategy": "auto"},
            "mcp_servers": {"some": "config"},
            "service_tier": "default",
            "container": "abc"
        })
        .to_string();
        let out = translate(inbound.as_bytes()).unwrap();
        let parsed: Value = serde_json::from_slice(&out.body).unwrap();
        for stripped in [
            "context_management",
            "mcp_servers",
            "service_tier",
            "container",
        ] {
            assert!(
                parsed.get(stripped).is_none(),
                "{stripped} must be stripped: {parsed}"
            );
        }
        // Bedrock-compatible fields stay.
        assert_eq!(parsed["max_tokens"], 32);
        assert_eq!(parsed["messages"][0]["role"], "user");
    }

    #[test]
    fn preserves_arbitrary_fields_like_system_and_tools() {
        let inbound = json!({
            "model": "claude-opus-4.7",
            "system": "you are concise",
            "tools": [{"name": "calc", "description": "math"}],
            "messages": [{"role": "user", "content": "2+2"}]
        })
        .to_string();
        let out = translate(inbound.as_bytes()).unwrap();
        let parsed: Value = serde_json::from_slice(&out.body).unwrap();
        assert_eq!(parsed["system"], "you are concise");
        assert_eq!(parsed["tools"][0]["name"], "calc");
        assert_eq!(parsed["messages"][0]["content"], "2+2");
    }
}
