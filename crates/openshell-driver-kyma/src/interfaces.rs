//! Driver dependency traits.
//!
//! `Driver` (in `driver.rs`) depends only on these abstract behaviors, not on
//! their concrete `KymaProvisioner` / `KymaEnricher` / `PrometheusMetrics`
//! implementations. Tests get auto-generated mocks via `mockall::automock`.

use crate::error::DriverError;
use async_trait::async_trait;
use computev1::pb::{DriverPlatformEvent, DriverSandbox};
use std::time::Duration;
use tokio::sync::mpsc;

/// One observation produced by the watch fan-in (Sandbox CRs + correlated
/// platform events).
///
/// `Updated` and `Platform` both carry boxed payloads to keep the variant
/// sizes balanced — `DriverSandbox` is several hundred bytes whereas the
/// `Deleted` payload is just a `String`.
#[derive(Debug, Clone)]
pub enum WatchEvent {
    /// A Sandbox CR was created or updated. Carries the latest snapshot.
    Updated(Box<DriverSandbox>),
    /// A Sandbox CR was deleted. Carries the sandbox id label value.
    Deleted(String),
    /// A platform-level event (currently: Kubernetes Warning Events on
    /// the Sandbox CR or its pod) correlated to a sandbox by name.
    Platform {
        sandbox_id: String,
        event: Box<DriverPlatformEvent>,
    },
}

/// Sandbox CR lifecycle. The single trait `Driver` calls on every RPC.
#[cfg_attr(test, mockall::automock)]
#[async_trait]
pub trait SandboxProvisioner: Send + Sync + 'static {
    async fn create(&self, sb: &DriverSandbox) -> Result<(), DriverError>;
    /// Both keyed by sandbox **id**, not name: the CR is named
    /// `{workspace}--{name}`, which the gateway never sees, so the
    /// `openshell.ai/sandbox-id` label is the only stable handle.
    async fn delete(&self, sandbox_id: &str) -> Result<(), DriverError>;
    async fn get(&self, sandbox_id: &str) -> Result<DriverSandbox, DriverError>;
    async fn list(&self) -> Result<Vec<DriverSandbox>, DriverError>;
    async fn watch(&self) -> Result<mpsc::Receiver<WatchEvent>, DriverError>;
    async fn validate_create(&self, sb: &DriverSandbox) -> Result<(), DriverError>;
    /// True when a single node can satisfy `count` GPUs.
    async fn has_gpu_capacity(&self, count: u32) -> Result<bool, DriverError>;

    /// Start a stopped sandbox. Keyed by sandbox **id**, like `get`/`delete`.
    async fn start_sandbox(&self, sandbox_id: &str) -> Result<(), DriverError>;
    /// Stop a running sandbox and wait until its pod is actually gone.
    /// Returning before termination would let the gateway believe a sandbox
    /// is stopped while its pod still runs.
    async fn stop_sandbox(&self, sandbox_id: &str) -> Result<(), DriverError>;

    /// POST a rendered Kyma `APIRule` manifest. No-op when the APIRule
    /// flag is off — the driver layer still gates the call site, this
    /// method only handles the HTTP for callers that pass a manifest.
    async fn apply_apirule(&self, manifest: serde_json::Value) -> Result<(), DriverError>;

    /// Prepare whatever the configured mode needs before a sandbox in
    /// `workspace` can be created. Must be idempotent: the gateway calls this
    /// before *every* create, not once per workspace.
    async fn ensure_workspace(&self, workspace: &str) -> Result<(), DriverError>;

    /// Tear down what `ensure_workspace` created. Only Managed mode has
    /// anything to remove.
    async fn delete_workspace(&self, workspace: &str) -> Result<(), DriverError>;
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
    /// `kube_name` is the `{workspace}--{name}` object name — the APIRule and
    /// the Service it targets are real cluster objects, so they must use the
    /// same name the Sandbox CR does. `sandbox_name` is the bare name, used
    /// only for the label.
    fn render_apirule(
        &self,
        sandbox_id: &str,
        kube_name: &str,
        sandbox_name: &str,
        workspace: &str,
    ) -> Option<serde_json::Value>;
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
        let _p = WatchEvent::Platform {
            sandbox_id: "sb-1".to_string(),
            event: Box::default(),
        };
    }
}
