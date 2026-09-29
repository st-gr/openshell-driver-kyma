// SPDX-License-Identifier: Apache-2.0

//! `/healthz` and `/readyz` for the chart's probes. Upstream's driver exposes
//! only its gRPC endpoint, so this port is Kyma-owned. `/readyz` turns ready
//! once the compute-driver socket is bound.

use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::get;
use axum::Router;

pub fn router(ready: Arc<AtomicBool>) -> Router {
    Router::new()
        .route("/healthz", get(|| async { (StatusCode::OK, "ok") }))
        .route("/readyz", get(readyz))
        .with_state(ready)
}

async fn readyz(State(ready): State<Arc<AtomicBool>>) -> (StatusCode, &'static str) {
    if ready.load(Ordering::Acquire) {
        (StatusCode::OK, "ready")
    } else {
        (StatusCode::SERVICE_UNAVAILABLE, "not ready")
    }
}

/// Serve the health endpoints on `0.0.0.0:<port>` until `shutdown` resolves.
pub async fn serve(
    port: u16,
    ready: Arc<AtomicBool>,
    shutdown: impl Future<Output = ()> + Send + 'static,
) -> std::io::Result<()> {
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    axum::serve(listener, router(ready))
        .with_graceful_shutdown(shutdown)
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;

    async fn status(router: Router, path: &str) -> StatusCode {
        router
            .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
            .await
            .unwrap()
            .status()
    }

    #[tokio::test]
    async fn healthz_is_always_ok() {
        let ready = Arc::new(AtomicBool::new(false));
        assert_eq!(status(router(ready), "/healthz").await, StatusCode::OK);
    }

    #[tokio::test]
    async fn readyz_follows_the_ready_flag() {
        let ready = Arc::new(AtomicBool::new(false));
        assert_eq!(
            status(router(Arc::clone(&ready)), "/readyz").await,
            StatusCode::SERVICE_UNAVAILABLE
        );
        ready.store(true, Ordering::Release);
        assert_eq!(status(router(ready), "/readyz").await, StatusCode::OK);
    }
}
