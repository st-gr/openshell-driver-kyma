//! HTTP handlers translating Anthropic-shape `/v1/messages` requests
//! → SAP AI Core's deployed Bedrock InvokeModel endpoints.
//!
//! Inbound: standard Anthropic Messages-API body.
//! Outbound: Bedrock-shape body (sans `model` and `stream`, with
//!           `anthropic_version` injected) to
//!           `/v2/inference/deployments/{deployment-id}/{invoke|invoke-with-response-stream}`.
//!
//! Streaming wire format: SAP defaults to `text/event-stream` (verified
//! via curl probe — see the project's reference memory for details), so
//! both directions speak SSE and the streaming path is byte pass-through.

use crate::config::Config;
use crate::error_mapper::BedrockError;
use crate::model_resolver;
use crate::sap_auth::TokenCache;
use crate::translator::{self, TranslateError};

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::{routing::post, Router};
use bytes::Bytes;
use std::sync::Arc;

/// Application state shared by every request.
#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Config>,
    pub tokens: TokenCache,
    pub http: reqwest::Client,
}

impl AppState {
    pub fn new(config: Config, http: reqwest::Client) -> Self {
        let tokens = TokenCache::new(config.sap_key.clone(), http.clone());
        Self {
            config: Arc::new(config),
            tokens,
            http,
        }
    }
}

/// Build the bridge router. The bridge speaks the Anthropic Messages
/// API, so this is mounted at `/v1/messages` regardless of how the
/// gateway upstream is configured.
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/v1/messages", post(messages_handler))
        .route("/healthz", axum::routing::get(healthz))
        .with_state(state)
}

async fn healthz() -> StatusCode {
    StatusCode::OK
}

/// Anthropic `/v1/messages` entrypoint. Translates the body, resolves
/// the deployment id, and forwards to SAP. Streaming is decided by the
/// `"stream": true` flag in the request body.
pub async fn messages_handler(State(state): State<AppState>, body: Bytes) -> Response {
    let translated = match translator::translate(&body) {
        Ok(t) => t,
        Err(TranslateError::NotJson | TranslateError::NotObject) => {
            return bedrock_error_response(
                StatusCode::BAD_REQUEST,
                "request body must be a JSON object".to_string(),
            );
        }
        Err(TranslateError::MissingModel) => {
            return bedrock_error_response(
                StatusCode::BAD_REQUEST,
                "request body is missing required field 'model'".to_string(),
            );
        }
        Err(TranslateError::InvalidModel) => {
            return bedrock_error_response(
                StatusCode::BAD_REQUEST,
                "'model' must be a non-empty string".to_string(),
            );
        }
    };

    let deployment = match model_resolver::resolve(
        &translated.model,
        &state.config.model_map,
        state.config.default_deployment.as_deref(),
    ) {
        Ok(d) => d.to_string(),
        Err(_) => {
            return bedrock_error_response(
                StatusCode::NOT_FOUND,
                format!("Unknown model id {}", translated.model),
            );
        }
    };

    let token = match state.tokens.token().await {
        Ok(t) => t,
        Err(e) => {
            tracing::error!(err = %e, "XSUAA token fetch failed");
            return bedrock_error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "upstream auth failed".to_string(),
            );
        }
    };

    let subpath = if translated.stream {
        "invoke-with-response-stream"
    } else {
        "invoke"
    };
    let url = format!(
        "{}/v2/inference/deployments/{}/{}",
        state
            .config
            .sap_key
            .serviceurls
            .ai_api_url
            .trim_end_matches('/'),
        deployment,
        subpath
    );

    tracing::debug!(
        model = %translated.model,
        deployment = %deployment,
        stream = translated.stream,
        "forwarding to SAP AI Core"
    );

    let req = state
        .http
        .post(&url)
        .bearer_auth(&token)
        .header("AI-Resource-Group", &state.config.resource_group)
        .header(header::CONTENT_TYPE, "application/json")
        .body(translated.body);

    let resp = match req.send().await {
        Ok(r) => r,
        Err(e) => {
            tracing::error!(err = %e, "SAP AI Core unreachable");
            return bedrock_error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "upstream unreachable".to_string(),
            );
        }
    };

    let status = resp.status();
    let upstream_axum_status =
        StatusCode::from_u16(status.as_u16()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);

    if !status.is_success() {
        let txt = resp.text().await.unwrap_or_default();
        let summary = if txt.is_empty() {
            format!("upstream returned {status}")
        } else {
            txt
        };
        return bedrock_error_response(upstream_axum_status, summary);
    }

    if translated.stream {
        // SAP returns `text/event-stream` SSE — same wire format Anthropic
        // SSE uses, so byte pass-through works directly.
        let stream = resp.bytes_stream();
        let body = Body::from_stream(stream);
        let mut headers = HeaderMap::new();
        headers.insert(header::CONTENT_TYPE, "text/event-stream".parse().unwrap());
        headers.insert(header::CACHE_CONTROL, "no-cache".parse().unwrap());
        // Disable buffering at intermediate proxies.
        headers.insert("X-Accel-Buffering", "no".parse().unwrap());
        (StatusCode::OK, headers, body).into_response()
    } else {
        let bytes = match resp.bytes().await {
            Ok(b) => b,
            Err(e) => {
                tracing::error!(err = %e, "failed to read SAP response body");
                return bedrock_error_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "upstream body read failed".to_string(),
                );
            }
        };
        let mut headers = HeaderMap::new();
        headers.insert(header::CONTENT_TYPE, "application/json".parse().unwrap());
        (StatusCode::OK, headers, bytes).into_response()
    }
}

fn bedrock_error_response(status: StatusCode, message: String) -> Response {
    let err = BedrockError::from_status(status, message);
    let body = serde_json::to_vec(&err).unwrap_or_else(|_| b"{}".to_vec());
    let mut headers = HeaderMap::new();
    headers.insert(header::CONTENT_TYPE, "application/json".parse().unwrap());
    (status, headers, body).into_response()
}
