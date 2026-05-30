//! `KymaProvisioner` — `SandboxProvisioner` impl backed by `kube-rs`.
//!
//! Manages `agents.x-k8s.io/v1alpha1/Sandbox` CRs in a single namespace via
//! `kube::Api<DynamicObject>` (the CRD is third-party so we don't generate
//! a typed wrapper). The supervisor binary is delivered via init container
//! plus `emptyDir`, mirroring the Go OpenShift driver's approach (see
//! `docs/why-init-container.md`).
//!
//! Test strategy: the pure JSON construction in `build_sandbox_spec` is
//! covered by extensive unit tests. The HTTP-touching methods (`create`,
//! `get`, `list`, `delete`, `watch`, `has_gpu_capacity`) are exercised via
//! the Tier-3 live-cluster suite in `tests/live_cluster.rs`, since wiring a
//! mock `tower::Service` for `kube::Client` is non-trivial in kube 3.x and
//! the Tier-3 tests provide stronger guarantees.

use crate::config::Config;
use crate::error::DriverError;
use crate::helpers::{build_env_list, build_resources, merge_maps, object_to_driver_sandbox};
use crate::interfaces::{SandboxProvisioner, WatchEvent};
use async_trait::async_trait;
use computev1::pb::{DriverPlatformEvent, DriverSandbox};
use futures::{StreamExt, TryStreamExt};
use k8s_openapi::api::core::v1::{Event as CoreEvent, Node};
use kube::{
    api::{Api, ApiResource, DeleteParams, DynamicObject, ListParams, PostParams},
    core::GroupVersionKind,
    runtime::watcher,
    Client,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};

const LABEL_SANDBOX_ID: &str = "openshell.ai/sandbox-id";
const LABEL_MANAGED_BY: &str = "openshell.ai/managed-by";
const LABEL_KAGENTI: &str = "kagenti.io/type";
const LABEL_ISTIO_INJECT: &str = "sidecar.istio.io/inject";
// Pod annotation read by the gateway after a successful TokenReview to
// resolve a projected SA token's pod identity to a sandbox identity.
// Note the differing TLD vs LABEL_SANDBOX_ID: that's intentional, the
// upstream gateway uses `.io/` for annotations and `.ai/` for labels.
const ANNOTATION_SANDBOX_ID: &str = "openshell.io/sandbox-id";
const SUPERVISOR_VOLUME: &str = "supervisor-bin";
const AGENT_CONTAINER_NAME: &str = "agent";
const SUPERVISOR_INIT_NAME: &str = "supervisor-init";
const SANDBOX_SERVICE_ACCOUNT: &str = "openshell-sandbox";
const GPU_RESOURCE: &str = "nvidia.com/gpu";

// Projected ServiceAccount token. The supervisor exchanges this short-
// lived audience-bound JWT for a gateway-minted sandbox token via
// IssueSandboxToken at startup, then uses the gateway token for all
// subsequent gRPC calls. Without this volume the supervisor refuses to
// start with "no sandbox token source available".
const SA_TOKEN_VOLUME: &str = "openshell-sa-token";
const SA_TOKEN_MOUNT_PATH: &str = "/var/run/secrets/openshell";
const SA_TOKEN_AUDIENCE: &str = "openshell-gateway";
const SA_TOKEN_TTL_SECS: i64 = 3600;

/// `KymaProvisioner` implements `SandboxProvisioner` for SAP BTP Kyma.
pub struct KymaProvisioner {
    client: Client,
    cfg: Config,
    sandbox_ar: ApiResource,
}

impl KymaProvisioner {
    /// Build a provisioner around an existing `kube::Client` and `Config`.
    #[must_use]
    pub fn new(client: Client, cfg: Config) -> Self {
        let gvk = GroupVersionKind {
            group: "agents.x-k8s.io".into(),
            version: "v1alpha1".into(),
            kind: "Sandbox".into(),
        };
        let sandbox_ar = ApiResource::from_gvk_with_plural(&gvk, "sandboxes");
        Self {
            client,
            cfg,
            sandbox_ar,
        }
    }

    fn sandboxes_api(&self) -> Api<DynamicObject> {
        Api::namespaced_with(self.client.clone(), &self.cfg.namespace, &self.sandbox_ar)
    }

    /// Idempotent PVC create for a sandbox's workspace mount.
    ///
    /// Tolerates AlreadyExists (a previous create attempt succeeded but
    /// the Sandbox CR create or a follow-up step failed; second attempt
    /// finds the PVC waiting). All other API errors propagate.
    async fn ensure_workspace_pvc(&self, sandbox_name: &str) -> Result<(), DriverError> {
        let pvc_api: Api<k8s_openapi::api::core::v1::PersistentVolumeClaim> =
            Api::namespaced(self.client.clone(), &self.cfg.namespace);
        let claim_name = format!("{sandbox_name}-workspace");

        let mut spec = json!({
            "accessModes": ["ReadWriteOnce"],
            "resources": { "requests": { "storage": self.cfg.sandbox_storage_size } },
        });
        if !self.cfg.sandbox_storage_class.is_empty() {
            spec["storageClassName"] = Value::String(self.cfg.sandbox_storage_class.clone());
        }

        let pvc: k8s_openapi::api::core::v1::PersistentVolumeClaim =
            serde_json::from_value(json!({
                "apiVersion": "v1",
                "kind": "PersistentVolumeClaim",
                "metadata": {
                    "name": claim_name,
                    "namespace": self.cfg.namespace,
                    "labels": {
                        LABEL_MANAGED_BY: "openshell",
                        "openshell.ai/sandbox-name": sandbox_name,
                    },
                },
                "spec": spec,
            }))
            .map_err(|e| {
                DriverError::Internal(anyhow::anyhow!("workspace PVC manifest build failed: {e}"))
            })?;

        match pvc_api.create(&PostParams::default(), &pvc).await {
            Ok(_) => Ok(()),
            Err(kube::Error::Api(s)) if s.code == 409 => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    /// Build the Sandbox CR's `spec` JSON value. Pure function; no I/O.
    /// Mirrors the Go reference's `buildSandboxSpec` but adds Kyma-specific
    /// behavior: when `cfg.istio_inject_sandboxes` is false, stamps the
    /// `sidecar.istio.io/inject: "false"` label on the pod template so
    /// Istio leaves the pod alone.
    #[must_use]
    pub fn build_sandbox_spec(&self, sb: &DriverSandbox) -> Value {
        let spec = sb.spec.as_ref();
        let template = spec.and_then(|s| s.template.as_ref());

        // ---------- supervisor init container ----------
        // Upstream NVIDIA OpenShell publishes the supervisor as a distroless
        // image containing only the `openshell-sandbox` binary at `/`. There
        // is no `cp`, `sh`, or busybox to invoke, so the binary self-copies
        // via its `copy-self <dest>` subcommand. This mirrors the argoexec
        // emissary pattern and matches what the upstream Kubernetes driver
        // does. See crates/openshell-driver-kubernetes/src/driver.rs in
        // st-gr/OpenShell for the reference implementation.
        let installed_path = format!("{}/openshell-sandbox", self.cfg.supervisor_mount_path);
        let init_container = json!({
            "name": SUPERVISOR_INIT_NAME,
            "image": self.cfg.supervisor_image,
            "command": [
                self.cfg.supervisor_binary_path,
                "copy-self",
                installed_path,
            ],
            "volumeMounts": [
                {
                    "name": SUPERVISOR_VOLUME,
                    "mountPath": self.cfg.supervisor_mount_path,
                }
            ],
        });

        // ---------- agent container ----------
        let image = template.map(|t| t.image.as_str()).unwrap_or("");
        let env_list = self.build_full_env_list(sb);

        // With user namespaces enabled, drop `privileged: true` — the
        // capabilities below remain (they're namespaced) and the
        // container's UID 0 maps to a non-root host UID via the kubelet's
        // user-namespace remap. Without user namespaces, `privileged: true`
        // is required for the supervisor's Landlock + netns setup.
        let mut agent_container = json!({
            "name": AGENT_CONTAINER_NAME,
            "image": image,
            "command": [format!("{}/openshell-sandbox", self.cfg.supervisor_mount_path)],
            "env": env_list,
            "securityContext": {
                "privileged": !self.cfg.enable_user_namespaces,
                "runAsUser": 0,
                "capabilities": {
                    "add": ["SYS_ADMIN", "NET_ADMIN", "SYS_PTRACE", "SYSLOG"]
                }
            },
            "volumeMounts": [
                {
                    "name": SUPERVISOR_VOLUME,
                    "mountPath": self.cfg.supervisor_mount_path,
                    "readOnly": true,
                }
            ],
        });

        // Resources: use what the user asked for, or fall back to defaults
        // sized for typical Kyma namespace quotas.
        let resources = match template.and_then(|t| t.resources.as_ref()) {
            Some(res) => build_resources(res, spec.is_some_and(|s| s.gpu)),
            None => json!({
                "requests": { "cpu": "100m", "memory": "128Mi" },
                "limits":   { "cpu": "500m", "memory": "512Mi" },
            }),
        };
        agent_container["resources"] = resources;

        // Projected ServiceAccount token volume mount on the agent
        // container. The supervisor reads this file and exchanges it
        // for a gateway-minted JWT via IssueSandboxToken at startup.
        // Without this, the supervisor refuses to start with
        // "no sandbox token source available".
        let agent_mounts = agent_container["volumeMounts"]
            .as_array_mut()
            .expect("volumeMounts initialized above");
        agent_mounts.push(json!({
            "name": SA_TOKEN_VOLUME,
            "mountPath": SA_TOKEN_MOUNT_PATH,
            "readOnly": true,
        }));

        // ---------- pod spec ----------
        let mut pod_spec = json!({
            "initContainers": [init_container],
            "containers": [agent_container],
            "serviceAccountName": SANDBOX_SERVICE_ACCOUNT,
            "volumes": [
                {
                    "name": SUPERVISOR_VOLUME,
                    "emptyDir": {}
                },
                // kubelet writes a short-lived audience-bound JWT into
                // <SA_TOKEN_MOUNT_PATH>/token and rotates it automatically.
                {
                    "name": SA_TOKEN_VOLUME,
                    "projected": {
                        "sources": [{
                            "serviceAccountToken": {
                                "audience": SA_TOKEN_AUDIENCE,
                                "expirationSeconds": SA_TOKEN_TTL_SECS,
                                "path": "token"
                            }
                        }],
                        "defaultMode": 256
                    }
                }
            ],
        });

        // Optional per-sandbox workspace PVC mount. The PVC itself is
        // created (and deleted) by the create()/delete() methods; here
        // we just thread its name into the pod's `volumes` and the
        // agent container's `volumeMounts`.
        if !self.cfg.sandbox_storage_size.is_empty() {
            let claim_name = format!("{}-workspace", sb.name);
            let volumes = pod_spec["volumes"]
                .as_array_mut()
                .expect("volumes initialized above");
            volumes.push(json!({
                "name": "workspace",
                "persistentVolumeClaim": { "claimName": claim_name },
            }));
            let mounts = pod_spec["containers"][0]["volumeMounts"]
                .as_array_mut()
                .expect("agent volumeMounts initialized above");
            mounts.push(json!({
                "name": "workspace",
                "mountPath": "/sandbox",
            }));
        }

        // Linux user-namespace remap. K8s 1.30+ kubelet-managed UID/GID
        // mapping; container UID 0 lands on a non-root host UID. Pod
        // remains rootful from its own POV but loses host-root.
        if self.cfg.enable_user_namespaces {
            pod_spec["hostUsers"] = Value::Bool(false);
        }

        // Optional `runtimeClassName` passthrough from `platform_config`.
        if let Some(pc) = template.and_then(|t| t.platform_config.as_ref()) {
            if let Some(rcn) = pc.fields.get("runtime_class_name") {
                if let Some(s) = rcn.kind.as_ref().and_then(string_from_value_kind) {
                    pod_spec["runtimeClassName"] = Value::String(s);
                }
            }
        }

        // ---------- pod template metadata (labels) ----------
        let user_labels = template.map(|t| t.labels.clone()).unwrap_or_default();
        let mut driver_labels: HashMap<String, String> = HashMap::new();
        driver_labels.insert(LABEL_SANDBOX_ID.into(), sb.id.clone());
        driver_labels.insert(LABEL_MANAGED_BY.into(), "openshell".into());
        driver_labels.insert(LABEL_KAGENTI.into(), "agent".into());
        if !self.cfg.istio_inject_sandboxes {
            driver_labels.insert(LABEL_ISTIO_INJECT.into(), "false".into());
        }
        let labels = merge_maps(&user_labels, &driver_labels);

        // Annotations: the gateway's K8s SA bootstrap authenticator
        // resolves the supervisor's projected SA token to a sandbox-id
        // by reading this annotation on the pod after TokenReview. It
        // is set once at pod create and immutable for the lifetime of
        // the sandbox.
        let mut annotations: HashMap<String, String> = HashMap::new();
        annotations.insert(ANNOTATION_SANDBOX_ID.into(), sb.id.clone());

        json!({
            "podTemplate": {
                "metadata": {
                    "labels": labels,
                    "annotations": annotations,
                },
                "spec": pod_spec,
            }
        })
    }

    fn build_full_env_list(&self, sb: &DriverSandbox) -> Vec<Value> {
        let spec = sb.spec.as_ref();
        let template = spec.and_then(|s| s.template.as_ref());
        let spec_env = spec.map(|s| s.environment.clone()).unwrap_or_default();
        let tmpl_env = template.map(|t| t.environment.clone()).unwrap_or_default();

        let mut envs = build_env_list(&spec_env, &tmpl_env);

        // Driver-injected environment for the supervisor.
        let mut gw_env: HashMap<String, String> = HashMap::new();
        gw_env.insert("OPENSHELL_SANDBOX_ID".into(), sb.id.clone());
        gw_env.insert("OPENSHELL_SANDBOX".into(), sb.name.clone());
        gw_env.insert("OPENSHELL_SANDBOX_COMMAND".into(), "sleep infinity".into());
        // Path to the projected ServiceAccount token written by kubelet.
        // Pairs with the SA_TOKEN_VOLUME we mount in build_sandbox_spec.
        gw_env.insert(
            "OPENSHELL_K8S_SA_TOKEN_FILE".into(),
            format!("{SA_TOKEN_MOUNT_PATH}/token"),
        );
        // Filesystem path of the Unix socket the supervisor's embedded SSH
        // daemon binds. The supervisor only spawns its long-lived
        // supervisor_session control stream (which bridges
        // RelayStream traffic from the gateway -> exec/SSH inside the
        // sandbox) when this env var is set. Without it the gateway
        // returns "supervisor session not connected" on every exec call.
        // Matches the upstream Kubernetes driver's default; the agent
        // container runs privileged + UID 0 so it can create /run/openshell
        // itself, no extra mount needed.
        gw_env.insert(
            "OPENSHELL_SSH_SOCKET_PATH".into(),
            "/run/openshell/ssh.sock".into(),
        );
        if !self.cfg.gateway_endpoint.is_empty() {
            gw_env.insert(
                "OPENSHELL_ENDPOINT".into(),
                self.cfg.gateway_endpoint.clone(),
            );
        }
        gw_env.insert(
            "ANTHROPIC_BASE_URL".into(),
            "https://inference.local/v1".into(),
        );
        gw_env.insert(
            "OPENAI_BASE_URL".into(),
            "https://inference.local/v1".into(),
        );
        if self.cfg.disable_claude_telemetry {
            gw_env.insert(
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".into(),
                "1".into(),
            );
        }

        for (k, v) in gw_env {
            envs.push(json!({ "name": k, "value": v }));
        }
        // Stable order for deterministic tests.
        envs.sort_by(|a, b| {
            a["name"]
                .as_str()
                .unwrap_or("")
                .cmp(b["name"].as_str().unwrap_or(""))
        });
        envs
    }

    fn build_dynamic_object(&self, sb: &DriverSandbox) -> DynamicObject {
        let mut driver_labels: HashMap<String, String> = HashMap::new();
        driver_labels.insert(LABEL_SANDBOX_ID.into(), sb.id.clone());
        driver_labels.insert(LABEL_MANAGED_BY.into(), "openshell".into());
        driver_labels.insert(LABEL_KAGENTI.into(), "agent".into());

        let user_labels = sb
            .spec
            .as_ref()
            .and_then(|s| s.template.as_ref())
            .map(|t| t.labels.clone())
            .unwrap_or_default();
        let labels_map = merge_maps(&user_labels, &driver_labels);
        let labels: std::collections::BTreeMap<String, String> = labels_map
            .iter()
            .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
            .collect();

        let mut obj = DynamicObject::new(&sb.name, &self.sandbox_ar);
        obj.metadata.namespace = Some(self.cfg.namespace.clone());
        obj.metadata.labels = Some(labels);
        obj.data = json!({ "spec": self.build_sandbox_spec(sb) });
        obj
    }
}

fn string_from_value_kind(kind: &prost_types::value::Kind) -> Option<String> {
    match kind {
        prost_types::value::Kind::StringValue(s) => Some(s.clone()),
        _ => None,
    }
}

#[async_trait]
impl SandboxProvisioner for KymaProvisioner {
    async fn create(&self, sb: &DriverSandbox) -> Result<(), DriverError> {
        // When workspace persistence is configured, provision the PVC
        // before the Sandbox CR. The CR's pod template references the
        // PVC by claim name; if the PVC isn't there yet the agent-sandbox
        // controller's pod stays Pending until it appears. Failing here
        // is preferable to that visible-but-broken state.
        if !self.cfg.sandbox_storage_size.is_empty() {
            self.ensure_workspace_pvc(&sb.name).await?;
        }

        let obj = self.build_dynamic_object(sb);
        self.sandboxes_api()
            .create(&PostParams::default(), &obj)
            .await?;
        tracing::info!(
            sandbox_id = %sb.id,
            sandbox_name = %sb.name,
            namespace = %self.cfg.namespace,
            "sandbox CR created"
        );
        Ok(())
    }

    async fn delete(&self, name: &str) -> Result<(), DriverError> {
        let result = match self
            .sandboxes_api()
            .delete(name, &DeleteParams::default())
            .await
        {
            Ok(_) => Ok(()),
            Err(kube::Error::Api(s)) if s.code == 404 => {
                Err(DriverError::NotFound(name.to_string()))
            }
            Err(e) => Err(e.into()),
        };

        // Best-effort PVC cleanup. We tolerate 404 (PVC was never
        // created or already gone) and propagate other errors only when
        // the Sandbox CR delete itself succeeded — if both fail, the
        // Sandbox-CR error is the more actionable one.
        if !self.cfg.sandbox_storage_size.is_empty() {
            let pvc_api: Api<k8s_openapi::api::core::v1::PersistentVolumeClaim> =
                Api::namespaced(self.client.clone(), &self.cfg.namespace);
            let claim_name = format!("{name}-workspace");
            match pvc_api.delete(&claim_name, &DeleteParams::default()).await {
                Ok(_) => {}
                Err(kube::Error::Api(s)) if s.code == 404 => {}
                Err(e) if result.is_ok() => return Err(e.into()),
                Err(e) => {
                    tracing::warn!(error = %e, sandbox_name = %name, "PVC cleanup failed; sandbox-CR delete error takes precedence");
                }
            }
        }

        result
    }

    async fn get(&self, name: &str) -> Result<DriverSandbox, DriverError> {
        match self.sandboxes_api().get(name).await {
            Ok(obj) => Ok(object_to_driver_sandbox(&obj)),
            Err(kube::Error::Api(s)) if s.code == 404 => {
                Err(DriverError::NotFound(name.to_string()))
            }
            Err(e) => Err(e.into()),
        }
    }

    async fn list(&self) -> Result<Vec<DriverSandbox>, DriverError> {
        let lp = ListParams::default().labels(&format!("{LABEL_MANAGED_BY}=openshell"));
        let list = self.sandboxes_api().list(&lp).await?;
        Ok(list.items.iter().map(object_to_driver_sandbox).collect())
    }

    async fn watch(&self) -> Result<mpsc::Receiver<WatchEvent>, DriverError> {
        let api = self.sandboxes_api();
        let cfg = watcher::Config::default().labels(&format!("{LABEL_MANAGED_BY}=openshell"));

        let (tx, rx) = mpsc::channel::<WatchEvent>(64);

        // Shared cache populated by the Sandbox-CR watcher and read by the
        // Event watcher. Maps `<sandbox-name>` (the CR's metadata.name) to
        // the corresponding sandbox-id label value. K8s Events reference
        // their target by `involvedObject.name`; Sandbox CRs and pods both
        // share the CR's name, which gives us a single lookup path for
        // both involvedObject.kind=="Sandbox" and =="Pod".
        let name_to_id: Arc<RwLock<HashMap<String, String>>> =
            Arc::new(RwLock::new(HashMap::new()));

        // Sandbox CR watcher.
        let cr_tx = tx.clone();
        let cr_cache = Arc::clone(&name_to_id);
        tokio::spawn(async move {
            let mut stream = watcher(api, cfg).boxed();
            while let Ok(Some(ev)) = stream.try_next().await {
                use kube::runtime::watcher::Event;
                let event = match ev {
                    Event::Apply(obj) | Event::InitApply(obj) => {
                        let name = obj.metadata.name.clone().unwrap_or_default();
                        let id = obj
                            .metadata
                            .labels
                            .as_ref()
                            .and_then(|l| l.get(LABEL_SANDBOX_ID).cloned())
                            .unwrap_or_default();
                        if !name.is_empty() && !id.is_empty() {
                            cr_cache.write().await.insert(name, id);
                        }
                        WatchEvent::Updated(Box::new(object_to_driver_sandbox(&obj)))
                    }
                    Event::Delete(obj) => {
                        let name = obj.metadata.name.clone().unwrap_or_default();
                        let id = obj
                            .metadata
                            .labels
                            .as_ref()
                            .and_then(|l| l.get(LABEL_SANDBOX_ID).cloned())
                            .unwrap_or_default();
                        if !name.is_empty() {
                            cr_cache.write().await.remove(&name);
                        }
                        WatchEvent::Deleted(id)
                    }
                    Event::Init | Event::InitDone => continue,
                };
                if cr_tx.send(event).await.is_err() {
                    break;
                }
            }
        });

        // Kubernetes Event watcher — surfaces pod-scheduling failures,
        // image pull errors, volume mount failures, and similar Warning
        // Events as platform-level WatchSandboxes events. Filtered to
        // `type=Warning` so Normal Events (cluster heartbeat, lifecycle
        // milestones) don't drown the stream.
        let events_api: Api<CoreEvent> = Api::namespaced(self.client.clone(), &self.cfg.namespace);
        let ev_tx = tx;
        let ev_cache = name_to_id;
        tokio::spawn(async move {
            // Field selector only takes simple comparisons; type=Warning
            // is supported on the Event resource.
            let cfg = watcher::Config::default().fields("type=Warning");
            let mut stream = watcher(events_api, cfg).boxed();
            while let Ok(Some(ev)) = stream.try_next().await {
                use kube::runtime::watcher::Event;
                let core_ev = match ev {
                    Event::Apply(e) | Event::InitApply(e) => e,
                    Event::Delete(_) | Event::Init | Event::InitDone => continue,
                };
                let involved = &core_ev.involved_object;
                let kind = involved.kind.as_deref().unwrap_or("");
                if kind != "Sandbox" && kind != "Pod" {
                    continue;
                }
                let Some(name) = involved.name.as_ref() else {
                    continue;
                };
                let sandbox_id = match ev_cache.read().await.get(name) {
                    Some(id) => id.clone(),
                    None => continue,
                };
                let platform_event = DriverPlatformEvent {
                    timestamp_ms: core_ev
                        .last_timestamp
                        .as_ref()
                        .map(|t| t.0.as_millisecond())
                        .unwrap_or(0),
                    source: "kubernetes".to_string(),
                    r#type: core_ev.type_.clone().unwrap_or_default(),
                    reason: core_ev.reason.clone().unwrap_or_default(),
                    message: core_ev.message.clone().unwrap_or_default(),
                    metadata: HashMap::from([("involvedKind".to_string(), kind.to_string())]),
                };
                let out = WatchEvent::Platform {
                    sandbox_id,
                    event: Box::new(platform_event),
                };
                if ev_tx.send(out).await.is_err() {
                    break;
                }
            }
        });

        Ok(rx)
    }

    async fn validate_create(&self, sb: &DriverSandbox) -> Result<(), DriverError> {
        if let Some(spec) = sb.spec.as_ref() {
            if spec.gpu {
                let ok = self.has_gpu_capacity().await?;
                if !ok {
                    return Err(DriverError::FailedPrecondition(format!(
                        "no nodes with {GPU_RESOURCE} allocatable in the cluster"
                    )));
                }
            }
        }
        Ok(())
    }

    async fn has_gpu_capacity(&self) -> Result<bool, DriverError> {
        if !self.cfg.gpu_support {
            return Ok(false);
        }
        let nodes: Api<Node> = Api::all(self.client.clone());
        let list = nodes.list(&ListParams::default()).await?;
        for node in list.items {
            if let Some(alloc) = node.status.as_ref().and_then(|s| s.allocatable.as_ref()) {
                if let Some(q) = alloc.get(GPU_RESOURCE) {
                    if q.0 != "0" {
                        return Ok(true);
                    }
                }
            }
        }
        Ok(false)
    }

    async fn apply_apirule(&self, manifest: serde_json::Value) -> Result<(), DriverError> {
        let gvk = GroupVersionKind {
            group: "gateway.kyma-project.io".into(),
            version: "v2".into(),
            kind: "APIRule".into(),
        };
        let ar = ApiResource::from_gvk_with_plural(&gvk, "apirules");
        let api: Api<DynamicObject> =
            Api::namespaced_with(self.client.clone(), &self.cfg.namespace, &ar);

        let name = manifest
            .pointer("/metadata/name")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let mut obj = DynamicObject::new(name, &ar);
        obj.metadata.namespace = Some(self.cfg.namespace.clone());
        if let Some(labels) = manifest
            .pointer("/metadata/labels")
            .and_then(|v| v.as_object())
        {
            obj.metadata.labels = Some(
                labels
                    .iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                    .collect(),
            );
        }
        if let Some(spec) = manifest.get("spec") {
            obj.data = serde_json::json!({ "spec": spec });
        }

        api.create(&PostParams::default(), &obj).await?;
        tracing::info!(
            apirule = %name,
            namespace = %self.cfg.namespace,
            "APIRule created"
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use computev1::pb::{DriverSandbox, DriverSandboxSpec, DriverSandboxTemplate};

    fn make_provisioner() -> KymaProvisioner {
        let cfg = Config {
            namespace: "test-ns".into(),
            ..Config::default()
        };
        // Construct a Client pointed at a placeholder; tests only call
        // pure methods (build_sandbox_spec, build_dynamic_object).
        let svc = tower::service_fn(|_req: http::Request<kube::client::Body>| async move {
            Ok::<_, std::convert::Infallible>(http::Response::new(kube::client::Body::empty()))
        });
        let client = Client::new(svc, "test-ns");
        KymaProvisioner::new(client, cfg)
    }

    fn make_sandbox(id: &str, name: &str, image: &str) -> DriverSandbox {
        DriverSandbox {
            id: id.into(),
            name: name.into(),
            spec: Some(DriverSandboxSpec {
                template: Some(DriverSandboxTemplate {
                    image: image.into(),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn build_sandbox_spec_includes_supervisor_init_container() {
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "create-test", "agent:latest");
        let spec = p.build_sandbox_spec(&sb);

        let init = &spec["podTemplate"]["spec"]["initContainers"][0];
        assert_eq!(init["name"], "supervisor-init");
        assert_eq!(init["image"], p.cfg.supervisor_image);
        // The distroless supervisor image has no `cp`; the binary self-
        // copies via its `copy-self <dest>` subcommand.
        assert_eq!(init["command"][0], p.cfg.supervisor_binary_path);
        assert_eq!(init["command"][1], "copy-self");
        assert_eq!(
            init["command"][2],
            format!("{}/openshell-sandbox", p.cfg.supervisor_mount_path)
        );
    }

    #[tokio::test]
    async fn build_sandbox_spec_agent_container_runs_supervisor() {
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "create-test", "myimage:1.2");
        let spec = p.build_sandbox_spec(&sb);

        let c = &spec["podTemplate"]["spec"]["containers"][0];
        assert_eq!(c["name"], "agent");
        assert_eq!(c["image"], "myimage:1.2");
        assert_eq!(
            c["command"][0],
            format!("{}/openshell-sandbox", p.cfg.supervisor_mount_path)
        );
    }

    #[tokio::test]
    async fn build_sandbox_spec_security_context_has_required_caps() {
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "x", "img");
        let spec = p.build_sandbox_spec(&sb);

        let sc = &spec["podTemplate"]["spec"]["containers"][0]["securityContext"];
        assert_eq!(sc["privileged"], true);
        assert_eq!(sc["runAsUser"], 0);
        let caps: Vec<&str> = sc["capabilities"]["add"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert_eq!(caps, vec!["SYS_ADMIN", "NET_ADMIN", "SYS_PTRACE", "SYSLOG"]);
        // Pod-level hostUsers is unset (i.e., default — host UID namespace).
        assert!(spec["podTemplate"]["spec"].get("hostUsers").is_none());
    }

    #[tokio::test]
    async fn build_sandbox_spec_user_namespaces_drops_privileged() {
        let cfg = Config {
            namespace: "test-ns".into(),
            enable_user_namespaces: true,
            ..Config::default()
        };
        let svc = tower::service_fn(|_req: http::Request<kube::client::Body>| async move {
            Ok::<_, std::convert::Infallible>(http::Response::new(kube::client::Body::empty()))
        });
        let p = KymaProvisioner::new(Client::new(svc, "test-ns"), cfg);
        let sb = make_sandbox("sb-1", "x", "img");
        let spec = p.build_sandbox_spec(&sb);

        let sc = &spec["podTemplate"]["spec"]["containers"][0]["securityContext"];
        assert_eq!(
            sc["privileged"], false,
            "privileged should be dropped when user namespaces are enabled"
        );
        // runAsUser stays at 0 — UID 0 inside the namespace remaps to a
        // non-root host UID via kubelet, which is the whole point.
        assert_eq!(sc["runAsUser"], 0);
        // The capabilities-add set is unchanged (they're namespaced).
        let caps: Vec<&str> = sc["capabilities"]["add"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert_eq!(caps, vec!["SYS_ADMIN", "NET_ADMIN", "SYS_PTRACE", "SYSLOG"]);
        // Pod-level hostUsers: false signals the kubelet to set up a UID/
        // GID remap for this pod.
        assert_eq!(spec["podTemplate"]["spec"]["hostUsers"], false);
    }

    #[tokio::test]
    async fn build_sandbox_spec_emptydir_volume_mounted_readonly() {
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "x", "img");
        let spec = p.build_sandbox_spec(&sb);

        let vol = &spec["podTemplate"]["spec"]["volumes"][0];
        assert_eq!(vol["name"], "supervisor-bin");
        assert!(vol.get("emptyDir").is_some());
        let mount = &spec["podTemplate"]["spec"]["containers"][0]["volumeMounts"][0];
        assert_eq!(mount["name"], "supervisor-bin");
        assert_eq!(mount["readOnly"], true);
    }

    #[tokio::test]
    async fn build_sandbox_spec_no_workspace_volume_when_storage_disabled() {
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "x", "img");
        let spec = p.build_sandbox_spec(&sb);

        let vols = spec["podTemplate"]["spec"]["volumes"].as_array().unwrap();
        assert!(
            !vols.iter().any(|v| v["name"] == "workspace"),
            "workspace volume should not appear when sandbox_storage_size is empty"
        );
    }

    #[tokio::test]
    async fn build_sandbox_spec_workspace_volume_when_storage_set() {
        let cfg = Config {
            namespace: "test-ns".into(),
            sandbox_storage_size: "5Gi".to_string(),
            ..Config::default()
        };
        let svc = tower::service_fn(|_req: http::Request<kube::client::Body>| async move {
            Ok::<_, std::convert::Infallible>(http::Response::new(kube::client::Body::empty()))
        });
        let p = KymaProvisioner::new(Client::new(svc, "test-ns"), cfg);
        let sb = make_sandbox("sb-1", "my-sandbox", "img");
        let spec = p.build_sandbox_spec(&sb);

        let vols = spec["podTemplate"]["spec"]["volumes"].as_array().unwrap();
        let ws = vols.iter().find(|v| v["name"] == "workspace").unwrap();
        assert_eq!(
            ws["persistentVolumeClaim"]["claimName"],
            "my-sandbox-workspace"
        );

        let mounts = spec["podTemplate"]["spec"]["containers"][0]["volumeMounts"]
            .as_array()
            .unwrap();
        let m = mounts.iter().find(|m| m["name"] == "workspace").unwrap();
        assert_eq!(m["mountPath"], "/sandbox");
    }

    #[tokio::test]
    async fn build_sandbox_spec_service_account_pinned() {
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "x", "img");
        let spec = p.build_sandbox_spec(&sb);
        assert_eq!(
            spec["podTemplate"]["spec"]["serviceAccountName"],
            "openshell-sandbox"
        );
    }

    #[tokio::test]
    async fn build_sandbox_spec_default_labels_present() {
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "x", "img");
        let spec = p.build_sandbox_spec(&sb);
        let labels = &spec["podTemplate"]["metadata"]["labels"];
        assert_eq!(labels["openshell.ai/sandbox-id"], "sb-1");
        assert_eq!(labels["openshell.ai/managed-by"], "openshell");
        assert_eq!(labels["kagenti.io/type"], "agent");
    }

    #[tokio::test]
    async fn istio_inject_label_set_when_disabled() {
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "x", "img");
        let spec = p.build_sandbox_spec(&sb);
        assert_eq!(
            spec["podTemplate"]["metadata"]["labels"]["sidecar.istio.io/inject"],
            "false"
        );
    }

    #[tokio::test]
    async fn istio_inject_label_absent_when_enabled() {
        let cfg = Config {
            namespace: "test-ns".into(),
            istio_inject_sandboxes: true,
            ..Config::default()
        };
        let svc = tower::service_fn(|_req: http::Request<kube::client::Body>| async move {
            Ok::<_, std::convert::Infallible>(http::Response::new(kube::client::Body::empty()))
        });
        let client = Client::new(svc, "test-ns");
        let p = KymaProvisioner::new(client, cfg);
        let sb = make_sandbox("sb-1", "x", "img");
        let spec = p.build_sandbox_spec(&sb);
        assert!(spec["podTemplate"]["metadata"]["labels"]
            .get("sidecar.istio.io/inject")
            .is_none());
    }

    #[tokio::test]
    async fn user_labels_merged_with_driver_labels() {
        let p = make_provisioner();
        let mut sb = make_sandbox("sb-1", "x", "img");
        sb.spec.as_mut().unwrap().template.as_mut().unwrap().labels =
            [("custom".to_string(), "user".to_string())]
                .into_iter()
                .collect();
        let spec = p.build_sandbox_spec(&sb);
        let labels = &spec["podTemplate"]["metadata"]["labels"];
        assert_eq!(labels["custom"], "user");
        assert_eq!(labels["openshell.ai/sandbox-id"], "sb-1");
    }

    #[tokio::test]
    async fn default_resources_injected_when_template_omits_resources() {
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "x", "img");
        let spec = p.build_sandbox_spec(&sb);
        let res = &spec["podTemplate"]["spec"]["containers"][0]["resources"];
        assert_eq!(res["requests"]["cpu"], "100m");
        assert_eq!(res["requests"]["memory"], "128Mi");
        assert_eq!(res["limits"]["cpu"], "500m");
        assert_eq!(res["limits"]["memory"], "512Mi");
    }

    #[tokio::test]
    async fn explicit_resources_passed_through() {
        let p = make_provisioner();
        let mut sb = make_sandbox("sb-1", "x", "img");
        sb.spec
            .as_mut()
            .unwrap()
            .template
            .as_mut()
            .unwrap()
            .resources = Some(computev1::pb::DriverResourceRequirements {
            cpu_request: "200m".into(),
            memory_request: "256Mi".into(),
            cpu_limit: "1".into(),
            memory_limit: "1Gi".into(),
        });
        let spec = p.build_sandbox_spec(&sb);
        let res = &spec["podTemplate"]["spec"]["containers"][0]["resources"];
        assert_eq!(res["requests"]["cpu"], "200m");
        assert_eq!(res["limits"]["memory"], "1Gi");
    }

    #[tokio::test]
    async fn driver_injected_env_present() {
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "create-test", "img");
        let spec = p.build_sandbox_spec(&sb);
        let env = spec["podTemplate"]["spec"]["containers"][0]["env"]
            .as_array()
            .unwrap();
        let names: Vec<&str> = env.iter().map(|e| e["name"].as_str().unwrap()).collect();
        assert!(names.contains(&"OPENSHELL_SANDBOX_ID"));
        assert!(names.contains(&"OPENSHELL_SANDBOX"));
        assert!(names.contains(&"ANTHROPIC_BASE_URL"));
        assert!(names.contains(&"OPENAI_BASE_URL"));
    }

    #[tokio::test]
    async fn driver_injected_env_with_telemetry_disabled() {
        let cfg = Config {
            disable_claude_telemetry: true,
            ..Config::default()
        };
        let svc = tower::service_fn(|_req: http::Request<kube::client::Body>| async move {
            Ok::<_, std::convert::Infallible>(http::Response::new(kube::client::Body::empty()))
        });
        let client = Client::new(svc, "test-ns");
        let p = KymaProvisioner::new(client, cfg);
        let sb = make_sandbox("sb-1", "tel-test", "img");
        let spec = p.build_sandbox_spec(&sb);
        let env = spec["podTemplate"]["spec"]["containers"][0]["env"]
            .as_array()
            .unwrap();
        let names: Vec<&str> = env.iter().map(|e| e["name"].as_str().unwrap()).collect();
        assert!(names.contains(&"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"));
        // Sanity: existing pseudo-endpoint env vars still present.
        assert!(names.contains(&"ANTHROPIC_BASE_URL"));
        assert!(names.contains(&"OPENAI_BASE_URL"));
    }

    #[tokio::test]
    async fn driver_injected_env_telemetry_disabled_off_by_default() {
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "tel-default", "img");
        let spec = p.build_sandbox_spec(&sb);
        let env = spec["podTemplate"]["spec"]["containers"][0]["env"]
            .as_array()
            .unwrap();
        let names: Vec<&str> = env.iter().map(|e| e["name"].as_str().unwrap()).collect();
        assert!(!names.contains(&"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"));
    }

    #[tokio::test]
    async fn has_gpu_capacity_short_circuits_when_flag_disabled() {
        let cfg = Config {
            namespace: "test-ns".into(),
            gpu_support: false,
            ..Config::default()
        };
        let svc = tower::service_fn(|_req: http::Request<kube::client::Body>| async move {
            Ok::<_, std::convert::Infallible>(http::Response::new(kube::client::Body::empty()))
        });
        let client = Client::new(svc, "test-ns");
        let p = KymaProvisioner::new(client, cfg);
        // No HTTP request is made because the flag short-circuits.
        assert!(!p.has_gpu_capacity().await.unwrap());
    }

    #[tokio::test]
    async fn validate_create_passes_when_no_gpu_requested() {
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "x", "img");
        // gpu=false in the spec; no node check should be needed.
        p.validate_create(&sb).await.unwrap();
    }
}
