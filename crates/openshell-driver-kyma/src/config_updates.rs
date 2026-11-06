// SPDX-License-Identifier: Apache-2.0

//! Upstream's `ComputeDriverConfigurationUpdates` service (v0.1.7 and later)
//! behind the Kyma hooks.
//!
//! `UpdateSandboxConfiguration` changes a stopped sandbox's command and
//! environment in place. An environment update replaces the workload's whole
//! environment, so the Kyma environment `enrich` added at create goes through
//! [`KymaHooks::enrich_environment_update`] first; everything else is forwarded
//! verbatim. An update carries no labels, so the enriched labels stay as created.

use std::sync::Arc;

use openshell_core::proto::compute::v1::{
    compute_driver_configuration_updates_server::ComputeDriverConfigurationUpdates,
    UpdateSandboxConfigurationRequest, UpdateSandboxConfigurationResponse,
};
use tonic::{Request, Response, Status};

use crate::service::KymaHooks;

/// Upstream's configuration-updates service with the Kyma hooks around it.
pub struct KymaConfigurationUpdates<S> {
    inner: S,
    hooks: Arc<dyn KymaHooks>,
}

impl<S> KymaConfigurationUpdates<S> {
    pub fn new(inner: S, hooks: Arc<dyn KymaHooks>) -> Self {
        Self { inner, hooks }
    }
}

#[tonic::async_trait]
impl<S: ComputeDriverConfigurationUpdates> ComputeDriverConfigurationUpdates
    for KymaConfigurationUpdates<S>
{
    async fn update_sandbox_configuration(
        &self,
        mut request: Request<UpdateSandboxConfigurationRequest>,
    ) -> Result<Response<UpdateSandboxConfigurationResponse>, Status> {
        if let Some(environment) = request.get_mut().environment.as_mut() {
            self.hooks.enrich_environment_update(environment);
        }
        self.inner.update_sandbox_configuration(request).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    use openshell_core::proto::compute::v1::{SandboxEnvironmentUpdate, SandboxMainProcessUpdate};

    use crate::enrich::{EnrichConfig, CLAUDE_TELEMETRY_ENV};
    use crate::hooks::KymaHookSet;

    type Received = Arc<Mutex<Option<UpdateSandboxConfigurationRequest>>>;

    /// Records the request upstream would have received.
    struct FakeInner {
        received: Received,
    }

    #[tonic::async_trait]
    impl ComputeDriverConfigurationUpdates for FakeInner {
        async fn update_sandbox_configuration(
            &self,
            request: Request<UpdateSandboxConfigurationRequest>,
        ) -> Result<Response<UpdateSandboxConfigurationResponse>, Status> {
            *self.received.lock().unwrap() = Some(request.into_inner());
            Ok(Response::new(UpdateSandboxConfigurationResponse {}))
        }
    }

    fn service() -> (KymaConfigurationUpdates<FakeInner>, Received) {
        let received = Received::default();
        let hooks = KymaHookSet::new(
            EnrichConfig {
                environment: vec![(CLAUDE_TELEMETRY_ENV.to_string(), "1".to_string())],
            },
            None,
        );
        let inner = FakeInner {
            received: Arc::clone(&received),
        };
        (
            KymaConfigurationUpdates::new(inner, Arc::new(hooks)),
            received,
        )
    }

    #[tokio::test]
    async fn an_environment_update_keeps_the_kyma_environment() {
        let (service, received) = service();
        let mut environment = SandboxEnvironmentUpdate::default();
        environment
            .values
            .insert("APP_MODE".to_string(), "prod".to_string());
        service
            .update_sandbox_configuration(Request::new(UpdateSandboxConfigurationRequest {
                environment: Some(environment),
                ..Default::default()
            }))
            .await
            .unwrap();
        let received = received.lock().unwrap().take().unwrap();
        let values = received.environment.unwrap().values;
        assert_eq!(values["APP_MODE"], "prod");
        assert_eq!(values[CLAUDE_TELEMETRY_ENV], "1");
    }

    // Absent environment means "unchanged" upstream: it must stay absent, or the
    // update would replace the environment with only the Kyma keys.
    #[tokio::test]
    async fn a_command_only_update_is_forwarded_unchanged() {
        let (service, received) = service();
        let request = UpdateSandboxConfigurationRequest {
            main_process: Some(SandboxMainProcessUpdate {
                command: vec!["sleep".to_string(), "60".to_string()],
                tty: false,
            }),
            ..Default::default()
        };
        service
            .update_sandbox_configuration(Request::new(request.clone()))
            .await
            .unwrap();
        assert_eq!(received.lock().unwrap().take().unwrap(), request);
    }
}
