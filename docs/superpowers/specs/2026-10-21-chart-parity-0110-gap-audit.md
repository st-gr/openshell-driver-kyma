# Chart parity gaps: openshell-driver-kyma vs upstream `deploy/helm/openshell` @ v0.1.4

Read-only audit, 2026-10-20; appendix to `2026-10-21-chart-parity-0110-design.md`.
Line numbers refer to the files as of that date. **Gap 3.1 (KEK) shipped in 0.10.4 (#92)**; it stays here for its upstream references.

Conventions:
- **U:** = upstream, `git show v0.1.4:<path>` in a checkout of NVIDIA/OpenShell; chart paths are relative to `deploy/helm/openshell/`.
- **O:** = our chart, `deploy/helm/openshell-driver-kyma/` (main @ a69cecb, chart 0.10.3).
- "Image" = the gateway pinned at `gateway.image.tag: sha256:bdb4fe24…` (O values.yaml:370-372). Everything below was checked against upstream **source** at v0.1.4 (`crates/openshell-server/src/cli.rs`, `config_file.rs`, …). That the pinned digest really is v0.1.4 is taken from the values comment. `scripts/check-gateway-config.sh` must still prove each new flag/TOML key against the image.
- Gateway precedence (U `crates/openshell-server/src/config_file.rs:12-15`): **CLI flag > OPENSHELL_* env > TOML > default**. Our chart passes most settings as CLI flags (O deployment.yaml:108-183), so any TOML key we add for a setting that is also passed as a flag is silently overridden.
- clap rejects a single-value flag given twice. Once the chart sets a flag itself, an operator who passes the same flag in `gateway.extraArgs` gets a startup failure. Every "new first-class flag" item below has this conflict with existing `gateway.extraArgs` users.

---

## 0. Surprises / corrections to the prior audit (read first)

1. **The credential KEK is ephemeral today (a bug, not just a missing `existingSecret`).** O renders no `[openshell.gateway.credential_storage]` (O gateway-config.yaml:65-137). The gateway then falls back to a file KEK at `$XDG_STATE_HOME|$HOME/.local/state` + `openshell/gateway/credentials/key-encryption-key.bin`:
   - default path: U `crates/openshell-driver-db-credstore/src/lib.rs:41,458-462,491-500`
   - load-or-create: U same file `:578-…`
   - state dir: U `crates/openshell-core/src/paths.rs:41-58`

   O mounts an **emptyDir** there (`gateway-state` at `/home/nonroot/.local/state`, O deployment.yaml:227-228, 280-281). So every pod restart creates a new KEK. With `gateway.dbPersistence.enabled` (PVC SQLite or Postgres), provider credentials stored before the restart become undecryptable: `"default credential storage object was encrypted with a different key-encryption key"` (U credstore lib.rs:690-693, `failed_precondition`). Upstream always generates and keeps a KEK Secret and passes it by env. Group 3.1 covers the whole mechanism, not only `existingSecret`.
2. **`gatewayConfig` (U values.yaml:306-308) is missing entirely.** It is upstream's generic YAML→TOML passthrough (U `_toml.tpl:1-10,100-364`). Without it, TOML-only settings cannot be reached at all; `gateway.extraArgs` cannot reach them because they have no flag. TOML-only settings:
   - `policy_validation_failure_mode`
   - `[openshell.gateway.otlp]`
   - `credential_drivers`, `default_credential_driver`, `credential_storage`
   - `ssh_session_ttl_secs`, `image_preparation_timeout_seconds`, `guest_tls_ca`
   - `interceptors`, `provider_profile_sources`, `mtls_auth`
   - `[[openshell.supervisor.middleware]]`
   - `[openshell.credential_drivers.*]`

   Full list: U config_file.rs:85-179, 296-333. Added as gap 1.9.
3. **Telemetry differs on the sandbox side as well as on the gateway.** In upstream, the in-process Kubernetes driver stamps `OPENSHELL_TELEMETRY_ENABLED` into every supervisor from its own process env (U `crates/openshell-driver-kubernetes/src/driver.rs:6763-6767`, `openshell_core::telemetry::enabled_env_value()`). Our driver links `openshell-core` with `default-features = false` (O Cargo.toml:29; upstream driver-kubernetes also uses `default-features=false`). Our `Cargo.lock` `openshell-core` entry has no `reqwest`/`chrono`, so the `telemetry` feature looks compiled out of our driver. `enabled_env_value()` then always returns `"false"` (U `crates/openshell-core/src/telemetry.rs:308-313`): our sandboxes always run with telemetry **off**. The gateway container has no env set, so the gateway's telemetry is **on** (default `"true"`, telemetry.rs:324-325). Inferred from Cargo.lock; confirm with `cargo tree -e features` in the dev container.
4. **`gateway.tls.clientCa.enabled` without OIDC does not authenticate anyone.**
   - v0.1.4 TLS never requires a client certificate: `require_client_auth: false`, U cli.rs:436-441.
   - O sets `allow_unauthenticated_users = true` whenever no OIDC issuer is set (O gateway-config.yaml:84-88).
   - With that flag on, a caller with no certificate is admitted as the dev principal (U `multiplex.rs:1135-1160`, `unauthenticated_dev_user_principal()`).
   - Result: "mTLS-only" mode is open. The O values comment at values.yaml:429-435 ("the gateway requires + verifies a client cert") is wrong for v0.1.4.
   - Upstream defaults `server.auth.allowUnauthenticatedUsers: false` and turns mTLS user auth on automatically when a client CA is set and there is no OIDC. Not a values gap, but it interacts with gap 2.7.
5. **`hostGatewayIP` is mostly covered already.** The sandbox side is `driver.hostGatewayIp` → `OPENSHELL_HOST_GATEWAY_IP` (O values.yaml:214, _driver-env.tpl:90-93). Only the **gateway pod's** `hostAliases` (U `_gateway-workload.tpl:42-48`) is missing.
6. **`certManager.serverIssuerRef` (external server certificate) does not apply to us.** It exists for SNI passthrough (OpenShift Route / GRPCRoute), where the gateway itself presents a public certificate. Our Istio ingress terminates the client's TLS with the cluster wildcard certificate and re-encrypts to the pod, which only needs the internal certificate. Classified (c).
7. Also missed by the prior audit:
   - `server.sandboxJwt.secretDefaultMode` (2.9)
   - `rbac.create` (2.10)
   - the top-level `credentialDrivers.vault.caConfigMapName` (U values.yaml:596-600, the preferred location, with `server.credentialDrivers.vault.caConfigMapName` as the legacy fallback)
   - the hidden `service.nodePort` (U service.yaml:18-20, no default in values)
   - NetworkPolicy egress: our pod policy (O networkpolicy.yaml:64-82) opens only 53, 443, the driver OTLP port and `extraEgress`. Gateway OTLP, a Postgres `externalDbSecret` (5432) and Vault (8200) all need egress rules, or a documented `networkPolicy.extraEgress`.
8. **`server.name` has a default-behaviour difference.** Upstream always renders TOML `name` = chart fullname (U `_toml.tpl:105`). Ours renders nothing, so the gateway uses `DEFAULT_GATEWAY_NAME = "openshell"` (U `crates/openshell-core/src/config.rs:29`).
9. **`enableLoopbackServiceHttp` (default true) and `policyValidationFailureMode` (default `fail_closed`) already behave the same as upstream's defaults** (U cli.rs:256-262; config.rs:52-60). Only the ability to change them is missing.

---

## Class (a) gaps

### Group 1: Gateway settings (9 gaps)

#### 1.1 `server.name` (gateway name)
- **U values:** `server.name: ""` (values.yaml:312-315), doc: "Defaults to the chart fullname so all replicas in one installation share an identity."
- **U renders:** TOML `[openshell.gateway] name = <server.name | default fullname>`, set only when absent from `gatewayConfig` (`_toml.tpl:105`).
- **Gateway accepts:** flag `--name`, env `OPENSHELL_GATEWAY_NAME`, default `"openshell"` (cli.rs:81-87); TOML `name` (config_file.rs:90-91, applied at cli.rs:1154-1157). An empty value fails: `"gateway name must not be empty"` (cli.rs:454-457). Used as the gateway's identity and OTel resource (cli.rs:627, 647).
- **U guards:** none in the chart.
- **U tests:** `tests/gateway_config_test.yaml` ("identifies the gateway by chart fullname by default" :75, "renders an explicit gateway name" :82); `tests/gateway_config_serializer_test.yaml`.
- **Lands in O:**
  - new `gateway.name` next to `gateway.grpcPort` (O values.yaml:373)
  - TOML `name = …` in `[openshell.gateway]` (O gateway-config.yaml:69-74), or flag `--name` in O deployment.yaml:115-135
  - default it to `include "openshell-driver-kyma.fullname"`, matching upstream
- **Conflict:**
  - `driver.gatewayName` (O values.yaml:205 → `OPENSHELL_GATEWAY_NAME` on the **driver** container, O _driver-env.tpl:45-48) is used only as the driver's OTel resource (O crates/openshell-driver-kyma/src/main.rs:71-79).
  - Upstream's in-process driver shares the gateway's name. For parity, default `driver.gatewayName` to the same value.
  - Changing the default from "openshell" to the fullname changes the identity of existing installs; release-note it.
- **New image surface:** none (flag/TOML exist).

#### 1.2 Gateway OTLP: `server.otlp.endpoint`, `server.otlp.serviceName`
- **U values:** `server.otlp.endpoint: ""`, `server.otlp.serviceName: ""` (values.yaml:318-323); "Empty uses openshell-gateway".
- **U renders:** `[openshell.gateway.otlp] endpoint = …, service_name = …`, only when `endpoint` is non-empty or `gatewayConfig."openshell.gateway.otlp"` is set (`_toml.tpl:162-170`). There is no flag or env.
- **Gateway accepts:** TOML only. `OtlpConfig { endpoint: String (required), service_name: Option<String> }`, `deny_unknown_fields`; "Presence of this table enables OTLP export; there is no `enabled` flag" (config_file.rs:279-294; used at cli.rs:642-660, 702-707).
- **U guards:** none. Note that upstream sets `service_name` from `serviceName` even when that is `""`, which renders `service_name = ""`.
- **U tests:** `gateway_config_test.yaml` (:266 "renders OTLP tracing configuration when configured", :276 "omits … by default", :297 "treats a null OTLP map as disabled"); `gateway_config_serializer_test.yaml`.
- **Lands in O:**
  - new `gateway.otlp.{endpoint,serviceName}` near `gateway.ocsfLog` (O values.yaml:449-465)
  - table rendered after the ocsf block (O gateway-config.yaml:99-113)
- **Conflict / interaction:**
  - Today only the **driver** exports traces (`driver.otlpEndpoint`, O values.yaml:200-204 → `OPENSHELL_OTLP_ENDPOINT`, O _driver-env.tpl:41-44).
  - The NetworkPolicy egress port comes from `driver.otlpEndpoint` only (O _helpers.tpl:214-221, networkpolicy.yaml:73-78). It must also cover the gateway endpoint.
  - Upstream has one setting covering gateway + in-process driver. Consider defaulting `driver.otlpEndpoint` from `gateway.otlp.endpoint`.
  - The O comment says the v0.1.4 exporter is plain http://; the same holds for the gateway, which uses `openshell-otel`.
- **New image surface:** TOML table (exists in source); add a `check_config` case to `scripts/check-gateway-config.sh`.

#### 1.3 `server.telemetryEnabled`
- **U values:** `server.telemetryEnabled: true` (values.yaml:349-351), "Enable anonymous OpenShell telemetry from the gateway and the sandbox supervisors it launches."
- **U renders:** env `OPENSHELL_TELEMETRY_ENABLED: {{ .Values.server.telemetryEnabled | quote }}` on the gateway container, always (`_gateway-workload.tpl:137-138`).
- **Gateway accepts:** env only; unset = true; `0|false|no|off` = false (U `crates/openshell-core/src/telemetry.rs:291-327`). The gateway image has the `telemetry` default feature (U `crates/openshell-server/Cargo.toml:119-120`).
- **U guards:** none. **U tests:** `gateway_config_test.yaml` :246, :255.
- **Lands in O:**
  - new `gateway.telemetryEnabled` (O values.yaml gateway block)
  - env on the gateway container (O deployment.yaml:103-183; the gateway container has **no `env:` block** today)
  - **also** on the driver container (O _driver-env.tpl), because the driver stamps the supervisors' value
- **Conflict:** see surprise 3. Our driver build appears to have telemetry compiled out, so the supervisors' value is always `"false"` whatever env is set. Parity on the sandbox side would need the `telemetry` feature on our `openshell-core` dependency (a Cargo change, not only a chart change).
- **New image surface:** none.

#### 1.4 `server.policyValidationFailureMode`
- **U values:** `policyValidationFailureMode: fail_closed` (values.yaml:439-441); allowed values `fail_closed` | `retain_last_valid`.
- **U renders:** TOML `[openshell.gateway] policy_validation_failure_mode = "<value>"`, always (`_toml.tpl:110-112`).
- **Gateway accepts:** TOML only, no flag or env (config_file.rs:126-128; cli.rs:572-574). The enum is in U `crates/openshell-core/src/config.rs:52-60`; default `FailClosed`.
- **U guards:** none in the chart; the gateway refuses unknown variants at parse time.
- **U tests:** `gateway_config_test.yaml` :761, :768.
- **Lands in O:** `gateway.policyValidationFailureMode` → O gateway-config.yaml `[openshell.gateway]` (:69-74). The default already matches.
- **New image surface:** TOML key; add a `check_config` case.

#### 1.5 `server.enableLoopbackServiceHttp`
- **U values:** `enableLoopbackServiceHttp: true` (values.yaml:433-435).
- **U renders:** TOML `enable_loopback_service_http = true|false`, always (`_toml.tpl:110-112`).
- **Gateway accepts:** flag `--enable-loopback-service-http <bool>` (`ArgAction::Set`), env `OPENSHELL_ENABLE_LOOPBACK_SERVICE_HTTP`, default true (cli.rs:255-262); TOML `enable_loopback_service_http` (config_file.rs:135-137).
- **U guards/tests:** none (no test file mentions it).
- **Lands in O:**
  - `gateway.enableLoopbackServiceHttp` → TOML (O gateway-config.yaml:69-74), or `--enable-loopback-service-http=<bool>` in args
  - reachable today via `gateway.extraArgs` (O values.yaml:376)
- **New image surface:** none.

#### 1.6 `server.enableWebsocketTunnel`
- **U values:** `enableWebsocketTunnel: false` (values.yaml:436-438), "Enable the WebSocket tunnel used by CLI/SDK clients behind an authenticated edge proxy."
- **U renders:** TOML `enable_websocket_tunnel`, always (`_toml.tpl:110-112`).
- **Gateway accepts:** `--enable-websocket-tunnel <bool>`, env `OPENSHELL_ENABLE_WEBSOCKET_TUNNEL`, default false (cli.rs:264-271); TOML (config_file.rs:138-140).
- **U tests:** `gateway_config_test.yaml` :16, :23; `gateway_config_serializer_test.yaml`.
- **Lands in O:** `gateway.enableWebsocketTunnel` → TOML or flag. Reachable today via extraArgs.
- **Interaction:** upstream frames the tunnel as being "behind an authenticated edge proxy". Our ingress does not authenticate (the gateway does; O values.yaml:540-544). Document whether the tunnel is useful or safe through `gatewayIngress`; the Istio VirtualService would also need WebSocket upgrade on the API host.
- **New image surface:** none.

#### 1.7 OIDC extras: `jwksTtl`, `scopesClaim`, `jwksAllowedOrigins`, `dangerouslyAllowInsecureHttp`
- **U values** (values.yaml:565-592):

  | Key | Default | Values line | Doc |
  |---|---|---|---|
  | `dangerouslyAllowInsecureHttp` | `false` | :570 | |
  | `jwksAllowedOrigins` | `[]` | :573 | "Entries must not include a path or query." |
  | `jwksTtl` | `3600` | :578 | "Must be greater than zero." |
  | `scopesClaim` | `""` | :588 | |
- **U renders:** in `[openshell.gateway.oidc]`, only when `server.oidc.issuer` is set (`_toml.tpl:146-161`).
  - `dangerously_allow_insecure_http`, `jwks_allowed_origins`, `audience` and `jwks_ttl_secs` are always set from values (:151-154). `jwks_allowed_origins = []` renders as an empty array.
  - `scopes_claim` is set only if non-empty (:158).
- **Gateway accepts:**
  - TOML `OidcConfig` (U `crates/openshell-core/src/config.rs:365-410`): `dangerously_allow_insecure_http` (default false), `jwks_allowed_origins` (Vec), `jwks_ttl_secs` (default 3600), `scopes_claim` (default "").
  - Flags (cli.rs):

    | Flag | Env | Lines | Notes |
    |---|---|---|---|
    | `--oidc-dangerously-allow-insecure-http <bool>` | `OPENSHELL_OIDC_DANGEROUSLY_ALLOW_INSECURE_HTTP` | 165-173 | ArgAction::Set |
    | `--oidc-jwks-allowed-origins a,b` | `OPENSHELL_OIDC_JWKS_ALLOWED_ORIGINS` | 175-181 | comma delimiter |
    | `--oidc-jwks-ttl` | `OPENSHELL_OIDC_JWKS_TTL` | 203-205 | default 3600 |
    | `--oidc-scopes-claim` | `OPENSHELL_OIDC_SCOPES_CLAIM` | 232-236 | default "" |
- **U guards:** none in the chart.
- **U tests:** `gateway_config_test.yaml` :283 "renders OIDC transport security settings" (dangerously + jwksAllowedOrigins); `gateway_config_serializer_test.yaml` (scopesClaim). No test for `jwksTtl`.
- **Lands in O:**
  - `gateway.oidc.{jwksTtl,scopesClaim,jwksAllowedOrigins,dangerouslyAllowInsecureHttp}` next to `rolesClaim` (O values.yaml:398-400)
  - flags inside the `{{- with .Values.gateway.oidc.issuer }}` block (O deployment.yaml:148-174), matching how O already passes the other OIDC settings
- **Conflict:** clap duplicate-flag failure for users who already set these via `gateway.extraArgs`. Our provider hook (O inference-provider-hook.yaml) needs no change.
- **New image surface:** none (flags exist); add a `check_args` render case.

#### 1.8 `server.oidc.caConfigMapName` (private OIDC issuer CA)
- **U values:** `caConfigMapName: ""` (values.yaml:589-592), "Name of a ConfigMap containing a CA certificate bundle (key: ca.crt) for verifying the OIDC issuer's TLS certificate."
- **U renders** (`_gateway-workload.tpl`), gated on `and (issuer from gatewayConfig."openshell.gateway.oidc" or server.oidc) .Values.server.oidc.caConfigMapName`:
  - env `SSL_CERT_FILE=/etc/openshell-tls/oidc-ca/ca.crt` (:129-136)
  - volumeMount `oidc-ca` → `/etc/openshell-tls/oidc-ca` readOnly (:179-183)
  - volume `configMap.name: <caConfigMapName>` with **no `items`**, so every key in the ConfigMap is projected (:280-284)
- **Gateway accepts:** a process env read by rustls/reqwest native roots, not by gateway code (upstream comment at :130-133).
- **U guards:** none. **U tests:** `gateway_config_test.yaml` :466 "mounts the OIDC CA bundle when TLS is disabled".
- **Lands in O:**
  - `gateway.oidc.caConfigMapName` (O values.yaml:382-408)
  - env on the gateway container (O deployment.yaml:103+; there is no env block yet)
  - mount after `gateway-tls` (O deployment.yaml:255-259), volume in O deployment.yaml:298-303
- **Caveats:**
  - `SSL_CERT_FILE` **replaces** the trust store for every outbound TLS connection of the gateway process (Vault, https OTLP, Kubernetes API if reqwest-based). The file must hold all the roots the gateway needs.
  - The ConfigMap lives in the release namespace.
  - Kyma issuers with public certificates do not need this.
- **New image surface:** none.

#### 1.9 `gatewayConfig` (generic TOML passthrough), missed by the prior audit
- **U values:** `gatewayConfig: { openshell: { version: 2 } }` (values.yaml:302-308). Top-level keys are TOML table names: dotted names such as `openshell.gateway`, `openshell.credential_drivers.vault` and `openshell.supervisor.middleware` (arrays of tables).
- **U renders:** the full serializer in `_toml.tpl:12-96` (key, scalar, inline table, array) and :100-364, with chart-owned fields overriding (TLS paths, `disable_tls`, bind addresses, `host_gateway_ip`, `credential_storage`, vault `ca_bundle`).
- **U guards (quoted):**
  - `"gatewayConfig must not contain an inline private key; provide it through a Secret-backed file mount"` (:27)
  - `"gatewayConfig must not contain inline URL credentials; provide them through a Secret-backed environment variable, file, or volume"` (:30)
  - `"gatewayConfig values must be strings, booleans, numbers, maps, or arrays; got %s"` (:49)
  - `"gatewayConfig must not contain database_url; provide database credentials through the chart's Secret-backed OPENSHELL_DB_URL environment variable"` (:62, :340, :355)
  - `"gatewayConfig arrays cannot contain null values"` (:78)
  - `"gatewayConfig defines %q both as a nested map and a dotted top-level table; use only the dotted top-level key"` (:315)
  - `"gatewayConfig table %q must be a map, got %s"` (:324)
  - `"gatewayConfig table %q contains an empty TOML key segment"` (:330)
  - `"gatewayConfig array-of-tables %q entry %d must be a map, got %s"` (:348)
  - `"gatewayConfig.openshell.gateway.credential_drivers must select exactly one backend or be omitted/null to use the chart default"` / `"… may select only one backend"` (:201, :204; `_helpers.tpl:612,615`)
- **U tests:** `tests/gateway_config_serializer_test.yaml`, `tests/gateway_secret_boundary_test.yaml` (:10-42), `tests/fixtures/parser-validation-values.yaml`.
- **Lands in O:** O gateway-config.yaml is hand-written TOML (:65-137). Adding a passthrough means either porting upstream's serializer or merging a restricted map.
- **Conflicts:**
  - Our `[openshell.drivers.kyma]` socket and admission tables must stay chart-owned. The gateway refuses to start unless the driver acknowledges the same admission policy (O values.yaml:154-158).
  - `openshell.drivers.kubernetes.*` has no effect here: our driver is configured by env.
  - TOML loses to the CLI flags O passes (OIDC, TLS, ports, `--server-san`).
  - O already renders `[openshell.gateway.auth]`, `[openshell.gateway.gateway_jwt]` and `[openshell.gateway.ocsf_log]`; a duplicate table is invalid TOML. Use upstream's "chart value fills only absent keys" model.
- **New image surface:** whatever the user supplies. `check-gateway-config.sh` should prove the fixture.

### Group 2: Pod / Kubernetes plumbing (10 gaps)

#### 2.1 ServiceAccount annotations (gateway SA and sandbox SA)
- **U values:** `serviceAccount.annotations: {}` (values.yaml:131-132); `sandboxServiceAccount.annotations: {}` (values.yaml:139-140).
- **U renders:** `metadata.annotations` on the gateway SA (`templates/serviceaccount.yaml:11-14`) and on the sandbox SA in the sandbox namespace (:27-30, gated on `workspaceResourcesEnabled` and `sandboxServiceAccount.create`).
- **U guards:** none. **U tests:** none assert annotations; `tests/sandbox_service_account_test.yaml` covers creation and naming only.
- **Lands in O:**
  - `serviceAccount.annotations` (O values.yaml:26-28) → O serviceaccount.yaml:4-8
  - `sandboxServiceAccount.annotations` (O values.yaml:50-52) → O sandbox-serviceaccount.yaml:17-23
- **Interaction:**
  - O's single SA serves **both** the driver and gateway containers (O deployment.yaml:41), so an annotation such as workload identity applies to both.
  - In managed mode the upstream driver creates the sandbox SA in each workspace namespace itself, without annotations (U `crates/openshell-driver-kubernetes/src/driver.rs:1260-1277`). This is the same as upstream.
  - O's sandbox SA uses a fixed name, `openshell-sandbox` (upstream: `<fullname>-sandbox`), and sets `automountServiceAccountToken: false`, which upstream does not.
- **New image surface:** none.

#### 2.2 `service.type` (and the hidden `service.nodePort`)
- **U values:** `service.type: ClusterIP` (values.yaml:194-195). `service.nodePort` is read but not declared.
- **U renders:** `spec.type: {{ .Values.service.type }}` (`templates/service.yaml:11`); `nodePort` on the grpc port when `type == NodePort` (:18-20). U also sets `appProtocol: grpc` (:17).
- **U guards/tests:** none.
- **Lands in O:** O service.yaml:9 hardcodes `type: ClusterIP`. Add `gatewayService.type` / `nodePort` (O values.yaml:530-531).
- **Interaction:**
  - The same Service carries the driver health port, gw-health, gw-metrics and `http-services` (O service.yaml:12-37). A LoadBalancer would expose all of them, so consider a separate Service.
  - A LoadBalancer bypasses the `gatewayIngress` CIDR fence and the Istio path. With `networkPolicy.enabled`, the gateway ports already admit any source (O networkpolicy.yaml:52-63).
- **New image surface:** none.

#### 2.3 `podLifecycle.terminationGracePeriodSeconds`
- **U values:** `podLifecycle.terminationGracePeriodSeconds: 30` (values.yaml:214-218); covers "supervisor session cleanup and draining queued OCSF records".
- **U renders:** `spec.terminationGracePeriodSeconds` (`_gateway-workload.tpl:36`).
- **U tests:** `gateway_config_test.yaml` :1420 "gives the gateway time to finish shutdown by default", :1427 "keeps an explicit termination grace period".
- **Lands in O:** pod spec (O deployment.yaml:40-47). The effective default today is the Kubernetes default of 30, which matches. The grace period is shared with the driver container.
- **New image surface:** none.

#### 2.4 Probe timings and `startupProbe`
- **U values** (values.yaml:263-288):

  | Probe | initialDelaySeconds | periodSeconds | timeoutSeconds | failureThreshold |
  |---|---|---|---|---|
  | startup | — | 2 | 1 | 30 |
  | liveness | 2 | 5 | 1 | 3 |
  | readiness | 1 | 2 | 1 | 3 |
- **U renders:** `startupProbe` httpGet `/healthz` port `health`; liveness `/healthz`; readiness `/readyz`, all using these values (`_gateway-workload.tpl:214-236`).
- **U tests:** none specific; `gateway_config_serializer_test.yaml` touches ports.
- **Lands in O:**
  - O gateway probes are hardcoded: liveness initialDelay 5 / period 10, readiness 2 / 5, no timeout or threshold, no startupProbe (O deployment.yaml:194-205).
  - Add `gateway.probes.{startup,liveness,readiness}`.
  - The driver probes (O deployment.yaml:60-75) are separate and stay O-owned.
- **New image surface:** none.

#### 2.5 `server.hostGatewayIP`, gateway-pod `hostAliases` only
- **U values:** `server.hostGatewayIP: ""` (values.yaml:398-402).
- **U renders:**
  - pod `hostAliases: [{ip, hostnames: [host.docker.internal, host.openshell.internal]}]` (`_gateway-workload.tpl:42-48`)
  - TOML `[openshell.drivers.kubernetes] host_gateway_ip` (chart-owned, `_toml.tpl:247-255`; `_helpers.tpl:531`)
- **U tests:** `gateway_pod_security_context_test.yaml` :38 "derives host aliases from server.hostGatewayIP and not gatewayConfig"; `gateway_config_test.yaml`.
- **O today:** the sandbox side is covered by `driver.hostGatewayIp` → `OPENSHELL_HOST_GATEWAY_IP` (O values.yaml:214, _driver-env.tpl:90-93). Missing: pod `hostAliases` in O deployment.yaml:40-47, derived from the same value. It applies to both containers, since they share one pod.
- **Class note:** low value on Kyma, where there is no Docker host.
- **New image surface:** none.

#### 2.6 `server.externalDbSecret`
- **U values:** `externalDbSecret: ""` (values.yaml:359-363), "Opaque Secret containing a PostgreSQL connection URI (key: uri)"; `dbUrl: "sqlite:/var/openshell/openshell.db"` (:355-358).
- **U renders:**
  - With externalDbSecret: env `OPENSHELL_DB_URL` from `secretKeyRef {name: externalDbSecret, key: uri}` (`_gateway-workload.tpl:118-124`), and **no** `--db-url` arg (:62-65 add `--db-url <dbUrl>` only when externalDbSecret is unset).
  - Also enables `workload.kind=deployment` and HA (not applicable here).
- **Gateway accepts:** `--db-url` / env `OPENSHELL_DB_URL` (cli.rs:123-129). The TOML `database_url` is rejected (config_file.rs:177-178).
- **U guards (quoted):**
  - validateSecretReference (`_helpers.tpl:443-457`, called at :602): `"server.externalDbSecret must be a Kubernetes Secret name, got %s"`, `"… must be no more than 253 characters"`, `"… must be a valid Kubernetes Secret name"`
  - `"workload.kind=deployment requires server.externalDbSecret; use workload.kind=statefulset for the default SQLite database."` (:585)
  - `"postgres.enabled was removed; …"` (:576)
- **U tests:** `gateway_config_test.yaml` :1222 "does not pass --db-url in args when externalDbSecret is set", :1231 "references externalDbSecret when set"; `gateway_secret_boundary_test.yaml` :50, :59; `autoscaling_test.yaml`, `credential_drivers_test.yaml` :277/:295, `replica_routing_test.yaml`, `gateway_upstream_proxy_ca_test.yaml`.
- **Lands in O:**
  - `gateway.dbPersistence.externalDbSecret` (O values.yaml:489-493)
  - O deployment.yaml:117-123: when it is set, omit `--db-url` (a CLI flag beats env, so both must never render) and add an env with secretKeyRef
  - O gateway-db-pvc.yaml:1 must also skip the PVC
- **Conflict:**
  - Our `gateway.dbPersistence.dbUrl` puts the full URL, including the password, in pod args and Helm release values (O values.yaml:491 example `postgresql://user:pass@…`).
  - Guard against `dbUrl` and `externalDbSecret` both being set.
  - NetworkPolicy egress to Postgres is not opened (O networkpolicy.yaml:64-82); needs `extraEgress`.
- **New image surface:** none.

#### 2.7 `server.tls.clientCaSecretName`
- **U values:** `clientCaSecretName: openshell-server-client-ca` (values.yaml:523-526), "Set to "" to disable client certificate verification for HTTPS-only mode"; `enableMtls: true` (:518-522).
- **U renders** (when TLS is on and `openshell.gatewayClientCaEnabled` is true, `_helpers.tpl:225-232`; false when disableTls, when not enableMtls, or when `clientCaSecretName == ""`):
  - TOML `[openshell.gateway.tls] client_ca_path = "/etc/openshell-tls/client-ca/ca.crt"` (`_toml.tpl:291-295`)
  - volumeMount `tls-client-ca` → `/etc/openshell-tls/client-ca` (`_gateway-workload.tpl:174-176`)
  - volume `tls-client-ca` (:268-277). Source is `server.tls.certSecretName` items `ca.crt` when `(pkiInitJob.enabled and not certManager.enabled) or (certManager.enabled and certManager.clientCaFromServerTlsSecret)`, **otherwise** the Secret `clientCaSecretName`.
  - HA extra: `peer-client-tls` mount (c).
- **U guards (quoted):**
  - `"server.tls.clientCaSecretName cannot be null; omit the key to use the chart default (openshell-server-client-ca), or set to \"\" to disable client certificate verification for HTTPS-only mode"` (`_helpers.tpl:624-626`)
  - `"certManager.clientCaFromServerTlsSecret is false but server.tls.clientCaSecretName is still the default (openshell-server-client-ca), which nothing creates when cert-manager owns TLS. …"` (`cert-manager-pki.yaml:45-47`)
- **U tests:** `statefulset_client_ca_test.yaml` (all 7 cases :13-118); `gateway_config_test.yaml` :856-941, :993; `cert_manager_pki_test.yaml` :145.
- **Lands in O:**
  - O passes `--tls-client-ca /etc/openshell-tls/server/ca.crt` (server-Secret CA) when `gateway.tls.clientCa.enabled` (O deployment.yaml:141-144; values.yaml:436-439). That equals upstream's built-in PKI path.
  - Add `gateway.tls.clientCa.secretName` (empty = server Secret ca.crt): a separate volume mount plus a flag path.
- **Interactions:** surprise 4 (without OIDC, the client CA authenticates nobody because O sets `allow_unauthenticated_users=true`); gap 4 (needed for cert-manager with `clientCaFromServerTlsSecret: false`).
- **New image surface:** none.

#### 2.8 `pkiInitJob.serverDnsNames` / `serverIpAddresses`
- **U values:** `serverDnsNames: []` (values.yaml:627-628), `serverIpAddresses: []` (:629-630). "Wildcard DNS SANs also enable sandbox service URLs under that domain" (:619-621).
- **U renders:**
  - In the certgen hook (full PKI mode only, `pkiInitJob.enabled and not certManager.enabled`), `--server-san=` for each default (`_helpers.tpl:369-381`: `<fullname>`, `<fullname>.<ns>.svc`, `<fullname>.<ns>.svc.cluster.local`, `localhost`, `<fullname>.localhost`, `*.<fullname>.localhost`, `host.docker.internal`, `host.containers.internal`), then `--server-san=127.0.0.1`, then each serverDnsNames entry, then each serverIpAddresses entry (`certgen.yaml:110-121`).
  - **And** runtime TOML `[openshell.gateway] server_sans = <serverDnsNames>` (certManager.serverDnsNames when certManager.enabled), only if non-empty and not set in gatewayConfig (`_toml.tpl:114-118`).
- **U tests:** `certgen_test.yaml` (:12, :77), `gateway_config_test.yaml` :835 "omits server_sans…", :962, :975 "preserves pkiInitJob serverDnsNames as the runtime SAN fallback".
- **Lands in O:**
  - new `gateway.sandboxJwt.serverDnsNames` / `serverIpAddresses` (O values.yaml:511-522)
  - appended in O gateway-jwt-pki-hook.yaml:132-138 (O's own SAN list: `<svc>`, `<svc>.<ns>`, `<svc>.<ns>.svc`, `<svc>.<ns>.svc.cluster.local`, localhost, 127.0.0.1)
  - runtime SANs merged into the existing `--server-san *.<domain>` flag (O deployment.yaml:175-180)
- **Conflict:**
  - Runtime SANs are passed as a CLI flag (`--server-san`, cli.rs:246-253, comma-delimited, repeatable). A TOML `server_sans` would be **overridden entirely** whenever serviceHosts is on, so render both from one merged list.
  - The hook never rewrites an existing Secret (certgen `decide_k8s` SkipExists, U `crates/openshell-server/src/certgen.rs:147-153`). New SANs apply only after the three PKI Secrets are deleted; same caveat as O values.yaml:424-427.
- **New image surface:** none.

#### 2.9 `server.sandboxJwt.secretDefaultMode` (missed)
- **U values:** `secretDefaultMode: ""` (values.yaml:549-552), "Default 0400 … Override to 0440 or 0444 if the container UID does not match the volume file owner."
- **U renders:** `sandbox-jwt` volume `defaultMode: {{ .Values.server.sandboxJwt.secretDefaultMode | default 0400 }}` (`_gateway-workload.tpl:243-246`).
- **U tests:** `gateway_config_test.yaml` :1279 (asserts defaultMode 256).
- **Lands in O:** O hardcodes `defaultMode: 0o400` (O deployment.yaml:292-297; also gateway-tls :298-303). Add `gateway.sandboxJwt.secretDefaultMode`.
- **New image surface:** none.

#### 2.10 `rbac.create` (missed)
- **U values:** `rbac.create: true` (values.yaml:147-152): "Disable to supply the namespaced sandbox and peer Role/RoleBinding and the cluster-scoped ClusterRole/ClusterRoleBinding out of band."
- **U renders:** gates role, rolebinding, peer-role, clusterrole and clusterrolebinding (`_helpers.tpl:113-148`).
- **U tests:** `rbac_test.yaml`, `clusterrole_test.yaml` :192 "omits the ClusterRole when all chart-managed RBAC is disabled".
- **Lands in O:**
  - O has only `rbac.clusterScoped.create` (O values.yaml:39-43)
  - the sandbox-namespace Role always renders in shared mode (O role.yaml:1-9 comments)
  - add `rbac.create` gating role.yaml, rolebinding.yaml, workspace-secret-source-role(binding).yaml and the cluster pair
- **New image surface:** none.

### Group 3: Credential storage and drivers (4 gaps)

#### 3.1 Default credential storage KEK (`server.credentialStorage.existingSecret` and the KEK Secret it replaces)
- **U values:** `credentialStorage.existingSecret: ""` (values.yaml:453-464). "The Secret must contain a key named "key-encryption-key" with a base64-encoded 32-byte value. Required for GitOps workflows that render manifests with `helm template` (where `lookup` is unavailable)."
- **U renders**, when no external credential driver is enabled:
  1. **Secret** `<fullname>-credential-storage-key-encryption-key` (`_helpers.tpl:316-322`), key `key-encryption-key` (:327-329), `type: Opaque`, annotation `helm.sh/resource-policy: keep`, value `randBytes 32 | b64enc`. Reused via `lookup` when present (`templates/credential-storage-key-encryption-key-secret.yaml:3-29`). Not rendered when `existingSecret` is set.
  2. **Env** `OPENSHELL_GATEWAY_CREDENTIAL_KEY_ENCRYPTION_KEY` (`_helpers.tpl:334-336`) from `secretKeyRef {name: existingSecret || generated, key: key-encryption-key}` (`_gateway-workload.tpl:111-117`). The env is not rendered when an external credential driver is selected.
  3. **TOML** `[openshell.gateway.credential_storage] key_encryption_key_env = "OPENSHELL_GATEWAY_CREDENTIAL_KEY_ENCRYPTION_KEY"` (`_toml.tpl:240-246`). Unset when any credential driver is selected.
- **Gateway accepts:**
  - `[openshell.gateway.credential_storage]` with either `key_encryption_key_path` or `key_encryption_key_env` (U credstore lib.rs:119-124, 445-472). Errors:
    - `"[openshell.gateway.credential_storage] set only one of key_encryption_key_path or key_encryption_key_env"`
    - `"… environment variable '{env_name}' is not set"`
    - `"key_encryption_key_env value must decode to exactly 32 bytes"`
  - Without the table it uses the file default (surprise 1).
- **U guards (quoted):**
  - `"existing credential storage key-encryption key Secret %s/%s is missing key %s"` (KEK template :12)
  - validateSecretReference messages for `server.credentialStorage.existingSecret` (`_helpers.tpl:603`)
- **U tests:** `credential_drivers_test.yaml` :17 "renders default encrypted credential storage by default", :30 "creates a retained default credential storage key-encryption key Secret by default", :46 "injects the default credential storage key-encryption key Secret into the gateway pod by default", :277, :295; `gateway_secret_boundary_test.yaml`.
- **Lands in O:**
  - new `gateway.credentialStorage.existingSecret`
  - new template `credential-storage-kek-secret.yaml` (gated on `gateway.enabled`)
  - env on the gateway container (O deployment.yaml:103+)
  - TOML table in O gateway-config.yaml after `[openshell.gateway.auth]` (:76-88)
- **Conflict/migration:**
  - Existing installs with a persisted DB hold credentials encrypted under a KEK that is lost at every restart. Switching to a Secret KEK changes the key id, so stored provider credentials must be re-created; the chart's provider hook does this on `helm upgrade`.
  - `lookup` is unavailable under `helm template`, which is what check-chart-render uses. A random key would be regenerated each render; expected, matching upstream.
- **New image surface:** TOML table and env (exist in source). Add a `check_config` case with the env set.

#### 3.2 `server.credentialDrivers.kubernetesSecrets.*`
- **U values** (values.yaml:470-486):

  | Key | Default | Doc |
  |---|---|---|
  | `enabled` | `false` | "WARNING: The RBAC Role grants read/write access to ALL Secrets in the configured namespace." |
  | `namespace` | `""` | |
  | `createNamespace` | `false` | |
  | `rbac.create` | `true` | |
- **U renders** when enabled (or when `gatewayConfig."openshell.gateway".credential_drivers` contains `kubernetes-secrets`, `_helpers.tpl:296-309`):
  - TOML `[openshell.gateway] credential_drivers = ["kubernetes-secrets"]` (`_toml.tpl:211-217`)
  - TOML `[openshell.credential_drivers.kubernetes-secrets] namespace = <ns>` (:220-226; ns from `_helpers.tpl:288-293`, default the release ns)
  - no `credential_storage` table and no KEK env/Secret (:240-246; KEK template :3; workload :111)
  - **Role** `<fullname>-credential-secrets` in that ns: secrets get/create/patch/delete (`templates/credential-secrets-role.yaml:1-33`)
  - **RoleBinding** to the gateway SA (`credential-secrets-rolebinding.yaml:1-25`)
  - optional **Namespace** with `helm.sh/resource-policy: keep`, adopted only when not owned by another release (`credential-secrets-namespace.yaml:4-27`)
- **Gateway accepts:** TOML `KubernetesSecretsDriverConfig { namespace }`, `deny_unknown_fields` (U `crates/openshell-driver-kubernetes-secrets/src/lib.rs:74-78`); in-cluster `Client::try_default()`. Compiled unconditionally into the gateway (U openshell-server Cargo.toml:17).
- **U guards (quoted):**
  - `"only one external server.credentialDrivers backend can be enabled at a time"` (`_toml.tpl:209`)
  - `"server.credentialDrivers.kubernetesSecrets.createNamespace requires server.credentialDrivers.kubernetesSecrets.namespace to name a namespace other than the release namespace"` (namespace template :8)
  - `"gatewayConfig.openshell.gateway.credential_drivers may select only one backend"` / `"… must select exactly one backend or be omitted/null to use the chart default"`
- **U tests:** `credential_drivers_test.yaml` :58, :83, :96, :160-183, :218, :243, :259, :268; `credential_secrets_namespace_test.yaml` (all); `clusterrole_test.yaml` :97-135 (no Secret access leaks into the ClusterRole); `gateway_config_test.yaml`.
- **Lands in O:**
  - `gateway.credentialDrivers.kubernetesSecrets.*`
  - TOML in O gateway-config.yaml
  - new templates for the Role, RoleBinding and Namespace, binding O's single SA (O _helpers.tpl:47-53)
- **Conflict:**
  - That SA is shared with the **driver** container, so the driver also gains read/write on every Secret in that namespace. Upstream's gateway and driver share a process anyway, so the effective privilege is the same.
  - If the namespace equals the sandbox namespace (`.Values.namespace`), sandbox bootstrap Secrets sit next to provider Secrets. Recommend a dedicated namespace.
  - `scripts/check-chart-render.sh` asserts RBAC rule-for-rule (O role.yaml:5-6); extend it.
- **New image surface:** TOML (exists in source).

#### 3.3 `server.credentialDrivers.vault.*` and top-level `credentialDrivers.vault.caConfigMapName`
- **U values** (values.yaml:487-509), all under `server.credentialDrivers.vault`:

  | Key | Default | Doc |
  |---|---|---|
  | `enabled` | `false` | |
  | `address` | `""` | "Non-loopback endpoints must use HTTPS" |
  | `caConfigMapName` | `""` | legacy location |
  | `mount` | `secret` | |
  | `kvVersion` | `"2"` | |
  | `authMethod` | `kubernetes` | |
  | `role` | `""` | |
  | `kubernetesAuthMount` | `kubernetes` | |
  | `serviceAccountTokenPath` | `/var/run/secrets/kubernetes.io/serviceaccount/token` | |
  | `tokenPath` | `""` | |
  | `timeoutSecs` | `""` | |

  Plus the top-level `credentialDrivers.vault.caConfigMapName: ""` (values.yaml:594-600), the preferred location.
- **U renders:**
  - TOML `credential_drivers = ["vault"]` (`_toml.tpl:214-215`)
  - `[openshell.credential_drivers.vault]`: `address`, `auth_method` and `role` always (:229-231); `mount`, `kv_version`, `kubernetes_auth_mount`, `service_account_token_path`, `token_path` and `timeout_secs` only if truthy (:232-234)
  - `ca_bundle = "/etc/openshell-tls/vault-ca/ca.crt"` only when Vault is selected and a CA ConfigMap is named; any user `ca_bundle` is removed (:259-270)
  - volume `vault-ca` configMap `items: [{key: ca.crt, path: ca.crt}]` mounted at `/etc/openshell-tls/vault-ca` (`_gateway-workload.tpl:184-188, 285-292`)
  - no KEK env/Secret/table
- **Gateway accepts:** TOML `VaultDriverConfig { address, ca_bundle, mount, kv_version, auth_method, role, kubernetes_auth_mount, service_account_token_path, token_path, timeout_secs (u64) }`, `deny_unknown_fields` (U `crates/openshell-driver-vault/src/lib.rs:85-97`).
  - Upstream renders `timeoutSecs` as given. A string such as `"30"` would serialize quoted and be rejected as a u64; render it with `int`.
- **U guards:** the same "only one … backend" messages as 3.2.
- **U tests:** `credential_drivers_test.yaml` :121 "renders Vault credential driver config", :142, :194 "mounts the Vault CA ConfigMap into the gateway"; `ci/values-credential-driver-vault.yaml`.
- **Lands in O:**
  - `gateway.credentialDrivers.vault.*`
  - TOML in O gateway-config.yaml
  - mount and volume in O deployment.yaml:255-262 / 298-306
- **Interaction:**
  - Kubernetes auth uses the shared SA token (automounted). The Vault role binds O's SA name, which is also the driver's identity.
  - Vault on 8200 needs NetworkPolicy egress (O networkpolicy.yaml:64-82).
  - If 1.8's `SSL_CERT_FILE` is also set, the Vault CA must be in that bundle too, or `ca_bundle` handles it per driver. Verify which one wins in reqwest.
- **New image surface:** TOML (exists in source).

#### 3.4 `server.providerTokenGrants.spiffe.*`, gateway side
- **U values:** `spiffe.enabled: false`, `spiffe.workloadApiSocketPath: /spiffe-workload-api/spire-agent.sock` (values.yaml:553-562).
- **U renders** (when enabled; path from `effectiveKubernetesConfig.provider_spiffe_workload_api_socket_path`, `_helpers.tpl:554-557`):
  - TOML `[openshell.drivers.kubernetes] provider_spiffe_workload_api_socket_path` (driver side)
  - gateway env `OPENSHELL_GATEWAY_SPIFFE_WORKLOAD_API_SOCKET=<path>` (`_gateway-workload.tpl:139-142`)
  - volumeMount `spiffe-workload-api` → `dir(path)` readOnly (:194-198)
  - volume `csi: {driver: csi.spiffe.io, readOnly: true}` (:301-306)
- **Gateway accepts:** env `OPENSHELL_GATEWAY_SPIFFE_WORKLOAD_API_SOCKET`. When unset, token exchange fails with `"{…} is required for provider token exchange"` / `"… is required for supervisor JWT-SVID validation"` (U `crates/openshell-server/src/grpc/provider.rs:44, 4403-4408, 4469-4474`).
- **U tests:** `gateway_config_test.yaml` :1264, :1279; `ci/values-spire.yaml`, `ci/values-spire-stack.yaml`.
- **O today:** driver side only: `driver.providerSpiffeWorkloadApiSocket` → `OPENSHELL_PROVIDER_SPIFFE_WORKLOAD_API_SOCKET` (O values.yaml:215, _driver-env.tpl:134-137).
- **Lands in O:**
  - add `gateway.providerTokenGrants.spiffe.{enabled,workloadApiSocketPath}`, or derive from `driver.providerSpiffeWorkloadApiSocket` (one value, as upstream)
  - env, mount and CSI volume on the gateway container (O deployment.yaml)
- **Interaction:** the CSI volume type is allowed under PSS restricted. It requires the SPIFFE CSI driver on the cluster, which is not on Kyma by default.
- **New image surface:** none.

### Group 4: `certManager.*` (1 gap; sub-items below)

#### 4.1 Upstream values (values.yaml:649-690)

| Key | Default | Values line |
|---|---|---|
| `certManager.enabled` | `false` | :655 |
| `certManager.caSecretName` | `openshell-ca-tls` | :657 |
| `certManager.serverIssuerRef` | `{ name: "", kind: "", group: "" }` | :664-667 |
| `certManager.clientCaFromServerTlsSecret` | `true` | :674 |
| `certManager.certificateDuration` | `8760h` | :676 |
| `certManager.certificateRenewBefore` | `720h` | :678 |
| `certManager.serverDnsNames` | `[openshell, openshell.openshell.svc, openshell.openshell.svc.cluster.local, localhost, openshell.localhost, "*.openshell.localhost", host.docker.internal]` | :680-687 |
| `certManager.serverIpAddresses` | `[127.0.0.1]` | :689-690 |

Related: `pkiInitJob.timeoutSeconds: 120` (:638), `pkiInitJob.failOnTimeout: true` (:647); `server.tls.certSecretName: openshell-server-tls` (:517), `clientTlsSecretName: openshell-client-tls` (:528), `clientCaSecretName` (:526).

#### 4.2 Resources upstream creates (`templates/cert-manager-pki.yaml`, all `cert-manager.io/v1`, release namespace)

| # | Kind / name | Spec | Lines |
|---|---|---|---|
| 1 | Issuer `<fullname>-selfsigned` (`_helpers.tpl:250-252`) | `selfSigned: {}` | :4-12 |
| 2 | Certificate `<fullname>-ca` | `isCA: true`, `commonName: openshell-ca`, `secretName: certManager.caSecretName`, ECDSA 256, issuerRef selfsigned Issuer. **No `duration`/`renewBefore`**, so cert-manager's default (90d, renew at 2/3) applies. | :14-31 |
| 3 | Issuer `<fullname>-ca-issuer` | `ca.secretName: certManager.caSecretName` | :33-42 |
| 4 | Certificate `<fullname>-server` (internal) | `secretName: server.tls.certSecretName`, `duration`/`renewBefore` from values, `commonName: <fullname>`, `dnsNames` = defaultServerDnsNames (8 names, `_helpers.tpl:369-381`) + `certManager.serverDnsNames` **unless** serverIssuerRef is set, `ipAddresses: serverIpAddresses`, ECDSA 256, usages `server auth, digital signature, key encipherment`, issuerRef `<fullname>-ca-issuer` | :59-97 |
| 5 | (only with `serverIssuerRef.name`) Certificate `<fullname>-server-external` | `secretName: <fullname>-server-external-tls`, `commonName: first serverDnsNames`, `dnsNames: serverDnsNames`, usages as #4, issuerRef `{name, kind \| default "Issuer", group \| default "cert-manager.io"}` | :98-132 |
| 6 | Certificate `<fullname>-client` | `secretName: server.tls.clientTlsSecretName`, duration/renewBefore, `commonName: openshell-client`, ECDSA 256, usages `client auth, digital signature, key encipherment`, issuerRef ca-issuer | :133-156 |

Guards (quoted):
- `"certManager.clientCaFromServerTlsSecret is false but server.tls.clientCaSecretName is still the default (openshell-server-client-ca), which nothing creates when cert-manager owns TLS. Set server.tls.clientCaSecretName to the secret containing the client CA (e.g. the value of certManager.caSecretName, which defaults to openshell-ca-tls), or set it to empty to disable mTLS client verification."` (:45-46)
- `"certManager.serverIssuerRef.name is set but certManager.serverDnsNames is empty — the external certificate requires at least one externally-resolvable DNS name."` (:50)
- `"certManager.serverIssuerRef.name is set (external issuer) but certManager.serverDnsNames contains %q — external CAs (e.g. ACME / Let's Encrypt) reject internal-only names per CA/Browser Forum baseline requirements. Override certManager.serverDnsNames with your externally-resolvable hostname(s)."` (:55)
- `"certManager.serverIssuerRef.name is set but certManager.enabled is false — the external server certificate, its Secret mount, and the gateway TLS configuration all require cert-manager to be enabled. Set certManager.enabled=true or remove certManager.serverIssuerRef.name."` (`_helpers.tpl:578-580`)

#### 4.3 How the upstream gateway pod consumes them (`_gateway-workload.tpl`)

| Volume | Source | Mount | Lines |
|---|---|---|---|
| `tls-cert` | Secret `server.tls.certSecretName` (tls.crt/tls.key/ca.crt) | `/etc/openshell-tls/server` | :162-164, :256-258 |
| `tls-external-cert` | Secret `<fullname>-server-external-tls` (serverIssuerRef only) | `/etc/openshell-tls/server-external` | :165-169, :259-263 |
| `tls-client-ca` | the server Secret's `ca.crt` (clientCaFromServerTlsSecret=true), else Secret `clientCaSecretName` | `/etc/openshell-tls/client-ca` | :174-176, :268-277 |

- TOML `[openshell.gateway.tls]` (`_toml.tpl:288-305`): `cert_path=/etc/openshell-tls/server/tls.crt`, `key_path=…/tls.key`, `client_ca_path=/etc/openshell-tls/client-ca/ca.crt` (when client CA is enabled). With serverIssuerRef also `external_cert_path`, `external_key_path` and `external_server_names = certManager.serverDnsNames`.
- TOML `[openshell.gateway] server_sans = certManager.serverDnsNames` (`_toml.tpl:115-117`).
- `OPENSHELL_PEER_TLS_CA_FILE=/etc/openshell-tls/server/ca.crt` (HA, :100-103).
- Sandboxes receive `server.tls.clientTlsSecretName` (the cert-manager client Secret, with `ca.crt`) via `[openshell.drivers.kubernetes] client_tls_secret_name` (`_toml.tpl:282-286`), so the CA in that Secret's `ca.crt` is what supervisors trust.

#### 4.4 certgen when `certManager.enabled` (`templates/certgen.yaml`)
- **Hook** SA, Role and RoleBinding at pre-install/pre-upgrade weight -30.
  - Role: secrets get/create, plus configmaps get/create/update only with `grpcRoute.backendTLSPolicy.enabled` (:30-38).
- **Job** `<fullname>-certgen` at weight -20, `activeDeadlineSeconds: timeoutSeconds+30`, `command: /usr/local/bin/openshell-gateway`, args:
  - `generate-certs --jwt-only --jwt-secret-name=<sandboxJwtSecretName>`
  - no server/client Secret names, no `--server-san`
  - no `--backend-ca-configmap-name` in the pre-hook (:103-109, :110, :122)
- **Second Job** `<fullname>-certgen-backend-ca` at **post-install/post-upgrade** weight 0, only when certManager and backendTLSPolicy are both on (:125-182). Args: `generate-certs --jwt-only --jwt-secret-name=… --backend-ca-configmap-name=<backendCaConfigMapName> --backend-ca-source-secret=<server.tls.certSecretName> --backend-ca-poll-timeout-seconds=<pkiInitJob.timeoutSeconds>` plus `--backend-ca-fail-on-timeout` if failOnTimeout.
- **Source** (U `crates/openshell-server/src/certgen.rs`):
  - `--jwt-only` "Create only the sandbox-JWT signing-key Secret … used when another controller owns TLS Secret provisioning" (:67-70)
  - `--backend-ca-source-secret` `requires = backend_ca_configmap_name` (:89-94)
  - poll interval 2s, default timeout 90 (:96-100, :362-363)
  - ConfigMap created, or **replaced when `ca.crt` differs** (:430-470)
  - the CA is read from the source Secret's `ca.crt`; error `"secret {name} has no ca.crt key"` (:329-336)
- **U tests:** `cert_manager_pki_test.yaml` (7 cases), `certgen_test.yaml` :38 "renders JWT-only certgen hook when cert-manager owns TLS", :77 "…even if pkiInitJob remains enabled", :133; `statefulset_client_ca_test.yaml` :29, :50, :87, :118; `gateway_config_test.yaml` :921, :941, :962, :1316; `route_test.yaml`; `ci/values-cert-manager.yaml` (`server.disableTls: false`, `certManager.enabled: true`).

#### 4.5 How O does it today: `templates/gateway-jwt-pki-hook.yaml`
- Gated on `gateway.enabled and gateway.sandboxJwt.enabled` (:1).
- SA, Role and RoleBinding at pre-install/pre-upgrade weight -30.
  - Role: secrets get/create (:44-47), plus configmaps get/create/update when `gatewayIngress.enabled` (:48-54).
- Job weight -20, `activeDeadlineSeconds: 120` (fixed, :89), pod runs as 65532, image = pinned gateway, args via ENTRYPOINT (:123-144):
  - `generate-certs --namespace=$(POD_NAMESPACE) --server-secret-name=<fullname>-server-tls --client-secret-name=<fullname>-client-tls --jwt-secret-name=<fullname>-jwt-keys`
  - (names from O _helpers.tpl:110-126, overridable via `gateway.sandboxJwt.{serverTlsSecretName,clientTlsSecretName,jwtSecretName}`)
  - SANs `<svc>`, `<svc>.<ns>`, `<svc>.<ns>.svc`, `<svc>.<ns>.svc.cluster.local`, `localhost`, `127.0.0.1`
  - with `gatewayIngress.enabled`, `--backend-ca-configmap-name=<fullname>-gateway-ca` (O _gateway-ingress.tpl:30-32)
- In full mode, certgen generates one in-memory CA (validity is certgen's own, never rotated) and writes server and client `kubernetes.io/tls` Secrets, each with `ca.crt`. It reads the CA for the ConfigMap from the server Secret and updates the ConfigMap on every run when it differs.
- **Consumers:**
  - the gateway mounts `<fullname>-server-tls` at `/etc/openshell-tls/server` (O deployment.yaml:255-259, 298-303) with `--tls-cert/--tls-key` and optional `--tls-client-ca …/server/ca.crt` (O deployment.yaml:136-144)
  - the driver hands `<fullname>-client-tls` to sandboxes (O _helpers.tpl:162-168 → `OPENSHELL_CLIENT_TLS_SECRET_NAME`)
  - Istio `DestinationRule <fullname>-gateway-tls` (O gateway-destinationrule.yaml:10-30): `tls.mode: SIMPLE`, `credentialName: "configmap://<ns>/<fullname>-gateway-ca"` (:27), `sni` and `subjectAltNames` = `<svc>.<ns>.svc.cluster.local`, `exportTo: [ingressNamespace]`

#### 4.6 What a cert-manager variant would need in O
- Values: `gateway.certManager.{enabled, caSecretName, clientCaFromServerTlsSecret, certificateDuration, certificateRenewBefore, serverDnsNames, serverIpAddresses}`. `serverIssuerRef` is (c), see surprise 6.
- The new template renders Issuer, CA Certificate, CA Issuer, server Certificate and client Certificate, targeting the **existing** O Secret names (`serverTlsSecretName`, `clientTlsSecretName`) so the gateway mounts and the driver env stay unchanged.
  - Use O's own SAN set (incl. `<svc>.<ns>`), not upstream's `openshell.openshell.*` default list. Upstream's `certManager.serverDnsNames` default is release-specific to "openshell/openshell".
- PKI hook: in cert-manager mode, switch to `--jwt-only --jwt-secret-name=…`.
  - In full mode, the pre-install hook would otherwise create the server/client Secrets first. cert-manager would then take over and reissue them under its own CA; the outcome is the same but a CA flip happens.
  - certgen's `PartialState` refuses mixed existence (`decide_k8s`, certgen.rs:147-153). Not hit in jwt-only mode.
- **CA ConfigMap for the Istio DR:** the pre-install hook cannot read a cert-manager Secret that does not exist yet. A post-install/post-upgrade Job like upstream's `-backend-ca` is needed: `--jwt-only --jwt-secret-name … --backend-ca-configmap-name=<fullname>-gateway-ca --backend-ca-source-secret=<serverTlsSecretName> --backend-ca-poll-timeout-seconds=<timeout> [--backend-ca-fail-on-timeout]`.
  - Port `pkiInitJob.timeoutSeconds` / `failOnTimeout`.
  - The Role needs configmaps get/create/update. The Job's `activeDeadlineSeconds` = timeout+30.
- **Hazard (also upstream):** the ConfigMap is refreshed only by hook runs. When cert-manager renews the CA (90d default because the CA has no duration), the server certificate is re-signed by the new CA, but `<fullname>-gateway-ca` keeps the old CA until the next `helm upgrade`, so the ingress's verification breaks. Options:
  - a long explicit CA duration
  - a periodic CronJob running the same `generate-certs` args
  - a trust-manager Bundle → ConfigMap, if trust-manager is installed
  - Istio `credentialName` pointing at a Secret is not an option: it must be in the ingress gateway's namespace, which the chart deliberately does not write to (O values.yaml:546-551)
- Sandboxes trust `ca.crt` from the client Secret, which cert-manager refreshes on renewal. Running supervisors keep their mounted copy; verify the behaviour across CA rotation.
- `--tls-client-ca` stays `/etc/openshell-tls/server/ca.crt` when the client CA comes from the server Secret; otherwise a separate mount (gap 2.7).
- New image surface: none (`generate-certs --jwt-only`, `--backend-ca-*` exist in source). `check-gateway-config.sh` already proves the PKI-hook args; add the jwt-only and backend-ca Job renders.

#### 4.7 Gardener (`cert.gardener.cloud/v1alpha1`) variant: differences
- **Issuers:**
  - selfSigned Issuer: `spec.selfSigned: {}`
  - CA Issuer: `spec.ca.privateKeySecretRef: {name, namespace}` instead of cert-manager's `ca.secretName`. The namespace is explicit.
- **Certificates:** `issuerRef: {name, namespace}`; there is no `kind`/`group`.
  - CA: `isCA: true` with issuerRef → self-signed Issuer, `secretName` (the CA secret that the CA Issuer's `privateKeySecretRef` names).
  - Leaves: `dnsNames`, `ipAddresses`, `usages`, `duration`, `renewBefore`, `secretName`.
- **Lifetime:** Gardener **refuses** a leaf whose lifetime exceeds the CA's, whereas cert-manager truncates. Upstream's CA has **no duration** while the leaves default to `8760h`, a combination that fails on Gardener. The variant must:
  - set an explicit CA `duration` ≥ the leaf `certificateDuration` (+ the renewal window)
  - add a chart guard (e.g. CA duration must be ≥ certificateDuration; fail message to write), and refuse leaves longer than the CA
  - plan the CA renewal: a re-issued CA will not re-sign existing leaves until they renew, and the DR ConfigMap hazard in 4.6 applies
- **Usages:** check that Gardener's `usages` vocabulary accepts the upstream strings (`server auth`, `client auth`, `digital signature`, `key encipherment`); verify against the cluster's CRD schema (`kubectl explain`, not run here).
- **Private key:** upstream sets `privateKey: {algorithm: ECDSA, size: 256}`; verify Gardener's field names. The given field list does not include `privateKey`.
- **Secret content:** **verify** that Gardener writes `ca.crt` into leaf Secrets for CA-issuer certificates. O depends on `ca.crt` in three places:
  - `--tls-client-ca …/server/ca.crt`
  - sandboxes trusting the client Secret's `ca.crt`
  - the `--backend-ca-source-secret` → DR ConfigMap path (certgen errors `"secret {name} has no ca.crt key"`)

  If Gardener does not write it, the CA must be taken from the CA Secret (`tls.crt`) instead, which needs a different ConfigMap source (certgen reads only `ca.crt`).
- **Shoot issuers:** Gardener honours namespaced Issuers in the shoot only when the shoot-cert-service extension has `shootIssuers.enabled`. Verify on Kyma; not checked here.
- **Watch-out:** Gardener's `commonName` limit is 64 chars, same as X.509. `<fullname>` is ≤ 63, so it is fine.

---

## Class (b) / (c): every other upstream values key

Values line numbers refer to U `deploy/helm/openshell/values.yaml` @ v0.1.4.

| Upstream key (values line) | Class | Where in O / reason |
|---|---|---|
| `replicaCount` (8) | c | Single-replica Deployment by design; driver sidecar over UDS (O deployment.yaml:18). |
| `global.image.{registry,tag,pullPolicy}` (10-17) | c | O pins each image independently by digest; there is no shared registry/tag. |
| `workload.kind`, `workload.allowMultiReplicaStatefulSet` (19-28) | c | O is always a Deployment (`strategy: Recreate`); persistence via `gateway.dbPersistence` PVC. |
| `gateway.image.{registry,repository,pullPolicy,tag,digest}` (30-41) | b | `gateway.image.{repository,tag,pullPolicy}`; a `tag` starting `sha256:` is a digest (O values.yaml:362-372, _helpers.tpl:77-84). |
| `sandboxRuntime.image.*` (44-55) | b | `driver.sandboxRuntimeImage`, `driver.sandboxRuntimeImagePullPolicy` (O values.yaml:186-187). |
| `supervisor.image.*` (58-71) | b | `driver.supervisorImage`, `driver.supervisorImagePullPolicy` (O values.yaml:88, 188). |
| `supervisor.sandboxRuntime.boundaryPort` (74) | b | `driver.sandboxRuntimeBoundaryPort` (O values.yaml:195). |
| `sandbox.image.{repository,tag,digest,pullPolicy}` (76-85) | b | `driver.sandboxImage` (one ref), `driver.sandboxImagePullPolicy` (O values.yaml:192-193). |
| `upstreamProxy.*` (89-119) | b | `driver.upstreamProxy.*` (O values.yaml:237-246). |
| `imagePullSecrets` (122) | b | `imagePullSecrets` (O values.yaml:337). |
| `nameOverride`, `fullnameOverride` (124-126) | b | Read by O _helpers.tpl:4-22 but not declared in values.yaml (works implicitly). Upstream defaults `nameOverride: "openshell"`. |
| `serviceAccount.create`, `.name` (130,134) | b | `serviceAccount.create/name` (O values.yaml:26-28). |
| `sandboxServiceAccount.create`, `.name` (138,142) | b | `sandboxServiceAccount.create/name` (O values.yaml:50-52); fixed default name `openshell-sandbox`. |
| `rbac.clusterScoped.{create,clusterRoleName,clusterRoleBindingName}` (153-162) | b | `rbac.clusterScoped.*` (O values.yaml:39-43). |
| `workspaceResources.enabled` (167-170) | c | Exists for splitting gateway and workspace releases (the openshell-workspace chart); O has a single release and the sandbox SA/Role/NP are tied to the in-pod driver (O role.yaml:7-9). |
| `podAnnotations`, `podLabels` (173-175) | b | `podAnnotations`, `podLabels` (O values.yaml:350-351); a shared pod. |
| `podSecurityContext` (177-179) | b | `podSecurityContext` (O values.yaml:314-320), restricted. |
| `securityContext` (181-191) | b | Partly: `containerSecurityContext` applies to the driver; the gateway container's securityContext is hardcoded to PSS-restricted (O deployment.yaml:208-216). Not configurable, deliberately. |
| `service.port`, `.healthPort`, `.metricsPort` (197-201) | b | `gateway.grpcPort/healthPort/metricsPort` (O values.yaml:373-375), passed as flags. Upstream's `metricsPort: 0` disables metrics; O cannot. |
| `agentSandbox.preflight.enabled` (208-211) | b | `crdPreInstallCheck.enabled` (O values.yaml:341-343). |
| `autoscaling.*` (229-261) | c | HPA/multi-replica not applicable (single replica plus UDS sidecar). |
| `resources` (291) | b | `gateway.resources` (gateway) and `resources` (driver) (O values.yaml:305-311, 471-477). |
| `nodeSelector`, `tolerations`, `affinity` (294-300) | b | Same keys (O values.yaml:345-347). |
| `server.logLevel` (317) | b | `driver.logLevel` drives both the driver env and gateway TOML `log_level` (O gateway-config.yaml:70); no separate gateway level. |
| `server.ocsfLog.*` (325-344) | b | `gateway.ocsfLog.*` (O values.yaml:454-465). |
| `server.extraVolumes`, `server.extraVolumeMounts` (346-348) | b | `gateway.extraVolumes/extraVolumeMounts` (O values.yaml:468-469). |
| `server.sandboxNamespace` (354) | b | `namespace` (O values.yaml:11). |
| `server.dbUrl` (358) | b | `gateway.dbPersistence.{enabled,dbUrl}` (O values.yaml:489-493); the default path differs (`sqlite:///var/lib/openshell/openshell.db`). |
| `server.sandboxImagePullSecrets` (366) | b | `driver.sandboxImagePullSecrets` (list of names) (O values.yaml:194). |
| `server.workspaceDefaultStorageSize`, `workspaceStorageClass` (370,375) | b | `driver.sandboxStorageSize`, `driver.sandboxStorageClass` (O values.yaml:121,124). |
| `server.defaultRuntimeClassName` (381) | b | `driver.runtimeClassName` (O values.yaml:197). |
| `server.sandboxUid`, `sandboxGid` (385,388) | b | `driver.sandboxUid/Gid` (O values.yaml:116-117). |
| `server.grpcEndpoint` (394) | b | `driver.gatewayEndpoint` (O values.yaml:93). |
| `server.enableUserNamespaces` (408) | b | `driver.enableUserNamespaces` (O values.yaml:109). |
| `server.drivers.kubernetes.allowDriverConfig` (413) | b | `driver.allowDriverConfig` (O values.yaml:159). |
| `server.drivers.kubernetes.resourceAdmission.*` (414-418) | b | `driver.resourceAdmission.*` (O values.yaml:165-176). |
| `server.drivers.kubernetes.workspaceMode` (423) | b | `driver.workspaceMode` (O values.yaml:148). |
| `server.drivers.kubernetes.operatorNamespaceLabel`, `operatorNamespaceFile` (426,429) | b | `driver.operatorNamespaceLabel`, `driver.operatorNamespaceConfigMap` (mounted file) (O values.yaml:219-222). |
| `server.disableTls` (432) | b | `gateway.tls.enabled` (inverse) (O values.yaml:436-437). |
| `server.grpcRateLimit.*` (446-452) | b | `gateway.grpcRateLimit.*` (O values.yaml:446-448). |
| `server.auth.allowUnauthenticatedUsers` (514) | b | Implicit: O sets it true exactly when there is no OIDC issuer (O gateway-config.yaml:84-88); there is no explicit switch. See surprise 4. |
| `server.tls.certSecretName` (517) | b | `gateway.sandboxJwt.serverTlsSecretName` (O values.yaml:516); a pre-created Secret is honoured (certgen SkipExists only if all three exist). |
| `server.tls.enableMtls` (522) | b | `gateway.tls.clientCa.enabled` (O values.yaml:438-439); upstream default on, O default off. |
| `server.tls.clientTlsSecretName` (528) | b | `gateway.sandboxJwt.clientTlsSecretName` / `driver.clientTlsSecretName` (O values.yaml:518, 213). |
| `server.sandboxJwt.signingSecretName` (537) | b | `gateway.sandboxJwt.jwtSecretName` (O values.yaml:515). |
| `server.sandboxJwt.gatewayId`, `ttlSecs` (540,542) | b | `gateway.sandboxJwt.gatewayId/ttlSecs` (O values.yaml:521-522). |
| `server.sandboxJwt.k8sSaTokenTtlSecs` (548) | b | `driver.saTokenTtlSecs` (O values.yaml:196). |
| `server.oidc.issuer`, `audience`, `rolesClaim`, `adminRole`, `userRole` (567,576,581,584,586) | b | `gateway.oidc.*` as flags (O values.yaml:382-400, deployment.yaml:148-174), plus `authOnly`. Upstream's audience default is `openshell-cli`; O requires it explicitly. |
| `networkPolicy.enabled` (606) | b | `networkPolicy.enabled` (O values.yaml:284) plus the sandbox-ssh policy and managed SSH ingress. |
| `pkiInitJob.enabled` (626) | b | `gateway.sandboxJwt.enabled` runs the same `generate-certs` hook (mandatory with the gateway). Bring-your-own certificates work by pre-creating all three Secrets. |
| `pkiInitJob.timeoutSeconds`, `failOnTimeout` (638,647) | a* | Used only by the cert-manager backend-CA poll; covered inside gap 4.6. |
| `certManager.serverIssuerRef.*` (664-667) | c | External SNI certificate for passthrough routes; O's Istio ingress terminates the public TLS (surprise 6). |
| `grpcRoute.*` incl. `gateway.*`, `listener.*`, `replicaRouting.enabled` (698-752) | c | Gateway API routing; O uses an Istio VirtualService on the Kyma gateway (`gatewayIngress`). Replica routing is HA-only. |
| `grpcRoute.backendTLSPolicy.{enabled,caCertificateConfigMapName,hostname}` (760-782) | b | Istio equivalent: `gatewayIngress` DestinationRule plus `<fullname>-gateway-ca` ConfigMap from the PKI hook (O gateway-destinationrule.yaml, gateway-jwt-pki-hook.yaml:139-144); the name is fixed and the hostname is the Service FQDN. |
| `openshiftRoute.*` (788-794) | c | OpenShift only. |
| (template-only) HA env `OPENSHELL_REPLICA_ID`, `OPENSHELL_POD_NAME/NAMESPACE/IP`, `OPENSHELL_PEER_*`, the `gateway-peer-token` projected volume, the peer Service/Role, `peer-client-tls` (`_gateway-workload.tpl:67-110,158-160,247-254`) | c | Multi-replica peer relay and leases (U `crates/openshell-server/src/lib.rs:475-500, 740-775`, `compute/lease.rs:249-253`); single replica. (`OPENSHELL_POD_NAME` also serves the `subPathExpr` OCSF example; harmless to add.) |
| (template-only) `[openshell.drivers.kubernetes]` table, incl. `managed_ssh_ingress`, `namespace`, `service_account_name`, `default_image`, `gateway_id`, `grpc_endpoint` (`_toml.tpl:128-145`; `_helpers.tpl:464-565`) | b | Our driver takes these as env (O _driver-env.tpl); the gateway has `[openshell.drivers.kyma]` (O gateway-config.yaml:115-137). |
| (template-only) TOML `bind_address`, `health_bind_address`, `metrics_bind_address`, `compute_driver` (`_toml.tpl:107-113`) | b | Flags `--bind-address 0.0.0.0 --port --health-port --metrics-port --compute-driver kyma --compute-driver-socket` (O deployment.yaml:124-135). |

---

## Counts

| Group | Class (a) gaps |
|---|---|
| 1 Gateway settings | 9 (1.1-1.9; 1.7 bundles 4 OIDC keys; 1.9 `gatewayConfig` is new) |
| 2 Pod/K8s plumbing | 10 (2.1-2.10; 2.9 `secretDefaultMode` and 2.10 `rbac.create` are new; 2.5 reduced to gateway-pod hostAliases) |
| 3 Credential storage & drivers | 4 (3.1-3.4; 3.1 widened to the whole KEK mechanism) |
| 4 certManager | 1 (sub-items 4.1-4.7; `serverIssuerRef` reclassified (c)) |

Test infrastructure note: O has no helm-unittest suite. Upstream's `tests/*.yaml` cases map onto `scripts/check-chart-render.sh` assertions, and on `scripts/check-gateway-config.sh` for flag/TOML acceptance against the pinned image.
