// SPDX-License-Identifier: Apache-2.0

//! Upstream's `openshell-driver-kubernetes` option surface, mirrored verbatim.
//!
//! The body of [`UpstreamArgs`] is upstream's `struct Args` from
//! `crates/openshell-driver-kubernetes/src/main.rs` at the pinned tag, with
//! `pub` added to each field; the `KubernetesComputeConfig { … }` literal in
//! [`compute_config`] is upstream's `main()` literal. Accepting exactly
//! upstream's flags and environment variables is what makes this driver
//! configure identically to upstream's. Do not edit either block by hand except
//! to mirror an upstream change: `scripts/check-upstream-args.sh` fails CI when
//! they drift.

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::PathBuf;

use clap::ArgAction;
use openshell_driver_kubernetes::{
    KubernetesComputeConfig, KubernetesImagePullPolicy, KubernetesSandboxRuntimeConfig,
    ManagedSshIngressConfig, WorkspaceMode, DEFAULT_GATEWAY_ID,
    DEFAULT_SANDBOX_SERVICE_ACCOUNT_NAME,
};

#[derive(clap::Args, Debug)]
#[allow(clippy::struct_excessive_bools)]
pub struct UpstreamArgs {
    /// Operator-owned JSON policy; omitted means driver config disabled and labels required.
    #[arg(
        long,
        env = "OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON",
        default_value = "{}"
    )]
    pub admission_config_json: openshell_core::resource_admission::DriverAdmissionConfig,
    /// Public compute-driver Unix socket used by an external gateway.
    #[arg(long, env = "OPENSHELL_COMPUTE_DRIVER_SOCKET")]
    pub bind_socket: Option<PathBuf>,

    #[arg(
        long,
        env = "OPENSHELL_COMPUTE_DRIVER_BIND",
        default_value = "127.0.0.1:50061"
    )]
    pub bind_address: SocketAddr,

    #[arg(long, env = "OPENSHELL_LOG_LEVEL", default_value = "info")]
    pub log_level: String,

    #[arg(long, env = "OPENSHELL_OTLP_ENDPOINT")]
    pub otlp_endpoint: Option<String>,

    #[arg(long, env = "OPENSHELL_GATEWAY_NAME")]
    pub gateway_name: Option<String>,

    #[arg(long, env = "OPENSHELL_WORKSPACE_MODE", default_value = "shared")]
    pub workspace_mode: WorkspaceMode,

    #[arg(
        long,
        env = "OPENSHELL_GATEWAY_ID",
        default_value = DEFAULT_GATEWAY_ID
    )]
    pub gateway_id: String,

    #[arg(long, env = "OPENSHELL_SANDBOX_NAMESPACE", default_value = "default")]
    pub sandbox_namespace: String,

    #[arg(long, env = "OPENSHELL_OPERATOR_NAMESPACE_LABEL")]
    pub operator_namespace_label: Option<String>,

    #[arg(long, env = "OPENSHELL_OPERATOR_NAMESPACE_FILE")]
    pub operator_namespace_file: Option<String>,

    #[arg(
        long,
        env = "OPENSHELL_K8S_SANDBOX_SERVICE_ACCOUNT",
        default_value = DEFAULT_SANDBOX_SERVICE_ACCOUNT_NAME
    )]
    pub sandbox_service_account: String,

    #[arg(long, env = "OPENSHELL_SANDBOX_IMAGE")]
    pub sandbox_image: Option<String>,

    #[arg(long, env = "OPENSHELL_SANDBOX_IMAGE_PULL_POLICY")]
    pub sandbox_image_pull_policy: Option<KubernetesImagePullPolicy>,

    #[arg(
        long,
        env = "OPENSHELL_SANDBOX_IMAGE_PULL_SECRETS",
        value_delimiter = ','
    )]
    pub sandbox_image_pull_secrets: Vec<String>,

    #[arg(long, env = "OPENSHELL_MANAGED_SSH_INGRESS_ENABLED")]
    pub managed_ssh_ingress_enabled: bool,

    #[arg(long, env = "OPENSHELL_MANAGED_SSH_GATEWAY_NAMESPACE")]
    pub managed_ssh_gateway_namespace: Option<String>,

    #[arg(
        long,
        env = "OPENSHELL_MANAGED_SSH_GATEWAY_POD_SELECTOR",
        value_delimiter = ','
    )]
    pub managed_ssh_gateway_pod_selector: Vec<String>,

    #[arg(long, env = "OPENSHELL_GRPC_ENDPOINT")]
    pub grpc_endpoint: Option<String>,

    #[arg(
        long,
        env = "OPENSHELL_SANDBOX_SSH_SOCKET_PATH",
        default_value = openshell_core::container_paths::SSH_SOCKET_PATH
    )]
    pub sandbox_ssh_socket_path: String,

    #[arg(long, env = "OPENSHELL_CLIENT_TLS_SECRET_NAME")]
    pub client_tls_secret_name: Option<String>,

    #[arg(long, env = "OPENSHELL_HOST_GATEWAY_IP")]
    pub host_gateway_ip: Option<String>,

    #[arg(long, env = "OPENSHELL_SANDBOX_RUNTIME_IMAGE")]
    pub sandbox_runtime_image: Option<String>,

    #[arg(long, env = "OPENSHELL_SANDBOX_RUNTIME_IMAGE_PULL_POLICY")]
    pub sandbox_runtime_image_pull_policy: Option<KubernetesImagePullPolicy>,

    #[arg(long, env = "OPENSHELL_SUPERVISOR_IMAGE")]
    pub supervisor_image: Option<String>,

    #[arg(long, env = "OPENSHELL_SUPERVISOR_IMAGE_PULL_POLICY")]
    pub supervisor_image_pull_policy: Option<KubernetesImagePullPolicy>,

    #[arg(
        long,
        env = "OPENSHELL_K8S_SANDBOX_RUNTIME_BOUNDARY_PORT",
        default_value_t = 5500
    )]
    pub sandbox_runtime_boundary_port: u16,

    /// Corporate HTTP forward proxy for policy-approved TLS CONNECT egress.
    #[arg(long, env = "OPENSHELL_UPSTREAM_PROXY")]
    pub https_proxy: Option<String>,

    /// Comma-separated destinations that bypass the corporate proxy.
    #[arg(long, env = "OPENSHELL_UPSTREAM_NO_PROXY")]
    pub no_proxy: Option<String>,

    /// Kubernetes Secret name containing the upstream proxy credential.
    #[arg(long, env = "OPENSHELL_UPSTREAM_PROXY_AUTH_SECRET_NAME")]
    pub proxy_auth_secret_name: Option<String>,

    /// Kubernetes Secret key containing the upstream proxy credential.
    #[arg(long, env = "OPENSHELL_UPSTREAM_PROXY_AUTH_SECRET_KEY")]
    pub proxy_auth_secret_key: Option<String>,

    /// Acknowledge cleartext Basic auth to an http:// upstream proxy.
    #[arg(long, env = "OPENSHELL_UPSTREAM_PROXY_AUTH_ALLOW_INSECURE", action = ArgAction::SetTrue)]
    pub proxy_auth_allow_insecure: bool,

    /// Send destination hostnames rather than validated IPs in CONNECT.
    #[arg(long, env = "OPENSHELL_UPSTREAM_PROXY_CONNECT_BY_HOSTNAME", action = ArgAction::SetTrue)]
    pub proxy_connect_by_hostname: bool,

    /// Path to a PEM CA bundle trusted for the corporate proxy. Required for
    /// an `https://` proxy with a private CA, and for a TLS-intercepting proxy
    /// that re-signs upstream certificates. Read by this process and staged
    /// into each sandbox's supervisor bootstrap Secret.
    #[arg(long, env = "OPENSHELL_UPSTREAM_PROXY_CA_BUNDLE")]
    pub proxy_ca_bundle: Option<String>,

    #[arg(long, env = "OPENSHELL_ENABLE_USER_NAMESPACES")]
    pub enable_user_namespaces: bool,

    /// Lifetime (seconds) of the projected `ServiceAccount` token
    /// kubelet writes into each sandbox pod for the `IssueSandboxToken`
    /// bootstrap exchange. Kubelet enforces a minimum of 600s; the
    /// gateway clamps values outside `[600, 86400]`. Default 3600.
    #[arg(long, env = "OPENSHELL_K8S_SA_TOKEN_TTL_SECS", default_value_t = 3600)]
    pub sa_token_ttl_secs: i64,

    #[arg(long, env = "OPENSHELL_PROVIDER_SPIFFE_WORKLOAD_API_SOCKET")]
    pub provider_spiffe_workload_api_socket_path: Option<String>,

    #[arg(long, env = "OPENSHELL_K8S_SANDBOX_UID")]
    pub sandbox_uid: Option<u32>,

    #[arg(long, env = "OPENSHELL_K8S_SANDBOX_GID")]
    pub sandbox_gid: Option<u32>,
}

/// Upstream's parser for `--managed-ssh-gateway-pod-selector` (`key=value`).
pub fn parse_managed_ssh_gateway_pod_selector(
    entries: &[String],
) -> miette::Result<BTreeMap<String, String>> {
    entries
        .iter()
        .map(|entry| {
            entry
                .split_once('=')
                .map(|(key, value)| (key.to_string(), value.to_string()))
                .ok_or_else(|| {
                    miette::miette!("managed SSH gateway pod selector must use key=value: {entry}")
                })
        })
        .collect::<miette::Result<BTreeMap<_, _>>>()
}

/// Build upstream's driver configuration from its own option surface.
///
/// `args` is consumed exactly as upstream's `main()` consumes it, so the
/// literal below stays byte-comparable with upstream's.
pub fn compute_config(
    args: UpstreamArgs,
    managed_ssh_gateway_pod_selector: BTreeMap<String, String>,
) -> KubernetesComputeConfig {
    KubernetesComputeConfig {
        allow_driver_config: args.admission_config_json.allow_driver_config,
        resource_admission: args.admission_config_json.resource_admission.clone(),
        workspace_mode: args.workspace_mode,
        gateway_id: args.gateway_id,
        namespace: args.sandbox_namespace,
        operator_namespace_label: args.operator_namespace_label,
        operator_namespace_file: args.operator_namespace_file,
        service_account_name: args.sandbox_service_account,
        default_image: args.sandbox_image.unwrap_or_default(),
        image_pull_policy: args.sandbox_image_pull_policy,
        image_pull_secrets: args.sandbox_image_pull_secrets,
        managed_ssh_ingress: ManagedSshIngressConfig {
            enabled: args.managed_ssh_ingress_enabled,
            gateway_namespace: args.managed_ssh_gateway_namespace.unwrap_or_default(),
            gateway_pod_selector: managed_ssh_gateway_pod_selector,
        },
        sandbox_runtime_image: args
            .sandbox_runtime_image
            .unwrap_or_else(openshell_core::config::default_sandbox_runtime_image),
        sandbox_runtime_image_pull_policy: args.sandbox_runtime_image_pull_policy,
        supervisor_image: args
            .supervisor_image
            .unwrap_or_else(openshell_core::config::default_supervisor_image),
        supervisor_image_pull_policy: args.supervisor_image_pull_policy,
        sandbox_runtime: KubernetesSandboxRuntimeConfig {
            boundary_port: args.sandbox_runtime_boundary_port,
        },
        https_proxy: args.https_proxy,
        no_proxy: args.no_proxy,
        proxy_auth_secret_name: args.proxy_auth_secret_name,
        proxy_auth_secret_key: args.proxy_auth_secret_key,
        proxy_auth_allow_insecure: args.proxy_auth_allow_insecure.then_some(true),
        proxy_connect_by_hostname: args.proxy_connect_by_hostname.then_some(true),
        proxy_ca_bundle: args.proxy_ca_bundle,
        grpc_endpoint: args.grpc_endpoint.unwrap_or_default(),
        ssh_socket_path: args.sandbox_ssh_socket_path,
        client_tls_secret_name: args.client_tls_secret_name.unwrap_or_default(),
        host_gateway_ip: args.host_gateway_ip.unwrap_or_default(),
        enable_user_namespaces: args.enable_user_namespaces,
        workspace_default_storage_size: std::env::var(
            "OPENSHELL_K8S_WORKSPACE_DEFAULT_STORAGE_SIZE",
        )
        .unwrap_or_else(|_| {
            openshell_driver_kubernetes::DEFAULT_WORKSPACE_STORAGE_SIZE.to_string()
        }),
        workspace_storage_class: std::env::var("OPENSHELL_K8S_WORKSPACE_STORAGE_CLASS")
            .unwrap_or_default(),
        default_runtime_class_name: std::env::var("OPENSHELL_K8S_DEFAULT_RUNTIME_CLASS_NAME")
            .unwrap_or_default(),
        sa_token_ttl_secs: args.sa_token_ttl_secs,
        provider_spiffe_workload_api_socket_path: args
            .provider_spiffe_workload_api_socket_path
            .unwrap_or_default(),
        sandbox_uid: args.sandbox_uid,
        sandbox_gid: args.sandbox_gid,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[derive(Parser)]
    struct Probe {
        #[command(flatten)]
        args: UpstreamArgs,
    }

    fn parse(argv: &[&str]) -> UpstreamArgs {
        let mut full = vec!["openshell-driver-kyma"];
        full.extend_from_slice(argv);
        Probe::try_parse_from(full)
            .expect("arguments should parse")
            .args
    }

    // Upstream's own test, carried over unchanged in substance.
    #[test]
    fn accepts_gateway_otlp_configuration() {
        let args = parse(&[
            "--otlp-endpoint",
            "http://collector.example:4317",
            "--gateway-name",
            "kubernetes-dev",
        ]);
        assert_eq!(
            args.otlp_endpoint.as_deref(),
            Some("http://collector.example:4317")
        );
        assert_eq!(args.gateway_name.as_deref(), Some("kubernetes-dev"));
    }

    #[test]
    fn defaults_match_upstream() {
        let args = parse(&[]);
        assert_eq!(args.sandbox_namespace, "default");
        assert_eq!(args.bind_address.to_string(), "127.0.0.1:50061");
        assert_eq!(args.sandbox_runtime_boundary_port, 5500);
        assert_eq!(args.sa_token_ttl_secs, 3600);
        assert!(args.bind_socket.is_none());
    }

    #[test]
    fn compute_config_uses_the_mirrored_options() {
        let args = parse(&[
            "--sandbox-namespace",
            "sandboxes",
            "--supervisor-image",
            "registry.example/supervisor@sha256:aaaa",
            "--sandbox-runtime-image",
            "registry.example/sandbox@sha256:bbbb",
            "--sa-token-ttl-secs",
            "7200",
        ]);
        let config = compute_config(args, BTreeMap::new());
        assert_eq!(config.namespace, "sandboxes");
        assert_eq!(
            config.supervisor_image,
            "registry.example/supervisor@sha256:aaaa"
        );
        assert_eq!(
            config.sandbox_runtime_image,
            "registry.example/sandbox@sha256:bbbb"
        );
        assert_eq!(config.sa_token_ttl_secs, 7200);
    }

    #[test]
    fn pod_selector_requires_key_value_pairs() {
        let parsed = parse_managed_ssh_gateway_pod_selector(&["app=gateway".to_string()])
            .expect("key=value parses");
        assert_eq!(parsed["app"], "gateway");
        assert!(parse_managed_ssh_gateway_pod_selector(&["gateway".to_string()]).is_err());
    }
}
