# Changelog

All notable changes to openshell-driver-kyma are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
