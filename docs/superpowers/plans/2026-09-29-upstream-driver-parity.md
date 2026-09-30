# Upstream Kubernetes Driver Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild `openshell-driver-kyma` as a thin Kyma layer over upstream NVIDIA OpenShell v0.1.2's `openshell-driver-kubernetes` crate so the driver has 100% feature parity with upstream's Kubernetes driver, and sandboxes run on Kyma again.

**Architecture:** The binary builds upstream's `KubernetesComputeDriver` from a verbatim copy of upstream's option surface, wraps it in upstream's own `ComputeDriverService`, and serves a `KymaComputeDriver<S>` that forwards every RPC to it. Three Kyma hooks sit around the forwarding: request enrichment before `CreateSandbox`, APIRule exposure after it, and PSA labelling after `EnsureWorkspace` in Managed mode. The chart mirrors upstream's option surface and RBAC; CI guards keep both from drifting.

**Tech Stack:** Rust 2021 (toolchain 1.95), tonic 0.14, kube 0.99 + k8s-openapi 0.24 (`v1_29`) — upstream's versions, clap 4 (`derive` + `env`), axum 0.8, Helm 3, bash + python3 CI scripts, GitHub Actions, kind.

**Spec:** `docs/superpowers/specs/2026-09-29-upstream-driver-parity-design.md` — read the "Amendments from planning" section; it overrides earlier sections where they conflict.

## Global Constraints

- Work on branch `feat/upstream-driver-parity`. Never commit to `main`.
- Rust builds and tests run **only** in the dev container: `make fmt` first, then `make test` (`fmt-check` + `clippy` + `cargo test --workspace --lib --tests`). Never run bare `cargo` on the host — it has no Rust toolchain. Formatting first is what lets the TDD red run reach the compiler.
- Commit with the repo's configured identity. Pass **no** `-c user.email` / `-c user.name`. End every commit message with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Upstream pin: `https://github.com/NVIDIA/OpenShell`, tag `v0.1.2`, for all three git dependencies (`openshell-driver-kubernetes`, `openshell-core`, `openshell-otel`). One tag, everywhere.
- `kube = "0.99"` and `k8s-openapi = "0.24"` with feature `v1_29` — exactly upstream's. Never feature `latest`, never `kube` 4.x in this workspace.
- The body of `UpstreamArgs` and the `KubernetesComputeConfig { … }` literal in `upstream_args.rs` are verbatim upstream. Never edit them by hand except to mirror an upstream change; `scripts/check-upstream-args.sh` enforces it.
- Kyma options: long flag prefix `--kyma-`, env prefix `OPENSHELL_KYMA_`.
- Objects the Kyma layer creates carry `app.kubernetes.io/managed-by: openshell-driver-kyma` and `openshell.ai/sandbox-id`; **never** `openshell.ai/managed-by: openshell`.
- Never modify, patch or delete upstream-owned objects (supervisor pods, `os-*` Secrets/Services, `openshell-sandbox-*` NetworkPolicies, Sandbox CRs).
- Enrichment and exposure must never fail `CreateSandbox`.
- Images are digest-pinned: supervisor `ghcr.io/nvidia/openshell/supervisor@sha256:d7b5264bb6bc56f4796e6fa3617b8e4a8d785be0b7293542efd8cc250b0fb67a`, sandbox runtime `ghcr.io/nvidia/openshell/sandbox@sha256:bf4797b6c511f2d8ba02955dbba4bf76c1f0dd6d83531420c5408d5f1fb9d72f` (both v0.1.2).
- Never write cluster-identifying values (cluster id, namespace UIDs, the `istio-system` namespace's component label) into any file, commit, log or prompt. Select namespaces by `kubernetes.io/metadata.name`.
- `provisioner.rs` et al. are deleted in Task 1 — do not port logic from them unless a task says so.
- **Outward-facing actions need the repo owner's explicit approval at the time:** `git push`, opening/merging PRs, creating tags, and anything that changes the live cluster. Tasks 13 and 14 contain those gates; stop and ask there.

## Review Focus

1. **Caller keys that collide with enrichment** — a sandbox created with its own `sidecar.istio.io/inject` label or an env var the chart also supplies must keep the caller's value. (Task 3, `caller_values_win_over_enrichment`.)
2. **A malformed `--kyma-sandbox-env` entry** (`FOO`, `=bar`) must stop the driver at startup naming the entry, not be silently dropped. (Task 3, `malformed_sandbox_env_is_rejected_by_name`.)
3. **APIRule creation rejected while exposure is enabled** (APIRule CRD absent, webhook denial) — `CreateSandbox` still succeeds and a Warning Event lands on the Sandbox CR. (Task 5, `apirule_failure_emits_a_warning_event`.)
4. **Shared-mode exposure with namespaced RBAC** — the CR lookup must be namespaced; a cluster-wide list would be forbidden by the shared-mode Role. (Task 5, `shared_mode_lookup_is_namespaced`.)
5. **Upstream adds or changes an option at the next bump** — CI must fail rather than the option silently going missing from the driver or the chart. (Task 2 perturbation proof; Task 7 `check-chart-render.sh` env-parity check.)

---

## File Structure

`crates/openshell-driver-kyma/` after this plan:

| File | Responsibility |
|---|---|
| `Cargo.toml` | Upstream git deps + the few crates the Kyma layer needs. |
| `src/lib.rs` | Module declarations only. |
| `src/upstream_args.rs` | Verbatim upstream option surface (`UpstreamArgs`), the verbatim config literal (`compute_config`), and upstream's pod-selector parser. |
| `src/kyma_args.rs` | Kyma options (`KymaArgs`), their validation, and derived hook configs. |
| `src/service.rs` | `KymaHooks` trait, `NoHooks`, and `KymaComputeDriver<S>` — forwards all 12 RPCs, runs hooks around `CreateSandbox`/`EnsureWorkspace`. |
| `src/enrich.rs` | Hook 1: pure request enrichment (labels + env). |
| `src/exposure.rs` | Hook 2: pure manifest builders + `ExposureReconciler` (Service, NetworkPolicy exception, APIRule, failure Event). |
| `src/namespaces.rs` | Hook 3: `NamespaceLabeler` for Managed-mode PSA labels. |
| `src/hooks.rs` | `KymaHookSet` — the production `KymaHooks` implementation composing the three hooks. |
| `src/health.rs` | `/healthz` and `/readyz` on the Kyma health port. |
| `src/main.rs` | Parse, trace, build upstream driver, wrap, serve on the socket, serve health. |

Deleted in Task 1: every other file under `crates/openshell-driver-kyma/src/` (including `src/vendor/`), `crates/openshell-driver-kyma/tests/`, and `crates/computev1/`. Deleted in Task 2: `proto/`, `scripts/vendor-proto.sh`, `scripts/check-proto-drift.sh`, `scripts/check-vendor-drift.sh`.

New scripts: `scripts/check-upstream-args.sh` (Task 2), `scripts/check-chart-render.sh` (Tasks 7–8).

Chart (`deploy/helm/openshell-driver-kyma/`): `templates/deployment.yaml`, `values.yaml`, `templates/gateway-config.yaml` (Task 7); `templates/role.yaml`, new `templates/clusterrole.yaml` replacing `clusterrole-{tokenreview,nodes,workspaces}.yaml`, `templates/rolebinding.yaml`, new `templates/clusterrolebinding.yaml`, `templates/networkpolicy.yaml` (Task 8); `templates/inference-provider-hook.yaml`, new `templates/inference-provider-profile.yaml` (Task 9).

---

### Task 1: Replace the driver core with a forwarding wrapper over upstream

The whole old implementation goes; upstream's driver takes its place behind a wrapper that forwards every RPC. Hooks exist as a trait with a no-op implementation; later tasks fill them in.

**Files:**
- Delete: every file under `crates/openshell-driver-kyma/src/` except `lib.rs` and `main.rs` (which are rewritten), including `src/vendor/`; `crates/openshell-driver-kyma/tests/`; `crates/computev1/`
- Modify: `Cargo.toml` (workspace), `crates/openshell-driver-kyma/Cargo.toml`, `Makefile`
- Create: `crates/openshell-driver-kyma/src/upstream_args.rs`, `src/kyma_args.rs`, `src/service.rs`
- Rewrite: `crates/openshell-driver-kyma/src/lib.rs`, `src/main.rs`

**Interfaces:**
- Produces: `openshell_driver_kyma::upstream_args::{UpstreamArgs, compute_config(args: UpstreamArgs, managed_ssh_gateway_pod_selector: BTreeMap<String, String>) -> KubernetesComputeConfig, parse_managed_ssh_gateway_pod_selector(entries: &[String]) -> miette::Result<BTreeMap<String, String>>}`
- Produces: `openshell_driver_kyma::kyma_args::KymaArgs` — `#[derive(clap::Args, Debug, Clone, Default)]`, empty in this task.
- Produces: `openshell_driver_kyma::service::KymaHooks` — `fn enrich(&self, sandbox: &mut DriverSandbox)`, `async fn after_create(&self, sandbox: DriverSandbox)`, `async fn after_ensure_workspace(&self, workspace: &str) -> Result<(), tonic::Status>`; `NoHooks`; `KymaComputeDriver<S>` with `KymaComputeDriver::new(inner: S, hooks: Arc<dyn KymaHooks>) -> Self`, implementing `openshell_core::proto::compute::v1::compute_driver_server::ComputeDriver` for any `S: ComputeDriver`.

- [ ] **Step 1: Delete the old implementation**

```bash
git rm -r -q crates/computev1 crates/openshell-driver-kyma/tests
cd crates/openshell-driver-kyma/src
git rm -r -q $(ls | grep -vE '^(lib|main)\.rs$')
cd -
```

In the workspace `Makefile`, delete the whole `test-integration` target (its recipe runs `--test live_cluster --features integration`, which no longer exists).

- [ ] **Step 2: Point the workspace at upstream's crates and versions**

In the root `Cargo.toml`:

- change `members` to `["crates/openshell-driver-kyma", "crates/openshell-bedrock-bridge"]`;
- replace the two Kubernetes client lines and their comment with:

```toml
# Kubernetes client — pinned to upstream NVIDIA OpenShell's versions, because
# this driver links upstream's Kubernetes driver and must share one kube stack
# with it. Follow upstream here; never bump these independently.
kube = { version = "0.99", default-features = false, features = ["client", "rustls-tls"] }
k8s-openapi = { version = "0.24", features = ["v1_29"] }

# Upstream NVIDIA OpenShell — this driver is a thin layer over its Kubernetes
# driver. One tag for all three; `make upstream-bump TAG=...` moves them together.
openshell-driver-kubernetes = { git = "https://github.com/NVIDIA/OpenShell", tag = "v0.1.2" }
openshell-core = { git = "https://github.com/NVIDIA/OpenShell", tag = "v0.1.2", default-features = false }
openshell-otel = { git = "https://github.com/NVIDIA/OpenShell", tag = "v0.1.2" }
miette = { version = "7", features = ["fancy"] }
```

- change the `clap` line to `clap = { version = "4", features = ["derive", "env"] }` — upstream's options read environment variables, which needs clap's `env` feature.

Keep each `openshell-*` line on exactly one line in that format: `scripts/check-upstream-args.sh` and `make upstream-bump` parse it.

- [ ] **Step 3: Replace the crate manifest**

Replace the `[dependencies]` and `[dev-dependencies]` sections of `crates/openshell-driver-kyma/Cargo.toml` (keep the `[package]` section; delete any `[features]` section and any `[[test]]` entries) with:

```toml
[dependencies]
openshell-driver-kubernetes = { workspace = true }
openshell-core = { workspace = true }
openshell-otel = { workspace = true }
tonic = { workspace = true, features = ["transport"] }
tokio = { workspace = true }
clap = { workspace = true }
miette = { workspace = true }
tracing = { workspace = true }

[dev-dependencies]
futures = { workspace = true }
```

Later tasks add what they need. Do not carry over `computev1`, `prometheus`, `rustls`, `serde_yaml` or the old kube-based crates.

- [ ] **Step 4: Rewrite `lib.rs`**

```rust
// SPDX-License-Identifier: Apache-2.0

//! OpenShell compute driver for SAP BTP Kyma.
//!
//! Upstream NVIDIA OpenShell's Kubernetes driver does all the compute work;
//! this crate mirrors its option surface and wraps its gRPC service with a
//! small Kyma layer. See `docs/superpowers/specs/2026-09-29-upstream-driver-parity-design.md`.

pub mod kyma_args;
pub mod service;
pub mod upstream_args;
```

- [ ] **Step 5: Create `src/upstream_args.rs` with the verbatim upstream surface**

This content was generated mechanically from upstream `v0.1.2` `crates/openshell-driver-kubernetes/src/main.rs` and verified identical by `scripts/check-upstream-args.sh` (Task 2). Copy it exactly:

```rust
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
    DEFAULT_GATEWAY_ID, DEFAULT_SANDBOX_SERVICE_ACCOUNT_NAME, KubernetesComputeConfig,
    KubernetesImagePullPolicy, KubernetesSandboxRuntimeConfig, ManagedSshIngressConfig,
    WorkspaceMode,
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
```

Append this test module to the same file:

```rust
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
        Probe::try_parse_from(full).expect("arguments should parse").args
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
        assert_eq!(args.otlp_endpoint.as_deref(), Some("http://collector.example:4317"));
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
        assert_eq!(config.supervisor_image, "registry.example/supervisor@sha256:aaaa");
        assert_eq!(config.sandbox_runtime_image, "registry.example/sandbox@sha256:bbbb");
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
```

- [ ] **Step 6: Create `src/kyma_args.rs`**

```rust
// SPDX-License-Identifier: Apache-2.0

//! Kyma-layer options. Every flag starts with `--kyma-` and every environment
//! variable with `OPENSHELL_KYMA_`, so they can never collide with upstream's.

/// Kyma options, flattened next to [`crate::upstream_args::UpstreamArgs`].
#[derive(clap::Args, Debug, Clone, Default)]
pub struct KymaArgs {}
```

- [ ] **Step 7: Write the failing service tests**

Create `src/service.rs` containing only the imports below and the test module; the implementation comes in Step 9.

```rust
// SPDX-License-Identifier: Apache-2.0

//! The Kyma compute driver: upstream's `ComputeDriverService` behind three
//! Kyma hooks.
//!
//! Every RPC is forwarded verbatim. Only `CreateSandbox` (enrich before,
//! expose after) and `EnsureWorkspace` (label after) add behaviour, so
//! capabilities, admission, sandbox authentication and runtime identity are
//! upstream's own — that is what makes this driver behave like upstream's.

use std::sync::Arc;

use openshell_core::proto::compute::v1::{
    compute_driver_server::ComputeDriver, AuthenticateSandboxRequest,
    AuthenticateSandboxResponse, CreateSandboxRequest, CreateSandboxResponse,
    DeleteSandboxRequest, DeleteSandboxResponse, DeleteWorkspaceRequest,
    DeleteWorkspaceResponse, DriverSandbox, EnsureWorkspaceRequest, EnsureWorkspaceResponse,
    GetCapabilitiesRequest, GetCapabilitiesResponse, GetSandboxRequest, GetSandboxResponse,
    ListSandboxesRequest, ListSandboxesResponse, StartSandboxRequest, StartSandboxResponse,
    StopSandboxRequest, StopSandboxResponse, ValidateSandboxCreateRequest,
    ValidateSandboxCreateResponse, WatchSandboxesRequest,
};
use tonic::{Request, Response, Status};

#[cfg(test)]
mod tests {
    use super::*;
    use std::pin::Pin;
    use std::sync::atomic::{AtomicUsize, Ordering};
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
            (Self { state: Arc::clone(&state) }, state)
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
            _request: Request<AuthenticateSandboxRequest>,
        ) -> Result<Response<AuthenticateSandboxResponse>, Status> {
            self.record("authenticate_sandbox");
            Ok(Response::new(AuthenticateSandboxResponse::default()))
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
            _request: Request<GetSandboxRequest>,
        ) -> Result<Response<GetSandboxResponse>, Status> {
            self.record("get_sandbox");
            Ok(Response::new(GetSandboxResponse::default()))
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
            _request: Request<DeleteSandboxRequest>,
        ) -> Result<Response<DeleteSandboxResponse>, Status> {
            self.record("delete_sandbox");
            Ok(Response::new(DeleteSandboxResponse::default()))
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
    /// channel, and optionally fail after_ensure_workspace.
    struct RecordingHooks {
        created: mpsc::UnboundedSender<String>,
        ensure_calls: AtomicUsize,
        fail_ensure: bool,
    }

    impl RecordingHooks {
        fn new(fail_ensure: bool) -> (Arc<Self>, mpsc::UnboundedReceiver<String>) {
            let (created, rx) = mpsc::unbounded_channel();
            let hooks = Self { created, ensure_calls: AtomicUsize::new(0), fail_ensure };
            (Arc::new(hooks), rx)
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
        async fn after_ensure_workspace(&self, _workspace: &str) -> Result<(), Status> {
            self.ensure_calls.fetch_add(1, Ordering::SeqCst);
            if self.fail_ensure {
                return Err(Status::unavailable("could not label namespace"));
            }
            Ok(())
        }
    }

    fn sandbox(id: &str) -> DriverSandbox {
        DriverSandbox { id: id.to_string(), name: "sb".to_string(), ..Default::default() }
    }

    fn create_request(id: &str) -> Request<CreateSandboxRequest> {
        Request::new(CreateSandboxRequest { sandbox: Some(sandbox(id)) })
    }

    #[tokio::test]
    async fn every_rpc_is_forwarded_to_the_inner_service() {
        let (inner, state) = FakeInner::new(FakeState::default());
        let driver = KymaComputeDriver::new(inner, Arc::new(NoHooks));

        driver.authenticate_sandbox(Request::new(Default::default())).await.unwrap();
        driver.get_capabilities(Request::new(Default::default())).await.unwrap();
        driver.validate_sandbox_create(Request::new(Default::default())).await.unwrap();
        driver.get_sandbox(Request::new(Default::default())).await.unwrap();
        driver.list_sandboxes(Request::new(Default::default())).await.unwrap();
        driver.create_sandbox(create_request("sb-1")).await.unwrap();
        driver.stop_sandbox(Request::new(Default::default())).await.unwrap();
        driver.start_sandbox(Request::new(Default::default())).await.unwrap();
        driver.delete_sandbox(Request::new(Default::default())).await.unwrap();
        driver.watch_sandboxes(Request::new(Default::default())).await.unwrap();
        driver.ensure_workspace(Request::new(Default::default())).await.unwrap();
        driver.delete_workspace(Request::new(Default::default())).await.unwrap();

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
        assert_eq!(response.into_inner().runtime_identity, "kubernetes://ns/cr-uid/pod-uid");
    }

    #[tokio::test]
    async fn create_enriches_before_upstream_sees_the_request() {
        let (inner, state) = FakeInner::new(FakeState::default());
        let (hooks, _rx) = RecordingHooks::new(false);
        let driver = KymaComputeDriver::new(inner, hooks);

        driver.create_sandbox(create_request("sb-1")).await.unwrap();

        let seen = state.created.lock().unwrap().clone().expect("upstream saw a sandbox");
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
        let (inner, _state) = FakeInner::new(FakeState { fail_create: true, ..Default::default() });
        let (hooks, mut rx) = RecordingHooks::new(false);
        let driver = KymaComputeDriver::new(inner, hooks);

        let err = driver.create_sandbox(create_request("sb-1")).await.unwrap_err();
        assert_eq!(err.code(), tonic::Code::FailedPrecondition);
        assert!(
            tokio::time::timeout(Duration::from_millis(200), rx.recv()).await.is_err(),
            "after_create must not run when upstream rejected the create"
        );
    }

    #[tokio::test]
    async fn ensure_workspace_hook_failure_fails_the_rpc() {
        let (inner, state) = FakeInner::new(FakeState::default());
        let (hooks, _rx) = RecordingHooks::new(true);
        let driver = KymaComputeDriver::new(inner, hooks);

        let err = driver
            .ensure_workspace(Request::new(EnsureWorkspaceRequest { workspace: "ws".to_string() }))
            .await
            .unwrap_err();
        assert_eq!(err.code(), tonic::Code::Unavailable);
        assert_eq!(*state.calls.lock().unwrap(), vec!["ensure_workspace"]);
    }

    #[tokio::test]
    async fn ensure_workspace_hook_is_skipped_when_upstream_fails() {
        let (inner, _state) = FakeInner::new(FakeState { fail_ensure: true, ..Default::default() });
        let (hooks, _rx) = RecordingHooks::new(false);
        let hooks_probe = Arc::clone(&hooks);
        let driver = KymaComputeDriver::new(inner, hooks);

        let err = driver
            .ensure_workspace(Request::new(EnsureWorkspaceRequest { workspace: "ws".to_string() }))
            .await
            .unwrap_err();
        assert_eq!(err.code(), tonic::Code::Internal);
        assert_eq!(hooks_probe.ensure_calls.load(Ordering::SeqCst), 0);
    }
}
```

If `EnsureWorkspaceRequest` has fields beyond `workspace` in the vendored proto, add `..Default::default()` to the two literals.

- [ ] **Step 8: Run the tests to verify they fail**

Run: `make fmt && make test`
Expected: FAIL — `cannot find struct KymaComputeDriver`, `cannot find trait KymaHooks`, `cannot find struct NoHooks`.

- [ ] **Step 9: Implement the wrapper**

Insert between the `use` block and `#[cfg(test)]` in `src/service.rs`:

```rust
/// Kyma behaviour around upstream's RPCs.
#[tonic::async_trait]
pub trait KymaHooks: Send + Sync + 'static {
    /// Edits the sandbox before upstream sees it. Must not fail.
    fn enrich(&self, sandbox: &mut DriverSandbox);

    /// Runs after upstream created the sandbox, off the request path. It cannot
    /// fail the create; implementations report their own failures.
    async fn after_create(&self, sandbox: DriverSandbox);

    /// Runs after upstream ensured a workspace. An error fails the RPC so the
    /// gateway retries.
    async fn after_ensure_workspace(&self, workspace: &str) -> Result<(), Status>;
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
```

- [ ] **Step 10: Rewrite `src/main.rs`**

```rust
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
use openshell_core::VERSION;
use openshell_core::proto::compute::v1::compute_driver_server::ComputeDriverServer;
use openshell_driver_kubernetes::{ComputeDriverService, KubernetesComputeDriver};
use openshell_driver_kyma::kyma_args::KymaArgs;
use openshell_driver_kyma::service::{KymaComputeDriver, NoHooks};
use openshell_driver_kyma::upstream_args::{
    compute_config, parse_managed_ssh_gateway_pod_selector, UpstreamArgs,
};
use tracing::info;

#[derive(Parser, Debug)]
#[command(name = "openshell-driver-kyma", version)]
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
    let Cli { upstream, kyma: _kyma } = Cli::parse();

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
        Arc::new(NoHooks),
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
```

- [ ] **Step 11: Run the tests and build the binary**

Run: `make fmt && make test`
Expected: PASS — the 4 `upstream_args` tests and the 7 `service` tests, plus the untouched `openshell-bedrock-bridge` tests.

Run: `make build`
Expected: the release binary links. If it panics at startup with "no process-level CryptoProvider", do not add a provider here — report it; Task 4 handles startup.

If the build fails because `KubernetesComputeConfig` fields, `ComputeDriverService::new`, `openshell_otel::install_driver_tracing` or `openshell_core::external_driver_socket` differ from what this task shows, stop and report the compiler error verbatim — those names are copied from upstream `v0.1.2` and a mismatch means the dependency did not resolve to that tag.

- [ ] **Step 12: Commit**

```bash
git add -A crates/ Cargo.toml Cargo.lock Makefile
git commit -m "feat(driver)!: become a thin wrapper over upstream's Kubernetes driver

Upstream v0.1.2 re-architected the sandbox runtime, which our own
implementation cannot run. The driver now links upstream's
openshell-driver-kubernetes crate, mirrors its option surface verbatim, and
serves upstream's ComputeDriverService behind a KymaComputeDriver that
forwards every RPC. Kyma behaviour hangs off three hooks, no-ops for now.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Parity guard, and retire proto vendoring

With upstream's crates linked directly, vendored protos and hand-copied upstream source are obsolete. What replaces them is a guard that the mirrored option surface matches upstream at the pin, plus a pin report the weekly sync can read.

**Files:**
- Create: `scripts/check-upstream-args.sh`, `scripts/check-upstream-pin.sh`
- Modify: `scripts/proto-lib.sh`, `scripts/resolve-upstream-refs.sh`, `Makefile`, `.github/workflows/branch-checks.yml`, `.github/workflows/upstream-sync.yml` (the `detect` job's drift step only), comments in `scripts/check-image-pins.sh`, `scripts/check-pin-status.sh`, `scripts/check-inference-local.sh`
- Delete: `proto/`, `scripts/vendor-proto.sh`, `scripts/check-proto-drift.sh`, `scripts/check-vendor-drift.sh`

**Interfaces:**
- Consumes: `crates/openshell-driver-kyma/src/upstream_args.rs` (Task 1); the one-line `openshell-driver-kubernetes = { git = "…", tag = "…" }` in the root `Cargo.toml`.
- Produces: `pinned_upstream_tag` (bash function in `scripts/proto-lib.sh`); `scripts/check-upstream-args.sh [--print-env]` — exit 0 and `UPSTREAM_ARGS_MATCH:` on match, exit 1 and `UPSTREAM_ARGS_DRIFT:` plus a unified diff on drift, exit 2 on fetch/parse errors, and with `--print-env` one upstream env-var name per line (42 at v0.1.2); `scripts/check-upstream-pin.sh` printing `PINNED_UPSTREAM_TAG:`, `LATEST_UPSTREAM_TAG:`, `VENDOR_TARGET_TAG:`, and `ADVISORY:` only when behind; `SANDBOX_RUNTIME_IMAGE=` from `resolve-upstream-refs.sh`; Makefile targets `upstream-args-check` and `upstream-bump TAG=…`.

- [ ] **Step 1: Add the pin reader to `scripts/proto-lib.sh`**

Append:

```bash
# The upstream NVIDIA/OpenShell tag the workspace links, read from the one-line
# `openshell-driver-kubernetes = { git = "...", tag = "..." }` in Cargo.toml.
pinned_upstream_tag() {
	local root
	root=$(git rev-parse --show-toplevel)
	sed -nE 's/^openshell-driver-kubernetes = \{ git = "[^"]+", tag = "([^"]+)" \}.*/\1/p' \
		"${root}/Cargo.toml" | head -1 | grep .
}
```

- [ ] **Step 2: Create `scripts/check-upstream-args.sh`**

This script was validated while writing this plan against upstream v0.1.2 and a copy of Task 1's `upstream_args.rs`: exit 0 on the verbatim copy, exit 1 when one doc comment or one config line is changed. Create it with exactly this content and `chmod 755`:

```bash
#!/usr/bin/env bash
# Fail when the driver's mirrored upstream option surface drifts from upstream
# NVIDIA/OpenShell's openshell-driver-kubernetes at the pinned tag.
#
# Compares two regions of crates/openshell-driver-kyma/src/upstream_args.rs
# against upstream's crates/openshell-driver-kubernetes/src/main.rs:
#   A. the body of `pub struct UpstreamArgs { ... }` against the body of
#      upstream's `struct Args { ... }` (our fields carry `pub `; stripped);
#   B. the `KubernetesComputeConfig { ... }` literal in compute_config()
#      against the one upstream's main() builds (leading whitespace ignored).
#
# Usage:
#   scripts/check-upstream-args.sh              check (exit 0 match, 1 drift)
#   scripts/check-upstream-args.sh --print-env  list every upstream env var
# UPSTREAM_TAG overrides the tag read from the workspace Cargo.toml.
# UPSTREAM_MAIN_RS points at a local upstream main.rs instead of fetching.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

ROOT=$(git rev-parse --show-toplevel)
OURS=${OURS_ARGS_RS:-$ROOT/crates/openshell-driver-kyma/src/upstream_args.rs}
TAG=${UPSTREAM_TAG:-$(pinned_upstream_tag)} || die "could not read the pinned upstream tag from Cargo.toml"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if [[ -n ${UPSTREAM_MAIN_RS:-} ]]; then
	cp "$UPSTREAM_MAIN_RS" "$WORK/upstream.rs"
else
	url="https://raw.githubusercontent.com/NVIDIA/OpenShell/${TAG}/crates/openshell-driver-kubernetes/src/main.rs"
	curl -fsSL "$url" -o "$WORK/upstream.rs" || { echo "could not fetch $url" >&2; exit 2; }
fi

MODE=${1:-check}
python3 - "$WORK/upstream.rs" "$OURS" "$MODE" "$TAG" <<'PY'
import difflib, re, sys

upstream_path, ours_path, mode, tag = sys.argv[1:5]
upstream = open(upstream_path).read().splitlines()

def body(lines, start_re, what, where):
    for i, line in enumerate(lines):
        if re.search(start_re, line):
            depth, out = 0, []
            for j in range(i, len(lines)):
                depth += lines[j].count("{") - lines[j].count("}")
                if j > i:
                    if depth <= 0:
                        return out
                    out.append(lines[j])
    sys.exit(f"could not find {what} in {where}")

if mode == "--print-env":
    text = "\n".join(upstream)
    names = re.findall(r'env\s*=\s*"([A-Z0-9_]+)"', text)
    names += re.findall(r'std::env::var\(\s*"([A-Z0-9_]+)"', text)
    print("\n".join(dict.fromkeys(names)))
    sys.exit(0)

ours = open(ours_path).read().splitlines()
up_args = body(upstream, r"^struct Args \{", "struct Args", f"upstream {tag}")
our_args = [re.sub(r"^(\s*)pub ", r"\1", l)
            for l in body(ours, r"^pub struct UpstreamArgs \{", "pub struct UpstreamArgs", ours_path)]
up_lit = [l.strip() for l in body(upstream, r"^\s*KubernetesComputeConfig \{\s*$", "config literal", f"upstream {tag}")]
our_lit = [l.strip() for l in body(ours, r"^\s*KubernetesComputeConfig \{\s*$", "config literal", ours_path)]

drift = False
for name, a, b in (("option struct", up_args, our_args), ("config literal", up_lit, our_lit)):
    if a != b:
        drift = True
        print(f"UPSTREAM_ARGS_DRIFT: {name} differs from upstream {tag}")
        sys.stdout.writelines(l + "\n" for l in difflib.unified_diff(
            b, a, f"ours ({name})", f"upstream {tag} ({name})", lineterm=""))
if drift:
    print("Mirror the upstream side of the diff above into "
          "crates/openshell-driver-kyma/src/upstream_args.rs.")
    sys.exit(1)
print(f"UPSTREAM_ARGS_MATCH: {len(up_args)} option lines and {len(up_lit)} config lines match upstream {tag}")
PY
```

- [ ] **Step 3: Prove the guard passes, and fails on drift**

Run: `./scripts/check-upstream-args.sh`
Expected: `UPSTREAM_ARGS_MATCH: 163 option lines and 55 config lines match upstream v0.1.2`, exit 0.

Change the doc comment `/// Public compute-driver Unix socket used by an external gateway.` in `upstream_args.rs` to `/// Public socket.`, run the script again, and confirm it prints `UPSTREAM_ARGS_DRIFT: option struct differs from upstream v0.1.2` and exits 1. Revert the edit, re-run, confirm exit 0.

Run: `./scripts/check-upstream-args.sh --print-env | wc -l`
Expected: `42`.

- [ ] **Step 4: Create `scripts/check-upstream-pin.sh`** (`chmod 755`)

```bash
#!/usr/bin/env bash
# Report where the driver's upstream pin stands, for CI and the weekly sync.
#
# The driver links upstream NVIDIA/OpenShell's Kubernetes driver at the tag
# pinned in the workspace Cargo.toml. Prints:
#   PINNED_UPSTREAM_TAG: <tag>   the tag Cargo.toml pins
#   LATEST_UPSTREAM_TAG: <tag>   the newest upstream release tag
#   VENDOR_TARGET_TAG: <tag>     the tag a sync should move to
#   ADVISORY: ...                only when the pin is behind the latest release
# then runs check-upstream-args.sh at the PINNED tag. Being behind is advisory
# (exit 0); a mirrored option surface that no longer matches the pinned tag is
# corruption and exits 1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

pinned=$(pinned_upstream_tag) || die "could not read the pinned upstream tag from Cargo.toml"
latest=$(latest_upstream_tag) || true
[[ -n $latest ]] || die "could not reach upstream to resolve its latest release tag"

echo "PINNED_UPSTREAM_TAG: ${pinned}"
echo "LATEST_UPSTREAM_TAG: ${latest}"
echo "VENDOR_TARGET_TAG: ${latest}"
if [[ $(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -1) != "$pinned" ]]; then
	echo "ADVISORY: pinned upstream ${pinned} is behind the latest release ${latest}"
fi

"${SCRIPT_DIR}/check-upstream-args.sh"
```

Run: `./scripts/check-upstream-pin.sh`
Expected: the three tag lines, no `ADVISORY:` while the pin equals the latest release, then `UPSTREAM_ARGS_MATCH: …`, exit 0.

- [ ] **Step 5: Repoint `scripts/resolve-upstream-refs.sh` and add the runtime image**

Replace

```bash
pinned_proto_ref=$(lock_get ref) || die "failed to read the pinned proto ref from UPSTREAM.lock"
```

with

```bash
# Kept as PINNED_PROTO_REF for the workflows that read it; it is now the
# upstream tag the driver links (Cargo.toml), since protos are no longer vendored.
pinned_proto_ref=$(pinned_upstream_tag) || die "failed to read the pinned upstream tag from Cargo.toml"
```

After the supervisor digest block add:

```bash
sandbox_runtime_image=$(resolve_image_digest ghcr.io/nvidia/openshell/sandbox "$image_tag") \
	|| die "failed to resolve the sandbox runtime image digest for ${image_tag}"
[[ -n $sandbox_runtime_image ]] || die "sandbox runtime image digest resolved empty for ${image_tag}"
```

and after `printf 'SUPERVISOR_IMAGE=%s\n' "$supervisor_image"` add `printf 'SANDBOX_RUNTIME_IMAGE=%s\n' "$sandbox_runtime_image"`.

Run: `./scripts/resolve-upstream-refs.sh`
Expected: includes `SANDBOX_RUNTIME_IMAGE=ghcr.io/nvidia/openshell/sandbox@sha256:bf4797b6c511f2d8ba02955dbba4bf76c1f0dd6d83531420c5408d5f1fb9d72f` while `GATEWAY_REF=latest` resolves to v0.1.2.

- [ ] **Step 6: Delete the proto tooling and prune `proto-lib.sh`**

```bash
git rm -r -q proto scripts/vendor-proto.sh scripts/check-proto-drift.sh scripts/check-vendor-drift.sh
```

In `scripts/proto-lib.sh`, delete every function that no longer has a caller: for each function defined in the file, run `grep -rn '<name>' scripts .github Makefile` and delete it when the only hit is its own definition. `lock_get` and `SPDX_LINES` must go; `die`, `latest_upstream_tag`, `resolve_image_digest` and `pinned_upstream_tag` must stay. Rewrite the header comment to: `# Shared helpers for the upstream pin and image-resolution scripts.`

In `scripts/check-image-pins.sh`, `scripts/check-pin-status.sh` and `scripts/check-inference-local.sh`, change each comment that names `check-proto-drift.sh` to name `check-upstream-pin.sh` instead. Comment-only edits.

- [ ] **Step 7: Replace the Makefile targets**

Delete the `proto`, `proto-check`, `proto-vendor` targets and the target whose recipe runs `./scripts/check-vendor-drift.sh`, with their comments. Add:

```make
# The mirrored upstream option surface must match upstream at the pinned tag.
# Runs on the host (needs network), not in the container.
.PHONY: upstream-args-check
upstream-args-check:
	./scripts/check-upstream-args.sh

# Move the driver to a new upstream release: make upstream-bump TAG=v0.1.3
# Rewrites the tag on the three openshell-* git dependencies, refreshes
# Cargo.lock, then prints any option-surface diff to mirror into
# crates/openshell-driver-kyma/src/upstream_args.rs.
.PHONY: upstream-bump
upstream-bump:
	@test -n "$(TAG)" || { echo "usage: make upstream-bump TAG=vX.Y.Z" >&2; exit 2; }
	sed -i.bak -E 's#^(openshell-[a-z-]+ = \{ git = "https://github.com/NVIDIA/OpenShell", tag = ")[^"]+(")#\1$(TAG)\2#' Cargo.toml
	rm -f Cargo.toml.bak
	$(DOCKER_RUN) $(DEV_IMAGE) cargo update -p openshell-driver-kubernetes
	./scripts/check-upstream-args.sh
```

Also remove `proto-check`/`proto-vendor`/vendor-drift entries from the `help` target's text if it lists them.

- [ ] **Step 8: Replace the CI drift job**

In `.github/workflows/branch-checks.yml`, replace the whole `proto-drift:` job (named `vendored protos match upstream`, with its "Check proto drift" and "Check vendored driver source drift" steps) with:

```yaml
  upstream-parity:
    name: driver options match upstream
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v7
      - name: Check the mirrored upstream option surface
        shell: bash
        run: ./scripts/check-upstream-args.sh
```

Match the checkout action version and any `timeout-minutes`/`permissions` keys the neighbouring jobs use.

In `.github/workflows/upstream-sync.yml`, in the `detect` job's `Check proto drift` step, change the step name to `Check upstream pin` and the command `./scripts/check-proto-drift.sh | tee /tmp/drift.txt` to `./scripts/check-upstream-pin.sh | tee /tmp/drift.txt`. Leave the rest of that step unchanged — it parses `ADVISORY:` and `VENDOR_TARGET_TAG:`, which the new script prints in the same format. The sync *PR* job is Task 10.

- [ ] **Step 9: Verify nothing still references the deleted tooling**

Run: `grep -rnE 'lock_get|proto/UPSTREAM\.lock|vendor-proto|check-proto-drift|check-vendor-drift|proto-check|proto-vendor' scripts .github Makefile crates`
Expected: hits only inside `.github/workflows/upstream-sync.yml`'s sync job (Task 10 rewrites them). Any other hit must be fixed now.

Run: `make fmt && make test`
Expected: PASS (nothing in Rust changed).

- [ ] **Step 10: Commit**

```bash
git add -A scripts proto Makefile .github
git commit -m "ci: guard the mirrored upstream options; retire proto vendoring

The driver links upstream's crates, so vendored protos and hand-copied
source are obsolete. check-upstream-args.sh proves our option surface and
config literal match upstream at the pinned tag; check-upstream-pin.sh
tells the weekly sync when upstream has moved on.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Kyma options and request enrichment

**Files:**
- Modify: `crates/openshell-driver-kyma/src/kyma_args.rs`, `src/lib.rs`, `src/main.rs`
- Create: `crates/openshell-driver-kyma/src/enrich.rs`, `src/hooks.rs`

**Interfaces:**
- Consumes: `service::{KymaHooks, KymaComputeDriver}` (Task 1).
- Produces: `enrich::{EnrichConfig { istio_inject: bool, environment: Vec<(String, String)> }, enrich(sandbox: &mut DriverSandbox, config: &EnrichConfig), ISTIO_INJECT_LABEL, KAGENTI_TYPE_LABEL, KAGENTI_TYPE_VALUE, CLAUDE_TELEMETRY_ENV}`; `kyma_args::KymaArgs` with fields `kyma_istio_inject_sandboxes: bool`, `kyma_disable_claude_telemetry: bool`, `kyma_sandbox_env: Vec<String>`, `kyma_enable_apirule: bool`, `kyma_cluster_domain: String`, `kyma_ingress_namespace: String`, `kyma_workspace_psa_level: String`, `kyma_health_port: u16`, plus `fn validate(&self) -> Result<(), String>` and `fn enrich_config(&self) -> EnrichConfig`; `hooks::KymaHookSet::new(enrich: EnrichConfig) -> Self` implementing `KymaHooks` (Tasks 5–6 extend its constructor).

- [ ] **Step 1: Write the failing enrichment tests**

Create `src/enrich.rs` with the header, constants and tests only:

```rust
// SPDX-License-Identifier: Apache-2.0

//! Hook 1: Kyma pod-level settings added to a sandbox before upstream sees it.
//!
//! Upstream copies `template.labels` onto the workload and merges
//! `template.environment` into its environment (`build_sandbox_env`), so
//! editing the request is enough — no pod patching, no webhook. Keys the caller
//! already set are never overwritten.

use openshell_core::proto::compute::v1::DriverSandbox;

/// Istio must not inject a sidecar into sandbox workloads: upstream's workload
/// fence gives them no egress, and the sidecar would sit outside the boundary.
pub const ISTIO_INJECT_LABEL: &str = "sidecar.istio.io/inject";
pub const KAGENTI_TYPE_LABEL: &str = "kagenti.io/type";
pub const KAGENTI_TYPE_VALUE: &str = "agent";
pub const CLAUDE_TELEMETRY_ENV: &str = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC";

#[cfg(test)]
mod tests {
    use super::*;
    use openshell_core::proto::compute::v1::{DriverSandboxSpec, DriverSandboxTemplate};

    fn config() -> EnrichConfig {
        EnrichConfig {
            istio_inject: false,
            environment: vec![("ANTHROPIC_BASE_URL".to_string(), "http://proxy:8080".to_string())],
        }
    }

    #[test]
    fn adds_labels_and_environment_to_a_bare_sandbox() {
        let mut sandbox = DriverSandbox { id: "sb-1".to_string(), ..Default::default() };
        enrich(&mut sandbox, &config());
        let template = sandbox.spec.unwrap().template.unwrap();
        assert_eq!(template.labels[ISTIO_INJECT_LABEL], "false");
        assert_eq!(template.labels[KAGENTI_TYPE_LABEL], KAGENTI_TYPE_VALUE);
        assert_eq!(template.environment["ANTHROPIC_BASE_URL"], "http://proxy:8080");
    }

    #[test]
    fn istio_injection_can_be_requested() {
        let mut sandbox = DriverSandbox::default();
        enrich(&mut sandbox, &EnrichConfig { istio_inject: true, environment: vec![] });
        let template = sandbox.spec.unwrap().template.unwrap();
        assert_eq!(template.labels[ISTIO_INJECT_LABEL], "true");
    }

    // Review Focus 1.
    #[test]
    fn caller_values_win_over_enrichment() {
        let mut template = DriverSandboxTemplate::default();
        template.labels.insert(ISTIO_INJECT_LABEL.to_string(), "true".to_string());
        template.environment.insert("ANTHROPIC_BASE_URL".to_string(), "http://mine".to_string());
        let mut sandbox = DriverSandbox {
            spec: Some(DriverSandboxSpec { template: Some(template), ..Default::default() }),
            ..Default::default()
        };
        enrich(&mut sandbox, &config());
        let template = sandbox.spec.unwrap().template.unwrap();
        assert_eq!(template.labels[ISTIO_INJECT_LABEL], "true");
        assert_eq!(template.environment["ANTHROPIC_BASE_URL"], "http://mine");
    }

    #[test]
    fn keeps_existing_spec_fields() {
        let mut sandbox = DriverSandbox {
            spec: Some(DriverSandboxSpec { log_level: "debug".to_string(), ..Default::default() }),
            ..Default::default()
        };
        enrich(&mut sandbox, &config());
        assert_eq!(sandbox.spec.unwrap().log_level, "debug");
    }
}
```

Add `pub mod enrich;` to `lib.rs`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make fmt && make test`
Expected: FAIL — `cannot find struct EnrichConfig`, `cannot find function enrich`.

- [ ] **Step 3: Implement enrichment**

Add above `#[cfg(test)]` in `src/enrich.rs`:

```rust
/// What hook 1 adds to every sandbox.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct EnrichConfig {
    /// Value of the `sidecar.istio.io/inject` label.
    pub istio_inject: bool,
    /// Environment added to the sandbox template.
    pub environment: Vec<(String, String)>,
}

/// Add Kyma labels and environment to `sandbox`, never overwriting a key the
/// caller set.
pub fn enrich(sandbox: &mut DriverSandbox, config: &EnrichConfig) {
    let template = sandbox
        .spec
        .get_or_insert_with(Default::default)
        .template
        .get_or_insert_with(Default::default);
    template
        .labels
        .entry(ISTIO_INJECT_LABEL.to_string())
        .or_insert_with(|| config.istio_inject.to_string());
    template
        .labels
        .entry(KAGENTI_TYPE_LABEL.to_string())
        .or_insert_with(|| KAGENTI_TYPE_VALUE.to_string());
    for (key, value) in &config.environment {
        template.environment.entry(key.clone()).or_insert_with(|| value.clone());
    }
}
```

Run: `make fmt && make test`
Expected: the 4 enrichment tests PASS.

- [ ] **Step 4: Write the failing option tests**

Replace `src/kyma_args.rs` with the header plus these tests (the struct comes in Step 6):

```rust
// SPDX-License-Identifier: Apache-2.0

//! Kyma-layer options. Every flag starts with `--kyma-` and every environment
//! variable with `OPENSHELL_KYMA_`, so they can never collide with upstream's.

use crate::enrich::{EnrichConfig, CLAUDE_TELEMETRY_ENV};

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[derive(Parser)]
    struct Probe {
        #[command(flatten)]
        kyma: KymaArgs,
    }

    fn parse(argv: &[&str]) -> KymaArgs {
        let mut full = vec!["openshell-driver-kyma"];
        full.extend_from_slice(argv);
        Probe::try_parse_from(full).expect("arguments should parse").kyma
    }

    #[test]
    fn defaults() {
        let args = parse(&[]);
        assert!(!args.kyma_istio_inject_sandboxes);
        assert!(!args.kyma_enable_apirule);
        assert_eq!(args.kyma_ingress_namespace, "istio-system");
        assert_eq!(args.kyma_workspace_psa_level, "");
        assert_eq!(args.kyma_health_port, 9090);
        assert!(args.validate().is_ok());
    }

    #[test]
    fn telemetry_flag_and_sandbox_env_become_enrichment_environment() {
        let args = parse(&[
            "--kyma-disable-claude-telemetry",
            "--kyma-sandbox-env",
            "ANTHROPIC_BASE_URL=http://proxy:8080/anthropic",
            "--kyma-sandbox-env",
            "ANTHROPIC_MODEL=claude-opus-4-7",
        ]);
        let config = args.enrich_config();
        assert!(config.environment.contains(&(
            "ANTHROPIC_BASE_URL".to_string(),
            "http://proxy:8080/anthropic".to_string()
        )));
        assert!(config.environment.contains(&("ANTHROPIC_MODEL".to_string(), "claude-opus-4-7".to_string())));
        assert!(config.environment.contains(&(CLAUDE_TELEMETRY_ENV.to_string(), "1".to_string())));
    }

    #[test]
    fn sandbox_env_value_may_contain_equals_signs() {
        let args = parse(&["--kyma-sandbox-env", "OPTS=a=b"]);
        assert!(args.validate().is_ok());
        assert_eq!(args.enrich_config().environment, vec![("OPTS".to_string(), "a=b".to_string())]);
    }

    // Review Focus 2.
    #[test]
    fn malformed_sandbox_env_is_rejected_by_name() {
        for bad in ["NO_EQUALS", "=value"] {
            let err = parse(&["--kyma-sandbox-env", bad]).validate().unwrap_err();
            assert!(err.contains(bad), "error must name the entry: {err}");
        }
    }

    #[test]
    fn apirule_requires_a_cluster_domain() {
        let err = parse(&["--kyma-enable-apirule"]).validate().unwrap_err();
        assert!(err.contains("--kyma-cluster-domain"), "{err}");
        assert!(parse(&["--kyma-enable-apirule", "--kyma-cluster-domain", "example.org"])
            .validate()
            .is_ok());
    }

    #[test]
    fn psa_level_must_be_a_pod_security_level() {
        for ok in ["", "privileged", "baseline", "restricted"] {
            assert!(parse(&["--kyma-workspace-psa-level", ok]).validate().is_ok(), "{ok}");
        }
        let err = parse(&["--kyma-workspace-psa-level", "strict"]).validate().unwrap_err();
        assert!(err.contains("strict"), "{err}");
    }
}
```

- [ ] **Step 5: Run the tests to verify they fail**

Run: `make fmt && make test`
Expected: FAIL — `KymaArgs` has no field `kyma_istio_inject_sandboxes`, no method `validate`/`enrich_config`.

- [ ] **Step 6: Implement `KymaArgs`**

Insert between the `use` line and `#[cfg(test)]`:

```rust
/// Kyma options, flattened next to [`crate::upstream_args::UpstreamArgs`].
#[derive(clap::Args, Debug, Clone, Default)]
pub struct KymaArgs {
    /// Let Istio inject a sidecar into sandbox workloads (label value "true").
    #[arg(long, env = "OPENSHELL_KYMA_ISTIO_INJECT_SANDBOXES")]
    pub kyma_istio_inject_sandboxes: bool,

    /// Add CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 to every sandbox.
    #[arg(long, env = "OPENSHELL_KYMA_DISABLE_CLAUDE_TELEMETRY")]
    pub kyma_disable_claude_telemetry: bool,

    /// KEY=VALUE added to every sandbox's environment. Repeatable; the
    /// environment variable takes a comma-separated list.
    #[arg(long, env = "OPENSHELL_KYMA_SANDBOX_ENV", value_delimiter = ',')]
    pub kyma_sandbox_env: Vec<String>,

    /// Expose each sandbox's port 8080 through a Kyma APIRule.
    #[arg(long, env = "OPENSHELL_KYMA_ENABLE_APIRULE")]
    pub kyma_enable_apirule: bool,

    /// Domain for APIRule hosts (`<sandbox>.<domain>`). Required with
    /// --kyma-enable-apirule.
    #[arg(long, env = "OPENSHELL_KYMA_CLUSTER_DOMAIN", default_value = "")]
    pub kyma_cluster_domain: String,

    /// Namespace of the Istio ingress gateway that APIRule traffic arrives from.
    #[arg(long, env = "OPENSHELL_KYMA_INGRESS_NAMESPACE", default_value = "istio-system")]
    pub kyma_ingress_namespace: String,

    /// Pod Security level applied to namespaces the driver creates in Managed
    /// mode. Empty leaves them unlabelled.
    #[arg(long, env = "OPENSHELL_KYMA_WORKSPACE_PSA_LEVEL", default_value = "")]
    pub kyma_workspace_psa_level: String,

    /// Port for /healthz and /readyz.
    #[arg(long, env = "OPENSHELL_KYMA_HEALTH_PORT", default_value_t = 9090)]
    pub kyma_health_port: u16,
}

impl KymaArgs {
    /// Reject combinations that would misbehave at runtime, naming the culprit.
    pub fn validate(&self) -> Result<(), String> {
        for entry in &self.kyma_sandbox_env {
            match entry.split_once('=') {
                Some((key, _)) if !key.is_empty() => {}
                _ => {
                    return Err(format!(
                        "--kyma-sandbox-env entry `{entry}` must be KEY=VALUE with a non-empty KEY"
                    ))
                }
            }
        }
        if self.kyma_enable_apirule && self.kyma_cluster_domain.is_empty() {
            return Err("--kyma-cluster-domain is required when --kyma-enable-apirule is set".into());
        }
        if !matches!(
            self.kyma_workspace_psa_level.as_str(),
            "" | "privileged" | "baseline" | "restricted"
        ) {
            return Err(format!(
                "--kyma-workspace-psa-level `{}` is not a Pod Security level \
                 (privileged, baseline, restricted, or empty)",
                self.kyma_workspace_psa_level
            ));
        }
        Ok(())
    }

    /// Hook 1's configuration. Call only after [`KymaArgs::validate`] succeeded.
    pub fn enrich_config(&self) -> EnrichConfig {
        let mut environment: Vec<(String, String)> = self
            .kyma_sandbox_env
            .iter()
            .filter_map(|entry| entry.split_once('='))
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect();
        if self.kyma_disable_claude_telemetry {
            environment.push((CLAUDE_TELEMETRY_ENV.to_string(), "1".to_string()));
        }
        EnrichConfig { istio_inject: self.kyma_istio_inject_sandboxes, environment }
    }
}
```

Run: `make fmt && make test`
Expected: the 6 option tests PASS.

- [ ] **Step 7: Add the production hook set and wire it**

Create `src/hooks.rs`:

```rust
// SPDX-License-Identifier: Apache-2.0

//! The production [`KymaHooks`]: request enrichment now; exposure and
//! namespace labelling join in later tasks.

use openshell_core::proto::compute::v1::DriverSandbox;
use tonic::Status;

use crate::enrich::{enrich, EnrichConfig};
use crate::service::KymaHooks;

pub struct KymaHookSet {
    enrich: EnrichConfig,
}

impl KymaHookSet {
    pub fn new(enrich: EnrichConfig) -> Self {
        Self { enrich }
    }
}

#[tonic::async_trait]
impl KymaHooks for KymaHookSet {
    fn enrich(&self, sandbox: &mut DriverSandbox) {
        enrich(sandbox, &self.enrich);
    }

    async fn after_create(&self, _sandbox: DriverSandbox) {}

    async fn after_ensure_workspace(&self, _workspace: &str) -> Result<(), Status> {
        Ok(())
    }
}
```

Add `pub mod hooks;` to `lib.rs`. In `main.rs`: change the destructuring to `let Cli { upstream, kyma } = Cli::parse();`, add directly after it

```rust
    kyma.validate().map_err(|err| miette::miette!("{err}"))?;
```

replace `Arc::new(NoHooks)` with `Arc::new(KymaHookSet::new(kyma.enrich_config()))`, and change the import to `use openshell_driver_kyma::hooks::KymaHookSet;` (drop `NoHooks` from the `service` import).

- [ ] **Step 8: Run all tests and build**

Run: `make fmt && make test && make build`
Expected: PASS; the binary builds.

- [ ] **Step 9: Commit**

```bash
git add -A crates/openshell-driver-kyma
git commit -m "feat(driver): Kyma options and request enrichment

Adds the --kyma-* option set and hook 1: Istio opt-out and kagenti labels
plus configured environment added to each sandbox template before upstream
sees it, never overriding keys the caller set.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Health endpoints

**Files:**
- Create: `crates/openshell-driver-kyma/src/health.rs`
- Modify: `src/lib.rs`, `src/main.rs`, `crates/openshell-driver-kyma/Cargo.toml`

**Interfaces:**
- Consumes: `KymaArgs::kyma_health_port` (Task 3).
- Produces: `health::{router(ready: Arc<AtomicBool>) -> axum::Router, serve(port: u16, ready: Arc<AtomicBool>, shutdown: impl Future<Output = ()> + Send + 'static) -> std::io::Result<()>}`.

- [ ] **Step 1: Add dependencies**

In `crates/openshell-driver-kyma/Cargo.toml` add `axum = { workspace = true }` to `[dependencies]` and `tower = { workspace = true, features = ["util"] }` to `[dev-dependencies]`.

- [ ] **Step 2: Write the failing tests**

Create `src/health.rs`:

```rust
// SPDX-License-Identifier: Apache-2.0

//! `/healthz` and `/readyz` for the chart's probes. Upstream's driver exposes
//! only its gRPC endpoint, so this port is Kyma-owned. `/readyz` turns ready
//! once the compute-driver socket is bound.

use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::get;
use axum::Router;

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;

    async fn status(router: Router, path: &str) -> StatusCode {
        router
            .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
            .await
            .unwrap()
            .status()
    }

    #[tokio::test]
    async fn healthz_is_always_ok() {
        let ready = Arc::new(AtomicBool::new(false));
        assert_eq!(status(router(ready), "/healthz").await, StatusCode::OK);
    }

    #[tokio::test]
    async fn readyz_follows_the_ready_flag() {
        let ready = Arc::new(AtomicBool::new(false));
        assert_eq!(status(router(Arc::clone(&ready)), "/readyz").await, StatusCode::SERVICE_UNAVAILABLE);
        ready.store(true, Ordering::Release);
        assert_eq!(status(router(ready), "/readyz").await, StatusCode::OK);
    }
}
```

Add `pub mod health;` to `lib.rs`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make fmt && make test`
Expected: FAIL — `cannot find function router`.

- [ ] **Step 4: Implement**

Insert above `#[cfg(test)]`:

```rust
pub fn router(ready: Arc<AtomicBool>) -> Router {
    Router::new()
        .route("/healthz", get(|| async { (StatusCode::OK, "ok") }))
        .route("/readyz", get(readyz))
        .with_state(ready)
}

async fn readyz(State(ready): State<Arc<AtomicBool>>) -> (StatusCode, &'static str) {
    if ready.load(Ordering::Acquire) {
        (StatusCode::OK, "ready")
    } else {
        (StatusCode::SERVICE_UNAVAILABLE, "not ready")
    }
}

/// Serve the health endpoints on `0.0.0.0:<port>` until `shutdown` resolves.
pub async fn serve(
    port: u16,
    ready: Arc<AtomicBool>,
    shutdown: impl Future<Output = ()> + Send + 'static,
) -> std::io::Result<()> {
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    axum::serve(listener, router(ready))
        .with_graceful_shutdown(shutdown)
        .await
}
```

- [ ] **Step 5: Wire it into `main.rs`**

After the `shutdown_tx`/`shutdown_rx` line add:

```rust
    let ready = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mut health_shutdown = shutdown_tx.subscribe();
    let health = tokio::spawn(openshell_driver_kyma::health::serve(
        kyma.kyma_health_port,
        Arc::clone(&ready),
        async move {
            let _ = health_shutdown.wait_for(|stopping| *stopping).await;
        },
    ));
```

In the Unix-socket branch, immediately after `let _cleanup = …;` add `ready.store(true, std::sync::atomic::Ordering::Release);`. In the TCP branch, add the same line before `tonic::transport::Server::builder()`. After the `if/else` completes, the result must still be returned; restructure the tail as:

```rust
    let served = if let Some(socket_path) = bind_socket {
        /* unchanged Unix-socket branch, with the ready.store line */
    } else {
        /* unchanged TCP branch, with the ready.store line */
    };
    health.abort();
    served
```

- [ ] **Step 6: Run all tests and build**

Run: `make fmt && make test && make build`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A crates/openshell-driver-kyma
git commit -m "feat(driver): /healthz and /readyz on the Kyma health port

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: APIRule exposure (hook 2)

**Files:**
- Create: `crates/openshell-driver-kyma/src/exposure.rs`, `src/test_support.rs`
- Modify: `src/lib.rs`, `src/hooks.rs`, `src/main.rs`, `crates/openshell-driver-kyma/Cargo.toml`

**Interfaces:**
- Consumes: `KymaArgs::{kyma_enable_apirule, kyma_cluster_domain, kyma_ingress_namespace}` (Task 3); `KubernetesComputeConfig::{is_multi_namespace(), namespace}` (upstream).
- Produces: `exposure::{SandboxOwner { namespace, name, uid }, ExposureConfig { cluster_domain: String, ingress_namespace: String, search_namespace: Option<String> }, ExposureError, ExposureReconciler::new(client: kube::Client, config: ExposureConfig), ExposureReconciler::reconcile(&self, sandbox_id: &str) -> Result<(), ExposureError>, service_manifest, ingress_policy_manifest, apirule_manifest, service_name, policy_name}`; `test_support::{mock_client, Recorded}` (test-only, reused by Task 6); `KymaHookSet::new(enrich: EnrichConfig, exposure: Option<ExposureReconciler>)`.

- [ ] **Step 1: Add dependencies**

In `crates/openshell-driver-kyma/Cargo.toml` add to `[dependencies]`: `kube = { workspace = true }`, `serde_json = { workspace = true }`, `thiserror = { workspace = true }`; to `[dev-dependencies]`: `http = { workspace = true }`, `http-body-util = { workspace = true }`.

- [ ] **Step 2: Create the fake Kubernetes API for tests**

Create `src/test_support.rs`:

```rust
// SPDX-License-Identifier: Apache-2.0

//! Test-only fake Kubernetes API: records every request (method, path, body)
//! and answers with whatever the test's `respond` closure returns.

use std::sync::{Arc, Mutex};

use http_body_util::BodyExt;

#[derive(Debug, Clone)]
pub struct Recorded {
    /// `"<METHOD> <path>"`, e.g. `"PATCH /api/v1/namespaces/ns/services/x"`.
    pub line: String,
    pub body: String,
}

pub fn mock_client<F>(respond: F) -> (kube::Client, Arc<Mutex<Vec<Recorded>>>)
where
    F: Fn(&str) -> (u16, String) + Send + Sync + 'static,
{
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    let respond = Arc::new(respond);
    let service = tower::service_fn(move |request: http::Request<kube::client::Body>| {
        let log = Arc::clone(&log);
        let respond = Arc::clone(&respond);
        async move {
            let line = format!("{} {}", request.method(), request.uri().path());
            let bytes = request
                .into_body()
                .collect()
                .await
                .map(|collected| collected.to_bytes())
                .unwrap_or_default();
            log.lock().unwrap().push(Recorded {
                line: line.clone(),
                body: String::from_utf8_lossy(&bytes).into_owned(),
            });
            let (status, body) = respond(&line);
            Ok::<_, std::convert::Infallible>(
                http::Response::builder()
                    .status(status)
                    .body(kube::client::Body::from(body.into_bytes()))
                    .unwrap(),
            )
        }
    });
    (kube::Client::new(service, "default"), seen)
}
```

If `kube::client::Body` has no `From<Vec<u8>>` in kube 0.99, add `bytes = "1"` to `[dev-dependencies]` and use `kube::client::Body::from(bytes::Bytes::from(body))`.

Add to `lib.rs`:

```rust
pub mod exposure;
#[cfg(test)]
pub(crate) mod test_support;
```

- [ ] **Step 3: Write the failing exposure tests**

Create `src/exposure.rs` with the header, constants and tests:

```rust
// SPDX-License-Identifier: Apache-2.0

//! Hook 2: expose a sandbox's port 8080 through a Kyma APIRule.
//!
//! Upstream fences sandbox workloads (`openshell-sandbox-workloads`): they
//! accept ingress only from supervisor pods on the boundary port and have no
//! egress. Direct HTTPS exposure is therefore an explicit, opt-in exception to
//! upstream's isolation — a Service selecting the workload by upstream's
//! boundary labels, a NetworkPolicy admitting only the Istio ingress gateway on
//! 8080, and the APIRule. All three are owner-referenced to the Sandbox CR, so
//! Kubernetes deletes them with it, and labelled as ours so they never look
//! like upstream's objects.

use kube::api::{Api, ApiResource, DynamicObject, ListParams, Patch, PatchParams, PostParams};
use kube::core::GroupVersionKind;
use serde_json::{json, Value};

pub const MANAGED_BY_LABEL: &str = "app.kubernetes.io/managed-by";
pub const MANAGED_BY_VALUE: &str = "openshell-driver-kyma";
pub const SANDBOX_ID_LABEL: &str = "openshell.ai/sandbox-id";
/// Upstream's boundary labels (`openshell-driver-kubernetes/src/isolation.rs`).
/// Selecting on `openshell.ai/sandbox-id` alone would also match the supervisor pod.
pub const BOUNDARY_PAIR_LABEL: &str = "openshell.ai/boundary-pair";
pub const BOUNDARY_ROLE_LABEL: &str = "openshell.ai/boundary-role";
pub const WORKLOAD_ROLE: &str = "workload";
pub const EXPOSE_PORT: i32 = 8080;
pub const KYMA_GATEWAY: &str = "kyma-system/kyma-gateway";
const FIELD_MANAGER: &str = "openshell-driver-kyma";
const SANDBOX_GROUP: &str = "agents.x-k8s.io";
const SANDBOX_VERSION: &str = "v1beta1";

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::mock_client;

    fn owner() -> SandboxOwner {
        SandboxOwner {
            namespace: "sandboxes".to_string(),
            name: "ws--sb".to_string(),
            uid: "cr-uid".to_string(),
        }
    }

    fn config(search_namespace: Option<&str>) -> ExposureConfig {
        ExposureConfig {
            cluster_domain: "example.org".to_string(),
            ingress_namespace: "istio-system".to_string(),
            search_namespace: search_namespace.map(str::to_string),
        }
    }

    enum Scenario {
        Ok,
        ApiRuleRejected,
        NoSandbox,
    }

    fn respond(scenario: Scenario) -> impl Fn(&str) -> (u16, String) + Send + Sync + 'static {
        move |line: &str| {
            if line.starts_with("GET ") && line.ends_with("/sandboxes") {
                let items = match scenario {
                    Scenario::NoSandbox => json!([]),
                    _ => json!([{
                        "apiVersion": "agents.x-k8s.io/v1beta1",
                        "kind": "Sandbox",
                        "metadata": {"name": "ws--sb", "namespace": "sandboxes", "uid": "cr-uid"}
                    }]),
                };
                let list = json!({
                    "apiVersion": "agents.x-k8s.io/v1beta1",
                    "kind": "SandboxList",
                    "metadata": {},
                    "items": items
                });
                return (200, list.to_string());
            }
            if matches!(scenario, Scenario::ApiRuleRejected) && line.contains("/apirules/") {
                let status = json!({
                    "kind": "Status", "apiVersion": "v1", "metadata": {},
                    "status": "Failure", "reason": "NotFound", "code": 404,
                    "message": "the server could not find the requested resource"
                });
                return (404, status.to_string());
            }
            (200, json!({"apiVersion": "v1", "kind": "Object", "metadata": {"name": "ok"}}).to_string())
        }
    }

    fn lines(seen: &std::sync::Arc<std::sync::Mutex<Vec<crate::test_support::Recorded>>>) -> Vec<String> {
        seen.lock().unwrap().iter().map(|r| r.line.clone()).collect()
    }

    #[test]
    fn service_selects_only_the_workload_pod() {
        let service = service_manifest(&owner(), "SB-ID");
        let selector = &service["spec"]["selector"];
        assert_eq!(selector[BOUNDARY_PAIR_LABEL], "sb-id");
        assert_eq!(selector[BOUNDARY_ROLE_LABEL], WORKLOAD_ROLE);
        assert!(selector.get(SANDBOX_ID_LABEL).is_none(), "sandbox-id would also match the supervisor");
        assert_eq!(service["spec"]["ports"][0]["port"], EXPOSE_PORT);
        assert_eq!(service["metadata"]["name"], "ws--sb-svc");
    }

    #[test]
    fn objects_are_labelled_as_ours_and_owned_by_the_sandbox() {
        let owner = owner();
        for manifest in [
            service_manifest(&owner, "sb-id"),
            ingress_policy_manifest(&owner, "sb-id", "istio-system"),
            apirule_manifest(&owner, "sb-id", "example.org"),
        ] {
            let labels = &manifest["metadata"]["labels"];
            assert_eq!(labels[MANAGED_BY_LABEL], MANAGED_BY_VALUE);
            assert_eq!(labels[SANDBOX_ID_LABEL], "sb-id");
            assert!(labels.get("openshell.ai/managed-by").is_none(), "must never look like upstream's");
            let reference = &manifest["metadata"]["ownerReferences"][0];
            assert_eq!(reference["kind"], "Sandbox");
            assert_eq!(reference["uid"], "cr-uid");
            assert_eq!(reference["apiVersion"], "agents.x-k8s.io/v1beta1");
            assert_eq!(manifest["metadata"]["namespace"], "sandboxes");
        }
    }

    #[test]
    fn ingress_policy_admits_only_the_istio_gateway_on_8080() {
        let policy = ingress_policy_manifest(&owner(), "sb-id", "istio-system");
        assert_eq!(policy["spec"]["policyTypes"], json!(["Ingress"]), "must never touch egress");
        assert_eq!(policy["spec"]["podSelector"]["matchLabels"][BOUNDARY_ROLE_LABEL], WORKLOAD_ROLE);
        let from = &policy["spec"]["ingress"][0]["from"][0];
        assert_eq!(from["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"], "istio-system");
        assert_eq!(from["podSelector"]["matchLabels"]["istio"], "ingressgateway");
        assert_eq!(policy["spec"]["ingress"][0]["ports"][0]["port"], EXPOSE_PORT);
        assert_eq!(policy["metadata"]["name"], "ws--sb-expose");
    }

    #[test]
    fn apirule_host_uses_the_workspace_qualified_name() {
        let rule = apirule_manifest(&owner(), "sb-id", "example.org");
        assert_eq!(rule["apiVersion"], "gateway.kyma-project.io/v2");
        assert_eq!(rule["spec"]["hosts"], json!(["ws--sb.example.org"]));
        assert_eq!(rule["spec"]["service"]["name"], "ws--sb-svc");
        assert_eq!(rule["spec"]["service"]["port"], EXPOSE_PORT);
        assert_eq!(rule["spec"]["gateway"], KYMA_GATEWAY);
    }

    #[tokio::test]
    async fn reconcile_applies_service_policy_and_apirule_in_order() {
        let (client, seen) = mock_client(respond(Scenario::Ok));
        ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile("sb-id")
            .await
            .expect("exposure succeeds");
        assert_eq!(
            lines(&seen),
            vec![
                "GET /apis/agents.x-k8s.io/v1beta1/namespaces/sandboxes/sandboxes",
                "PATCH /api/v1/namespaces/sandboxes/services/ws--sb-svc",
                "PATCH /apis/networking.k8s.io/v1/namespaces/sandboxes/networkpolicies/ws--sb-expose",
                "PATCH /apis/gateway.kyma-project.io/v2/namespaces/sandboxes/apirules/ws--sb",
            ]
        );
    }

    // Review Focus 4.
    #[tokio::test]
    async fn shared_mode_lookup_is_namespaced() {
        let (client, seen) = mock_client(respond(Scenario::Ok));
        ExposureReconciler::new(client, config(Some("sandboxes"))).reconcile("sb-id").await.unwrap();
        assert!(lines(&seen)[0].contains("/namespaces/sandboxes/sandboxes"));

        let (client, seen) = mock_client(respond(Scenario::Ok));
        ExposureReconciler::new(client, config(None)).reconcile("sb-id").await.unwrap();
        assert_eq!(lines(&seen)[0], "GET /apis/agents.x-k8s.io/v1beta1/sandboxes");
    }

    // Review Focus 3.
    #[tokio::test]
    async fn apirule_failure_emits_a_warning_event() {
        let (client, seen) = mock_client(respond(Scenario::ApiRuleRejected));
        let err = ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile("sb-id")
            .await
            .unwrap_err();
        assert!(err.to_string().contains("APIRule"), "{err}");
        let recorded = seen.lock().unwrap().clone();
        let event = recorded
            .iter()
            .find(|r| r.line == "POST /api/v1/namespaces/sandboxes/events")
            .expect("a Warning Event was recorded");
        assert!(event.body.contains("\"Warning\""), "{}", event.body);
        assert!(event.body.contains("ExposureFailed"), "{}", event.body);
        assert!(event.body.contains("cr-uid"), "event must point at the Sandbox: {}", event.body);
    }

    #[tokio::test]
    async fn missing_sandbox_is_reported_without_an_event() {
        let (client, seen) = mock_client(respond(Scenario::NoSandbox));
        let err = ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile("sb-id")
            .await
            .unwrap_err();
        assert!(matches!(err, ExposureError::SandboxNotFound(_)));
        assert!(lines(&seen).iter().all(|line| !line.starts_with("POST ")));
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `make fmt && make test`
Expected: FAIL — `cannot find struct SandboxOwner`, `cannot find function service_manifest`, etc.

- [ ] **Step 5: Implement exposure**

Insert above `#[cfg(test)]` in `src/exposure.rs`:

```rust
/// The Sandbox CR the exposure objects belong to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SandboxOwner {
    pub namespace: String,
    pub name: String,
    pub uid: String,
}

impl SandboxOwner {
    fn api_version() -> String {
        format!("{SANDBOX_GROUP}/{SANDBOX_VERSION}")
    }

    fn owner_reference(&self) -> Value {
        json!({
            "apiVersion": Self::api_version(),
            "kind": "Sandbox",
            "name": self.name,
            "uid": self.uid,
        })
    }
}

#[derive(Debug, Clone)]
pub struct ExposureConfig {
    pub cluster_domain: String,
    pub ingress_namespace: String,
    /// `Some(namespace)` in Shared mode, where the driver's RBAC is namespaced;
    /// `None` searches all namespaces (Managed and Operator modes).
    pub search_namespace: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum ExposureError {
    #[error("no Sandbox resource carries {SANDBOX_ID_LABEL}={0}")]
    SandboxNotFound(String),
    #[error("the Sandbox resource for {0} has no namespace, name or uid")]
    IncompleteSandbox(String),
    #[error("{what}: {source}")]
    Kube {
        what: String,
        #[source]
        source: kube::Error,
    },
}

pub fn service_name(kube_name: &str) -> String {
    format!("{kube_name}-svc")
}

pub fn policy_name(kube_name: &str) -> String {
    format!("{kube_name}-expose")
}

fn labels(sandbox_id: &str) -> Value {
    json!({ MANAGED_BY_LABEL: MANAGED_BY_VALUE, SANDBOX_ID_LABEL: sandbox_id })
}

fn workload_selector(sandbox_id: &str) -> Value {
    // Upstream's `pair_label_value` lowercases the sandbox id.
    json!({
        BOUNDARY_PAIR_LABEL: sandbox_id.to_ascii_lowercase(),
        BOUNDARY_ROLE_LABEL: WORKLOAD_ROLE,
    })
}

fn metadata(owner: &SandboxOwner, name: &str, sandbox_id: &str) -> Value {
    json!({
        "name": name,
        "namespace": owner.namespace,
        "labels": labels(sandbox_id),
        "ownerReferences": [owner.owner_reference()],
    })
}

pub fn service_manifest(owner: &SandboxOwner, sandbox_id: &str) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": metadata(owner, &service_name(&owner.name), sandbox_id),
        "spec": {
            "selector": workload_selector(sandbox_id),
            "ports": [{"name": "http", "protocol": "TCP", "port": EXPOSE_PORT, "targetPort": EXPOSE_PORT}],
        },
    })
}

pub fn ingress_policy_manifest(owner: &SandboxOwner, sandbox_id: &str, ingress_namespace: &str) -> Value {
    json!({
        "apiVersion": "networking.k8s.io/v1",
        "kind": "NetworkPolicy",
        "metadata": metadata(owner, &policy_name(&owner.name), sandbox_id),
        "spec": {
            "podSelector": {"matchLabels": workload_selector(sandbox_id)},
            "policyTypes": ["Ingress"],
            "ingress": [{
                "from": [{
                    "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": ingress_namespace}},
                    "podSelector": {"matchLabels": {"istio": "ingressgateway"}},
                }],
                "ports": [{"protocol": "TCP", "port": EXPOSE_PORT}],
            }],
        },
    })
}

pub fn apirule_manifest(owner: &SandboxOwner, sandbox_id: &str, cluster_domain: &str) -> Value {
    json!({
        "apiVersion": "gateway.kyma-project.io/v2",
        "kind": "APIRule",
        "metadata": metadata(owner, &owner.name, sandbox_id),
        "spec": {
            "gateway": KYMA_GATEWAY,
            // Workspace-qualified, so two sandboxes named `dev` in different
            // workspaces never claim the same host.
            "hosts": [format!("{}.{cluster_domain}", owner.name)],
            "service": {"name": service_name(&owner.name), "port": EXPOSE_PORT},
            "rules": [{"path": "/*", "methods": ["GET", "POST"], "noAuth": true}],
        },
    })
}

fn failure_event_manifest(owner: &SandboxOwner, message: &str) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": "Event",
        "metadata": {"generateName": format!("{}-expose-", owner.name), "namespace": owner.namespace},
        "involvedObject": {
            "apiVersion": SandboxOwner::api_version(),
            "kind": "Sandbox",
            "name": owner.name,
            "namespace": owner.namespace,
            "uid": owner.uid,
        },
        "type": "Warning",
        "reason": "ExposureFailed",
        "message": message,
        "source": {"component": FIELD_MANAGER},
    })
}

fn resource(group: &str, version: &str, kind: &str, plural: &str) -> ApiResource {
    ApiResource::from_gvk_with_plural(&GroupVersionKind::gvk(group, version, kind), plural)
}

pub struct ExposureReconciler {
    client: kube::Client,
    config: ExposureConfig,
}

impl ExposureReconciler {
    pub fn new(client: kube::Client, config: ExposureConfig) -> Self {
        Self { client, config }
    }

    /// Find the sandbox's CR, expose it, and on failure record a Warning Event
    /// on the CR. Never retried here: the sandbox itself is healthy either way.
    pub async fn reconcile(&self, sandbox_id: &str) -> Result<(), ExposureError> {
        let owner = self.find_owner(sandbox_id).await?;
        if let Err(error) = self.expose(&owner, sandbox_id).await {
            if let Err(event_error) = self.report_failure(&owner, &error).await {
                tracing::warn!(sandbox_id, error = %event_error, "could not record the exposure failure as an Event");
            }
            return Err(error);
        }
        Ok(())
    }

    async fn find_owner(&self, sandbox_id: &str) -> Result<SandboxOwner, ExposureError> {
        let sandboxes = resource(SANDBOX_GROUP, SANDBOX_VERSION, "Sandbox", "sandboxes");
        let api: Api<DynamicObject> = match &self.config.search_namespace {
            Some(namespace) => Api::namespaced_with(self.client.clone(), namespace, &sandboxes),
            None => Api::all_with(self.client.clone(), &sandboxes),
        };
        let list = api
            .list(&ListParams::default().labels(&format!("{SANDBOX_ID_LABEL}={sandbox_id}")))
            .await
            .map_err(|source| ExposureError::Kube { what: "listing Sandbox resources".into(), source })?;
        let object = list
            .items
            .into_iter()
            .next()
            .ok_or_else(|| ExposureError::SandboxNotFound(sandbox_id.to_string()))?;
        match (object.metadata.namespace, object.metadata.name, object.metadata.uid) {
            (Some(namespace), Some(name), Some(uid)) => Ok(SandboxOwner { namespace, name, uid }),
            _ => Err(ExposureError::IncompleteSandbox(sandbox_id.to_string())),
        }
    }

    async fn expose(&self, owner: &SandboxOwner, sandbox_id: &str) -> Result<(), ExposureError> {
        self.apply(
            resource("", "v1", "Service", "services"),
            owner,
            &service_name(&owner.name),
            service_manifest(owner, sandbox_id),
            "applying the exposure Service",
        )
        .await?;
        self.apply(
            resource("networking.k8s.io", "v1", "NetworkPolicy", "networkpolicies"),
            owner,
            &policy_name(&owner.name),
            ingress_policy_manifest(owner, sandbox_id, &self.config.ingress_namespace),
            "applying the ingress NetworkPolicy",
        )
        .await?;
        self.apply(
            resource("gateway.kyma-project.io", "v2", "APIRule", "apirules"),
            owner,
            &owner.name,
            apirule_manifest(owner, sandbox_id, &self.config.cluster_domain),
            "applying the APIRule",
        )
        .await
    }

    async fn apply(
        &self,
        api_resource: ApiResource,
        owner: &SandboxOwner,
        name: &str,
        manifest: Value,
        what: &str,
    ) -> Result<(), ExposureError> {
        let api: Api<DynamicObject> =
            Api::namespaced_with(self.client.clone(), &owner.namespace, &api_resource);
        api.patch(name, &PatchParams::apply(FIELD_MANAGER).force(), &Patch::Apply(&manifest))
            .await
            .map(|_| ())
            .map_err(|source| ExposureError::Kube { what: what.into(), source })
    }

    async fn report_failure(&self, owner: &SandboxOwner, error: &ExposureError) -> Result<(), kube::Error> {
        let api: Api<DynamicObject> = Api::namespaced_with(
            self.client.clone(),
            &owner.namespace,
            &resource("", "v1", "Event", "events"),
        );
        let event: DynamicObject = serde_json::from_value(failure_event_manifest(owner, &error.to_string()))
            .expect("the event manifest is a well-formed object");
        api.create(&PostParams::default(), &event).await.map(|_| ())
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `make fmt && make test`
Expected: the 8 exposure tests PASS.

- [ ] **Step 7: Wire exposure into the hooks and `main.rs`**

In `src/hooks.rs`: add the field `exposure: Option<ExposureReconciler>`, change the constructor to `pub fn new(enrich: EnrichConfig, exposure: Option<ExposureReconciler>) -> Self`, and replace `after_create` with:

```rust
    async fn after_create(&self, sandbox: DriverSandbox) {
        let Some(exposure) = &self.exposure else {
            return;
        };
        if let Err(error) = exposure.reconcile(&sandbox.id).await {
            tracing::warn!(sandbox_id = %sandbox.id, %error, "sandbox created but not exposed");
        }
    }
```

In `src/main.rs`, replace `let driver = KubernetesComputeDriver::new(compute_config(upstream, selector), shutdown_rx)` with:

```rust
    let config = compute_config(upstream, selector);
    // The Kyma layer's own client; upstream's driver builds its own internally.
    let hook_client = kube::Client::try_default().await.into_diagnostic()?;
    let exposure = kyma.kyma_enable_apirule.then(|| {
        ExposureReconciler::new(
            hook_client.clone(),
            ExposureConfig {
                cluster_domain: kyma.kyma_cluster_domain.clone(),
                ingress_namespace: kyma.kyma_ingress_namespace.clone(),
                search_namespace: (!config.is_multi_namespace()).then(|| config.namespace.clone()),
            },
        )
    });
    let driver = KubernetesComputeDriver::new(config.clone(), shutdown_rx)
```

and construct the hooks with `KymaHookSet::new(kyma.enrich_config(), exposure)`. Import `openshell_driver_kyma::exposure::{ExposureConfig, ExposureReconciler}` and add `kube = { workspace = true }` usage (already a dependency).

- [ ] **Step 8: Run all tests and build**

Run: `make fmt && make test && make build`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add -A crates/openshell-driver-kyma
git commit -m "feat(driver): APIRule exposure as an explicit exception to upstream's fence

Hook 2. When --kyma-enable-apirule is set, each sandbox gets a Service
selecting its workload by upstream's boundary labels, a NetworkPolicy
admitting only the Istio ingress gateway on 8080, and an APIRule, all
owner-referenced to the Sandbox CR and labelled as ours. A failure never
fails the create; it becomes a Warning Event on the Sandbox.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Managed-namespace PSA labelling (hook 3)

**Files:**
- Create: `crates/openshell-driver-kyma/src/namespaces.rs`
- Modify: `src/lib.rs`, `src/hooks.rs`, `src/main.rs`

**Interfaces:**
- Consumes: `test_support::mock_client` (Task 5); `KymaArgs::kyma_workspace_psa_level` (Task 3); upstream `KubernetesComputeConfig::{workspace_mode, namespace_for_workspace}`, `WorkspaceMode`.
- Produces: `namespaces::{NamespaceLabeler::new(client: kube::Client, config: KubernetesComputeConfig, level: String) -> Option<NamespaceLabeler>, NamespaceLabeler::label(&self, workspace: &str) -> Result<(), tonic::Status>, PSA_ENFORCE_LABEL}`; `KymaHookSet::new(enrich: EnrichConfig, exposure: Option<ExposureReconciler>, namespaces: Option<NamespaceLabeler>)`.

- [ ] **Step 1: Write the failing tests**

Create `src/namespaces.rs`:

```rust
// SPDX-License-Identifier: Apache-2.0

//! Hook 3: Pod Security labels on the namespaces the driver creates.
//!
//! Only Managed mode creates namespaces. Shared mode uses the chart-managed
//! release namespace, and Operator-mode namespaces belong to the operator, so
//! neither is touched. The namespace name comes from upstream's own
//! `namespace_for_workspace`, never re-derived here.

use k8s_openapi::api::core::v1::Namespace;
use kube::api::{Api, Patch, PatchParams};
use openshell_driver_kubernetes::{KubernetesComputeConfig, WorkspaceMode};
use serde_json::json;
use tonic::Status;

pub const PSA_ENFORCE_LABEL: &str = "pod-security.kubernetes.io/enforce";

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::mock_client;

    fn config(mode: WorkspaceMode) -> KubernetesComputeConfig {
        KubernetesComputeConfig {
            workspace_mode: mode,
            gateway_id: "gw".to_string(),
            ..KubernetesComputeConfig::default()
        }
    }

    fn ok(_line: &str) -> (u16, String) {
        (200, r#"{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"x"}}"#.to_string())
    }

    #[test]
    fn labeler_exists_only_in_managed_mode_with_a_level() {
        let (client, _) = mock_client(ok);
        assert!(NamespaceLabeler::new(client.clone(), config(WorkspaceMode::Shared), "baseline".into()).is_none());
        assert!(NamespaceLabeler::new(client.clone(), config(WorkspaceMode::Managed), String::new()).is_none());
        assert!(NamespaceLabeler::new(client, config(WorkspaceMode::Managed), "baseline".into()).is_some());
    }

    #[tokio::test]
    async fn managed_namespace_is_labelled_with_the_level() {
        let (client, seen) = mock_client(ok);
        let expected = config(WorkspaceMode::Managed)
            .namespace_for_workspace("ws", None)
            .expect("managed mode names a namespace");
        NamespaceLabeler::new(client, config(WorkspaceMode::Managed), "baseline".into())
            .unwrap()
            .label("ws")
            .await
            .expect("label succeeds");
        let recorded = seen.lock().unwrap().clone();
        assert_eq!(recorded.len(), 1);
        assert_eq!(recorded[0].line, format!("PATCH /api/v1/namespaces/{expected}"));
        assert!(recorded[0].body.contains(PSA_ENFORCE_LABEL), "{}", recorded[0].body);
        assert!(recorded[0].body.contains("baseline"), "{}", recorded[0].body);
    }

    #[tokio::test]
    async fn patch_failure_becomes_unavailable_naming_the_namespace() {
        let (client, _) = mock_client(|_line: &str| {
            (500, r#"{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","code":500,"message":"boom"}"#.to_string())
        });
        let status = NamespaceLabeler::new(client, config(WorkspaceMode::Managed), "baseline".into())
            .unwrap()
            .label("ws")
            .await
            .unwrap_err();
        assert_eq!(status.code(), tonic::Code::Unavailable);
        assert!(status.message().contains("openshell-gw-"), "{}", status.message());
    }
}
```

Add `pub mod namespaces;` to `lib.rs`, and `k8s-openapi = { workspace = true }` to the crate's `[dependencies]`.

If `KubernetesComputeConfig::default()` fails `validate` rules on `namespace_for_workspace` in Managed mode, the upstream error message will say which field; set that field in `config()` rather than changing the assertion.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make fmt && make test`
Expected: FAIL — `cannot find struct NamespaceLabeler`.

- [ ] **Step 3: Implement**

Insert above `#[cfg(test)]`:

```rust
pub struct NamespaceLabeler {
    client: kube::Client,
    config: KubernetesComputeConfig,
    level: String,
}

impl NamespaceLabeler {
    /// `None` unless the driver creates namespaces (Managed mode) and a level
    /// is configured.
    pub fn new(client: kube::Client, config: KubernetesComputeConfig, level: String) -> Option<Self> {
        (matches!(config.workspace_mode, WorkspaceMode::Managed) && !level.is_empty())
            .then(|| Self { client, config, level })
    }

    /// Apply the Pod Security enforce label to the workspace's namespace.
    pub async fn label(&self, workspace: &str) -> Result<(), Status> {
        let namespace = self
            .config
            .namespace_for_workspace(workspace, None)
            .map_err(Status::internal)?;
        let patch = json!({"metadata": {"labels": {PSA_ENFORCE_LABEL: self.level}}});
        Api::<Namespace>::all(self.client.clone())
            .patch(&namespace, &PatchParams::default(), &Patch::Merge(&patch))
            .await
            .map(|_| ())
            .map_err(|error| {
                Status::unavailable(format!(
                    "labelling workspace namespace {namespace} with {PSA_ENFORCE_LABEL}={}: {error}",
                    self.level
                ))
            })
    }
}
```

Run: `make fmt && make test`
Expected: the 3 namespace tests PASS.

- [ ] **Step 4: Wire into hooks and `main.rs`**

In `src/hooks.rs`: add `namespaces: Option<NamespaceLabeler>`, change the constructor to `pub fn new(enrich: EnrichConfig, exposure: Option<ExposureReconciler>, namespaces: Option<NamespaceLabeler>) -> Self`, and replace `after_ensure_workspace` with:

```rust
    async fn after_ensure_workspace(&self, workspace: &str) -> Result<(), Status> {
        match &self.namespaces {
            Some(labeler) => labeler.label(workspace).await,
            None => Ok(()),
        }
    }
```

In `src/main.rs`, before building the hooks:

```rust
    let namespaces = NamespaceLabeler::new(
        hook_client.clone(),
        config.clone(),
        kyma.kyma_workspace_psa_level.clone(),
    );
```

and pass it as the third `KymaHookSet::new` argument. Update the file header of `hooks.rs` to: `//! The production [`KymaHooks`]: request enrichment, APIRule exposure, and Managed-mode namespace labelling.`

- [ ] **Step 5: Run all tests and build**

Run: `make fmt && make test && make build`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A crates/openshell-driver-kyma
git commit -m "feat(driver): PSA labels on Managed-mode workspace namespaces

Hook 3. After upstream ensures a workspace in Managed mode, label its
namespace with the configured Pod Security level. The namespace name comes
from upstream's namespace_for_workspace. Shared and Operator namespaces are
never touched.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Chart — driver configuration mirrors upstream

**Files:**
- Create: `deploy/helm/openshell-driver-kyma/templates/_driver-env.tpl`, `scripts/check-chart-render.sh`
- Modify: `deploy/helm/openshell-driver-kyma/templates/deployment.yaml` (driver container), `values.yaml` (`driver:` block, new `upstream:` and `networkPolicy:` blocks), `templates/_workspace-guards.tpl`, `templates/_helpers.tpl`, `.github/workflows/helm-lint.yml`

**Interfaces:**
- Consumes: `scripts/check-upstream-args.sh --print-env` and `pinned_upstream_tag` (Task 2); driver env vars `OPENSHELL_*` (upstream) and `OPENSHELL_KYMA_*` (Tasks 3–6).
- Produces: helper `openshell-driver-kyma.driverEnv`; helper `openshell-driver-kyma.grpcEndpoint`; values `upstream.version`, `networkPolicy.enabled`, and the `driver.*` keys below; `scripts/check-chart-render.sh` (checks 1–3 and 6 here, 4–5 added in Task 8).

- [ ] **Step 1: Write the render check first**

Create `scripts/check-chart-render.sh` (`chmod 755`):

```bash
#!/usr/bin/env bash
# Render the chart and assert the driver's configuration surface:
#   1. every upstream option (check-upstream-args.sh --print-env) is referenced
#      by the chart templates, so it can be set from values;
#   2. the admission policy the gateway derives from [openshell.drivers.kyma]
#      equals the one the driver acknowledges (OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON);
#   3. the driver container takes no command-line args, and removed values are
#      gone from values.yaml;
#   6. values.yaml's upstream.version equals the tag Cargo.toml pins.
# Checks 4 and 5 (NetworkPolicies, RBAC) are added with the RBAC work.
# Needs helm, python3 with PyYAML, and network access (for check 1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

ROOT=$(git rev-parse --show-toplevel)
CHART="$ROOT/deploy/helm/openshell-driver-kyma"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

"$SCRIPT_DIR/check-upstream-args.sh" --print-env >"$WORK/upstream-env.txt"
pinned_upstream_tag >"$WORK/pinned-tag.txt"
for mode in shared managed; do
	for allow in true false; do
		extra=()
		[[ $mode == managed ]] && extra=(--set gateway.sandboxJwt.gatewayId=gw)
		helm template t "$CHART" --set gateway.enabled=true \
			--set "driver.workspaceMode=$mode" --set "driver.allowDriverConfig=$allow" \
			"${extra[@]}" >"$WORK/render-$mode-$allow.yaml"
	done
done

python3 - "$WORK" "$CHART" <<'PY'
import json, pathlib, re, sys
import yaml

work, chart = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
failures = []

def docs(path):
    return [d for d in yaml.safe_load_all(path.read_text()) if d]

def driver_container(documents):
    for d in documents:
        if d.get("kind") == "Deployment":
            for c in d["spec"]["template"]["spec"]["containers"]:
                if c["name"] == "driver":
                    return c
    raise SystemExit("no driver container rendered")

# 1. every upstream option is reachable from values
templates = "\n".join(p.read_text() for p in (chart / "templates").glob("*"))
missing = [n for n in (work / "upstream-env.txt").read_text().split() if n not in templates]
if missing:
    failures.append("upstream options not reachable from the chart: " + ", ".join(missing))

# 2. gateway and driver agree on the admission policy
for render in sorted(work.glob("render-*.yaml")):
    expected = render.stem.endswith("-true")
    documents = docs(render)
    toml = next(d["data"]["gateway.toml"] for d in documents
                if d.get("kind") == "ConfigMap" and "gateway.toml" in d.get("data", {}))
    kyma_table = toml.split("[openshell.drivers.kyma]", 1)[1].split("\n[", 1)[0]
    m = re.search(r"^\s*allow_driver_config\s*=\s*(true|false)\s*$", kyma_table, re.M)
    gateway_side = m and m.group(1) == "true"
    env = {e["name"]: e.get("value") for e in driver_container(documents).get("env", [])}
    driver_side = json.loads(env["OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON"]).get("allow_driver_config")
    if not (gateway_side == driver_side == expected):
        failures.append(f"{render.name}: gateway allow_driver_config={gateway_side}, "
                        f"driver={driver_side}, values={expected}")
    # upstream's chart derives the gateway's and the driver's gateway_id from one value
    jwt_id = re.search(r'^\s*gateway_id\s*=\s*"([^"]*)"', toml, re.M)
    if not jwt_id or env.get("OPENSHELL_GATEWAY_ID") != jwt_id.group(1):
        failures.append(f"{render.name}: driver OPENSHELL_GATEWAY_ID={env.get('OPENSHELL_GATEWAY_ID')!r} "
                        f"differs from the gateway's gateway_id={jwt_id and jwt_id.group(1)!r}")

# 3. no args on the driver, removed values gone
if "args" in driver_container(docs(work / "render-shared-true.yaml")):
    failures.append("the driver container still passes command-line args")
removed = ["supervisorBinaryPath", "supervisorMountPath", "gpuSupport", "enableNetworkPolicy",
           "telemetryEnabled", "stopTimeoutSecs", "driverConfigAllowVolumes",
           "operatorNamespaceAllowlist", "gatewayId"]
values = (chart / "values.yaml").read_text()
driver_values = (yaml.safe_load(values) or {}).get("driver", {})
still = [k for k in removed if k in driver_values]
if still:
    failures.append("removed values still in values.yaml: " + ", ".join(still))

# 6. the chart's upstream version is the pinned tag
pinned = (work / "pinned-tag.txt").read_text().strip()
chart_version = (yaml.safe_load(values) or {}).get("upstream", {}).get("version")
if chart_version != pinned:
    failures.append(f"values upstream.version={chart_version!r}, Cargo.toml pins {pinned!r}")

if failures:
    print("CHART_RENDER_FAIL:")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("CHART_RENDER_OK")
PY
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/check-chart-render.sh`
Expected: `CHART_RENDER_FAIL:` listing missing upstream options, the driver still passing args, a gateway-id mismatch, the removed values, and `upstream.version`.

- [ ] **Step 3: Replace the `driver:` values**

In `values.yaml`, inside `driver:`, **delete** `supervisorBinaryPath`, `supervisorMountPath`, `gpuSupport`, `enableNetworkPolicy`, `telemetryEnabled`, `stopTimeoutSecs`, `operatorNamespaceAllowlist`, `driverConfigAllowVolumes` and `gatewayId` with their comments. `driver.gatewayId` goes because upstream's chart derives the gateway's and the driver's gateway id from one value; here that is `gateway.sandboxJwt.gatewayId` via the existing `openshell-driver-kyma.gatewayId` helper, which the gateway TOML already uses. Keep `socket`, `supervisorImage`, `gatewayEndpoint`, `istioInjectSandboxes`, `enableApirule`, `clusterDomain`, `disableClaudeTelemetry`, `enableUserNamespaces`, `sandboxUid`, `sandboxGid`, `sandboxStorageSize`, `sandboxStorageClass`, `healthPort`, `logLevel`, `workspaceMode`, `allowDriverConfig`, updating any comment that describes the old driver's behaviour. Update the `allowDriverConfig` comment to say it now also governs caller volumes, because upstream's resource admission checks them. **Add**, inside `driver:`:

```yaml
  # --- Upstream openshell-driver-kubernetes options (same names upstream's
  # chart uses; each maps to the upstream environment variable in
  # templates/_driver-env.tpl). Empty/false means "upstream's default". ---
  # Sandbox runtime (isolation backend) image, digest-pinned. Upstream's
  # compiled-in default depends on build variables a git-dependency build does
  # not set, so the chart always passes it.
  sandboxRuntimeImage: ghcr.io/nvidia/openshell/sandbox@sha256:bf4797b6c511f2d8ba02955dbba4bf76c1f0dd6d83531420c5408d5f1fb9d72f
  sandboxRuntimeImagePullPolicy: ""
  supervisorImagePullPolicy: ""
  # Default sandbox image when a create request names none.
  sandboxImage: ""
  sandboxImagePullPolicy: ""
  sandboxImagePullSecrets: []
  sandboxRuntimeBoundaryPort: 5500
  saTokenTtlSecs: 3600
  runtimeClassName: ""
  sandboxSshSocketPath: ""
  bindAddress: ""
  otlpEndpoint: ""
  gatewayName: ""
  clientTlsSecretName: ""
  hostGatewayIp: ""
  providerSpiffeWorkloadApiSocket: ""
  # Operator mode: select namespaces by label, or by a file of names mounted
  # from a ConfigMap (replaces the removed operatorNamespaceAllowlist).
  operatorNamespaceLabel: ""
  operatorNamespaceConfigMap:
    name: ""
    key: namespaces
  managedSshIngress:
    enabled: false
    gatewayNamespace: ""
    gatewayPodSelector: []   # key=value entries
  upstreamProxy:
    url: ""
    noProxy: ""
    authSecretName: ""
    authSecretKey: ""
    allowInsecure: false
    connectByHostname: false
    caBundleConfigMap:
      name: ""
      key: ca.crt
  # --- Kyma layer ---
  # KEY=VALUE environment added to every sandbox.
  sandboxEnv: []
  # Namespace of the Istio ingress gateway APIRule traffic arrives from.
  ingressNamespace: istio-system
  # Pod Security level for namespaces the driver creates in managed mode.
  workspacePsaLevel: ""
```

Add two new top-level blocks:

```yaml
# The upstream NVIDIA/OpenShell release this chart's driver links. Must equal
# the tag in the workspace Cargo.toml (scripts/check-chart-render.sh).
upstream:
  version: v0.1.2

networkPolicy:
  # NetworkPolicy for the driver+gateway pod. Sandbox pods are fenced by
  # upstream's own per-namespace policies; the chart must not add to them.
  enabled: true
```

Remove the values comment block that describes `proto/UPSTREAM.lock` and `scripts/check-proto-drift.sh` (around the gateway image), replacing it with one sentence: the gateway image is resolved from the upstream release in `upstream.version`.

- [ ] **Step 4: Add the gRPC endpoint helper**

Append to `templates/_helpers.tpl`:

```yaml
{{/*
The gateway endpoint sandboxes dial (upstream --grpc-endpoint). An explicit
driver.gatewayEndpoint wins; with the gateway sidecar enabled it defaults to
this release's Service. Empty lets upstream decide.
*/}}
{{- define "openshell-driver-kyma.grpcEndpoint" -}}
{{- if .Values.driver.gatewayEndpoint -}}
{{- .Values.driver.gatewayEndpoint -}}
{{- else if .Values.gateway.enabled -}}
{{- printf "http://%s.%s.svc.cluster.local:%v" (include "openshell-driver-kyma.fullname" .) .Release.Namespace .Values.gateway.grpcPort -}}
{{- end -}}
{{- end -}}
```

- [ ] **Step 5: Create `templates/_driver-env.tpl`**

Booleans are emitted only when true: upstream's boolean options are presence flags.

```yaml
{{/*
Environment for the driver container: upstream openshell-driver-kubernetes's
options, by upstream's own variable names, then the Kyma layer's.
scripts/check-chart-render.sh fails CI when an upstream option is missing here.
*/}}
{{- define "openshell-driver-kyma.driverEnv" -}}
{{- $d := .Values.driver -}}
- name: OPENSHELL_COMPUTE_DRIVER_SOCKET
  value: {{ $d.socket | quote }}
- name: OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON
  # Must agree with [openshell.drivers.kyma] allow_driver_config in
  # gateway-config.yaml; both render from driver.allowDriverConfig.
  value: {{ dict "allow_driver_config" $d.allowDriverConfig | toJson | quote }}
- name: OPENSHELL_LOG_LEVEL
  value: {{ $d.logLevel | quote }}
- name: OPENSHELL_SANDBOX_NAMESPACE
  value: {{ .Values.namespace | quote }}
- name: OPENSHELL_WORKSPACE_MODE
  value: {{ $d.workspaceMode | quote }}
- name: OPENSHELL_GATEWAY_ID
  # The same value the gateway's gateway_jwt uses, as in upstream's chart.
  value: {{ include "openshell-driver-kyma.gatewayId" . | quote }}
- name: OPENSHELL_K8S_SANDBOX_SERVICE_ACCOUNT
  value: {{ .Values.sandboxServiceAccount.name | quote }}
- name: OPENSHELL_SUPERVISOR_IMAGE
  value: {{ $d.supervisorImage | quote }}
- name: OPENSHELL_SANDBOX_RUNTIME_IMAGE
  value: {{ $d.sandboxRuntimeImage | quote }}
- name: OPENSHELL_K8S_SANDBOX_RUNTIME_BOUNDARY_PORT
  value: {{ $d.sandboxRuntimeBoundaryPort | quote }}
- name: OPENSHELL_K8S_SA_TOKEN_TTL_SECS
  value: {{ $d.saTokenTtlSecs | quote }}
{{- with include "openshell-driver-kyma.grpcEndpoint" . }}
- name: OPENSHELL_GRPC_ENDPOINT
  value: {{ . | quote }}
{{- end }}
{{- with $d.bindAddress }}
- name: OPENSHELL_COMPUTE_DRIVER_BIND
  value: {{ . | quote }}
{{- end }}
{{- with $d.otlpEndpoint }}
- name: OPENSHELL_OTLP_ENDPOINT
  value: {{ . | quote }}
{{- end }}
{{- with $d.gatewayName }}
- name: OPENSHELL_GATEWAY_NAME
  value: {{ . | quote }}
{{- end }}
{{- with $d.operatorNamespaceLabel }}
- name: OPENSHELL_OPERATOR_NAMESPACE_LABEL
  value: {{ . | quote }}
{{- end }}
{{- if $d.operatorNamespaceConfigMap.name }}
- name: OPENSHELL_OPERATOR_NAMESPACE_FILE
  value: {{ printf "/etc/openshell-operator-namespaces/%s" $d.operatorNamespaceConfigMap.key | quote }}
{{- end }}
{{- with $d.sandboxImage }}
- name: OPENSHELL_SANDBOX_IMAGE
  value: {{ . | quote }}
{{- end }}
{{- with $d.sandboxImagePullPolicy }}
- name: OPENSHELL_SANDBOX_IMAGE_PULL_POLICY
  value: {{ . | quote }}
{{- end }}
{{- with $d.sandboxImagePullSecrets }}
- name: OPENSHELL_SANDBOX_IMAGE_PULL_SECRETS
  value: {{ join "," . | quote }}
{{- end }}
{{- if $d.managedSshIngress.enabled }}
- name: OPENSHELL_MANAGED_SSH_INGRESS_ENABLED
  value: "true"
{{- end }}
{{- with $d.managedSshIngress.gatewayNamespace }}
- name: OPENSHELL_MANAGED_SSH_GATEWAY_NAMESPACE
  value: {{ . | quote }}
{{- end }}
{{- with $d.managedSshIngress.gatewayPodSelector }}
- name: OPENSHELL_MANAGED_SSH_GATEWAY_POD_SELECTOR
  value: {{ join "," . | quote }}
{{- end }}
{{- with $d.sandboxSshSocketPath }}
- name: OPENSHELL_SANDBOX_SSH_SOCKET_PATH
  value: {{ . | quote }}
{{- end }}
{{- with $d.clientTlsSecretName }}
- name: OPENSHELL_CLIENT_TLS_SECRET_NAME
  value: {{ . | quote }}
{{- end }}
{{- with $d.hostGatewayIp }}
- name: OPENSHELL_HOST_GATEWAY_IP
  value: {{ . | quote }}
{{- end }}
{{- with $d.sandboxRuntimeImagePullPolicy }}
- name: OPENSHELL_SANDBOX_RUNTIME_IMAGE_PULL_POLICY
  value: {{ . | quote }}
{{- end }}
{{- with $d.supervisorImagePullPolicy }}
- name: OPENSHELL_SUPERVISOR_IMAGE_PULL_POLICY
  value: {{ . | quote }}
{{- end }}
{{- with $d.upstreamProxy.url }}
- name: OPENSHELL_UPSTREAM_PROXY
  value: {{ . | quote }}
{{- end }}
{{- with $d.upstreamProxy.noProxy }}
- name: OPENSHELL_UPSTREAM_NO_PROXY
  value: {{ . | quote }}
{{- end }}
{{- with $d.upstreamProxy.authSecretName }}
- name: OPENSHELL_UPSTREAM_PROXY_AUTH_SECRET_NAME
  value: {{ . | quote }}
{{- end }}
{{- with $d.upstreamProxy.authSecretKey }}
- name: OPENSHELL_UPSTREAM_PROXY_AUTH_SECRET_KEY
  value: {{ . | quote }}
{{- end }}
{{- if $d.upstreamProxy.allowInsecure }}
- name: OPENSHELL_UPSTREAM_PROXY_AUTH_ALLOW_INSECURE
  value: "true"
{{- end }}
{{- if $d.upstreamProxy.connectByHostname }}
- name: OPENSHELL_UPSTREAM_PROXY_CONNECT_BY_HOSTNAME
  value: "true"
{{- end }}
{{- if $d.upstreamProxy.caBundleConfigMap.name }}
- name: OPENSHELL_UPSTREAM_PROXY_CA_BUNDLE
  value: {{ printf "/etc/openshell-upstream-proxy/%s" $d.upstreamProxy.caBundleConfigMap.key | quote }}
{{- end }}
{{- if $d.enableUserNamespaces }}
- name: OPENSHELL_ENABLE_USER_NAMESPACES
  value: "true"
{{- end }}
{{- with $d.providerSpiffeWorkloadApiSocket }}
- name: OPENSHELL_PROVIDER_SPIFFE_WORKLOAD_API_SOCKET
  value: {{ . | quote }}
{{- end }}
{{- with $d.sandboxUid }}
- name: OPENSHELL_K8S_SANDBOX_UID
  value: {{ . | quote }}
{{- end }}
{{- with $d.sandboxGid }}
- name: OPENSHELL_K8S_SANDBOX_GID
  value: {{ . | quote }}
{{- end }}
{{- with $d.sandboxStorageSize }}
- name: OPENSHELL_K8S_WORKSPACE_DEFAULT_STORAGE_SIZE
  value: {{ . | quote }}
{{- end }}
{{- with $d.sandboxStorageClass }}
- name: OPENSHELL_K8S_WORKSPACE_STORAGE_CLASS
  value: {{ . | quote }}
{{- end }}
{{- with $d.runtimeClassName }}
- name: OPENSHELL_K8S_DEFAULT_RUNTIME_CLASS_NAME
  value: {{ . | quote }}
{{- end }}
{{- if $d.istioInjectSandboxes }}
- name: OPENSHELL_KYMA_ISTIO_INJECT_SANDBOXES
  value: "true"
{{- end }}
{{- if $d.disableClaudeTelemetry }}
- name: OPENSHELL_KYMA_DISABLE_CLAUDE_TELEMETRY
  value: "true"
{{- end }}
{{- if $d.enableApirule }}
- name: OPENSHELL_KYMA_ENABLE_APIRULE
  value: "true"
- name: OPENSHELL_KYMA_CLUSTER_DOMAIN
  value: {{ required "driver.clusterDomain is required when driver.enableApirule is true" $d.clusterDomain | quote }}
{{- end }}
- name: OPENSHELL_KYMA_INGRESS_NAMESPACE
  value: {{ $d.ingressNamespace | quote }}
{{- with $d.workspacePsaLevel }}
- name: OPENSHELL_KYMA_WORKSPACE_PSA_LEVEL
  value: {{ . | quote }}
{{- end }}
- name: OPENSHELL_KYMA_HEALTH_PORT
  value: {{ $d.healthPort | quote }}
{{- with (include "openshell-driver-kyma.sandboxEnv" .) }}
- name: OPENSHELL_KYMA_SANDBOX_ENV
  value: {{ . | quote }}
{{- end }}
{{- end -}}

{{/*
Comma-joined KEY=VALUE list for OPENSHELL_KYMA_SANDBOX_ENV. Task 9 appends the
inference provider's variables.
*/}}
{{- define "openshell-driver-kyma.sandboxEnv" -}}
{{- join "," .Values.driver.sandboxEnv -}}
{{- end -}}
```

- [ ] **Step 6: Rewrite the driver container**

In `templates/deployment.yaml`, in the `driver` container, delete the entire `args:` list and the existing `env:` list (it only held `RUST_LOG`), and put in their place:

```yaml
          # Upstream openshell-driver-kubernetes's options by upstream's own
          # variable names, then OPENSHELL_KYMA_* for the Kyma layer.
          env:
            {{- include "openshell-driver-kyma.driverEnv" . | nindent 12 }}
```

Keep the container's ports, probes, resources and security context. If `driver.operatorNamespaceConfigMap.name` or `driver.upstreamProxy.caBundleConfigMap.name` is set, the driver container must mount them; add to the driver container's `volumeMounts` (create the list if absent):

```yaml
            {{- if .Values.driver.operatorNamespaceConfigMap.name }}
            - name: operator-namespaces
              mountPath: /etc/openshell-operator-namespaces
              readOnly: true
            {{- end }}
            {{- if .Values.driver.upstreamProxy.caBundleConfigMap.name }}
            - name: upstream-proxy-ca
              mountPath: /etc/openshell-upstream-proxy
              readOnly: true
            {{- end }}
```

and to the pod's `volumes`:

```yaml
        {{- with .Values.driver.operatorNamespaceConfigMap.name }}
        - name: operator-namespaces
          configMap:
            name: {{ . }}
        {{- end }}
        {{- with .Values.driver.upstreamProxy.caBundleConfigMap.name }}
        - name: upstream-proxy-ca
          configMap:
            name: {{ . }}
        {{- end }}
```

- [ ] **Step 7: Update the workspace guards**

In `templates/_workspace-guards.tpl`, change the managed-mode gateway-id lines to validate `include "openshell-driver-kyma.gatewayId" .` (it always has a value now — the fullname by default — so drop the "requires driver.gatewayId" failure and keep only the DNS-1123 check, naming `gateway.sandboxJwt.gatewayId` in its message). Delete the managed-mode `if .Values.driver.enableNetworkPolicy` block (upstream now installs its workload fence in every managed namespace) and replace the operator-mode guard with:

```yaml
{{- if and (eq $mode "operator") (not .Values.driver.operatorNamespaceLabel) (not .Values.driver.operatorNamespaceConfigMap.name) -}}
{{- fail "driver.workspaceMode=operator requires driver.operatorNamespaceLabel or driver.operatorNamespaceConfigMap.name, which select the namespaces upstream's driver may use." -}}
{{- end -}}
```

In `templates/networkpolicy.yaml` change the first line's condition from `.Values.driver.enableNetworkPolicy` to `.Values.networkPolicy.enabled` (the sandbox policy is removed in Task 8).

- [ ] **Step 8: Run the check and the other chart gates**

Run: `./scripts/check-chart-render.sh`
Expected: `CHART_RENDER_OK`.

Run: `helm lint deploy/helm/openshell-driver-kyma && ./scripts/check-gateway-config.sh`
Expected: lint passes; `GATEWAY_CONFIG_ACCEPTED`.

Run: `helm template t deploy/helm/openshell-driver-kyma --set driver.enableApirule=true 2>&1 | tail -2`
Expected: fails with `driver.clusterDomain is required when driver.enableApirule is true`.

- [ ] **Step 9: Run the check in CI**

In `.github/workflows/helm-lint.yml`, add after the lint step, matching its style:

```yaml
      - name: Assert the driver's configuration surface
        shell: bash
        run: ./scripts/check-chart-render.sh
```

If the workflow does not install PyYAML or has no network, add the same setup the `gateway-config` job in `branch-checks.yml` uses.

- [ ] **Step 10: Commit**

```bash
git add -A deploy scripts/check-chart-render.sh .github/workflows/helm-lint.yml
git commit -m "feat(chart)!: configure the driver through upstream's option surface

The driver container now takes upstream openshell-driver-kubernetes's
options by upstream's own environment variables, plus OPENSHELL_KYMA_* for
the Kyma layer. Every upstream option is reachable from values, the
sandbox runtime image is digest-pinned, and the admission policy renders
from one value on both the gateway and driver side.
check-chart-render.sh keeps all three true.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Chart — RBAC mirrors upstream; stop fencing sandbox pods ourselves

**Files:**
- Create: `deploy/helm/openshell-driver-kyma/templates/clusterrole.yaml`, `templates/clusterrolebinding.yaml`
- Rewrite: `templates/role.yaml`
- Delete: `templates/clusterrole-tokenreview.yaml`, `templates/clusterrole-nodes.yaml`, `templates/clusterrole-workspaces.yaml`
- Modify: `templates/rolebinding.yaml` (only if the Role's name changes), `templates/networkpolicy.yaml`, `scripts/check-chart-render.sh`

**Interfaces:**
- Consumes: `.Values.driver.{workspaceMode, allowDriverConfig, enableApirule, workspacePsaLevel}`, `.Values.networkPolicy.enabled` (Task 7).
- Produces: checks 4 and 5 in `scripts/check-chart-render.sh`.

- [ ] **Step 1: Extend the render check (failing first)**

In `scripts/check-chart-render.sh`, add renders with APIRule exposure and managed mode:

```bash
helm template t "$CHART" --set gateway.enabled=true --set driver.enableApirule=true \
	--set driver.clusterDomain=example.org >"$WORK/rbac-apirule.yaml"
helm template t "$CHART" --set gateway.enabled=true --set driver.workspaceMode=managed \
	--set gateway.sandboxJwt.gatewayId=gw --set driver.enableApirule=true \
	--set driver.clusterDomain=example.org --set driver.workspacePsaLevel=baseline \
	>"$WORK/rbac-managed-apirule.yaml"
```

Place them before the `python3` call. They are named `rbac-*.yaml` so check 2's `render-*.yaml` glob does not pick them up. Then add to the Python block, before the failure report:

```python
# 4. no chart NetworkPolicy selects OpenShell sandbox pods
for render in sorted(work.glob("r*.yaml")):
    for d in docs(render):
        if d.get("kind") != "NetworkPolicy":
            continue
        selector = (d.get("spec") or {}).get("podSelector") or {}
        keys = list((selector.get("matchLabels") or {}).keys())
        keys += [e.get("key", "") for e in selector.get("matchExpressions") or []]
        if any(k.startswith("openshell.ai/") for k in keys):
            failures.append(f"{render.name}: NetworkPolicy {d['metadata']['name']} selects sandbox "
                            "pods and would add to upstream's workload fence")

# 5. RBAC covers upstream's rules plus the Kyma layer's
def granted(documents, kind):
    return [r for d in documents if d.get("kind") == kind for r in d.get("rules", [])]

def covers(rules, group, resource, verb):
    return any(group in r.get("apiGroups", []) and resource in r.get("resources", [])
               and (verb in r.get("verbs", []) or "*" in r.get("verbs", [])) for r in rules)

def need(rules, where, group, resources, verbs):
    for resource in resources:
        for verb in verbs:
            if not covers(rules, group, resource, verb):
                failures.append(f"{where}: missing {verb} on {group or 'core'}/{resource}")

WORKLOAD = [("agents.x-k8s.io", ["sandboxes", "sandboxes/status"],
             ["create", "delete", "get", "list", "patch", "update", "watch"]),
            ("", ["events"], ["get", "list", "watch"]),
            ("", ["pods"], ["create", "delete", "get", "list", "patch", "watch"]),
            ("", ["services"], ["create", "get"]),
            ("networking.k8s.io", ["networkpolicies"], ["create", "get"])]
CLUSTER = [("node.k8s.io", ["runtimeclasses"], ["get"]),
           ("scheduling.k8s.io", ["priorityclasses"], ["get"]),
           ("authentication.k8s.io", ["tokenreviews"], ["create"]),
           ("", ["nodes"], ["get", "list", "watch"]),
           ("", ["namespaces"], ["get"])]
KYMA = [("", ["services"], ["patch"]), ("networking.k8s.io", ["networkpolicies"], ["patch"]),
        ("gateway.kyma-project.io", ["apirules"], ["create", "get", "patch"]),
        ("", ["events"], ["create"])]

shared = docs(work / "render-shared-true.yaml")
for group, resources, verbs in WORKLOAD + [("", ["secrets"], ["create", "delete"]),
                                           ("", ["persistentvolumeclaims"], ["get"])]:
    need(granted(shared, "Role"), "shared Role", group, resources, verbs)
for group, resources, verbs in CLUSTER:
    need(granted(shared, "ClusterRole"), "shared ClusterRole", group, resources, verbs)
for group, resources, verbs in KYMA:
    need(granted(docs(work / "rbac-apirule.yaml"), "Role"), "shared Role with APIRule", group, resources, verbs)

managed = docs(work / "rbac-managed-apirule.yaml")
for group, resources, verbs in WORKLOAD + CLUSTER + KYMA + [
        ("", ["namespaces"], ["list", "watch", "create", "delete", "patch"]),
        ("", ["secrets"], ["create", "delete"]),
        ("", ["serviceaccounts"], ["create", "get"]),
        ("networking.k8s.io", ["networkpolicies"], ["update"])]:
    need(granted(managed, "ClusterRole"), "managed ClusterRole", group, resources, verbs)
```

Run `./scripts/check-chart-render.sh`; expected FAIL listing the missing rules and the `-sandbox` NetworkPolicy.

- [ ] **Step 2: Rewrite `templates/role.yaml`**

Keep `metadata.name: {{ include "openshell-driver-kyma.fullname" . }}` — `rolebinding.yaml` binds that name. Replace the file with:

```yaml
{{- if eq .Values.driver.workspaceMode "shared" }}
# The driver's rights in the shared sandbox namespace: upstream
# openshell-driver-kubernetes's shared-mode Role (deploy/helm/openshell/
# templates/role.yaml at the pinned tag), plus the Kyma layer's APIRule
# exposure when enabled. scripts/check-chart-render.sh asserts both.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "openshell-driver-kyma.fullname" . }}
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
rules:
  {{- if .Values.driver.allowDriverConfig }}
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get"]
  {{- end }}
  - apiGroups: ["agents.x-k8s.io"]
    resources: ["sandboxes", "sandboxes/status"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete", "get", "list", "patch", "watch"]
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["create", "get"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["create", "get"]
  {{- if .Values.driver.enableApirule }}
  # Kyma layer: server-side apply of the exposure Service, NetworkPolicy and
  # APIRule, and a Warning Event when exposure fails.
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["patch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["patch"]
  - apiGroups: ["gateway.kyma-project.io"]
    resources: ["apirules"]
    verbs: ["create", "get", "patch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create"]
  {{- end }}
{{- end }}
```

Make `rolebinding.yaml`'s condition match (`eq .Values.driver.workspaceMode "shared"`).

- [ ] **Step 3: Create `templates/clusterrole.yaml` and its binding**

```yaml
{{- $mode := .Values.driver.workspaceMode }}
# Cluster-scoped rights for the driver: upstream openshell-driver-kubernetes's
# ClusterRole (deploy/helm/openshell/templates/clusterrole.yaml at the pinned
# tag), plus the Kyma layer's needs in the multi-namespace modes.
# scripts/check-chart-render.sh asserts both.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "openshell-driver-kyma.fullname" . }}-driver-{{ .Release.Namespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
rules:
  - apiGroups: ["node.k8s.io"]
    resources: ["runtimeclasses"]
    verbs: ["get"]
  - apiGroups: ["scheduling.k8s.io"]
    resources: ["priorityclasses"]
    verbs: ["get"]
  {{- if and (ne $mode "shared") .Values.driver.allowDriverConfig }}
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get"]
  {{- end }}
  # The driver authenticates sandbox bootstrap credentials itself.
  - apiGroups: ["authentication.k8s.io"]
    resources: ["tokenreviews"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs:
      - get
      {{- if ne $mode "shared" }}
      - list
      - watch
      {{- end }}
      {{- if eq $mode "managed" }}
      - create
      - delete
      {{- if .Values.driver.workspacePsaLevel }}
      - patch
      {{- end }}
      {{- end }}
  {{- if ne $mode "shared" }}
  - apiGroups: ["agents.x-k8s.io"]
    resources: ["sandboxes", "sandboxes/status"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete", "get", "list", "patch", "watch"]
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["create", "get"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["create", "get"]
  {{- end }}
  {{- if eq $mode "managed" }}
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "delete"]
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    verbs: ["create", "get"]
  {{- if .Values.networkPolicy.enabled }}
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["get", "create", "patch", "update"]
  {{- end }}
  {{- end }}
  {{- if and (ne $mode "shared") .Values.driver.enableApirule }}
  # Kyma layer: APIRule exposure in whichever namespace a sandbox lives.
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["patch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["patch"]
  - apiGroups: ["gateway.kyma-project.io"]
    resources: ["apirules"]
    verbs: ["create", "get", "patch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create"]
  {{- end }}
```

`templates/clusterrolebinding.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ include "openshell-driver-kyma.fullname" . }}-driver-{{ .Release.Namespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ include "openshell-driver-kyma.fullname" . }}-driver-{{ .Release.Namespace }}
subjects:
  - kind: ServiceAccount
    name: {{ include "openshell-driver-kyma.serviceAccountName" . }}
    namespace: {{ .Release.Namespace }}
```

The managed-mode `networkpolicies` update rule is gated on `networkPolicy.enabled` exactly as upstream gates it; the render check's managed render uses the default (`true`).

```bash
git rm -q deploy/helm/openshell-driver-kyma/templates/clusterrole-tokenreview.yaml \
          deploy/helm/openshell-driver-kyma/templates/clusterrole-nodes.yaml \
          deploy/helm/openshell-driver-kyma/templates/clusterrole-workspaces.yaml
```

- [ ] **Step 4: Remove the chart's sandbox NetworkPolicy**

In `templates/networkpolicy.yaml`, delete the second document (the `-sandbox` NetworkPolicy selecting `openshell.ai/managed-by: openshell`) and its `---` separator, and replace the header line `# Sandbox pods are governed by a separate NetworkPolicy below.` with:

```yaml
# Sandbox pods are fenced by upstream's own per-namespace NetworkPolicies
# (openshell-sandbox-workloads, openshell-sandbox-supervisors). The chart must
# not select them: NetworkPolicies are additive, so any policy here would widen
# upstream's fence. scripts/check-chart-render.sh enforces this.
```

The driver+gateway policy stays; its ingress has no `from` restriction on the gateway ports, so supervisor pods still reach the gateway.

- [ ] **Step 5: Run the checks**

Run: `./scripts/check-chart-render.sh && helm lint deploy/helm/openshell-driver-kyma && ./scripts/check-gateway-config.sh`
Expected: `CHART_RENDER_OK`, lint passes, `GATEWAY_CONFIG_ACCEPTED`.

- [ ] **Step 6: Commit**

```bash
git add -A deploy scripts/check-chart-render.sh
git commit -m "feat(chart)!: mirror upstream's driver RBAC; stop widening its fence

RBAC now matches upstream's chart for every workspace mode, plus the Kyma
layer's APIRule rights only when exposure is on. The chart's own sandbox
NetworkPolicy is removed: it selected upstream's workload pods and, because
NetworkPolicies are additive, granted them egress upstream's fence denies.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Providers — upstream's profile model replaces `inference set`

`openshell inference set` does not exist in the v0.1.2 CLI; providers are profiles now. A profile declares the endpoint host the credential is injected for and a `binaries` allowlist. Upstream's gateway default profile source is already `user`, so the gateway TOML needs no change.

**Files:**
- Create: `deploy/helm/openshell-driver-kyma/templates/inference-provider-profile.yaml`
- Modify: `templates/inference-provider-hook.yaml`, `templates/_inference-provider-guards.tpl`, `templates/_driver-env.tpl` (the `sandboxEnv` helper), `values.yaml` (`inferenceProvider:` block), `scripts/check-chart-render.sh`

**Interfaces:**
- Consumes: `.Values.upstream.version` (Task 7); helper `openshell-driver-kyma.sandboxEnv` (Task 7).
- Produces: ConfigMap `<fullname>-inference-profile` with key `profile.yaml`; values `inferenceProvider.profileId`, `inferenceProvider.binaries`; check 7 in `check-chart-render.sh`.

- [ ] **Step 1: Confirm the v0.1.2 CLI's exact flags**

```bash
docker run --rm --platform linux/amd64 alpine:3.20 sh -c '
  apk add -q --no-cache curl ca-certificates >/dev/null
  curl -fsSL https://github.com/NVIDIA/OpenShell/releases/download/v0.1.2/openshell-x86_64-unknown-linux-musl.tar.gz | tar -xz -C /usr/local/bin
  for c in "provider profile lint" "provider profile import" "provider profile update" "provider create" "provider update"; do
    echo "=== openshell $c --help"; openshell $c --help
  done'
```

The hook script in Step 5 assumes: `provider profile lint -f FILE`, `provider profile import -f FILE --global`, `provider profile update -f FILE --global`, `provider create --name NAME --type PROFILE_ID --credential ENV_KEY --global`, `provider update NAME --credential ENV_KEY`, and the global `--gateway-endpoint URL`. Where the help output differs, use the help's spelling in Step 5 and say so in the report.

- [ ] **Step 2: Extend the render check (failing first)**

In `scripts/check-chart-render.sh`, add a render before the `python3` call:

```bash
helm template t "$CHART" --set gateway.enabled=true --set inferenceProvider.enabled=true \
	--set inferenceProvider.type=anthropic \
	--set inferenceProvider.baseUrl=http://gateway.llm.svc.cluster.local:8080/anthropic \
	--set inferenceProvider.modelId=claude-opus-4-7 \
	--set inferenceProvider.credentialSecret.name=creds \
	--set inferenceProvider.credentialSecret.key=api-key >"$WORK/rbac-inference.yaml"
```

and to the Python block, before the failure report:

```python
# 7. providers use upstream's profile model, the pinned CLI, and reach sandboxes
if "openshell inference" in templates or "inference set" in templates:
    failures.append("templates still call the removed `openshell inference` command")
inference = docs(work / "rbac-inference.yaml")
profile_cm = next((d for d in inference if d.get("kind") == "ConfigMap"
                   and "profile.yaml" in d.get("data", {})), None)
if profile_cm is None:
    failures.append("no provider profile ConfigMap rendered")
else:
    profile = yaml.safe_load(profile_cm["data"]["profile.yaml"])
    endpoint = profile["endpoints"][0]
    if (endpoint["host"], endpoint["port"]) != ("gateway.llm.svc.cluster.local", 8080):
        failures.append(f"profile endpoint {endpoint} does not match inferenceProvider.baseUrl")
    if "/usr/bin/node" not in profile["binaries"]:
        failures.append("profile binaries must include node, which runs claude-code")
job = next(d for d in inference if d.get("kind") == "Job")
job_env = {e["name"]: e.get("value") for e in job["spec"]["template"]["spec"]["containers"][0].get("env", [])}
if job_env.get("CLI_VERSION") != pinned:
    failures.append(f"hook CLI_VERSION={job_env.get('CLI_VERSION')!r}, expected the pinned {pinned!r}")
driver_env = {e["name"]: e.get("value") for e in driver_container(inference).get("env", [])}
sandbox_env = driver_env.get("OPENSHELL_KYMA_SANDBOX_ENV", "")
for wanted in ("ANTHROPIC_BASE_URL=http://gateway.llm.svc.cluster.local:8080/anthropic",
               "ANTHROPIC_MODEL=claude-opus-4-7"):
    if wanted not in sandbox_env.split(","):
        failures.append(f"sandboxes do not receive {wanted}")
```

Move the `pinned = …` line (check 6) above check 7 if it is not already. Run: `./scripts/check-chart-render.sh` — expected FAIL on check 7.

- [ ] **Step 3: Values and guards**

In `values.yaml` `inferenceProvider:`, add (keep existing keys and comments; update the block's description to the profile model):

```yaml
  # Provider profile id registered with the gateway. Empty = "kyma-<type>".
  profileId: ""
  # Processes allowed to reach the inference endpoint through the sandbox
  # supervisor. claude-code runs under node, so node must be listed; add the
  # interpreter of any other SDK your sandbox image uses.
  binaries:
    - /usr/bin/node
    - /usr/local/bin/node
    - /usr/bin/claude
    - /usr/local/bin/claude
```

In `templates/_inference-provider-guards.tpl`, inside the `if .Values.inferenceProvider.enabled` block, add:

```yaml
{{- if ne .Values.inferenceProvider.type "anthropic" -}}
{{- fail (printf "inferenceProvider.type %q is not supported: the chart ships a provider profile for \"anthropic\" only." .Values.inferenceProvider.type) -}}
{{- end -}}
```

and add to `_helpers.tpl`:

```yaml
{{- define "openshell-driver-kyma.inferenceProfileId" -}}
{{- default (printf "kyma-%s" .Values.inferenceProvider.type) .Values.inferenceProvider.profileId -}}
{{- end -}}

{{- define "openshell-driver-kyma.inferenceProviderName" -}}
{{- default (printf "%s-%s" .Release.Name .Values.inferenceProvider.type) .Values.inferenceProvider.name -}}
{{- end -}}
```

(If the hook already defines the provider-name default inline, replace that with the helper.)

- [ ] **Step 4: Render the profile**

Create `templates/inference-provider-profile.yaml`:

```yaml
{{- if .Values.inferenceProvider.enabled }}
{{- $url := urlParse .Values.inferenceProvider.baseUrl }}
{{- $hostPort := splitList ":" $url.host }}
{{- $host := first $hostPort }}
{{- $port := ternary (last $hostPort) (ternary "443" "80" (eq $url.scheme "https")) (eq (len $hostPort) 2) }}
# Provider profile for upstream's profile model. The endpoint is the inference
# proxy the sandbox actually calls (inferenceProvider.baseUrl), not
# api.anthropic.com: the supervisor injects the credential only for requests
# to this host, and only from the processes in `binaries`.
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "openshell-driver-kyma.fullname" . }}-inference-profile
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
data:
  profile.yaml: |
    id: {{ include "openshell-driver-kyma.inferenceProfileId" . }}
    display_name: Anthropic via {{ $host }}
    description: Anthropic inference through the cluster's inference proxy
    category: inference
    inference_capable: true
    credentials:
      - name: api_key
        description: Anthropic API key
        env_vars: [ANTHROPIC_API_KEY]
        required: true
        auth_style: header
        header_name: x-api-key
    discovery:
      credentials: [api_key]
    endpoints:
      - host: {{ $host }}
        port: {{ $port }}
        protocol: rest
        access: read-write
        enforcement: enforce
    binaries: {{ toJson .Values.inferenceProvider.binaries }}
{{- end }}
```

- [ ] **Step 5: Rewrite the hook's configuration steps**

In `templates/inference-provider-hook.yaml`:

- set `CLI_VERSION`'s value to `{{ .Values.upstream.version | quote }}` (it is hard-coded `"v0.0.91"` today — that rot is why the hook broke);
- add env `PROFILE_ID` = `{{ include "openshell-driver-kyma.inferenceProfileId" . | quote }}` and make `PROVIDER_NAME` use `openshell-driver-kyma.inferenceProviderName`;
- mount the profile ConfigMap: add a `volumes` entry `{name: profile, configMap: {name: <fullname>-inference-profile}}` and a `volumeMounts` entry `{name: profile, mountPath: /profile, readOnly: true}` on the hook container;
- replace every shell step after "wait for the gateway to be reachable" (the old `provider create/update` and `inference set` steps) with:

```sh
                # 4. Register the provider profile (upstream's profile model;
                #    `openshell inference set` no longer exists). Idempotent:
                #    import, or update when it already exists.
                echo "[hook] validating provider profile ${PROFILE_ID}..."
                openshell --gateway-endpoint "${GATEWAY_URL}" provider profile lint -f /profile/profile.yaml
                echo "[hook] registering provider profile ${PROFILE_ID}..."
                if ! openshell --gateway-endpoint "${GATEWAY_URL}" provider profile import -f /profile/profile.yaml --global; then
                  echo "[hook] import failed (likely already present); updating"
                  openshell --gateway-endpoint "${GATEWAY_URL}" provider profile update -f /profile/profile.yaml --global
                fi

                # 5. Create the provider from that profile with the API key.
                #    The CLI reads ANTHROPIC_API_KEY from this container's env.
                echo "[hook] configuring provider ${PROVIDER_NAME}..."
                if openshell --gateway-endpoint "${GATEWAY_URL}" provider create \
                     --name "${PROVIDER_NAME}" --type "${PROFILE_ID}" \
                     --credential ANTHROPIC_API_KEY --global; then
                  echo "[hook] provider created"
                else
                  echo "[hook] provider create failed (likely AlreadyExists); updating"
                  openshell --gateway-endpoint "${GATEWAY_URL}" provider update "${PROVIDER_NAME}" \
                    --credential ANTHROPIC_API_KEY
                fi
                echo "[hook] done. Create sandboxes with: openshell sandbox create --provider ${PROVIDER_NAME} ..."
```

Remove the `MODEL_ID` env var from the hook (the model reaches sandboxes through `ANTHROPIC_MODEL`, Step 6). Rewrite the file's header comment to describe the profile flow instead of `inference set`.

- [ ] **Step 6: Give sandboxes the endpoint and model**

In `templates/_driver-env.tpl`, replace the `openshell-driver-kyma.sandboxEnv` helper body with:

```yaml
{{- define "openshell-driver-kyma.sandboxEnv" -}}
{{- $env := .Values.driver.sandboxEnv -}}
{{- if .Values.inferenceProvider.enabled -}}
{{- $env = concat $env (list
      (printf "ANTHROPIC_BASE_URL=%s" .Values.inferenceProvider.baseUrl)
      (printf "ANTHROPIC_MODEL=%s" .Values.inferenceProvider.modelId)) -}}
{{- end -}}
{{- join "," $env -}}
{{- end -}}
```

- [ ] **Step 7: Verify, including a real lint of the rendered profile**

Run: `./scripts/check-chart-render.sh && helm lint deploy/helm/openshell-driver-kyma`
Expected: `CHART_RENDER_OK`; lint passes.

Lint the rendered profile with the real v0.1.2 CLI (stage it under `$HOME`, which Docker Desktop shares):

```bash
mkdir -p "$HOME/.cache/oscheck"
helm template t deploy/helm/openshell-driver-kyma --set gateway.enabled=true \
  --set inferenceProvider.enabled=true --set inferenceProvider.type=anthropic \
  --set inferenceProvider.baseUrl=http://gateway.llm.svc.cluster.local:8080/anthropic \
  --set inferenceProvider.modelId=claude-opus-4-7 \
  --set inferenceProvider.credentialSecret.name=creds --set inferenceProvider.credentialSecret.key=api-key \
  --show-only templates/inference-provider-profile.yaml \
  | python3 -c 'import sys,yaml; print(yaml.safe_load(sys.stdin)["data"]["profile.yaml"])' \
  > "$HOME/.cache/oscheck/profile.yaml"
docker run --rm --platform linux/amd64 -v "$HOME/.cache/oscheck:/p:ro" alpine:3.20 sh -c '
  apk add -q --no-cache curl ca-certificates >/dev/null
  curl -fsSL https://github.com/NVIDIA/OpenShell/releases/download/v0.1.2/openshell-x86_64-unknown-linux-musl.tar.gz | tar -xz -C /usr/local/bin
  openshell provider profile lint -f /p/profile.yaml'
rm -rf "$HOME/.cache/oscheck"
```

Expected: lint reports the profile valid. If lint rejects a field, fix the template and repeat. If `lint` needs a gateway connection, report that and skip this step — Task 13 exercises the profile against the live gateway.

- [ ] **Step 8: Commit**

```bash
git add -A deploy scripts/check-chart-render.sh
git commit -m "feat(chart)!: configure inference through upstream's provider profiles

\`openshell inference set\` is gone in v0.1.2. The hook now registers a
chart-rendered provider profile whose endpoint is the configured inference
proxy and whose binaries allowlist covers claude-code's node process, then
creates the provider from it, using the CLI of the pinned upstream release.
Sandboxes receive ANTHROPIC_BASE_URL and ANTHROPIC_MODEL.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Weekly sync and Dependabot follow the upstream pin

**Files:**
- Modify: `.github/workflows/upstream-sync.yml` (the `sync` job), `.github/dependabot.yml`

**Interfaces:**
- Consumes: `make upstream-bump TAG=…` (Task 2); `SANDBOX_RUNTIME_IMAGE`, `SUPERVISOR_IMAGE`, `GATEWAY_IMAGE` from `resolve-upstream-refs.sh` (Task 2); `scripts/check-chart-render.sh` (Tasks 7–9).

- [ ] **Step 1: Stop Dependabot from moving the Kubernetes stack**

In `.github/dependabot.yml`, in the `package-ecosystem: "cargo"` entry, add (merging with any existing `ignore:` list):

```yaml
    # kube and k8s-openapi follow upstream NVIDIA/OpenShell's versions, because
    # the driver links upstream's Kubernetes driver; the openshell-* git
    # dependencies move with `make upstream-bump`. Never bump these here.
    ignore:
      - dependency-name: "kube"
      - dependency-name: "kube-runtime"
      - dependency-name: "k8s-openapi"
      - dependency-name: "openshell-*"
```

- [ ] **Step 2: Rewrite the sync job's instructions**

In `.github/workflows/upstream-sync.yml`, `sync` job:

- in the `Set proto contract target tag` step, change every `make proto-vendor TAG=<...>` in its error text to `make upstream-bump TAG=<...>`, and every mention of `check-proto-drift.sh` to `check-upstream-pin.sh`;
- in the `Let Claude perform the sync` step's prompt, replace the numbered instruction that begins `1. Re-vendor the protos with \`make proto-vendor TAG=${{ env.PROTO_TARGET_TAG }}\`` together with its continuation lines (the `NEVER hand-edit anything under proto/ …` sentence) by:

```text
            1. Move the driver to the new upstream release with
               `make upstream-bump TAG=${{ env.PROTO_TARGET_TAG }}`. It rewrites the three
               openshell-* git dependencies, refreshes Cargo.lock, and prints any diff in
               upstream's option surface. Mirror that diff into
               crates/openshell-driver-kyma/src/upstream_args.rs exactly — the two guarded
               blocks must stay byte-identical to upstream (scripts/check-upstream-args.sh).
            2. Update the chart to the same release: values.yaml `upstream.version`,
               `driver.supervisorImage` (use $SUPERVISOR_IMAGE), `driver.sandboxRuntimeImage`
               (use $SANDBOX_RUNTIME_IMAGE) and the gateway image digest (use $GATEWAY_IMAGE).
            3. Compare upstream's deploy/helm/openshell/templates/role.yaml and clusterrole.yaml
               between the old and new tags. Mirror any change into this chart's role.yaml and
               clusterrole.yaml and into the WORKLOAD/CLUSTER lists in
               scripts/check-chart-render.sh.
            4. Verify: `make fmt && make test`, `./scripts/check-chart-render.sh`,
               `./scripts/check-gateway-config.sh`.
```

  and renumber the remaining items of that list after these four;
- in the PR-body table, change the row label `Proto pin before this sync` to `Upstream pin before this sync` (keep `${PINNED_PROTO_REF}`).

Keep the `PROTO_TARGET_TAG` and `PINNED_PROTO_REF` variable names: they are wired through job outputs, and renaming them buys nothing.

- [ ] **Step 3: Verify**

Run: `python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/upstream-sync.yml")); yaml.safe_load(open(".github/dependabot.yml"))' && echo YAML_OK`
Expected: `YAML_OK`.

Run: `grep -nE 'proto-vendor|check-proto-drift|NEVER hand-edit anything under proto' .github/workflows/upstream-sync.yml || echo CLEAN`
Expected: `CLEAN`.

Confirm the `upstream-sync.yml triggers stay locked down` guard still holds: the file's `on:` block is unchanged (`schedule` + `workflow_dispatch` only).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/upstream-sync.yml .github/dependabot.yml
git commit -m "ci: weekly sync moves the upstream pin; Dependabot leaves kube alone

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Smokes reach pod Ready, bootstrap, and stop/start

The smokes stopped at "Sandbox CR created" because they installed only the agent-sandbox CRD with no controller. That is exactly how v0.8.0 shipped with sandboxes that could not start. They now install the pinned controller and follow a sandbox through its whole life.

**Files:**
- Modify: `scripts/interop-smoke.sh`, `scripts/managed-smoke.sh`, and the kind setup in `.github/workflows/interop-smoke.yml` (and the managed-smoke workflow, if separate) only if it pins a node image older than Kubernetes v1.30

**Interfaces:**
- Consumes: `SANDBOX_RUNTIME_IMAGE`, `SUPERVISOR_IMAGE` (resolve-upstream-refs.sh); chart values `driver.sandboxRuntimeImage`, `driver.supervisorImage`, `driver.workspacePsaLevel`.

- [ ] **Step 1: Install the agent-sandbox controller instead of a bare CRD**

In `scripts/interop-smoke.sh`, delete `CRD_URL`, the comment block explaining why the controller is deliberately not deployed, and the `curl … "$CRD_URL" | yq 'del(.spec.conversion)' | kubectl apply` step. Put in their place:

```bash
# The agent-sandbox controller turns Sandbox CRs into pods. Without it no
# sandbox ever starts, which is how v0.8.0 shipped with sandboxes that could
# not run while this smoke stayed green. Pinned by release and by hash.
AGENT_SANDBOX_VERSION=v0.5.2
AGENT_SANDBOX_SHA256=230ee446d6035f631577e1c6b857f6973a8f09a0a853675d3cc34ebfe47abd6b
log "installing agent-sandbox ${AGENT_SANDBOX_VERSION} (CRD + controller)"
curl -fsSL -o /tmp/agent-sandbox.yaml \
	"https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/sandbox.yaml" \
	|| fail "could not download agent-sandbox ${AGENT_SANDBOX_VERSION}"
echo "${AGENT_SANDBOX_SHA256}  /tmp/agent-sandbox.yaml" | sha256sum -c - >/dev/null \
	|| fail "agent-sandbox manifest does not match the pinned sha256"
kubectl apply -f /tmp/agent-sandbox.yaml || fail "could not install agent-sandbox"
kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=3m \
	|| fail "the agent-sandbox controller never became ready"
```

Do the same in `scripts/managed-smoke.sh`. If a workflow pins a kind node image older than v1.30.0, bump it to `kindest/node:v1.31.0` — upstream's supervisor pod uses pod scheduling gates, GA in 1.30.

- [ ] **Step 2: Pass the runtime image to the chart**

Next to the existing `: "${SUPERVISOR_IMAGE:?…}"`-style guard (add one if absent) require `SANDBOX_RUNTIME_IMAGE`, and add `--set driver.sandboxRuntimeImage="$SANDBOX_RUNTIME_IMAGE"` beside `--set driver.supervisorImage="$SUPERVISOR_IMAGE"` in both smokes' `helm install`.

- [ ] **Step 3: Assert what upstream's CR carries**

In interop-smoke's ASSERT 2, reduce the CR label loop to `openshell.ai/sandbox-id` and `openshell.ai/managed-by` — the labels upstream's driver sets. `kagenti.io/type` moves to the workload pod (next step), because hook 1 puts it on the sandbox template.

- [ ] **Step 4: Replace "Assertion 3b removed" with the runtime assertions**

Delete the `# --- Assertion 3b removed …` comment block and add, after ASSERT 3:

```bash
# osh sandbox list prints NAME CREATED PHASE; print the phase for one sandbox.
sandbox_phase() {
	osh sandbox list 2>/dev/null | awk -v n="$1" '$1 == n {print $NF}'
}
wait_phase() { # name phase timeout-seconds
	local deadline=$((SECONDS + $3))
	while ((SECONDS < deadline)); do
		[[ $(sandbox_phase "$1") == "$2" ]] && return 0
		sleep 5
	done
	return 1
}
wait_phase_not() { # name phase timeout-seconds
	local deadline=$((SECONDS + $3))
	while ((SECONDS < deadline)); do
		local p
		p=$(sandbox_phase "$1")
		[[ -n $p && $p != "$2" ]] && return 0
		sleep 5
	done
	return 1
}

log "ASSERT 3c: the sandbox runtime starts and bootstraps"
sid=$(kubectl -n "$NS" get sandbox "$cr" -o jsonpath='{.metadata.labels.openshell\.ai/sandbox-id}')
[[ -n $sid ]] || fail "Sandbox ${cr} has no openshell.ai/sandbox-id label"
pair=${sid,,}
kubectl -n "$NS" wait --for=condition=Ready "pod/os-supervisor-${pair}" --timeout=5m || {
	kubectl -n "$NS" describe pod "os-supervisor-${pair}" >&2 || true
	fail "supervisor pod os-supervisor-${pair} never became Ready"
}
kubectl -n "$NS" wait --for=condition=Ready pod \
	-l "openshell.ai/boundary-pair=${pair},openshell.ai/boundary-role=workload" --timeout=5m || {
	kubectl -n "$NS" get pods -l "openshell.ai/boundary-pair=${pair}" -o wide >&2 || true
	fail "the workload pod never became Ready"
}
wait_phase "$SB" Ready 300 || fail "gateway never reported ${SB} Ready: bootstrap did not complete (phase: $(sandbox_phase "$SB"))"

log "ASSERT 3d: Kyma enrichment reached the workload pod"
wl_labels=$(kubectl -n "$NS" get pod -l "openshell.ai/boundary-pair=${pair},openshell.ai/boundary-role=workload" \
	-o jsonpath='{.items[0].metadata.labels}')
grep -q '"sidecar.istio.io/inject":"false"' <<<"$wl_labels" || fail "workload pod lacks sidecar.istio.io/inject=false: ${wl_labels}"
grep -q '"kagenti.io/type":"agent"' <<<"$wl_labels" || fail "workload pod lacks kagenti.io/type=agent: ${wl_labels}"

log "ASSERT 3e: stop and start round-trip"
osh sandbox stop "$SB" || fail "stop ${SB} failed"
wait_phase_not "$SB" Ready 180 || fail "${SB} never left Ready after stop"
osh sandbox start "$SB" || fail "start ${SB} failed"
wait_phase "$SB" Ready 300 || fail "${SB} did not return to Ready after start (phase: $(sandbox_phase "$SB"))"
```

If the CLI prints phases in a different case or column than `NAME CREATED PHASE`, adjust `sandbox_phase` to the real output and say so in the report (print `osh sandbox list` once in the log for evidence).

- [ ] **Step 5: Managed smoke — same lifecycle, plus hook 3**

In `scripts/managed-smoke.sh`'s `helm install`, replace any `--set driver.gatewayId=…` with `--set gateway.sandboxJwt.gatewayId=…` (Task 7 removed `driver.gatewayId`), and add `--set driver.workspacePsaLevel=privileged` (a level that always admits, so this tests the labelling mechanism without depending on the PSA level Task 13 chooses). After its existing assertion that a sandbox was created in a managed namespace, add the same `sandbox_phase`/`wait_phase`/`wait_phase_not` helpers and ASSERT 3c–3e logic targeting that sandbox's namespace (the namespace variable the script already uses for the managed workspace), then:

```bash
log "ASSERT M-psa: the managed namespace carries the configured Pod Security level"
level=$(kubectl get namespace "$MANAGED_NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
[[ $level == privileged ]] || fail "managed namespace ${MANAGED_NS} has enforce='${level}', expected 'privileged'"
```

using the script's actual variable in place of `MANAGED_NS`.

- [ ] **Step 6: Lint the scripts**

Run: `bash -n scripts/interop-smoke.sh scripts/managed-smoke.sh && (command -v shellcheck >/dev/null && shellcheck scripts/interop-smoke.sh scripts/managed-smoke.sh || true)`
Expected: no syntax errors; no new shellcheck errors.

The smokes run in CI (kind); they are exercised for real in Task 13. Do not push to trigger them here.

- [ ] **Step 7: Commit**

```bash
git add scripts/interop-smoke.sh scripts/managed-smoke.sh .github/workflows
git commit -m "test(smoke): follow a sandbox to Ready, bootstrap, and stop/start

The smokes installed the agent-sandbox CRD with no controller, so no
sandbox ever started, and v0.8.0 shipped with sandboxes that could not run
while CI stayed green. They now install the pinned controller and assert
supervisor and workload pods Ready, bootstrap complete, enrichment applied,
a stop/start round-trip, and managed-namespace PSA labelling.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Docs, CHANGELOG and version 0.9.0

**Files:**
- Modify: `Cargo.toml` (workspace version), `deploy/helm/openshell-driver-kyma/Chart.yaml`, `CHANGELOG.md`, `README.md`, `docs/getting-started.md`, `docs/production-deployment.md`, `docs/kyma-vs-openshift.md`, `docs/superpowers/specs/2026-09-29-upstream-driver-parity-design.md` (status line)

- [ ] **Step 1: Bump the version**

Root `Cargo.toml` `[workspace.package] version = "0.9.0"`; `Chart.yaml` `version: 0.9.0` and `appVersion: "0.9.0"`. Run `make fmt && make test` so `Cargo.lock` picks up the new version, and include the lockfile in the commit.

- [ ] **Step 2: Write the CHANGELOG entry**

Add a `## [0.9.0]` section at the top of `CHANGELOG.md` (dated the day it is written) with these subsections, in this order:

- **UPGRADE NOTE (bold, first):** delete all existing sandboxes before upgrading. The pod topology changes (a separate supervisor pod per sandbox) and upstream's runtime identity replaces ours, so existing sandboxes cannot bootstrap. Remove the removed values below from your values file before `helm upgrade`.
- **Changed — architecture:** the driver is now upstream NVIDIA OpenShell v0.1.2's `openshell-driver-kubernetes` behind a thin Kyma layer; every RPC is upstream's; configuration mirrors upstream's options 1:1; sandboxes run upstream's hardened supervisor pod and isolation fence.
- **Values migration table** — two columns, old → new:

  | Removed / renamed | Now |
  |---|---|
  | `driver.supervisorBinaryPath`, `driver.supervisorMountPath` | removed — upstream's runtime owns the supervisor |
  | `driver.gpuSupport`, `driver.telemetryEnabled`, `driver.stopTimeoutSecs` | removed — upstream behaviour |
  | `driver.enableNetworkPolicy` | `networkPolicy.enabled` (driver+gateway pod only; sandboxes are fenced by upstream) |
  | `driver.operatorNamespaceAllowlist` | `driver.operatorNamespaceLabel` or `driver.operatorNamespaceConfigMap` |
  | `driver.driverConfigAllowVolumes` | `driver.allowDriverConfig` — caller volumes are now checked by upstream's resource admission |
  | `driver.gatewayId` | `gateway.sandboxJwt.gatewayId` — the gateway and driver now always share one id, as upstream's chart does |
  | `inferenceProvider` via `openshell inference set` | provider profiles; create sandboxes with `--provider <name>` |

- **Added:** every upstream option reachable from values (list the new `driver.*` keys from Task 7), `driver.sandboxEnv`, `driver.workspacePsaLevel`, `driver.ingressNamespace`, `inferenceProvider.profileId`/`binaries`, `upstream.version`.
- **Security:** the chart's own sandbox NetworkPolicy is removed — it widened upstream's workload fence. APIRule exposure (`driver.enableApirule`, off by default) is an explicit, documented exception admitting only the Istio ingress gateway to port 8080.
- **Fixed:** sandboxes run on upstream v0.1.2 again (v0.8.0 could not start them); the inference hook no longer uses a hard-coded v0.0.91 CLI.
- **CI:** `check-upstream-args.sh` and `check-chart-render.sh` keep the driver and chart at parity with upstream; the smokes now run the agent-sandbox controller and follow sandboxes to Ready, bootstrap and stop/start.
- **Removed:** `/metrics` on the driver health port (nothing scraped it; upstream traces over OTLP — set `driver.otlpEndpoint`).

- [ ] **Step 3: Update the docs**

Run: `grep -rnE 'supervisorBinaryPath|supervisorMountPath|gpuSupport|enableNetworkPolicy|operatorNamespaceAllowlist|driverConfigAllowVolumes|stopTimeoutSecs|telemetryEnabled|--istio-inject-sandboxes|--enable-apirule|--supervisor-image|inference set|/metrics|provisioner\.rs' README.md docs --include='*.md' | grep -vE 'docs/superpowers/|docs/upstream-prs/|docs/upstream-external-compute-driver-pr-body\.md'`

Update every hit to the v0.9.0 behaviour. Also, in `README.md` and `docs/kyma-vs-openshift.md`, replace any description of the driver's own provisioning/authentication internals with one paragraph: the driver runs upstream's Kubernetes driver unchanged and adds request enrichment, APIRule exposure and managed-namespace PSA labels. In `docs/getting-started.md`, describe sandbox creation with `--provider <name>` when an inference provider is configured. Leave historical CHANGELOG entries and the upstream-PR drafts alone.

In the spec, change `Status: approved (design), not yet implemented` to `Status: implemented in v0.9.0`.

- [ ] **Step 4: Verify**

Run: `make fmt && make test && ./scripts/check-chart-render.sh && helm lint deploy/helm/openshell-driver-kyma`
Expected: all PASS / `CHART_RENDER_OK`.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml Cargo.lock deploy/helm/openshell-driver-kyma/Chart.yaml CHANGELOG.md README.md docs
git commit -m "docs: v0.9.0 — upstream Kubernetes driver parity

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: GATED — pre-release, CI, and cluster verification

**Stop before Step 1 and ask the repo owner to approve: pushing the branch, opening a draft PR, tagging `v0.9.0-rc.1`, and redeploying the test cluster (which deletes its sandboxes).** Do not proceed on an earlier approval.

Pre-flight for every outward-facing step: `gh auth status` must show `st-gr` active (never the work account); `gh repo view --json visibility` is `PUBLIC`, so scan `git diff origin/main...HEAD` for tokens, keys, emails and cluster identifiers before pushing.

**Files:** whatever the verification findings require (expected: `values.yaml` defaults such as `driver.workspacePsaLevel` and `inferenceProvider.binaries`).

- [ ] **Step 1: Push and open a draft PR; wait for green CI**

```bash
git push -u origin feat/upstream-driver-parity
gh pr create --draft --base main --title "feat!: upstream Kubernetes driver parity (v0.9.0)" --body-file <(printf '%s\n\n%s\n' \
  "Implements docs/superpowers/specs/2026-09-29-upstream-driver-parity-design.md per docs/superpowers/plans/2026-09-29-upstream-driver-parity.md." \
  "🤖 Generated with [Claude Code](https://claude.com/claude-code)")
```

Wait until every check has concluded on the branch's HEAD commit (check the SHA; a stale run on an older commit does not count). All must pass, including both smokes. `managed workspace mode smoke` has a known ASSERT M2 flake: re-run once before investigating a single red run of that assertion; any other failure is investigated, not re-run.

- [ ] **Step 2: Cut the release candidate**

```bash
git tag -a v0.9.0-rc.1 -m "v0.9.0-rc.1 — upstream Kubernetes driver parity"
git push origin v0.9.0-rc.1
```

Wait for `release-tag.yml` to succeed, then resolve the driver image's index digest without pulling (the image is amd64-only): `docker buildx imagetools inspect ghcr.io/st-gr/openshell-driver-kyma:v0.9.0-rc.1` → the top-level `Digest:`.

- [ ] **Step 3: Drain and deploy**

```bash
kubectl get sandboxes.agents.x-k8s.io -A            # record what will be deleted
kubectl delete sandboxes.agents.x-k8s.io --all -n openshell-system
helm get values ods -n openshell-system -o yaml > /tmp/ods-values.yaml
```

Edit `/tmp/ods-values.yaml`: remove every key the Task 12 migration table lists as removed; remove any `driver.supervisorImage` and `gateway.image.tag` overrides so the chart's pinned v0.1.2 digests apply; set `image.tag` to `sha256:<rc digest>`. Never touch the `sail-proxy` or `openwebui` namespaces.

```bash
helm upgrade ods deploy/helm/openshell-driver-kyma -n openshell-system -f /tmp/ods-values.yaml --wait --timeout 8m
```

- [ ] **Step 4: Verify on the cluster, deciding with these rules**

a. **Driver and gateway:** pod `2/2 Ready`; gateway log shows `Compute driver connected`. Otherwise stop and report.

b. **Lifecycle:** create a sandbox with the v0.1.2 CLI from a throwaway in-cluster pod (as the v0.8.0 deploy did), confirm `os-supervisor-<id>` and the workload pod reach Ready, the CLI phase reaches `Ready`, then stop/start returns to `Ready`.

c. **PSA level for `driver.workspacePsaLevel`:** with the sandbox running, run `kubectl label --dry-run=server --overwrite ns openshell-system pod-security.kubernetes.io/enforce=restricted`, then the same with `baseline`. Choose the strictest level that prints **no** warning about the sandbox's supervisor or workload pod. Set that as the chart default for `driver.workspacePsaLevel` in `values.yaml` with a comment recording the evidence. Do not actually relabel `openshell-system`.

d. **Enrichment:** the workload pod has `sidecar.istio.io/inject=false` and `kagenti.io/type=agent`, and its spec's environment contains any `driver.sandboxEnv` value you set for the test. If the environment is missing, switch hook 1 to `spec.environment` (a one-line change in `enrich.rs` plus its tests) and repeat.

e. **APIRule exposure:** only if the owner supplies the cluster domain. Upgrade with `driver.enableApirule=true`, create a sandbox running `python3 -m http.server 8080`, and `curl -s -o /dev/null -w '%{http_code}' https://<cr-name>.<domain>/` → `200`. If it is blocked, inspect the exposure Service's endpoints and the NetworkPolicies selecting the workload; fix inside the Kyma layer only, never by editing upstream's policies. The domain must not be written into any file.

f. **Provider:** with `inferenceProvider` enabled as it was before (sail-proxy base URL, existing credential Secret), confirm the hook Job succeeds. Then create a sandbox from the sandbox-claude image with `--provider <name>` and run `claude -p "reply with ok"`. If the request is denied, read the supervisor pod's log for the denied executable path, add it to `inferenceProvider.binaries` in `values.yaml`, and repeat.

- [ ] **Step 5: Commit the findings and re-verify**

Commit the value changes from Step 4 (for example `fix(chart): default workspacePsaLevel to <level>; allow <path> to reach the provider`), with the evidence in the message body — never the cluster domain or any cluster identifier. Push, and wait for CI to be green again on the new HEAD.

---

### Task 14: GATED — merge, release v0.9.0, deploy

**Stop and ask the repo owner to approve merging PR, tagging `v0.9.0`, and redeploying.**

- [ ] **Step 1: Merge**

Mark the PR ready, confirm every check is green on HEAD, and squash-merge with subject `feat!: upstream Kubernetes driver parity (#<n>)` and a body summarising the CHANGELOG entry, ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Sync local `main` to `origin/main`.

- [ ] **Step 2: Release**

```bash
git fetch origin --prune --tags
git tag -a v0.9.0 origin/main -m "v0.9.0 — upstream Kubernetes driver parity"
git push origin v0.9.0
```

Wait for `release-tag.yml` to succeed; resolve the `v0.9.0` driver index digest as in Task 13.

- [ ] **Step 3: Deploy and re-verify**

`helm upgrade` the cluster to the merged chart with `image.tag=sha256:<v0.9.0 digest>`, then repeat Task 13 Step 4 (a), (b) and (f). Report the result.

---

## Self-Review Notes

- Spec coverage: architecture and forwarding (Task 1); flag parity and drift guard (Tasks 1–2, 7); hooks 1–3 (Tasks 3, 5, 6); health (Task 4); chart RBAC and admission coupling (Tasks 7–8); fence integrity (Task 8); providers (Task 9); dependency tracking (Tasks 2, 10); smokes to pod Ready (Task 11); release and rollout (Tasks 12–14); risks — APIRule versus fence (Tasks 5, 8, 13e), library API drift (Task 2), PSA level (Tasks 6, 13c), build time (accepted).
- Deliberately not built: a delete hook (owner references garbage-collect exposure objects); a policy evaluator for caller volumes (upstream's resource admission now does it); upstream's gateway chart.
