//! Streaming pass-through integration test.
//!
//! Spins up a wiremock SAP backend that returns a binary blob with the
//! AWS event-stream `Content-Type`. Asserts the bridge:
//! 1. Sends `Accept: application/vnd.amazon.eventstream` outbound.
//! 2. Sets the same Content-Type on its own response.
//! 3. Pipes the bytes through unchanged (chunk boundaries don't matter
//!    for this assertion — wiremock returns the body in one chunk and
//!    we compare the whole thing — but the bridge code path uses
//!    `bytes_stream()` and never buffers, which is what we care about).
//! 4. Sets `X-Accel-Buffering: no`.

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use openshell_bedrock_bridge::config::ServiceUrls;
use openshell_bedrock_bridge::{router, AppState, Config, SapServiceKey};
use serde_json::json;
use std::collections::HashMap;
use tower::ServiceExt;
use wiremock::matchers::{body_string, header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn cfg(server_uri: &str) -> Config {
    Config {
        bind_address: "127.0.0.1".into(),
        port: 0,
        path_prefix: "/saic-aws-bedrock".into(),
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

/// Hand-crafted bytes that look like a single AWS event-stream frame:
/// total_len=0x1C, headers_len=0x00, prelude_crc=00000000 (not validated
/// by the bridge — we're testing pass-through, not framing). 28 bytes
/// total: 12 prelude + 0 headers + 12 payload + 4 trailing CRC.
fn fake_eventstream_bytes() -> Vec<u8> {
    let mut buf = Vec::new();
    // Prelude: total length (4) + headers length (4) + prelude CRC (4)
    buf.extend_from_slice(&[0x00, 0x00, 0x00, 0x1C]); // total = 28 bytes
    buf.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]); // headers length = 0
    buf.extend_from_slice(&[0xDE, 0xAD, 0xBE, 0xEF]); // fake prelude CRC
                                                      // Payload: 12 bytes — looks like a base64-encoded JSON-ish blob
    buf.extend_from_slice(b"hello-stream");
    // Trailing message CRC (4 bytes)
    buf.extend_from_slice(&[0xCA, 0xFE, 0xBA, 0xBE]);
    buf
}

#[tokio::main]
#[test]
async fn streaming_invoke_passes_bytes_through_with_correct_outbound_accept() {
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/oauth/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "access_token": "tok",
            "expires_in": 3600u64,
        })))
        .mount(&server)
        .await;

    let inbound_body = json!({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 32,
        "messages": [{"role": "user", "content": "hi"}]
    })
    .to_string();
    let upstream_bytes = fake_eventstream_bytes();

    Mock::given(method("POST"))
        .and(path(
            "/v2/inference/deployments/dep-opus/invoke-with-response-stream",
        ))
        // Verifies the outbound Accept header from the bridge.
        .and(header("accept", "application/vnd.amazon.eventstream"))
        .and(header("authorization", "Bearer tok"))
        .and(header("ai-resource-group", "default"))
        .and(header("content-type", "application/json"))
        .and(body_string(inbound_body.clone()))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "application/vnd.amazon.eventstream")
                .set_body_bytes(upstream_bytes.clone()),
        )
        .expect(1)
        .mount(&server)
        .await;

    let app = router(AppState::new(cfg(&server.uri()), reqwest::Client::new()));

    let req = Request::builder()
        .method("POST")
        .uri("/saic-aws-bedrock/model/claude-opus-4.7/invoke-with-response-stream")
        .header("content-type", "application/json")
        .body(Body::from(inbound_body.clone()))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        resp.headers()
            .get("content-type")
            .unwrap()
            .to_str()
            .unwrap(),
        "application/vnd.amazon.eventstream"
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
    let req = Request::builder()
        .method("POST")
        .uri("/saic-aws-bedrock/model/claude-opus-4.7/invoke-with-response-stream")
        .header("content-type", "application/json")
        .body(Body::from("{}"))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::TOO_MANY_REQUESTS);
    let body = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["__type"].as_str().unwrap(), "ThrottlingException");
}
