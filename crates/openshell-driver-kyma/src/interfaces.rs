//! Driver dependency traits.
//!
//! `Driver` (in `driver.rs`) depends only on these abstract behaviors, not on
//! their concrete `KymaProvisioner` / `KymaEnricher` / `PrometheusMetrics`
//! implementations. Tests get auto-generated mocks via `mockall::automock`.

use crate::error::DriverError;
use async_trait::async_trait;
use computev1::pb::DriverSandbox;
use std::time::Duration;
use tokio::sync::mpsc;

/// One observation produced by the Sandbox CR watcher.
///
/// `Updated` carries a boxed snapshot to keep the variant sizes balanced —
/// `DriverSandbox` is several hundred bytes whereas the `Deleted` payload
/// is just a `String`.
#[derive(Debug, Clone)]
pub enum WatchEvent {
    /// A Sandbox CR was created or updated. Carries the latest snapshot.
    Updated(Box<DriverSandbox>),
    /// A Sandbox CR was deleted. Carries the sandbox id label value.
    Deleted(String),
}

/// Sandbox CR lifecycle. The single trait `Driver` calls on every RPC.
#[cfg_attr(test, mockall::automock)]
#[async_trait]
pub trait SandboxProvisioner: Send + Sync + 'static {
    async fn create(&self, sb: &DriverSandbox) -> Result<(), DriverError>;
    async fn delete(&self, name: &str) -> Result<(), DriverError>;
    async fn get(&self, name: &str) -> Result<DriverSandbox, DriverError>;
    async fn list(&self) -> Result<Vec<DriverSandbox>, DriverError>;
    async fn watch(&self) -> Result<mpsc::Receiver<WatchEvent>, DriverError>;
    async fn validate_create(&self, sb: &DriverSandbox) -> Result<(), DriverError>;
    async fn has_gpu_capacity(&self) -> Result<bool, DriverError>;

    /// POST a rendered Kyma `APIRule` manifest. No-op when the APIRule
    /// flag is off — the driver layer still gates the call site, this
    /// method only handles the HTTP for callers that pass a manifest.
    async fn apply_apirule(&self, manifest: serde_json::Value) -> Result<(), DriverError>;
}

/// Kyma-specific behaviors layered onto the bare provisioner: Pod Security
/// Admission detection, Istio sidecar injection toggle, optional APIRule
/// rendering.
#[cfg_attr(test, mockall::automock)]
#[async_trait]
pub trait PlatformEnricher: Send + Sync + 'static {
    /// Returns the value of `pod-security.kubernetes.io/enforce` on the
    /// given namespace. Returns `Err(FailedPrecondition)` when the label is
    /// absent or set to anything other than `privileged`.
    async fn detect_psa(&self, namespace: &str) -> Result<String, DriverError>;

    /// Mutates the pod template JSON in-place: stamps the Istio inject
    /// label when sandbox injection is disabled, and any other Kyma-specific
    /// adjustments.
    async fn enrich_pod_template(
        &self,
        template: serde_json::Value,
        namespace: &str,
    ) -> Result<serde_json::Value, DriverError>;

    /// Renders the optional APIRule manifest. Returns `None` when the
    /// `--enable-apirule` flag is off.
    fn render_apirule(&self, sandbox_id: &str, sandbox_name: &str) -> Option<serde_json::Value>;
}

/// Bounded-cardinality counters and histograms. Implementations should
/// expose Prometheus text via `/metrics`.
#[cfg_attr(test, mockall::automock)]
pub trait DriverMetrics: Send + Sync + 'static {
    fn sandbox_created(&self, name: &str, gpu: bool, duration: Duration);
    fn sandbox_deleted(&self, name: &str);
    fn sandbox_failed(&self, name: &str, reason: &str);
    fn watch_event_received(&self, event_type: &str);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn watch_event_constructs() {
        let _u = WatchEvent::Updated(Box::default());
        let _d = WatchEvent::Deleted("sb-1".to_string());
    }
}
