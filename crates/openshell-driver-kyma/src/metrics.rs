//! Prometheus metrics + axum HTTP server for `/healthz`, `/readyz`,
//! `/metrics`. Bounded label cardinality: `result` and `event_type` are
//! enums-as-strings (`ok` / `failed`, `updated` / `deleted`), never user
//! input.

use crate::interfaces::DriverMetrics;
use axum::{
    extract::State,
    http::{header, StatusCode},
    response::IntoResponse,
    routing::get,
    Router,
};
use prometheus::{
    Encoder, HistogramOpts, HistogramVec, IntCounter, IntCounterVec, Opts, Registry, TextEncoder,
};
use std::net::SocketAddr;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;

const METRIC_PREFIX: &str = "openshell_driver_";

/// `PrometheusMetrics` implements `DriverMetrics` over a `prometheus::Registry`.
pub struct PrometheusMetrics {
    registry: Registry,
    sandbox_created: IntCounterVec,
    sandbox_deleted: IntCounter,
    sandbox_failed: IntCounterVec,
    watch_events: IntCounterVec,
    create_duration: HistogramVec,
}

impl PrometheusMetrics {
    /// Build a fresh metrics suite. Each metric name is prefixed with
    /// `openshell_driver_` so all driver-emitted series are easy to filter.
    pub fn new() -> Result<Self, prometheus::Error> {
        let registry = Registry::new();

        let sandbox_created = IntCounterVec::new(
            Opts::new(
                format!("{METRIC_PREFIX}sandbox_created_total"),
                "Sandbox CRs created by the driver.",
            ),
            &["result", "gpu"],
        )?;
        let sandbox_deleted = IntCounter::with_opts(Opts::new(
            format!("{METRIC_PREFIX}sandbox_deleted_total"),
            "Sandbox CRs deleted by the driver.",
        ))?;
        let sandbox_failed = IntCounterVec::new(
            Opts::new(
                format!("{METRIC_PREFIX}sandbox_failed_total"),
                "Sandbox lifecycle operations that returned an error.",
            ),
            &["reason"],
        )?;
        let watch_events = IntCounterVec::new(
            Opts::new(
                format!("{METRIC_PREFIX}watch_events_total"),
                "Sandbox watch events forwarded to the gateway.",
            ),
            &["event_type"],
        )?;
        let create_duration = HistogramVec::new(
            HistogramOpts::new(
                format!("{METRIC_PREFIX}sandbox_create_duration_seconds"),
                "Time taken to provision a Sandbox CR.",
            )
            .buckets(prometheus::DEFAULT_BUCKETS.to_vec()),
            &["gpu"],
        )?;

        registry.register(Box::new(sandbox_created.clone()))?;
        registry.register(Box::new(sandbox_deleted.clone()))?;
        registry.register(Box::new(sandbox_failed.clone()))?;
        registry.register(Box::new(watch_events.clone()))?;
        registry.register(Box::new(create_duration.clone()))?;

        Ok(Self {
            registry,
            sandbox_created,
            sandbox_deleted,
            sandbox_failed,
            watch_events,
            create_duration,
        })
    }

    /// Render the full registry as Prometheus text format.
    #[must_use]
    pub fn gather_text(&self) -> String {
        let encoder = TextEncoder::new();
        let mut buf = Vec::new();
        let _ = encoder.encode(&self.registry.gather(), &mut buf);
        String::from_utf8_lossy(&buf).into_owned()
    }

    /// Borrow the underlying registry — used by the axum handler.
    #[must_use]
    pub fn registry(&self) -> &Registry {
        &self.registry
    }
}

impl DriverMetrics for PrometheusMetrics {
    fn sandbox_created(&self, _name: &str, gpu: bool, duration: Duration) {
        let gpu_label = if gpu { "true" } else { "false" };
        self.sandbox_created
            .with_label_values(&["ok", gpu_label])
            .inc();
        self.create_duration
            .with_label_values(&[gpu_label])
            .observe(duration.as_secs_f64());
    }

    fn sandbox_deleted(&self, _name: &str) {
        self.sandbox_deleted.inc();
    }

    fn sandbox_failed(&self, _name: &str, reason: &str) {
        self.sandbox_failed.with_label_values(&[reason]).inc();
    }

    fn watch_event_received(&self, event_type: &str) {
        self.watch_events.with_label_values(&[event_type]).inc();
    }
}

/// Shared state for the axum router.
#[derive(Clone)]
pub struct HealthState {
    pub metrics: Arc<PrometheusMetrics>,
    pub ready: Arc<AtomicBool>,
}

/// Build the axum router that exposes /healthz, /readyz, /metrics.
#[must_use]
pub fn router(state: HealthState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/metrics", get(metrics))
        .with_state(state)
}

/// Serve the health/readiness/metrics HTTP endpoints until the future is
/// cancelled or the listener errors out. Intended to be spawned alongside
/// the gRPC server in `main.rs`.
pub async fn serve_http(
    addr: SocketAddr,
    metrics: Arc<PrometheusMetrics>,
    ready: Arc<AtomicBool>,
) -> Result<(), std::io::Error> {
    let app = router(HealthState { metrics, ready });
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app)
        .await
        .map_err(std::io::Error::other)
}

async fn healthz() -> impl IntoResponse {
    (StatusCode::OK, "ok")
}

async fn readyz(State(state): State<HealthState>) -> impl IntoResponse {
    if state.ready.load(Ordering::SeqCst) {
        (StatusCode::OK, "ok")
    } else {
        (StatusCode::SERVICE_UNAVAILABLE, "not ready")
    }
}

async fn metrics(State(state): State<HealthState>) -> impl IntoResponse {
    let body = state.metrics.gather_text();
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/plain; version=0.0.4")],
        body,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn metrics_register_without_panic() {
        let m = PrometheusMetrics::new().unwrap();
        // Sanity check: registry exists and gather_text doesn't panic.
        // Note: prometheus 0.14's gather() returns only metrics that have
        // observed at least one sample, so the count starts low.
        let _ = m.gather_text();
        // After incrementing one counter, at least that counter family
        // appears in the gathered text.
        m.sandbox_deleted("a");
        let text = m.gather_text();
        assert!(text.contains("openshell_driver_sandbox_deleted_total"));
    }

    #[test]
    fn sandbox_created_increments_counter_and_histogram() {
        let m = PrometheusMetrics::new().unwrap();
        m.sandbox_created("foo", false, Duration::from_millis(10));
        let text = m.gather_text();
        assert!(text.contains("openshell_driver_sandbox_created_total"));
        assert!(text.contains("result=\"ok\""));
        assert!(text.contains("gpu=\"false\""));
        assert!(text.contains("openshell_driver_sandbox_create_duration_seconds"));
    }

    #[test]
    fn watch_event_received_records_event_type_label() {
        let m = PrometheusMetrics::new().unwrap();
        m.watch_event_received("updated");
        m.watch_event_received("deleted");
        let text = m.gather_text();
        assert!(text.contains("event_type=\"updated\""));
        assert!(text.contains("event_type=\"deleted\""));
    }

    #[test]
    fn sandbox_failed_records_reason_label() {
        let m = PrometheusMetrics::new().unwrap();
        m.sandbox_failed("foo", "create_failed");
        let text = m.gather_text();
        assert!(text.contains("reason=\"create_failed\""));
    }

    #[tokio::test]
    async fn axum_serves_metrics_health_ready() {
        let metrics = Arc::new(PrometheusMetrics::new().unwrap());
        metrics.sandbox_created("foo", false, Duration::from_millis(1));
        let ready = Arc::new(AtomicBool::new(true));

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = router(HealthState {
            metrics: metrics.clone(),
            ready: ready.clone(),
        });
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });

        // /healthz
        let resp = reqwest::get(format!("http://{addr}/healthz")).await.unwrap();
        assert_eq!(resp.status(), 200);
        assert_eq!(resp.text().await.unwrap(), "ok");

        // /readyz when ready
        let resp = reqwest::get(format!("http://{addr}/readyz")).await.unwrap();
        assert_eq!(resp.status(), 200);

        // /metrics
        let resp = reqwest::get(format!("http://{addr}/metrics")).await.unwrap();
        assert_eq!(resp.status(), 200);
        let body = resp.text().await.unwrap();
        assert!(body.contains("openshell_driver_sandbox_created_total"));

        // /readyz when not ready
        ready.store(false, Ordering::SeqCst);
        let resp = reqwest::get(format!("http://{addr}/readyz")).await.unwrap();
        assert_eq!(resp.status(), 503);

        server.abort();
    }
}
