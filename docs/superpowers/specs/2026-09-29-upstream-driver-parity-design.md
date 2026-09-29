# Upstream Kubernetes driver parity — design

Status: approved (design), not yet implemented
Target release: v0.9.0
Upstream reference: NVIDIA/OpenShell v0.1.2, `crates/openshell-driver-kubernetes`

## Problem

v0.8.0 migrated the driver↔gateway contract to upstream v0.1.2 and it works:
on the Kyma cluster the gateway logs `Compute driver connected`, so the
schema-v2 config, capability negotiation and admission acknowledgement are all
accepted. Sandboxes, however, do not run. Deploying v0.8.0 exposed two further
v0.1.2 changes outside that migration's scope:

1. **The sandbox runtime was re-architected.** Upstream renamed the supervisor
   binary (`/openshell-sandbox` → `/openshell-supervisor`) and changed its
   contract: it now runs as a separate hardened supervisor pod
   (`os-supervisor-<suffix>`: non-root, read-only root filesystem, all
   capabilities dropped, health-socket readiness probe), driven by a backend
   descriptor and an auth bundle delivered through per-sandbox bootstrap
   Secrets, behind an "authenticated boundary protocol". Our init container
   fails with `--backend-descriptor-file is required for --role=isolation-backend`.
   Pinning the previous supervisor image gets the pod to Kubernetes `Ready`, but
   the gateway never leaves `Provisioning` because a v0.0.116-era supervisor
   cannot complete v0.1.2's delegated bootstrap. There is no working
   combination without adopting the new runtime.
2. **`openshell inference set` no longer exists.** "Inference" survives only as
   a provider-profile category. The chart's inference-provider hook is dead.

CI did not catch either because `scripts/interop-smoke.sh` deliberately stops at
"Sandbox CR created", never at "pod Ready".

The requirement is explicit: **nothing below 100% feature parity with
upstream's Kubernetes driver is acceptable.** Upstream's driver is ~16.8k lines
(`driver.rs` alone 11.7k); ours is ~10.8k and a runtime generation behind.
Porting would make parity approximate and permanently lagging.

## Goal and success criteria

- Every RPC, capability and configuration option that upstream's
  `openshell-driver-kubernetes` supports at the pinned tag behaves identically
  in this driver — including the supervisor pod runtime, bootstrap Secrets, the
  isolation boundary, resource admission with workload references, upstream
  proxy (auth, CA bundle, connect-by-hostname), SPIFFE workload API, client
  TLS, managed SSH ingress, user namespaces, workspace modes and operator
  namespace selection.
- Kyma-specific value is kept on top: per-sandbox APIRule exposure, Istio
  coexistence, PSA handling, Claude telemetry opt-out.
- Parity **holds** across upstream releases: drift fails CI rather than
  shipping.
- Observable on the cluster: sandboxes bootstrap and run, stop/start round-trip,
  and APIRule exposure reaches the sandbox.

## Decisions

1. **Build on upstream's driver as a library** (approach A). Rejected: porting
   upstream's runtime (parity lags forever) and running upstream's binary
   unmodified with a separate Kyma controller (adds a component, and the driver
   stops being a product).
2. **Forward every RPC through upstream's own `ComputeDriverService`**, not just
   its driver methods, so capability, admission and authentication logic are
   upstream's verbatim.
3. **Adopt upstream's configuration surface 1:1.** Where our historical flag
   and upstream's differ, upstream wins; the chart maps values accordingly.
4. **Carry Kyma pod-level behaviour by editing the create request**, using the
   `labels` and `environment` maps on `DriverSandboxTemplate`, which upstream
   applies. No post-hoc pod patching and no mutating webhook.
5. Release as **v0.9.0** — an architectural break.

## Architecture

```
gateway ──UDS──▶ KymaComputeDriver ──forwards──▶ upstream ComputeDriverService
                    │  (3 hooks)                        │
                    │                                   └─▶ KubernetesComputeDriver
                    └─▶ Kyma layer: request labels/env,     (supervisor pod, bootstrap
                        Service+APIRule, namespace labels     Secrets, isolation, admission)
```

- **Dependency.** `openshell-driver-kubernetes` (and, transitively,
  `openshell-core`, `openshell-isolation-interface`,
  `openshell-sandbox-backend`, `openshell-policy`, `openshell-otel`) as a git
  dependency on `NVIDIA/OpenShell` at the pinned tag. Upstream vendors `protoc`
  (`protoc-bin-vendored`), so no system toolchain is added; upstream requires
  Rust ≥ 1.94 and this workspace pins 1.95.
- **Types.** Proto types come from `openshell_core::proto`. The vendored-proto
  `computev1` crate, `scripts/vendor-proto.sh` and the proto-drift check retire;
  proto drift is impossible when the types are upstream's own.
- **Binary.** `main.rs` builds `KubernetesComputeConfig` from the mirrored flag
  surface, calls `KubernetesComputeDriver::new(...)`, wraps it in
  `ComputeDriverService::new(driver)`, and serves `KymaComputeDriver` over the
  compute-driver Unix socket, mirroring upstream's `main.rs` wiring.
- **`KymaComputeDriver`** implements the tonic `ComputeDriver` trait by holding
  the upstream service and delegating every method. Only three methods add
  behaviour (next section); the rest are single-line forwards.

## The Kyma layer

The only behaviour this repository owns. Each hook is small, isolated in its
own module, and unit-testable against a mocked inner service.

**1. Before `CreateSandbox` — request enrichment.** Add to the sandbox
template's `labels`: `sidecar.istio.io/inject: "false"` (the only place Istio
is handled; unless
`--kyma-istio-inject-sandboxes`) and the kagenti type label. Add to
`environment`: the Claude telemetry opt-out when `--kyma-disable-claude-telemetry`
is set. Caller-supplied keys win over enrichment, so a caller can override
deliberately. Then forward.

**2. After `CreateSandbox` succeeds / before `DeleteSandbox` — exposure.** When
`--kyma-enable-apirule` is set, reconcile a per-sandbox Service selecting the
agent workload and an APIRule `<ws>--<sb>.<cluster-domain>` → port 8080,
owner-referenced to the Sandbox CR so Kubernetes garbage-collects them. An
exposure failure is logged and surfaced as a Kubernetes Event on the Sandbox;
it never fails the create, because the sandbox itself is healthy. Delete is
best-effort and never blocks upstream's deletion.

**3. `EnsureWorkspace` — namespace labelling.** After upstream creates or
confirms a workspace namespace, apply the PSA labels the runtime requires.
Idempotent patch; `DeleteWorkspace` needs no hook. Istio is deliberately NOT
handled at namespace level: in Shared mode the sandbox namespace is the
release namespace, and labelling it `istio-injection: disabled` would pull the
gateway itself out of the mesh and break its egress to the upstream inference
proxy. Istio opt-out is pod-level only, via hook 1. The Shared-mode namespace's
PSA labels stay chart-managed, as today.

Everything else currently in this repository retires: the provisioner,
`driver_config` decoding, workspace-mode logic, sandbox authentication, runtime
identity, admission acknowledgement and capability reporting. Upstream
implements all of it.

## Configuration

The driver accepts upstream's options with **the same long names and the same
environment variables** (39 options at v0.1.2, including
`OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON`, the upstream-proxy family, SPIFFE,
client TLS, managed SSH ingress, `OPENSHELL_SUPERVISOR_IMAGE` and
`OPENSHELL_SANDBOX_RUNTIME_IMAGE`). Kyma options carry a `--kyma-` prefix so the
two sets can never collide.

Mapping of today's flags:

| Today | v0.9.0 |
|---|---|
| `--socket` | upstream `--bind-socket` / `OPENSHELL_COMPUTE_DRIVER_SOCKET` |
| `--namespace` | upstream `--sandbox-namespace` |
| `--supervisor-image` | upstream `--supervisor-image` |
| `--gateway-endpoint` | upstream `--grpc-endpoint` |
| `--enable-user-namespaces` | upstream `--enable-user-namespaces` |
| `--log-level`, `--workspace-mode`, `--gateway-id` | upstream equivalents |
| `--operator-namespace-allowlist` | upstream `--operator-namespace-label` / `--operator-namespace-file` (upstream's mechanism replaces ours) |
| `--allow-driver-config`, `--driver-config-allow-volumes` | upstream `OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON` (upstream resource admission now governs caller volumes, closing the v0.8.0 known gap) |
| `--supervisor-binary-path`, `--supervisor-mount-path`, `--sandbox-uid`, `--sandbox-gid`, `--stop-timeout-secs`, `--gpu-support`, `--enable-network-policy`, `--telemetry-enabled`, `--sandbox-storage-size`, `--sandbox-storage-class` | removed — superseded by upstream's runtime, isolation or `driver_config` |
| `--istio-inject-sandboxes`, `--enable-apirule`, `--cluster-domain`, `--disable-claude-telemetry` | Kyma: `--kyma-istio-inject-sandboxes`, `--kyma-enable-apirule`, `--kyma-cluster-domain`, `--kyma-disable-claude-telemetry` |
| `--health-port` | Kyma: `--kyma-health-port`. Upstream exposes only its gRPC bind and no HTTP health endpoint, while this chart's liveness/readiness probes use HTTP `/healthz`, so the endpoint is Kyma-owned |

**The admission coupling survives in upstream's form.** The gateway derives its
policy from `[openshell.drivers.kyma]`; upstream's driver takes its policy from
`OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON`. The chart renders both from one
values block, exactly as v0.8.0 did for `allow_driver_config`, so they cannot
disagree.

## Chart

- **RBAC mirrors upstream's chart** for the driver ServiceAccount — whatever the
  supervisor pod, bootstrap Secrets, NetworkPolicies and workload references
  require — plus the Kyma layer's APIRule, Service and namespace-label
  permissions. The planning phase derives the exact rules from upstream's
  `deploy/helm/openshell/templates/{clusterrole,role}.yaml` at the pinned tag.
- **Images derive from the pinned upstream ref**: gateway, supervisor and
  sandbox runtime. No template hard-codes a version.
- The gateway TOML stays as v0.8.0 shipped it (schema v2).
- Values for removed flags are dropped, with a CHANGELOG migration table.

## Providers

The inference-provider hook is rewritten for v0.1.2's provider-profile model.
Gateway config gains `provider_profile_sources = [{ type = "user" }]`, and the
hook creates the Anthropic profile, the provider and its credential through the
CLI matching the pinned upstream ref. The CLI version is derived from that ref,
never hard-coded. The exact v0.1.2 commands are taken from the v0.1.2 CLI
source during planning and verified against the running gateway.

## Keeping parity

- **Flag-surface test.** CI extracts upstream `main.rs`'s option set at the
  pinned tag and fails if this driver does not accept every one of them under
  the same name and environment variable.
- **Runtime smoke.** `interop-smoke.sh` and `managed-smoke.sh` extend past
  "Sandbox CR created" to: supervisor pod Ready; gateway phase leaves
  `Provisioning` (bootstrap complete); a stop/start round-trip returns to
  running. This is the check whose absence let v0.8.0 ship broken.
- **Dependency tracking.** The weekly upstream sync bumps the git dependency's
  tag together with `GATEWAY_REF`, so the driver library, gateway, supervisor
  and CLI always move as one version.

## Rollout

- v0.9.0. Breaking: drain and recreate sandboxes, because the pod topology
  changes. Chart values for removed flags must be removed.
- Cluster verification before the release is called done: create, bootstrap,
  stop/start, APIRule reachability over HTTPS, and the inference provider
  configured and usable from a sandbox.

## Risks and verification items

These are resolved in planning with the decision rule stated, not left open.

- **APIRule ingress versus upstream isolation.** Upstream's per-sandbox
  NetworkPolicies may deny inbound 8080 to the agent pod. Verify on the cluster
  first. If it is denied, exposure adds an explicit NetworkPolicy allowing the
  Istio ingress gateway to reach port 8080, owned by the Kyma layer — never a
  change to upstream's policies.
- **Upstream's library API is not a stability promise.** The wrapper touches
  few symbols (`KubernetesComputeConfig`, `KubernetesComputeDriver::new`,
  `ComputeDriverService::new`, the trait). The pinned tag and the flag-surface
  test make breakage loud at bump time.
- **Namespace PSA level.** The supervisor pod is restricted-compatible; the
  agent workload may need more. The Kyma layer sets whatever level upstream's
  workload requires, derived from the running pods' security contexts, not
  assumed.
- **Build time** grows with upstream's crates. Mitigated by the existing cargo
  cache volume and CI cache.

## Out of scope

- Upstream's gateway chart as a whole. This chart keeps its gateway sidecar;
  only driver-relevant parts (RBAC, images, admission) mirror upstream's chart.
- Any change to upstream code. If the wrapper needs a hook upstream lacks, that
  becomes an upstream issue, not a fork.
