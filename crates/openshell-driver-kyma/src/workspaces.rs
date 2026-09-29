// SPDX-License-Identifier: Apache-2.0

//! Upstream's create-path namespace step, which `KymaComputeDriver` runs before
//! it forwards `CreateSandbox` when the hooks prepare the workspace first.
//!
//! Upstream's `create_sandbox_inner` (`openshell-driver-kubernetes` `driver.rs`)
//! validates a Managed workspace's namespace name and calls `ensure_namespace`
//! (the namespace, its ServiceAccount and the managed SSH policy) before it
//! creates anything, and its service maps the errors through
//! `ComputeDriverError`, so a namespace another gateway owns is
//! `FAILED_PRECONDITION`. Upstream's `EnsureWorkspace` RPC runs the same step but
//! reports every `ensure_namespace` error as `INTERNAL`; calling the driver
//! directly keeps the create path's codes.

use openshell_core::ComputeDriverError;
use openshell_driver_kubernetes::config::validate_managed_namespace_name;
use openshell_driver_kubernetes::{KubernetesComputeDriver, KubernetesDriverError, WorkspaceMode};
use tonic::Status;

use crate::service::WorkspaceNamespaces;

/// A clone of upstream's driver (it shares the driver's client and
/// configuration), and the gateway id the namespace names are built from.
pub struct UpstreamNamespaces {
    driver: KubernetesComputeDriver,
    gateway_id: String,
}

impl UpstreamNamespaces {
    pub fn new(driver: KubernetesComputeDriver, gateway_id: String) -> Self {
        Self { driver, gateway_id }
    }
}

#[tonic::async_trait]
impl WorkspaceNamespaces for UpstreamNamespaces {
    /// Only Managed mode creates namespaces; in the other modes upstream's
    /// create path has nothing to ensure.
    async fn ensure(&self, workspace: &str) -> Result<(), Status> {
        if !matches!(self.driver.workspace_mode(), WorkspaceMode::Managed) {
            return Ok(());
        }
        check_managed_namespace(&self.gateway_id, workspace)?;
        self.driver
            .ensure_namespace(workspace)
            .await
            .map(drop)
            .map_err(upstream_status)
    }
}

/// Upstream's `validate_workspace_namespace` for Managed mode, which its create
/// path runs before `ensure_namespace`: an invalid name is `INVALID_ARGUMENT`
/// before any API call.
fn check_managed_namespace(gateway_id: &str, workspace: &str) -> Result<(), Status> {
    validate_managed_namespace_name(gateway_id, workspace)
        .map_err(|message| upstream_status(KubernetesDriverError::InvalidArgument(message)))
}

/// The status upstream's `ComputeDriverService::create_sandbox` returns for a
/// driver error.
fn upstream_status(error: KubernetesDriverError) -> Status {
    Status::from(ComputeDriverError::from(error))
}

#[cfg(test)]
mod tests {
    use super::*;

    // The create path's codes, not EnsureWorkspace's blanket INTERNAL: an
    // ownership conflict is FAILED_PRECONDITION, as `create_sandbox_inner` returns.
    #[test]
    fn errors_map_as_upstreams_create_path() {
        for (error, code) in [
            (
                KubernetesDriverError::Precondition(
                    "namespace openshell-gw-a exists but is not owned by this gateway".into(),
                ),
                tonic::Code::FailedPrecondition,
            ),
            (
                KubernetesDriverError::InvalidArgument("bad".into()),
                tonic::Code::InvalidArgument,
            ),
            (KubernetesDriverError::NotFound, tonic::Code::NotFound),
            (
                KubernetesDriverError::Message("timeout creating namespace".into()),
                tonic::Code::Internal,
            ),
        ] {
            assert_eq!(upstream_status(error).code(), code);
        }
    }

    #[test]
    fn an_invalid_managed_namespace_is_refused_as_an_invalid_argument() {
        let status = check_managed_namespace("gw", "Not_A_Label").unwrap_err();
        assert_eq!(status.code(), tonic::Code::InvalidArgument);
        assert!(
            status.message().contains("openshell-gw-Not_A_Label"),
            "{status}"
        );
        assert!(check_managed_namespace("gw", "team-a").is_ok());
    }
}
