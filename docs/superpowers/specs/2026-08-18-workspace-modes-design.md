# Upstream v0.0.107 parity: workspace modes + sandbox start/stop — design

**Date:** 2026-08-18
**Status:** approved, not yet implemented
**Upstream reference:** NVIDIA/OpenShell v0.0.107

## Problem

v0.0.107 added two RPCs to the `ComputeDriver` contract:

```proto
rpc EnsureWorkspace(EnsureWorkspaceRequest) returns (EnsureWorkspaceResponse);
rpc DeleteWorkspace(DeleteWorkspaceRequest) returns (DeleteWorkspaceResponse);
```

`scripts/check-proto-drift.sh` flagged this as the first genuine contract
change since v0.0.97 — every sync since has been digests only.

**Nothing is broken today.** The gateway maps `Unimplemented` to `Ok(())`
(`openshell-server/src/compute/mod.rs:903`), the same tolerance as
`GetGatewayListenerRequirements`, so the driver keeps working untouched
against a v0.0.107 gateway. This is a capability gap, not an outage.

### What upstream actually models

The RPCs are the surface of a tenancy model with three modes
(`crates/openshell-driver-kubernetes/src/config.rs:99`):

| Mode | Namespace | Resource naming |
|---|---|---|
| `Shared` (default) | one static namespace | `{workspace}--{name}` |
| `Managed` | `openshell-{gateway_id}-{workspace}`, driver-created | `{name}` |
| `Operator` | pre-existing, allowlisted | `{name}` |

**This driver is already a correct `Shared`-mode driver** — single namespace,
`{workspace}--{name}` naming, adopted during the v0.0.91 sync. Upstream's own
description of `Shared` matches it line for line. So "follow upstream's
example" does not mean adopting namespace-per-workspace; it means implementing
the mode abstraction, of which today's behaviour is one branch.

## Decisions

1. **Full parity — all three modes.** Not Shared-only.
2. **Chart-conditional RBAC.** Shared installs gain zero privilege.
3. **Managed does a full bootstrap**, not just a namespace.
4. **Mode rules live in a new `src/workspace.rs`.**
5. **`StartSandbox` / `StopSandbox` are implemented for real**, both CRD
   versions, rather than left `unimplemented`.

## Architecture

New module `src/workspace.rs` owns every mode rule; nothing else knows how
modes work.

```rust
pub enum WorkspaceMode { Shared, Managed, Operator }   // Shared = default

pub fn namespace_for(cfg, workspace, allowlist) -> Result<String, DriverError>
//   Shared   -> cfg.namespace
//   Managed  -> openshell-{gateway_id}-{workspace}
//   Operator -> workspace, iff allowlisted, else PermissionDenied

pub fn kube_resource_name(mode, workspace, name) -> String
//   Shared            -> "{workspace}--{name}"
//   Managed|Operator  -> "{name}"

pub fn managed_namespace(gateway_id, workspace) -> String
pub fn validate_workspace_mode(cfg) -> Result<(), DriverError>   // startup
```

Two properties make this safe to land on a live cluster:

- **Every rule returns today's value under `Shared`.** An existing install
  behaves identically with no config change.
- **Lookup is already name-independent.** `find_by_sandbox_id` resolves CRs by
  the `openshell.ai/sandbox-id` label, never by name — forced by the v0.0.91
  rename. Changing the naming scheme per mode therefore cannot break
  `get`/`delete`; those paths only need the correct namespace to search.

### Consequential changes elsewhere

- `provisioner.rs` stops reading `cfg.namespace` (12 sites) and resolves the
  namespace per call from the sandbox's workspace.
- `detect_psa` moves from a one-shot startup check to a per-workspace check in
  Managed/Operator: the namespace it validates does not exist at startup.
  In **Managed** it runs *after* bootstrap has applied the label — it is a
  post-condition, not a precondition, and a failure there means the label
  did not stick (e.g. a policy controller stripped it). In **Operator** it
  is a genuine precondition and its existing error message already tells the
  operator exactly which `kubectl label ns` to run.
- New `--gateway-id` flag, defaulted in the chart from the existing
  `gateway.sandboxJwt.gatewayId`. It needs its own flag rather than reading the
  JWT config, because Managed must work with `sandboxJwt.enabled=false`.

## RPC semantics

Both mirror upstream's control flow (`grpc.rs:178-229`).

**`EnsureWorkspace`** — empty workspace → `invalid_argument`; validate the
name; then:

| Mode | Behaviour |
|---|---|
| `Shared` | nothing (upstream: `Shared => {}`) |
| `Operator` | allowlist check; `permission_denied` if absent |
| `Managed` | bootstrap, below |

**Managed bootstrap**, every step tolerating `AlreadyExists`:

1. Namespace `openshell-{gateway_id}-{workspace}`, labelled `managed-by`,
   `gateway-id`, `sandbox-workspace`
2. `pod-security.kubernetes.io/enforce=privileged`
3. ServiceAccount `openshell-sandbox`
4. NetworkPolicy — only when `driver.enableNetworkPolicy`, reusing the chart's
   existing rules

Steps 2-4 are Kyma-specific and have no upstream counterpart: `detect_psa`
hard-fails without the label, and `SANDBOX_SERVICE_ACCOUNT` is pinned into
every pod spec, so a bare namespace cannot run a sandbox.

**`DeleteWorkspace`** — empty → `invalid_argument`; only `Managed` touches
namespaces (`workspace_delete_requires_namespace_access` is
`matches!(mode, Managed)`). Managed keeps all four upstream guardrails:

- the name is **derived**, never operator-supplied, so it cannot target
  `sail-proxy`, `openwebui` or `kube-system`
- 404 → `Ok` (idempotent)
- **ownership-label check** — skip if not labelled for this gateway, which
  protects a pre-existing namespace that happens to match the convention
- **UID precondition** on the delete, so a namespace recreated between get and
  delete is not destroyed by a stale decision

`SandboxProvisioner` gains `ensure_workspace(&str)` and
`delete_workspace(&str)`. The enricher gains nothing.

### New failure surface

Today these RPCs return `Unimplemented` and the gateway swallows it. Once
implemented, a failure in `EnsureWorkspace` fails whatever explicitly called
it. **Correction (2026-08-19): the premise this section originally rested
on was wrong.** It assumed the gateway calls `EnsureWorkspace` before every
sandbox create — it does not. Grepping the gateway at v0.0.109,
`ensure_workspace` appears zero times in `crates/openshell-server/src/grpc/
sandbox.rs`; its only callers are `grpc/provider.rs:2238`, `:3396`, and
`provider_refresh.rs:550`, all gated on `stores_provider_credentials()`. It
is also not called by `openshell workspace create`. Upstream's own
Kubernetes driver does not rely on the RPC either — it bootstraps the
managed namespace lazily inside `create_sandbox` itself (`driver.rs:1358`).
`KymaProvisioner::create` now does the same (see the CI-parity fix report
under `.superpowers/sdd/2026-08-18-v0.0.107-parity/`): it calls
`bootstrap_managed_namespace` directly under `Managed`, so a real cluster
never depends on `EnsureWorkspace` having been called first. The RPC itself
is unchanged and remains part of the contract; it is simply not the only
path to bootstrap any more, and the idempotence bootstrap already had turns
out to matter for a different reason: `create` calls it on every single
sandbox create, not once per workspace.

## RBAC and chart wiring

| Mode | Rendered |
|---|---|
| `shared` | today's namespaced Role — **unchanged** |
| `operator` | ClusterRole: sandboxes, pods, PVCs cluster-wide |
| `managed` | the above **plus** namespaces `create/delete/get/list`, serviceaccounts `create`, networkpolicies `create` |

New values:

- `driver.workspaceMode` — `shared` (default) / `managed` / `operator`
- `driver.gatewayId` — defaults from `gateway.sandboxJwt.gatewayId`
- `driver.operatorNamespaceAllowlist` — list, required when mode is `operator`.
  **Static, read once at startup** from the flag. Upstream's type is
  refreshable; we do not need that, and a static list keeps the failure mode
  obvious (a namespace added to the chart requires a restart, not a silent
  partial rollout).

A `{{- fail -}}` guard rejects `managed` without a DNS-1123 `gatewayId`, and
`operator` with an empty allowlist — mirroring upstream's
`validate_workspace_mode` and the chart's existing guard style.

### Operator mode prerequisite (deliberate gap)

Upstream's Operator mode only checks the allowlist; it does not bootstrap.
This driver pins `openshell-sandbox` into every pod spec, so an
operator-managed namespace lacking that ServiceAccount produces pods that
never start.

**Decision: document it as an Operator-mode prerequisite** — the namespace must
carry the PSA label and the `openshell-sandbox` SA — rather than grant
cluster-wide `serviceaccounts: create` for a mode whose entire premise is that
the platform team owns namespace contents.

## Migration — breaking

Switching modes changes both the namespace and the resource names, so existing
sandboxes become unreachable: `default--hello4` in `openshell-system` has no
counterpart in `openshell-{gateway_id}-default`.

**Delete sandboxes before switching modes, then recreate.** This is the same
class of migration as the v0.0.91 rename and must be documented as loudly, in
`docs/internal/runbook-upstream-sync.md` and the CHANGELOG. The mode is not
something to flip on a cluster with live sandboxes.

## Testing

- **`workspace.rs`** — table-driven unit tests over all three modes, plus the
  guardrail predicates. These are pure functions; cover naming, namespace
  resolution, allowlist rejection, and startup validation.
- **`grpc_contract.rs`** — both RPCs: empty workspace, each mode's dispatch,
  and the ownership-check skip.
- **Interop smoke stays on `shared`**, so it keeps exercising the deployed path.
- **New `managed` smoke job.** Proves namespace bootstrap and the
  ownership-guarded delete against a real API server. Roughly doubles smoke
  runtime, accepted deliberately: namespace deletion is precisely the behaviour
  that must not ship on unit tests alone. It must assert both directions —
  that an owned namespace IS deleted, and that an unlabelled namespace of the
  same name is NOT.

## Sandbox start/stop

A second, independent subsystem in the same v0.0.107 parity push. Unlike the
workspace RPCs this closes a **functional** gap, not a capability one: the
gateway does not swallow `Unimplemented` for these (`compute/mod.rs:1048`,
`:1203`), so `openshell sandbox stop` fails against this driver today.

Both were stubbed as `unimplemented` — `StopSandbox` since the original build,
`StartSandbox` added by the v0.0.106 sync (PR #24), which mirrored the existing
stub. Correct at the time; now replaced.

### Mechanism

Upstream patches the Sandbox CR's operating state, dispatching on the served
API version (`driver.rs:4254`):

```
v1beta1  -> spec.operatingMode: "Running" | "Suspended"
v1alpha1 -> spec.replicas: 1 | 0
```

**Both are implemented**, matching upstream, even though the installed CRD
currently serves only `v1alpha1` (verified: `served=true, storage=true`, and no
`v1beta1`). The `v1beta1` branch is dead code today. It is included on purpose:
when agent-sandbox starts serving `v1beta1`, a `v1alpha1`-only driver would
silently patch a field the new CRD ignores — a quiet breakage, which is exactly
the failure class this repo's upstream tracking exists to prevent.

### Semantics

- Empty `sandbox_id` → `invalid_argument`, matching upstream's guard.
- Resolve the CR through the existing `find_by_sandbox_id` label selector —
  the same name-independent lookup the workspace work relies on.
- Patch with a **`resourceVersion` precondition** (optimistic concurrency), so
  a concurrent update fails the patch rather than clobbering it.
- `StopSandbox` then **polls until the pod is actually gone**, bounded by a
  timeout; returning before termination would let the gateway believe a
  sandbox is stopped while its pod still runs.
- Timeout: reuse upstream's shape — a bounded deadline with backoff. Default
  120s, exposed as `driver.stopTimeoutSecs` so an operator can raise it for
  slow-terminating workloads.
- `NotFound` from the selector → `not_found`, not `internal`.

`SandboxProvisioner` gains `start_sandbox(&str)` and `stop_sandbox(&str)`.

### Testing

- Unit tests for the patch-payload builder across both API versions and both
  directions (running/suspended) — a pure function, table-driven.
- Contract tests: empty `sandbox_id`, and that neither RPC returns
  `Unimplemented` any more.
- The `shared` interop smoke gains a stop → verify pod gone → start → verify
  Ready cycle on a real cluster. This is the only way to prove the poll loop
  and the replicas patch actually work against a live agent-sandbox controller.

## Implementation phasing

Five phases, each independently mergeable and each leaving `main` shippable.
`Shared` stays the default throughout, so nothing changes for the deployed
cluster until someone opts in.

0. **Proto bump to v0.0.107.** The vendored proto is pinned at v0.0.106 and
   does **not** contain `EnsureWorkspace`/`DeleteWorkspace`. Everything below
   depends on `make proto-vendor TAG=v0.0.107` landing first.
1. **Start/stop.** Sequenced first because it is the only phase closing a
   functional gap users hit today (`openshell sandbox stop` currently fails).
   Independent of the workspace work; costs a rebase over later
   `provisioner.rs` churn, accepted deliberately for earlier value.
2. **Shared parity.** `workspace.rs` with all three modes defined, both
   workspace RPCs implemented, `Shared` wired end to end. Provisioner switches
   to resolved namespaces. No RBAC change, no chart values beyond
   `workspaceMode`. Zero behaviour change.
3. **Managed.** Bootstrap, guarded delete, conditional ClusterRole,
   `gatewayId`, the `managed` smoke job. The destructive phase; it should not
   share a PR with anything else.
4. **Operator.** Allowlist config, validation, the documented prerequisite.
   Smallest phase; no bootstrap, no namespace lifecycle.

## Out of scope

- Changing the deployed cluster's mode. It stays `shared`; this work only makes
  other modes available.
- Multi-namespace `list`/`watch` optimisation. Both already filter by the
  `managed-by` label and work cluster-wide once RBAC allows it.
- `driver_config` passthrough (`DriverSandboxTemplate.driver_config`), still
  unwired since v0.0.91 and unrelated.
