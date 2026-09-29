// SPDX-License-Identifier: Apache-2.0

//! The Kyma compute driver: upstream's `ComputeDriverService` behind three
//! Kyma hooks.
//!
//! Every RPC is forwarded verbatim. Only `CreateSandbox` (enrich and prepare
//! the workspace before, expose after) and `EnsureWorkspace` (label after) add
//! behaviour, so capabilities, admission, sandbox authentication and runtime
//! identity are upstream's own — that is what makes this driver behave like
//! upstream's.

use std::sync::Arc;

use openshell_core::proto::compute::v1::{
    compute_driver_server::ComputeDriver, AuthenticateSandboxRequest, AuthenticateSandboxResponse,
    CreateSandboxRequest, CreateSandboxResponse, DeleteSandboxRequest, DeleteSandboxResponse,
    DeleteWorkspaceRequest, DeleteWorkspaceResponse, DriverSandbox, EnsureWorkspaceRequest,
    EnsureWorkspaceResponse, GetCapabilitiesRequest, GetCapabilitiesResponse, GetSandboxRequest,
    GetSandboxResponse, ListSandboxesRequest, ListSandboxesResponse, StartSandboxRequest,
    StartSandboxResponse, StopSandboxRequest, StopSandboxResponse, ValidateSandboxCreateRequest,
    ValidateSandboxCreateResponse, WatchSandboxesRequest,
};
use tonic::{Request, Response, Status};

/// Kyma behaviour around upstream's RPCs.
#[tonic::async_trait]
pub trait KymaHooks: Send + Sync + 'static {
    /// Edits the sandbox before upstream sees it. Must not fail.
    fn enrich(&self, sandbox: &mut DriverSandbox);

    /// Runs after upstream created the sandbox, off the request path. It cannot
    /// fail the create; implementations report their own failures.
    async fn after_create(&self, sandbox: DriverSandbox);

    /// Runs after upstream ensured a workspace, on `EnsureWorkspace` and, when
    /// `prepares_workspace_before_create`, on `CreateSandbox`. An error fails
    /// that RPC so the gateway retries.
    async fn after_ensure_workspace(&self, workspace: &str) -> Result<(), Status>;

    /// Whether `CreateSandbox` must ensure (and run `after_ensure_workspace`
    /// for) the sandbox's workspace before upstream creates anything.
    ///
    /// Upstream's gateway calls `EnsureWorkspace` only in provider-credential
    /// flows; its create path never does. Upstream's driver creates a Managed
    /// namespace inside `CreateSandbox` itself, so a hook that must act on the
    /// namespace before the first pod exists cannot rely on `EnsureWorkspace`.
    fn prepares_workspace_before_create(&self) -> bool {
        false
    }
}

/// Hooks that do nothing: the driver behaves exactly like upstream's.
pub struct NoHooks;

#[tonic::async_trait]
impl KymaHooks for NoHooks {
    fn enrich(&self, _sandbox: &mut DriverSandbox) {}
    async fn after_create(&self, _sandbox: DriverSandbox) {}
    async fn after_ensure_workspace(&self, _workspace: &str) -> Result<(), Status> {
        Ok(())
    }
}

/// Upstream's compute driver service with Kyma hooks around it.
pub struct KymaComputeDriver<S> {
    inner: S,
    hooks: Arc<dyn KymaHooks>,
}

impl<S> KymaComputeDriver<S> {
    pub fn new(inner: S, hooks: Arc<dyn KymaHooks>) -> Self {
        Self { inner, hooks }
    }
}

#[tonic::async_trait]
impl<S: ComputeDriver> ComputeDriver for KymaComputeDriver<S> {
    type WatchSandboxesStream = S::WatchSandboxesStream;

    async fn authenticate_sandbox(
        &self,
        request: Request<AuthenticateSandboxRequest>,
    ) -> Result<Response<AuthenticateSandboxResponse>, Status> {
        self.inner.authenticate_sandbox(request).await
    }

    async fn get_capabilities(
        &self,
        request: Request<GetCapabilitiesRequest>,
    ) -> Result<Response<GetCapabilitiesResponse>, Status> {
        self.inner.get_capabilities(request).await
    }

    async fn validate_sandbox_create(
        &self,
        request: Request<ValidateSandboxCreateRequest>,
    ) -> Result<Response<ValidateSandboxCreateResponse>, Status> {
        self.inner.validate_sandbox_create(request).await
    }

    async fn get_sandbox(
        &self,
        request: Request<GetSandboxRequest>,
    ) -> Result<Response<GetSandboxResponse>, Status> {
        self.inner.get_sandbox(request).await
    }

    async fn list_sandboxes(
        &self,
        request: Request<ListSandboxesRequest>,
    ) -> Result<Response<ListSandboxesResponse>, Status> {
        self.inner.list_sandboxes(request).await
    }

    async fn create_sandbox(
        &self,
        mut request: Request<CreateSandboxRequest>,
    ) -> Result<Response<CreateSandboxResponse>, Status> {
        if let Some(sandbox) = request.get_mut().sandbox.as_mut() {
            self.hooks.enrich(sandbox);
        }
        if self.hooks.prepares_workspace_before_create() {
            // Without a sandbox there is no workspace: forward unchanged and let
            // upstream reject the request.
            if let Some(sandbox) = request.get_ref().sandbox.as_ref() {
                // Upstream's own idempotent path, so the namespace exists (or is
                // ownership-checked) and is prepared before any pod is admitted.
                // A failure here must not reach upstream's create.
                let workspace = sandbox.workspace.clone();
                self.inner
                    .ensure_workspace(Request::new(EnsureWorkspaceRequest {
                        workspace: workspace.clone(),
                    }))
                    .await?;
                self.hooks.after_ensure_workspace(&workspace).await?;
            }
        }
        let created = request.get_ref().sandbox.clone();
        let response = self.inner.create_sandbox(request).await?;
        if let Some(sandbox) = created {
            // Off the request path: exposure must never delay or fail a create
            // that upstream already completed.
            let hooks = Arc::clone(&self.hooks);
            tokio::spawn(async move { hooks.after_create(sandbox).await });
        }
        Ok(response)
    }

    async fn stop_sandbox(
        &self,
        request: Request<StopSandboxRequest>,
    ) -> Result<Response<StopSandboxResponse>, Status> {
        self.inner.stop_sandbox(request).await
    }

    async fn start_sandbox(
        &self,
        request: Request<StartSandboxRequest>,
    ) -> Result<Response<StartSandboxResponse>, Status> {
        self.inner.start_sandbox(request).await
    }

    async fn delete_sandbox(
        &self,
        request: Request<DeleteSandboxRequest>,
    ) -> Result<Response<DeleteSandboxResponse>, Status> {
        self.inner.delete_sandbox(request).await
    }

    async fn watch_sandboxes(
        &self,
        request: Request<WatchSandboxesRequest>,
    ) -> Result<Response<Self::WatchSandboxesStream>, Status> {
        self.inner.watch_sandboxes(request).await
    }

    async fn ensure_workspace(
        &self,
        request: Request<EnsureWorkspaceRequest>,
    ) -> Result<Response<EnsureWorkspaceResponse>, Status> {
        let workspace = request.get_ref().workspace.clone();
        let response = self.inner.ensure_workspace(request).await?;
        self.hooks.after_ensure_workspace(&workspace).await?;
        Ok(response)
    }

    async fn delete_workspace(
        &self,
        request: Request<DeleteWorkspaceRequest>,
    ) -> Result<Response<DeleteWorkspaceResponse>, Status> {
        self.inner.delete_workspace(request).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::pin::Pin;
    use std::sync::Mutex;
    use std::time::Duration;

    use futures::Stream;
    use openshell_core::proto::compute::v1::WatchSandboxesEvent;
    use tokio::sync::mpsc;

    type TestWatchStream =
        Pin<Box<dyn Stream<Item = Result<WatchSandboxesEvent, Status>> + Send + 'static>>;

    #[derive(Default)]
    struct FakeState {
        calls: Mutex<Vec<&'static str>>,
        created: Mutex<Option<DriverSandbox>>,
        fail_create: bool,
        fail_ensure: bool,
    }

    struct FakeInner {
        state: Arc<FakeState>,
    }

    impl FakeInner {
        fn new(state: FakeState) -> (Self, Arc<FakeState>) {
            let state = Arc::new(state);
            (
                Self {
                    state: Arc::clone(&state),
                },
                state,
            )
        }
        fn record(&self, name: &'static str) {
            self.state.calls.lock().unwrap().push(name);
        }
    }

    #[tonic::async_trait]
    impl ComputeDriver for FakeInner {
        type WatchSandboxesStream = TestWatchStream;

        async fn authenticate_sandbox(
            &self,
            request: Request<AuthenticateSandboxRequest>,
        ) -> Result<Response<AuthenticateSandboxResponse>, Status> {
            self.record("authenticate_sandbox");
            // Echo: the credential comes back as the sandbox id.
            Ok(Response::new(AuthenticateSandboxResponse {
                sandbox_id: request.into_inner().credential,
                ..Default::default()
            }))
        }
        async fn get_capabilities(
            &self,
            _request: Request<GetCapabilitiesRequest>,
        ) -> Result<Response<GetCapabilitiesResponse>, Status> {
            self.record("get_capabilities");
            Ok(Response::new(GetCapabilitiesResponse::default()))
        }
        async fn validate_sandbox_create(
            &self,
            _request: Request<ValidateSandboxCreateRequest>,
        ) -> Result<Response<ValidateSandboxCreateResponse>, Status> {
            self.record("validate_sandbox_create");
            Ok(Response::new(ValidateSandboxCreateResponse::default()))
        }
        async fn get_sandbox(
            &self,
            request: Request<GetSandboxRequest>,
        ) -> Result<Response<GetSandboxResponse>, Status> {
            self.record("get_sandbox");
            // Echo: the requested id and name come back as the sandbox.
            let request = request.into_inner();
            Ok(Response::new(GetSandboxResponse {
                sandbox: Some(DriverSandbox {
                    id: request.sandbox_id,
                    name: request.name,
                    ..Default::default()
                }),
            }))
        }
        async fn list_sandboxes(
            &self,
            _request: Request<ListSandboxesRequest>,
        ) -> Result<Response<ListSandboxesResponse>, Status> {
            self.record("list_sandboxes");
            Ok(Response::new(ListSandboxesResponse::default()))
        }
        async fn create_sandbox(
            &self,
            request: Request<CreateSandboxRequest>,
        ) -> Result<Response<CreateSandboxResponse>, Status> {
            self.record("create_sandbox");
            *self.state.created.lock().unwrap() = request.into_inner().sandbox;
            if self.state.fail_create {
                return Err(Status::failed_precondition("rejected by upstream"));
            }
            Ok(Response::new(CreateSandboxResponse {
                runtime_identity: "kubernetes://ns/cr-uid/pod-uid".to_string(),
            }))
        }
        async fn stop_sandbox(
            &self,
            _request: Request<StopSandboxRequest>,
        ) -> Result<Response<StopSandboxResponse>, Status> {
            self.record("stop_sandbox");
            Ok(Response::new(StopSandboxResponse::default()))
        }
        async fn start_sandbox(
            &self,
            _request: Request<StartSandboxRequest>,
        ) -> Result<Response<StartSandboxResponse>, Status> {
            self.record("start_sandbox");
            Ok(Response::new(StartSandboxResponse::default()))
        }
        async fn delete_sandbox(
            &self,
            request: Request<DeleteSandboxRequest>,
        ) -> Result<Response<DeleteSandboxResponse>, Status> {
            self.record("delete_sandbox");
            // The response is only a bool: report a deletion exactly when a
            // sandbox id arrived.
            Ok(Response::new(DeleteSandboxResponse {
                deleted: !request.into_inner().sandbox_id.is_empty(),
            }))
        }
        async fn watch_sandboxes(
            &self,
            _request: Request<WatchSandboxesRequest>,
        ) -> Result<Response<Self::WatchSandboxesStream>, Status> {
            self.record("watch_sandboxes");
            Ok(Response::new(Box::pin(futures::stream::empty())))
        }
        async fn ensure_workspace(
            &self,
            _request: Request<EnsureWorkspaceRequest>,
        ) -> Result<Response<EnsureWorkspaceResponse>, Status> {
            self.record("ensure_workspace");
            if self.state.fail_ensure {
                return Err(Status::internal("upstream failed"));
            }
            Ok(Response::new(EnsureWorkspaceResponse::default()))
        }
        async fn delete_workspace(
            &self,
            _request: Request<DeleteWorkspaceRequest>,
        ) -> Result<Response<DeleteWorkspaceResponse>, Status> {
            self.record("delete_workspace");
            Ok(Response::new(DeleteWorkspaceResponse::default()))
        }
    }

    /// Hooks that label the sandbox on enrich, report after_create through a
    /// channel, record each workspace after_ensure_workspace receives, and
    /// optionally fail after_ensure_workspace. `preparing` hooks also ask for
    /// the workspace to be prepared before create and log
    /// `hook_after_ensure_workspace` into the fake inner's call log, so tests
    /// can assert the order across the inner service and the hook.
    struct RecordingHooks {
        created: mpsc::UnboundedSender<String>,
        ensured: Mutex<Vec<String>>,
        fail_ensure: bool,
        prepares: bool,
        call_log: Option<Arc<FakeState>>,
    }

    impl RecordingHooks {
        fn new(fail_ensure: bool) -> (Arc<Self>, mpsc::UnboundedReceiver<String>) {
            let (created, rx) = mpsc::unbounded_channel();
            let hooks = Self {
                created,
                ensured: Mutex::new(Vec::new()),
                fail_ensure,
                prepares: false,
                call_log: None,
            };
            (Arc::new(hooks), rx)
        }

        /// Hooks that prepare the workspace before create, logging into `state`.
        fn preparing(state: &Arc<FakeState>, fail_ensure: bool) -> Arc<Self> {
            // after_create's receiver is not needed: a closed channel is ignored.
            let (created, _rx) = mpsc::unbounded_channel();
            Arc::new(Self {
                created,
                ensured: Mutex::new(Vec::new()),
                fail_ensure,
                prepares: true,
                call_log: Some(Arc::clone(state)),
            })
        }
    }

    #[tonic::async_trait]
    impl KymaHooks for RecordingHooks {
        fn enrich(&self, sandbox: &mut DriverSandbox) {
            sandbox
                .spec
                .get_or_insert_with(Default::default)
                .template
                .get_or_insert_with(Default::default)
                .labels
                .insert("enriched".to_string(), "yes".to_string());
        }
        async fn after_create(&self, sandbox: DriverSandbox) {
            let _ = self.created.send(sandbox.id);
        }
        async fn after_ensure_workspace(&self, workspace: &str) -> Result<(), Status> {
            self.ensured.lock().unwrap().push(workspace.to_string());
            if let Some(state) = &self.call_log {
                state
                    .calls
                    .lock()
                    .unwrap()
                    .push("hook_after_ensure_workspace");
            }
            if self.fail_ensure {
                return Err(Status::unavailable("could not label namespace"));
            }
            Ok(())
        }
        fn prepares_workspace_before_create(&self) -> bool {
            self.prepares
        }
    }

    fn sandbox(id: &str) -> DriverSandbox {
        DriverSandbox {
            id: id.to_string(),
            name: "sb".to_string(),
            ..Default::default()
        }
    }

    fn create_request(id: &str) -> Request<CreateSandboxRequest> {
        Request::new(CreateSandboxRequest {
            sandbox: Some(sandbox(id)),
        })
    }

    fn create_request_in(id: &str, workspace: &str) -> Request<CreateSandboxRequest> {
        Request::new(CreateSandboxRequest {
            sandbox: Some(DriverSandbox {
                workspace: workspace.to_string(),
                ..sandbox(id)
            }),
        })
    }

    #[tokio::test]
    async fn every_rpc_is_forwarded_to_the_inner_service() {
        let (inner, state) = FakeInner::new(FakeState::default());
        let driver = KymaComputeDriver::new(inner, Arc::new(NoHooks));

        driver
            .authenticate_sandbox(Request::new(Default::default()))
            .await
            .unwrap();
        driver
            .get_capabilities(Request::new(Default::default()))
            .await
            .unwrap();
        driver
            .validate_sandbox_create(Request::new(Default::default()))
            .await
            .unwrap();
        driver
            .get_sandbox(Request::new(Default::default()))
            .await
            .unwrap();
        driver
            .list_sandboxes(Request::new(Default::default()))
            .await
            .unwrap();
        driver.create_sandbox(create_request("sb-1")).await.unwrap();
        driver
            .stop_sandbox(Request::new(Default::default()))
            .await
            .unwrap();
        driver
            .start_sandbox(Request::new(Default::default()))
            .await
            .unwrap();
        driver
            .delete_sandbox(Request::new(Default::default()))
            .await
            .unwrap();
        driver
            .watch_sandboxes(Request::new(Default::default()))
            .await
            .unwrap();
        driver
            .ensure_workspace(Request::new(Default::default()))
            .await
            .unwrap();
        driver
            .delete_workspace(Request::new(Default::default()))
            .await
            .unwrap();

        assert_eq!(
            *state.calls.lock().unwrap(),
            vec![
                "authenticate_sandbox",
                "get_capabilities",
                "validate_sandbox_create",
                "get_sandbox",
                "list_sandboxes",
                "create_sandbox",
                "stop_sandbox",
                "start_sandbox",
                "delete_sandbox",
                "watch_sandboxes",
                "ensure_workspace",
                "delete_workspace",
            ]
        );
    }

    #[tokio::test]
    async fn create_returns_upstreams_response_unchanged() {
        let (inner, _state) = FakeInner::new(FakeState::default());
        let driver = KymaComputeDriver::new(inner, Arc::new(NoHooks));
        let response = driver.create_sandbox(create_request("sb-1")).await.unwrap();
        assert_eq!(
            response.into_inner().runtime_identity,
            "kubernetes://ns/cr-uid/pod-uid"
        );
    }

    #[tokio::test]
    async fn other_rpcs_pass_payloads_through_and_return_inner_responses_unchanged() {
        let (inner, _state) = FakeInner::new(FakeState::default());
        let driver = KymaComputeDriver::new(inner, Arc::new(NoHooks));

        let got = driver
            .get_sandbox(Request::new(GetSandboxRequest {
                sandbox_id: "sb-get".to_string(),
                name: "get-me".to_string(),
            }))
            .await
            .unwrap()
            .into_inner()
            .sandbox
            .expect("inner echoed a sandbox");
        assert_eq!((got.id.as_str(), got.name.as_str()), ("sb-get", "get-me"));

        let deleted = driver
            .delete_sandbox(Request::new(DeleteSandboxRequest {
                sandbox_id: "sb-del".to_string(),
                name: "del-me".to_string(),
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(deleted.deleted);

        let auth = driver
            .authenticate_sandbox(Request::new(AuthenticateSandboxRequest {
                credential: "sb-auth".to_string(),
            }))
            .await
            .unwrap()
            .into_inner();
        assert_eq!(auth.sandbox_id, "sb-auth");
    }

    #[tokio::test]
    async fn create_enriches_before_upstream_sees_the_request() {
        let (inner, state) = FakeInner::new(FakeState::default());
        let (hooks, _rx) = RecordingHooks::new(false);
        let driver = KymaComputeDriver::new(inner, hooks);

        driver.create_sandbox(create_request("sb-1")).await.unwrap();

        let seen = state
            .created
            .lock()
            .unwrap()
            .clone()
            .expect("upstream saw a sandbox");
        let labels = seen.spec.unwrap().template.unwrap().labels;
        assert_eq!(labels.get("enriched").map(String::as_str), Some("yes"));
    }

    #[tokio::test]
    async fn after_create_runs_after_a_successful_create() {
        let (inner, _state) = FakeInner::new(FakeState::default());
        let (hooks, mut rx) = RecordingHooks::new(false);
        let driver = KymaComputeDriver::new(inner, hooks);

        driver.create_sandbox(create_request("sb-7")).await.unwrap();

        let id = tokio::time::timeout(Duration::from_secs(2), rx.recv())
            .await
            .expect("after_create ran")
            .expect("channel open");
        assert_eq!(id, "sb-7");
    }

    #[tokio::test]
    async fn after_create_is_skipped_when_upstream_rejects_the_create() {
        let (inner, _state) = FakeInner::new(FakeState {
            fail_create: true,
            ..Default::default()
        });
        let (hooks, mut rx) = RecordingHooks::new(false);
        let driver = KymaComputeDriver::new(inner, hooks);

        let err = driver
            .create_sandbox(create_request("sb-1"))
            .await
            .unwrap_err();
        assert_eq!(err.code(), tonic::Code::FailedPrecondition);
        assert!(
            tokio::time::timeout(Duration::from_millis(200), rx.recv())
                .await
                .is_err(),
            "after_create must not run when upstream rejected the create"
        );
    }

    #[tokio::test]
    async fn ensure_workspace_hook_failure_fails_the_rpc() {
        let (inner, state) = FakeInner::new(FakeState::default());
        let (hooks, _rx) = RecordingHooks::new(true);
        let driver = KymaComputeDriver::new(inner, hooks);

        let err = driver
            .ensure_workspace(Request::new(EnsureWorkspaceRequest {
                workspace: "ws".to_string(),
            }))
            .await
            .unwrap_err();
        assert_eq!(err.code(), tonic::Code::Unavailable);
        assert_eq!(*state.calls.lock().unwrap(), vec!["ensure_workspace"]);
    }

    #[tokio::test]
    async fn ensure_workspace_hook_is_skipped_when_upstream_fails() {
        let (inner, _state) = FakeInner::new(FakeState {
            fail_ensure: true,
            ..Default::default()
        });
        let (hooks, _rx) = RecordingHooks::new(false);
        let hooks_probe = Arc::clone(&hooks);
        let driver = KymaComputeDriver::new(inner, hooks);

        let err = driver
            .ensure_workspace(Request::new(EnsureWorkspaceRequest {
                workspace: "ws".to_string(),
            }))
            .await
            .unwrap_err();
        assert_eq!(err.code(), tonic::Code::Internal);
        assert!(hooks_probe.ensured.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn after_ensure_workspace_receives_the_requested_workspace() {
        let (inner, _state) = FakeInner::new(FakeState::default());
        let (hooks, _rx) = RecordingHooks::new(false);
        let hooks_probe = Arc::clone(&hooks);
        let driver = KymaComputeDriver::new(inner, hooks);

        driver
            .ensure_workspace(Request::new(EnsureWorkspaceRequest {
                workspace: "team-a".to_string(),
            }))
            .await
            .unwrap();
        assert_eq!(*hooks_probe.ensured.lock().unwrap(), vec!["team-a"]);
    }

    #[tokio::test]
    async fn create_prepares_the_workspace_before_forwarding() {
        let (inner, state) = FakeInner::new(FakeState::default());
        let hooks = RecordingHooks::preparing(&state, false);
        let hooks_probe = Arc::clone(&hooks);
        let driver = KymaComputeDriver::new(inner, hooks);

        driver
            .create_sandbox(create_request_in("sb-1", "team-a"))
            .await
            .unwrap();

        assert_eq!(
            *state.calls.lock().unwrap(),
            vec![
                "ensure_workspace",
                "hook_after_ensure_workspace",
                "create_sandbox"
            ]
        );
        assert_eq!(*hooks_probe.ensured.lock().unwrap(), vec!["team-a"]);
    }

    #[tokio::test]
    async fn create_is_not_forwarded_when_the_workspace_hook_fails() {
        let (inner, state) = FakeInner::new(FakeState::default());
        let driver = KymaComputeDriver::new(inner, RecordingHooks::preparing(&state, true));

        let err = driver
            .create_sandbox(create_request_in("sb-1", "team-a"))
            .await
            .unwrap_err();

        assert_eq!(err.code(), tonic::Code::Unavailable);
        assert_eq!(
            *state.calls.lock().unwrap(),
            vec!["ensure_workspace", "hook_after_ensure_workspace"],
            "an unlabelled namespace must not get a pod"
        );
    }

    #[tokio::test]
    async fn create_is_not_forwarded_when_upstream_ensure_fails() {
        let (inner, state) = FakeInner::new(FakeState {
            fail_ensure: true,
            ..Default::default()
        });
        let hooks = RecordingHooks::preparing(&state, false);
        let hooks_probe = Arc::clone(&hooks);
        let driver = KymaComputeDriver::new(inner, hooks);

        let err = driver
            .create_sandbox(create_request_in("sb-1", "team-a"))
            .await
            .unwrap_err();

        assert_eq!(err.code(), tonic::Code::Internal);
        assert_eq!(*state.calls.lock().unwrap(), vec!["ensure_workspace"]);
        assert!(hooks_probe.ensured.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn create_makes_no_ensure_call_unless_the_hooks_ask_for_one() {
        let (inner, state) = FakeInner::new(FakeState::default());
        let (hooks, _rx) = RecordingHooks::new(false);
        let hooks_probe = Arc::clone(&hooks);
        let driver = KymaComputeDriver::new(inner, hooks);

        driver
            .create_sandbox(create_request_in("sb-1", "team-a"))
            .await
            .unwrap();

        assert_eq!(*state.calls.lock().unwrap(), vec!["create_sandbox"]);
        assert!(hooks_probe.ensured.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn create_without_a_sandbox_is_forwarded_unchanged() {
        let (inner, state) = FakeInner::new(FakeState::default());
        let driver = KymaComputeDriver::new(inner, RecordingHooks::preparing(&state, false));

        driver
            .create_sandbox(Request::new(CreateSandboxRequest { sandbox: None }))
            .await
            .unwrap();

        assert_eq!(*state.calls.lock().unwrap(), vec!["create_sandbox"]);
    }
}
