//! HTTP handlers translating Claude Code Bedrock requests → SAP AI Core.

use crate::config::Config;
use crate::error_mapper::BedrockError;
use crate::model_resolver;
use crate::sap_auth::TokenCache;

use axum::body::Body;
use axum::extract::{Path, State};
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

/// Build the bridge router.
///
/// Routes mounted under `cfg.path_prefix` (default `/saic-aws-bedrock`):
/// - `POST /model/{model_id}/invoke`                    — non-streaming
/// - `POST /model/{model_id}/invoke-with-response-stream` — pass-through stream
/// - `GET /healthz`                                      — empty 200
pub fn router(state: AppState) -> Router {
    let prefix = state.config.path_prefix.trim_end_matches('/').to_string();
    let bedrock = Router::new()
        .route("/model/{model_id}/invoke", post(invoke_handler))
        .route(
            "/model/{model_id}/invoke-with-response-stream",
            post(invoke_stream_handler),
        )
        .with_state(state);

    Router::new()
        .nest(&prefix, bedrock)
        .route("/healthz", axum::routing::get(healthz))
}

async fn healthz() -> StatusCode {
    StatusCode::OK
}

/// Non-streaming invoke. Body bytes forwarded unchanged.
pub async fn invoke_handler(
    State(state): State<AppState>,
    Path(model_id): Path<String>,
    body: Bytes,
) -> Response {
    forward(&state, &model_id, body, "invoke", false).await
}

/// Streaming invoke. Pass-through.
pub async fn invoke_stream_handler(
    State(state): State<AppState>,
    Path(model_id): Path<String>,
    body: Bytes,
) -> Response {
    forward(&state, &model_id, body, "invoke-with-response-stream", true).await
}

async fn forward(
    state: &AppState,
    model_id: &str,
    body: Bytes,
    subpath: &str,
    streaming: bool,
) -> Response {
    let deployment = match model_resolver::resolve(
        model_id,
        &state.config.model_map,
        state.config.default_deployment.as_deref(),
    ) {
        Ok(d) => d.to_string(),
        Err(_) => {
            return bedrock_error_response(
                StatusCode::NOT_FOUND,
                format!("Unknown model id {model_id}"),
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

    let mut req = state
        .http
        .post(&url)
        .bearer_auth(&token)
        .header("AI-Resource-Group", &state.config.resource_group)
        .header(header::CONTENT_TYPE, "application/json");

    if streaming {
        // The probe (Task 1) confirmed SAP emits native AWS event-stream
        // binary framing when asked. Pass-through then needs no re-framing.
        req = req.header(header::ACCEPT, "application/vnd.amazon.eventstream");
    }

    let resp = match req.body(body).send().await {
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
            // Pass through the upstream's message body as-is when present;
            // SAP returns useful Anthropic-style error JSON we can hand to
            // Claude Code.
            txt
        };
        return bedrock_error_response(upstream_axum_status, summary);
    }

    if streaming {
        let stream = resp.bytes_stream();
        let body = Body::from_stream(stream);
        let mut headers = HeaderMap::new();
        headers.insert(
            header::CONTENT_TYPE,
            "application/vnd.amazon.eventstream".parse().unwrap(),
        );
        // Disable buffering at intermediate proxies (mirrors AWS Bedrock).
        headers.insert("X-Accel-Buffering", "no".parse().unwrap());
        (StatusCode::OK, headers, body).into_response()
    } else {
        // Non-streaming: pass body bytes verbatim.
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
