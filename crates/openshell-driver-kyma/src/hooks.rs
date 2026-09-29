// SPDX-License-Identifier: Apache-2.0

//! The production [`KymaHooks`]: request enrichment, APIRule exposure, and Managed-mode namespace labelling.
//!
//! Namespace labelling runs on `EnsureWorkspace` and also before
//! `CreateSandbox`: upstream's gateway calls `EnsureWorkspace` only in
//! provider-credential flows, while upstream's driver creates the Managed
//! namespace inside `CreateSandbox` itself.

use std::time::Duration;

use openshell_core::proto::compute::v1::DriverSandbox;
use tonic::Status;

use crate::enrich::{enrich, EnrichConfig};
use crate::exposure::{ExposureReconciler, KUBE_API_TIMEOUT, MAX_API_CALLS};
use crate::namespaces::NamespaceLabeler;
use crate::service::KymaHooks;

/// The last-resort bound on one exposure. Each of its API calls is already
/// bounded by upstream's `KUBE_API_TIMEOUT` (`exposure::KUBE_API_TIMEOUT`), so a
/// hung call fails the exposure and still records the Warning Event; this only
/// ends a task that hangs outside them. `after_create` runs detached, so
/// nothing may leak.
const EXPOSURE_TIMEOUT: Duration =
    Duration::from_secs(KUBE_API_TIMEOUT.as_secs() * (MAX_API_CALLS + 1));

pub struct KymaHookSet {
    enrich: EnrichConfig,
    /// `None` unless `--kyma-enable-apirule` is set.
    exposure: Option<ExposureReconciler>,
    /// `None` unless the driver creates namespaces (Managed mode) and a Pod
    /// Security level is configured. Applied on `EnsureWorkspace` and, via
    /// `prepares_workspace_before_create`, before every `CreateSandbox`.
    namespaces: Option<NamespaceLabeler>,
}

impl KymaHookSet {
    pub fn new(
        enrich: EnrichConfig,
        exposure: Option<ExposureReconciler>,
        namespaces: Option<NamespaceLabeler>,
    ) -> Self {
        Self {
            enrich,
            exposure,
            namespaces,
        }
    }

    /// Exposes the sandbox, if enabled, giving up after `limit`. Failures are
    /// logged, never returned: the sandbox itself was created.
    async fn expose_within(&self, sandbox: &DriverSandbox, limit: Duration) {
        let Some(exposure) = &self.exposure else {
            return;
        };
        match tokio::time::timeout(limit, exposure.reconcile(sandbox)).await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                tracing::warn!(sandbox_id = %sandbox.id, %error, "sandbox created but not exposed");
            }
            Err(_elapsed) => {
                tracing::warn!(sandbox_id = %sandbox.id, timeout = ?limit, "sandbox created but exposure timed out");
            }
        }
    }
}

#[tonic::async_trait]
impl KymaHooks for KymaHookSet {
    fn enrich(&self, sandbox: &mut DriverSandbox) {
        enrich(sandbox, &self.enrich);
    }

    async fn after_create(&self, sandbox: DriverSandbox) {
        self.expose_within(&sandbox, EXPOSURE_TIMEOUT).await;
    }

    async fn after_ensure_workspace(&self, workspace: &str) -> Result<(), Status> {
        match &self.namespaces {
            Some(labeler) => labeler.label(workspace).await,
            None => Ok(()),
        }
    }

    /// Upstream creates the Managed namespace inside `CreateSandbox`, so the
    /// label must be applied there too, before the first pod is admitted.
    fn prepares_workspace_before_create(&self) -> bool {
        self.namespaces.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enrich::{ISTIO_INJECT_LABEL, KAGENTI_TYPE_LABEL, KAGENTI_TYPE_VALUE};
    use crate::exposure::ExposureConfig;
    use crate::test_support::{hanging_client, mock_client};
    use openshell_driver_kubernetes::{KubernetesComputeConfig, WorkspaceMode};
    use std::time::Duration;

    #[test]
    fn enrich_hook_applies_the_configured_enrichment() {
        let hooks = KymaHookSet::new(
            EnrichConfig {
                istio_inject: true,
                environment: vec![("KEY".to_string(), "value".to_string())],
            },
            None,
            None,
        );
        let mut sandbox = DriverSandbox::default();
        KymaHooks::enrich(&hooks, &mut sandbox);
        let template = sandbox.spec.unwrap().template.unwrap();
        assert_eq!(template.labels[ISTIO_INJECT_LABEL], "true");
        assert_eq!(template.labels[KAGENTI_TYPE_LABEL], KAGENTI_TYPE_VALUE);
        assert_eq!(template.environment["KEY"], "value");
    }

    // The spawned after_create task cannot report a failure to anyone: it must
    // log and return, never panic or propagate.
    #[tokio::test]
    async fn after_create_swallows_an_exposure_failure() {
        let (client, seen) = mock_client(|_| (500, "{}".to_string()));
        let exposure = ExposureReconciler::new(
            client,
            ExposureConfig {
                cluster_domain: "example.org".to_string(),
                ingress_namespace: "istio-system".to_string(),
                search_namespace: Some("sandboxes".to_string()),
                gateway_id: "gw".to_string(),
            },
        );
        let hooks = KymaHookSet::new(EnrichConfig::default(), Some(exposure), None);

        KymaHooks::after_create(
            &hooks,
            DriverSandbox {
                id: "sb-1".to_string(),
                ..Default::default()
            },
        )
        .await;

        let recorded = seen.lock().unwrap().clone();
        assert_eq!(recorded.len(), 1, "the failed lookup is not retried");
        assert!(recorded[0].line.starts_with("GET "), "{}", recorded[0].line);
    }

    // The task is detached: a hung API call must end at the timeout, not leak.
    #[tokio::test]
    async fn exposure_gives_up_when_the_api_never_answers() {
        let exposure = ExposureReconciler::new(
            hanging_client(),
            ExposureConfig {
                cluster_domain: "example.org".to_string(),
                ingress_namespace: "istio-system".to_string(),
                search_namespace: Some("sandboxes".to_string()),
                gateway_id: "gw".to_string(),
            },
        );
        let hooks = KymaHookSet::new(EnrichConfig::default(), Some(exposure), None);
        let sandbox = DriverSandbox {
            id: "sb-1".to_string(),
            ..Default::default()
        };

        tokio::time::timeout(
            Duration::from_secs(5),
            hooks.expose_within(&sandbox, Duration::from_millis(50)),
        )
        .await
        .expect("expose_within returns once its limit is reached");
    }

    fn labeler(client: kube::Client) -> NamespaceLabeler {
        NamespaceLabeler::new(
            client,
            KubernetesComputeConfig {
                workspace_mode: WorkspaceMode::Managed,
                gateway_id: "gw".to_string(),
                ..KubernetesComputeConfig::default()
            },
            "baseline".to_string(),
        )
        .expect("managed mode with a level")
    }

    #[tokio::test]
    async fn ensure_workspace_without_a_labeler_touches_nothing() {
        let hooks = KymaHookSet::new(EnrichConfig::default(), None, None);
        KymaHooks::after_ensure_workspace(&hooks, "ws")
            .await
            .expect("no labeler, nothing to do");
    }

    #[tokio::test]
    async fn ensure_workspace_labels_the_namespace() {
        let (client, seen) = mock_client(|_| {
            (
                200,
                r#"{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"x"}}"#.to_string(),
            )
        });
        let hooks = KymaHookSet::new(EnrichConfig::default(), None, Some(labeler(client)));

        KymaHooks::after_ensure_workspace(&hooks, "ws")
            .await
            .expect("label succeeds");

        let recorded = seen.lock().unwrap().clone();
        assert_eq!(recorded.len(), 1);
        assert!(
            recorded[0].line.starts_with("PATCH "),
            "{}",
            recorded[0].line
        );
    }

    // The gateway retries EnsureWorkspace on error, so a failed label must be
    // returned, not swallowed.
    #[tokio::test]
    async fn ensure_workspace_returns_a_labelling_failure() {
        let (client, _) = mock_client(|_| (500, "{}".to_string()));
        let hooks = KymaHookSet::new(EnrichConfig::default(), None, Some(labeler(client)));

        let status = KymaHooks::after_ensure_workspace(&hooks, "ws")
            .await
            .unwrap_err();

        assert_eq!(status.code(), tonic::Code::Unavailable);
    }

    #[tokio::test]
    async fn create_prepares_the_workspace_only_when_a_labeler_is_configured() {
        let (client, _) = mock_client(|_| (200, "{}".to_string()));
        let with = KymaHookSet::new(EnrichConfig::default(), None, Some(labeler(client)));
        let without = KymaHookSet::new(EnrichConfig::default(), None, None);

        assert!(KymaHooks::prepares_workspace_before_create(&with));
        assert!(!KymaHooks::prepares_workspace_before_create(&without));
    }
}
