# openshell-driver-kyma — Implementation Plan

## Context

Build a Rust implementation of the OpenShell `ComputeDriver` gRPC contract that
runs on SAP BTP Kyma clusters. The driver is wire-compatible with the upstream
OpenShell gateway and provisions agent sandboxes as
`agents.x-k8s.io/v1alpha1/Sandbox` CRDs.

**Why this change.** OpenShell ships compute drivers for Docker, Podman, VM,
and vanilla Kubernetes, plus a community Go driver for OpenShift. Nothing
exists for SAP BTP Kyma, so OpenShell can't currently run there. The user
wants to use OpenShell on their existing Kyma cluster without forking
NVIDIA's Rust workspace and without disturbing existing workloads in
sensitive namespaces (`your-llm-gateway`, `<other-namespace>`, etc.).

**Reference and approach.** Mirror the structure of the Go OpenShift driver
at `github.com/zanetworker/openshell-driver-openshift` (cloned to
`C:/tmp-bwx/openshell-driver-kyma/reference-openshift/`). Same trait layout
(`SandboxProvisioner` / `PlatformEnricher` / `DriverMetrics`), same 8 gRPC
RPCs, same 3-tier test pyramid, ported to Rust with `tonic`, `kube-rs`,
`prost`, `axum`. Adapt for Kyma: Pod Security Admission instead of OpenShift
SCC, configurable Istio sidecar injection, optional Kyma `APIRule`
(`gateway.kyma-project.io/v2`), Helm chart, GitHub Actions CI matching
NVIDIA OpenShell's pragmatic level (DCO, branch-checks, helm-lint, GHCR
image build — no cosign / Trivy / SBOM gates).

**Approved spec:** `C:/tmp-bwx/openshell-driver-kyma/docs/superpowers/specs/2026-05-26-openshell-driver-kyma-design.md`

**Hard constraints.**
- **Isolation.** Driver writes/reads stay namespace-scoped. Tier-3 tests
  refuse to run against any system namespace; deny-list is extensible at
  runtime via `INTEGRATION_TEST_NAMESPACE_DENYLIST` env var so the user can
  protect `your-llm-gateway`, `<other-namespace>`, etc. without committing those names.
- **Privacy.** No cluster IDs, IPs, OIDC issuers, or namespace names beyond
  generic examples land in any committed file.
- **Security baseline.** Driver pod fits PSS `restricted`. Sandbox pods need
  `privileged` PSA on their namespace (cluster-admin's responsibility — the
  driver checks and fails fast, never sets the label itself).

**Tech stack.** Rust (edition 2021, toolchain 1.83.0); `tonic` 0.14, `prost`
0.14, `kube` (0.96 baseline — engineer to verify with `cargo search` at
install time; if 3.x exists, upgrade in one focused commit), `k8s-openapi`
0.27, `tokio` 1.x, `axum` 0.8, `prometheus` 0.14, `clap` 4, `tracing` 0.1,
`thiserror` 2, `anyhow` 1, `mockall` 0.13, `tower-test` 0.4. Proto codegen
via `tonic-prost-build` 0.14 (note: not the older `tonic-build`).

## Approach

A standalone Cargo workspace with two crates:

- `crates/computev1` — generated `tonic` + `prost` code from the vendored
  `proto/compute_driver.proto`. Compiled by `build.rs` so the generated code
  never lands in git.
- `crates/openshell-driver-kyma` — binary + library. Modules: `config`,
  `error`, `interfaces`, `helpers`, `provisioner`, `enricher`, `metrics`,
  `driver`, `main`.

Three traits in `interfaces.rs`:

- `SandboxProvisioner` — Sandbox CR lifecycle (Create/Get/List/Delete/Watch)
  + GPU validation. Implemented by `KymaProvisioner` (uses `kube-rs`
  `DynamicObject` + `Api::namespaced_with`).
- `PlatformEnricher` — Kyma-specific behaviors. Implemented by
  `KymaEnricher`: Istio injection toggle, PSA detection (fail-fast),
  optional APIRule rendering.
- `DriverMetrics` — Prometheus counters/histograms; bounded label
  cardinality.

The `Driver` struct holds `Arc<dyn ...>` of all three and implements
`compute_driver_server::ComputeDriver`. Same dependency-injection pattern as
the Go reference — keeps unit tests synthetic and the binary's wiring in one
place (`main.rs`).

Tonic listens on a Unix domain socket; `axum` on a separate TCP port serves
`/healthz`, `/readyz`, `/metrics`. Both share graceful shutdown on SIGTERM.

For each Sandbox CR we POST a pod template containing an init container that
copies the supervisor binary into an `emptyDir`, then the agent container
runs that copy. Same approach as the Go OpenShift driver — avoids `hostPath`
which Kyma's `restricted` PSS would block on the sandbox namespace if it
weren't labeled `privileged`.

## File patterns

| Pattern | Representative paths |
|---|---|
| Per-module source + colocated `mod tests` | `crates/openshell-driver-kyma/src/{config,error,helpers,interfaces,provisioner,enricher,metrics,driver}.rs` |
| Tier-2 / Tier-3 integration tests | `crates/openshell-driver-kyma/tests/{grpc_contract,live_cluster,common/{mod,kube_mock}}.rs` |
| Helm chart templates | `deploy/helm/openshell-driver-kyma/templates/{serviceaccount,role,rolebinding,clusterrole-nodes,deployment,service,networkpolicy,pre-install-crd-check}.yaml` |
| GitHub Actions workflows | `.github/workflows/{branch-checks,dco,helm-lint,docker-build,release-tag}.yml` |
| Repo hygiene | `{LICENSE,README.md,CONTRIBUTING.md,SECURITY.md,CHANGELOG.md,THIRD-PARTY-NOTICES,Makefile,Cargo.toml,rust-toolchain.toml,.gitignore,.dockerignore,.markdownlint-cli2.jsonc}` |
| Adapted docs | `docs/{why-init-container,kyma-vs-openshift,istio-considerations}.md` |

## Conventions

- **Mocks.** `kube::Client` is built from `tower_test::mock::pair()` so we
  assert outgoing HTTP without a real apiserver. Helper in
  `tests/common/kube_mock.rs`. Trait mocks via `#[cfg_attr(test,
  mockall::automock)]` on each trait in `interfaces.rs`.
- **Tests.** Unit tests live in `mod tests` blocks colocated with each
  source file (Rust idiom; mirrors Go's `_test.go` in the reference).
- **Commits.** Every commit signed (`git commit -s`) for DCO. Conventional
  Commit subjects: `feat(scope): ...`, `test(scope): ...`, `build(...)`,
  `chore: ...`, `docs: ...`, `ci: ...`.

## Implementation tasks

41 tasks grouped A–P. Tasks follow strict TDD where it applies; pure
scaffolding tasks (Cargo manifests, Dockerfiles, Helm templates, GitHub
Actions, docs) use a non-TDD shape but always include explicit verification.
All paths absolute relative to `C:/tmp-bwx/openshell-driver-kyma/` (`<repo>/`
below).

### Task 1 — Repo skeleton

**Create:** `<repo>/.gitignore`, `.dockerignore`, `LICENSE`, `README.md` (skeleton), `THIRD-PARTY-NOTICES`.
- `git init -b main` in `<repo>/`.
- `.gitignore` covers `target/`, `*.sock`, `kubeconfig*`, `.env*`, `.idea/`, `.vscode/`, `*.swp`, `dist/`, `*.tgz`, `coverage/`. Note: `Cargo.lock` IS committed.
- `.dockerignore` covers `target/`, `.git/`, `.github/`, `tests/`, `docs/`, `deploy/Dockerfile.dev`, `*.md`, `Makefile`.
- `LICENSE`: verbatim Apache-2.0.
- `README.md`: skeleton (Title, one-paragraph desc, "Status: Phase 1", link to spec). Full README in Task 38.
- `THIRD-PARTY-NOTICES`: header + "Generated at release time."
- Commit: `chore: initialize repo skeleton with Apache-2.0 license`.

### Task 2 — Cargo workspace + toolchain pin

**Create:** `<repo>/Cargo.toml`, `rust-toolchain.toml`.
- Workspace declares `resolver = "2"`, members `["crates/computev1", "crates/openshell-driver-kyma"]`, `[workspace.package]` (edition 2021, version 0.1.0, license Apache-2.0).
- `[workspace.dependencies]` with all pinned versions: `tonic = "0.14"`, `prost = "0.14"`, `prost-types = "0.14"`, `kube = { version = "0.96", default-features = false, features = ["client", "runtime", "derive", "rustls-tls"] }`, `k8s-openapi = { version = "0.27", features = ["latest"] }`, `tokio = { version = "1", features = ["full"] }`, `axum = "0.8"`, `prometheus = "0.14"`, `clap = { version = "4", features = ["derive"] }`, `thiserror = "2"`, `tracing = "0.1"`, `tracing-subscriber = { version = "0.3", features = ["json", "env-filter"] }`, `futures = "0.3"`, `tokio-stream = { version = "0.1", features = ["net"] }`, `anyhow = "1"`, `serde = { version = "1", features = ["derive"] }`, `serde_json = "1"`, `serde_yaml = "0.9"`, `async-trait = "0.1"`, `mockall = "0.13"`, `tower = "0.5"`, `tower-test = "0.4"`, `http = "1"`, `http-body-util = "0.1"`.
- `rust-toolchain.toml`: `channel = "1.83.0"`, `components = ["rustfmt", "clippy"]`.
- Verify: `cargo metadata --no-deps --format-version 1 > /dev/null` exits 0 (after empty crate stubs).
- Commit: `build: scaffold Cargo workspace with pinned toolchain`.

### Task 3 — Vendor proto

**Create:** `<repo>/proto/compute_driver.proto`.
- Copy byte-for-byte from `reference-openshift/proto/compute_driver.proto`. Preserve the SPDX header verbatim (legal hook for the vendored file).
- Record `sha256sum` in commit body for traceability.
- Commit: `vendor: import openshell compute_driver.proto from upstream`.

### Task 4 — `crates/computev1` codegen

**Create:** `crates/computev1/{Cargo.toml, build.rs, src/lib.rs}`.
- `Cargo.toml`: deps `tonic`, `prost`, `prost-types` from workspace; build-dep `tonic-prost-build = "0.14"`.
- `build.rs`:
  ```rust
  fn main() -> Result<(), Box<dyn std::error::Error>> {
      tonic_prost_build::configure()
          .build_server(true)
          .build_client(true)
          .compile_protos(&["../../proto/compute_driver.proto"], &["../../proto"])?;
      Ok(())
  }
  ```
- `src/lib.rs`:
  ```rust
  #![allow(clippy::all, clippy::pedantic)]
  pub mod pb { tonic::include_proto!("openshell.compute.v1"); }
  pub use pb::compute_driver_server;
  ```
- Verify: `cargo build -p computev1` succeeds; `DriverSandbox`, `compute_driver_server::ComputeDriver`, `WatchSandboxesEvent` are present in generated artifacts.
- Commit: `feat(computev1): generate tonic/prost bindings from compute_driver.proto`.

### Task 5 — Binary crate manifest + module stubs

**Create:** `crates/openshell-driver-kyma/{Cargo.toml, src/lib.rs, src/main.rs}`.
- `Cargo.toml`: binary + library, `path` dep on `computev1`, all workspace deps; `[features] integration = []`.
- `lib.rs` declares all 8 modules as stubs (`pub fn _placeholder() {}`).
- `main.rs`: `fn main() { println!("driver placeholder"); }`.
- Verify: `cargo build -p openshell-driver-kyma` succeeds.
- Commit: `build: scaffold openshell-driver-kyma binary crate`.

### Task 6 — `error.rs` with `tonic::Status` mapping

**Create:** `crates/openshell-driver-kyma/src/error.rs`.

TDD: 6 tests verifying each variant (`InvalidArgument` → `Code::InvalidArgument`, `NotFound`, `AlreadyExists`, `FailedPrecondition`, `Kube` API 404 → `NotFound`, `Internal` from `anyhow` → `Internal`). Then implement:

```rust
use thiserror::Error;
#[derive(Error, Debug)]
pub enum DriverError {
    #[error("invalid argument: {0}")] InvalidArgument(String),
    #[error("not found: {0}")] NotFound(String),
    #[error("already exists: {0}")] AlreadyExists(String),
    #[error("precondition failed: {0}")] FailedPrecondition(String),
    #[error("unavailable: {0}")] Unavailable(String),
    #[error("kubernetes api: {0}")] Kube(#[from] kube::Error),
    #[error(transparent)] Internal(#[from] anyhow::Error),
}
impl From<DriverError> for tonic::Status {
    fn from(e: DriverError) -> Self {
        use tonic::{Code, Status};
        match e {
            DriverError::InvalidArgument(m) => Status::new(Code::InvalidArgument, m),
            DriverError::NotFound(m) => Status::new(Code::NotFound, m),
            DriverError::AlreadyExists(m) => Status::new(Code::AlreadyExists, m),
            DriverError::FailedPrecondition(m) => Status::new(Code::FailedPrecondition, m),
            DriverError::Unavailable(m) => Status::new(Code::Unavailable, m),
            DriverError::Kube(kube::Error::Api(r)) if r.code == 404 => Status::new(Code::NotFound, r.message),
            DriverError::Kube(kube::Error::Api(r)) if r.code == 409 => Status::new(Code::AlreadyExists, r.message),
            DriverError::Kube(other) => Status::new(Code::Internal, other.to_string()),
            DriverError::Internal(e) => Status::new(Code::Internal, e.to_string()),
        }
    }
}
```

Commit: `feat(error): map DriverError variants to tonic::Status codes`.

### Task 7 — `config.rs` (clap-derive)

**Create:** `src/config.rs`.

TDD: one test asserting all 14 defaults from spec table. Implement `Config` as `#[derive(Debug, Clone, clap::Parser)]` with `#[arg(long, default_value = ...)]` on each field plus `impl Default`. Defaults: `socket=/var/run/openshell-driver.sock`, `namespace=openshell-system`, `supervisor_image=ghcr.io/nvidia/openshell-community/supervisor:latest`, `supervisor_binary_path=/usr/local/bin/openshell-sandbox`, `supervisor_mount_path=/opt/openshell/bin`, `gateway_endpoint=""`, `istio_inject_sandboxes=false`, `enable_apirule=false`, `cluster_domain=""`, `gpu_support=true`, `enable_network_policy=false`, `health_port=9090`, `log_level=info`. `pub fn from_env_and_args() -> Self { Self::parse() }`.

Commit: `feat(config): add Config struct with clap-derived CLI flags`.

### Task 8 — `interfaces.rs` traits + `WatchEvent`

**Create:** `src/interfaces.rs`.

TDD: compile-time test that `WatchEvent::Updated(DriverSandbox)` and `WatchEvent::Deleted(String)` construct. Implement:

```rust
use async_trait::async_trait;
use computev1::pb::DriverSandbox;
use std::time::Duration;

#[derive(Debug, Clone)]
pub enum WatchEvent { Updated(DriverSandbox), Deleted(String) }

#[cfg_attr(test, mockall::automock)]
#[async_trait]
pub trait SandboxProvisioner: Send + Sync + 'static {
    async fn create(&self, sb: &DriverSandbox) -> Result<(), crate::error::DriverError>;
    async fn delete(&self, name: &str) -> Result<(), crate::error::DriverError>;
    async fn get(&self, name: &str) -> Result<DriverSandbox, crate::error::DriverError>;
    async fn list(&self) -> Result<Vec<DriverSandbox>, crate::error::DriverError>;
    async fn watch(&self) -> Result<tokio::sync::mpsc::Receiver<WatchEvent>, crate::error::DriverError>;
    async fn validate_create(&self, sb: &DriverSandbox) -> Result<(), crate::error::DriverError>;
    async fn has_gpu_capacity(&self) -> Result<bool, crate::error::DriverError>;
}

#[cfg_attr(test, mockall::automock)]
#[async_trait]
pub trait PlatformEnricher: Send + Sync + 'static {
    async fn detect_psa(&self, namespace: &str) -> Result<String, crate::error::DriverError>;
    async fn enrich_pod_template(&self, template: serde_json::Value, namespace: &str) -> Result<serde_json::Value, crate::error::DriverError>;
    fn render_apirule(&self, sandbox_id: &str, sandbox_name: &str) -> Option<serde_json::Value>;
}

#[cfg_attr(test, mockall::automock)]
pub trait DriverMetrics: Send + Sync + 'static {
    fn sandbox_created(&self, name: &str, gpu: bool, duration: Duration);
    fn sandbox_deleted(&self, name: &str);
    fn sandbox_failed(&self, name: &str, reason: &str);
    fn watch_event_received(&self, event_type: &str);
}
```

Commit: `feat(interfaces): define provisioner/enricher/metrics traits`.

### Task 9 — `helpers.rs::object_to_driver_sandbox`

**Create:** `src/helpers.rs`.

TDD: 4 tests covering id-label extraction, status `agentPod` → `instance_id`, `conditions` array → `Vec<DriverCondition>`, `metadata.deletionTimestamp` set → `status.deleting=true`. Each test builds a `serde_json::Value` fixture, wraps in `kube::core::DynamicObject`, asserts proto fields. Implementation mirrors `provisioner.go:13-73` semantics (read labels and `obj.data.status` paths).

Commit: `feat(helpers): port objToDriverSandbox conversion from Go`.

### Task 10 — `helpers.rs` env/resources/map utilities

**Modify:** `src/helpers.rs` (append).

TDD: 5 tests — spec env overrides template env; CPU+memory request/limit emit; `gpu=true` adds `nvidia.com/gpu=1` to limits; `merge_maps` keeps both with b winning; `get_string` handles string/f64/missing-key. Implement `build_env_list`, `build_resources`, `merge_maps`, `get_string` matching `helpers.go:76-155`.

Commit: `feat(helpers): port env/resources/map helpers from Go`.

### Task 11 — `KymaProvisioner` + Create

**Create:** `src/provisioner.rs`, `tests/common/{mod.rs,kube_mock.rs}`.

TDD test: `create_posts_sandbox_cr_with_correct_labels_and_image` uses `tower_test::mock::pair` to assert outgoing POST goes to `/apis/agents.x-k8s.io/v1alpha1/namespaces/test-ns/sandboxes` with `metadata.name=create-test`, `labels.openshell.ai/sandbox-id=sb-100`, `labels.openshell.ai/managed-by=openshell`, `containers[0].image=img:latest`. Implement `KymaProvisioner { client, cfg }`. GVR built via `ApiResource::from_gvk_with_plural(&GroupVersionKind { group: "agents.x-k8s.io".into(), version: "v1alpha1".into(), kind: "Sandbox".into() }, "sandboxes")`. `Api::namespaced_with(client, ns, &ar)`. Build `DynamicObject` from a `serde_json::json!` value. The full `build_sandbox_spec` body lands in Task 15; this task uses a minimal pod template.

Commit: `feat(provisioner): KymaProvisioner skeleton + Create with labels`.

### Task 12 — Get / List / Delete

**Modify:** `src/provisioner.rs`.

TDD: 4 tests — `get_returns_driver_sandbox` (mock GET, assert id+instance_id from `agentPod`); `list_filters_by_label` (assert `labelSelector=openshell.ai%2Fmanaged-by%3Dopenshell` in query); `delete_returns_not_found_on_404` (driver layer turns this into `Deleted=false` later); `delete_succeeds_on_200`. Implement using `Api::get`, `Api::list_with(ListParams::default().labels("openshell.ai/managed-by=openshell"))`, `Api::delete(name, &DeleteParams::default())`. Each `DynamicObject` runs through `helpers::object_to_driver_sandbox`.

Commit: `feat(provisioner): implement get/list/delete with managed-by label filter`.

### Task 13 — Watch

**Modify:** `src/provisioner.rs`.

TDD: `watch_channel_closes_on_drop` and a positive `watch_emits_updated_on_apply_event` test using `tower_test::mock` to feed a synthetic chunked watch response. Implement using `kube::runtime::watcher` with `watcher::Config::default().labels("openshell.ai/managed-by=openshell")`. Spawn a `tokio::spawn` consuming the watcher stream; `Event::Apply(obj)` → `WatchEvent::Updated(object_to_driver_sandbox(&obj))`; `Event::Delete(obj)` → `WatchEvent::Deleted(label["openshell.ai/sandbox-id"])`; forward into `tokio::sync::mpsc::channel(64)`. `Init`/`InitApply`/`InitDone` reset cache by emitting `Updated` for each item (matches Go `Added`/`Modified` handling).

Commit: `feat(provisioner): implement watch via kube::runtime::watcher with mpsc forward`.

### Task 14 — `has_gpu_capacity`

**Modify:** `src/provisioner.rs`.

TDD: 3 tests — node with no GPU returns false; node with `nvidia.com/gpu: "1"` returns true; `gpu_support=false` returns `Ok(false)` without an HTTP call. Implement: short-circuit when `cfg.gpu_support=false`; otherwise `Api::<Node>::all(client).list(&ListParams::default()).await?`, walk allocatable, return `true` on first non-zero `nvidia.com/gpu`.

Commit: `feat(provisioner): GPU capacity check honors --gpu-support flag`.

### Task 15 — `build_sandbox_spec` (init container, security context, labels, defaults)

**Modify:** `src/provisioner.rs`.

TDD: ~6 sub-tests mirroring `TestBuildSandboxSpec_SupervisorInitContainer` and `TestBuildSandboxSpec_Labels` — init container `name=supervisor-init`, agent container command, `securityContext.privileged=true / runAsUser=0 / capabilities.add=[SYS_ADMIN,NET_ADMIN,SYS_PTRACE,SYSLOG]`, `emptyDir` volume with `readOnly` mount, `serviceAccountName=openshell-sandbox`, label set including `openshell.ai/sandbox-id`, `openshell.ai/managed-by=openshell`, `kagenti.io/type=agent`, `sidecar.istio.io/inject=false` only when flag is false, `runtimeClassName` from `platform_config`, and **default resources** (`requests: 100m CPU / 128Mi mem; limits: 500m CPU / 512Mi mem`) injected only when `tmpl.resources` is unset. Direct port of `provisioner.go:222-297` using `serde_json::json!`.

Commit: `feat(provisioner): build_sandbox_spec with init container, caps, default resources`.

### Task 16 — `KymaEnricher` + Istio inject toggle

**Create:** `src/enricher.rs`.

TDD: 2 tests — `enrich_adds_istio_inject_false_label_when_disabled` (preserves existing labels, adds `sidecar.istio.io/inject=false`); `enrich_does_not_touch_label_when_inject_enabled`. Implement `KymaEnricher { client, cfg }` and `impl PlatformEnricher`. `enrich_pod_template` walks the JSON, ensures `metadata.labels` exists, conditionally inserts the istio label.

Commit: `feat(enricher): KymaEnricher with --istio-inject-sandboxes handling`.

### Task 17 — PSA detection + fail-fast

**Modify:** `src/enricher.rs`.

TDD: 3 tests — privileged label returns `Ok("privileged")`; baseline label → `Err(FailedPrecondition)` whose message names `privileged` and `pod-security.kubernetes.io/enforce`; missing label → `Err(FailedPrecondition)`. Implement `detect_psa(&self, ns: &str)` reading `Api::<Namespace>::all(client).get(ns).await?.metadata.labels[k]`. Wired into `Driver::new` startup in Task 24.

Commit: `feat(enricher): PSA enforce-label detection with fail-fast on baseline/restricted`.

### Task 18 — APIRule rendering (`gateway.kyma-project.io/v2`)

**Modify:** `src/enricher.rs`.

TDD: positive case yields APIRule v2 manifest with `spec.hosts=[<name>.<cluster_domain>]`, `spec.service.{name,port}`, `spec.rules[0].path=/*`, `spec.rules[0].methods=[GET,POST]`, JWT block when issuer present; negative case (`enable_apirule=false`) returns `None`. Implement `render_apirule(&self, sandbox_id, sandbox_name) -> Option<serde_json::Value>` returning `None` when flag is off. POST is wired in Task 40.

Commit: `feat(enricher): render Kyma APIRule v2 manifest behind --enable-apirule`.

### Task 19 — `metrics.rs` (Prometheus + axum)

**Create:** `src/metrics.rs`.

TDD: 2 tests — `prometheus_metrics_exposes_sandbox_created_counter` (registry contains `openshell_driver_sandbox_created_total{result=\"ok\"}` and histogram); `axum_serves_metrics_and_health` (spawn `serve_http` on port 0, GET `/metrics` returns 200 with `# HELP openshell_driver_*`, `/healthz`+`/readyz` return `ok`). Implement `PrometheusMetrics` with 4 counters (`sandbox_{created,deleted,failed}_total{result|reason}`, `watch_events_total{event_type}`) plus `sandbox_create_duration_seconds` histogram. `serve_http(addr, registry, ready_flag)` builds `axum::Router`. Bound label cardinality — `reason` is variant name only, never user message.

Commit: `feat(metrics): Prometheus counters + axum /metrics /healthz /readyz`.

### Task 20 — Driver: GetCapabilities + StopSandbox

**Create:** `src/driver.rs`.

TDD: 3 tests — `get_capabilities_reports_kyma_and_gpu_flag` (driver_name="kyma", supports_gpu=true when flag true); `get_capabilities_reports_no_gpu_when_disabled`; `stop_sandbox_returns_unimplemented`. Implement `Driver { provisioner: Arc<dyn SandboxProvisioner>, enricher: Arc<dyn PlatformEnricher>, metrics: Arc<dyn DriverMetrics>, cfg: Config }`. `impl ComputeDriver for Driver`. `get_capabilities` returns `name="kyma"`, `version=env!("CARGO_PKG_VERSION")`, `default_image="ghcr.io/nvidia/openshell-community/sandboxes/base:latest"`, `supports_gpu=cfg.gpu_support`. `stop_sandbox` returns `Err(Status::unimplemented(...))`.

Commit: `feat(driver): implement GetCapabilities and StopSandbox RPCs`.

### Task 21 — Driver: ValidateSandboxCreate + CreateSandbox

**Modify:** `src/driver.rs`.

TDD: 7 tests — validate failure → `FailedPrecondition`; validate ok; create with empty id/name/missing-spec/missing-template/missing-image → `InvalidArgument` (5 sub-cases); create success records `metrics.sandbox_created`; create failure records `metrics.sandbox_failed` and returns `Internal`. Mirror `driver.go:108-146`. Time `Instant::now()` around `provisioner.create()`.

Commit: `feat(driver): implement ValidateSandboxCreate and CreateSandbox RPCs`.

### Task 22 — Driver: Get/List/DeleteSandbox

**Modify:** `src/driver.rs`.

TDD: 7 tests covering get NotFound, get success, list error → Internal, list empty, delete success, delete idempotent (`NotFound` from provisioner → `Deleted=false` no error), delete other error → Internal. Idempotency rule explicitly:

```rust
match self.provisioner.delete(name).await {
    Ok(()) => Ok(Response::new(DeleteSandboxResponse { deleted: true })),
    Err(DriverError::NotFound(_)) => Ok(Response::new(DeleteSandboxResponse { deleted: false })),
    Err(DriverError::Kube(kube::Error::Api(r))) if r.code == 404 => Ok(Response::new(DeleteSandboxResponse { deleted: false })),
    Err(e) => Err(e.into()),
}
```

Commit: `feat(driver): implement Get/List/DeleteSandbox with idempotent delete`.

### Task 23 — Driver: WatchSandboxes (server stream)

**Modify:** `src/driver.rs`.

TDD: `watch_streams_updates_and_deletes_then_closes_on_client_cancel`. Mock `provisioner.watch()` returns a pre-built `mpsc::Receiver` with 1 `Updated` + 1 `Deleted`, then the sender drops. Collect the tonic stream into a `Vec`; assert two events with right payload variants and stream ends with `None`. Implement: `type WatchStream = Pin<Box<dyn Stream<Item = Result<WatchSandboxesEvent, Status>> + Send>>`. Wrap the receiver with `ReceiverStream::new(rx).map(|ev| Ok(map_event(ev)))`. Increment `metrics.watch_event_received("updated"|"deleted")` per event.

Commit: `feat(driver): implement WatchSandboxes server-streaming RPC`.

### Task 24 — `main.rs` wiring

**Modify:** `src/main.rs`.
**Note.** The proto defines 8 RPCs (no `ResolveSandboxEndpoint`); spec section "gRPC contract & error mapping" listing 9 was an editing artifact — confirmed by reading both `proto/compute_driver.proto` and `reference-openshift/internal/driver/driver.go`. We implement only what's in the proto.

TDD: smoke test in `tests/cli_help.rs` using `assert_cmd::Command` to run `--help` and assert all 14 flags appear. Implement:

```rust
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cfg = Config::from_env_and_args();
    init_tracing(&cfg.log_level);

    let kube_client = build_kube_client().await?;
    let enricher = Arc::new(KymaEnricher::new(kube_client.clone(), cfg.clone()));
    enricher.detect_psa(&cfg.namespace).await?;  // PSA fail-fast

    let provisioner = Arc::new(KymaProvisioner::new(kube_client.clone(), cfg.clone()));
    let metrics = Arc::new(PrometheusMetrics::new());

    let _ = std::fs::remove_file(&cfg.socket);
    let listener = tokio::net::UnixListener::bind(&cfg.socket)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&cfg.socket, std::fs::Permissions::from_mode(0o660))?;
    let stream = tokio_stream::wrappers::UnixListenerStream::new(listener);

    let driver = Driver::new_with_deps(provisioner, enricher, metrics.clone(), cfg.clone());
    let svc = compute_driver_server::ComputeDriverServer::new(driver);

    let http_addr: std::net::SocketAddr = format!("0.0.0.0:{}", cfg.health_port).parse()?;
    let http = tokio::spawn(metrics::serve_http(http_addr, metrics));
    let shutdown = shutdown_signal();

    tracing::info!(socket = %cfg.socket, namespace = %cfg.namespace, "driver starting");
    tonic::transport::Server::builder()
        .add_service(svc)
        .serve_with_incoming_shutdown(stream, shutdown).await?;
    http.abort();
    Ok(())
}
```

`build_kube_client()` tries `kube::Config::incluster_env()` then `kube::Config::infer().await?`. `shutdown_signal()` awaits SIGTERM/SIGINT via `tokio::signal::unix::signal`.

Commit: `feat(main): wire tonic UDS, axum sidecar, graceful shutdown, PSA fail-fast`.

### Task 25 — Smoke build verification (no commit)

Run `cargo build --release -p openshell-driver-kyma`. Run `target/release/openshell-driver-kyma --help` (or `.exe`). Verify all 14 flags appear. Verification only.

### Task 26 — Tier-2 contract test harness

**Create:** `tests/grpc_contract.rs`. **Modify:** `tests/common/mod.rs` (add `start_test_server()`).

TDD: harness mirrors `contract_test.go:34-97` — `tempfile::tempdir_in("/tmp")` for socket path under 108-char limit, `UnixListener::bind` + `UnixListenerStream`, mocked `MockSandboxProvisioner` (mockall) with configured expectations, `tonic::transport::Server` spawned with `oneshot` shutdown, `Endpoint::try_from("http://[::]:50051").connect_with_connector(service_fn(|_| async { UnixStream::connect(socket).await }))` for the client. First test: `grpc_get_capabilities_returns_kyma`.

Commit: `test(grpc-contract): UDS+tonic harness with mocked provisioner`.

### Task 27 — Tier-2 contract test cases (port from Go)

**Modify:** `tests/grpc_contract.rs`.

Port one-for-one: `TestGRPC_CreateAndGetSandbox`, `TestGRPC_CreateValidation_MissingFields` (5 sub-cases), `TestGRPC_DeleteIdempotent`, `TestGRPC_ListSandboxes`, `TestGRPC_StopReturnsUnimplemented`, `TestGRPC_WatchSandboxes`. Total ~10 passing.

Commit: `test(grpc-contract): port all 9 contract scenarios from Go reference`.

### Task 28 — Tier-3 live cluster harness with deny-list

**Create:** `tests/live_cluster.rs`.

TDD: `setup_integration_refuses_kube_system` panics when `INTEGRATION_TEST_NAMESPACE=kube-system`. Implement `setup_integration()`:
- Read `INTEGRATION_TEST_NAMESPACE`; if unset → skip.
- Default deny-list: `["default","kube-system","kube-public","kube-node-lease","istio-system","kyma-system","agent-sandbox-system"]`.
- Extend with comma-split from `INTEGRATION_TEST_NAMESPACE_DENYLIST` env var.
- Panic with clear message if denied.
- Build `kube::Client`. List Sandbox CRD with `Limit: 1`. If Err → skip.
- Create namespace if missing; label `pod-security.kubernetes.io/enforce: privileged`.
- Cleanup: delete Sandboxes with `openshell.ai/managed-by=openshell` at teardown; if `INTEGRATION_DELETE_NAMESPACE=true`, delete the namespace.

Gate the file: `#![cfg(feature = "integration")]`.

Commit: `test(integration): harness with deny-list enforcement and CRD pre-flight`.

### Task 29 — Tier-3 cases: lifecycle + labels + init container + Istio

**Modify:** `tests/live_cluster.rs`.

6 tests gated by `#[cfg(feature = "integration")]`: `test_create_and_list_sandbox`, `test_get_sandbox`, `test_delete_sandbox`, `test_verify_labels`, `test_verify_supervisor_init_container`, `test_istio_inject_disabled`. Structure mirrors `lifecycle_test.go:175-355`.

Run with `INTEGRATION_TEST_NAMESPACE=openshell-driver-test` against the user's live Kyma cluster until all 6 pass.

Commit: `test(integration): 6 lifecycle cases mirroring the OpenShift reference`.

### Task 30 — Tier-3: PSA fail-fast + e2e Sandbox Ready/Pod Running

**Modify:** `tests/live_cluster.rs`.

2 tests:
- `test_psa_check_fails_in_unprivileged_namespace`: temp namespace with `enforce=baseline`; expected `Driver::new` (or PSA detect) returns error; `t.Cleanup`-equivalent deletes the namespace.
- `test_e2e_sandbox_runs`: create sandbox, poll up to 90s for `status.conditions[type=Ready,status=True]`, fetch the pod via typed client, assert `pod.status.phase=="Running"`. Then delete and poll up to 30s for the CR to disappear.

Commit: `test(integration): PSA fail-fast and e2e Sandbox Ready/Pod Running smoke`.

### Task 31 — Production Dockerfile

**Create:** `deploy/Dockerfile`. cargo-chef → distroless static (rustls, no openssl). Build args `RUST_VERSION=1.83.0`. Final stage `gcr.io/distroless/static-debian12:nonroot` running as `65532:65532`.

Verify `docker build -f deploy/Dockerfile -t openshell-driver-kyma:dev .` succeeds (~30 MB final image); `docker run --rm openshell-driver-kyma:dev --help` lists flags.

Commit: `build(docker): production Dockerfile with cargo-chef and distroless static`.

### Task 32 — Dev Dockerfile

**Create:** `deploy/Dockerfile.dev`. Base `rust:1.83.0-bookworm-slim` + `protoc`, `pkg-config`, `git`, `curl`, `jq`, `build-essential`, `cargo-chef`, `cargo-llvm-cov`, `kubectl`, `helm`, `markdownlint-cli2`. `WORKDIR /workspace`.

Verify `docker build -f deploy/Dockerfile.dev -t openshell-driver-kyma-dev:latest .` succeeds.

Commit: `build(docker): dev toolchain image with rustfmt/clippy/protoc/kubectl/helm`.

### Task 33 — Makefile

**Create:** `Makefile`. Targets: `proto`, `build`, `fmt`, `clippy`, `test`, `test-integration`, `test-all`, `image`, `dev-image`, `dev-shell`, `dev-shell-with-kube`, `dev-test`, `dev-build`, `helm-lint`, `clean`, `run`. `dev-shell` mounts `$PWD:/workspace` + named volume `cargo-target:/workspace/target` (key incremental-cache win). `dev-shell-with-kube` adds `$HOME/.kube:/root/.kube:ro`. `test-integration` errors out if `INTEGRATION_TEST_NAMESPACE` is unset.

Verify `make build` and `make test` work locally.

Commit: `build(make): all dev/CI targets including dev-shell and test-integration`.

### Task 34 — Helm chart core (Chart.yaml, values, RBAC)

**Create:** `deploy/helm/openshell-driver-kyma/{Chart.yaml, values.yaml, templates/_helpers.tpl, templates/serviceaccount.yaml, templates/role.yaml, templates/rolebinding.yaml, templates/clusterrole-nodes.yaml, templates/clusterrolebinding-nodes.yaml}`.

`Chart.yaml`: apiVersion v2, name `openshell-driver-kyma`, version 0.1.0, kubeVersion ">=1.27.0-0". `values.yaml` mirrors all 14 spec flags plus `image.{repository,tag}`, `serviceAccount.name=openshell-driver`, `resources.driver.{requests,limits}`. `role.yaml` namespace-scoped on `sandboxes.agents.x-k8s.io` (`{get,list,watch,create,delete,patch}`); when `.Values.enableApirule`, add the same on `apirules.gateway.kyma-project.io`. `clusterrole-nodes.yaml` rendered only when `.Values.gpuSupport`.

Verify: `helm template ... --set gpuSupport=false --set enableApirule=false` produces NO ClusterRole and NO `apirules` permission; with both true, both appear.

Commit: `feat(helm): chart skeleton with namespace-scoped Role and gated ClusterRole`.

### Task 35 — Helm Deployment + Service + NetworkPolicy + pre-install hook

**Create:** `deployment.yaml`, `service.yaml`, `networkpolicy.yaml`, `pre-install-crd-check.yaml`.

- Deployment: 1 replica, full restricted PSS context (`runAsNonRoot=true`, `runAsUser=65532`, `readOnlyRootFilesystem=true`, `allowPrivilegeEscalation=false`, `capabilities.drop=[ALL]`, `seccompProfile.type=RuntimeDefault`); annotation `sidecar.istio.io/inject: "false"`; args from `.Values`; emptyDir volume for the UDS.
- Service: ClusterIP exposing port 9090 for `/metrics` scrape.
- NetworkPolicy gated by `.Values.enableNetworkPolicy`: default-deny ingress + allow gateway label; default-deny egress except UDP/53 to kube-system + the gateway service.
- `pre-install-crd-check.yaml`: `Job` annotated `helm.sh/hook: pre-install`, runs `kubectl get crd sandboxes.agents.x-k8s.io || (echo 'agent-sandbox CRD missing; install kubernetes-sigs/agent-sandbox first' && exit 1)`.

Verify `helm lint deploy/helm/openshell-driver-kyma` reports 0 errors.

Commit: `feat(helm): Deployment, Service, NetworkPolicy, and pre-install CRD check`.

### Task 36 — GitHub Actions: branch-checks

**Create:** `.github/workflows/branch-checks.yml`. Triggers on `pull_request` and `push: branches: [main]`. Steps: `actions/checkout@v4`, `dtolnay/rust-toolchain@1.83.0` with rustfmt+clippy, `Swatinem/rust-cache@v2`, install protoc, then `cargo fmt --check`, `cargo clippy --workspace --all-targets -- -D warnings -W clippy::pedantic`, `cargo build --release --workspace`, `cargo test --workspace`.

Commit: `ci: branch-checks workflow with fmt/clippy/test/build`.

### Task 37 — GitHub Actions: dco + helm-lint + docker-build + release-tag

**Create:** `.github/workflows/{dco.yml,helm-lint.yml,docker-build.yml,release-tag.yml}`.

- `dco.yml`: `tim-actions/dco@v1` on PRs.
- `helm-lint.yml`: `azure/setup-helm@v4` → `helm lint deploy/helm/openshell-driver-kyma`.
- `docker-build.yml` on push to main: `docker/setup-buildx`, `docker/login-action` to `ghcr.io` with `GITHUB_TOKEN`, `docker/build-push-action` pushing `ghcr.io/${{ github.repository }}:{${{ github.sha }},latest}`.
- `release-tag.yml` on `tags: ['v*']`: same docker push with `:${{ github.ref_name }}` + `:latest`, `helm package`, `softprops/action-gh-release@v2` attaching the chart `.tgz`.

Verify YAML with `actionlint` if available.

Commit: `ci: add DCO, helm-lint, docker-build, release-tag workflows`.

### Task 38 — Repo hygiene (README, CONTRIBUTING, SECURITY, CHANGELOG, dependabot, markdownlint)

**Modify:** `README.md` (full rewrite). **Create:** `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `.github/dependabot.yml`, `.markdownlint-cli2.jsonc`.

- README: title, badges (CI/license/container), one-paragraph description, "Status: Phase 1", quick-start (`helm install ...`), link to spec doc, the 14-flag configuration table, contributing pointer, license. **No cluster IDs, no secrets, no real namespaces beyond `openshell-system` / `openshell-driver-test`.**
- CONTRIBUTING: dev workflow with `make dev-shell` / `make dev-test`; DCO sign-off (`git commit -s`); branch naming; PR checklist.
- SECURITY: vuln-reporting via private channel — placeholder email; never via public issues.
- CHANGELOG (Keep-a-Changelog): `## [Unreleased]`.
- dependabot: ecosystems `cargo` (weekly) and `github-actions` (weekly).
- markdownlint config: disable MD013 (line-length).

Verify `markdownlint-cli2 "**/*.md"` succeeds.

Commit: `docs: README, contributing, security, changelog, dependabot, markdownlint`.

### Task 39 — Adapted docs

**Create:** `docs/why-init-container.md`, `docs/kyma-vs-openshift.md`, `docs/istio-considerations.md`. Adapt `reference-openshift/docs/why-init-container.md` (replace OpenShift-specific terms with Kubernetes-generic). Add a delta table for Kyma vs OpenShift (PSA vs SCC, Istio default-on, APIRule vs Route, Gardener-AWS GPU pools, OIDC kubeconfig via `exec` plugin). Document `--istio-inject-sandboxes`: why default false, how to safely enable.

Verify `markdownlint-cli2 "docs/*.md"`.

Commit: `docs: why-init-container, kyma-vs-openshift, istio-considerations`.

### Task 40 — Wire enricher into provisioner.create + APIRule POST

**Modify:** `src/provisioner.rs`.

TDD: 3 tests — `create_calls_enricher_enrich_pod_template` (mock enricher's `enrich_pod_template` is called; mutated JSON is what's POSTed); `create_posts_apirule_when_enabled` (with flag, mock sees a 2nd POST to `gateway.kyma-project.io/v2/.../apirules`); `create_does_not_post_apirule_when_disabled` (request count = 1 — Sandbox only). Implement: `KymaProvisioner::create` calls `self.enricher.enrich_pod_template(spec, &cfg.namespace).await?` before constructing the DynamicObject; if `cfg.enable_apirule`, render via `enricher.render_apirule(...)` and POST through a separate `Api::namespaced_with(client, ns, &apirule_ar)`.

Commit: `feat(provisioner): wire enricher.enrich_pod_template + APIRule POST`.

### Task 41 — Final clippy + fmt + lockfile

**Modify:** any style fixes; `Cargo.lock`.

`cargo fmt --all`. `cargo clippy --workspace --all-targets -- -D warnings -W clippy::pedantic` clean. `cargo test --workspace` green (Tier 1 + Tier 2).

Commit: `chore: cargo fmt + clippy::pedantic clean across workspace`.

## Verification (end-to-end)

Run after Task 41:

1. **All test tiers green against the user's live Kyma cluster:**
   ```
   make test-all INTEGRATION_TEST_NAMESPACE=openshell-driver-test
   ```
   Expected: ~50 unit tests + ~10 contract tests + 8 integration tests including `test_e2e_sandbox_runs` all pass.

2. **Image builds and runs:**
   ```
   make image && docker run --rm openshell-driver-kyma:dev --help
   ```
   Expected: image <90s with warm cache; `--help` lists all 14 flags.

3. **Helm chart lints:**
   ```
   helm lint deploy/helm/openshell-driver-kyma
   ```
   Expected: `1 chart(s) linted, 0 chart(s) failed`.

4. **All 5 GitHub Actions workflows green** on first PR (`branch-checks`, `dco`, `helm-lint`; `docker-build` and `release-tag` no-op on PRs).

5. **Manual smoke against the cluster:**
   ```
   helm install openshell-driver-kyma deploy/helm/openshell-driver-kyma \
     --namespace openshell-system --create-namespace
   kubectl logs -n openshell-system deploy/openshell-driver-kyma
   ```
   Expected: pod reaches Ready; logs contain `driver listening` line.

## Critical files (where most engineering attention will go)

- `crates/openshell-driver-kyma/src/driver.rs` — gRPC service impl (8 RPCs)
- `crates/openshell-driver-kyma/src/provisioner.rs` — Sandbox CR lifecycle (largest single file)
- `crates/openshell-driver-kyma/src/enricher.rs` — Kyma-specific behaviors (Istio, PSA, APIRule)
- `crates/openshell-driver-kyma/src/main.rs` — process bootstrap & graceful shutdown
- `deploy/helm/openshell-driver-kyma/templates/deployment.yaml` — pod hardening
- `crates/openshell-driver-kyma/tests/live_cluster.rs` — Tier-3 e2e safety (deny-list)
- `proto/compute_driver.proto` — vendored contract; do not modify

## Reuse from existing code

- **Reference Go driver** at `C:/tmp-bwx/openshell-driver-kyma/reference-openshift/`: every Rust task with TDD steps mirrors a corresponding Go file. Read the Go source side-by-side when implementing — the algorithms are identical, only the language idioms differ. Specifically: `internal/driver/driver.go` ↔ `src/driver.rs`; `provisioner.go` ↔ `src/provisioner.rs`; `helpers.go` ↔ `src/helpers.rs`; `interfaces.go` ↔ `src/interfaces.rs`; `enricher_noop.go` ↔ `src/enricher.rs` (we replace the noop with real Kyma logic); `cmd/driver/main.go` ↔ `src/main.rs`; `internal/grpctest/contract_test.go` ↔ `tests/grpc_contract.rs`; `test/integration/lifecycle_test.go` ↔ `tests/live_cluster.rs`; `Makefile` ↔ `Makefile`.
- **User's prior Kyma work** at `<local-workspace-path>/<llm-proxy-product>/<llm-proxy-private>/kyma/`: deployment patterns (PeerAuthentication, DestinationRule, sidecar injection toggles) — read for context only; do not import any cluster-specific values.

## Notes for the executor

- **Verify `kube` crate version at install time.** Plan pins `0.96` as known-good baseline. If `cargo search kube` shows a stable 3.x, upgrade and adjust API names in one focused follow-up commit. The plan's call sites (`Api::namespaced_with`, `ApiResource::from_gvk_with_plural`, `kube::runtime::watcher`, `Config::default().labels(...)`) are stable across recent versions.
- **Windows host vs Linux build.** All CI and most dev work happens inside `openshell-driver-kyma-dev:latest` (Linux). Windows host can run `cargo` directly for fast feedback, but the binary's UDS code (`tokio::net::UnixListener`, `std::os::unix::fs::PermissionsExt`) is Linux-only — `cargo check` will succeed cross-platform but `cargo build` of the binary on Windows host will fail. That's expected; build inside the dev container.
- **Tier-3 tests touch the live Kyma cluster.** Always verify `INTEGRATION_TEST_NAMESPACE` is set to `openshell-driver-test` (or another non-deny-listed value) before running. The harness panics on `kube-system` etc.
