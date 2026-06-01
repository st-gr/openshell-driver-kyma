//! XSUAA `client_credentials` token cache.
//!
//! Single in-flight refresh: callers race on a `Mutex` so only one POST
//! to the token endpoint happens per refresh window. The cache returns
//! the current token while it's > 60s away from expiry.
//!
//! Discipline:
//! - `clientsecret` is held only inside `SapServiceKey` and the HTTP
//!   request body; never logged.
//! - The bearer token itself is logged only as `<redacted>` or `len=N`.
//! - No `/debug/config` endpoint exposes either.

use crate::config::SapServiceKey;
use anyhow::{anyhow, Context, Result};
use serde::Deserialize;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{Mutex, RwLock};

/// How close to expiry the cache will treat a token as stale.
const REFRESH_LEAD: Duration = Duration::from_secs(60);

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    expires_in: u64,
}

#[derive(Debug, Clone)]
struct TokenSlot {
    access_token: String,
    /// Refresh strictly before this instant.
    refresh_at: Instant,
}

#[derive(Clone)]
pub struct TokenCache {
    inner: Arc<TokenCacheInner>,
}

struct TokenCacheInner {
    sap_key: SapServiceKey,
    state: RwLock<Option<TokenSlot>>,
    refresh_lock: Mutex<()>,
    http: reqwest::Client,
}

impl TokenCache {
    pub fn new(sap_key: SapServiceKey, http: reqwest::Client) -> Self {
        Self {
            inner: Arc::new(TokenCacheInner {
                sap_key,
                state: RwLock::new(None),
                refresh_lock: Mutex::new(()),
                http,
            }),
        }
    }

    /// Return a fresh-enough access token, refreshing if needed.
    pub async fn token(&self) -> Result<String> {
        if let Some(slot) = self.cached().await {
            if Instant::now() < slot.refresh_at {
                return Ok(slot.access_token);
            }
        }

        // Acquire the refresh lock; only one task fetches at a time.
        let _guard = self.inner.refresh_lock.lock().await;

        // Re-check under the lock — another task may have refreshed
        // while we were waiting.
        if let Some(slot) = self.cached().await {
            if Instant::now() < slot.refresh_at {
                return Ok(slot.access_token);
            }
        }

        let new_slot = self.fetch().await?;
        let token = new_slot.access_token.clone();
        *self.inner.state.write().await = Some(new_slot);
        Ok(token)
    }

    async fn cached(&self) -> Option<TokenSlot> {
        self.inner.state.read().await.clone()
    }

    async fn fetch(&self) -> Result<TokenSlot> {
        let url = format!(
            "{}/oauth/token",
            self.inner.sap_key.url.trim_end_matches('/')
        );
        let started = Instant::now();
        let resp = self
            .inner
            .http
            .post(&url)
            .basic_auth(
                &self.inner.sap_key.clientid,
                Some(&self.inner.sap_key.clientsecret),
            )
            .form(&[("grant_type", "client_credentials")])
            .send()
            .await
            .context("XSUAA token endpoint unreachable")?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            // Log without leaking the secret in the URL or body.
            tracing::warn!(
                xsuaa_status = %status,
                body_len = body.len(),
                "XSUAA token fetch failed"
            );
            return Err(anyhow!(
                "XSUAA token endpoint returned {} (body length {} bytes)",
                status,
                body.len()
            ));
        }

        let parsed: TokenResponse = resp
            .json()
            .await
            .context("XSUAA token endpoint returned a non-JSON or unexpected-shape response")?;

        if parsed.expires_in == 0 || parsed.access_token.is_empty() {
            return Err(anyhow!("XSUAA returned an empty token or zero expires_in"));
        }

        let lifetime = Duration::from_secs(parsed.expires_in);
        let refresh_at = if lifetime > REFRESH_LEAD {
            started + lifetime - REFRESH_LEAD
        } else {
            // Pathological short token; still cache for a tick to avoid hammering.
            started + Duration::from_secs(1)
        };
        tracing::info!(
            token_len = parsed.access_token.len(),
            expires_in_s = parsed.expires_in,
            refresh_in_s = (refresh_at - Instant::now()).as_secs(),
            "fetched XSUAA token"
        );
        Ok(TokenSlot {
            access_token: parsed.access_token,
            refresh_at,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ServiceUrls;
    use serde_json::json;
    use wiremock::matchers::{body_string, header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn key(server: &MockServer) -> SapServiceKey {
        SapServiceKey {
            clientid: "client".into(),
            clientsecret: "secret".into(),
            url: server.uri(),
            serviceurls: ServiceUrls {
                ai_api_url: "https://ai.example".into(),
            },
        }
    }

    #[tokio::test]
    async fn caches_token_until_near_expiry() {
        let server = MockServer::start().await;
        // Hand back a token that will be considered fresh for 70-60 = 10 seconds.
        Mock::given(method("POST"))
            .and(path("/oauth/token"))
            .and(header(
                "authorization",
                "Basic Y2xpZW50OnNlY3JldA==", // base64("client:secret")
            ))
            .and(body_string("grant_type=client_credentials"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "access_token": "tok-1",
                "expires_in": 70u64,
            })))
            .expect(1)
            .mount(&server)
            .await;

        let cache = TokenCache::new(key(&server), reqwest::Client::new());

        let t1 = cache.token().await.expect("first fetch");
        let t2 = cache.token().await.expect("cache hit");
        assert_eq!(t1, "tok-1");
        assert_eq!(t2, "tok-1");

        // wiremock's `.expect(1)` would fail at server.verify() if the
        // second call had hit it.
        server.verify().await;
    }

    #[tokio::test]
    async fn refreshes_after_lifetime_minus_lead() {
        let server = MockServer::start().await;
        // Lifetime 61s -> refresh window opens 1s after issuance.
        // Two responses: tok-A then tok-B.
        Mock::given(method("POST"))
            .and(path("/oauth/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "access_token": "tok-A",
                "expires_in": 61u64,
            })))
            .up_to_n_times(1)
            .mount(&server)
            .await;

        let cache = TokenCache::new(key(&server), reqwest::Client::new());
        let t1 = cache.token().await.unwrap();
        assert_eq!(t1, "tok-A");

        // Stage the second response, then wait past the refresh-at instant.
        Mock::given(method("POST"))
            .and(path("/oauth/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "access_token": "tok-B",
                "expires_in": 70u64,
            })))
            .expect(1)
            .mount(&server)
            .await;
        tokio::time::sleep(Duration::from_millis(1500)).await;

        let t2 = cache.token().await.unwrap();
        assert_eq!(t2, "tok-B", "should have refreshed");
        server.verify().await;
    }

    #[tokio::test]
    async fn propagates_xsuaa_error_status() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/oauth/token"))
            .respond_with(ResponseTemplate::new(401).set_body_string("invalid_client"))
            .mount(&server)
            .await;

        let cache = TokenCache::new(key(&server), reqwest::Client::new());
        let err = cache.token().await.unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("401"), "expected 401 in error: {msg}");
        // Critically: the body content should be summarized, not echoed.
        assert!(
            !msg.contains("invalid_client"),
            "error must not echo XSUAA body verbatim: {msg}"
        );
    }
}
