# Upstream chart parity on Kyma (0.11.0) — design

**Status:** for review (2026-10-21), builder check done. Targets chart/driver 0.11.0.
**Baseline:** main after 0.10.4 (`c023df0`), upstream OpenShell v0.1.4, gateway
image pinned at `gateway.image.tag`.
**Appendix:** `2026-10-21-chart-parity-0110-gap-audit.md`, the key-by-key audit
of upstream `deploy/helm/openshell/values.yaml` @ v0.1.4 against our chart, with
the upstream template, source and test line references for every gap. This
document decides *what* to build; the appendix is the reference for *how
upstream does it*. Gap numbers (1.1 … 4.7) refer to the appendix.

## 1. Intent

The project rule is full feature parity with upstream's Kubernetes deployment.
The 2026-10-19 audit found that our chart cannot express about 60 upstream
settings: the 0.10.1 "parity" pass only covered what v0.1.3 changed. 0.11.0
closes those gaps.

The user's framing for this release: **"Strive for feature parity where feasible
with the Kyma environment."** That means:

- Every upstream *capability* an operator can switch on with upstream's chart
  must be reachable with ours, unless it cannot work on Kyma or is tied to an
  architecture we deliberately don't have (single replica, driver as a sidecar
  over a Unix socket, Istio instead of Gateway API).
- Parity is of **capability, not key names**. Our values keep their existing
  layout (`gateway.*`, `driver.*`); a new key goes where our chart's structure
  puts it, named after upstream's key where that reads naturally. Exception:
  `gatewayConfig` keeps upstream's top-level name, because operators paste
  upstream snippets into it verbatim.
- Defaults stay where they are unless upstream's default is a security
  property (§5.3) or the old default was a bug.

## 2. Goals, non-goals, anti-goals

**Goals**

1. All class (a) gaps of the appendix, groups 1–4, implemented, except 3.1 which
   shipped in 0.10.4.
2. Certificates from **cert-manager** *and* from **Gardener's certificate
   service** (`cert.gardener.cloud`), both opt-in. The PKI hook stays the default.
3. The four "surprises" that are defects, fixed (§5).
4. Each new value proven three ways, as for earlier releases: a render assertion
   in `scripts/check-chart-render.sh`; acceptance by the pinned gateway image in
   `scripts/check-gateway-config.sh` wherever the value reaches a flag or TOML;
   and a live or kind run where the feature talks to something external (§7).

**Non-goals**

- Class (b) keys (we have them under another name) and class (c) keys (cannot
  apply: HA/replicas, `workload.kind`, autoscaling, Gateway API `grpcRoute`,
  OpenShift routes, `certManager.serverIssuerRef`, `workspaceResources`). The
  appendix's last table lists each with its reason.
- Renaming existing values to upstream's names.
- A helm-unittest suite. Upstream's `tests/*.yaml` cases are ported as
  assertions into `check-chart-render.sh`.
- Open items outside the audit: IAS tenant test (#82), the `numTrustedProxies`
  decision, the walkthrough's stale chart version, `rea`'s "Completed" phase.

**Anti-goals** (a technically working result that is still a failure)

- Anything that changes what other applications on the shared Kyma ingress see.
  No RequestAuthentication on the shared ingress; no writes to `istio-system` or
  `kyma-system`; the neighbour probes must be unchanged before and after the
  `ods` upgrade.
- An existing install that upgrades with unchanged values and silently loses
  access, sandboxes, stored credentials or its gateway identity. Every default
  that changes behaviour gets a CHANGELOG "Upgrading" entry and, where possible,
  a render-time failure with a clear message instead of a silent change.
- A value that renders but the pinned gateway ignores or refuses at startup
  (the flag-beats-TOML trap, clap duplicate flags).

## 3. Constraints

- **Gateway precedence:** CLI flag > `OPENSHELL_*` env > TOML > default. Our
  chart passes most settings as flags (`templates/deployment.yaml`). A setting
  must be rendered in exactly one of those places; a TOML key for something the
  chart already passes as a flag is dead.
- **clap duplicates:** once the chart passes a flag, an operator who also has it
  in `gateway.extraArgs` gets a startup failure. Every new first-class flag
  needs a render guard that fails with a message naming the value to use
  instead (pattern: "gateway.extraArgs sets --X; use gateway.Y instead").
- **Single pod, shared ServiceAccount:** the driver and gateway containers share
  one pod and one SA. RBAC or SA annotations given to "the gateway" apply to
  both; say so in the values comments.
- **PSS restricted** in the release namespace: no hostPath, no privilege. CSI
  ephemeral volumes are allowed.
- **Kyma ingress:** clients reach the gateway through the Istio ingress, which
  terminates public TLS and re-encrypts to the pod using the CA ConfigMap
  `<fullname>-gateway-ca` (DestinationRule `credentialName: configmap://…`).
  The chart writes nothing into the ingress gateway's namespace.
- **No secrets in values or args:** database URLs with passwords, Vault tokens
  and keys come from Secrets (env `secretKeyRef` or mounted files), as upstream's
  `gatewayConfig` guards require.
- Rust builds and tests run only in the dev container via `make`. Python check
  scripts run with `/usr/bin/python3` (PyYAML).
- Cluster domain, tenant, client ids and secrets never go into files.

## 4. What gets built, per group

### 4.1 Gateway settings (group 1)

| Gap | New value(s) | Rendered as | Notes |
|---|---|---|---|
| 1.1 | `gateway.name` (default: chart fullname) | TOML `[openshell.gateway] name` | `driver.gatewayName` defaults to the same value. Default changes from `openshell` (§5.4). |
| 1.2 | `gateway.otlp.{endpoint,serviceName}` | TOML `[openshell.gateway.otlp]`, only when `endpoint` is set; `service_name` only when non-empty | `driver.otlpEndpoint` defaults to `gateway.otlp.endpoint` (one setting, as upstream). NetworkPolicy egress opens its port (§4.6). |
| 1.3 | `gateway.telemetryEnabled` (default **`false`**, upstream `true`) | env `OPENSHELL_TELEMETRY_ENABLED` on the gateway container, always rendered | User decision: no telemetry to NVIDIA (§5.2). |
| 1.4 | `gateway.policyValidationFailureMode` (default `fail_closed`) | TOML | Render guard: only `fail_closed` / `retain_last_valid`. |
| 1.5 | `gateway.enableLoopbackServiceHttp` (default `true`) | TOML | Same default as today. |
| 1.6 | `gateway.enableWebsocketTunnel` (default `false`) | TOML | Values comment: our ingress does not authenticate; the gateway does. The builder checks whether the VirtualService passes WebSocket upgrades and documents the result; no ingress change unless it is needed and neighbour-safe. |
| 1.7 | `gateway.oidc.{jwksTtl,scopesClaim,jwksAllowedOrigins,dangerouslyAllowInsecureHttp}` | flags, inside the existing OIDC flag block | Same mechanism as the other OIDC settings; extraArgs duplicate guard. |
| 1.8 | `gateway.oidc.caConfigMapName` | env `SSL_CERT_FILE` + ConfigMap mount, as upstream | Values comment: replaces the trust store for *all* outbound TLS of the gateway (Vault, https OTLP). |
| 1.9 | top-level `gatewayConfig` | upstream's YAML→TOML serializer and guards, ported | §4.5. |

Where upstream renders a setting as TOML and the gateway also has a flag
(1.5, 1.6), use TOML like upstream, so that `gatewayConfig` and the first-class
value meet in one place.

### 4.2 Pod and Kubernetes plumbing (group 2)

| Gap | New value(s) | Notes |
|---|---|---|
| 2.1 | `serviceAccount.annotations`, `sandboxServiceAccount.annotations` | Gateway SA annotation applies to the driver too. |
| 2.2 | `gatewayService.type` (default `ClusterIP`), `gatewayService.nodePort` | Applies to the existing Service. Values comment: a LoadBalancer/NodePort bypasses the ingress CIDR fence and exposes every port of that Service. The builder decides whether the driver health port must move to its own Service first (it should not be public). |
| 2.3 | `gateway.terminationGracePeriodSeconds` (default 30) | Pod-level; shared with the driver. |
| 2.4 | `gateway.probes.{startup,liveness,readiness}` | Upstream's defaults and a new `startupProbe`. This changes today's hardcoded timings to upstream's (§6). |
| 2.5 | (none) | Pod `hostAliases` derived from the existing `driver.hostGatewayIp`. |
| 2.6 | `gateway.dbPersistence.externalDbSecret` | Env `OPENSHELL_DB_URL` from the Secret's key `uri`; no `--db-url`; no PVC. Guard: not together with `dbUrl`. Existing `dbUrl` stays, with a values comment preferring the Secret. |
| 2.7 | `gateway.tls.clientCa.secretName` | Empty = the server Secret's `ca.crt` (today). Needed by cert-manager/Gardener with a separate client CA. |
| 2.8 | `gateway.sandboxJwt.serverDnsNames`, `serverIpAddresses` | Appended to the PKI hook SANs and merged into the one runtime `--server-san` flag list. Values comment: the hook never rewrites existing Secrets. |
| 2.9 | `gateway.sandboxJwt.secretDefaultMode` (default `0400`) | Sandbox-JWT and TLS volumes. |
| 2.10 | `rbac.create` (default `true`) | Gates every namespaced Role/RoleBinding the chart renders, and the cluster pair together with `rbac.clusterScoped.create`. Hook Roles (PKI, provider, CRD check) stay ungated, as upstream's certgen Role. |

### 4.3 Credential storage and drivers (group 3)

- **3.1 (done in 0.10.4).** When an external credential driver is selected, the
  KEK Secret, its env and the `credential_storage` table are not rendered, as
  upstream. Switching an install from the default store to an external driver
  orphans the credentials already stored: the values comment and the docs say
  so.
- **3.2 `gateway.credentialDrivers.kubernetesSecrets.{enabled,namespace,createNamespace,rbac.create}`.**
  TOML as upstream; Role `<fullname>-credential-secrets` (secrets
  get/create/patch/delete) and RoleBinding to the shared SA; optional Namespace
  with `resource-policy: keep`. Guards: upstream's "only one backend" and
  `createNamespace` messages; refuse `namespace` equal to the sandbox namespace
  `.Values.namespace` (sandbox bootstrap Secrets live there).
- **3.3 `gateway.credentialDrivers.vault.*`**, plus upstream's
  `caConfigMapName` (one location: `gateway.credentialDrivers.vault.caConfigMapName`).
  `timeoutSecs` rendered as an integer. NetworkPolicy egress to the Vault port
  (§4.6).
- **3.4 SPIFFE, gateway side:** `gateway.providerTokenGrants.spiffe.{enabled,workloadApiSocketPath}`
  drives both the gateway (env `OPENSHELL_GATEWAY_SPIFFE_WORKLOAD_API_SOCKET`,
  CSI volume `csi.spiffe.io`) and the driver (`OPENSHELL_PROVIDER_SPIFFE_WORKLOAD_API_SOCKET`).
  `driver.providerSpiffeWorkloadApiSocket` stays as an override for the driver
  side.
- Selecting a backend through `gatewayConfig` (`credential_drivers`) behaves the
  same as through these values, with upstream's guards.

### 4.4 Certificates: cert-manager and Gardener (group 4)

**Values** (all under `gateway.certManager`):
`enabled` (default `false`), `api` (`cert-manager.io` | `cert.gardener.cloud`,
default `cert-manager.io`), `caSecretName`, `caDuration`,
`clientCaFromServerTlsSecret` (default `true`), `certificateDuration` (default
`8760h`), `certificateRenewBefore` (default `720h`), `serverDnsNames`,
`serverIpAddresses`, plus `gateway.sandboxJwt.timeoutSeconds` and
`failOnTimeout` for the CA poll.

**Resources**, in the release namespace, with one template per API:
self-signed Issuer, CA Certificate, CA Issuer, server Certificate, client
Certificate. They target the **existing** Secret names
(`gateway.sandboxJwt.serverTlsSecretName` / `clientTlsSecretName`), so the
gateway mounts and the driver's client-Secret env don't change. Server SANs are
our hook's SAN set plus `serverDnsNames`/`serverIpAddresses` (not upstream's
`openshell.openshell.*` defaults).

**Hooks:**
- The pre-install/pre-upgrade PKI hook switches to
  `generate-certs --jwt-only --jwt-secret-name=…` when `certManager.enabled`.
- A new post-install/post-upgrade Job (upstream's `-certgen-backend-ca`
  equivalent) fills `<fullname>-gateway-ca` from the server Secret's `ca.crt`
  for the Istio DestinationRule, using `--backend-ca-*` flags. It is rendered
  only with `gatewayIngress.enabled`.

**Gardener-specific** (proven on `ods` on 2026-10-20 with a throwaway namespace):
- Namespaced Issuers and Certificates work outside `kyma-system`;
  `selfSigned` and `ca` issuers work; leaf Secrets contain `ca.crt`, `tls.crt`,
  `tls.key`, and leaves verify against the CA.
- The CA Issuer is `spec.ca.privateKeySecretRef: {name, namespace}`; Certificates
  use `issuerRef: {name, namespace}`.
- **Gardener refuses a leaf whose lifetime exceeds the CA's** (cert-manager
  truncates). The CA Certificate therefore always gets an explicit `caDuration`
  (default `87600h`, ten years) for both APIs, and a render guard fails unless
  `caDuration` > `certificateDuration` + `certificateRenewBefore`.
- The builder verifies the `usages` strings and the private-key fields against
  the cluster's CRD (`kubectl explain`, read-only) before writing the template.

**CA renewal and the DestinationRule ConfigMap.** The ConfigMap is only
refreshed by hook runs. When the CA is renewed, the ingress keeps trusting the
old CA until the next `helm upgrade` and traffic through the ingress fails.
The ten-year CA default makes this rare. Docs state the procedure: renew →
`helm upgrade` (same values) refreshes the ConfigMap. No CronJob in 0.11.0.

**Switching an existing install** between the PKI hook and cert-manager/Gardener
(either direction) is supported by a documented procedure, not automated:
delete the server, client and JWT Secrets, `helm upgrade`, then restart the
gateway and recreate or restart running sandboxes, which keep their mounted
copy of the old `ca.crt`. Without deleting them, certgen's mixed-state refusal
or cert-manager's takeover decides the outcome, so the docs make the deletion
step explicit. CI kind and the `ods` Gardener run test fresh installs only.

### 4.5 `gatewayConfig` passthrough (1.9)

- Port upstream's serializer (`_toml.tpl`) and every guard message quoted in the
  appendix, with "chart value fills only absent keys" semantics: our chart's
  own tables (`auth`, `gateway_jwt`, `ocsf_log`, `credential_storage`, OTLP, …)
  merge with a user table of the same name, and the user's key wins over a
  first-class value unless the key is chart-owned.
- **Chart-owned, refused with a message:** the `[openshell.drivers.kyma]` tables
  (socket and admission, which the driver must acknowledge), TLS paths, bind
  addresses, `database_url`, and any key the chart passes as a CLI flag (it
  would be silently overridden). The message names the value to use instead.
- `openshell.drivers.kubernetes.*` is refused: our driver is configured by env,
  so it would do nothing.
- `check-gateway-config.sh` proves a representative fixture against the image.

### 4.6 NetworkPolicy egress

When `networkPolicy.enabled`, the pod policy opens, in addition to today's:
the gateway OTLP port (parsed from `gateway.otlp.endpoint`, as for the driver)
and the Vault port (parsed from `address`, default 8200). An external database
is reached through `networkPolicy.extraEgress`, because its URL is inside a
Secret the chart cannot read; the values comment for `externalDbSecret` says so.

## 5. Defects fixed alongside

### 5.1 mTLS-only mode admits anyone

With `gateway.tls.clientCa.enabled` and no OIDC, the chart sets
`allow_unauthenticated_users = true`, and v0.1.4 TLS never requires a client
certificate, so a caller without one is admitted as the dev principal. The
values comment claims the opposite.

Fix: a new `gateway.auth.allowUnauthenticatedUsers` with upstream's meaning.
Its default is computed: `true` only when neither OIDC nor a client CA is
configured (today's dev mode); with a client CA and no OIDC the chart renders
mTLS user authentication instead, as upstream does. Setting it to `true`
explicitly together with a client CA fails rendering, whether it comes from
the value or from `gatewayConfig`. The values comment is corrected. CHANGELOG: clients of an mTLS-only install must now present the
client certificate (which is what the operator was told was already required).

Every sandbox receives the client Secret (`<fullname>-client-tls`). With one CA
for users and sandboxes (the PKI hook, or `clientCaFromServerTlsSecret: true`),
a process inside a sandbox can present that certificate and be accepted as a
user. This is upstream's model too. **User decision (2026-10-21): follow
upstream.** The values comment and `docs/production-deployment.md` state it
plainly (anyone who can read a sandbox's mounted client Secret can act as a
user of an mTLS-only gateway; use OIDC where that matters). A separate user
CA is out of scope for 0.11.0.

### 5.2 Telemetry

Today the gateway sends anonymous telemetry (on by default), while sandboxes
never do: our driver appears to be built without `openshell-core`'s `telemetry`
feature, so it always stamps `OPENSHELL_TELEMETRY_ENABLED=false` into
supervisors. The builder first confirms this with `cargo tree -e features` in
the dev container.

**User decision (2026-10-21): "No telemetry to NVIDIA."** Telemetry is off
everywhere by default, a deliberate departure from upstream:
- `gateway.telemetryEnabled` defaults to `false`; the env is always rendered,
  so the gateway's own default (`true`) never applies. This **stops** telemetry
  that existing installs' gateways send today.
- The driver stays built without the `telemetry` feature, so sandboxes keep
  receiving `OPENSHELL_TELEMETRY_ENABLED=false` whatever the value. The values
  comment says that `true` affects the gateway only. No Rust change.
- `driver.disableClaudeTelemetry` (Anthropic's Claude Code telemetry inside
  sandboxes) is a separate setting and is not changed by this release.

### 5.3 CA ConfigMap goes stale on renewal

Handled by §4.4 (long CA duration, documented procedure).

### 5.4 Gateway name default

Upstream names the gateway after the chart fullname; ours runs as `openshell`.
0.11.0 adopts upstream's default. Before the change, the builder checks in the
v0.1.4 source what the gateway name is persisted into (database rows, sandbox
records, JWT claims), and what the driver does with `driver.gatewayName`
(labels, selectors, annotations on sandbox objects). If an existing install would lose sandboxes or sessions,
the chart keeps `openshell` for upgrades (via `lookup` of the running
Deployment's config) and uses the fullname only for new installs; the CHANGELOG
explains which. One helper decides the name for both the gateway and the
driver, so they can never diverge. The `ods` rc test runs with the private
values unchanged; no `gateway.name` is added to them.

## 6. Behaviour changes for existing installs

| Change | Who is affected | Mitigation |
|---|---|---|
| mTLS-only now authenticates (5.1) | installs with a client CA and no OIDC | CHANGELOG; render failure on the contradictory combination |
| Gateway name default (5.4) | every install without an explicit name | source check first; `lookup` fallback if needed |
| Probe timings to upstream's | every gateway pod | none needed; values let operators restore the old timings |
| First-class flags vs `gateway.extraArgs` | operators passing the same flags today | render guard naming the replacement value |
| Gateway telemetry off by default (5.2) | every install with a gateway | CHANGELOG; `gateway.telemetryEnabled: true` restores it |

## 7. Verification

- **Render:** a `check-chart-render.sh` case per new value: default render
  unchanged where the default is unchanged, the value's rendering, and each
  guard's failure message (good-/bad- case pairs, as in 0.10.x).
  `check-chart-render.sh` is already 1680 lines; the builder may split new
  groups into a sibling script called from it, without restructuring the
  existing cases.
- **Image acceptance:** `check-gateway-config.sh` runs every new flag and TOML
  table against the pinned gateway image.
- **CI kind** (user decision: kind is enough for these): cert-manager mode
  end to end (gateway starts on cert-manager certificates, a sandbox connects);
  Vault credential driver (dev-mode Vault in kind, a provider credential stored
  and read back through a sandbox); SPIFFE (SPIRE + CSI driver in kind, the
  gateway gets its socket). These are new jobs or steps in the existing smokes;
  they may be slow, so they can run on PRs touching the chart and on tags.
- **Live on `ods`:**
  1. rc deploy of 0.11.0 with the private values unchanged: neighbour probes
     unchanged; `rea` and its providers still work; a gateway restart keeps
     credentials (0.10.4 check repeated).
  2. Gardener mode on `ods` in a second, throwaway release in its own namespace
     (no ingress, `gatewayIngress.enabled=false`): certificates issued, gateway
     starts, a sandbox connects; then uninstalled. The `ods` release itself
     stays on the PKI hook.
- `make test`, `make clippy`, `make fmt-check` if any Rust changes (none are
  planned).

## 8. Delivery

One branch and one release, 0.11.0, implemented task-by-task from a plan, with
an rc on `ods` before the tag. Commit type `feat(chart)!` because of §6.
Docs: `docs/production-deployment.md` gains sections on cert-manager/Gardener,
credential drivers and `gatewayConfig`; CHANGELOG "Upgrading" lists §6.

## 9. Left to the builder

- Template file layout and helper names.
- Exact guard wording for chart-specific guards (upstream's messages are kept
  verbatim where they apply, with the key names translated to ours).
- Whether 2.2 needs the driver health port split into another Service.
- How the CI kind jobs are split and triggered.

## 10. Decisions taken during review

- Telemetry: "No telemetry to NVIDIA" (5.2).
- Sandbox client certificates accepted as users on mTLS-only gateways: follow
  upstream and document it (5.1).

## Calls I made (check these while reading)

- `gatewayConfig` keeps upstream's top-level name; everything else lives under
  our existing `gateway.*` structure.
- cert-manager and Gardener share one `gateway.certManager` block with an `api`
  switch, rather than two blocks.
- CA duration default ten years for both APIs, with a guard, instead of a
  renewal CronJob.
- mTLS-only installs become authenticated by default (5.1).
- The gateway name follows upstream unless the source check shows it breaks
  existing installs.
- One release rather than one per group.
- Switching an existing install to or from cert-manager/Gardener: documented
  manual procedure; tests cover fresh installs only.
- Gateway name: one helper for the gateway and the driver; `ods` private values
  stay unchanged.
- `rbac.create` does not gate hook Roles (as upstream).
