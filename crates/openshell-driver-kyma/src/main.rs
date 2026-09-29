// SPDX-License-Identifier: Apache-2.0

//! `openshell-driver-kyma`: upstream's Kubernetes compute driver behind a thin
//! Kyma layer.
//!
//! Serving mirrors upstream `openshell-driver-kubernetes`'s `main()` — the same
//! tracing, the same private Unix socket or TCP bind, the same RPC layer — so
//! the driver behaves identically. The one difference is the gRPC service:
//! upstream's `ComputeDriverService` wrapped in `KymaComputeDriver`.

use std::sync::Arc;

use clap::Parser;
use miette::{IntoDiagnostic, Result};
use openshell_core::proto::compute::v1::compute_driver_server::ComputeDriverServer;
use openshell_core::VERSION;
use openshell_driver_kubernetes::{ComputeDriverService, KubernetesComputeDriver};
use openshell_driver_kyma::hooks::KymaHookSet;
use openshell_driver_kyma::kyma_args::KymaArgs;
use openshell_driver_kyma::service::KymaComputeDriver;
use openshell_driver_kyma::upstream_args::{
    compute_config, parse_managed_ssh_gateway_pod_selector, UpstreamArgs,
};
use tracing::info;

// `about`/`long_about = None` keep `--help` without a description line, like
// upstream's: clap would otherwise show a flattened struct's doc comment
// (`KymaArgs`'s) as the command's about text.
#[derive(Parser, Debug)]
#[command(name = "openshell-driver-kyma", version, about = None, long_about = None)]
struct Cli {
    #[command(flatten)]
    upstream: UpstreamArgs,
    #[command(flatten)]
    kyma: KymaArgs,
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let terminate = async {
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                Ok(mut signal) => {
                    signal.recv().await;
                }
                Err(_) => std::future::pending::<()>().await,
            }
        };
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            () = terminate => {}
        }
    }

    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let Cli { upstream, kyma } = Cli::parse();
    kyma.validate().map_err(|err| miette::miette!("{err}"))?;

    // Owned copies: the tracing guard borrows these for the life of the
    // process, while `upstream` itself is consumed by compute_config below.
    let otlp_endpoint = upstream.otlp_endpoint.clone();
    let gateway_name = upstream.gateway_name.clone();
    let log_level = upstream.log_level.clone();
    let _tracing = openshell_otel::install_driver_tracing(
        openshell_driver_kubernetes::otel_tracing::TRACING,
        openshell_otel::DriverTracingConfig {
            endpoint: otlp_endpoint.as_deref(),
            gateway_name: gateway_name.as_deref(),
            service_version: VERSION,
            log_level: &log_level,
        },
    );

    let selector =
        parse_managed_ssh_gateway_pod_selector(&upstream.managed_ssh_gateway_pod_selector)?;
    let bind_socket = upstream.bind_socket.clone();
    let bind_address = upstream.bind_address;

    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    let driver = KubernetesComputeDriver::new(compute_config(upstream, selector), shutdown_rx)
        .await
        .into_diagnostic()?;
    let service = ComputeDriverServer::new(KymaComputeDriver::new(
        ComputeDriverService::new(driver),
        Arc::new(KymaHookSet::new(kyma.enrich_config())),
    ));
    let shutdown = async move {
        shutdown_signal().await;
        let _ = shutdown_tx.send(true);
    };

    if let Some(socket_path) = bind_socket {
        let listener = openshell_core::external_driver_socket::bind_private(&socket_path)
            .map_err(|err| miette::miette!("{err}"))?;
        let _cleanup =
            openshell_core::external_driver_socket::SocketCleanup::new(socket_path.clone());
        info!(socket = %socket_path.display(), "Starting Kyma compute driver");
        tonic::transport::Server::builder()
            .layer(openshell_otel::compute_driver_rpc_layer())
            .add_service(service)
            .serve_with_incoming_shutdown(
                openshell_core::external_driver_socket::SameUidUnixIncoming::new(listener),
                shutdown,
            )
            .await
            .into_diagnostic()
    } else {
        info!(address = %bind_address, "Starting Kyma compute driver");
        tonic::transport::Server::builder()
            .layer(openshell_otel::compute_driver_rpc_layer())
            .add_service(service)
            .serve_with_shutdown(bind_address, shutdown)
            .await
            .into_diagnostic()
    }
}
