//! Entrypoint for the openshell-driver-kyma binary.
//!
//! Wires the gRPC server (Unix domain socket) and the axum sidecar
//! (`/healthz`, `/readyz`, `/metrics`) onto the same Tokio runtime and
//! shuts both down gracefully on SIGTERM/SIGINT. PSA fail-fast happens
//! before either listener binds: if the target namespace is not labeled
//! `pod-security.kubernetes.io/enforce: privileged` the binary exits with
//! a clear error.
//!
//! UNIX-only: this file uses `tokio::net::UnixListener` and
//! `std::os::unix::fs::PermissionsExt`. `cargo build` on Windows succeeds
//! (the lib still compiles) but the binary itself is Linux-only — that's
//! by design, the driver runs in a container.

#![cfg(unix)]

use anyhow::{Context, Result};
use clap::Parser;
use computev1::pb::compute_driver_server::ComputeDriverServer;
use openshell_driver_kyma::{
    config::Config,
    driver::Driver,
    enricher::KymaEnricher,
    interfaces::{DriverMetrics, PlatformEnricher, SandboxProvisioner},
    metrics::{serve_http, PrometheusMetrics},
    provisioner::KymaProvisioner,
};
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use tokio::net::UnixListener;
use tokio::signal::unix::{signal, SignalKind};
use tokio_stream::wrappers::UnixListenerStream;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    // rustls 0.23 requires the binary to install a default CryptoProvider
    // before any TLS code runs. kube-rs (-> hyper-rustls -> rustls) panics
    // at runtime otherwise: "Could not automatically determine the
    // process-level CryptoProvider from Rustls crate features." We use
    // ring (no aws-lc-rs dep tree, no C compiler at build).
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("install rustls ring crypto provider");

    let cfg = Config::parse();
    init_tracing(&cfg.log_level);

    openshell_driver_kyma::workspace::validate_workspace_mode(&cfg)
        .map_err(|e| anyhow::anyhow!("invalid workspace configuration: {e}"))?;

    // Fail closed rather than silently downgrading isolation. Kept as its
    // own check next to `validate_workspace_mode` rather than folded into
    // it (in `workspace.rs`): `validate_workspace_mode` verifies a config is
    // internally consistent (e.g. `managed` has a usable `gateway_id`); this
    // check is about a known gap in what `KymaProvisioner` can actually do
    // (see `bootstrap_managed_namespace`'s doc comment in `provisioner.rs`),
    // which belongs at the composition site where the provisioner is wired
    // up, not inside the mode-validation module itself.
    if let Some(msg) = managed_network_policy_gap(&cfg) {
        anyhow::bail!(msg);
    }

    // Same fail-closed reasoning: a bad numeric identity is far cheaper to
    // catch here than per-sandbox inside the supervisor.
    if let Some(msg) = openshell_driver_kyma::config::sandbox_identity_gap(&cfg) {
        anyhow::bail!(msg);
    }

    tracing::info!(
        socket = %cfg.socket,
        namespace = %cfg.namespace,
        workspace_mode = ?cfg.workspace_mode,
        gpu_support = cfg.gpu_support,
        enable_apirule = cfg.enable_apirule,
        istio_inject_sandboxes = cfg.istio_inject_sandboxes,
        "starting openshell-driver-kyma"
    );

    let kube_client = build_kube_client().await.context("build kube client")?;

    // PSA fail-fast: must happen before we bind the listener, so a
    // misconfigured cluster never sees a half-up driver. Only meaningful
    // under `Shared`, where `cfg.namespace` is the one static namespace the
    // chart installs ahead of time — under `Managed`/`Operator` there is no
    // single namespace to check yet at startup; that check moves into the
    // per-workspace path in later phases.
    let enricher =
        Arc::new(KymaEnricher::new(kube_client.clone(), cfg.clone())) as Arc<dyn PlatformEnricher>;
    if cfg.workspace_mode == openshell_driver_kyma::workspace::WorkspaceMode::Shared {
        enricher
            .detect_psa(&cfg.namespace)
            .await
            .context("PSA pre-flight check")?;
        tracing::info!(namespace = %cfg.namespace, "PSA enforce=privileged confirmed");
    } else {
        tracing::info!(
            workspace_mode = ?cfg.workspace_mode,
            "skipping startup PSA pre-flight check; not applicable outside Shared mode"
        );
    }

    let provisioner =
        Arc::new(KymaProvisioner::new(kube_client, cfg.clone())) as Arc<dyn SandboxProvisioner>;
    let metrics_concrete = Arc::new(PrometheusMetrics::new().context("build Prometheus registry")?);
    let metrics = metrics_concrete.clone() as Arc<dyn DriverMetrics>;
    let ready = Arc::new(AtomicBool::new(false));

    // Clean up any stale socket from a previous run.
    let _ = std::fs::remove_file(&cfg.socket);
    let listener =
        UnixListener::bind(&cfg.socket).with_context(|| format!("bind UDS at {}", cfg.socket))?;
    std::fs::set_permissions(&cfg.socket, std::fs::Permissions::from_mode(0o660)).ok();
    let stream = UnixListenerStream::new(listener);

    let driver = Driver::new_with_deps(provisioner, enricher.clone(), metrics, cfg.clone());
    let svc = ComputeDriverServer::new(driver);

    // Sidecar HTTP server for kubelet probes + Prometheus scrapes.
    let http_addr: std::net::SocketAddr = format!("0.0.0.0:{}", cfg.health_port)
        .parse()
        .context("parse health-port")?;
    let http_metrics = metrics_concrete.clone();
    let http_ready = ready.clone();
    let http_handle = tokio::spawn(async move {
        if let Err(e) = serve_http(http_addr, http_metrics, http_ready).await {
            tracing::error!(error = %e, "axum http server exited with error");
        }
    });

    ready.store(true, std::sync::atomic::Ordering::SeqCst);
    tracing::info!(socket = %cfg.socket, http = %http_addr, "driver ready");

    let shutdown = shutdown_signal();
    tonic::transport::Server::builder()
        .add_service(svc)
        .serve_with_incoming_shutdown(stream, shutdown)
        .await
        .context("tonic gRPC server")?;

    http_handle.abort();
    tracing::info!("driver shut down cleanly");
    Ok(())
}

/// Whether the driver must refuse to start.
///
/// `Managed` namespace NetworkPolicy support is not implemented yet —
/// `KymaProvisioner::bootstrap_managed_namespace` creates the namespace,
/// its PSA label, and the sandbox ServiceAccount, but deliberately no
/// NetworkPolicy (see that function's doc comment for why: the chart's
/// sandbox policy depends on Helm-only inputs that don't exist in `Config`).
/// An operator who explicitly asked for network isolation via
/// `--enable-network-policy` must never silently get sandboxes in managed
/// namespaces with weaker isolation than they configured, so this combination
/// is refused at startup rather than allowed to run unenforced.
#[must_use]
fn managed_network_policy_gap(cfg: &Config) -> Option<String> {
    if cfg.workspace_mode == openshell_driver_kyma::workspace::WorkspaceMode::Managed
        && cfg.enable_network_policy
    {
        Some(
            "managed-namespace NetworkPolicy support is not implemented yet; refusing to \
             start with --workspace-mode managed --enable-network-policy=true, since \
             continuing would give sandboxes in managed namespaces weaker network isolation \
             than requested. Set --enable-network-policy=false to accept no network isolation \
             for managed namespaces, or use --workspace-mode shared."
                .to_string(),
        )
    } else {
        None
    }
}

fn init_tracing(level: &str) {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(level));
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .json()
        .init();
}

async fn build_kube_client() -> Result<kube::Client> {
    if let Ok(config) = kube::Config::incluster() {
        return Ok(kube::Client::try_from(config)?);
    }
    let config = kube::Config::infer().await?;
    Ok(kube::Client::try_from(config)?)
}

async fn shutdown_signal() {
    let mut sigterm = signal(SignalKind::terminate()).expect("install SIGTERM handler");
    let mut sigint = signal(SignalKind::interrupt()).expect("install SIGINT handler");
    tokio::select! {
        _ = sigterm.recv() => tracing::info!("SIGTERM received, shutting down"),
        _ = sigint.recv() => tracing::info!("SIGINT received, shutting down"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openshell_driver_kyma::workspace::WorkspaceMode;

    fn cfg_with(mode: WorkspaceMode, enable_network_policy: bool) -> Config {
        Config {
            workspace_mode: mode,
            enable_network_policy,
            ..Config::default()
        }
    }

    #[test]
    fn managed_with_network_policy_enabled_is_a_gap() {
        let cfg = cfg_with(WorkspaceMode::Managed, true);
        let msg = managed_network_policy_gap(&cfg).expect("must refuse to start");
        assert!(msg.contains("NetworkPolicy"));
        assert!(msg.contains("--workspace-mode managed"));
    }

    #[test]
    fn managed_without_network_policy_is_fine() {
        let cfg = cfg_with(WorkspaceMode::Managed, false);
        assert!(managed_network_policy_gap(&cfg).is_none());
    }

    #[test]
    fn shared_with_network_policy_enabled_is_fine() {
        // Shared's NetworkPolicy is rendered by the chart, not this driver,
        // so this combination is unaffected by the managed-mode gap.
        let cfg = cfg_with(WorkspaceMode::Shared, true);
        assert!(managed_network_policy_gap(&cfg).is_none());
    }

    #[test]
    fn operator_with_network_policy_enabled_is_fine() {
        // Operator namespaces are pre-existing and platform-team-owned;
        // this task's gap is specific to namespaces this driver bootstraps.
        let cfg = cfg_with(WorkspaceMode::Operator, true);
        assert!(managed_network_policy_gap(&cfg).is_none());
    }
}
