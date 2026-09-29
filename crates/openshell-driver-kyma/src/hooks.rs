// SPDX-License-Identifier: Apache-2.0

//! The production [`KymaHooks`]: request enrichment and APIRule exposure now;
//! namespace labelling joins in a later task.

use std::time::Duration;

use openshell_core::proto::compute::v1::DriverSandbox;
use tonic::Status;

use crate::enrich::{enrich, EnrichConfig};
use crate::exposure::ExposureReconciler;
use crate::service::KymaHooks;

/// Upstream's `KUBE_API_TIMEOUT` (`driver.rs`). `after_create` runs detached,
/// so a hung API call must end here rather than leak the task.
const EXPOSURE_TIMEOUT: Duration = Duration::from_secs(30);

pub struct KymaHookSet {
    enrich: EnrichConfig,
    /// `None` unless `--kyma-enable-apirule` is set.
    exposure: Option<ExposureReconciler>,
}

impl KymaHookSet {
    pub fn new(enrich: EnrichConfig, exposure: Option<ExposureReconciler>) -> Self {
        Self { enrich, exposure }
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

    async fn after_ensure_workspace(&self, _workspace: &str) -> Result<(), Status> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enrich::{ISTIO_INJECT_LABEL, KAGENTI_TYPE_LABEL, KAGENTI_TYPE_VALUE};
    use crate::exposure::ExposureConfig;
    use crate::test_support::{hanging_client, mock_client};
    use std::time::Duration;

    #[test]
    fn enrich_hook_applies_the_configured_enrichment() {
        let hooks = KymaHookSet::new(
            EnrichConfig {
                istio_inject: true,
                environment: vec![("KEY".to_string(), "value".to_string())],
            },
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
            },
        );
        let hooks = KymaHookSet::new(EnrichConfig::default(), Some(exposure));

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
            },
        );
        let hooks = KymaHookSet::new(EnrichConfig::default(), Some(exposure));
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
}
