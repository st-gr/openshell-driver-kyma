//! Tier-2 gRPC contract tests: a real `tonic` server on a temp Unix domain
//! socket, a real `tonic` client, and `mockall`-generated mocks for the
//! trait dependencies. Proves wire-compatibility with the upstream
//! OpenShell gateway protocol.
//!
//! Mocks are defined inline with `mockall::mock!` because the
//! `#[cfg_attr(test, automock)]` annotations in `interfaces.rs` only
//! generate mocks for the lib's own test binary, not for integration
//! tests in `tests/`.

#![cfg(unix)]

use async_trait::async_trait;
use computev1::pb::{
    compute_driver_client::ComputeDriverClient, compute_driver_server::ComputeDriverServer,
    watch_sandboxes_event::Payload, CreateSandboxRequest, DeleteSandboxRequest,
    DeleteWorkspaceRequest, DriverSandbox, DriverSandboxSpec, DriverSandboxTemplate,
    EnsureWorkspaceRequest, GetCapabilitiesRequest, GetGatewayListenerRequirementsRequest,
    GetSandboxRequest, ListSandboxesRequest, StartSandboxRequest, StopSandboxRequest,
    ValidateSandboxCreateRequest, WatchSandboxesRequest,
};
use mockall::mock;
use openshell_driver_kyma::{
    config::Config,
    driver::Driver,
    error::DriverError,
    interfaces::{DriverMetrics, PlatformEnricher, SandboxProvisioner, WatchEvent},
};
use std::convert::Infallible;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tempfile::TempDir;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc;
use tokio_stream::wrappers::UnixListenerStream;
use tokio_stream::StreamExt;
use tonic::transport::{Endpoint, Uri};
use tower::service_fn;

mock! {
    pub Provisioner {}
    #[async_trait]
    impl SandboxProvisioner for Provisioner {
        async fn create(&self, sb: &DriverSandbox) -> Result<(), DriverError>;
        async fn delete(&self, sandbox_id: &str) -> Result<(), DriverError>;
        async fn get(&self, sandbox_id: &str) -> Result<DriverSandbox, DriverError>;
        async fn list(&self) -> Result<Vec<DriverSandbox>, DriverError>;
        async fn watch(&self) -> Result<mpsc::Receiver<WatchEvent>, DriverError>;
        async fn validate_create(&self, sb: &DriverSandbox) -> Result<(), DriverError>;
        async fn has_gpu_capacity(&self, count: u32) -> Result<bool, DriverError>;
        async fn start_sandbox(&self, sandbox_id: &str) -> Result<(), DriverError>;
        async fn stop_sandbox(&self, sandbox_id: &str) -> Result<(), DriverError>;
        async fn apply_apirule(
            &self,
            manifest: serde_json::Value,
            namespace: &str,
        ) -> Result<(), DriverError>;
        async fn ensure_workspace(&self, workspace: &str) -> Result<(), DriverError>;
        async fn delete_workspace(&self, workspace: &str) -> Result<(), DriverError>;
    }
}

mock! {
    pub Enricher {}
    #[async_trait]
    impl PlatformEnricher for Enricher {
        async fn detect_psa(&self, namespace: &str) -> Result<String, DriverError>;
        async fn enrich_pod_template(
            &self,
            template: serde_json::Value,
            namespace: &str,
        ) -> Result<serde_json::Value, DriverError>;
        fn render_apirule(
            &self,
            sandbox_id: &str,
            kube_name: &str,
            sandbox_name: &str,
            workspace: &str,
            namespace: &str,
        ) -> Option<serde_json::Value>;
    }
}

mock! {
    pub Metrics {}
    impl DriverMetrics for Metrics {
        fn sandbox_created(&self, name: &str, gpu: bool, duration: Duration);
        fn sandbox_deleted(&self, name: &str);
        fn sandbox_failed(&self, name: &str, reason: &str);
        fn watch_event_received(&self, event_type: &str);
    }
}

fn temp_socket() -> (TempDir, PathBuf) {
    let dir = tempfile::Builder::new()
        .prefix("ock-")
        .tempdir_in("/tmp")
        .unwrap();
    let path = dir.path().join("d.sock");
    (dir, path)
}

async fn start_server(
    socket: PathBuf,
    provisioner: MockProvisioner,
    enricher: MockEnricher,
    metrics: MockMetrics,
) -> (
    ComputeDriverClient<tonic::transport::Channel>,
    tokio::sync::oneshot::Sender<()>,
    tokio::task::JoinHandle<()>,
) {
    start_server_with_config(socket, provisioner, enricher, metrics, Config::default()).await
}

/// Like `start_server`, but with an explicit `Config` — needed for the tests
/// that exercise mode-dependent behavior (e.g. the `EnsureWorkspace`/
/// `DeleteWorkspace` boundary check, which only requires a strict DNS-1123
/// workspace under `Managed`/`Operator`).
async fn start_server_with_config(
    socket: PathBuf,
    provisioner: MockProvisioner,
    enricher: MockEnricher,
    metrics: MockMetrics,
    cfg: Config,
) -> (
    ComputeDriverClient<tonic::transport::Channel>,
    tokio::sync::oneshot::Sender<()>,
    tokio::task::JoinHandle<()>,
) {
    let listener = UnixListener::bind(&socket).expect("bind UDS");
    let stream = UnixListenerStream::new(listener);

    let driver = Driver::new_with_deps(
        Arc::new(provisioner),
        Arc::new(enricher),
        Arc::new(metrics),
        cfg,
    );

    let (tx, rx) = tokio::sync::oneshot::channel::<()>();
    let server_handle = tokio::spawn(async move {
        let _ = tonic::transport::Server::builder()
            .add_service(ComputeDriverServer::new(driver))
            .serve_with_incoming_shutdown(stream, async move {
                let _ = rx.await;
            })
            .await;
    });

    tokio::time::sleep(Duration::from_millis(50)).await;

    let socket_for_client = socket.clone();
    let channel = Endpoint::try_from("http://[::1]:50051")
        .unwrap()
        .connect_with_connector(service_fn(move |_uri: Uri| {
            let s = socket_for_client.clone();
            async move {
                Ok::<_, Infallible>(hyper_util::rt::TokioIo::new(
                    UnixStream::connect(s).await.expect("connect UDS"),
                ))
            }
        }))
        .await
        .expect("connect");

    (ComputeDriverClient::new(channel), tx, server_handle)
}

fn valid_sandbox(id: &str, name: &str) -> DriverSandbox {
    DriverSandbox {
        id: id.into(),
        name: name.into(),
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

#[tokio::test]
async fn grpc_get_capabilities_returns_kyma() {
    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) = start_server(
        socket,
        MockProvisioner::new(),
        MockEnricher::new(),
        MockMetrics::new(),
    )
    .await;

    let r = client
        .get_capabilities(GetCapabilitiesRequest {})
        .await
        .unwrap()
        .into_inner();
    assert_eq!(r.driver_name, "kyma");
    // `supports_gpu` was reserved upstream in v0.0.91 and no longer exists on
    // the response. GPU capability is now surfaced at ValidateSandboxCreate
    // instead — see `validate_create_rejects_gpu_without_capacity`.
    assert!(!r.driver_version.is_empty());
    assert!(!r.default_image.is_empty());

    drop(shutdown);
    let _ = handle.await;
}

/// Over the real wire, not just the trait: proves a v0.0.97 gateway calling
/// this RPC gets a valid empty response rather than `Unimplemented`.
#[tokio::test]
async fn grpc_gateway_listener_requirements_returns_empty() {
    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) = start_server(
        socket,
        MockProvisioner::new(),
        MockEnricher::new(),
        MockMetrics::new(),
    )
    .await;

    let r = client
        .get_gateway_listener_requirements(GetGatewayListenerRequirementsRequest {})
        .await
        .expect("RPC must be implemented, not Unimplemented")
        .into_inner();
    assert!(r.requirements.is_empty());

    drop(shutdown);
    let _ = handle.await;
}

#[tokio::test]
async fn grpc_create_then_get_round_trips() {
    let mut p = MockProvisioner::new();
    p.expect_create().returning(|_| Ok(()));
    p.expect_get().returning(|name| {
        Ok(DriverSandbox {
            id: "sb-id-1".into(),
            name: name.to_string(),
            ..Default::default()
        })
    });
    let mut m = MockMetrics::new();
    m.expect_sandbox_created().return_const(());

    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) = start_server(socket, p, MockEnricher::new(), m).await;

    client
        .create_sandbox(CreateSandboxRequest {
            sandbox: Some(valid_sandbox("sb-id-1", "sb-1")),
        })
        .await
        .unwrap();

    let got = client
        .get_sandbox(GetSandboxRequest {
            sandbox_id: "sb-id-1".into(),
            sandbox_name: "sb-1".into(),
        })
        .await
        .unwrap()
        .into_inner();
    assert_eq!(got.sandbox.unwrap().id, "sb-id-1");

    drop(shutdown);
    let _ = handle.await;
}

#[tokio::test]
async fn grpc_create_invalid_argument_when_id_missing() {
    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) = start_server(
        socket,
        MockProvisioner::new(),
        MockEnricher::new(),
        MockMetrics::new(),
    )
    .await;

    let mut sb = valid_sandbox("", "sb-1");
    sb.id = String::new();
    let err = client
        .create_sandbox(CreateSandboxRequest { sandbox: Some(sb) })
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::InvalidArgument);

    drop(shutdown);
    let _ = handle.await;
}

#[tokio::test]
async fn grpc_delete_idempotent_returns_false_on_not_found() {
    let mut p = MockProvisioner::new();
    p.expect_delete()
        .returning(|_| Err(DriverError::NotFound("gone".into())));
    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) =
        start_server(socket, p, MockEnricher::new(), MockMetrics::new()).await;

    let r = client
        .delete_sandbox(DeleteSandboxRequest {
            sandbox_id: "id".into(),
            sandbox_name: "gone".into(),
        })
        .await
        .unwrap()
        .into_inner();
    assert!(!r.deleted);

    drop(shutdown);
    let _ = handle.await;
}

#[tokio::test]
async fn grpc_list_returns_empty_when_no_sandboxes() {
    let mut p = MockProvisioner::new();
    p.expect_list().returning(|| Ok(vec![]));
    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) =
        start_server(socket, p, MockEnricher::new(), MockMetrics::new()).await;

    let r = client
        .list_sandboxes(ListSandboxesRequest {})
        .await
        .unwrap()
        .into_inner();
    assert!(r.sandboxes.is_empty());

    drop(shutdown);
    let _ = handle.await;
}

/// The whole point of Phase 1: these used to return Unimplemented, and the
/// gateway does NOT swallow that for stop/start — `openshell sandbox stop`
/// failed against this driver.
#[tokio::test]
async fn grpc_stop_and_start_are_implemented() {
    let mut p = MockProvisioner::new();
    p.expect_stop_sandbox().times(1).returning(|_| Ok(()));
    p.expect_start_sandbox().times(1).returning(|_| Ok(()));

    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) =
        start_server(socket, p, MockEnricher::new(), MockMetrics::new()).await;

    client
        .stop_sandbox(StopSandboxRequest {
            sandbox_id: "sb-1".into(),
            sandbox_name: "n".into(),
        })
        .await
        .expect("stop must be implemented");
    client
        .start_sandbox(StartSandboxRequest {
            sandbox_id: "sb-1".into(),
            sandbox_name: "n".into(),
        })
        .await
        .expect("start must be implemented");

    drop(shutdown);
    // Unlike other tests here, this one's whole purpose is to catch a
    // regressed handler that stops calling the provisioner. mockall's
    // `.times(1)` checkpoint fires on Drop of the mock, which happens
    // inside the spawned server task as it tears down — a task panic
    // there surfaces only as `Err` from this JoinHandle, not as a panic
    // on the current thread. `let _ = handle.await;` (used elsewhere in
    // this file) would silently swallow that and let the test report
    // "ok" even when the expectation was violated, so unwrap it instead.
    handle.await.unwrap();
}

#[tokio::test]
async fn grpc_stop_rejects_empty_sandbox_id() {
    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) = start_server(
        socket,
        MockProvisioner::new(),
        MockEnricher::new(),
        MockMetrics::new(),
    )
    .await;

    let err = client
        .stop_sandbox(StopSandboxRequest {
            sandbox_id: String::new(),
            sandbox_name: "n".into(),
        })
        .await
        .expect_err("empty sandbox_id must be rejected");
    assert_eq!(err.code(), tonic::Code::InvalidArgument);

    drop(shutdown);
    let _ = handle.await;
}

#[tokio::test]
async fn grpc_start_rejects_empty_sandbox_id() {
    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) = start_server(
        socket,
        MockProvisioner::new(),
        MockEnricher::new(),
        MockMetrics::new(),
    )
    .await;

    let err = client
        .start_sandbox(StartSandboxRequest {
            sandbox_id: String::new(),
            sandbox_name: "n".into(),
        })
        .await
        .expect_err("empty sandbox_id must be rejected");
    assert_eq!(err.code(), tonic::Code::InvalidArgument);

    drop(shutdown);
    let _ = handle.await;
}

#[tokio::test]
async fn grpc_validate_returns_failed_precondition_when_provisioner_rejects() {
    let mut p = MockProvisioner::new();
    p.expect_validate_create()
        .returning(|_| Err(DriverError::FailedPrecondition("no gpu".into())));
    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) =
        start_server(socket, p, MockEnricher::new(), MockMetrics::new()).await;

    let err = client
        .validate_sandbox_create(ValidateSandboxCreateRequest {
            sandbox: Some(valid_sandbox("id", "x")),
        })
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::FailedPrecondition);

    drop(shutdown);
    let _ = handle.await;
}

#[tokio::test]
async fn grpc_watch_streams_two_events_then_closes() {
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

    let mut p = MockProvisioner::new();
    let rx_cell = std::sync::Mutex::new(Some(rx));
    p.expect_watch()
        .returning(move || Ok(rx_cell.lock().unwrap().take().unwrap()));

    let mut m = MockMetrics::new();
    m.expect_watch_event_received().return_const(());

    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) = start_server(socket, p, MockEnricher::new(), m).await;

    let mut stream = client
        .watch_sandboxes(WatchSandboxesRequest {})
        .await
        .unwrap()
        .into_inner();

    let ev = stream.next().await.unwrap().unwrap();
    match ev.payload.unwrap() {
        Payload::Sandbox(s) => assert_eq!(s.sandbox.unwrap().name, "A"),
        other => panic!("expected sandbox event, got {other:?}"),
    }
    let ev = stream.next().await.unwrap().unwrap();
    match ev.payload.unwrap() {
        Payload::Deleted(d) => assert_eq!(d.sandbox_id, "id-B"),
        other => panic!("expected deleted event, got {other:?}"),
    }
    assert!(stream.next().await.is_none());

    drop(shutdown);
    let _ = handle.await;
}

#[tokio::test]
async fn grpc_ensure_workspace_rejects_empty_workspace() {
    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) = start_server(
        socket,
        MockProvisioner::new(),
        MockEnricher::new(),
        MockMetrics::new(),
    )
    .await;

    let err = client
        .ensure_workspace(EnsureWorkspaceRequest {
            workspace: String::new(),
        })
        .await
        .expect_err("empty workspace must be rejected");
    assert_eq!(err.code(), tonic::Code::InvalidArgument);

    drop(shutdown);
    let _ = handle.await;
}

/// Shared mode is a no-op, but it must be a *successful* no-op: a caller
/// (or a future gateway version) may still call EnsureWorkspace directly, and
/// an error here would surface as a spurious failure even though `Shared`
/// has no bootstrap to do. `.times(1)` plus `handle.await.unwrap()` (rather than
/// `let _ = handle.await;`) makes this non-vacuous: mockall's default
/// call-count is 0..usize::MAX, so an expectation without `.times(..)` is
/// satisfied by zero calls, and the checkpoint panic that would catch a
/// regressed handler fires inside the spawned server task, which only
/// surfaces as an `Err` from the JoinHandle.
#[tokio::test]
async fn grpc_ensure_workspace_succeeds_in_shared_mode() {
    let mut p = MockProvisioner::new();
    p.expect_ensure_workspace().times(1).returning(|_| Ok(()));

    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) =
        start_server(socket, p, MockEnricher::new(), MockMetrics::new()).await;

    client
        .ensure_workspace(EnsureWorkspaceRequest {
            workspace: "default".into(),
        })
        .await
        .expect("shared mode must succeed");

    drop(shutdown);
    handle.await.unwrap();
}

#[tokio::test]
async fn grpc_delete_workspace_rejects_empty_workspace() {
    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) = start_server(
        socket,
        MockProvisioner::new(),
        MockEnricher::new(),
        MockMetrics::new(),
    )
    .await;

    let err = client
        .delete_workspace(DeleteWorkspaceRequest {
            workspace: String::new(),
        })
        .await
        .expect_err("empty workspace must be rejected");
    assert_eq!(err.code(), tonic::Code::InvalidArgument);

    drop(shutdown);
    let _ = handle.await;
}

/// A traversal-shaped workspace must be rejected before it reaches the
/// provisioner — the mock has no expectations set, so a call that got past
/// validation would panic inside the spawned server task rather than
/// surface as a clean `InvalidArgument`. This is a `Managed`/`Operator`
/// property: under those modes `workspace` becomes a Kubernetes namespace
/// name and therefore a raw, unencoded URL path segment. `Shared` never
/// uses `workspace` this way — see
/// `grpc_ensure_workspace_shared_mode_accepts_a_traversal_shaped_workspace`
/// below for the property that must hold there instead.
#[tokio::test]
async fn grpc_ensure_workspace_rejects_path_traversal() {
    let (_dir, socket) = temp_socket();
    let cfg = Config {
        workspace_mode: openshell_driver_kyma::workspace::WorkspaceMode::Managed,
        gateway_id: "gw1".into(),
        ..Config::default()
    };
    let (mut client, shutdown, handle) = start_server_with_config(
        socket,
        MockProvisioner::new(),
        MockEnricher::new(),
        MockMetrics::new(),
        cfg,
    )
    .await;

    let err = client
        .ensure_workspace(EnsureWorkspaceRequest {
            workspace: "a/../../../../api/v1/namespaces/kube-system".into(),
        })
        .await
        .expect_err("traversal-shaped workspace must be rejected under Managed");
    assert_eq!(err.code(), tonic::Code::InvalidArgument);

    drop(shutdown);
    let _ = handle.await;
}

/// See `grpc_ensure_workspace_rejects_path_traversal` — same boundary check
/// on the delete side, under the same `Managed`-mode property.
#[tokio::test]
async fn grpc_delete_workspace_rejects_path_traversal() {
    let (_dir, socket) = temp_socket();
    let cfg = Config {
        workspace_mode: openshell_driver_kyma::workspace::WorkspaceMode::Managed,
        gateway_id: "gw1".into(),
        ..Config::default()
    };
    let (mut client, shutdown, handle) = start_server_with_config(
        socket,
        MockProvisioner::new(),
        MockEnricher::new(),
        MockMetrics::new(),
        cfg,
    )
    .await;

    let err = client
        .delete_workspace(DeleteWorkspaceRequest {
            workspace: "a/../../../../api/v1/namespaces/kube-system".into(),
        })
        .await
        .expect_err("traversal-shaped workspace must be rejected under Managed");
    assert_eq!(err.code(), tonic::Code::InvalidArgument);

    drop(shutdown);
    let _ = handle.await;
}

/// The regression this whole fix undoes, proven on the wire: before this
/// branch, `EnsureWorkspace`/`DeleteWorkspace` returned `Unimplemented`
/// (swallowed by the gateway) under every mode, so `Shared` — the default,
/// and every existing install's mode — accepted any non-empty workspace
/// string. A workspace containing a dot (`acme.dev`, a valid Sandbox CR
/// name character but not a valid DNS-1123 label) must still be accepted
/// under `Shared` today. A traversal-shaped string is not itself dangerous
/// under `Shared` (`namespace_for` ignores `workspace` entirely and always
/// returns `cfg.namespace`), so it doubles as evidence the boundary check no
/// longer over-narrows `Shared` at all.
#[tokio::test]
async fn grpc_ensure_workspace_shared_mode_accepts_a_dotted_workspace() {
    let mut p = MockProvisioner::new();
    p.expect_ensure_workspace()
        .withf(|ws: &str| ws == "acme.dev")
        .times(1)
        .returning(|_| Ok(()));

    let (_dir, socket) = temp_socket();
    let (mut client, shutdown, handle) =
        start_server(socket, p, MockEnricher::new(), MockMetrics::new()).await;

    client
        .ensure_workspace(EnsureWorkspaceRequest {
            workspace: "acme.dev".into(),
        })
        .await
        .expect("Shared must accept a workspace containing a dot");

    drop(shutdown);
    handle.await.unwrap();
}
