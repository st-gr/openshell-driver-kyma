//! Streaming pass-through integration test.
//!
//! Spins up a wiremock SAP backend that returns SSE bytes — same wire
//! format Anthropic SSE uses. Verifies:
//!  1. Outbound URL ends with `/invoke-with-response-stream`.
//!  2. Outbound body has `model` and `stream` stripped, `anthropic_version`
//!     present.
//!  3. Bridge sets `Content-Type: text/event-stream` on its own response.
//!  4. Bridge sets `X-Accel-Buffering: no`.
//!  5. SSE bytes pass through unchanged.

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use openshell_bedrock_bridge::config::ServiceUrls;
use openshell_bedrock_bridge::{router, AppState, Config, SapServiceKey};
use serde_json::{json, Value};
use std::collections::HashMap;
use tower::ServiceExt;
use wiremock::matchers::{header, method, path};
use wiremock::{Mock, MockServer, Request as MockRequest, ResponseTemplate};

fn cfg(server_uri: &str) -> Config {
    Config {
        bind_address: "127.0.0.1".into(),
        port: 0,
        resource_group: "default".into(),
        sap_key: SapServiceKey {
            clientid: "client".into(),
            clientsecret: "secret".into(),
            url: server_uri.to_string(),
            serviceurls: ServiceUrls {
                ai_api_url: server_uri.to_string(),
            },
        },
        model_map: HashMap::from([("claude-opus-4.7".to_string(), "dep-opus".to_string())]),
        default_deployment: None,
        log_level: "info".into(),
    }
}

/// A small SSE blob shaped like an Anthropic streaming session.
fn fake_sse_bytes() -> Vec<u8> {
    let mut s = String::new();
    s.push_str("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_01\"}}\n\n");
    s.push_str("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\n");
    s.push_str("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n");
    s.into_bytes()
}

#[tokio::main]
#[test]
async fn streaming_request_routes_to_invoke_with_response_stream() {
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/oauth/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "access_token": "tok",
            "expires_in": 3600u64,
        })))
        .mount(&server)
        .await;

    let upstream_bytes = fake_sse_bytes();
    let upstream_for_resp = upstream_bytes.clone();

    Mock::given(method("POST"))
        .and(path(
            "/v2/inference/deployments/dep-opus/invoke-with-response-stream",
        ))
        .and(header("authorization", "Bearer tok"))
        .and(header("ai-resource-group", "default"))
        .and(header("content-type", "application/json"))
        .respond_with(move |req: &MockRequest| {
            let body: Value = serde_json::from_slice(&req.body).expect("SAP receives JSON body");
            assert!(
                body.get("model").is_none(),
                "outbound body must not carry 'model': {body}"
            );
            assert!(
                body.get("stream").is_none(),
                "outbound body must not carry 'stream': {body}"
            );
            assert_eq!(body["anthropic_version"], "bedrock-2023-05-31");
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "text/event-stream")
                .set_body_bytes(upstream_for_resp.clone())
        })
        .expect(1)
        .mount(&server)
        .await;

    let app = router(AppState::new(cfg(&server.uri()), reqwest::Client::new()));

    let inbound = json!({
        "model": "claude-opus-4.7",
        "max_tokens": 32,
        "messages": [{"role": "user", "content": "hi"}],
        "stream": true
    })
    .to_string();
    let req = Request::builder()
        .method("POST")
        .uri("/v1/messages")
        .header("content-type", "application/json")
        .body(Body::from(inbound))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        resp.headers()
            .get("content-type")
            .unwrap()
            .to_str()
            .unwrap(),
        "text/event-stream"
    );
    assert_eq!(
        resp.headers()
            .get("x-accel-buffering")
            .unwrap()
            .to_str()
            .unwrap(),
        "no"
    );

    let body_bytes = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
    assert_eq!(body_bytes.as_ref(), upstream_bytes.as_slice());

    server.verify().await;
}

#[tokio::main]
#[test]
async fn streaming_invoke_upstream_429_translates_to_throttling() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/oauth/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "access_token": "tok",
            "expires_in": 3600u64,
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(
            "/v2/inference/deployments/dep-opus/invoke-with-response-stream",
        ))
        .respond_with(ResponseTemplate::new(429).set_body_string("rate limited"))
        .mount(&server)
        .await;

    let app = router(AppState::new(cfg(&server.uri()), reqwest::Client::new()));
    let inbound = json!({
        "model": "claude-opus-4.7",
        "messages": [],
        "stream": true
    })
    .to_string();
    let req = Request::builder()
        .method("POST")
        .uri("/v1/messages")
        .header("content-type", "application/json")
        .body(Body::from(inbound))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::TOO_MANY_REQUESTS);
    let body = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
    let v: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["__type"].as_str().unwrap(), "ThrottlingException");
}
