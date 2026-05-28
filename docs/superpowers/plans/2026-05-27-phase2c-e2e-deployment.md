# Phase 2c — End-to-end deployment, user manual, and CLI test

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** Make the driver actually usable end-to-end: a single `helm install` deploys the gateway sidecar + driver, exposes the gateway, and a Tier-3 e2e test drives the OpenShell CLI from a laptop through the gateway to a real sandbox running on Kyma.

**Architecture:** Extend the existing Helm chart at `deploy/helm/openshell-driver-kyma/` with a second container in the Deployment (the gateway, image from Phase 2a), an `emptyDir` mount for the shared UDS, a Service exposing the gateway gRPC port, and an optional `APIRule` for external access. Add `docs/install-cli.md` (CLI install for Win/macOS/Linux) and `docs/getting-started.md` (the unified "from-zero-to-running-claude" walk-through). Add a Tier-3 e2e test that downloads the CLI, points it at the gateway, runs `openshell sandbox create -- claude`, and verifies the sandbox reaches Ready.

**Tech stack:** unchanged — Rust, Helm 3, GitHub Actions, gRPC.

**Depends on:** Phase 2a (gateway image at `ghcr.io/st-gr/openshell-gateway:<tag>`). Compatible with Phase 2b but not blocked by it.

**Reference materials:**
- Phase 2a plan at `docs/superpowers/plans/2026-05-27-phase2a-gateway-fork.md`
- `reference-openshift/deploy/gateway-with-driver.yaml` — the OpenShift-driver author's wiring of gateway + driver as sidecars in one pod
- `docs/cloud-connector-setup.md` — already covers the SCC routing path; the user manual links to it for that specific deployment topology

---

## File map

| File | Change |
|---|---|
| `deploy/helm/openshell-driver-kyma/values.yaml` | New `gateway:` section with image, port, gRPC settings, JWT/OIDC config; `gatewayApirule:` section with host, gateway selector, jwt issuer; `gatewayService:` boolean to toggle the gateway Service |
| `deploy/helm/openshell-driver-kyma/templates/deployment.yaml` | Add gateway container as a sidecar in the same pod; add `socket-dir` emptyDir volume mounted by both containers; gateway container args reference the shared socket path |
| `deploy/helm/openshell-driver-kyma/templates/service.yaml` | Add a second port (the gateway's gRPC port) when `gatewayService.enabled` |
| `deploy/helm/openshell-driver-kyma/templates/gateway-apirule.yaml` (NEW) | `gateway.kyma-project.io/v2` APIRule rendered when `gatewayApirule.enabled`; mirrors the per-sandbox APIRule shape from `enricher.rs` but for the gateway's hostname |
| `deploy/helm/openshell-driver-kyma/templates/role.yaml` | Permission for the driver SA to read the gateway secret if mTLS is on |
| `docs/install-cli.md` (NEW) | CLI install for Win/macOS/Linux: NVIDIA upstream releases, our fork-image-compatible CLI version, env setup |
| `docs/getting-started.md` (NEW) | Single linear walk-through from "I have a Kyma cluster" to "I'm running `openshell sandbox create -- claude` from my laptop" |
| `README.md` | Front-load `docs/getting-started.md` link; remove TBD references |
| `crates/openshell-driver-kyma/tests/e2e_cli.rs` (NEW) | Tier-3 test that runs the CLI binary against the deployed gateway |
| `Makefile` | Add `make e2e-cli` target |

---

### Task 1: Helm values for gateway

**Files:**
- Modify: `deploy/helm/openshell-driver-kyma/values.yaml`

- [ ] **Step 1**: Add a `gateway` block; default to disabled so existing installs are not affected:
  ```yaml
  # Gateway sidecar configuration. When enabled, the chart deploys an
  # openshell-server (NVIDIA OpenShell gateway, st-gr/OpenShell fork)
  # alongside the driver in the same pod, sharing a UDS via emptyDir.
  gateway:
    enabled: false
    image:
      repository: ghcr.io/st-gr/openshell-gateway
      tag: latest
      pullPolicy: IfNotPresent
    grpcPort: 8080
    metricsPort: 9091
    healthPort: 9092
    # Path inside the pod where the driver and gateway both see the UDS.
    # Must be writable by the driver container (UID 65532).
    socketPath: /shared/driver.sock
    extraArgs: []      # extra flags passed to `openshell-server run`
    # OIDC for client auth (the openshell CLI authenticates via OIDC).
    # When unset, --disable-tls is added (suitable for cluster-internal
    # gateways behind a service mesh).
    oidc:
      issuer: ""
      audience: ""
      adminRole: ""
      userRole: ""
    # gateway pod-level resources, separate from driver
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 1Gi }

  # ClusterIP Service exposing the gateway's gRPC + metrics ports.
  gatewayService:
    enabled: false   # turn on with .Values.gateway.enabled

  # Kyma APIRule for external access. Requires .Values.gatewayService.enabled.
  gatewayApirule:
    enabled: false
    host: ""               # e.g. openshell.<cluster-id>.kyma.ondemand.com
    gateway: kyma-system/kyma-gateway
    rules:
      - path: /*
        methods: [POST]
        # JWT auth referencing the same OIDC issuer as gateway.oidc above.
        jwt:
          authentications: []   # filled by user; example in docs
  ```
- [ ] **Step 2**: Verify defaults don't break existing render:
  ```
  make helm-lint
  helm template deploy/helm/openshell-driver-kyma > /tmp/before.yaml
  ```
- [ ] **Step 3**: Commit:
  ```
  git add deploy/helm/openshell-driver-kyma/values.yaml
  git commit -s -m "feat(helm): values for optional gateway sidecar + APIRule"
  ```

### Task 2: Gateway sidecar in Deployment

**Files:**
- Modify: `deploy/helm/openshell-driver-kyma/templates/deployment.yaml`

The gateway shares the pod with the driver. Both mount a `socket-dir` `emptyDir` so the driver writes the UDS at `/shared/driver.sock` and the gateway reads it via `--compute-driver-socket /shared/driver.sock`.

- [ ] **Step 1**: Add a shared volume and mount it on the driver container (driver currently has its own emptyDir for the socket — change so the path matches `.Values.gateway.socketPath`):
  ```yaml
  volumes:
    - name: socket-dir
      emptyDir: {}
    - name: tmp
      emptyDir: {}
  ```
  Driver volumeMount becomes:
  ```yaml
  volumeMounts:
    - name: socket-dir
      mountPath: {{ dir .Values.gateway.socketPath | quote }}
    - name: tmp
      mountPath: /tmp
  ```
  Driver args: change `--socket` to `{{ .Values.gateway.socketPath }}`.
- [ ] **Step 2**: Add the gateway container immediately after the driver container, gated by `.Values.gateway.enabled`:
  ```yaml
  {{- if .Values.gateway.enabled }}
  - name: gateway
    image: "{{ .Values.gateway.image.repository }}:{{ .Values.gateway.image.tag }}"
    imagePullPolicy: {{ .Values.gateway.image.pullPolicy }}
    args:
      - run
      - --bind-address
      - "0.0.0.0"
      - --port
      - {{ .Values.gateway.grpcPort | quote }}
      - --health-port
      - {{ .Values.gateway.healthPort | quote }}
      - --metrics-port
      - {{ .Values.gateway.metricsPort | quote }}
      - --compute-driver-socket
      - {{ .Values.gateway.socketPath | quote }}
      {{- if not .Values.gateway.oidc.issuer }}
      - --disable-tls
      {{- else }}
      - --oidc-issuer
      - {{ .Values.gateway.oidc.issuer | quote }}
      - --oidc-audience
      - {{ .Values.gateway.oidc.audience | quote }}
      {{- with .Values.gateway.oidc.adminRole }}
      - --oidc-admin-role
      - {{ . | quote }}
      {{- end }}
      {{- with .Values.gateway.oidc.userRole }}
      - --oidc-user-role
      - {{ . | quote }}
      {{- end }}
      {{- end }}
      {{- with .Values.gateway.extraArgs }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    ports:
      - name: grpc
        containerPort: {{ .Values.gateway.grpcPort }}
        protocol: TCP
      - name: gw-health
        containerPort: {{ .Values.gateway.healthPort }}
        protocol: TCP
      - name: gw-metrics
        containerPort: {{ .Values.gateway.metricsPort }}
        protocol: TCP
    livenessProbe:
      httpGet: { path: /healthz, port: gw-health }
      initialDelaySeconds: 5
      periodSeconds: 10
    readinessProbe:
      httpGet: { path: /readyz, port: gw-health }
      initialDelaySeconds: 2
      periodSeconds: 5
    resources:
      {{- toYaml .Values.gateway.resources | nindent 6 }}
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: [ALL] }
      runAsNonRoot: true
      runAsUser: 65532
      seccompProfile: { type: RuntimeDefault }
    volumeMounts:
      - name: socket-dir
        mountPath: {{ dir .Values.gateway.socketPath | quote }}
  {{- end }}
  ```
- [ ] **Step 3**: Verify rendering:
  ```
  helm template deploy/helm/openshell-driver-kyma --set gateway.enabled=true \
    --set gateway.oidc.issuer=https://example.accounts.ondemand.com \
    --set gateway.oidc.audience=openshell \
    | grep -E '(name: gateway|--compute-driver-socket|--oidc-issuer)'
  ```
- [ ] **Step 4**: Verify the driver-only render is unchanged versus pre-change:
  ```
  helm template deploy/helm/openshell-driver-kyma > /tmp/after.yaml
  diff /tmp/before.yaml /tmp/after.yaml
  ```
  Diff should show only the renamed socket path (driver argument) and the new volume names; no semantic changes when `gateway.enabled=false`.
- [ ] **Step 5**: Commit:
  ```
  git add deploy/helm/openshell-driver-kyma/templates/deployment.yaml
  git commit -s -m "feat(helm): gateway sidecar gated by .Values.gateway.enabled

  Driver and gateway share a socket-dir emptyDir; driver writes the UDS,
  gateway reads via --compute-driver-socket. Gateway is restricted-PSS
  compatible (runAsNonRoot, drop ALL caps, RuntimeDefault seccomp)."
  ```

### Task 3: Gateway Service + APIRule

**Files:**
- Modify: `deploy/helm/openshell-driver-kyma/templates/service.yaml`
- Create: `deploy/helm/openshell-driver-kyma/templates/gateway-apirule.yaml`

- [ ] **Step 1**: Update `service.yaml` to add the gateway ports when `gatewayService.enabled`:
  ```yaml
  ports:
    - name: health
      port: {{ .Values.driver.healthPort }}
      targetPort: health
      protocol: TCP
    {{- if .Values.gatewayService.enabled }}
    - name: grpc
      port: {{ .Values.gateway.grpcPort }}
      targetPort: grpc
      protocol: TCP
    - name: gw-metrics
      port: {{ .Values.gateway.metricsPort }}
      targetPort: gw-metrics
      protocol: TCP
    {{- end }}
  ```
- [ ] **Step 2**: Create `gateway-apirule.yaml`:
  ```yaml
  {{- if and .Values.gatewayApirule.enabled .Values.gatewayService.enabled -}}
  apiVersion: gateway.kyma-project.io/v2
  kind: APIRule
  metadata:
    name: {{ include "openshell-driver-kyma.fullname" . }}-gateway
    namespace: {{ .Release.Namespace }}
    labels:
      {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
  spec:
    gateway: {{ .Values.gatewayApirule.gateway }}
    hosts: [{{ .Values.gatewayApirule.host | quote }}]
    service:
      name: {{ include "openshell-driver-kyma.fullname" . }}
      port: {{ .Values.gateway.grpcPort }}
    rules:
      {{- toYaml .Values.gatewayApirule.rules | nindent 6 }}
  {{- end }}
  ```
- [ ] **Step 3**: Verify:
  ```
  helm template deploy/helm/openshell-driver-kyma \
    --set gateway.enabled=true \
    --set gatewayService.enabled=true \
    --set gatewayApirule.enabled=true \
    --set gatewayApirule.host=openshell.example.kyma.ondemand.com \
    | grep -A 20 'kind: APIRule'
  ```
- [ ] **Step 4**: `helm lint` clean.
- [ ] **Step 5**: Commit:
  ```
  git add deploy/helm/openshell-driver-kyma/templates/
  git commit -s -m "feat(helm): gateway Service + Kyma APIRule for external access"
  ```

### Task 4: `docs/install-cli.md`

**Files:**
- Create: `docs/install-cli.md`

- [ ] **Step 1**: Write a single-page CLI install doc covering:
  - **macOS**: `uv tool install -U openshell` (PyPI build) OR `brew install openshell` if/when published. Note that the CLI version must be wire-compatible with the deployed gateway image; we recommend pinning to the version matching `ghcr.io/st-gr/openshell-gateway`'s tag.
  - **Linux**: same `uv tool install` path; alternatively download a release binary from `github.com/NVIDIA/OpenShell/releases`.
  - **Windows**: `uv tool install` works under Git Bash / WSL2. Native Windows is not officially supported by upstream; suggest WSL2.
  - **Verify**: `openshell --version` should match the gateway's reported version (`Health` RPC).
  - **First-time setup**: `openshell gateway add https://<your-gateway-host> --name kyma`. If using a self-signed cert, `--ca-cert /path/to/cert.pem`. If using OIDC, the CLI opens a browser for login.
  - **Test connection**: `openshell gateway list && openshell sandbox list` should both succeed (the second returns an empty list).
- [ ] **Step 2**: Run `markdownlint-cli2 "docs/install-cli.md"` (or `make dev-shell` then `markdownlint-cli2`).
- [ ] **Step 3**: Commit:
  ```
  git add docs/install-cli.md
  git commit -s -m "docs: openshell CLI install guide for win/mac/linux"
  ```

### Task 5: `docs/getting-started.md`

**Files:**
- Create: `docs/getting-started.md`

A single linear walk-through. Each section is one concrete action. The doc explicitly assumes Phase 2a's image exists.

- [ ] **Step 1**: Outline:
  1. **Prerequisites** — Kyma cluster, `kubectl get ns` works, `agent-sandbox` CRD installed.
  2. **Label the sandbox namespace privileged** — `kubectl label ns openshell-system pod-security.kubernetes.io/enforce=privileged`.
  3. **Install the chart with the gateway enabled** — explicit `helm install` invocation with `gateway.enabled=true`, `gatewayService.enabled=true`, OIDC values for SAP IAS (or `--disable-tls` for in-cluster only).
  4. **Verify pods Ready** — `kubectl -n openshell-system get pods` and the expected log lines for both containers.
  5. **Install the CLI** — link to `docs/install-cli.md`.
  6. **Reach the gateway** — two options:
     - Public: `kubectl apply -f` an APIRule (the chart already provisioned it if `gatewayApirule.enabled=true`); `openshell gateway add https://<host> --name kyma`.
     - Private (VPN-only): port-forward via SCC per `docs/cloud-connector-setup.md`; `openshell gateway add http://localhost:8080 --name kyma --local`.
  7. **First sandbox** — `openshell provider create --type anthropic --credential ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY` and `openshell sandbox create --provider anthropic --from quay.io/azaalouk/demo-sandbox-claude:latest -- claude`.
  8. **Connect** — `openshell sandbox exec -n <name> -- claude --version`.
  9. **Transfer files** — `openshell sandbox scp ./prompt.txt <name>:/workspace/` (refer to `docs/openshell-api-programmatic-usage.md` for non-CLI patterns).
  10. **Tear down** — `openshell sandbox delete <name>`; optionally `helm uninstall openshell-driver-kyma -n openshell-system`.
- [ ] **Step 2**: For each section, include the exact command, the expected output (with elided cluster IDs), and the next step's hand-off. Include a troubleshooting block at the end covering: PSA label missing, gateway not Ready, OIDC token expired, APIRule 404.
- [ ] **Step 3**: `markdownlint-cli2`.
- [ ] **Step 4**: Commit:
  ```
  git add docs/getting-started.md
  git commit -s -m "docs: getting started — Kyma cluster to running Claude in 10 steps"
  ```

### Task 6: README front-load

**Files:**
- Modify: `README.md`

- [ ] **Step 1**: Replace the existing quickstart block with a one-paragraph pointer plus the canonical first-time link:
  ```md
  ## Quick start

  Follow the linear walk-through in [docs/getting-started.md](docs/getting-started.md).
  It takes you from "I have a Kyma cluster" to "I'm running Claude inside an
  OpenShell sandbox" in 10 steps. For programmatic access without the CLI,
  see [docs/openshell-api-programmatic-usage.md](docs/openshell-api-programmatic-usage.md).
  For private routing through SAP Cloud Connector, see
  [docs/cloud-connector-setup.md](docs/cloud-connector-setup.md).
  ```
- [ ] **Step 2**: Remove any "Status: Phase 1" wording that's now stale; replace with "Status: Phase 2 (gateway-deployable, end-to-end testable)".
- [ ] **Step 3**: Commit:
  ```
  git add README.md
  git commit -s -m "docs(readme): front-load getting-started; promote past Phase 1"
  ```

### Task 7: Tier-3 e2e CLI test

**Files:**
- Create: `crates/openshell-driver-kyma/tests/e2e_cli.rs`
- Modify: `Makefile`

- [ ] **Step 1**: Write the test. It assumes a deployed `openshell-driver-kyma` chart with `gateway.enabled=true`, `gatewayService.enabled=true`. It downloads the upstream OpenShell CLI binary (skipping if `OPENSHELL_BIN` is set), points it at the gateway via `kubectl port-forward`, and exercises the happy path.
  ```rust
  #![cfg(all(unix, feature = "integration"))]

  use std::process::{Command, Stdio};
  use std::time::Duration;

  fn cli_bin() -> String {
      std::env::var("OPENSHELL_BIN").unwrap_or_else(|_| "openshell".into())
  }

  fn require(env: &str) -> String {
      std::env::var(env).unwrap_or_else(|_| panic!("{env} must be set"))
  }

  #[test]
  fn cli_creates_and_deletes_sandbox_through_real_gateway() {
      let ns = require("INTEGRATION_TEST_NAMESPACE");
      let _ = require("ANTHROPIC_API_KEY");
      // Sanity: refuse system namespaces (defense in depth even though
      // the deployment already imposes the deny-list).
      for forbidden in ["kube-system","kyma-system","istio-system","default"] {
          assert_ne!(ns, forbidden, "refusing to run e2e in {forbidden}");
      }
      // 1. Port-forward the gateway service.
      let mut pf = Command::new("kubectl")
          .args(["-n", &ns, "port-forward", "svc/openshell-driver-kyma", "8080:8080"])
          .stdout(Stdio::piped()).stderr(Stdio::piped())
          .spawn().expect("kubectl port-forward");
      std::thread::sleep(Duration::from_secs(2));

      // 2. Register gateway.
      let r = Command::new(cli_bin())
          .args(["gateway","add","http://localhost:8080","--name","e2e","--local"])
          .status().expect("openshell gateway add");
      assert!(r.success());

      // 3. Provider.
      let r = Command::new(cli_bin())
          .args(["provider","create","--type","anthropic",
                 "--credential", &format!("ANTHROPIC_API_KEY={}", std::env::var("ANTHROPIC_API_KEY").unwrap())])
          .status().expect("openshell provider create");
      assert!(r.success());

      // 4. Sandbox create.
      let name = format!("e2e-{}", std::time::SystemTime::now()
          .duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos());
      let r = Command::new(cli_bin())
          .args(["sandbox","create","--name",&name,
                 "--provider","anthropic",
                 "--from","quay.io/azaalouk/demo-sandbox-claude:latest",
                 "--", "sleep","infinity"])
          .status().expect("openshell sandbox create");
      assert!(r.success());

      // 5. Wait for it to become Ready (via the CLI).
      for _ in 0..60 {
          let out = Command::new(cli_bin())
              .args(["sandbox","get",&name,"-o","json"])
              .output().expect("get");
          let txt = String::from_utf8_lossy(&out.stdout);
          if txt.contains("\"phase\":\"Ready\"") { break; }
          std::thread::sleep(Duration::from_secs(2));
      }

      // 6. Exec a trivial command.
      let r = Command::new(cli_bin())
          .args(["sandbox","exec","-n",&name,"--","echo","ok"])
          .status().expect("openshell sandbox exec");
      assert!(r.success());

      // 7. Cleanup.
      let _ = Command::new(cli_bin()).args(["sandbox","delete",&name]).status();
      let _ = Command::new(cli_bin()).args(["gateway","remove","e2e"]).status();
      let _ = pf.kill();
  }
  ```
- [ ] **Step 2**: Add the make target:
  ```make
  .PHONY: e2e-cli
  e2e-cli:
  ifeq ($(strip $(INTEGRATION_TEST_NAMESPACE)),)
  	$(error INTEGRATION_TEST_NAMESPACE must be set)
  endif
  ifeq ($(strip $(ANTHROPIC_API_KEY)),)
  	$(error ANTHROPIC_API_KEY must be set)
  endif
  	$(DOCKER_RUN) -v "$(HOME)/.kube:/root/.kube:ro" \
  		-e INTEGRATION_TEST_NAMESPACE=$(INTEGRATION_TEST_NAMESPACE) \
  		-e ANTHROPIC_API_KEY=$(ANTHROPIC_API_KEY) \
  		-e OPENSHELL_BIN=openshell \
  		$(DEV_IMAGE) \
  		bash -c "uv tool install -q openshell 2>/dev/null || true; \
  		         cargo test -p openshell-driver-kyma --test e2e_cli --features integration -- --test-threads=1"
  ```
- [ ] **Step 3**: Run against your live cluster (after Phase 2a's image is published and the chart is installed with `gateway.enabled=true`):
  ```
  make e2e-cli INTEGRATION_TEST_NAMESPACE=openshell-driver-test ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
  ```
- [ ] **Step 4**: Iterate until the test passes; document any platform-specific quirks in `docs/getting-started.md`'s troubleshooting section.
- [ ] **Step 5**: Commit:
  ```
  git add crates/openshell-driver-kyma/tests/e2e_cli.rs Makefile
  git commit -s -m "test(e2e): CLI-driven sandbox lifecycle through gateway sidecar"
  ```

### Task 8: CHANGELOG + bump

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1**: Add an entry under `## [Unreleased]` summarizing the new capabilities — gateway sidecar, APIRule, getting-started, e2e test.
- [ ] **Step 2**: Tag once Phase 2a, 2b, 2c are all merged:
  ```
  git tag -s v0.2.0 -m "Phase 2: end-to-end usable on Kyma"
  git push origin v0.2.0
  ```
  The `release-tag` workflow builds + publishes the driver image and packages the chart automatically.

---

## Verification (end-to-end)

1. `make test` and `make helm-lint` green on a fresh checkout.
2. `helm install openshell-driver-kyma deploy/helm/openshell-driver-kyma -n openshell-system --create-namespace --set gateway.enabled=true --set gatewayService.enabled=true --set gateway.oidc.issuer=https://<your-iss>` succeeds; both containers reach Ready.
3. Following `docs/getting-started.md` end-to-end on a clean laptop produces a running Claude Code sandbox and the user can `openshell sandbox exec -- claude --version`.
4. `make e2e-cli INTEGRATION_TEST_NAMESPACE=openshell-driver-test ANTHROPIC_API_KEY=...` runs to green.
5. CI: branch-checks + helm-lint + (when published) docker-build all green on the PR that lands these changes.

## Self-review checklist

- **Spec coverage**: addresses the 6 gap items from the audit (gateway deployment, gateway exposure, user manual, CLI install, e2e test, README cleanup). Driver hardening is in 2b; the gateway image is in 2a.
- **Placeholders**: every Helm fragment is concrete; the e2e test code is full; docs sections enumerate the specific commands and outputs.
- **Type consistency**: `gateway.socketPath` is the single source of truth for the UDS — both driver and gateway containers reference it. `gatewayApirule.enabled` requires `gatewayService.enabled` (enforced via `and` in the template).
- **Risk**: The Tier-3 e2e test depends on the upstream `openshell` CLI's wire compatibility with our forked gateway. If the CLI version drifts ahead of the fork, the test breaks. Mitigation: pin the CLI version in `Makefile`'s `e2e-cli` target via `uv tool install openshell==<version>` matching the gateway image's tag.
