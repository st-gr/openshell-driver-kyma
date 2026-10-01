// SPDX-License-Identifier: Apache-2.0

//! The production [`KymaHooks`]: request enrichment and Managed-mode namespace labelling.
//!
//! Namespace labelling runs on `EnsureWorkspace` and also before
//! `CreateSandbox`: upstream's gateway calls `EnsureWorkspace` only in
//! provider-credential flows, while upstream's driver creates the Managed
//! namespace inside `CreateSandbox` itself.

use openshell_core::proto::compute::v1::DriverSandbox;
use tonic::Status;

use crate::enrich::{enrich, EnrichConfig};
use crate::namespaces::NamespaceLabeler;
use crate::service::KymaHooks;

pub struct KymaHookSet {
    enrich: EnrichConfig,
    /// `None` unless the driver creates namespaces (Managed mode) and a Pod
    /// Security level is configured. Applied on `EnsureWorkspace` and, via
    /// `prepares_workspace_before_create`, before every `CreateSandbox`.
    namespaces: Option<NamespaceLabeler>,
}

impl KymaHookSet {
    pub fn new(enrich: EnrichConfig, namespaces: Option<NamespaceLabeler>) -> Self {
        Self { enrich, namespaces }
    }
}

#[tonic::async_trait]
impl KymaHooks for KymaHookSet {
    fn enrich(&self, sandbox: &mut DriverSandbox) {
        enrich(sandbox, &self.enrich);
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
    use crate::test_support::mock_client;
    use openshell_driver_kubernetes::{KubernetesComputeConfig, WorkspaceMode};

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
        let hooks = KymaHookSet::new(EnrichConfig::default(), None);
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
        let hooks = KymaHookSet::new(EnrichConfig::default(), Some(labeler(client)));

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
        let hooks = KymaHookSet::new(EnrichConfig::default(), Some(labeler(client)));

        let status = KymaHooks::after_ensure_workspace(&hooks, "ws")
            .await
            .unwrap_err();

        assert_eq!(status.code(), tonic::Code::Unavailable);
    }

    #[tokio::test]
    async fn create_prepares_the_workspace_only_when_a_labeler_is_configured() {
        let (client, _) = mock_client(|_| (200, "{}".to_string()));
        let with = KymaHookSet::new(EnrichConfig::default(), Some(labeler(client)));
        let without = KymaHookSet::new(EnrichConfig::default(), None);

        assert!(KymaHooks::prepares_workspace_before_create(&with));
        assert!(!KymaHooks::prepares_workspace_before_create(&without));
    }
}
