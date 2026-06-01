//! End-to-end integration test for the non-streaming `/invoke` route.
//!
//! Spins up a wiremock SAP backend covering both XSUAA `/oauth/token`
//! and the AI Core inference endpoint. Builds the bridge router around
//! that mock, sends a Bedrock-shape request through axum's `oneshot`,
//! asserts:
//!   - SAP got the expected outbound URL + headers + body bytes.
//!   - The bridge returned the SAP body verbatim.
//!   - Error statuses translate to Bedrock-shape JSON.

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
        model_map: HashMap::from([("claude-opus-4.7".to_string(), "dep-opus-4-7".to_string())]),
        default_deployment: None,
        log_level: "info".into(),
    }
}

#[tokio::main]
#[test]
async fn non_streaming_invoke_forwards_body_verbatim() {
    let server = MockServer::start().await;

    // Token endpoint.
    Mock::given(method("POST"))
        .and(path("/oauth/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "access_token": "tok-test",
            "expires_in": 3600u64,
        })))
        .mount(&server)
        .await;

    // SAP inference endpoint.
    let inbound_body = json!({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 32,
        "messages": [{"role": "user", "content": "hi"}]
    })
    .to_string();
    let upstream_response = json!({
        "content": [{"type": "text", "text": "Hi there"}],
        "stop_reason": "end_turn",
        "model": "claude-opus-4-7",
    });
    Mock::given(method("POST"))
        .and(path("/v2/inference/deployments/dep-opus-4-7/invoke"))
        .and(header("authorization", "Bearer tok-test"))
        .and(header("ai-resource-group", "default"))
        .and(header("content-type", "application/json"))
        .and(body_string(inbound_body.clone()))
        .respond_with(ResponseTemplate::new(200).set_body_json(upstream_response.clone()))
        .expect(1)
        .mount(&server)
        .await;

    let app = router(AppState::new(cfg(&server.uri()), reqwest::Client::new()));

    let req = Request::builder()
        .method("POST")
        .uri("/saic-aws-bedrock/model/claude-opus-4.7/invoke")
        .header("content-type", "application/json")
        .body(Body::from(inbound_body.clone()))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        resp.headers().get("content-type").unwrap(),
        "application/json"
    );

    let body_bytes = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
    let parsed: serde_json::Value = serde_json::from_slice(&body_bytes).unwrap();
    assert_eq!(parsed, upstream_response);

    server.verify().await;
}

#[tokio::main]
#[test]
async fn unknown_model_returns_404_resource_not_found() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/oauth/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "access_token": "tok",
            "expires_in": 3600u64,
        })))
        .mount(&server)
        .await;

    let app = router(AppState::new(cfg(&server.uri()), reqwest::Client::new()));
    let req = Request::builder()
        .method("POST")
        .uri("/saic-aws-bedrock/model/no-such-model/invoke")
        .header("content-type", "application/json")
        .body(Body::from(r#"{}"#))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let body = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["__type"].as_str().unwrap(), "ResourceNotFoundException");
    assert!(v["message"].as_str().unwrap().contains("no-such-model"));
}

#[tokio::main]
#[test]
async fn upstream_400_translates_to_validation_exception() {
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
        .and(path("/v2/inference/deployments/dep-opus-4-7/invoke"))
        .respond_with(
            ResponseTemplate::new(400)
                .set_body_string(r#"{"error":{"type":"invalid_request_error","message":"bad"}}"#),
        )
        .mount(&server)
        .await;

    let app = router(AppState::new(cfg(&server.uri()), reqwest::Client::new()));
    let req = Request::builder()
        .method("POST")
        .uri("/saic-aws-bedrock/model/claude-opus-4.7/invoke")
        .header("content-type", "application/json")
        .body(Body::from("{}"))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["__type"].as_str().unwrap(), "ValidationException");
}

#[tokio::main]
#[test]
async fn healthz_returns_200() {
    let server = MockServer::start().await;
    let app = router(AppState::new(cfg(&server.uri()), reqwest::Client::new()));
    let req = Request::builder()
        .method("GET")
        .uri("/healthz")
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}
