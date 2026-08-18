//! Driver configuration parsed from the command line and/or environment.
//!
//! Every field has a default that matches the design spec's flag table.
//! `Config::from_env_and_args()` is the binary's parser entrypoint;
//! `Config::default()` is what tests use to construct a sane, isolated
//! configuration.

use clap::Parser;

/// Runtime configuration for the driver. Field defaults match the public
/// flag table in the design spec.
#[derive(Debug, Clone, Parser)]
#[command(
    name = "openshell-driver-kyma",
    version,
    about = "OpenShell ComputeDriver gRPC service for SAP BTP Kyma",
    long_about = None,
)]
pub struct Config {
    /// Unix domain socket path the gRPC server listens on.
    #[arg(long, default_value = "/var/run/openshell-driver.sock")]
    pub socket: String,

    /// Kubernetes namespace where the driver creates Sandbox CRs.
    #[arg(long, default_value = "openshell-system")]
    pub namespace: String,

    /// OCI image containing the supervisor binary copied into the sandbox.
    #[arg(long, default_value = "ghcr.io/nvidia/openshell/supervisor:latest")]
    pub supervisor_image: String,

    /// Path to the supervisor binary inside the supervisor image.
    #[arg(long, default_value = "/openshell-sandbox")]
    pub supervisor_binary_path: String,

    /// Mount path for the supervisor binary volume in the agent container.
    #[arg(long, default_value = "/opt/openshell/bin")]
    pub supervisor_mount_path: String,

    /// Gateway gRPC endpoint the supervisor calls back to.
    /// Empty string means "do not inject the OPENSHELL_ENDPOINT env var".
    #[arg(long, default_value = "")]
    pub gateway_endpoint: String,

    /// When false, the driver stamps `sidecar.istio.io/inject: "false"` on
    /// every sandbox pod template so Istio leaves the pod alone.
    #[arg(long, default_value_t = false, action = clap::ArgAction::Set, num_args = 0..=1, default_missing_value = "true")]
    pub istio_inject_sandboxes: bool,

    /// When true, the driver creates a `gateway.kyma-project.io/v2/APIRule`
    /// per sandbox so the sandbox is reachable outside the cluster.
    #[arg(long, default_value_t = false, action = clap::ArgAction::Set, num_args = 0..=1, default_missing_value = "true")]
    pub enable_apirule: bool,

    /// Kyma cluster domain suffix (e.g. `<id>.kyma.ondemand.com`). Empty
    /// string asks the driver to discover the value from the cluster's
    /// Istio Gateway at startup. Only consulted when `--enable-apirule`.
    #[arg(long, default_value = "")]
    pub cluster_domain: String,

    /// When true, the driver lists nodes (cluster-scope read-only) and
    /// validates GPU capacity before accepting a GPU sandbox request.
    /// Set to false to run with namespace-only RBAC (sandbox creation
    /// without GPUs still works).
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set, num_args = 0..=1, default_missing_value = "true")]
    pub gpu_support: bool,

    /// When true, the Helm chart renders the optional sandbox NetworkPolicy.
    /// This flag is propagated for tooling consistency; the chart consults
    /// `.Values.enableNetworkPolicy` directly.
    #[arg(long, default_value_t = false, action = clap::ArgAction::Set, num_args = 0..=1, default_missing_value = "true")]
    pub enable_network_policy: bool,

    /// When true, the driver injects `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`
    /// into every sandbox pod's env. Useful when sandboxes are routed through
    /// an in-cluster LLM gateway that can't service Anthropic's optional
    /// telemetry endpoints.
    #[arg(long, default_value_t = false, action = clap::ArgAction::Set, num_args = 0..=1, default_missing_value = "true")]
    pub disable_claude_telemetry: bool,

    /// When true, sandbox pods run with `hostUsers: false` so the
    /// container's UID 0 is remapped to a non-root host UID via a Linux
    /// user namespace. The agent container's `privileged: true` is also
    /// dropped — the SYS_ADMIN/NET_ADMIN/SYS_PTRACE/SYSLOG capabilities
    /// remain (they're namespaced) so the supervisor's Landlock and
    /// network-namespace setup still work, but the container can no
    /// longer escape to host root.
    ///
    /// Requires Kubernetes 1.30+ with `UserNamespacesSupport` feature
    /// gate enabled (default-on in K8s 1.33+, alpha in 1.30-1.32).
    /// Kyma/Gardener clusters expose this on recent shoot versions.
    #[arg(long, default_value_t = false, action = clap::ArgAction::Set, num_args = 0..=1, default_missing_value = "true")]
    pub enable_user_namespaces: bool,

    /// Per-sandbox PVC size for the `/sandbox` workspace mount. Empty
    /// string disables persistent workspaces (default — workspace is
    /// pod-local emptyDir managed by the supervisor). Any non-empty value
    /// is passed through to the rendered PVC's `resources.requests.storage`
    /// (e.g. `5Gi`, `200Mi`).
    #[arg(long, default_value = "")]
    pub sandbox_storage_size: String,

    /// StorageClassName for per-sandbox workspace PVCs. Empty string lets
    /// Kubernetes pick the cluster's default StorageClass. Only consulted
    /// when `--sandbox-storage-size` is non-empty.
    #[arg(long, default_value = "")]
    pub sandbox_storage_class: String,

    /// HTTP port for the sidecar `/healthz`, `/readyz`, and `/metrics`
    /// endpoints. The gRPC server still listens on the UDS only.
    #[arg(long, default_value_t = 9090)]
    pub health_port: u16,

    /// Tracing log level. `RUST_LOG` overrides this when set.
    #[arg(long, default_value = "info")]
    pub log_level: String,

    /// How long `stop_sandbox` waits for the pod to terminate before giving
    /// up. Raise it for workloads with long graceful-shutdown handlers.
    #[arg(long, default_value_t = 120)]
    pub stop_timeout_secs: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            socket: "/var/run/openshell-driver.sock".to_string(),
            namespace: "openshell-system".to_string(),
            supervisor_image: "ghcr.io/nvidia/openshell/supervisor:latest".to_string(),
            supervisor_binary_path: "/openshell-sandbox".to_string(),
            supervisor_mount_path: "/opt/openshell/bin".to_string(),
            gateway_endpoint: String::new(),
            istio_inject_sandboxes: false,
            enable_apirule: false,
            cluster_domain: String::new(),
            gpu_support: true,
            enable_network_policy: false,
            disable_claude_telemetry: false,
            enable_user_namespaces: false,
            sandbox_storage_size: String::new(),
            sandbox_storage_class: String::new(),
            health_port: 9090,
            log_level: "info".to_string(),
            stop_timeout_secs: 120,
        }
    }
}

impl Config {
    /// Parse configuration from `std::env::args` and environment variables.
    /// Used by the binary's `main`. Tests should use `Config::default()`.
    #[must_use]
    pub fn from_env_and_args() -> Self {
        Self::parse()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_spec() {
        let c = Config::default();
        assert_eq!(c.socket, "/var/run/openshell-driver.sock");
        assert_eq!(c.namespace, "openshell-system");
        assert_eq!(
            c.supervisor_image,
            "ghcr.io/nvidia/openshell/supervisor:latest"
        );
        assert_eq!(c.supervisor_binary_path, "/openshell-sandbox");
        assert_eq!(c.supervisor_mount_path, "/opt/openshell/bin");
        assert_eq!(c.gateway_endpoint, "");
        assert!(!c.istio_inject_sandboxes);
        assert!(!c.enable_apirule);
        assert_eq!(c.cluster_domain, "");
        assert!(c.gpu_support);
        assert!(!c.enable_network_policy);
        assert!(!c.disable_claude_telemetry);
        assert!(!c.enable_user_namespaces);
        assert_eq!(c.sandbox_storage_size, "");
        assert_eq!(c.sandbox_storage_class, "");
        assert_eq!(c.health_port, 9090);
        assert_eq!(c.log_level, "info");
    }

    #[test]
    fn clap_parses_all_flags() {
        let c = Config::parse_from([
            "openshell-driver-kyma",
            "--socket",
            "/tmp/d.sock",
            "--namespace",
            "test-ns",
            "--supervisor-image",
            "test/sup:1.2.3",
            "--enable-apirule",
            "--gpu-support=false",
            "--health-port",
            "8080",
            "--log-level",
            "debug",
        ]);
        assert_eq!(c.socket, "/tmp/d.sock");
        assert_eq!(c.namespace, "test-ns");
        assert_eq!(c.supervisor_image, "test/sup:1.2.3");
        assert!(c.enable_apirule);
        assert!(!c.gpu_support);
        assert_eq!(c.health_port, 8080);
        assert_eq!(c.log_level, "debug");
    }

    #[test]
    fn clap_defaults_match_default_impl() {
        let cli = Config::parse_from(["openshell-driver-kyma"]);
        let dflt = Config::default();
        assert_eq!(cli.socket, dflt.socket);
        assert_eq!(cli.namespace, dflt.namespace);
        assert_eq!(cli.supervisor_image, dflt.supervisor_image);
        assert_eq!(cli.istio_inject_sandboxes, dflt.istio_inject_sandboxes);
        assert_eq!(cli.enable_apirule, dflt.enable_apirule);
        assert_eq!(cli.gpu_support, dflt.gpu_support);
        assert_eq!(cli.health_port, dflt.health_port);
    }
}
