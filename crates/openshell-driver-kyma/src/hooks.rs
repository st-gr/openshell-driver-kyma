// SPDX-License-Identifier: Apache-2.0

//! The production [`KymaHooks`]: request enrichment and APIRule exposure now;
//! namespace labelling joins in a later task.

use openshell_core::proto::compute::v1::DriverSandbox;
use tonic::Status;

use crate::enrich::{enrich, EnrichConfig};
use crate::exposure::ExposureReconciler;
use crate::service::KymaHooks;

pub struct KymaHookSet {
    enrich: EnrichConfig,
    /// `None` unless `--kyma-enable-apirule` is set.
    exposure: Option<ExposureReconciler>,
}

impl KymaHookSet {
    pub fn new(enrich: EnrichConfig, exposure: Option<ExposureReconciler>) -> Self {
        Self { enrich, exposure }
    }
}

#[tonic::async_trait]
impl KymaHooks for KymaHookSet {
    fn enrich(&self, sandbox: &mut DriverSandbox) {
        enrich(sandbox, &self.enrich);
    }

    async fn after_create(&self, sandbox: DriverSandbox) {
        let Some(exposure) = &self.exposure else {
            return;
        };
        if let Err(error) = exposure.reconcile(&sandbox.id).await {
            tracing::warn!(sandbox_id = %sandbox.id, %error, "sandbox created but not exposed");
        }
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
    use crate::test_support::mock_client;

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
}
