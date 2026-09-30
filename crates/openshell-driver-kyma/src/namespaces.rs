// SPDX-License-Identifier: Apache-2.0

//! Hook 3: Pod Security labels on the namespaces the driver creates.
//!
//! Only Managed mode creates namespaces. Shared mode uses the chart-managed
//! release namespace, and Operator-mode namespaces belong to the operator, so
//! neither is touched. The namespace name comes from upstream's own
//! `namespace_for_workspace`, never re-derived here.
//!
//! The label is applied both after `EnsureWorkspace` and before
//! `CreateSandbox` (see `KymaComputeDriver::create_sandbox`). Upstream's
//! gateway calls `EnsureWorkspace` only in provider-credential flows; its
//! create path never does, because upstream's driver creates the Managed
//! namespace inside `CreateSandbox` itself. Labelling only on `EnsureWorkspace`
//! would leave a fresh workspace's first pods admitted under the cluster
//! default.

use std::time::Duration;

use k8s_openapi::api::core::v1::Namespace;
use kube::api::{Api, Patch, PatchParams};
use openshell_driver_kubernetes::{KubernetesComputeConfig, WorkspaceMode};
use serde_json::json;
use tonic::Status;

pub const PSA_ENFORCE_LABEL: &str = "pod-security.kubernetes.io/enforce";

/// Upstream's `KUBE_API_TIMEOUT` (`driver.rs`). The hook runs on the
/// `EnsureWorkspace` request path, so a hung API call must end here.
const LABEL_TIMEOUT: Duration = Duration::from_secs(30);

pub struct NamespaceLabeler {
    client: kube::Client,
    config: KubernetesComputeConfig,
    level: String,
}

impl NamespaceLabeler {
    /// `None` unless the driver creates namespaces (Managed mode) and a level
    /// is configured.
    pub fn new(
        client: kube::Client,
        config: KubernetesComputeConfig,
        level: String,
    ) -> Option<Self> {
        (matches!(config.workspace_mode, WorkspaceMode::Managed) && !level.is_empty()).then(|| {
            Self {
                client,
                config,
                level,
            }
        })
    }

    /// Apply the Pod Security enforce label to the workspace's namespace.
    pub async fn label(&self, workspace: &str) -> Result<(), Status> {
        self.label_within(workspace, LABEL_TIMEOUT).await
    }

    /// [`Self::label`], giving up after `limit`. Sends a merge patch that sets only
    /// the enforce label, so the namespace's other labels are left alone.
    async fn label_within(&self, workspace: &str, limit: Duration) -> Result<(), Status> {
        let namespace = self
            .config
            .namespace_for_workspace(workspace, None)
            .map_err(Status::internal)?;
        let patch = json!({"metadata": {"labels": {PSA_ENFORCE_LABEL: self.level}}});
        let api = Api::<Namespace>::all(self.client.clone());
        let params = PatchParams::default();
        let patch = Patch::Merge(&patch);
        let request = api.patch(&namespace, &params, &patch);
        match tokio::time::timeout(limit, request).await {
            Ok(Ok(_)) => Ok(()),
            Ok(Err(error)) => Err(Status::unavailable(format!(
                "labelling workspace namespace {namespace} with {PSA_ENFORCE_LABEL}={}: {error}",
                self.level
            ))),
            Err(_elapsed) => Err(Status::unavailable(format!(
                "labelling workspace namespace {namespace} with {PSA_ENFORCE_LABEL}={} timed out after {limit:?}",
                self.level
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{hanging_client, mock_client};

    fn config(mode: WorkspaceMode) -> KubernetesComputeConfig {
        KubernetesComputeConfig {
            workspace_mode: mode,
            gateway_id: "gw".to_string(),
            ..KubernetesComputeConfig::default()
        }
    }

    fn ok(_line: &str) -> (u16, String) {
        (
            200,
            r#"{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"x"}}"#.to_string(),
        )
    }

    // `kube::Client::new` spawns its buffer worker, so it needs a runtime.
    #[tokio::test]
    async fn labeler_exists_only_in_managed_mode_with_a_level() {
        let (client, _) = mock_client(ok);
        assert!(NamespaceLabeler::new(
            client.clone(),
            config(WorkspaceMode::Shared),
            "baseline".into()
        )
        .is_none());
        assert!(NamespaceLabeler::new(
            client.clone(),
            config(WorkspaceMode::Operator),
            "baseline".into()
        )
        .is_none());
        assert!(NamespaceLabeler::new(
            client.clone(),
            config(WorkspaceMode::Managed),
            String::new()
        )
        .is_none());
        assert!(
            NamespaceLabeler::new(client, config(WorkspaceMode::Managed), "baseline".into())
                .is_some()
        );
    }

    #[tokio::test]
    async fn managed_namespace_is_labelled_with_the_level() {
        let (client, seen) = mock_client(ok);
        let expected = config(WorkspaceMode::Managed)
            .namespace_for_workspace("ws", None)
            .expect("managed mode names a namespace");
        NamespaceLabeler::new(client, config(WorkspaceMode::Managed), "baseline".into())
            .unwrap()
            .label("ws")
            .await
            .expect("label succeeds");
        let recorded = seen.lock().unwrap().clone();
        assert_eq!(recorded.len(), 1);
        assert_eq!(
            recorded[0].line,
            format!("PATCH /api/v1/namespaces/{expected}")
        );
        // Merge patch that sets only the enforce label: no other label, no
        // other field, so the namespace's existing labels are left alone.
        let body: serde_json::Value = serde_json::from_str(&recorded[0].body).expect("json body");
        assert_eq!(
            body,
            json!({"metadata": {"labels": {"pod-security.kubernetes.io/enforce": "baseline"}}})
        );
    }

    #[tokio::test]
    async fn patch_failure_becomes_unavailable_naming_the_namespace() {
        let (client, _) = mock_client(|_line: &str| {
            (
                500,
                r#"{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","code":500,"message":"boom"}"#
                    .to_string(),
            )
        });
        let expected = config(WorkspaceMode::Managed)
            .namespace_for_workspace("ws", None)
            .expect("managed mode names a namespace");
        let status =
            NamespaceLabeler::new(client, config(WorkspaceMode::Managed), "baseline".into())
                .unwrap()
                .label("ws")
                .await
                .unwrap_err();
        assert_eq!(status.code(), tonic::Code::Unavailable);
        assert!(status.message().contains(&expected), "{}", status.message());
    }

    // The hook runs on the EnsureWorkspace request path: a hung API call must
    // end at the limit with a retryable status, not block the gateway.
    #[tokio::test]
    async fn labelling_times_out_when_the_api_never_answers() {
        let expected = config(WorkspaceMode::Managed)
            .namespace_for_workspace("ws", None)
            .expect("managed mode names a namespace");
        let labeler = NamespaceLabeler::new(
            hanging_client(),
            config(WorkspaceMode::Managed),
            "baseline".into(),
        )
        .unwrap();

        let status = tokio::time::timeout(
            Duration::from_secs(5),
            labeler.label_within("ws", Duration::from_millis(50)),
        )
        .await
        .expect("label_within returns once its limit is reached")
        .unwrap_err();

        assert_eq!(status.code(), tonic::Code::Unavailable);
        assert!(
            status.message().contains(&expected) && status.message().contains("timed out"),
            "{}",
            status.message()
        );
    }
}
