# Phase 2b — Driver hardening per upstream-sync-review

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** Bring `openshell-driver-kyma` up to parity with NVIDIA upstream's post-extraction Kubernetes driver, fixing the gaps documented in `reference-openshift/docs/upstream-sync-review.md`. Each gap is independently testable.

**Architecture:** Six surgical changes to `crates/openshell-driver-kyma/src/`: drop `privileged: true` in favour of caps-only, add PVC workspace persistence behind a flag, add Kubernetes Event correlation in the watcher, add an mTLS client-secret volume mount, make `serviceAccountName` configurable, add `imagePullPolicy` config. Each change has its own commit and at least one new unit test.

**Tech stack:** unchanged — Rust 1.95, kube 3.1, k8s-openapi 0.27, tonic 0.14, axum 0.8.

**Reference materials:**
- `reference-openshift/docs/upstream-sync-review.md` — sections 2 (privileged vs caps), 4 (PVC), 5 (mTLS), 6 (Event correlation), 7 (host_gateway_ip — out of scope here), 8 (image_pull_policy).
- Upstream PRs cited in the review:
  - [#817](https://github.com/NVIDIA/OpenShell/pull/817) — k8s driver extraction; capabilities, mTLS volume, Event correlation
  - [#739](https://github.com/NVIDIA/OpenShell/pull/739) — PVC workspace persistence
  - [#862](https://github.com/NVIDIA/OpenShell/pull/862) — system CA + mTLS

---

## File map

| File | Change |
|---|---|
| `crates/openshell-driver-kyma/src/provisioner.rs` | Drop `privileged: true` from agent securityContext; add PVC `volumeClaimTemplates` and workspace-init init container; thread `image_pull_policy`; render mTLS volume mount when configured; respect configurable `serviceAccountName` |
| `crates/openshell-driver-kyma/src/config.rs` | Add `image_pull_policy`, `client_tls_secret_name`, `enable_workspace_pvc`, `workspace_pvc_size`, `sandbox_service_account` flags |
| `crates/openshell-driver-kyma/src/provisioner.rs` (Watch) | Add a second watch over `events.k8s.io/v1/Event`, correlate by pod-name index, emit `WatchEvent::PlatformEvent` |
| `crates/openshell-driver-kyma/src/interfaces.rs` | Extend `WatchEvent` with `PlatformEvent { sandbox_id, source, type, reason, message, timestamp_ms, metadata }` variant |
| `crates/openshell-driver-kyma/src/driver.rs` | Map `WatchEvent::PlatformEvent` → `WatchSandboxesPlatformEvent` proto; add `metrics.platform_event(...)` |
| `crates/openshell-driver-kyma/src/metrics.rs` | Add `platform_events_total{reason}` counter |
| `deploy/helm/openshell-driver-kyma/values.yaml` | Surface the new flags (sandbox.serviceAccount, sandbox.workspacePvc.{enabled,size}, sandbox.clientTlsSecretName, sandbox.imagePullPolicy) |
| `deploy/helm/openshell-driver-kyma/templates/role.yaml` | Add `events` get/list/watch when event correlation is enabled |

---

### Task 1: Drop `privileged: true` from agent securityContext

**Files:**
- Modify: `crates/openshell-driver-kyma/src/provisioner.rs` (the `build_sandbox_spec` function, agent container `securityContext` JSON block)

The supervisor needs `SYS_ADMIN` (seccomp + netns), `NET_ADMIN` (veth), `SYS_PTRACE` (proc/fd reads in CONNECT proxy), and `SYSLOG` (kmsg). It does **not** need full `privileged`.

- [ ] **Step 1**: Update the failing test in `provisioner::tests` first:
  ```rust
  #[tokio::test]
  async fn build_sandbox_spec_does_not_set_privileged_true() {
      let p = make_provisioner();
      let sb = make_sandbox("sb-1", "x", "img");
      let spec = p.build_sandbox_spec(&sb);
      let sc = &spec["podTemplate"]["spec"]["containers"][0]["securityContext"];
      // privileged must NOT be set; admission controllers should accept on caps alone
      assert!(sc.get("privileged").is_none());
      // runAsUser stays 0; the supervisor drops privileges before exec'ing the agent
      assert_eq!(sc["runAsUser"], 0);
      // capabilities stay as before
      let caps: Vec<&str> = sc["capabilities"]["add"].as_array().unwrap()
          .iter().map(|v| v.as_str().unwrap()).collect();
      assert_eq!(caps, vec!["SYS_ADMIN","NET_ADMIN","SYS_PTRACE","SYSLOG"]);
  }
  ```
- [ ] **Step 2**: Run the test to verify it fails (existing code sets `"privileged": true`):
  ```
  make dev-test
  ```
- [ ] **Step 3**: Remove the `"privileged": true,` line from `build_sandbox_spec`. The agent container `securityContext` json should now be:
  ```rust
  "securityContext": {
      "runAsUser": 0,
      "capabilities": {
          "add": ["SYS_ADMIN", "NET_ADMIN", "SYS_PTRACE", "SYSLOG"]
      }
  },
  ```
- [ ] **Step 4**: Re-run tests; the existing test `build_sandbox_spec_security_context_has_required_caps` may now also need updating (was asserting `privileged == true`):
  ```
  make dev-test
  ```
  Update the existing assertion to `assert!(sc.get("privileged").is_none());` if it still asserts the old value.
- [ ] **Step 5**: Commit:
  ```
  git add crates/openshell-driver-kyma/src/provisioner.rs
  git commit -s -m "feat(provisioner): drop privileged:true; capabilities are sufficient

  The supervisor needs SYS_ADMIN/NET_ADMIN/SYS_PTRACE/SYSLOG. privileged
  granted ALL caps + host devices, which is much broader. Removing it
  lets a custom PSA profile / SCC with just those four caps suffice."
  ```

### Task 2: Configurable `serviceAccountName` and `imagePullPolicy`

**Files:**
- Modify: `crates/openshell-driver-kyma/src/config.rs`
- Modify: `crates/openshell-driver-kyma/src/provisioner.rs`

- [ ] **Step 1**: Add two fields to `Config`:
  ```rust
  /// ServiceAccount name attached to every sandbox pod. Cluster-admin must
  /// pre-create this SA in the sandbox namespace.
  #[arg(long, default_value = "openshell-sandbox")]
  pub sandbox_service_account: String,

  /// Pod-level imagePullPolicy applied to the supervisor init container and
  /// the agent container. Empty string defers to Kubernetes's default
  /// (Always for :latest tags, IfNotPresent otherwise).
  #[arg(long, default_value = "")]
  pub image_pull_policy: String,
  ```
- [ ] **Step 2**: Update `Default` impl with the same defaults.
- [ ] **Step 3**: Failing test `defaults_match_spec` already covers field defaults — extend it:
  ```rust
  assert_eq!(c.sandbox_service_account, "openshell-sandbox");
  assert_eq!(c.image_pull_policy, "");
  ```
- [ ] **Step 4**: In `build_sandbox_spec`, replace the hardcoded `SANDBOX_SERVICE_ACCOUNT` constant usage with `&self.cfg.sandbox_service_account`. Inject `imagePullPolicy` into both containers when non-empty:
  ```rust
  if !self.cfg.image_pull_policy.is_empty() {
      init_container["imagePullPolicy"] = Value::String(self.cfg.image_pull_policy.clone());
      agent_container["imagePullPolicy"] = Value::String(self.cfg.image_pull_policy.clone());
  }
  ```
- [ ] **Step 5**: Add unit tests:
  ```rust
  #[tokio::test]
  async fn build_sandbox_spec_uses_configured_service_account() {
      let cfg = Config { sandbox_service_account: "custom-sa".into(), namespace: "ns".into(), ..Config::default() };
      let p = KymaProvisioner::new(test_client(), cfg);
      let sb = make_sandbox("sb-1", "x", "img");
      let spec = p.build_sandbox_spec(&sb);
      assert_eq!(spec["podTemplate"]["spec"]["serviceAccountName"], "custom-sa");
  }

  #[tokio::test]
  async fn build_sandbox_spec_threads_image_pull_policy_when_set() {
      let cfg = Config { image_pull_policy: "Always".into(), namespace: "ns".into(), ..Config::default() };
      let p = KymaProvisioner::new(test_client(), cfg);
      let sb = make_sandbox("sb-1", "x", "img");
      let spec = p.build_sandbox_spec(&sb);
      assert_eq!(spec["podTemplate"]["spec"]["containers"][0]["imagePullPolicy"], "Always");
      assert_eq!(spec["podTemplate"]["spec"]["initContainers"][0]["imagePullPolicy"], "Always");
  }
  ```
- [ ] **Step 6**: Run tests:
  ```
  make dev-test
  ```
- [ ] **Step 7**: Commit:
  ```
  git add crates/openshell-driver-kyma/src/config.rs \
          crates/openshell-driver-kyma/src/provisioner.rs
  git commit -s -m "feat(config): expose sandbox_service_account + image_pull_policy

  Drops two hardcoded values (openshell-sandbox SA, no pull policy)
  and threads them through build_sandbox_spec."
  ```

### Task 3: Optional PVC workspace persistence

**Files:**
- Modify: `crates/openshell-driver-kyma/src/config.rs`
- Modify: `crates/openshell-driver-kyma/src/provisioner.rs`

Per upstream PR #739, when enabled each sandbox gets a 2 Gi RWO PVC for `/sandbox` data. A separate `workspace-init` init container seeds the PVC from the agent image's `/sandbox` on first boot using a `.workspace-initialized` sentinel.

- [ ] **Step 1**: Add config:
  ```rust
  /// When true, each sandbox is provisioned with a workspace PVC so
  /// /sandbox content survives pod restarts. Off by default to match
  /// the OpenShift driver's Phase 1 ephemeral behavior.
  #[arg(long, default_value_t = false, action = clap::ArgAction::Set, num_args = 0..=1, default_missing_value = "true")]
  pub enable_workspace_pvc: bool,

  /// PVC size for the sandbox workspace. Only used when
  /// --enable-workspace-pvc is true.
  #[arg(long, default_value = "2Gi")]
  pub workspace_pvc_size: String,
  ```
- [ ] **Step 2**: Failing test:
  ```rust
  #[tokio::test]
  async fn workspace_pvc_template_added_when_enabled() {
      let cfg = Config { enable_workspace_pvc: true, namespace: "ns".into(), ..Config::default() };
      let p = KymaProvisioner::new(test_client(), cfg);
      let sb = make_sandbox("sb-1", "x", "img");
      let spec = p.build_sandbox_spec(&sb);
      let templates = spec.pointer("/volumeClaimTemplates").unwrap().as_array().unwrap();
      assert_eq!(templates.len(), 1);
      assert_eq!(templates[0]["metadata"]["name"], "workspace");
      assert_eq!(templates[0]["spec"]["accessModes"][0], "ReadWriteOnce");
      assert_eq!(templates[0]["spec"]["resources"]["requests"]["storage"], "2Gi");
      // workspace-init container exists and writes the sentinel
      let inits = spec.pointer("/podTemplate/spec/initContainers").unwrap().as_array().unwrap();
      assert!(inits.iter().any(|c| c["name"] == "workspace-init"));
  }

  #[tokio::test]
  async fn workspace_pvc_absent_when_disabled() {
      let cfg = Config { enable_workspace_pvc: false, namespace: "ns".into(), ..Config::default() };
      let p = KymaProvisioner::new(test_client(), cfg);
      let sb = make_sandbox("sb-1", "x", "img");
      let spec = p.build_sandbox_spec(&sb);
      assert!(spec.pointer("/volumeClaimTemplates").is_none());
  }
  ```
- [ ] **Step 3**: Implement. In `build_sandbox_spec`, when `cfg.enable_workspace_pvc`:
  - Add a `workspace-init` init container before `supervisor-init`. Image: same as the agent. Command:
    ```sh
    if [ ! -f /workspace/.workspace-initialized ]; then \
      tar -cf - -C /sandbox . | tar -xpf - -C /workspace && \
      touch /workspace/.workspace-initialized; \
    fi
    ```
  - Add a `workspace` volume mount on the agent container at `/sandbox` (replacing whatever the image had at `/sandbox`).
  - At the Sandbox CR level (not pod level), add `volumeClaimTemplates`:
    ```rust
    if self.cfg.enable_workspace_pvc {
        spec_obj["volumeClaimTemplates"] = json!([{
            "metadata": { "name": "workspace" },
            "spec": {
                "accessModes": ["ReadWriteOnce"],
                "resources": { "requests": { "storage": self.cfg.workspace_pvc_size } }
            }
        }]);
    }
    ```
- [ ] **Step 4**: Run tests:
  ```
  make dev-test
  ```
- [ ] **Step 5**: Commit:
  ```
  git add crates/openshell-driver-kyma/src/config.rs \
          crates/openshell-driver-kyma/src/provisioner.rs
  git commit -s -m "feat(provisioner): optional PVC workspace persistence

  Behind --enable-workspace-pvc. When enabled, each sandbox gets a 2Gi
  RWO PVC mounted at /sandbox via a volumeClaimTemplate, plus a
  workspace-init container that seeds the PVC from the agent image on
  first boot. Mirrors NVIDIA upstream PR #739."
  ```

### Task 4: mTLS client secret volume mount

**Files:**
- Modify: `crates/openshell-driver-kyma/src/config.rs`
- Modify: `crates/openshell-driver-kyma/src/provisioner.rs`

- [ ] **Step 1**: Config:
  ```rust
  /// Name of a Secret in the sandbox namespace containing the supervisor's
  /// mTLS client cert (`tls.crt`/`tls.key`). When set, the secret is
  /// mounted read-only at /etc/openshell-tls/client. Empty disables mTLS.
  #[arg(long, default_value = "")]
  pub client_tls_secret_name: String,
  ```
- [ ] **Step 2**: Failing test:
  ```rust
  #[tokio::test]
  async fn mtls_secret_volume_mounted_when_configured() {
      let cfg = Config { client_tls_secret_name: "my-tls".into(), namespace: "ns".into(), ..Config::default() };
      let p = KymaProvisioner::new(test_client(), cfg);
      let sb = make_sandbox("sb-1", "x", "img");
      let spec = p.build_sandbox_spec(&sb);
      let vols = spec.pointer("/podTemplate/spec/volumes").unwrap().as_array().unwrap();
      assert!(vols.iter().any(|v| v["secret"]["secretName"] == "my-tls"));
      let mounts = spec.pointer("/podTemplate/spec/containers/0/volumeMounts").unwrap().as_array().unwrap();
      assert!(mounts.iter().any(|m| m["mountPath"] == "/etc/openshell-tls/client" && m["readOnly"] == true));
  }
  ```
- [ ] **Step 3**: Implement: append a Secret volume + agent-container volumeMount when `cfg.client_tls_secret_name` non-empty. Mount mode `0400`.
- [ ] **Step 4**: Run tests; commit:
  ```
  git add crates/openshell-driver-kyma/src/config.rs \
          crates/openshell-driver-kyma/src/provisioner.rs
  git commit -s -m "feat(provisioner): mount mTLS client secret when configured"
  ```

### Task 5: Kubernetes Event correlation in `Watch`

**Files:**
- Modify: `crates/openshell-driver-kyma/src/interfaces.rs` (extend WatchEvent)
- Modify: `crates/openshell-driver-kyma/src/provisioner.rs` (Watch impl)
- Modify: `crates/openshell-driver-kyma/src/driver.rs` (map to proto)
- Modify: `crates/openshell-driver-kyma/src/metrics.rs` (counter)

Today the driver only watches Sandbox CRs and emits Updated/Deleted. Upstream's k8s driver also watches `events.k8s.io/v1/Event`, correlates each event to a sandbox via a pod-name index, and emits `WatchSandboxesPlatformEvent`. This is critical for surfacing `FailedScheduling`, `ErrImagePull`, etc.

- [ ] **Step 1**: Extend the enum in `interfaces.rs`:
  ```rust
  #[derive(Debug, Clone)]
  pub enum WatchEvent {
      Updated(Box<DriverSandbox>),
      Deleted(String),
      PlatformEvent {
          sandbox_id: String,
          source: String,
          ev_type: String,
          reason: String,
          message: String,
          timestamp_ms: i64,
      },
  }
  ```
- [ ] **Step 2**: Failing test in `provisioner::tests`:
  ```rust
  #[tokio::test]
  async fn watcher_correlates_events_to_sandbox_id() { /* uses fake watcher streams */ }
  ```
  Realistic test setup is non-trivial because it requires a fake `kube::runtime::watcher` for both Sandbox CR and Event. Acceptable scope: a unit-level test that exercises the correlation function (`correlate_event_to_sandbox(ev: &Event, index: &PodIndex) -> Option<String>`), and the integration with the runtime is verified via Tier-3 in Phase 2c.
- [ ] **Step 3**: Implement. In the Watch path, spawn a second `kube::runtime::watcher` over `Api::<Event>::namespaced(client, ns)`. Maintain a `pod_to_sandbox_id: HashMap<String, String>` populated from the Sandbox CR watcher's `status.agentPod`. When an event arrives whose `regarding.name` matches a pod in the index, emit `WatchEvent::PlatformEvent { sandbox_id, source: "kubernetes", ev_type: ev.type_, reason: ev.reason, message: ev.note, timestamp_ms: ev.event_time.unix_timestamp_millis() }`.
- [ ] **Step 4**: Map in `driver.rs::watch_sandboxes`:
  ```rust
  WatchEvent::PlatformEvent { sandbox_id, source, ev_type, reason, message, timestamp_ms } => {
      metrics.platform_event(&reason);
      WatchSandboxesEvent {
          payload: Some(Payload::PlatformEvent(WatchSandboxesPlatformEvent {
              sandbox_id,
              event: Some(DriverPlatformEvent {
                  source, r#type: ev_type, reason, message, timestamp_ms,
                  metadata: HashMap::new(),
              }),
          })),
      }
  }
  ```
- [ ] **Step 5**: Add `metrics::platform_event(reason: &str)` to `DriverMetrics` trait and `PrometheusMetrics`. Counter: `platform_events_total{reason}`.
- [ ] **Step 6**: Update Helm `role.yaml` to grant `events get/list/watch` in the same namespace.
- [ ] **Step 7**: Run tests; commit:
  ```
  git add crates/openshell-driver-kyma/src/ deploy/helm/openshell-driver-kyma/templates/role.yaml
  git commit -s -m "feat(provisioner): correlate K8s Events to sandboxes; emit PlatformEvent"
  ```

### Task 6: Helm values + lint

**Files:**
- Modify: `deploy/helm/openshell-driver-kyma/values.yaml`
- Modify: `deploy/helm/openshell-driver-kyma/templates/deployment.yaml`

- [ ] **Step 1**: Add the new `.Values.driver.*` keys to `values.yaml`:
  ```yaml
  driver:
    sandboxServiceAccount: openshell-sandbox
    imagePullPolicy: ""
    enableWorkspacePvc: false
    workspacePvcSize: 2Gi
    clientTlsSecretName: ""
  ```
- [ ] **Step 2**: Add the corresponding args to the Deployment template using the same `--flag` form as existing entries:
  ```yaml
  - --sandbox-service-account
  - {{ .Values.driver.sandboxServiceAccount | quote }}
  {{- if .Values.driver.imagePullPolicy }}
  - --image-pull-policy
  - {{ .Values.driver.imagePullPolicy | quote }}
  {{- end }}
  - --enable-workspace-pvc={{ .Values.driver.enableWorkspacePvc }}
  - --workspace-pvc-size
  - {{ .Values.driver.workspacePvcSize | quote }}
  {{- if .Values.driver.clientTlsSecretName }}
  - --client-tls-secret-name
  - {{ .Values.driver.clientTlsSecretName | quote }}
  {{- end }}
  ```
- [ ] **Step 3**: Verify rendering:
  ```
  make helm-lint
  helm template deploy/helm/openshell-driver-kyma --set driver.enableWorkspacePvc=true \
    --set driver.clientTlsSecretName=tls-test \
    | grep -E '(--enable-workspace-pvc|--client-tls-secret-name)'
  ```
- [ ] **Step 4**: Commit:
  ```
  git add deploy/helm/openshell-driver-kyma/
  git commit -s -m "feat(helm): expose hardening flags in values.yaml"
  ```

---

## Verification (end-to-end)

1. `make test` (unit + Tier 1/2) green.
2. `make test-integration INTEGRATION_TEST_NAMESPACE=openshell-driver-test` green; the existing `test_verify_supervisor_init_container` and `test_verify_labels_*` tests still pass; new tests for PVC and mTLS render correctly.
3. `helm template` with all new flags toggled on emits valid YAML; `helm lint` is clean.
4. The pod created by the driver in a non-`privileged` PSA-`baseline` namespace (separate test namespace, e.g. `openshell-driver-test-baseline`) FAILS at admission — confirms our caps-only approach still requires `pod-security.kubernetes.io/enforce: privileged` because of `runAsUser: 0` + `SYS_ADMIN`. (We do NOT downgrade the PSA requirement; we only narrow what we ask for inside the privileged tier.)

## Self-review checklist

- **Spec coverage**: addresses sections 2, 4, 5, 6, 8 of `upstream-sync-review.md`. Section 7 (`host_gateway_ip`) is deliberately left for a follow-up since it's deployment-topology-specific.
- **Placeholders**: each task has concrete code for the change being made plus concrete tests.
- **Type consistency**: `WatchEvent::PlatformEvent` is a struct variant with named fields used identically in the producer (provisioner) and consumer (driver). `metrics.platform_event(reason: &str)` is the only new metrics hook and has one call site.
