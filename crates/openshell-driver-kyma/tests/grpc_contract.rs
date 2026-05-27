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
    watch_sandboxes_event::Payload, CreateSandboxRequest, DeleteSandboxRequest, DriverSandbox,
    DriverSandboxSpec, DriverSandboxTemplate, GetCapabilitiesRequest, GetSandboxRequest,
    ListSandboxesRequest, StopSandboxRequest, ValidateSandboxCreateRequest, WatchSandboxesRequest,
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
        async fn delete(&self, name: &str) -> Result<(), DriverError>;
        async fn get(&self, name: &str) -> Result<DriverSandbox, DriverError>;
        async fn list(&self) -> Result<Vec<DriverSandbox>, DriverError>;
        async fn watch(&self) -> Result<mpsc::Receiver<WatchEvent>, DriverError>;
        async fn validate_create(&self, sb: &DriverSandbox) -> Result<(), DriverError>;
        async fn has_gpu_capacity(&self) -> Result<bool, DriverError>;
        async fn apply_apirule(&self, manifest: serde_json::Value) -> Result<(), DriverError>;
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
        fn render_apirule(&self, sandbox_id: &str, sandbox_name: &str) -> Option<serde_json::Value>;
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
    let listener = UnixListener::bind(&socket).expect("bind UDS");
    let stream = UnixListenerStream::new(listener);

    let driver = Driver::new_with_deps(
        Arc::new(provisioner),
        Arc::new(enricher),
        Arc::new(metrics),
        Config::default(),
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
    assert!(r.supports_gpu);

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

#[tokio::test]
async fn grpc_stop_returns_unimplemented() {
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
            sandbox_id: "id".into(),
            sandbox_name: "x".into(),
        })
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::Unimplemented);

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
