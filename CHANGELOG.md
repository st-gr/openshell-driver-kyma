# Changelog

All notable changes to openshell-driver-kyma are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

### Changed

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
