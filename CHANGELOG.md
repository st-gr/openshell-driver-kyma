# Changelog

All notable changes to openshell-driver-kyma are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **Verified live on Kyma:** the VirtualService, Service and NetworkPolicy are
  created as designed; on a cluster whose ingress gateway carries ALLOW
  `AuthorizationPolicy` allowlists, the route answers `403 RBAC: access denied`
  until an ALLOW rule covers the sandbox hosts (documented in
  getting-started and production-deployment; the driver does not manage
  `istio-system` policies).
- **Sandbox exposure goes through an Istio VirtualService on Kyma's gateway.**
  With `driver.enableApirule`, the driver now applies a `networking.istio.io/v1`
  VirtualService `<cr>` where 0.9.0 applied an APIRule: host
  `<workspace>--<name>.<clusterDomain>`, bound to `driver.istioGateway`
  (default `kyma-system/kyma-gateway`), routing every path and method to port
  8080 of the Service `<cr>-svc`. Traffic goes from the Istio ingress gateway
  to the Service and on to the workload pod, which needs no Istio sidecar;
  the missing sidecar is what kept 0.9.0's APIRule in `Error` (see 0.9.0
  "Known limitations"). The Service, the NetworkPolicy that admits only the
  ingress gateway, the owner references, the labels and the `ExposureFailed`
  Warning Event are unchanged, and so is the security trade-off: the route is
  unauthenticated, so enabling exposure publishes the sandbox's port 8080.
  (The APIRule allowed only `GET` and `POST`; the VirtualService does not
  filter methods.) `driver.enableApirule` keeps its name and switches exposure
  of either kind on. Exposure runs when a sandbox is created, so a sandbox
  created by 0.9.0 keeps its APIRule until it is deleted; recreate it to get a
  VirtualService.
- **RBAC for exposure follows the kind.** With `driver.enableApirule`, the
  driver is granted `create` and `patch` on `networking.istio.io`
  `virtualservices` instead of `gateway.kyma-project.io` `apirules` (in the
  shared-mode Role, cluster-wide in managed and operator mode). With
  `driver.exposureKind: apirule` it gets the `apirules` rule instead; never
  both.

### Added

- **`driver.exposureKind`** (`--kyma-exposure-kind`,
  `OPENSHELL_KYMA_EXPOSURE_KIND`): `virtualservice` (default) or `apirule`.
  `apirule` keeps 0.9.0's APIRule v2 exposure for a future mesh-compatible
  setup; on Kyma with upstream v0.1.2 it still does not carry traffic (Kyma
  sets the rule to `Error` and the ingress gateway answers 403).
- **`driver.istioGateway`** (`--kyma-istio-gateway`,
  `OPENSHELL_KYMA_ISTIO_GATEWAY`): the Istio Gateway the VirtualService binds
  to, `<namespace>/<name>`, default `kyma-system/kyma-gateway`, whose servers
  accept `*.<cluster-domain>`.
- The chart refuses to render, naming the value, a `driver.exposureKind` other
  than `virtualservice` or `apirule`, or a `driver.istioGateway` that is not
  two DNS-1123 labels joined by one `/`; the driver refuses both at startup.

## [0.9.0] — 2026-09-29

**UPGRADE NOTE: delete all existing sandboxes before upgrading to this
release, and remove the values listed under "Values migration" from your
values file before `helm upgrade`.** The pod topology changes (every sandbox
now gets a separate supervisor pod next to its workload pod) and upstream's
runtime identity replaces ours, so a sandbox created by 0.8.0 cannot
bootstrap and there is no back-fill path. Recreate your sandboxes after the
upgrade. To upgrade from 0.8.0 with only this section in front of you:

1. `openshell sandbox list`, then `openshell sandbox delete <name>` for every
   sandbox, before the upgrade. If one is left behind, remove its Sandbox CR
   with `kubectl delete sandbox` afterwards.
2. Run the `kubernetes-sigs/agent-sandbox` controller v0.5.2, the release CI
   tests against: `kubectl apply -f
   https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.2/sandbox.yaml`
   installs its CRD and controller. Without the controller no sandbox pod is
   ever created.
3. Edit your values file with the "Values migration" table below. Helm does
   not reject unknown keys, so a removed key that you leave in place is
   silently ignored (for example `driver.enableNetworkPolicy: false` no longer
   turns the driver NetworkPolicy off; set `networkPolicy.enabled: false`).
   If your values file overrides `driver.supervisorImage` or
   `gateway.image.tag`, drop the override or re-pin it to upstream v0.1.2: the
   driver, gateway, supervisor and sandbox runtime images must be one release.
   Three defaults changed to upstream's (see "Changed"): set
   `driver.allowDriverConfig: true` to keep 0.8.0's behaviour, where callers
   could pass `driver_config`; set `driver.workspacePsaLevel: privileged` if
   your managed-mode sandboxes need more than the `restricted` level the chart
   now labels new namespaces with (0.8.0 labelled them `privileged`); and set
   `driver.managedSshIngress.enabled: false` if managed mode must not get the
   SSH ingress policy. With `gateway.enabled`, also set
   `gatewayService.enabled` and `gateway.sandboxJwt.enabled`, and leave
   `inferenceProvider.enabled` off when `gateway.oidc.issuer` or
   `gateway.tls.enabled` is set: the chart now refuses those settings.
4. `helm upgrade <release> <chart> -f my-values.yaml`. Pass the values file
   again; do not use `--reuse-values`, which keeps the 0.8.0 chart's defaults
   and ignores the new ones. The chart refuses to render, naming the value,
   for the invalid settings listed in the "Managed mode" bullet under
   "Changed" (and for the checks it already had in 0.8.0, such as an unknown
   `driver.workspaceMode` or incomplete `gateway.tls`, `bedrockBridge` or
   `gatewayApirule` settings); other invalid values are refused by the driver
   at startup with upstream's message, so check the driver's log after the
   upgrade.
5. If `inferenceProvider.enabled` is set, the post-upgrade hook registers a
   provider profile and creates the provider `<release>-<type>` (0.8.0 named
   it `<fullname>-<type>`). If it fails with "provider ... exists with type
   ...", the provider name is already taken by a 0.8.0 provider: delete it
   (`openshell provider delete <name>`) or set `inferenceProvider.name`. A
   0.8.0 provider under the old default name stays in the gateway database,
   unused; delete it when you no longer need it.
6. Use an `openshell` CLI of v0.1.2, and create sandboxes with
   `--provider <name>` (see "Changed").

### Changed

- **Architecture: the driver is upstream's Kubernetes driver behind a thin
  Kyma layer.** It links NVIDIA OpenShell v0.1.2's
  `openshell-driver-kubernetes` as a library (git dependencies pinned to one
  tag) and forwards every `ComputeDriver` RPC to upstream's own service, so
  capability negotiation, resource admission, sandbox authentication, runtime
  identity, workspace modes, stop/start and the sandbox lifecycle are
  upstream's. Configuration mirrors upstream's options 1:1: the same long
  names and the same `OPENSHELL_*` environment variables (the chart sets
  environment variables; the driver container takes no command-line
  arguments). Sandboxes run upstream's hardened supervisor pod
  (`os-supervisor-<sandbox id>`) beside the workload pod, inside upstream's
  isolation fence. The Kyma layer adds eight `--kyma-*` options
  (`OPENSHELL_KYMA_*`) and three hooks: request enrichment (the
  `sidecar.istio.io/inject` and `kagenti.io/type` labels and any configured
  sandbox environment), APIRule exposure, and Pod Security labels on the
  namespaces the driver creates in managed mode. The vendored proto, the
  provisioner, the sandbox-authentication code and the driver's own
  admission and capability logic are gone.
- **Inference is configured through upstream's provider profiles.**
  `openshell inference set`, `inference.local` and the L7 router bundle do not
  exist in upstream v0.1.2. The chart now renders a provider profile (the
  endpoint `host:port` from `inferenceProvider.baseUrl`, plus `binaries`); the
  post-install hook imports it with the CLI of `upstream.version` and creates
  the provider from it; sandboxes are created with `--provider <name>` and
  receive `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL` in their environment.
  The API key is bound to the endpoint's host and port. `binaries` gates which
  processes may reach the endpoint; upstream v0.1.2 does not yet restrict the
  key by calling binary.
- **Managed mode.** The gateway id (default: the release fullname) must be at
  most 33 characters, upstream's limit; a longer release name must set
  `gateway.sandboxJwt.gatewayId`. The chart now fails at render time, naming
  the value, for these invalid settings: the workspace-mode rules upstream
  refuses at startup (a managed gateway id that is not a DNS-1123 label or is
  too long, managed SSH ingress without a gateway namespace or pod selector,
  operator mode without exactly one of the namespace label and the ConfigMap),
  a sandbox UID or GID outside 1 to 4294967294, a non-boolean
  `driver.allowDriverConfig` or `driver.resourceAdmission.enabled`, a
  `driver.resourceAdmission.requiredLabels` that is not a map or is empty while
  `driver.resourceAdmission.enabled` is true (upstream refuses an empty label
  set at startup, `openshell-core` `src/resource_admission.rs:136`), a malformed
  `driver.sandboxEnv` entry, an
  invalid `inferenceProvider` (a type other than `anthropic`; a `baseUrl` that
  is not an http(s) URL to a host name, that carries credentials or contains a
  comma; no `modelId`, `binaries` or credential Secret), and
  `driver.enableApirule` without `driver.clusterDomain`. That list is the new
  checks, not every check the chart makes. Other invalid values
  (for example a non-numeric `driver.saTokenTtlSecs`, an unknown pull policy, a
  bad `driver.workspacePsaLevel` or a port out of range) are refused by the
  driver at startup with upstream's message, so the pod crash-loops and the
  driver's log names the option.
  The Pod Security label from `driver.workspacePsaLevel` is applied before
  each `CreateSandbox` and on `EnsureWorkspace`, because upstream's create
  path creates the namespace itself. The namespace is then ensured by the
  step upstream's create path runs, with its status codes: a namespace
  another gateway owns is `FAILED_PRECONDITION`.
- **Managed-mode namespaces are labelled `restricted`, not `privileged`.**
  0.8.0 labelled every namespace it created
  `pod-security.kubernetes.io/enforce=privileged`. `driver.workspacePsaLevel`
  now defaults to `restricted`: on the v0.9.0 live check a server-side dry run
  of that level on a namespace with a running sandbox printed no warning
  (upstream's supervisor and workload pods are non-root, drop all capabilities
  and use the RuntimeDefault seccomp profile). Set it to `baseline`,
  `privileged` or `""` (no label) to change that.
- **Defaults follow upstream's chart.** `driver.allowDriverConfig` defaults to
  `false` (0.8.0: `true`), so a caller's `driver_config` is refused until an
  operator opts in; set it to `true` to keep 0.8.0's behaviour.
  `driver.sandboxImage` defaults to upstream's sandbox image,
  `nvcr.io/nvidia/base/ubuntu:24.04`. In managed mode with the in-pod gateway
  and `networkPolicy.enabled`, the driver's managed SSH ingress is on by
  default, naming the release namespace and this chart's pod as the gateway,
  as upstream derives it from its `networkPolicy.enabled`; the
  `driver.managedSshIngress.*` values override each part (`enabled: false`
  turns it off), and the driver's ClusterRole gains the NetworkPolicy rights
  it needs only while it is on.
- **The chart refuses gateway settings that cannot work**, each confirmed
  against upstream v0.1.2: `gateway.enabled` without `gatewayService.enabled`
  (sandboxes dial the release's Service; set `driver.gatewayEndpoint` to use
  another address) or without `gateway.sandboxJwt.enabled` (supervisors cannot
  bootstrap without the gateway's sandbox-JWT keys), and `inferenceProvider.enabled`
  without the gateway's Service or together with `gateway.oidc.issuer` (the
  provider hook calls the gateway without a token, which an OIDC gateway
  refuses) or with `gateway.tls.enabled` (the hook always dials `http://` and
  presents no client certificate); register the provider from an
  authenticated CLI instead, see `docs/production-deployment.md`.
- **APIRule host is `<workspace>--<name>.<clusterDomain>` in every workspace
  mode.** It was the Sandbox CR name, which collided across workspaces in
  managed mode. Exposure also works with agent-sandbox controllers that serve
  only `v1alpha1`, finds the Sandbox by its id and the gateway id, as
  upstream's own lookup does, and bounds each API call at 30 seconds
  (upstream's limit), so a hung call still records the Warning Event.
- **RBAC mirrors upstream's chart exactly, per workspace mode:** a Role in the
  shared namespace, a ClusterRole for the cluster-scoped and multi-namespace
  rights, and upstream's workspace-secret-source Role (`get` on exactly the
  client TLS and image-pull Secrets the driver stages). The Kyma layer adds
  only what it calls: APIRule, Service, NetworkPolicy and Event writes when
  exposure is on, and namespace `patch` when a PSA level is set. The three
  0.8.0 ClusterRoles (nodes, tokenreview, workspaces) are replaced by one.
- **The driver pod's `/healthz` and `/readyz` are Kyma-owned** (upstream's
  driver serves only gRPC) on `driver.healthPort`; `/readyz` turns ready once
  the compute-driver socket is bound.
- **The sandbox runtime image is always passed, digest-pinned**
  (`driver.sandboxRuntimeImage`), as is the supervisor image: upstream's
  compiled-in defaults depend on build variables that a git-dependency build
  does not set.

### Values migration

| Removed / renamed | Now |
|---|---|
| `driver.supervisorBinaryPath`, `driver.supervisorMountPath` | removed — upstream's runtime owns the supervisor |
| `driver.gpuSupport`, `driver.telemetryEnabled`, `driver.stopTimeoutSecs` | removed — upstream behaviour |
| `driver.enableNetworkPolicy` | `networkPolicy.enabled` (driver+gateway pod only; sandboxes are fenced by upstream) |
| `driver.operatorNamespaceAllowlist` | `driver.operatorNamespaceLabel` or `driver.operatorNamespaceConfigMap` |
| `driver.driverConfigAllowVolumes` | `driver.allowDriverConfig` — caller volumes are now checked by upstream's resource admission |
| `driver.gatewayId` | `gateway.sandboxJwt.gatewayId` — the gateway and driver now always share one id, as upstream's chart does |
| `gatewayUpstreamEgress.*` | removed — upstream's supervisor pods carry their own egress policy (allow-all); workloads have none |
| `driver.socket` default `/var/run/openshell-driver.sock` | `/var/run/openshell/driver.sock` — upstream's driver refuses to start unless its own uid owns the socket's parent directory, so the socket now sits one level below the shared emptyDir; an override must keep at least three directories (the chart refuses less) |
| `inferenceProvider` via `openshell inference set` | provider profiles; create sandboxes with `--provider <name>`. The default provider name is `<release>-<type>` (was `<fullname>-<type>`) |

### Added

- **Every upstream driver option is reachable from values**, under upstream's
  own names in `values.yaml`: `driver.bindAddress`, `driver.gatewayName`,
  `driver.otlpEndpoint`, `driver.runtimeClassName`, `driver.saTokenTtlSecs`,
  `driver.clientTlsSecretName`, `driver.hostGatewayIp`,
  `driver.sandboxSshSocketPath`, `driver.providerSpiffeWorkloadApiSocket`,
  `driver.sandboxImage`, `driver.sandboxImagePullPolicy`,
  `driver.sandboxImagePullSecrets`, `driver.sandboxRuntimeImage`,
  `driver.sandboxRuntimeImagePullPolicy`, `driver.sandboxRuntimeBoundaryPort`,
  `driver.supervisorImagePullPolicy`, `driver.operatorNamespaceLabel`,
  `driver.operatorNamespaceConfigMap.{name,key}`,
  `driver.managedSshIngress.{enabled,gatewayNamespace,gatewayPodSelector}` and
  the `driver.upstreamProxy.*` family (`url`, `noProxy`, `authSecretName`,
  `authSecretKey`, `allowInsecure`, `connectByHostname`,
  `caBundleConfigMap.{name,key}`). `scripts/testdata/chart-all-options.yaml`
  sets every option, and CI proves each reaches the driver container.
- **`driver.sandboxEnv`**: `KEY=VALUE` entries added to every sandbox
  (`--kyma-sandbox-env`). An explicit entry beats
  `driver.disableClaudeTelemetry`, and the first duplicate wins.
- **`driver.workspacePsaLevel`**: the Pod Security level applied to managed-mode
  namespaces (`privileged`, `baseline`, `restricted`, or empty for none).
- **`driver.ingressNamespace`**: the namespace of the Istio ingress gateway
  that APIRule traffic arrives from (default `istio-system`).
- **`inferenceProvider.profileId`** and **`inferenceProvider.binaries`**: the
  provider profile's id (default `kyma-<type>`) and the executables allowed
  to reach the endpoint (default: `node` and `claude` under `/usr/bin` and
  `/usr/local/bin`; it must not be empty).
- **`upstream.version`**: the upstream release the driver links and the
  provider hook's CLI comes from. CI requires it to equal the tag in
  `Cargo.toml`.
- **`networkPolicy.enabled`** (was `driver.enableNetworkPolicy`).
- **`driver.resourceAdmission.enabled`** (default `true`) and
  **`driver.resourceAdmission.requiredLabels`** (default: upstream's built-in
  labels): upstream's resource admission policy for the PVCs a sandbox
  attaches, rendered like `allowDriverConfig` into both the gateway's
  `[openshell.drivers.kyma]` tables and the driver's admission JSON.
- **OTLP egress:** with `driver.otlpEndpoint` and `networkPolicy.enabled`, the
  driver+gateway pod's NetworkPolicy allows the collector's port (80 or 443
  when the URL names none), to any address.

### Security

- **The chart's own sandbox NetworkPolicy is removed.** It selected
  `openshell.ai/managed-by: openshell`, which upstream puts on both the
  workload and the supervisor pod; NetworkPolicies are additive, so it
  widened upstream's workload fence. CI now fails on any chart NetworkPolicy
  that selects sandbox pods, apart from the SSH-ingress policy below.
- **The chart mirrors upstream's `<fullname>-sandbox-ssh` ingress policy**
  (shared mode, `networkPolicy.enabled`, in-pod gateway only): SSH (TCP 2222)
  to sandbox pods only from the gateway pod. With an external gateway
  (`gateway.enabled=false`) the gateway's own deployment owns that policy.
  In managed mode the driver applies the equivalent policy itself
  (`driver.managedSshIngress`, on by default with the in-pod gateway).
- **APIRule exposure is an explicit, documented exception to upstream's
  fence, off by default (`driver.enableApirule`).** Upstream's workload pods
  accept ingress only from their supervisor pod, so exposing port 8080
  needs a Kyma-owned Service, a NetworkPolicy admitting only the Istio
  ingress gateway (`istio: ingressgateway` in `driver.ingressNamespace`) to
  port 8080 of that sandbox's workload pod, and the APIRule. All three are
  owner-referenced to the Sandbox CR and lack upstream's
  `openshell.ai/managed-by` label (they carry
  `app.kubernetes.io/managed-by: openshell-driver-kyma`). The
  APIRule is `noAuth`: enabling exposure publishes the sandbox's port 8080,
  and inbound traffic bypasses the supervisor. **Not yet functional on Kyma
  with upstream v0.1.2** (see "Known limitations"): the objects are created
  correctly, but Kyma's APIRule v2 sets the rule to `Error` because the
  workload pod has no Istio sidecar, and injecting one is incompatible with
  upstream's zero-egress workload fence today.
- **The provider hook verifies the CLI it downloads** against the release's
  `openshell-checksums-sha256.txt` before running it, picks the asset by the
  node's architecture (x86_64 or aarch64), and receives the API key only as an
  environment variable read from a Secret (`secretKeyRef`), never from the
  chart or the command line.

### Fixed

- **The `sandbox-claude` image's `claude` wrapper kept the provider credential
  from being injected.** It unset `ANTHROPIC_API_KEY` for the retired
  `inference.local` router; under the provider model that variable carries the
  supervisor's resolver placeholder, and the proxy substitutes the real key only
  when the client sends it. The wrapper now leaves `ANTHROPIC_API_KEY` and
  `ANTHROPIC_BASE_URL` alone (verified on the v0.9.0 live check: `claude -p`
  answers through the provider). Images built before this fix need
  `/usr/bin/claude` called directly.

- **Sandboxes run on upstream v0.1.2 again.** 0.8.0's driver could not start
  them: upstream renamed the supervisor and moved it to a separate,
  bootstrapped pod, and our init container failed with
  `--backend-descriptor-file is required`.
- **The inference hook no longer uses a hard-coded v0.0.91 CLI.** It uses the
  CLI of `upstream.version`, so the CLI always matches the gateway.
- **With `gateway.tls.enabled`, sandboxes dial `https://`.** The default
  gateway endpoint was always `http://`; it now takes its scheme from
  `gateway.tls.enabled`, as upstream's takes it from `disableTls`, and the
  driver mounts the client TLS Secret the chart's PKI hook creates unless
  `driver.clientTlsSecretName` names one.

### CI

- `scripts/check-upstream-args.sh` and `scripts/check-chart-render.sh` keep the
  driver and chart at parity with upstream: the first fails when the driver
  does not accept every option upstream's driver does at the pinned tag, the
  second renders the chart and asserts every option, the exact RBAC per mode,
  the NetworkPolicies and the provider hook.
- The smokes now run the agent-sandbox controller and follow sandboxes to
  Ready, bootstrap and stop/start (0.8.0 shipped with sandboxes that could not
  run because the smokes installed only the CRD).
- The weekly upstream sync moves the pin (`make upstream-bump`) and Dependabot
  leaves `kube`, `k8s-openapi` and `openshell-*` to follow upstream.
- The smokes install the chart's pinned gateway, supervisor and sandbox
  runtime images and the CLI of `upstream.version`, the set the chart ships
  (they installed the latest upstream release before), and
  `scripts/check-image-digests.sh` fails when those pins are not the digests
  upstream published for `upstream.version`. The weekly sync's staleness
  check also compares the sandbox runtime image.
- `scripts/check-upstream-args.sh` also holds the rest of upstream's driver
  `main.rs` (its `main()`) to a reviewed hash, `scripts/upstream-main-rs.sha256`,
  and prints the upstream diff when it changes.

### Removed

- **`/metrics` on the driver health port.** Nothing scraped it; upstream traces
  over OTLP. Set `driver.otlpEndpoint`.
- The vendored `ComputeDriver` proto and `crates/computev1`, the proto-drift
  check, `scripts/check-inference-local.sh` (it detected the removal of
  `inference.local`, which has landed), the `make test-integration` target
  with `tests/live_cluster.rs`, and `docs/why-init-container.md` (the init
  container it explains is gone).
- The `make e2e-cli` target and `scripts/e2e-cli.sh`, which drove a v0.0.50 CLI
  against the old single-pod topology and ran nowhere; the kind smokes cover
  that path.
- `scripts/render-static-kubeconfig.js`, a kubeconfig helper nothing in the
  repository referenced.

### Known limitations

- **Do not create sandboxes from
  `ghcr.io/nvidia/openshell-community/sandboxes/base:latest`.** Its embedded
  sandbox policy is rejected by the v0.1.2 supervisor ("Image policy is
  invalid"), so such a sandbox never reaches Ready. Use the chart's default
  image (no `--from`) or an image without an embedded policy. The docs and
  smokes no longer reference it.
- **APIRule exposure does not carry traffic yet.** Kyma's APIRule v2 refuses a
  rule whose target pod has no Istio sidecar (`Pod … does not have an injected
  istio sidecar`, live check on v0.9.0), and upstream v0.1.2's workload fence
  gives the workload pod no egress, so an injected sidecar could not reach
  istiod. `driver.enableApirule` creates the Service, NetworkPolicy and APIRule
  as documented, but the ingress gateway answers 403 until a mesh-compatible
  design lands. Treat it as experimental. Since then exposure defaults to an
  Istio VirtualService, which needs no sidecar; see "Unreleased".
- **Claude Code's real executable must be in `inferenceProvider.binaries`.**
  The npm launcher `/usr/bin/claude` execs into
  `/usr/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe`, which is
  the path the supervisor sees on the request; the chart default lists it
  (upstream's `claude-code` profile lists only the launcher paths). Images that
  install Claude Code elsewhere need their own path added, which the supervisor
  log names (`DENIED <path> -> <host>:<port>`).
- **Operator mode:** the namespace owner must grant the driver `create` and
  `delete` on Secrets in each operator namespace. Upstream ships that Role in
  its separate `openshell-workspace` chart; this chart does not.
- **The SAP AI Core bridge** (`bedrockBridge`): with `networkPolicy.enabled`,
  its NetworkPolicy admits only OpenShell pods in the release namespace
  (`.Release.Namespace`). A sandbox reaches it only if it runs there: shared
  mode with `namespace` equal to the release namespace. Sandboxes in managed or
  operator mode, or in a different `namespace`, cannot.
- **`driver.otlpEndpoint` must be plain `http://`.** Upstream v0.1.2 builds its
  OTLP exporter without TLS, so an `https://` endpoint logs an error and
  exports nothing.
- **With `gateway.dbPersistence.enabled=false`,** a gateway restart loses the
  provider and profile until the next `helm upgrade` re-runs the hook.
- **`driver.sandboxEnv` values (and `inferenceProvider.baseUrl` and `modelId`)
  cannot contain a comma:** the driver splits the list on commas. Set such a
  variable per sandbox instead.
- **Gateway TLS (`gateway.tls.enabled`) is not verified end to end.** The PKI
  hook issues the gateway's server certificate with no SAN for the in-cluster
  Service name: `gateway-jwt-pki-hook.yaml` passes no `--server-san`, where
  upstream's certgen passes the Service's DNS names, `127.0.0.1` and any extras
  (`deploy/helm/openshell/templates/certgen.yaml:109-121` at v0.1.2). Supervisors
  dialling `https://<fullname>.<namespace>.svc.cluster.local` will likely fail
  certificate verification. Leave `gateway.tls.enabled` off (the default)
  unless you have verified it against your supervisors.

## [0.8.0] — 2026-09-28

### Added

- **Re-vendored the `ComputeDriver` proto contract to upstream `v0.1.2`**
  (`proto/UPSTREAM.lock`, via `make proto-vendor TAG=v0.1.2`). Unlike the
  prior `v0.0.116` move, this one changed the wire shape substantially, and
  `compute_driver.proto` gained two new transitive proto dependencies
  (`extension.proto`, `sandbox.proto`, which itself pulls in
  `datamodel.proto`) that upstream did not previously require —
  `scripts/vendor-proto.sh`'s `FILES` list and `crates/computev1/build.rs`'s
  compile list were extended to vendor and compile all three, and
  `crates/computev1/src/lib.rs` now nests the generated modules as
  `openshell::{compute,extension,sandbox,datamodel}::v1` (re-exported
  flat under `pb::` for existing call sites) so prost's cross-package
  `super::` references resolve.
  - **`GetGatewayListenerRequirements` was removed** and replaced with
    **`AuthenticateSandbox`**, which this driver implements: it performs the
    Kubernetes `TokenReview` on the sandbox's projected ServiceAccount token
    itself and advertises `GetCapabilitiesResponse.supports_sandbox_authentication`.
    See "Changed" below and `sandbox_auth.rs` / `provisioner.rs`.
  - **`GetCapabilitiesRequest`/`Response` gained a peer capability/protocol-
    version negotiation scheme** (`extension.proto`'s `PeerMetadata`), plus
    `resource_capabilities`, `rootfs_tar_staging_dir`/`rootfs_tar_max_bytes`,
    and `resource_admission_policy`. This driver now rejects a
    `GetCapabilitiesRequest.gateway` with unmet `required_capabilities` (per
    that field's own contract comment), reports `resource_capabilities`
    reflecting already-implemented CPU/memory-limit and GPU-selection
    behavior (`helpers::build_resources`, `helpers::effective_gpu_count`),
    reports no rootfs-tar support (unimplemented), and acknowledges the
    gateway's resource-admission policy (see "Changed" below). The
    `extension.protocol_version`/`implementation_name` values sent back
    remain a conservative self-identification with no verified interop
    reference (open TODO at the call site in `driver.rs`), and the driver
    does not yet implement the wider operator admission/policy negotiation
    surface (`DriverSandboxSpec.policy`, `WorkloadIdentityRequest`,
    `DriverFenceEvidence`).
  - **Field renames and retyping**, all with exactly one call site, now
    updated: `sandbox_name` → `name` on `GetSandboxRequest`,
    `StopSandboxRequest`, `StartSandboxRequest`, `DeleteSandboxRequest`, and
    `DriverSandboxStatus`; `DriverCondition.last_transition_time` (string) →
    `transition_time` (`google.protobuf.Timestamp`); and
    `DriverPlatformEvent.timestamp_ms` (int64 millis) → `event_time`
    (`google.protobuf.Timestamp`). New helpers
    `helpers::parse_timestamp`/`helpers::jiff_to_prost_timestamp` cover the
    RFC3339-string and typed-`k8s_openapi::Time` conversion paths
    respectively.
  - **The pinned gateway/supervisor container image digests**
    (`gateway.image.tag`, `driver.supervisorImage` in
    `deploy/helm/openshell-driver-kyma/values.yaml`) were bumped to the
    `v0.1.2` images in the same change. See the updated comment above
    `gateway.image` in `values.yaml` for the full contract-diff writeup and
    prior-pin history.
  - `cargo test --workspace` gained coverage for the new/changed surface:
    `driver.rs`'s `get_capabilities_rejects_unmet_gateway_required_capabilities` /
    `..._accepts_gateway_with_no_required_capabilities`, and
    `helpers.rs`'s `parse_timestamp_handles_empty_and_
    malformed_strings` and an updated `conditions_array_is_extracted`.

### Changed

- **UPGRADE NOTE: delete all existing sandboxes before upgrading to this
  release.** `IssueSandboxToken` compares the sandbox's persisted
  `COMPUTE_DRIVER` and `COMPUTE_RUNTIME_IDENTITY` annotations, and sandboxes
  created under v0.0.116 do not carry them. Their bootstrap is therefore
  denied, and there is no back-fill path. Drain and recreate every sandbox;
  do not expect an in-place upgrade of running ones.
- **Gateway config is schema v2.** The chart's `gateway.toml` now sets
  `version = 2`, no longer emits a gateway-scope `sandbox_namespace`, and
  declares `[openshell.drivers.kyma]` with `socket_path` and
  `allow_driver_config`. The TOML is now rendered whenever the gateway runs
  (previously only with sandbox-JWT enabled). New chart value
  `driver.allowDriverConfig` feeds both the TOML and the driver's
  `--allow-driver-config` flag so the two sides cannot disagree; upstream
  defaults it to false, which would reject every caller `driver_config`.
  The gateway container selects the driver with `--compute-driver kyma`
  (upstream v0.1.x removed `--drivers`).
- **`AuthenticateSandbox` is implemented and the capability is advertised**
  (`supports_sandbox_authentication: true`). The driver, not the gateway,
  performs the `TokenReview` on the projected ServiceAccount token
  (upstream deleted the gateway's `auth/k8s_sa` authenticator in v0.1.2),
  resolves the presenting Pod to its Sandbox CR, and enforces that the Pod
  is owned by that CR.
- **`runtime_identity` is returned from `CreateSandbox`, `StartSandbox` and
  `AuthenticateSandbox`** as `kyma://{namespace}/{sandbox_uid}`, produced by
  one function (`sandbox_auth::runtime_identity`) so the three cannot drift.
- **The resource-admission acknowledgement is reported** in
  `GetCapabilitiesResponse.resource_admission_policy`. It must equal the
  policy the gateway derives from `[openshell.drivers.kyma]`, otherwise the
  gateway refuses the driver at startup.
- **The `tokenreviews: create` ClusterRole grant is now ungated** (no longer
  conditional on `gateway.sandboxJwt.enabled`), because the driver's
  ServiceAccount performs the TokenReview.
- **New CI guard `scripts/check-gateway-config.sh`** renders the chart's
  gateway TOML and proves the digest-pinned gateway image the chart deploys
  accepts it (`GATEWAY_CONFIG_ACCEPTED`), so a schema break is caught in CI
  rather than at install time.
- **The gateway pin is lifted.** `.github/upstream-compat.env` is back to
  `GATEWAY_REF=latest` (which resolves to v0.1.2 today) and `PIN_BLOCKED_BY`
  is gone; the migration the pin was waiting for has landed.

### Known gap (not addressed by this release)

- **Upstream removed the managed inference router and `inference.local`**
  between `v0.0.116` and `v0.1.2` (confirmed via
  `scripts/check-inference-local.sh v0.1.2`; tracks NVIDIA/OpenShell#3195).
  This is an architecture change behind an **unchanged** `ComputeDriver`
  wire contract, so it is invisible to `check-proto-drift.sh` and to
  everything else in this release. `provisioner.rs` still injects
  `ANTHROPIC_BASE_URL=https://inference.local` /
  `OPENAI_BASE_URL=https://inference.local` into every sandbox, and that
  host no longer resolves against a `v0.1.2`+ gateway; the chart's
  `inferenceProvider.*` values configure the now-removed workspace-global
  route rather than the replacement provider-profile-plus-attachment
  workflow. This requires its own dedicated design (there is no upstream
  Kubernetes driver source vendored in this repo to confirm the replacement
  wiring against) and is intentionally **not** fixed here — see
  `scripts/check-inference-local.sh`'s inline hints for where to start.

## [0.6.0] — 2026-08-31

### Added

- **Re-vendored the `ComputeDriver` proto contract to upstream `v0.0.116`**
  (`proto/UPSTREAM.lock`, via `make proto-vendor TAG=v0.0.116`). This is a
  no-op at the wire level: `proto/compute_driver.proto` and
  `proto/options.proto` are byte-identical (same sha256) between `v0.0.111`
  and `v0.0.116` — only the tag and commit upstream cut releases against
  changed. `cargo build --workspace --all-targets` needed no code changes,
  and no test changes were required, because there is no new or altered
  RPC/message surface to implement or exercise.
  - The pinned gateway/supervisor container image digests
    (`gateway.image.tag`, `driver.supervisorImage` in
    `deploy/helm/openshell-driver-kyma/values.yaml`) are intentionally
    **unchanged** and remain the `v0.0.111` images: upstream has tagged
    `v0.0.112` through `v0.0.116` without publishing matching
    gateway/supervisor container images, so `.github/upstream-compat.env`
    keeps `GATEWAY_REF=v0.0.111` pinned (see that file's `PIN_REASON`,
    `PIN_REVIEW_AFTER=2026-09-07`). The proto contract pin and the image
    pin are independent axes; see the comment above `gateway.image` in
    `values.yaml`.

### Security

- **The sandboxed user can no longer advertise networking capabilities to
  its own supervisor.** `OPENSHELL_NETWORK_RUNTIME_CAPABILITIES` is now set
  (empty) by the driver, overriding any value supplied through
  `spec.environment`. Empty and absent are behaviourally identical to the
  supervisor, so this is a defensive overwrite rather than a declaration —
  without it a sandbox could claim `policy-dns-transparent-tcp` and the
  supervisor would proceed on a substrate Kyma does not provide, instead of
  failing loudly. Upstream overwrites it unconditionally for the same
  reason.

### Added

- **`driver.telemetryEnabled` (default `false`), propagated to every sandbox
  supervisor as `OPENSHELL_TELEMETRY_ENABLED`.** This driver emits no
  telemetry of its own, and upstream's Kubernetes driver compiles telemetry
  out and effectively sends `"false"` as well, so `false` is both the
  faithful default and the safe one.
  - **It is sent explicitly rather than omitted, and that distinction is the
    point:** a supervisor image built with the `telemetry` feature treats an
    *absent* variable as **enabled** (`value.unwrap_or("true")` in
    openshell-core). Omitting it would silently opt such an image in.

- **Optional numeric sandbox identity (`driver.sandboxUid` /
  `driver.sandboxGid`).** Without it the driver supplies no identity
  metadata, which upstream classifies as `DriverIdentity::None` — the same
  bucket as VM/offline drivers — and the supervisor falls back to resolving
  the *name* `sandbox` from the image's `/etc/passwd`. That works only for
  images carrying such a user. Upstream's own Kubernetes driver sits in the
  `Resolved { uid, gid }` bucket instead, which is what lets it run images
  that have no `sandbox` entry. Setting `sandboxUid` opts into that path.
  - **Default is unchanged and emits nothing** — existing sandboxes keep
    resolving by name.
  - `sandboxGid` defaults to `sandboxUid`, mirroring upstream's
    `sandbox_gid.or(sandbox_uid)`.
  - Only the config half of upstream's resolution is mirrored; its other
    source is OpenShift SCC namespace annotations, which Kyma does not have
    — the same reason `bootstrap_managed_namespace` does not copy them.
  - The driver refuses to start on an out-of-range value, or on a
    `sandboxGid` with no `sandboxUid` (which the supervisor would silently
    ignore, since it needs both).

- **`spec.environment` now reaches `openshell sandbox exec` and SSH
  sessions.** The supervisor runs those children under `env_clear()` for
  isolation, so pod env alone only ever reached the sandbox's main process.
  The driver now also sends `OPENSHELL_USER_ENVIRONMENT` (upstream's
  mechanism, JSON-encoded), which the supervisor re-injects per child. This
  is the root cause of the long-standing "pod-spec env does not propagate to
  exec sessions" behaviour — it was never CLI filtering.
  - **Deliberate divergence:** upstream sends only the caller's own
    `spec.environment`; this driver also includes the agent-facing injected
    variables (`ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`,
    `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`), since strict parity would
    fix the mechanism and leave the symptom. Supervisor plumbing
    (`OPENSHELL_*`) is excluded on purpose.
- **`spec.log_level` is honoured**, propagating to the supervisor as
  `OPENSHELL_LOG_LEVEL` (contract field 1, previously unread).

## [0.5.0] — 2026-08-24

### Added

- **Synced the `ComputeDriver` contract to upstream v0.0.111.** Diff against
  the previous v0.0.109 pin: `GetCapabilitiesResponse` gained
  `gateway_manages_lifecycle` (field 6) and `DriverSandboxSpec` gained
  `command` (field 12, repeated string) and `tty` (field 13, bool). No RPC
  was added or removed; both changes are purely additive fields, so this is
  wire-compatible in both directions and required no gRPC handler changes —
  only new fields on two existing messages.
  - `gateway_manages_lifecycle` lets a driver ask the gateway to stop
    sandbox compute during its own graceful shutdown and restart the
    retained running intent on startup — bracketing meant for drivers whose
    compute is tied to the gateway process's lifetime. This driver always
    returns `false`: a Kyma sandbox is a Pod/Sandbox CR living in the
    cluster independently of the driver or gateway process, and
    `WatchSandboxes` already reflects its true state continuously
    regardless of either restarting, so there is nothing here for the
    gateway to bracket. See `driver.rs::get_capabilities`.
  - `command`/`tty` let a caller specify the sandbox's canonical process
    (argv, unparsed by a shell) and whether it gets a retained pseudo-
    terminal. **Deliberately left unimplemented.** This driver already
    injects a fixed `OPENSHELL_SANDBOX_COMMAND=sleep infinity` env var for
    the supervisor, but that mechanism is a single shell-parsed string with
    no tty equivalent, and nothing in this repo or its vendored sources
    establishes what wire format the supervisor now expects for an
    argv-style command (a new env var? JSON-encoded? indexed vars?) or for
    tty allocation (an env var, or the Pod container's own `tty`/`stdin`
    fields). There is no vendored upstream Kubernetes driver source in this
    repo to confirm against. A `TODO` at the call site
    (`provisioner.rs::build_full_env_list`) and a pinned regression test
    (`driver_injected_env_ignores_request_command_and_tty_for_now`) record
    this gap explicitly rather than guessing at a wire contract that could
    silently break sandbox startup.
- **Re-pinned `gateway.image.tag` and `driver.supervisorImage` by digest** to
  the v0.0.111 builds:
  - gateway: `sha256:004ca59466ca388884af843a437d55674d7638a96132fb8fad8bcbb2db634bdd`
  - supervisor: `sha256:cdad6b34973c06ea330cbba93e8264b50195de040c1c02f4981a97773603bcfc`

## [0.4.0] — 2026-08-19

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

### Fixed

- **`create_sandbox` now bootstraps a `Managed`-mode namespace itself,
  instead of assuming the gateway already called `EnsureWorkspace`.** That
  assumption was false: grepping the gateway at v0.0.109, `ensure_workspace`
  is never called from `grpc/sandbox.rs` (its only callers are gated on
  `stores_provider_credentials()`), nor by `openshell workspace create`. The
  managed-mode interop smoke caught this in CI: `create sandbox failed:
  namespaces "openshell-smoke-default" not found`. Matches upstream's
  Kubernetes driver, which bootstraps lazily inside its own `create_sandbox`
  (`driver.rs:1358`) for exactly this reason. `KymaProvisioner::create` now
  calls the existing (already-idempotent) `bootstrap_managed_namespace`
  under `Managed`, after `driver_config` validation and before the Sandbox
  CR (and any workspace PVC) are created — so a malformed request still
  fails before touching the cluster, and the namespace exists before
  anything is placed in it. `Shared` and `Operator` are unaffected: `Shared`
  bootstraps nothing (unchanged), and `Operator`'s own precondition (the
  allowlist check) is unchanged. Deliberately does **not** call
  `ensure_image_pull_secrets` or copy OpenShift SCC annotations the way
  upstream's Kubernetes driver does — neither concept has an analogue on
  Kyma. The `EnsureWorkspace` RPC itself is unchanged and remains part of
  the contract; it is simply not the only path to bootstrap any more.
- **Removed `ASSERT 3b` (stop/start) from `scripts/interop-smoke.sh`.** It
  could never pass there: the gateway refuses `StopSandbox`/`StartSandbox`
  unless the sandbox's phase is already `Ready`
  (`crates/openshell-server/src/compute/mod.rs:1082`), and this smoke
  deliberately installs only the agent-sandbox CRD with no controller, so a
  sandbox's phase never advances. The RPC was rejected by the gateway
  itself (gRPC status 9, `FailedPrecondition`) before ever reaching this
  driver — not a driver bug, and the same gate applies to upstream's own
  Kubernetes driver. A comment in its place records why, so it isn't
  re-added; stop/start remain covered by unit tests and by verification
  against a real cluster with a running controller.

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
