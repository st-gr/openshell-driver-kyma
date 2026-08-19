# Changelog

All notable changes to openshell-driver-kyma are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Implemented the `StopSandbox` and `StartSandbox` RPCs — this branch's
  headline fix.** `StopSandbox` patches the Sandbox CR to a stopped
  operating state, then polls until its pod has actually gone, bounded by
  the new `--stop-timeout-secs` (`driver.stopTimeoutSecs`, default `120`);
  returning as soon as the patch is accepted would let the gateway believe
  a sandbox is stopped while its pod keeps running. `StartSandbox` (added
  in `[0.3.3]` below as an `Unimplemented` placeholder pending this) now
  performs the matching resume patch. **This supersedes the `[0.3.3]` note
  that this driver's `StopSandbox`/`StartSandbox` are themselves
  `Unimplemented` — that statement no longer holds.**
- **Added `driver.stopTimeoutSecs`** (default `120`), passed as
  `--stop-timeout-secs`.
- **Added `driver.gatewayId`** (default `""`, falling back to
  `gateway.sandboxJwt.gatewayId` when unset — itself defaulting to the
  chart's fullname), passed as `--gateway-id`. Required, and must be a
  DNS-1123 label, when `driver.workspaceMode` is `managed` — it becomes
  part of every managed namespace's name
  (`openshell-{gatewayId}-{workspace}`).
- **Added `driver.operatorNamespaceAllowlist`** (default `[]`), passed as
  `--operator-namespace-allowlist`. Required and non-empty when
  `driver.workspaceMode` is `operator`; an empty allowlist denies every
  workspace.
- **The driver refuses to start with `--workspace-mode managed
  --enable-network-policy=true`.** Managed-namespace `NetworkPolicy`
  support is not implemented (`bootstrap_managed_namespace` deliberately
  does not create one — porting the chart's Helm-templated
  `NetworkPolicy` into Rust would mean maintaining the same security
  policy in two languages that must never drift). Continuing anyway would
  silently give sandboxes in managed namespaces weaker network isolation
  than the shared namespace's, so `main.rs` refuses to start with that
  combination rather than let it happen quietly. Use `--workspace-mode
  shared` (the default) if network policy enforcement is required.
- **Implemented the `EnsureWorkspace` and `DeleteWorkspace` RPCs**, backed by
  a new `src/workspace.rs` that centralizes every tenancy rule behind three
  modes: `Shared` (default), `Managed`, and `Operator`. All three are now
  fully implemented: `Shared` reproduces this driver's pre-existing
  single-namespace behavior, `Managed` derives, creates and tears down a
  namespace per workspace, and `Operator` resolves sandboxes into
  pre-existing, allowlisted namespaces that a platform team owns — the
  driver only ever reads them, and never creates or deletes them.
- **Implemented `Operator` workspace mode.** `ensure_workspace` resolves the
  namespace through the allowlist check already in `workspace::namespace_for`
  (`PermissionDenied` for a workspace that isn't allowlisted), then verifies
  the namespace carries `pod-security.kubernetes.io/enforce=privileged` as a
  genuine precondition — unlike `Managed`, where the same check is a
  post-condition on a label the driver itself just applied. `delete_workspace`
  stays a no-op under `Operator`: the driver never created these namespaces
  and must never remove them. The chart's ClusterRole for `operator` gains
  `namespaces: ["get"]` (never `create`/`delete`) so that precondition check
  can read the namespace; see the new "Operator mode prerequisite" section of
  `docs/internal/runbook-upstream-sync.md` for what the platform team must
  prepare — the PSA label and an `openshell-sandbox` ServiceAccount — before
  adding a namespace to `driver.operatorNamespaceAllowlist`.
- **Added the `driver.workspaceMode` Helm value**, defaulting to `shared`.
  It is passed to the driver as `--workspace-mode` and accepts `shared`,
  `managed`, or `operator`. A default install is unaffected: `shared`
  reproduces every namespace and object-naming rule this driver used before
  this change.
  **Switching workspace modes is breaking.** Both the namespace a sandbox
  lives in and its object names change with the mode, so sandboxes created
  under one mode become unreachable (not deleted — orphaned) once the mode
  changes. Delete every sandbox before switching `driver.workspaceMode`, and
  recreate them afterwards.
- **Added support for `driver_config` (proto field 12,
  `DriverSandboxTemplate.driver_config`)** — the structured channel through
  which a caller configures Kyma-specific pod knobs: node selector,
  tolerations, priority class name, runtime class name (following
  `platform_config` > `driver_config.pod` > cluster-default precedence),
  and per-container resource/volume/volume-mount overrides for the agent
  container. `src/driver_config.rs` decodes and enforces eleven validation
  rules ported from upstream's `validate_kubernetes_driver_volumes`/
  `validate_kubernetes_driver_volume_mounts` (DNS-1123 name shape, reserved-
  and duplicate-name rejection, PVC claim name shape, a `read_only=false`
  mount against a `read_only=true` PVC, mount-target conflicts with this
  driver's own control paths and the `/sandbox` workspace root, duplicate
  normalized mount targets, sub-path validation), plus two driver-specific
  checks rejecting a mount that overlaps the projected SA-token mount or
  the supervisor-binary mount. An explicit `driver_config` mount at or
  under `/sandbox` now takes over workspace persistence instead of this
  driver's own PVC injection.

  **`driver_config.volumes[].persistent_volume_claim.claim_name` is
  operator-trust-level input.** Validation constrains it to a DNS-1123
  subdomain only — there is no ownership check or allowlist against other
  sandboxes' PVCs. In `Shared` mode (the default), every sandbox's
  workspace PVC lives in one namespace under the predictable name
  `{workspace}--{name}-workspace`, so a template author with `driver_config`
  access can name another sandbox's workspace PVC and mount it read-write.
  Upstream's Kubernetes driver has the identical validation shape, so this
  is inherited contract behavior, not a defect introduced here — but it is
  a genuinely new capability on this branch, and this driver's `Shared`
  default co-locates every tenant's sandboxes in one namespace, which makes
  the exposure easier to hit than it may be for upstream's callers. See
  "`driver_config` volumes are operator-trust-level input" in
  `docs/internal/runbook-upstream-sync.md`. **Gated off by default — see the
  next entry.**
- **Added `driver.driverConfigAllowVolumes`** (default `false`), passed as
  `--driver-config-allow-volumes`. Gates exactly the exposure described
  above: with it off (the default), a `driver_config` that declares
  `volumes[]` or `containers.agent.volume_mounts[]` is rejected with
  `PermissionDenied`, naming this flag, before the request reaches the
  cluster — enforced from both `CreateSandbox` and `ValidateSandboxCreate`.
  The rejection is deliberately a different error from a malformed
  `driver_config` (which still returns `InvalidArgument` with the specific
  rule it violated) so an operator can tell "this request is disallowed by
  policy" apart from "this request is broken." Scoped precisely to
  `volumes`/`containers.agent.volume_mounts` — `driver_config.pod.*` and
  `containers.agent.resources` are not the exposure and keep working
  regardless of this flag. `driver_config` support is new and unreleased on
  this branch, so defaulting this off is not a regression for anyone.
- **`platform_config.host_users` and `platform_config.agent_socket_path` are
  now honored per sandbox**, closing two v0.0.107 parity gaps.
  `host_users` overrides the cluster-wide `--enable-user-namespaces` default
  for that one sandbox — **note the inversion: `host_users: true` means the
  pod uses the *host* user namespace, i.e. Kubernetes' `hostUsers` is left
  unset and per-sandbox user-namespace isolation is OFF**; a non-bool value
  is treated as absent, matching upstream's `platform_config_bool`.
  `agent_socket_path`, when non-empty, is threaded into the Sandbox CR as
  `agentSocket`; omitted from the CR body entirely when empty, so existing
  sandboxes' CRs are unchanged.
- **Vendored `crates/openshell-core/src/driver_mounts.rs` from upstream
  v0.0.107 (Apache-2.0)** into `src/vendor/driver_mounts.rs`, with one
  documented, mechanically-reversible local patch (an import this crate
  can't satisfy, replaced by the same constants inlined by value).
  Provenance recorded in `src/vendor/UPSTREAM.lock`. The new
  `scripts/check-vendor-drift.sh` (wired into CI, and into the new `make
  vendor-check` target) checks the vendored body against upstream at the
  pinned commit, the recorded checksum, the local patch block's own
  reversibility, the patch block's `CONTROL_ROOTS`/`OCI_RUNTIME_MOUNT_ROOTS`
  literal values against upstream's `container_paths.rs`, and the
  provenance header's `commit:` line against the pin.

### Changed

- **Synced the `ComputeDriver` contract to upstream v0.0.107.** Diff against
  the previous v0.0.106 pin: `EnsureWorkspace`/`DeleteWorkspace` were added
  (implemented above); `scripts/check-proto-drift.sh` passes against the
  new pin.
- **Fixed `upstream-sync.yml` conflating the vendored-contract pin with the
  gateway/supervisor image pin.** `resolve-upstream-refs.sh`'s `GATEWAY_TAG`
  pins the gateway *image*; `proto/UPSTREAM.lock`'s `ref` pins the vendored
  *contract* — the sync job previously built its Claude prompt and
  branch/commit/PR naming entirely from `GATEWAY_TAG`, so pinning it behind
  the contract pin would have told the next weekly run to re-vendor the
  protos backward. `check-proto-drift.sh` now emits a stable
  `VENDOR_TARGET_TAG`; the sync job uses it for every contract-facing string
  and leaves `GATEWAY_IMAGE`/`SUPERVISOR_IMAGE` alone for the image-digest
  bump. An empty or malformed `VENDOR_TARGET_TAG` now fails the job loudly
  instead of silently falling back to `GATEWAY_TAG`. `vendor-proto.sh` also
  now refuses to vendor a tag older than the current pin without an
  explicit `VENDOR_ALLOW_DOWNGRADE=1`.
- **Added `scripts/check-pin-status.sh`**, an advisory (never-failing)
  reporter on the `GATEWAY_REF` pin in `.github/upstream-compat.env`. While
  pinned, the weekly detect job's staleness check compares pinned digests
  against themselves and stays green forever, so a pin whose reason has
  evaporated could sit unnoticed for months; this script closes that blind
  spot by checking whether both gateway and supervisor images now exist for
  the newest upstream tag. `PIN_REASON`/`PIN_REVIEW_AFTER` metadata keys
  were added to `upstream-compat.env` (currently empty; `GATEWAY_REF`
  remains un-pinned — whether to pin is a decision for the repo owner).
- **Synced the vendored contract and pinned images to upstream v0.0.109.**
  Upstream tagged v0.0.107 and v0.0.108 but published no container images
  for either; v0.0.109 is the newest tag with published images.
  `proto/UPSTREAM.lock`'s protos and
  `crates/openshell-driver-kyma/src/vendor/UPSTREAM.lock`'s Rust source are
  **byte-identical** to v0.0.107 (same per-file checksums recorded under the
  new ref/commit) — `scripts/check-proto-drift.sh` and
  `scripts/check-vendor-drift.sh` both confirm this and no driver code
  changed as a result; this was a pin bump, not a contract migration.
  `check-proto-drift.sh` no longer emits its "N releases behind"
  `ADVISORY:` line.
- **Re-pinned `gateway.image.tag` and `driver.supervisorImage` by digest** to
  the v0.0.109 builds, resolved via `scripts/resolve-upstream-refs.sh`:
  - gateway: `sha256:deb2065ed7319e4a481f7b1d01774dc04fabd6457b11f196fb5bd0baf60592ca`
  - supervisor: `sha256:7cae8e3f477d3281e3a27bd921745e68895d0a80b16d10a107867bdfb386ae5b`

  This closes the last remaining feature-parity gap: until now a default
  install ran a gateway that predates `EnsureWorkspace`/`DeleteWorkspace`,
  so this branch's new RPCs were never exercised end to end.

## [0.3.3] — 2026-08-17

### Added

- **Implemented the `StartSandbox` RPC** added upstream in v0.0.106, the
  resume counterpart to `StopSandbox`. This driver's `StopSandbox` is itself
  `Unimplemented` (it has no "stopped" lifecycle state — see `driver.rs`), so
  there is nothing for `StartSandbox` to resume from either; it returns
  `Unimplemented` for the same reason, matching `StopSandbox`'s existing
  behavior rather than guessing at semantics for a state this driver cannot
  enter. No upstream Kubernetes driver source is vendored into this repo, so
  if/when `StopSandbox` gains a real implementation, `StartSandbox` needs
  matching logic added at the same time — flagged with a TODO at the call
  site in `driver.rs::start_sandbox`.

### Changed

- **Synced the `ComputeDriver` contract to upstream v0.0.106.** Diff against
  the previous v0.0.102 pin: `StartSandbox`/`StartSandboxRequest`/
  `StartSandboxResponse` were added (see above) and the `StopSandbox` RPC
  doc-comment was reworded; `proto/options.proto` is unchanged.
  `scripts/check-proto-drift.sh` passes against the new pin. `cargo build
  --workspace --all-targets` required exactly one fix: implementing the new
  `start_sandbox` trait method.
- **Re-pinned `gateway.image.tag` and `driver.supervisorImage` by digest** to
  the v0.0.106 builds:
  - gateway: `sha256:a3804181521e6fe326abee5092a93c80bf3f85da6a7e68316f7d66512782f928`
  - supervisor: `sha256:722f44669722961b7f432b0b81de25b91a58f34a61d6403bef967acaf2b3af01`

## [0.3.2] — 2026-08-11

### Changed

- **Synced the `ComputeDriver` contract to upstream v0.0.102.** The vendored
  protos are **byte-identical** to v0.0.99 (`proto/UPSTREAM.lock` records the
  same per-file checksums under the new ref/commit) — `scripts/check-proto-drift.sh`
  confirms this and no driver code changed as a result. `cargo build
  --workspace --all-targets` is clean against the new pin with no code
  changes required. This was a pin bump rather than a contract migration.
- **Re-pinned `gateway.image.tag` and `driver.supervisorImage` by digest** to
  the v0.0.102 builds:
  - gateway: `sha256:47f5ca7b3c368841fe0ab8ef33d409ffedc6b937019d2a187b0cc4380f8ad976`
  - supervisor: `sha256:5e33ec485b9e05a00431a23faabf4a49376b8351d90664d585922e148fb18fa4`

## [0.3.1] — 2026-08-06

### Changed

- **Synced the `ComputeDriver` contract to upstream v0.0.99.** The vendored
  protos are **byte-identical** to v0.0.97 (`proto/UPSTREAM.lock` records the
  same per-file checksums under the new ref/commit) — `scripts/check-proto-drift.sh`
  confirms this and no driver code changed as a result. Upstream's v0.0.98 and
  v0.0.99 releases were test/build/perf/docs work (system CA root build mode,
  OCI image working-directory handling, `TCP_NODELAY` on latency-sensitive
  hops, VM driver OTLP tracing) that does not touch the driver-facing RPCs, so
  this was a pin bump rather than a contract migration.
- **Re-pinned `gateway.image.tag` and `driver.supervisorImage` by digest** to
  the v0.0.99 builds:
  - gateway: `sha256:1909b9d7d3f8486b4f770c1670f26db05722ed7b42f54991664fa59f016db8c3`
  - supervisor: `sha256:ea3632b6e9528e2309103af5b6949606fcdc83ca1f69e8db81482a25bea84bb6`

## [0.3.0] — 2026-08-04

### Added

- **Synced the `ComputeDriver` contract to upstream v0.0.97** and implemented
  the new `GetGatewayListenerRequirements` RPC, returning an empty list —
  the same thing upstream's own Kubernetes driver returns. The RPC lets a
  driver ask the gateway to bind extra listeners; it exists for runtimes
  whose host forwarder terminates on a gateway-local address (rootless pasta
  under the Docker/Podman/VM drivers). A Kyma sandbox is a Pod reached over
  cluster networking, so there is no host-side listener to request.

  This was **not** an outage waiting to happen. A v0.0.97 gateway calling the
  RPC against a v0.0.91-built driver gets `Unimplemented` from tonic's
  fallback route, and the gateway maps that to an empty list rather than
  treating it as an error. Implementing it explicitly is still worth doing:
  it stops "we have no requirements" and "this driver predates the RPC" from
  looking identical in the gateway's logs.

- **Upstream-ahead advisory in `scripts/check-proto-drift.sh`.** The drift
  check compares against the *pinned* ref, which is deliberate — bumping the
  pin should be a reviewable commit, and failing CI on someone else's tag
  push would make the build red for reasons no PR could fix. The cost was
  that being six releases behind was invisible, which is the same blind spot
  that let the original vendoring drift for two months.

  The check now also reports how far behind the pin is, and distinguishes
  "upstream released" (informational) from "upstream released **and** the
  contract changed" (actionable, with the diff command). It stays non-fatal
  in both cases, and treats an unreachable network as "unknown" rather than
  "up to date".

### Changed

- `driver.supervisorImage` is now **pinned by digest** in the chart default
  instead of tracking `:latest`. The supervisor runs as root with
  `SYS_ADMIN` inside every sandbox, so a rolling tag meant every sandbox
  silently picked up whatever upstream last pushed — the chart's own comment
  already warned against exactly this.

## [0.2.0] — 2026-07-29

### Changed — BREAKING

- **Synced the `ComputeDriver` contract with upstream OpenShell v0.0.91.**
  The protos were vendored once on 2026-05-27 and never updated, leaving
  the driver six upstream changes behind the gateway now deployed. Nothing
  was visibly broken, because the drifted fields happened to be ones this
  cluster never exercised — but two of the six changes are wire-breaking,
  so the failure was latent rather than absent.
  - `DriverSandboxSpec.gpu` (a `bool`) became `resource_requirements`
    (a `ResourceRequirements` message) **at the same field number**. That
    is varint → length-delimited on the wire, so a GPU sandbox request from
    a v0.0.91 gateway could not have decoded. Unreachable until now only
    because this cluster has no GPU nodes.
  - `GetCapabilitiesResponse.supports_gpu` was reserved upstream. GPU
    capability is now reported by rejecting the request at
    `ValidateSandboxCreate`, which moves the failure from list time to
    create time. `driver.gpuSupport` still gates that check.
  - GPU counts follow upstream exactly: a `gpu` block with the count
    omitted means **one** GPU, and `count: 0` is an error rather than
    "no GPU". `has_gpu_capacity` checks the requested count **per node**,
    not cluster-wide — a pod runs on one node, so two nodes with one GPU
    each cannot host a two-GPU sandbox.
- **Sandbox CRs, PVCs and APIRules are now named `{workspace}--{name}`.**
  This matches upstream's v0.0.91 tenancy model and stops identically-named
  sandboxes in different workspaces from colliding in a shared namespace.
  A name that would exceed the DNS-1123 63-character limit is now rejected
  at validate time with an actionable message instead of a late 422 from
  the API server. Under the `default` workspace that caps sandbox names at
  54 characters.
- **`GetSandbox` and `DeleteSandbox` resolve via the
  `openshell.ai/sandbox-id` label instead of a direct name lookup.** The
  gateway addresses sandboxes by id and by *bare* name and knows nothing of
  the qualified object name, so this had to land together with the rename —
  not after it — or every lookup would have missed. `list` and `watch` now
  skip an unconvertible CR with a warning rather than failing wholesale, so
  one malformed object cannot hide every other sandbox.

  **Migration:** existing sandboxes are not found after upgrading, because
  they predate the naming change. Delete them **before** rolling out the new
  driver, then recreate them:

  ```sh
  openshell sandbox delete <name>     # for each existing sandbox
  helm upgrade ...                    # roll out the new driver
  openshell sandbox create ...        # recreate
  ```

  This is the same "recreate your sandboxes" migration the 0.0.91 gateway
  upgrade already required, so the two pair naturally in one window.

### Added

- **Proto drift is now a CI failure.** `scripts/check-proto-drift.sh`
  compares the vendored protos against the upstream ref pinned in
  `proto/UPSTREAM.lock` and runs as a `branch-checks` job. It verifies both
  that the local files match upstream (catching a hand-edited proto) and
  that the checksums recorded in the lock match upstream (catching a lock
  doctored to fit). It compares against the *pinned* commit, so releases
  upstream don't turn the build red on their own — adopting a new version
  stays a deliberate commit.
- `make proto-vendor TAG=<tag>` (`scripts/vendor-proto.sh`) automates
  re-vendoring: resolves the tag to a commit, rewrites the provenance
  headers, and regenerates `proto/UPSTREAM.lock`. `make proto-check` runs
  the drift check locally.
- `proto/UPSTREAM.lock` records the upstream tag, **commit SHA**, and a
  per-file sha256 of the pristine content. The original vendoring recorded
  only a content hash with no upstream ref, which is precisely why two
  months of drift went unnoticed.
- `proto/options.proto` is vendored so the `sandbox_token` secret
  annotation resolves. It is deliberately excluded from `compile_protos`:
  it is extend-only and resolves through the include path.

## [0.1.2] — 2026-07-02

### Added

- **End-to-end tutorial for direct Anthropic-shaped endpoints**
  ([`docs/tutorial-anthropic-direct.md`](docs/tutorial-anthropic-direct.md)).
  A linear ~15 minute walkthrough for a first-time reader with a Kyma
  cluster, `kubectl`, and any Anthropic-compatible upstream URL + API
  key — no SAP AI Core, no in-cluster LLM gateway, no OIDC. Uses the
  upstream NVIDIA gateway image, cross-links to the other docs for the
  variants it deliberately doesn't cover.
- **`openshell-bedrock-bridge` crate + image + chart wiring.** A new
  in-cluster HTTP translation proxy that lets Claude Code reach
  Anthropic models deployed via SAP AI Core's Bedrock schema (XSUAA
  bearer auth, no SigV4). The bridge speaks the **Anthropic Messages
  API** on the inside (`POST /v1/messages`) and translates outbound to
  SAP's Bedrock InvokeModel endpoints. From the gateway's perspective
  it's a normal `anthropic` provider; from the sandbox's perspective,
  inference flows through `inference.local` exactly the way the
  standard Anthropic walkthrough describes — no Bedrock-mode env, no
  AWS creds, no per-pod policy carve-out.
- Translation flow: parse the inbound `/v1/messages` body, look up the
  `model` field in the operator-supplied `modelMap` to pick a SAP
  deployment id, strip `model` and `stream` from the body, inject
  `anthropic_version: "bedrock-2023-05-31"`, exchange the operator's
  SAP BTP service-key for an XSUAA bearer (cached until ~60s before
  expiry), forward to
  `${AI_API_URL}/v2/inference/deployments/{deploymentId}/{invoke|invoke-with-response-stream}`,
  and pipe the response bytes back. Streaming is byte-pass-through SSE:
  SAP defaults to `text/event-stream` and Anthropic SSE has the same
  wire format, so no per-event re-framing is needed.
- New chart block `bedrockBridge:` (default `enabled: false`). When on,
  the chart deploys the bridge as a standalone Deployment + ClusterIP
  Service + dedicated NetworkPolicy (DNS + 0.0.0.0/0:443 with RFC1918
  excluded — public SAP endpoints only), AND extends the sandbox-pod
  NetworkPolicy with an egress rule to the bridge:8787. The operator
  wires the bridge into the chart by pointing
  `inferenceProvider.baseUrl` at the bridge's in-cluster Service URL
  with `inferenceProvider.type: anthropic`; the existing
  inference-provider Job then registers it as a normal Anthropic
  upstream. Pre-flight `{{- fail -}}` guards refuse to render when
  `bedrockBridge.enabled=true` is missing the SAP service-key Secret
  reference, missing-both `modelMap` and `singleDeploymentId`, or
  missing `gateway.enabled=true`.
- Sensitive-material discipline: the operator pre-creates a Secret
  carrying the SAP service-key JSON
  (`kubectl create secret generic <name> --from-file=service-key.json=./sk-openshell.json`).
  The chart **never** reads the Secret's contents. The bridge pod
  mounts it as a file at `/etc/sap-aicore/service-key.json` (read-only,
  defaultMode `0o400`). Sandbox pods cannot reach the Secret: different
  pod, different SA, no `secrets:get` RBAC, NP egress allows only
  `bridge:8787`. The bridge logs token length only — never the
  `clientsecret` or the bearer token itself.
- New Dockerfile `deploy/Dockerfile.bridge` (multi-stage cargo-chef →
  distroless/cc, nonroot UID 65532), mirroring the driver Dockerfile.
- New image `ghcr.io/st-gr/openshell-bedrock-bridge` published by both
  the `docker-build` workflow (every push to main) and the `release-tag`
  workflow (every `v*` tag, with `:v<tag>`, `:<v-stripped-tag>`, and
  `:latest`). docker-build is now a 2x matrix; release-tag has
  parallel build steps with separate cache scopes.
- `.gitignore` patterns for SAP service-key files (`sk-*.json`,
  `*.sap-key.json`, `service-key*.json`, `**/sap-aicore-*.json`) so
  operator-uploaded keys can't accidentally land in git.
- `docs/walkthrough-claude-files.md` "Variant: SAP AI Core via the
  in-cluster translation bridge" section showing the values overlay,
  the (unchanged) sandbox env, and three sandbox-leakage verification
  steps (mount-only-on-bridge, sandbox SA can't get the Secret,
  sandbox env carries no SAP material).
- 42 new bridge tests: Tier-1 unit (config three-source loader, XSUAA
  token cache + refresh, model resolver, error mapper, Anthropic→
  Bedrock body translator) plus Tier-2 integration (Anthropic-shape
  request → Bedrock-shape outbound + verbatim response, unknown-model
  404, missing-model 400 ValidationException, upstream-400
  ValidationException, healthz, streaming SSE pass-through,
  streaming-429 ThrottlingException) — all green inside the dev image.

#### Design rationale

The original SAP AI Core Bedrock translation prompt described a
`POST /saic-aws-bedrock/model/{id}/invoke[-with-response-stream]`
shape with claude-code in Bedrock mode (`CLAUDE_CODE_USE_BEDROCK=1`,
`ANTHROPIC_BEDROCK_BASE_URL`, empty AWS creds). We tested that shape
end-to-end against a real Kyma cluster and found two empirical
constraints in NVIDIA's upstream OpenShell:

1. `normalize_provider_type` does not recognize `aws-bedrock`.
   `provider create --type aws-bedrock` is rejected at the gateway,
   so the bridge can't be registered through the chart's standard
   provider hook.
2. The supervisor's in-sandbox L7 router pins URL patterns per
   provider type. For `anthropic`-type providers, only `/v1/messages`
   is permitted; any other path returns 403
   `"connection not allowed by policy"`. So registering the bridge
   as `--type anthropic` to bypass (1) doesn't help — the supervisor
   still refuses Bedrock-shape URLs.

Together, these mean the prompt's verbatim sandbox env is not
deliverable on a stock OpenShell sandbox today. The Anthropic-in /
Bedrock-out design above moves the protocol translation server-side
into the bridge, so the sandbox uses the standard Anthropic-mode env
and the gateway routes `/v1/messages` traffic normally.

#### Future unlock for the prompt's verbatim Bedrock-mode env

An upstream PR to NVIDIA OpenShell adding `aws-bedrock` to
`normalize_provider_type` (with the right URL patterns:
`/model/{id}/invoke` and `/model/{id}/invoke-with-response-stream`)
would let operators register the bridge as `--type aws-bedrock` and
run claude-code in its native Bedrock mode against `inference.local`
exactly the way the prompt describes. Once that lands, the bridge
itself could shrink to a path-translating + auth-substituting
pass-through (no body translation, no field denylist). See
`docs/upstream-aws-bedrock-pr-draft.md` for the planned PR.

### Fixed

- **`deployment.yaml`: pass `--drivers kyma` alongside
  `--compute-driver-socket`** ([`fa2ee6e`](https://github.com/st-gr/openshell-driver-kyma/commit/fa2ee6e)).
  Required by the named-remote-endpoint refactor upstream shipped as
  NVIDIA/OpenShell#1703. Reserved built-in driver names
  (`kubernetes`, `docker`, `podman`, `vm`) reject sockets; non-reserved
  names like `kyma` pair with the socket. Without this addition the
  gateway sidecar's driver name defaults to the fallback `external`
  (still functional but produces a misleading log line and blocks the
  named-endpoint capabilities check).
- **`openshell gateway add` command syntax across tutorials.**
  Upstream CLI `v0.0.75` requires `--local` before the endpoint URL
  (`openshell gateway add --local http://…` — was
  `openshell gateway add http://… --local`). Updated in
  `docs/tutorial-anthropic-direct.md`, `docs/walkthrough-claude-files.md`,
  and `docs/cloud-connector-setup.md`.

### Changed

- **Gateway image pinned to upstream NVIDIA `0.0.73`**
  ([`9ee21b8`](https://github.com/st-gr/openshell-driver-kyma/commit/9ee21b8)).
  Retires the local-fork build path
  (`ghcr.io/st-gr/openshell-gateway`) that we ran while
  NVIDIA/OpenShell#1703 (external compute driver), NVIDIA/OpenShell#1704
  (AWS Bedrock provider), and the cross-PR `shutdown_tx` regression
  NVIDIA/OpenShell#2026 (fixed upstream in NVIDIA/OpenShell#1985) were
  in flight. `values.yaml` now points at
  `ghcr.io/nvidia/openshell/gateway@sha256:523609f8…`; `values.example.yaml`
  references the upstream repo.

## [0.1.1] — 2026-05-31

### Added

- Phase 1 implementation: KymaProvisioner, KymaEnricher,
  PrometheusMetrics, Driver gRPC service implementing all 8 RPCs from
  the OpenShell `ComputeDriver` contract.
- Phase 1 tests: Tier-1 unit (65 cases), Tier-2 gRPC contract over
  real Unix domain socket (8 cases), Tier-3 live-cluster harness
  gated by `INTEGRATION_TEST_NAMESPACE` with system-namespace
  deny-list.
- Phase 1 startup checks: PSA fail-fast with actionable error
  pointing to the kubectl command to fix the namespace label.
- Phase 1 Helm chart: gated RBAC (cluster-scope node access only
  when `--gpu-support`, APIRule permissions only when
  `--enable-apirule`), restricted Pod Security context for the
  driver pod, optional sandbox NetworkPolicy, pre-install Job that
  aborts release if the agent-sandbox CRD is missing.
- Phase 1 CI: `branch-checks`, `dco`, `helm-lint`, `docker-build`,
  `release-tag` workflows. Dependabot for cargo + github-actions +
  docker on weekly cadence.
- Phase 1 dev container (`deploy/Dockerfile.dev`) bundling Rust 1.95
  + protoc + kubectl + helm + markdownlint-cli2.
- Phase 2a: fork of NVIDIA/OpenShell at `st-gr/OpenShell` adding the
  `External(PathBuf)` variant to `ComputeDriverKind` and a
  `--compute-driver-socket` CLI flag, allowing out-of-tree driver
  binaries to plug into an upstream gateway over a Unix socket. The
  forked gateway image ships at `ghcr.io/st-gr/openshell-gateway`.
- Phase 2c: optional gateway sidecar in the chart
  (`gateway.enabled=true`). Driver + gateway run as two containers
  in one pod sharing a UDS via emptyDir. Optional ClusterIP Service
  exposes gateway gRPC + metrics. Optional Kyma APIRule for public
  exposure (`gatewayApirule.enabled`).
- Sandbox-JWT auth (`gateway.sandboxJwt.enabled`) — Helm pre-install
  hook running `openshell-gateway generate-certs`, JWT signing-key
  Secret, gateway TOML config (`[openshell.gateway.gateway_jwt]` +
  `[openshell.drivers.kubernetes]`), ClusterRole for
  `tokenreviews:create`, namespace-scoped `pods:get`. The supervisor
  inside each sandbox now exchanges its projected SA token for a
  per-sandbox JWT, fetches policy, and reaches `phase=Ready`.
- Driver: `openshell.io/sandbox-id` annotation on every sandbox pod,
  read by the gateway after TokenReview to bind a token to a sandbox.
- Driver: projected SA token volume + `OPENSHELL_K8S_SA_TOKEN_FILE`
  env injected into every sandbox pod.
- Driver: `OPENSHELL_SSH_SOCKET_PATH=/run/openshell/ssh.sock` env so
  the supervisor spawns its long-lived control stream.
- Driver: rustls `CryptoProvider::install_default()` at top of `main`
  (rustls 0.23 requires this).
- Helm `sandbox-serviceaccount.yaml` template — the SA every sandbox
  pod attaches via `spec.podSpec.serviceAccountName`. Zero RBAC,
  `automountServiceAccountToken: false`.
- New `make e2e-cli` target — full end-to-end harness exercising
  CLI → gateway → driver → CR → pod → supervisor → CLI exec on a
  live cluster, using a minimal ubuntu-based sandbox image at
  `ghcr.io/st-gr/e2e-sandbox` (built from `e2e/sandbox/Dockerfile`
  by `.github/workflows/build-e2e-sandbox.yml`).
- Static-kubeconfig renderer (`scripts/render-static-kubeconfig.js`)
  resolves OIDC exec auth on the host so the dev container can talk
  to Kyma.
- New documentation: `docs/install-cli.md`, `docs/getting-started.md`,
  `docs/production-deployment.md`. README front-loads
  `docs/getting-started.md`. `docs/why-init-container.md`,
  `docs/kyma-vs-openshift.md`, `docs/openshell-api-programmatic-usage.md`,
  `docs/cloud-connector-setup.md` updated to reflect the gateway-sidecar +
  sandbox-JWT + NetworkPolicy posture.
- New chart values: top-level `imagePullSecrets` (rendered on the
  driver+gateway pod when set; the chart never creates the Secret).
  Documented BYO `serviceAccount` path
  (`serviceAccount.create=false` + `serviceAccount.name=<existing>`).
  Documented supervisor-image digest-pinning policy in `values.yaml`
  comments.
- Optional in-cluster LLM-gateway routing for sandbox model traffic.
  Three new chart blocks turn this into a declarative one-`helm install`
  flow without ever leaking the upstream URL or API key into the sandbox:
  - `gateway.dbPersistence` — PVC-backed SQLite (or external Postgres
    via `dbUrl`) for the gateway's provider/inference DB so configs
    survive pod restarts.
  - `inferenceProvider` — post-install,post-upgrade Helm Hook Job that
    calls `openshell provider create` + `openshell inference set`
    against the in-pod gateway. The Anthropic API key is mounted into
    the Job from a Secret the operator manages — the chart never sees
    the key. Mirrors the existing gateway-jwt-pki-hook pattern.
  - `gatewayUpstreamEgress` — NetworkPolicy egress rule on the
    **driver+gateway pod** (NOT the sandbox-pod policy) allowing the
    gateway sidecar to reach the operator's in-cluster LLM upstream.
    The sandbox NetworkPolicy is unchanged — sandbox traffic always
    terminates at the in-pod gateway.
- Driver `--disable-claude-telemetry` flag (default false). When true,
  the driver injects `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` into
  every sandbox pod's env. Useful when the in-cluster LLM gateway
  cannot service Anthropic's optional telemetry endpoints. Independent
  of inference routing — flip on its own when you want to silence
  telemetry without rerouting model calls.
- Pre-flight `{{- fail -}}` guards (in
  `templates/_inference-provider-guards.tpl`) that refuse to render
  when `inferenceProvider.enabled=true` is missing any of `type`,
  `baseUrl`, `modelId`, `credentialSecret.name`, or
  `credentialSecret.key`, and similarly for `gatewayUpstreamEgress`
  enabled with empty `namespace` or `port`. Mirrors the
  `gateway-apirule.yaml` `{{- fail -}}` style.
- Documented architecture preservation rationale in
  `docs/production-deployment.md` and a new "Gateway-mediated
  inference routing" section in `docs/kyma-vs-openshift.md`. The
  hardcoded `ANTHROPIC_BASE_URL=https://inference.local/v1` and
  `OPENAI_BASE_URL=https://inference.local/v1` env injections
  (`provisioner.rs:277-284`) are explicitly preserved — they are
  upstream NVIDIA OpenShell's pseudo-endpoint that the gateway sidecar
  intercepts and rewrites.
- `docs/getting-started.md` Step 5b walking through the opt-in flow
  end-to-end: Secret create + namespace label + `helm install --set`
  with the three new blocks.
- `deploy/helm/openshell-driver-kyma/values.example.yaml` — single-file
  copy-paste-edit reference overlay covering every opt-in (gateway,
  sandboxJwt, dbPersistence, inferenceProvider, gatewayUpstreamEgress,
  APIRule, OIDC) with placeholder values and a pre-flight checklist.
  Trims the multi-step `--set` chain down to `helm install -f my-values.yaml`,
  in line with NVIDIA's CLI-first install vision.
- Helm chart published as an OCI artifact on every `v*` tag. The
  `release-tag` workflow now runs `helm push` against
  `oci://ghcr.io/st-gr/charts`, so operators can do
  `helm install ods oci://ghcr.io/st-gr/charts/openshell-driver-kyma
  --version <ver>` without cloning the repo. The dedicated `/charts`
  OCI namespace avoids collision with the driver container image at
  `ghcr.io/st-gr/openshell-driver-kyma`.
- Native digest-pinning in the chart's image helper. When `image.tag`
  or `gateway.image.tag` starts with `sha256:`, the helper emits
  `<repo>@sha256:<digest>` (the OCI canonical form) instead of
  `<repo>:<tag>`. Production digest pin is now a one-line values
  overlay; no Kustomize patch needed.
- The `release-tag` workflow now publishes the released image at both
  `:v<tag>` and `:<v-stripped-tag>` so the chart's image helper
  default (which falls through to `Chart.AppVersion`, with no leading
  `v`) resolves cleanly without `--set image.tag=...`.
- Driver `--enable-user-namespaces` flag (default false) and chart
  `driver.enableUserNamespaces` value. When true, sandbox pods get
  `hostUsers: false` and the agent container's `privileged: true` is
  dropped — UID 0 inside the pod's user namespace remaps to a non-root
  host UID via the kubelet. SYS_ADMIN/NET_ADMIN/SYS_PTRACE/SYSLOG
  capabilities are namespaced and remain effective. Requires K8s 1.30+
  with the `UserNamespacesSupport` feature gate enabled. Closes the
  Phase 2b T1 follow-up.
- Driver `--sandbox-storage-size` and `--sandbox-storage-class` flags;
  chart `driver.sandboxStorageSize` and `driver.sandboxStorageClass`
  values. When `sandbox-storage-size` is non-empty, the driver
  provisions a `<sandbox-name>-workspace` PVC alongside each Sandbox
  CR, mounts it at `/sandbox`, and cleans it up on sandbox delete.
  Workspace data survives pod rescheduling. Chart's namespace-scoped
  Role gains `persistentvolumeclaims: get/create/delete` only when the
  feature is on. Closes the Phase 2b T3 follow-up.
- Gateway TLS opt-in (`gateway.tls.enabled`) + mTLS opt-in
  (`gateway.tls.clientCa.enabled`). The chart's existing cert-gen Job
  already creates server-tls and client-tls Secrets; the deployment
  template now mounts the server-tls Secret on the gateway container
  and passes `--tls-cert` / `--tls-key` (and `--tls-client-ca` for
  mTLS) when the new values are on. TLS and OIDC are now independent —
  any combination of {TLS off, TLS on, mTLS on} × {OIDC off, OIDC on}
  is valid. Pre-flight guard: `gateway.tls.enabled=true` requires
  `gateway.sandboxJwt.enabled=true`. Closes the Phase 2b T4 follow-up.
- K8s Event correlation in `WatchSandboxes`. The driver now spawns a
  second informer on `core.v1.Event` (filtered to `type=Warning`) and
  emits matching Events as `WatchSandboxesPlatformEvent` payloads
  alongside the existing Updated/Deleted streams. Surfaces
  pod-scheduling failures, image-pull errors, mount failures, etc. to
  the gateway / CLI promptly. The chart's namespace-scoped Role gains
  `events: get/list/watch`. Closes the Phase 2b T5 follow-up.
- Dev-image Node bumped from 18 to 22 LTS via NodeSource so
  `markdownlint-cli2` (and any future Node 20+ tooling) works inside
  the dev container.
- `e2e/sandbox/Dockerfile` pins `ubuntu:24.04` by digest so a future
  retag can't silently change what `make e2e-cli` builds.

### Fixed

- **`ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL` injected as
  `https://inference.local` instead of `https://inference.local/v1`.**
  Anthropic and OpenAI SDKs (and `claude-code`) append `/v1/messages`
  themselves; with `/v1` already in the env var, the request landed at
  `/v1/v1/messages` and the supervisor's L7 router rejected it with
  `403 {"error":"connection not allowed by policy: POST /v1/v1/messages"}`.
  Curl-based clients that hand-built the URL had been masking the bug.
  Discovered during the 2026-05-31 live E2E with `claude-cli/2.1.158`;
  the supervisor's NET:OPEN log showed the doubled `/v1`. With this
  fix `claude -p "..."` round-trips cleanly through
  `inference.local → supervisor router → operator's in-cluster LLM upstream → Anthropic`.

### Changed

- **`gatewayUpstreamEgress` NetworkPolicy rule moved from the
  driver+gateway pod to the sandbox pod.** Discovered during T8 live
  smoke against an in-cluster LLM upstream: the original placement was
  a no-op because the gateway sidecar is bundle/config plane only and
  never forwards inference request bytes. Per NVIDIA's documented
  architecture (https://docs.nvidia.com/openshell/about/how-it-works
  and the in-process-router decision in NVIDIA/OpenShell#998 — "No
  subprocess, no loopback hop"), the supervisor inside the sandbox pod
  is what dials the upstream: it terminates `inference.local` TLS using
  the sandbox CA at `/etc/openshell-tls/`, fetches the bundle via
  `GetInferenceBundle`, strips caller creds, and connects out from the
  sandbox pod's eth0. The egress rule now lives where it's actually
  needed. Same `gatewayUpstreamEgress` values block — name kept for
  backwards compatibility with deployed values overlays.
- **Architecture wording corrected across docs.** Earlier phrasing
  ("the sandbox itself never sees either", "the gateway sidecar
  rewrites and forwards") was overstated. The accurate model is
  agent-vs-supervisor isolation within the sandbox pod: the agent
  application's env shows only `inference.local` and it cannot read
  the real URL or API key, but the supervisor process (same pod,
  separate process namespace, runs privileged) holds the bundle and
  is the actual dialer. Updated `docs/getting-started.md` Step 5b,
  `docs/production-deployment.md` "Why these settings keep the agent
  isolated", `docs/kyma-vs-openshift.md` "Gateway-mediated inference
  routing", and the comments on `gatewayUpstreamEgress` in `values.yaml`
  + `values.example.yaml` to reflect this.

- `docs/getting-started.md` rewritten from a 9-step tour with a Step 5b
  for in-cluster LLM routing into a 4-step NVIDIA-aligned flow:
  prerequisites → bootstrap namespace → copy-edit-install
  `values.example.yaml` → verify + exec. The legacy `--set` chain moved
  to Appendix A; APIRule public exposure moved to Appendix B.

- NetworkPolicy is now default-on (`driver.enableNetworkPolicy: true`).
  Renders two policies: driver/gateway pod (ingress on health/grpc/
  metrics, egress to DNS and 443), and a sandbox-pod policy (no
  ingress; egress to DNS, in-pod gateway VIP, and 0.0.0.0/0:443 with
  RFC1918 excluded).
- Supervisor sideload: `cp <src> <dst>` replaced by the binary's
  `copy-self <dest>` subcommand. The upstream supervisor image is
  distroless and has no `cp`; this matches what upstream's K8s driver
  does. Driver default `--supervisor-binary-path` moved from
  `/usr/local/bin/openshell-sandbox` to `/openshell-sandbox` (where
  the binary actually lives in the image).
- Default sandbox supervisor image path corrected from
  `ghcr.io/nvidia/openshell-community/supervisor` (404) to
  `ghcr.io/nvidia/openshell/supervisor`.
- Gateway args no longer include the non-existent `run` subcommand
  (default action is to run the server).
- Tier-3 deny-list tests refactored to call a pure
  `validate_namespace_against_denylist` helper instead of mutating
  process env, which used to leak `INTEGRATION_TEST_NAMESPACE` into
  subsequent tests.
- Tier-3 PSA-label patch on the namespace now includes the required
  `apiVersion` + `kind` for server-side apply.
- `make test-integration` mounts the active kubeconfig file (from the
  host's `KUBECONFIG`) directly at `/root/.kube/config`, instead of
  the entire `~/.kube` dir (which often contains a stale
  rancher-desktop config pointing at localhost).
- Default `gateway.image.repository` is the public
  `ghcr.io/st-gr/openshell-gateway`. Driver image is also public on
  GHCR (operator visibility flip on 2026-05-28 after security audit
  confirmed only stripped binary on distroless base, no compile-time
  cluster identifiers).

### Security

- Refuses to render `gatewayApirule.yaml` when
  `gatewayApirule.enabled=true` and `gateway.oidc.issuer` is empty.
  Prevents accidentally publishing an unauthenticated gateway with
  `allow_unauthenticated_users = true` + `--disable-tls`.
- Switched secrets-scan workflow from `gitleaks/gitleaks-action` to a
  direct `gitleaks` CLI invocation that scans the full working tree.
  The wrapper's diff scan from `github.event.before^..HEAD` failed
  after history rewrites with `fatal: ambiguous argument` and put a
  red badge on the README despite a clean tree.
- `gitleaks detect` clean across all 56 commits of the new history.
- Operator-environment fingerprint scrubbed from the entire history
  (`git filter-repo`): user-namespace names, internal product
  references, and one hardcoded local Windows workspace path are
  gone from every commit and every commit message.

### Removed

- `deploy/runner/`, `scripts/{add,remove,create}-runner-*.js`, and
  the runner-* Makefile section moved to a new dedicated repo
  `st-gr/gha-runner-kyma` with full commit history preserved
  (`git filter-repo --path-rename`). The driver and the runner had
  no shared dependencies. Live cluster runners keep running off the
  in-cluster ConfigMaps and Deployments.

### Follow-ups (deliberately deferred)

The following are **not** in this release. Each is a stand-alone
unit of work and should ship in its own PR/release.

- **CI-driven `make e2e-cli`.** Run the full e2e on every push using
  the self-hosted Kyma runner at `st-gr/gha-runner-kyma`.
- **Upstream PR for `feat/external-compute-driver-socket`.** Submit
  the gateway patch in `st-gr/OpenShell` to NVIDIA/OpenShell.
- **Initial commit + branch protection for `st-gr/sail-proxy`.**
- **CI-driven live-cluster smoke for in-cluster LLM-gateway routing.**
  The smoke itself was completed manually (2026-05-30, a real Kyma
  cluster + an in-cluster Anthropic-compatible upstream — sandbox
  curled `https://inference.local/v1/messages`, response came back
  through the supervisor's in-process inference router unchanged).
  Moving that into CI requires the self-hosted Kyma runner +
  operator-owned API key as a GitHub secret; deferred until the runner
  picks it up.
