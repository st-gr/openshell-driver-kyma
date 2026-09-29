//! `Driver` — gRPC service implementation that ties the provisioner,
//! enricher, and metrics together. The struct holds `Arc<dyn ...>` of each
//! trait so the same code can run with real Kyma plumbing in production
//! and with `mockall`-generated mocks under test.

use crate::config::Config;
use crate::error::DriverError;
use crate::interfaces::{DriverMetrics, PlatformEnricher, SandboxProvisioner, WatchEvent};
use computev1::pb::{
    compute_driver_server::ComputeDriver, AuthenticateSandboxRequest, AuthenticateSandboxResponse,
    CpuResourceCapabilities, CreateSandboxRequest, CreateSandboxResponse, DeleteSandboxRequest,
    DeleteSandboxResponse, DeleteWorkspaceRequest, DeleteWorkspaceResponse, EnsureWorkspaceRequest,
    EnsureWorkspaceResponse, GetCapabilitiesRequest, GetCapabilitiesResponse, GetSandboxRequest,
    GetSandboxResponse, GpuResourceCapabilities, ListSandboxesRequest, ListSandboxesResponse,
    MemoryResourceCapabilities, PeerMetadata, ProtocolVersion, ResourceCapabilities,
    StartSandboxRequest, StartSandboxResponse, StopSandboxRequest, StopSandboxResponse,
    ValidateSandboxCreateRequest, ValidateSandboxCreateResponse, WatchSandboxesDeletedEvent,
    WatchSandboxesEvent, WatchSandboxesPlatformEvent, WatchSandboxesRequest,
    WatchSandboxesSandboxEvent,
};
use futures::Stream;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Instant;
use tokio_stream::wrappers::ReceiverStream;
use tokio_stream::StreamExt;
use tonic::{Request, Response, Status};

const DRIVER_NAME: &str = "kyma";
/// Baseline compute-extension contract capability. Upstream's
/// `ExtensionFamily::Compute.contract_capability()` yields this literal; this
/// driver vendors only the proto (no `openshell-core`), so it is spelled here.
const COMPUTE_CONTRACT_CAPABILITY: &str = "openshell.compute.contract";

/// Capabilities this driver actually supports, and so the only ones a gateway
/// may require of it. Upstream's own Kubernetes driver advertises exactly the
/// contract capability and no additional ones.
const SUPPORTED_CAPABILITIES: &[&str] = &[COMPUTE_CONTRACT_CAPABILITY];

const DEFAULT_SANDBOX_IMAGE: &str = "ghcr.io/nvidia/openshell-community/sandboxes/base:latest";

pub type WatchStream = Pin<Box<dyn Stream<Item = Result<WatchSandboxesEvent, Status>> + Send>>;

/// `Driver` exposes the OpenShell ComputeDriver gRPC contract.
pub struct Driver {
    provisioner: Arc<dyn SandboxProvisioner>,
    enricher: Arc<dyn PlatformEnricher>,
    metrics: Arc<dyn DriverMetrics>,
    cfg: Config,
}

impl Driver {
    /// Build a Driver with all three dependencies. Use this in tests with
    /// mockall-generated mocks; in `main` the dependencies are the real
    /// `KymaProvisioner`, `KymaEnricher`, and `PrometheusMetrics`.
    #[must_use]
    pub fn new_with_deps(
        provisioner: Arc<dyn SandboxProvisioner>,
        enricher: Arc<dyn PlatformEnricher>,
        metrics: Arc<dyn DriverMetrics>,
        cfg: Config,
    ) -> Self {
        Self {
            provisioner,
            enricher,
            metrics,
            cfg,
        }
    }
}

#[tonic::async_trait]
impl ComputeDriver for Driver {
    async fn get_capabilities(
        &self,
        req: Request<GetCapabilitiesRequest>,
    ) -> Result<Response<GetCapabilitiesResponse>, Status> {
        // Added upstream in v0.1.2: the gateway declares protocol
        // capabilities it requires via `gateway.required_capabilities`, and
        // the field's own comment says drivers "must reject unmet
        // requirements". A real v0.1.2 gateway always requires
        // `openshell.compute.contract`, the baseline compute-extension
        // contract every compute driver advertises (confirmed against a real
        // v0.1.2 gateway by the interop smoke), so a blanket rejection of any
        // nonempty list refuses a perfectly normal gateway. Reject only the
        // requirements this driver does not support; unknown *additional*
        // ones still fail here rather than as a confusing runtime failure.
        if let Some(gateway) = req.into_inner().gateway {
            let unsupported: Vec<&String> = gateway
                .required_capabilities
                .iter()
                .filter(|c| !SUPPORTED_CAPABILITIES.contains(&c.as_str()))
                .collect();
            if !unsupported.is_empty() {
                return Err(Status::failed_precondition(format!(
                    "kyma driver does not support required gateway capabilities: {unsupported:?}"
                )));
            }
        }

        // `supports_gpu` (field 4) was reserved upstream in v0.0.91 — the
        // gateway no longer learns GPU capability from capabilities. A GPU
        // request is now rejected at ValidateSandboxCreate instead, which
        // moves the failure from list-time to create-time. `cfg.gpu_support`
        // still gates that validation; see `has_gpu_capacity`.
        Ok(Response::new(GetCapabilitiesResponse {
            driver_name: DRIVER_NAME.to_string(),
            driver_version: env!("CARGO_PKG_VERSION").to_string(),
            default_image: DEFAULT_SANDBOX_IMAGE.to_string(),
            // Added upstream in v0.0.111: lets a driver ask the gateway to
            // stop sandbox compute on graceful shutdown and restart the
            // retained running intent on startup. That bracketing exists
            // for drivers whose compute is tied to the gateway process's
            // own lifetime. A Kyma sandbox is a Pod/Sandbox CR living in
            // the cluster independently of this driver or the gateway —
            // `WatchSandboxes` already reflects its true state continuously
            // regardless of either process restarting — so there is
            // nothing for the gateway to bracket here.
            gateway_manages_lifecycle: false,
            // This driver verifies the sandbox's projected ServiceAccount
            // token itself (see `authenticate_sandbox`), so it takes over the
            // bootstrap check the gateway performed before v0.1.2. Enabling
            // this obliges create, start, and authenticate to return the same
            // stable `runtime_identity`; see `sandbox_auth::runtime_identity`.
            supports_sandbox_authentication: true,
            // The gateway already waits for the standard OpenShell
            // supervisor session on top of this driver's own platform-ready
            // observation (Sandbox CR conditions via `WatchSandboxes`); this
            // driver does not additionally self-report runtime readiness.
            driver_reports_runtime_readiness: false,
            // Reflects behavior already implemented and tested in
            // `helpers::build_resources` (turns `cpu_limit`/`memory_limit`
            // into Kubernetes container resource limits) and
            // `helpers::effective_gpu_count` (accepts a GPU request with or
            // without an explicit count).
            resource_capabilities: Some(ResourceCapabilities {
                cpu: Some(CpuResourceCapabilities {
                    limit_supported: true,
                }),
                memory: Some(MemoryResourceCapabilities {
                    limit_supported: true,
                }),
                gpu: Some(GpuResourceCapabilities {
                    default_selection_supported: true,
                    count_selection_supported: true,
                }),
            }),
            // This driver does not support provisioning a sandbox from a
            // staged rootfs tar file; zero means "unsupported" per the
            // field's own doc comment.
            rootfs_tar_staging_dir: String::new(),
            rootfs_tar_max_bytes: 0,
            // Mirrors upstream's `extension_metadata()` as used by its own
            // Kubernetes driver: protocol 1.0, the compute contract both
            // supported and required, no additional capabilities.
            extension: Some(PeerMetadata {
                protocol_version: Some(ProtocolVersion { major: 1, minor: 0 }),
                implementation_name: "openshell/kyma".to_string(),
                implementation_version: env!("CARGO_PKG_VERSION").to_string(),
                supported_capabilities: SUPPORTED_CAPABILITIES
                    .iter()
                    .map(|c| c.to_string())
                    .collect(),
                required_capabilities: vec![COMPUTE_CONTRACT_CAPABILITY.to_string()],
            }),
            // TODO(upstream v0.1.2): this driver does not yet implement the
            // new operator admission/policy negotiation system
            // (`DriverSandboxSpec.policy`, `WorkloadIdentityRequest`,
            // `DriverFenceEvidence`, `resolved_identity`, `fence_evidence`,
            // etc. on compute_driver.proto). This driver acknowledges the
            // policy for the handshake but does not yet enforce admission
            // negotiation.
            //
            // Must equal the policy the gateway derives from
            // `[openshell.drivers.kyma]`, or it refuses the driver at
            // startup. Empty is accepted only when the gateway has admission
            // explicitly disabled, which is not the default.
            resource_admission_policy: crate::sandbox_auth::admission_acknowledgement(
                self.cfg.allow_driver_config,
                self.cfg.resource_admission_enabled,
                &crate::sandbox_auth::default_required_labels(),
            ),
        }))
    }

    /// Added upstream in v0.1.2. The gateway delegates sandbox bootstrap
    /// authentication here: it hands over the `Bearer` credential a sandbox
    /// presented on `IssueSandboxToken` and expects the sandbox's identity
    /// back. This driver verifies the projected ServiceAccount token with a
    /// Kubernetes TokenReview — the check the gateway itself performed before
    /// v0.1.2 deleted its in-tree `auth/k8s_sa` authenticator.
    async fn authenticate_sandbox(
        &self,
        req: Request<AuthenticateSandboxRequest>,
    ) -> Result<Response<AuthenticateSandboxResponse>, Status> {
        // The credential is secret-tagged in the proto; it is never logged.
        let credential = req.into_inner().credential;
        let (sandbox_id, runtime_identity) = self
            .provisioner
            .authenticate_sandbox(&credential)
            .await
            .map_err(Status::from)?;
        Ok(Response::new(AuthenticateSandboxResponse {
            sandbox_id,
            runtime_identity,
        }))
    }

    async fn validate_sandbox_create(
        &self,
        req: Request<ValidateSandboxCreateRequest>,
    ) -> Result<Response<ValidateSandboxCreateResponse>, Status> {
        let sandbox = req
            .into_inner()
            .sandbox
            .ok_or_else(|| Status::invalid_argument("sandbox is required"))?;
        self.provisioner
            .validate_create(&sandbox)
            .await
            .map_err(Status::from)?;
        Ok(Response::new(ValidateSandboxCreateResponse {}))
    }

    async fn create_sandbox(
        &self,
        req: Request<CreateSandboxRequest>,
    ) -> Result<Response<CreateSandboxResponse>, Status> {
        let sb = req
            .into_inner()
            .sandbox
            .ok_or_else(|| Status::invalid_argument("sandbox is required"))?;
        if sb.id.is_empty() {
            return Err(Status::invalid_argument("sandbox id is required"));
        }
        if sb.name.is_empty() {
            return Err(Status::invalid_argument("sandbox name is required"));
        }
        let spec = sb
            .spec
            .as_ref()
            .ok_or_else(|| Status::invalid_argument("sandbox spec is required"))?;
        let template = spec
            .template
            .as_ref()
            .ok_or_else(|| Status::invalid_argument("sandbox template is required"))?;
        if template.image.is_empty() {
            return Err(Status::invalid_argument(
                "sandbox template image is required",
            ));
        }

        let start = Instant::now();
        // GPU is now a message (`resource_requirements`), not a bool. Resolve
        // it up front so a `count: 0` request fails before we touch the cluster.
        let gpu_count = crate::helpers::effective_gpu_count(spec.resource_requirements.as_ref())
            .map_err(Status::from)?;
        let name = sb.name.clone();
        let id = sb.id.clone();
        let workspace = sb.workspace.clone();
        let kube_name =
            crate::workspace::kube_resource_name(self.cfg.workspace_mode, &workspace, &name);
        match self.provisioner.create(&sb).await {
            Ok(()) => {
                self.metrics
                    .sandbox_created(&name, gpu_count.is_some(), start.elapsed());

                // Optional APIRule post — gated by --enable-apirule. Failure
                // here does NOT roll back the Sandbox CR; we surface it as
                // a metric and log so operators can investigate. Returning
                // the create-success keeps the gateway happy.
                //
                // The namespace is resolved once, here, and passed to both
                // `render_apirule` (so it lands in the manifest) and
                // `apply_apirule` (so it's the API target) — that is what
                // keeps the two from disagreeing under Managed/Operator
                // mode. `create()` already resolved the same value via the
                // same `namespace_for` for this workspace/mode to place the
                // Sandbox CR, so a resolution error here is not expected in
                // practice, but is handled the same way as an apply
                // failure rather than risked as a silent skip.
                if self.cfg.enable_apirule {
                    match crate::workspace::namespace_for(&self.cfg, &workspace) {
                        Ok(namespace) => {
                            if let Some(manifest) = self
                                .enricher
                                .render_apirule(&id, &kube_name, &name, &workspace, &namespace)
                            {
                                if let Err(e) =
                                    self.provisioner.apply_apirule(manifest, &namespace).await
                                {
                                    self.metrics.sandbox_failed(&name, "apirule_failed");
                                    tracing::warn!(
                                        sandbox_name = %name,
                                        error = %e,
                                        "APIRule create failed; sandbox CR remains"
                                    );
                                }
                            }
                        }
                        Err(e) => {
                            self.metrics.sandbox_failed(&name, "apirule_failed");
                            tracing::warn!(
                                sandbox_name = %name,
                                error = %e,
                                "APIRule namespace resolution failed; sandbox CR remains"
                            );
                        }
                    }
                }

                // Required whenever the driver advertises
                // `supports_sandbox_authentication`. An empty value makes the
                // gateway compensate the create and delete the sandbox.
                let runtime_identity = self
                    .provisioner
                    .runtime_identity(&id)
                    .await
                    .map_err(Status::from)?;
                Ok(Response::new(CreateSandboxResponse { runtime_identity }))
            }
            Err(e) => {
                self.metrics.sandbox_failed(&name, "create_failed");
                Err(Status::from(e))
            }
        }
    }

    async fn get_sandbox(
        &self,
        req: Request<GetSandboxRequest>,
    ) -> Result<Response<GetSandboxResponse>, Status> {
        // Keyed by id, not name — the CR is named `{workspace}--{name}` and
        // the gateway only ever sends the bare name.
        let id = req.into_inner().sandbox_id;
        let sandbox = self.provisioner.get(&id).await.map_err(Status::from)?;
        Ok(Response::new(GetSandboxResponse {
            sandbox: Some(sandbox),
        }))
    }

    async fn list_sandboxes(
        &self,
        _req: Request<ListSandboxesRequest>,
    ) -> Result<Response<ListSandboxesResponse>, Status> {
        let sandboxes = self.provisioner.list().await.map_err(Status::from)?;
        Ok(Response::new(ListSandboxesResponse { sandboxes }))
    }

    async fn stop_sandbox(
        &self,
        req: Request<StopSandboxRequest>,
    ) -> Result<Response<StopSandboxResponse>, Status> {
        let id = req.into_inner().sandbox_id;
        if id.is_empty() {
            return Err(Status::invalid_argument("sandbox_id is required"));
        }
        self.provisioner
            .stop_sandbox(&id)
            .await
            .map_err(Status::from)?;
        Ok(Response::new(StopSandboxResponse {}))
    }

    /// Added upstream in v0.0.106 as the counterpart to `StopSandbox`
    /// (resume a stopped sandbox's platform resources). Delegates to
    /// `SandboxProvisioner::start_sandbox`, mirroring `stop_sandbox` above.
    ///
    /// Three v0.1.2 request fields are deliberately not read:
    /// - `expected_runtime_identity`: its contract is that a driver
    ///   advertising runtime-identity binding must preserve the stable
    ///   resource the identity names and replace only the
    ///   generation-specific runtime component. This driver satisfies that
    ///   by construction: `start_sandbox`/`stop_sandbox` PATCH the Sandbox
    ///   CR's operating mode (`patch_operating_state`) instead of deleting
    ///   and recreating it, so the CR's `metadata.uid` (the only variable
    ///   part of the identity besides the namespace) survives, and the pod
    ///   is the generation-specific component that gets replaced. The
    ///   identity format deliberately excludes the pod UID for this reason.
    /// - `launch_authentication` and `generation_id`: not read. They are
    ///   the analogue of the likewise unread `sandbox_token` (see
    ///   `provisioner.rs`).
    async fn start_sandbox(
        &self,
        req: Request<StartSandboxRequest>,
    ) -> Result<Response<StartSandboxResponse>, Status> {
        let id = req.into_inner().sandbox_id;
        if id.is_empty() {
            return Err(Status::invalid_argument("sandbox_id is required"));
        }
        self.provisioner
            .start_sandbox(&id)
            .await
            .map_err(Status::from)?;
        let runtime_identity = self
            .provisioner
            .runtime_identity(&id)
            .await
            .map_err(Status::from)?;
        Ok(Response::new(StartSandboxResponse { runtime_identity }))
    }

    async fn delete_sandbox(
        &self,
        req: Request<DeleteSandboxRequest>,
    ) -> Result<Response<DeleteSandboxResponse>, Status> {
        let inner = req.into_inner();
        let name = inner.name;
        let id = inner.sandbox_id;

        match self.provisioner.delete(&id).await {
            Ok(()) => {
                self.metrics.sandbox_deleted(&name);
                tracing::info!(sandbox_id = %id, sandbox_name = %name, "sandbox deleted");
                Ok(Response::new(DeleteSandboxResponse { deleted: true }))
            }
            Err(DriverError::NotFound(_)) => {
                Ok(Response::new(DeleteSandboxResponse { deleted: false }))
            }
            Err(DriverError::Kube(kube::Error::Api(s))) if s.code == 404 => {
                Ok(Response::new(DeleteSandboxResponse { deleted: false }))
            }
            Err(e) => {
                self.metrics.sandbox_failed(&name, "delete_failed");
                Err(Status::from(e))
            }
        }
    }

    type WatchSandboxesStream = WatchStream;

    async fn watch_sandboxes(
        &self,
        _req: Request<WatchSandboxesRequest>,
    ) -> Result<Response<Self::WatchSandboxesStream>, Status> {
        let rx = self.provisioner.watch().await.map_err(Status::from)?;
        let metrics = self.metrics.clone();
        let stream = ReceiverStream::new(rx).map(move |event| {
            let mapped = match event {
                WatchEvent::Updated(sandbox) => {
                    metrics.watch_event_received("updated");
                    WatchSandboxesEvent {
                        payload: Some(computev1::pb::watch_sandboxes_event::Payload::Sandbox(
                            WatchSandboxesSandboxEvent {
                                sandbox: Some(*sandbox),
                            },
                        )),
                    }
                }
                WatchEvent::Deleted(id) => {
                    metrics.watch_event_received("deleted");
                    WatchSandboxesEvent {
                        payload: Some(computev1::pb::watch_sandboxes_event::Payload::Deleted(
                            WatchSandboxesDeletedEvent { sandbox_id: id },
                        )),
                    }
                }
                WatchEvent::Platform { sandbox_id, event } => {
                    metrics.watch_event_received("platform");
                    WatchSandboxesEvent {
                        payload: Some(
                            computev1::pb::watch_sandboxes_event::Payload::PlatformEvent(
                                WatchSandboxesPlatformEvent {
                                    sandbox_id,
                                    event: Some(*event),
                                },
                            ),
                        ),
                    }
                }
            };
            Ok(mapped)
        });
        Ok(Response::new(Box::pin(stream) as Self::WatchSandboxesStream))
    }

    /// Dispatches to `SandboxProvisioner::ensure_workspace`. Under `Shared`
    /// mode this is a deliberate successful no-op: `Shared` has no
    /// workspace bootstrap to do, so an error here would only ever be
    /// spurious. Note this RPC is not the only path to bootstrap — the
    /// gateway does not call `EnsureWorkspace` before every sandbox create
    /// (grepping v0.0.109's `grpc/sandbox.rs`, it's called zero times
    /// there), so `KymaProvisioner::create` also bootstraps `Managed`
    /// namespaces lazily, itself, on every create (see `provisioner.rs`).
    /// This RPC remains part of the contract and keeps working as its own
    /// path. `Managed`/`Operator` modes gate on the provisioner's real
    /// bootstrap logic — both are fully implemented (see `workspace.rs`,
    /// `provisioner.rs`).
    async fn ensure_workspace(
        &self,
        req: Request<EnsureWorkspaceRequest>,
    ) -> Result<Response<EnsureWorkspaceResponse>, Status> {
        let ws = req.into_inner().workspace;
        crate::workspace::validate_workspace_name(self.cfg.workspace_mode, &ws)
            .map_err(Status::from)?;
        self.provisioner
            .ensure_workspace(&ws)
            .await
            .map_err(Status::from)?;
        Ok(Response::new(EnsureWorkspaceResponse {}))
    }

    /// Dispatches to `SandboxProvisioner::delete_workspace`. See
    /// `ensure_workspace` for why `Shared` mode must succeed as a no-op.
    async fn delete_workspace(
        &self,
        req: Request<DeleteWorkspaceRequest>,
    ) -> Result<Response<DeleteWorkspaceResponse>, Status> {
        let ws = req.into_inner().workspace;
        crate::workspace::validate_workspace_name(self.cfg.workspace_mode, &ws)
            .map_err(Status::from)?;
        self.provisioner
            .delete_workspace(&ws)
            .await
            .map_err(Status::from)?;
        Ok(Response::new(DeleteWorkspaceResponse {}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::interfaces::{MockDriverMetrics, MockPlatformEnricher, MockSandboxProvisioner};
    use computev1::pb::{DriverSandbox, DriverSandboxSpec, DriverSandboxTemplate};
    use mockall::predicate::*;
    use std::time::Duration;
    use tokio::sync::mpsc;

    fn make_driver_with_mocks(
        cfg: Config,
        provisioner: MockSandboxProvisioner,
        metrics: MockDriverMetrics,
    ) -> Driver {
        Driver::new_with_deps(
            Arc::new(provisioner),
            Arc::new(MockPlatformEnricher::new()),
            Arc::new(metrics),
            cfg,
        )
    }

    fn valid_request_sandbox() -> DriverSandbox {
        DriverSandbox {
            id: "sb-id-1".into(),
            name: "sb-1".into(),
            spec: Some(DriverSandboxSpec {
                template: Some(DriverSandboxTemplate {
                    image: "agent:1.0".into(),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    // ---------- GetCapabilities + StopSandbox ----------

    #[tokio::test]
    async fn get_capabilities_reports_kyma() {
        let cfg = Config {
            gpu_support: true,
            ..Config::default()
        };
        let d =
            make_driver_with_mocks(cfg, MockSandboxProvisioner::new(), MockDriverMetrics::new());
        let r = d
            .get_capabilities(Request::new(GetCapabilitiesRequest::default()))
            .await
            .unwrap()
            .into_inner();
        assert_eq!(r.driver_name, "kyma");
        assert!(!r.driver_version.is_empty());
        assert_eq!(
            r.default_image,
            "ghcr.io/nvidia/openshell-community/sandboxes/base:latest"
        );
    }

    /// Added upstream in v0.0.111. A Kyma sandbox's compute lives in the
    /// cluster independently of the driver or gateway process, so this
    /// driver never needs the gateway to bracket its own restarts with an
    /// explicit stop/start of sandbox compute. Pinning `false` here keeps a
    /// future change from silently opting the gateway into that bracketing.
    #[tokio::test]
    async fn get_capabilities_reports_gateway_does_not_manage_lifecycle() {
        let d = make_driver_with_mocks(
            Config::default(),
            MockSandboxProvisioner::new(),
            MockDriverMetrics::new(),
        );
        let r = d
            .get_capabilities(Request::new(GetCapabilitiesRequest::default()))
            .await
            .unwrap()
            .into_inner();
        assert!(!r.gateway_manages_lifecycle);
    }

    #[tokio::test]
    async fn capabilities_acknowledge_the_admission_policy() {
        let d = make_driver_with_mocks(
            Config::default(),
            MockSandboxProvisioner::new(),
            MockDriverMetrics::new(),
        );
        let caps = d
            .get_capabilities(Request::new(GetCapabilitiesRequest::default()))
            .await
            .expect("capabilities")
            .into_inner();
        assert!(
            caps.resource_admission_policy.starts_with("v1:"),
            "got {}",
            caps.resource_admission_policy
        );
        assert_eq!(
            caps.resource_admission_policy,
            r#"v1:{"allow_driver_config":true,"resource_admission":{"enabled":true,"required_labels":{"openshell.ai/sandbox-attachable":"true","openshell.ai/sandbox-attachable-workspace":"${workspace}"}}}"#
        );
    }

    async fn caps_for(required: Option<Vec<&str>>) -> Result<GetCapabilitiesResponse, Status> {
        let d = make_driver_with_mocks(
            Config::default(),
            MockSandboxProvisioner::new(),
            MockDriverMetrics::new(),
        );
        let gateway = required.map(|r| PeerMetadata {
            required_capabilities: r.into_iter().map(String::from).collect(),
            ..Default::default()
        });
        d.get_capabilities(Request::new(GetCapabilitiesRequest { gateway }))
            .await
            .map(Response::into_inner)
    }

    /// The exact case a real v0.1.2 gateway sends; rejecting it made the
    /// gateway refuse to start.
    #[tokio::test]
    async fn get_capabilities_accepts_the_compute_contract_requirement() {
        caps_for(Some(vec!["openshell.compute.contract"]))
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn get_capabilities_rejects_unknown_required_capability() {
        let s = caps_for(Some(vec!["openshell.compute.does-not-exist"]))
            .await
            .unwrap_err();
        assert_eq!(s.code(), tonic::Code::FailedPrecondition);
        assert!(s.message().contains("openshell.compute.does-not-exist"));
    }

    #[tokio::test]
    async fn get_capabilities_rejects_mixed_requirement_naming_the_unknown_one() {
        let s = caps_for(Some(vec![
            "openshell.compute.contract",
            "openshell.compute.does-not-exist",
        ]))
        .await
        .unwrap_err();
        assert_eq!(s.code(), tonic::Code::FailedPrecondition);
        assert!(s.message().contains("openshell.compute.does-not-exist"));
        assert!(!s.message().contains("openshell.compute.contract"));
    }

    #[tokio::test]
    async fn get_capabilities_accepts_empty_or_absent_gateway_requirements() {
        caps_for(Some(vec![])).await.unwrap();
        caps_for(None).await.unwrap();
    }

    #[tokio::test]
    async fn get_capabilities_advertises_the_compute_contract() {
        let ext = caps_for(None).await.unwrap().extension.expect("extension");
        assert!(ext
            .supported_capabilities
            .contains(&"openshell.compute.contract".to_string()));
        assert!(ext
            .required_capabilities
            .contains(&"openshell.compute.contract".to_string()));
    }

    #[tokio::test]
    async fn authenticate_sandbox_returns_the_identity_from_the_provisioner() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_authenticate_sandbox()
            .returning(|_| Ok(("sb-1".to_string(), "kyma://openshell/cr-uid".to_string())));
        let d = make_driver_with_mocks(Config::default(), p, MockDriverMetrics::new());

        let resp = d
            .authenticate_sandbox(Request::new(AuthenticateSandboxRequest {
                credential: "a-token".into(),
            }))
            .await
            .expect("authentication should succeed")
            .into_inner();

        assert_eq!(resp.sandbox_id, "sb-1");
        assert_eq!(resp.runtime_identity, "kyma://openshell/cr-uid");
    }

    #[tokio::test]
    async fn authenticate_sandbox_propagates_rejection_codes() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_authenticate_sandbox()
            .returning(|_| Err(DriverError::Unauthenticated("nope".into())));
        let d = make_driver_with_mocks(Config::default(), p, MockDriverMetrics::new());

        let err = d
            .authenticate_sandbox(Request::new(AuthenticateSandboxRequest {
                credential: "a-token".into(),
            }))
            .await
            .unwrap_err();

        assert_eq!(err.code(), tonic::Code::Unauthenticated);
    }

    #[tokio::test]
    async fn capabilities_advertise_sandbox_authentication() {
        let d = make_driver_with_mocks(
            Config::default(),
            MockSandboxProvisioner::new(),
            MockDriverMetrics::new(),
        );
        let caps = d
            .get_capabilities(Request::new(GetCapabilitiesRequest::default()))
            .await
            .expect("capabilities")
            .into_inner();
        assert!(caps.supports_sandbox_authentication);
    }

    /// v0.0.91 reserved `supports_gpu`, so capabilities no longer vary with
    /// `--gpu-support`. Pinning that here keeps anyone from reintroducing a
    /// GPU signal on a response field the gateway stopped reading.
    #[tokio::test]
    async fn get_capabilities_is_independent_of_gpu_support() {
        let mut responses = Vec::new();
        for gpu_support in [true, false] {
            let cfg = Config {
                gpu_support,
                ..Config::default()
            };
            let d = make_driver_with_mocks(
                cfg,
                MockSandboxProvisioner::new(),
                MockDriverMetrics::new(),
            );
            responses.push(
                d.get_capabilities(Request::new(GetCapabilitiesRequest::default()))
                    .await
                    .unwrap()
                    .into_inner(),
            );
        }
        assert_eq!(responses[0], responses[1]);
    }

    // ---------- ValidateSandboxCreate ----------

    #[tokio::test]
    async fn validate_returns_failed_precondition_when_provisioner_rejects() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_validate_create()
            .returning(|_| Err(DriverError::FailedPrecondition("no gpu".into())));
        let d = make_driver_with_mocks(Config::default(), p, MockDriverMetrics::new());
        let s = d
            .validate_sandbox_create(Request::new(ValidateSandboxCreateRequest {
                sandbox: Some(valid_request_sandbox()),
            }))
            .await
            .unwrap_err();
        assert_eq!(s.code(), tonic::Code::FailedPrecondition);
    }

    #[tokio::test]
    async fn validate_returns_ok_on_success() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_validate_create().returning(|_| Ok(()));
        let d = make_driver_with_mocks(Config::default(), p, MockDriverMetrics::new());
        d.validate_sandbox_create(Request::new(ValidateSandboxCreateRequest {
            sandbox: Some(valid_request_sandbox()),
        }))
        .await
        .unwrap();
    }

    // ---------- CreateSandbox ----------

    #[tokio::test]
    async fn create_invalid_argument_when_id_missing() {
        let d = make_driver_with_mocks(
            Config::default(),
            MockSandboxProvisioner::new(),
            MockDriverMetrics::new(),
        );
        let mut sb = valid_request_sandbox();
        sb.id = String::new();
        let s = d
            .create_sandbox(Request::new(CreateSandboxRequest { sandbox: Some(sb) }))
            .await
            .unwrap_err();
        assert_eq!(s.code(), tonic::Code::InvalidArgument);
    }

    #[tokio::test]
    async fn create_invalid_argument_when_image_missing() {
        let d = make_driver_with_mocks(
            Config::default(),
            MockSandboxProvisioner::new(),
            MockDriverMetrics::new(),
        );
        let mut sb = valid_request_sandbox();
        sb.spec.as_mut().unwrap().template.as_mut().unwrap().image = String::new();
        let s = d
            .create_sandbox(Request::new(CreateSandboxRequest { sandbox: Some(sb) }))
            .await
            .unwrap_err();
        assert_eq!(s.code(), tonic::Code::InvalidArgument);
    }

    #[tokio::test]
    async fn create_calls_provisioner_and_records_metrics_on_success() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_create().returning(|_| Ok(()));
        p.expect_runtime_identity()
            .returning(|_| Ok("kyma://openshell/cr-uid".to_string()));
        let mut m = MockDriverMetrics::new();
        m.expect_sandbox_created()
            .with(eq("sb-1"), eq(false), always())
            .times(1)
            .return_const(());
        let d = make_driver_with_mocks(Config::default(), p, m);
        d.create_sandbox(Request::new(CreateSandboxRequest {
            sandbox: Some(valid_request_sandbox()),
        }))
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn create_returns_the_runtime_identity() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_create().returning(|_| Ok(()));
        p.expect_runtime_identity()
            .returning(|_| Ok("kyma://openshell/cr-uid".to_string()));
        let mut m = MockDriverMetrics::new();
        m.expect_sandbox_created().return_const(());
        let d = make_driver_with_mocks(Config::default(), p, m);

        let resp = d
            .create_sandbox(Request::new(CreateSandboxRequest {
                sandbox: Some(valid_request_sandbox()),
            }))
            .await
            .expect("create should succeed");

        assert_eq!(
            resp.into_inner().runtime_identity,
            "kyma://openshell/cr-uid"
        );
    }

    #[tokio::test]
    async fn start_returns_the_runtime_identity() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_start_sandbox().returning(|_| Ok(()));
        p.expect_runtime_identity()
            .returning(|_| Ok("kyma://openshell/cr-uid".to_string()));
        let d = make_driver_with_mocks(Config::default(), p, MockDriverMetrics::new());

        let resp = d
            .start_sandbox(Request::new(StartSandboxRequest {
                sandbox_id: "sb-1".into(),
                ..Default::default()
            }))
            .await
            .expect("start should succeed");

        assert_eq!(
            resp.into_inner().runtime_identity,
            "kyma://openshell/cr-uid"
        );
    }

    #[tokio::test]
    async fn create_records_failed_metric_and_returns_internal_on_provisioner_error() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_create()
            .returning(|_| Err(DriverError::Internal(anyhow::anyhow!("boom"))));
        let mut m = MockDriverMetrics::new();
        m.expect_sandbox_failed()
            .with(eq("sb-1"), eq("create_failed"))
            .times(1)
            .return_const(());
        let d = make_driver_with_mocks(Config::default(), p, m);
        let s = d
            .create_sandbox(Request::new(CreateSandboxRequest {
                sandbox: Some(valid_request_sandbox()),
            }))
            .await
            .unwrap_err();
        assert_eq!(s.code(), tonic::Code::Internal);
    }

    // ---------- Get / List / Delete ----------

    #[tokio::test]
    async fn get_returns_not_found_on_provisioner_not_found() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_get()
            .returning(|_| Err(DriverError::NotFound("missing".into())));
        let d = make_driver_with_mocks(Config::default(), p, MockDriverMetrics::new());
        let s = d
            .get_sandbox(Request::new(GetSandboxRequest {
                sandbox_id: String::new(),
                name: "missing".into(),
            }))
            .await
            .unwrap_err();
        assert_eq!(s.code(), tonic::Code::NotFound);
    }

    #[tokio::test]
    async fn get_returns_sandbox_on_success() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_get().returning(|n| {
            Ok(DriverSandbox {
                id: "id-1".into(),
                name: n.to_string(),
                ..Default::default()
            })
        });
        let d = make_driver_with_mocks(Config::default(), p, MockDriverMetrics::new());
        let r = d
            .get_sandbox(Request::new(GetSandboxRequest {
                sandbox_id: String::new(),
                name: "found".into(),
            }))
            .await
            .unwrap()
            .into_inner();
        assert_eq!(r.sandbox.unwrap().id, "id-1");
    }

    #[tokio::test]
    async fn list_returns_internal_on_provisioner_error() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_list()
            .returning(|| Err(DriverError::Internal(anyhow::anyhow!("apiserver down"))));
        let d = make_driver_with_mocks(Config::default(), p, MockDriverMetrics::new());
        let s = d
            .list_sandboxes(Request::new(ListSandboxesRequest {}))
            .await
            .unwrap_err();
        assert_eq!(s.code(), tonic::Code::Internal);
    }

    #[tokio::test]
    async fn list_returns_empty_when_no_sandboxes() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_list().returning(|| Ok(vec![]));
        let d = make_driver_with_mocks(Config::default(), p, MockDriverMetrics::new());
        let r = d
            .list_sandboxes(Request::new(ListSandboxesRequest {}))
            .await
            .unwrap()
            .into_inner();
        assert!(r.sandboxes.is_empty());
    }

    #[tokio::test]
    async fn delete_returns_deleted_true_on_success() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_delete().returning(|_| Ok(()));
        let mut m = MockDriverMetrics::new();
        m.expect_sandbox_deleted().return_const(());
        let d = make_driver_with_mocks(Config::default(), p, m);
        let r = d
            .delete_sandbox(Request::new(DeleteSandboxRequest {
                sandbox_id: "id".into(),
                name: "name".into(),
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(r.deleted);
    }

    #[tokio::test]
    async fn delete_returns_deleted_false_when_not_found() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_delete()
            .returning(|_| Err(DriverError::NotFound("gone".into())));
        let d = make_driver_with_mocks(Config::default(), p, MockDriverMetrics::new());
        let r = d
            .delete_sandbox(Request::new(DeleteSandboxRequest {
                sandbox_id: "id".into(),
                name: "gone".into(),
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(!r.deleted);
    }

    #[tokio::test]
    async fn delete_returns_internal_on_other_error() {
        let mut p = MockSandboxProvisioner::new();
        p.expect_delete()
            .returning(|_| Err(DriverError::Internal(anyhow::anyhow!("boom"))));
        let mut m = MockDriverMetrics::new();
        m.expect_sandbox_failed().return_const(());
        let d = make_driver_with_mocks(Config::default(), p, m);
        let s = d
            .delete_sandbox(Request::new(DeleteSandboxRequest {
                sandbox_id: "id".into(),
                name: "name".into(),
            }))
            .await
            .unwrap_err();
        assert_eq!(s.code(), tonic::Code::Internal);
    }

    // ---------- WatchSandboxes ----------

    #[tokio::test]
    async fn watch_streams_updates_and_deletes_then_closes() {
        // Pre-build a channel with one Updated and one Deleted event, then
        // drop the sender to close the stream.
        let (tx, rx) = mpsc::channel::<WatchEvent>(4);
        tx.send(WatchEvent::Updated(Box::new(DriverSandbox {
            id: "id-A".into(),
            name: "A".into(),
            ..Default::default()
        })))
        .await
        .unwrap();
        tx.send(WatchEvent::Deleted("id-B".into())).await.unwrap();
        drop(tx);

        let mut p = MockSandboxProvisioner::new();
        // mockall can't return a non-Clone mpsc::Receiver directly; wrap in
        // a one-shot Option pattern.
        let rx_cell = std::sync::Mutex::new(Some(rx));
        p.expect_watch()
            .returning(move || Ok(rx_cell.lock().unwrap().take().expect("watch called once")));

        let mut m = MockDriverMetrics::new();
        m.expect_watch_event_received().return_const(());

        let d = make_driver_with_mocks(Config::default(), p, m);
        let resp = d
            .watch_sandboxes(Request::new(WatchSandboxesRequest {}))
            .await
            .unwrap();
        let mut stream = resp.into_inner();

        // First event: Updated(A)
        let ev = stream.next().await.unwrap().unwrap();
        match ev.payload.unwrap() {
            computev1::pb::watch_sandboxes_event::Payload::Sandbox(s) => {
                assert_eq!(s.sandbox.unwrap().name, "A");
            }
            other => panic!("expected sandbox event, got {other:?}"),
        }

        // Second: Deleted(id-B)
        let ev = stream.next().await.unwrap().unwrap();
        match ev.payload.unwrap() {
            computev1::pb::watch_sandboxes_event::Payload::Deleted(d) => {
                assert_eq!(d.sandbox_id, "id-B");
            }
            other => panic!("expected deleted event, got {other:?}"),
        }

        // Third: stream closes when the sender drops.
        assert!(stream.next().await.is_none());
    }

    #[tokio::test]
    async fn watch_surfaces_platform_events() {
        let (tx, rx) = mpsc::channel::<WatchEvent>(4);
        tx.send(WatchEvent::Platform {
            sandbox_id: "id-X".into(),
            event: Box::new(computev1::pb::DriverPlatformEvent {
                event_time: Some(prost_types::Timestamp {
                    seconds: 1_700_000_000,
                    nanos: 0,
                }),
                source: "kubernetes".into(),
                r#type: "Warning".into(),
                reason: "FailedScheduling".into(),
                message: "0/3 nodes are available".into(),
                metadata: std::collections::HashMap::from([("involvedKind".into(), "Pod".into())]),
            }),
        })
        .await
        .unwrap();
        drop(tx);

        let mut p = MockSandboxProvisioner::new();
        let rx_cell = std::sync::Mutex::new(Some(rx));
        p.expect_watch()
            .returning(move || Ok(rx_cell.lock().unwrap().take().expect("watch called once")));

        let mut m = MockDriverMetrics::new();
        m.expect_watch_event_received().return_const(());

        let d = make_driver_with_mocks(Config::default(), p, m);
        let mut stream = d
            .watch_sandboxes(Request::new(WatchSandboxesRequest {}))
            .await
            .unwrap()
            .into_inner();

        let ev = stream.next().await.unwrap().unwrap();
        match ev.payload.unwrap() {
            computev1::pb::watch_sandboxes_event::Payload::PlatformEvent(p) => {
                assert_eq!(p.sandbox_id, "id-X");
                let inner = p.event.unwrap();
                assert_eq!(inner.reason, "FailedScheduling");
                assert_eq!(inner.r#type, "Warning");
                assert_eq!(
                    inner.metadata.get("involvedKind").map(String::as_str),
                    Some("Pod")
                );
            }
            other => panic!("expected platform_event, got {other:?}"),
        }
    }

    // The Driver does not build any axum/tonic server itself; the binary
    // wires that in main.rs (Task 24). This test exercises the type
    // assembly so a future regression on the Stream associated type is
    // caught at compile time.
    #[tokio::test]
    async fn watch_returns_stream_with_correct_associated_type() {
        let (tx, rx) = mpsc::channel::<WatchEvent>(1);
        drop(tx);

        let mut p = MockSandboxProvisioner::new();
        let rx_cell = std::sync::Mutex::new(Some(rx));
        p.expect_watch()
            .returning(move || Ok(rx_cell.lock().unwrap().take().expect("watch called once")));

        let m = MockDriverMetrics::new();
        let d = make_driver_with_mocks(Config::default(), p, m);
        let resp = d
            .watch_sandboxes(Request::new(WatchSandboxesRequest {}))
            .await
            .unwrap();
        let _stream: WatchStream = resp.into_inner();
        // sleep briefly to let the spawned task settle
        let _ = tokio::time::timeout(Duration::from_millis(10), async {
            // no-op
        })
        .await;
    }
}
