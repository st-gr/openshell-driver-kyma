# openshell-driver-kyma — Design Spec

**Date:** 2026-05-26
**Status:** Draft (awaiting review)

## Goal

A standalone Rust implementation of the OpenShell `ComputeDriver` gRPC contract,
targeting SAP BTP Kyma clusters. Wire-compatible with the upstream OpenShell
gateway. Provisions agent sandboxes as `agents.x-k8s.io/v1alpha1/Sandbox` CRDs
with all Kyma-specific accommodations (Pod Security Admission, Istio sidecar
injection control, optional Kyma `APIRule` for external access, optional
Prometheus metrics, Helm chart).

The reference implementation is the Go OpenShift driver at
`github.com/zanetworker/openshell-driver-openshift`. This design mirrors its
contract and layered structure, ports it to Rust, and adds Kyma-specific
behaviors.

## Non-goals

- Re-implementing the OpenShell gateway. We integrate with the existing forked
  gateway via its `--compute-driver-socket` flag.
- Re-implementing the `agent-sandbox` controller. The controller is installed
  as a prerequisite from `kubernetes-sigs/agent-sandbox`.
- Supporting non-Kyma Kubernetes distributions as a first-class target. The
  driver should still run on vanilla Kubernetes, but we don't test for that.
- Any feature that would mutate cluster-scoped resources or cross namespace
  boundaries beyond opt-out read-only `Node`/`Gateway` reads.

## Architecture

```
openshell-gateway ── Unix domain socket ── openshell-driver-kyma (Rust, Tonic gRPC)
                                                  │
                                                  ├── SandboxProvisioner trait
                                                  │     └── KymaProvisioner (kube-rs)
                                                  │           Creates / watches Sandbox CRDs
                                                  │           Injects supervisor (init container + emptyDir)
                                                  │           Resolves pod IPs for exec/SSH
                                                  │           GPU validation (nvidia.com/gpu)
                                                  │
                                                  ├── PlatformEnricher trait
                                                  │     └── KymaEnricher
                                                  │           Disable/keep Istio sidecar (flag)
                                                  │           PSS-aware securityContext
                                                  │           Optional APIRule per sandbox (flag)
                                                  │
                                                  └── DriverMetrics trait
                                                        └── PrometheusMetrics
                                                              /metrics HTTP endpoint
                                                              sandbox_created/deleted/failed counters
```

Three traits, three implementations, all wired through a `Driver` struct that
implements `tonic`'s generated `compute_driver_server::ComputeDriver` service.
Behind every RPC there is a single trait method, so unit tests can stub out
the cluster entirely.

The driver listens on a Unix domain socket (default
`/var/run/openshell-driver.sock`), same as the OpenShift driver — this keeps
the gateway-driver contract identical to upstream.

## Why a fresh standalone repo

We considered three approaches:

- **A. Standalone Cargo workspace** (chosen). Independent release cadence,
  small surface, easy testing, no upstream coupling. Vendor only the
  `compute_driver.proto` file (Apache-2.0, retain SPDX header).
- **B. Fork NVIDIA/OpenShell.** Pulls in 16+ crates; build/test surface
  becomes huge; upstream changes require ongoing merge work. Rejected.
- **C. Standalone + `openshell-core` git dependency.** Couples release cadence
  to upstream and requires `openshell-core` to be publishable. Rejected.

## File structure

```
openshell-driver-kyma/
├── Cargo.toml                          # workspace manifest
├── rust-toolchain.toml                 # pin stable Rust
├── README.md                           # public-facing usage (no cluster details)
├── Makefile                            # build/test convenience
├── proto/
│   └── compute_driver.proto            # vendored from NVIDIA/OpenShell, Apache-2.0
├── crates/
│   ├── computev1/                      # generated tonic+prost code
│   │   ├── Cargo.toml
│   │   ├── build.rs                    # tonic_build::compile_protos
│   │   └── src/lib.rs                  # re-exports `pb::*` and the server trait
│   └── openshell-driver-kyma/          # the binary
│       ├── Cargo.toml
│       ├── src/
│       │   ├── main.rs                 # CLI flags (clap), tokio runtime, server bootstrap
│       │   ├── config.rs               # Config + defaults
│       │   ├── driver.rs               # Driver struct, gRPC service impl
│       │   ├── interfaces.rs           # SandboxProvisioner, PlatformEnricher, DriverMetrics traits
│       │   ├── provisioner.rs          # KymaProvisioner (kube-rs Sandbox CR lifecycle)
│       │   ├── enricher.rs             # KymaEnricher (Istio inject, PSS, APIRule)
│       │   ├── metrics.rs              # PrometheusMetrics + /metrics HTTP server
│       │   ├── helpers.rs              # CR <-> proto conversions, env merging, resource mapping
│       │   └── error.rs                # DriverError (thiserror) → tonic::Status mapping
│       └── tests/
│           ├── grpc_contract.rs        # Tier 2: gRPC over UDS + mocked K8s
│           ├── live_cluster.rs         # Tier 3: real cluster (gated by env)
│           └── common/                 # test helpers shared across files
├── deploy/
│   ├── Dockerfile                      # multi-stage: cargo-chef + distroless nonroot (production)
│   ├── Dockerfile.dev                  # build toolchain image for fast local iteration
│   ├── kustomize/
│   │   ├── base/                       # ServiceAccount, RBAC, Deployment
│   │   └── kyma/                       # Kyma overlay (PSS labels, sidecar.istio.io/inject=false)
│   └── helm/openshell-driver-kyma/     # Helm chart
├── .github/
│   └── workflows/
│       ├── branch-checks.yml           # fmt + clippy + Tier 1-2 tests
│       ├── dco.yml                     # DCO sign-off check
│       ├── helm-lint.yml               # helm lint
│       ├── docker-build.yml            # multi-stage image, push to GHCR
│       └── release-tag.yml             # on v* tag, build/publish
└── docs/
    ├── superpowers/specs/              # this design doc
    ├── superpowers/plans/              # implementation plan
    ├── why-init-container.md           # adapted from upstream OpenShift driver
    ├── kyma-vs-openshift.md            # delta documentation
    └── istio-considerations.md         # explains the Istio inject flag
```

Notes:

- `computev1` is its own crate so the binary doesn't recompile prost-generated
  code on every edit.
- Live integration tests are gated by `INTEGRATION_TEST_NAMESPACE` env var
  (skip silently when unset), same pattern as the OpenShift driver.
- No secrets, no kubeconfig paths, no cluster identifiers in any committed file.

## Tech stack

- **Language:** Rust (matches NVIDIA upstream).
- **gRPC:** `tonic` (transport feature) + `prost`/`prost-types` for proto.
- **Kubernetes:** `kube` (with `runtime` and `derive` features) + `k8s-openapi`.
- **Async:** `tokio`, `futures`, `tokio-stream`.
- **CLI:** `clap` v4 (derive feature).
- **Logging/diagnostics:** `tracing`, `tracing-subscriber` (JSON formatter).
- **Errors:** `thiserror` for the `DriverError` enum, `anyhow` only at the
  binary's top edge for context-rich error chaining.
- **Metrics:** `prometheus` crate + a small `axum`-served `/metrics` endpoint
  on a separate HTTP port.

This matches the dependency surface of NVIDIA's `openshell-driver-kubernetes`.

## gRPC contract & error mapping

Same 9 RPCs as the OpenShift driver, wire-compatible with the upstream gateway.

| RPC | Returns | Error path |
|-----|---------|------------|
| `GetCapabilities` | name=`kyma`, version, `supports_gpu` reflects the `--gpu-support` flag | never errors |
| `ValidateSandboxCreate` | OK or `FailedPrecondition` | GPU requested but no node has `nvidia.com/gpu`; PSA label missing on namespace; sandbox name invalid |
| `CreateSandbox` | OK or error | Missing id/name/spec/template/image → `InvalidArgument`. K8s API failure → `Internal`. Already-exists → `AlreadyExists`. |
| `GetSandbox` | sandbox snapshot or `NotFound` | CR doesn't exist or watcher missed it |
| `ListSandboxes` | snapshots filtered by `openshell.ai/managed-by=openshell` label | API failure → `Internal` |
| `StopSandbox` | `Unimplemented` | Phase 1 leaves this stubbed, mirroring OpenShift driver |
| `DeleteSandbox` | `deleted=true` or `false` | Idempotent: deleting a missing CR returns `deleted=false`, not error |
| `ResolveSandboxEndpoint` | pod IP + agent_fd + sandbox_fd | `NotFound` if sandbox missing; `Unavailable` if pod not yet scheduled |
| `WatchSandboxes` | server-stream of update/delete events | stream closes on context cancel; partial errors logged, never crash the stream |

Error-to-status mapping lives in `error.rs`:

```rust
#[derive(thiserror::Error, Debug)]
pub enum DriverError {
    #[error("invalid argument: {0}")]    InvalidArgument(String),
    #[error("not found: {0}")]            NotFound(String),
    #[error("already exists: {0}")]       AlreadyExists(String),
    #[error("precondition failed: {0}")] FailedPrecondition(String),
    #[error("kubernetes api: {0}")]       Kube(#[from] kube::Error),
    #[error(transparent)]                  Internal(#[from] anyhow::Error),
}

impl From<DriverError> for tonic::Status { /* maps to gRPC codes */ }
```

This keeps RPC handlers small (`?` propagates errors and the `From` impl turns
them into the right gRPC status code).

Proto generation: `crates/computev1/build.rs` invokes
`tonic_build::compile_protos("../../proto/compute_driver.proto")`. Generated
code is built each time, never committed.

## Sandbox CRD lifecycle

For each RPC, here's exactly what the K8s call looks like (using
`kube::Api<DynamicObject>` because `Sandbox` is from a third-party CRD).

**Create.** Dynamic POST to `agents.x-k8s.io/v1alpha1/namespaces/<ns>/sandboxes`.
The Rust pod-template builder produces:

```yaml
spec:
  podTemplate:
    metadata:
      labels:
        kagenti.io/type: agent
        openshell.ai/managed-by: openshell
        openshell.ai/sandbox-id: <id>
        sidecar.istio.io/inject: "false"   # if --istio-inject-sandboxes=false
        <user labels>
    spec:
      initContainers:
        - name: supervisor-init
          image: <--supervisor-image>
          command: ["cp", "<--supervisor-binary-path>", "<--supervisor-mount-path>/"]
          volumeMounts: [{ name: supervisor-bin, mountPath: <--supervisor-mount-path> }]
      containers:
        - name: agent
          image: <user image>
          command: ["<--supervisor-mount-path>/openshell-sandbox"]
          env: [merged spec.environment + template.environment + driver-injected gateway env]
          securityContext:
            privileged: true
            runAsUser: 0
            capabilities: { add: [SYS_ADMIN, NET_ADMIN, SYS_PTRACE, SYSLOG] }
          resources: { requests, limits }
          volumeMounts: [{ name: supervisor-bin, mountPath: <...>, readOnly: true }]
      serviceAccountName: openshell-sandbox
      volumes: [{ name: supervisor-bin, emptyDir: {} }]
      runtimeClassName: <from platform_config>   # optional passthrough
```

**Watch.** `kube_runtime::watcher` with
`LabelSelector: openshell.ai/managed-by=openshell`. Translates
`Applied`/`Restarted`/`Deleted` events to `WatchSandboxesEvent` proto messages
and forwards them to the gRPC server-stream via a `tokio::sync::mpsc` channel.
On stream cancel, the watcher is dropped; `kube-runtime` cleans up.

**Get / List.** Dynamic API calls, then convert each `DynamicObject` to a
`DriverSandbox` via `helpers::object_to_driver_sandbox` (mirrors Go's
`objToDriverSandbox`).

**Delete.** Dynamic DELETE. Idempotent — 404 maps to `Deleted=false`, not an
error.

**ResolveEndpoint.** Get the Sandbox CR, read its `status.agentPod` field for
the pod name, fetch the pod, return its `status.podIP` (and the `agent_fd` /
`sandbox_fd` from the CR status).

## SAP BTP Kyma compatibility

**Pod Security Admission** (Kyma uses PSA, not OpenShift SCC):

- Driver pod fits the `restricted` profile — no special label needed for the
  driver namespace.
- Sandbox pods need elevated caps + `privileged: true` for the supervisor to
  install Landlock/seccomp. **The sandbox namespace must be labeled
  `pod-security.kubernetes.io/enforce: privileged`.** The driver does not
  modify namespace labels — that's a cluster-admin operation.
- The driver detects the PSA enforcement label of its target namespace at
  startup and fails fast with a clear error if absent or set to
  `baseline`/`restricted`. This avoids cryptic admission errors at
  sandbox-create time.

**Istio sidecar injection** (Kyma's Istio module is on by default):

- Driver pod: `sidecar.istio.io/inject: "false"` always (UDS doesn't need a
  sidecar).
- Sandbox pods: controlled by `--istio-inject-sandboxes` (default `false`).
  When `false`, the driver stamps `sidecar.istio.io/inject: "false"` on every
  Sandbox CR's pod template.

**Kyma API Gateway (`APIRule`):** Behind `--enable-apirule` (default off), the
driver creates one `gateway.kyma-project.io/v2alpha1` `APIRule` per sandbox
pointing at the sandbox's Service. JWT auth profile is configurable. When the
flag is off, no `apirules` RBAC permission is granted, so the driver runs
cleanly in clusters without the API Gateway module.

The cluster-suffix domain (`*.<cluster-id>.kyma.ondemand.com`) is **never
hardcoded** — the driver reads it from the cluster's `Gateway` resource at
startup, or accepts a `--cluster-domain` override.

**RBAC scoping for Kyma:**

- ServiceAccount has only namespace-scoped permissions on
  `sandboxes.agents.x-k8s.io`.
- Cluster-scoped `nodes` get/list (for GPU validation) is opt-out via
  `--gpu-support=false`. When off, the driver returns `SupportsGpu=false` from
  `GetCapabilities` and rejects GPU sandbox requests with a clear error. This
  lets users without cluster-admin run the driver with a pure namespace-scoped
  Role/RoleBinding.
- All RBAC is generated via the Helm chart's templated Role/ClusterRole so
  it's auditable and minimal.

**Kyma module dependencies (documented prerequisites):**

- Required: Istio module (default-on in Kyma).
- Required: agent-sandbox CRD + controller, installed by the user from
  `kubernetes-sigs/agent-sandbox`. Helm chart `pre-install` hook only checks
  the CRD is present and aborts with a clear message if not.
- Optional: API Gateway module (only needed if `--enable-apirule`).
- Optional: NVIDIA GPU operator (only needed for GPU sandboxes; Kyma on
  Gardener-AWS supports GPU node pools).

**Auth path:**

- In-cluster: ServiceAccount token via `kube::Config::incluster()`. No OIDC.
- Local dev: `kube::Config::infer()` picks up `KUBECONFIG` /
  `~/.kube/config`. BTP Kyma's OIDC kubeconfig works automatically because
  `kube-rs` honors `exec` credential plugin entries (`kubectl oidc-login` is
  invoked transparently). Not driver code we write.

**Default sandbox resources** (overridable per request):
`requests: 100m CPU / 128Mi mem; limits: 500m CPU / 512Mi mem`.

## Isolation guarantees

The driver and the workloads it manages must not affect anything outside their
own namespace(s).

**What the driver writes — by namespace scope:**

| Resource | Scope | When |
|----------|-------|------|
| `Sandbox` (`agents.x-k8s.io/v1alpha1`) | namespace, driver namespace only | always |
| `APIRule` (`gateway.kyma-project.io`) | namespace, driver namespace only | only with `--enable-apirule` |
| `Service` (per sandbox) | namespace, driver namespace only | only with `--enable-apirule` |

**What the driver reads — by scope:**

| Resource | Scope | When |
|----------|-------|------|
| `Sandbox` get/list/watch | namespace | always |
| `Node` get/list | cluster, **read-only** | only with `--gpu-support=true` |
| `Gateway` (Istio) get | cluster, **read-only** | only with `--enable-apirule` to discover cluster domain |

**Hard guarantees enforced by RBAC + code:**

1. No cluster-scoped writes ever. RBAC has zero `*` verbs on cluster-scoped
   resources.
2. No cross-namespace reads. All informer/watch calls are namespace-scoped via
   `kube::Api::namespaced(client, &ns)`. The code has no path that takes
   "all namespaces".
3. No mutating/validating admission webhooks.
4. No DaemonSets, no node-level agents, no `hostPath`, no `hostNetwork`, no
   `hostPID`, no `hostIPC`.
5. No PriorityClass on driver or sandbox pods. Default priority — cannot
   preempt other workloads.
6. No PodDisruptionBudget that could block evictions outside the driver
   namespace.
7. No shared volumes across pods or namespaces. Only `emptyDir` per-pod.
8. No custom finalizers on Sandbox CRs. The agent-sandbox controller owns its
   finalizer lifecycle.
9. No labels/annotations on objects we did not create. No auto-enrollment
   labels on the sandbox namespace itself.
10. No registry mirrors, no `imagePullSecrets` injection into other
    namespaces' ServiceAccounts.

**Sandbox network isolation** (opt-in `--enable-network-policy`):

- Default-deny ingress for sandbox pods, with allow-rule for the driver's
  gateway sidecar pod (matched by label).
- Default-deny egress except DNS (UDP 53 to `kube-system` `kube-dns`) and the
  gateway service.

**Resource starvation prevention:**

- Sandbox pods always get explicit `resources.limits` (memory + CPU) — never
  unbounded. Driver injects defaults if a request omits them.
- Driver pod has its own modest limits (100m CPU / 128Mi memory).
- Neither uses `system-node-critical` or `system-cluster-critical` priority.

**Cluster-admin actions that remain the user's responsibility (driver never
does these):**

- Installing the agent-sandbox CRD (cluster-scoped, one-time).
- Installing the agent-sandbox controller into its own namespace.
- Labeling the sandbox namespace `pod-security.kubernetes.io/enforce: privileged`.
- Creating the sandbox namespace itself.

The Helm `pre-install` hook only checks these exist and fails with a clear
message if not — it never creates or modifies them.

**Tier-3 test safeguards.** Tier-3 tests refuse to run if
`INTEGRATION_TEST_NAMESPACE` is set to any of the well-known system namespaces
(`default`, `kube-system`, `kube-public`, `kube-node-lease`, `istio-system`,
`kyma-system`, `agent-sandbox-system`). The deny-list is extensible at runtime
via the `INTEGRATION_TEST_NAMESPACE_DENYLIST` env var (comma-separated) so
operators can protect additional sensitive namespaces without committing those
names to the repo. The default value `openshell-driver-test` is the only
namespace ever touched out-of-the-box, and the test harness creates and
(optionally) deletes it.

## Security and operational hardening

Scope matches NVIDIA OpenShell's visible practices: pragmatic, not
enterprise-grade. We deliberately do **not** add cosign signing, Trivy gates,
cargo-deny gates, or SBOM attachment, because NVIDIA does not visibly do those
either and we want to keep maintenance light.

**Container & runtime hardening (driver pod):**

- Distroless `nonroot` base image, multi-stage Cargo build with `cargo-chef`
  for cache-friendly rebuilds.
- `runAsNonRoot: true`, `runAsUser: 65532`, `readOnlyRootFilesystem: true`,
  `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`,
  `seccompProfile: RuntimeDefault`. Driver pod fits `restricted` PSS profile.
- No `hostPath`, no `hostNetwork`, no `hostPID`. Only the UDS via emptyDir
  shared with the gateway sidecar.
- ServiceAccount RBAC scoped to: `sandboxes.agents.x-k8s.io`
  get/list/watch/create/delete/patch in the configured namespace; cluster-scope
  `nodes` get/list only when GPU support is enabled. Optional `apirules`
  permission only when the APIRule flag is enabled.
- `sidecar.istio.io/inject: "false"` on the driver pod.

**Repo hygiene:**

- `LICENSE` (Apache-2.0), `THIRD-PARTY-NOTICES`. Vendored proto retains its
  NVIDIA SPDX header.
- `README.md`, `CONTRIBUTING.md`, `SECURITY.md` (vuln-reporting policy
  pointing to a private channel — no GitHub-issue route),
  `CHANGELOG.md` (Keep-a-Changelog).
- DCO sign-off enforced by a `dco.yml` workflow.
- `rust-toolchain.toml`, `Cargo.lock` committed.
- `.markdownlint-cli2.jsonc`.
- `.gitignore` and `.dockerignore` covering `target/`, `*.sock`, `kubeconfig*`,
  `*.kubeconfig`, `.env*`, secrets directories.
- Dependabot for `cargo` and `github-actions` ecosystems.

**Runtime behavior:**

- `tracing` JSON logger, `RUST_LOG` honored. Log only stable identifiers
  (sandbox name/id/namespace, condition reasons). Never log kubeconfig
  contents, bearer tokens, env-var values, or full sandbox specs.
- Graceful shutdown on SIGTERM via `tonic::Server::serve_with_shutdown`.
- `/healthz`, `/readyz`, `/metrics` HTTP endpoints on a separate port from
  the UDS, with bounded-cardinality Prometheus labels (no per-sandbox labels;
  counters by `result` and `event_type` only).

## Testing strategy

**Tier 1 — unit (pure Rust, fast):** module-level tests in `src/*.rs`. Cover
`helpers.rs` conversions, `provisioner.rs` build-pod-spec logic, `enricher.rs`
flag-driven mutations, error mapping. Use `kube::Client` with
`tower_test::mock::pair` — no real K8s, no fake CRD server.

**Tier 2 — gRPC contract (`tests/grpc_contract.rs`):** spin up a real `tonic`
server on a temp UDS, connect a real `tonic` client, exercise all 9 RPCs.
K8s layer mocked at the HTTP level. Proves wire-compatibility with the
upstream gateway protocol.

**Tier 3 — live integration (`tests/live_cluster.rs`, gated by
`INTEGRATION_TEST_NAMESPACE` env var):** exercises the driver against a real
Kyma cluster.

Cases (each creates a sandbox with a unique name, registers a cleanup):

1. `test_create_and_list_sandbox` — sandbox shows up in `ListSandboxes`.
2. `test_get_sandbox` — fields match what was created.
3. `test_delete_sandbox` — idempotent; second delete returns `deleted=false`.
4. `test_verify_labels` — `openshell.ai/managed-by`, `openshell.ai/sandbox-id`,
   `kagenti.io/type=agent` are present on the CR.
5. `test_verify_supervisor_init_container` —
   `spec.podTemplate.spec.initContainers[0].name == "supervisor-init"`.
6. `test_istio_inject_disabled` — when flag is `false`, the pod template
   carries `sidecar.istio.io/inject: "false"`.
7. `test_psa_check_fails_in_unprivileged_namespace` — driver refuses to start
   if PSA label is wrong.
8. `test_e2e_sandbox_runs` (live e2e smoke): create a Sandbox, wait up to
   90s for `status.conditions[type=Ready].status=True`, verify the pod is
   `Running`, then delete and confirm the CR disappears within 30s.

**Pre-flight (`setup_integration` helper) before tests:**

- Verify `KUBECONFIG` (or `~/.kube/config`) is set.
- Verify the Sandbox CRD is installed; skip the suite with a clear message
  if not.
- Verify `INTEGRATION_TEST_NAMESPACE` is not in the deny-list.
- Create the namespace if missing; label
  `pod-security.kubernetes.io/enforce: privileged`.
- Cleanup hook: at suite teardown, delete every Sandbox CR with
  `openshell.ai/managed-by=openshell` and (optionally, behind
  `INTEGRATION_DELETE_NAMESPACE=true`) delete the namespace.

## Build, release, and CI

**Local dev workflow:**

```
make proto              # regenerate tonic code (rare; only when .proto changes)
make build              # cargo build --release
make test               # Tier 1 + Tier 2
make test-integration   # Tier 3, requires INTEGRATION_TEST_NAMESPACE
make test-all           # all tiers
make image              # docker build using deploy/Dockerfile

# Containerized iteration (fast feedback, no GitHub Actions wait):
make dev-shell          # pre-warmed Rust toolchain container with project bind-mounted
make dev-test           # runs cargo fmt --check + clippy + tests inside the dev container
make dev-build          # builds the release binary inside the dev container
```

**Development container** (`deploy/Dockerfile.dev` + `Makefile` targets):

A pre-built image with the entire build toolchain baked in lets us reproduce
CI behavior locally without waiting on GitHub Actions, and gives a consistent
environment regardless of host OS (Linux / macOS / Windows-with-WSL2).

- Base: `rust:1.<workspace-pinned>-bookworm-slim`.
- Pre-installed: `cargo-chef`, `cargo-llvm-cov`, `clippy`, `rustfmt`,
  `protoc` (for tonic-build), `pkg-config`, `git`, `kubectl`, `helm`,
  `markdownlint-cli2`. Sized to be ~1 GB; built once, cached by Docker.
- The image's `WORKDIR` is `/workspace`. The Makefile mounts the project root
  there read-write and mounts a named Docker volume at `/workspace/target` so
  Cargo's incremental cache survives between runs (key win vs. rebuilding
  from scratch every time).
- For Tier-3 work the user can also mount `$HOME/.kube` read-only so
  `kubectl` and `kube-rs` see the existing kubeconfig — only used on
  explicit opt-in (`make dev-shell-with-kube`), never default.
- Built locally with `make dev-image` and tagged
  `openshell-driver-kyma-dev:latest`. Not pushed to any registry. The same
  Dockerfile can later be promoted to a CI base image if we want to skip
  toolchain install time in GitHub Actions.

**GitHub Actions (`.github/workflows/`):**

- `branch-checks.yml`: `cargo fmt --check`, `cargo clippy -D warnings -W clippy::pedantic`,
  `cargo build --release`, Tiers 1 + 2 tests. Runs on PR and push to main.
- `dco.yml`: enforces DCO sign-off on commits.
- `helm-lint.yml`: `helm lint deploy/helm/openshell-driver-kyma`.
- `docker-build.yml`: multi-stage image build, push to GHCR
  (`ghcr.io/<owner>/openshell-driver-kyma:<sha>`) on push to main; uses
  `GITHUB_TOKEN` so it works in a private repo with no extra secrets.
- `release-tag.yml`: on `v*` semver tag, build + push image with both
  `:vX.Y.Z` and `:latest`, generate a GitHub Release with auto-notes and the
  Helm chart packaged as a `.tgz` artifact.

**Dockerfile.** Standard cargo-chef → distroless-nonroot pattern. We prefer
`rustls` over `openssl-sys` so the final image can be `distroless/static`,
not `distroless/cc`.

**Helm chart (`deploy/helm/openshell-driver-kyma`):**

- `values.yaml` exposes every flag (`namespace`, `supervisorImage`,
  `enableApirule`, `gpuSupport`, `istioInjectSandboxes`,
  `enableNetworkPolicy`, etc.).
- Templates: `serviceaccount.yaml`, `role.yaml`, `rolebinding.yaml`,
  `clusterrole-nodes.yaml` (rendered only when `gpuSupport=true`),
  `deployment.yaml`, `service.yaml`, `networkpolicy.yaml` (rendered only when
  `enableNetworkPolicy=true`).
- `pre-install` hook: `kubectl get crd sandboxes.agents.x-k8s.io` check that
  aborts install with a clear error if the CRD is missing.
- All templates honor the `restricted` PSS profile for the driver pod.

**Release flow:** push semver tag `vX.Y.Z` → GHCR image + GitHub Release with
the chart packaged as a `.tgz`. No automatic chart-repo publishing in
Phase 1; users install via `helm install ./deploy/helm/openshell-driver-kyma`.

## Configuration flags (CLI / env / Helm `values.yaml` parity)

| Flag | Default | Purpose |
|------|---------|---------|
| `--socket` | `/var/run/openshell-driver.sock` | UDS path for gRPC |
| `--namespace` | `openshell-system` | K8s namespace for sandboxes |
| `--supervisor-image` | `ghcr.io/nvidia/openshell-community/supervisor:latest` | Supervisor OCI image |
| `--supervisor-binary-path` | `/usr/local/bin/openshell-sandbox` | Binary path inside supervisor image |
| `--supervisor-mount-path` | `/opt/openshell/bin` | Mount point in agent container |
| `--gateway-endpoint` | `""` | Gateway gRPC endpoint for supervisor callback |
| `--istio-inject-sandboxes` | `false` | Whether to allow Istio sidecar injection on sandbox pods |
| `--enable-apirule` | `false` | Create Kyma `APIRule` per sandbox |
| `--cluster-domain` | `""` (auto-detect) | Kyma cluster domain suffix; only used when `--enable-apirule` |
| `--gpu-support` | `true` | Whether to validate GPU capacity (requires cluster-scoped node read) |
| `--enable-network-policy` | `false` | Render the optional sandbox NetworkPolicy (Helm only) |
| `--health-port` | `9090` | HTTP port for `/healthz`, `/readyz`, `/metrics` |
| `--log-level` | `info` | tracing log level (also via `RUST_LOG`) |

## Open questions / risks

- **`agent-sandbox` CRD on Kyma.** The CRD is upstream Apache-2.0 and works on
  any Kubernetes ≥1.27. Validated by the Tier-3 e2e test before declaring
  done.
- **Privileged sandbox pods + Kyma PSA.** Requires labeling the sandbox
  namespace `privileged`. Documented as a prerequisite; Helm hook checks for
  it; driver fails fast if absent.
- **`kube-rs` vs OIDC kubeconfig.** Relies on `kube-rs` honoring `exec`
  credential plugins. Documented as an external dependency. If `kube-rs` ever
  regresses on this, the test harness will catch it.
- **Cluster-admin permission for GPU validation.** Mitigated by the
  `--gpu-support=false` opt-out.

## Sub-projects (none)

The scope is a single subsystem (one driver binary + chart + tests). It does
not need decomposition into independent specs.
