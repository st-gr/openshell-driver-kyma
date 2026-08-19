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
use crate::helpers::{
    build_env_list, build_resources, effective_gpu_count, merge_maps, object_to_driver_sandbox,
};
use crate::interfaces::{SandboxProvisioner, WatchEvent};
use async_trait::async_trait;
use computev1::pb::{DriverPlatformEvent, DriverSandbox};
use futures::{StreamExt, TryStreamExt};
use k8s_openapi::api::core::v1::{Event as CoreEvent, Namespace, Node, ServiceAccount};
use kube::{
    api::{
        Api, ApiResource, DeleteParams, DynamicObject, ListParams, Patch, PatchParams, PostParams,
        Preconditions,
    },
    core::GroupVersionKind,
    runtime::watcher,
    Client,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};

// Identity labels. Re-exported from `helpers` so the CR writer and the CR
// reader (`object_to_driver_sandbox`) can never drift apart.
use crate::helpers::{
    LABEL_GATEWAY_ID, LABEL_MANAGED_BY, LABEL_MANAGED_BY_VALUE, LABEL_SANDBOX_ID,
    LABEL_SANDBOX_NAME, LABEL_SANDBOX_NAMESPACE, LABEL_SANDBOX_WORKSPACE,
};
use crate::workspace::WorkspaceMode;

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
//
// This is also why `DriverSandboxSpec.sandbox_token` (added upstream in
// v0.0.91, marked `[(openshell.options.v1.secret) = true]`) is deliberately
// never read here: writing it into the pod spec would persist a bearer token
// in an object readable by anyone with `get sandbox` in the namespace, and
// it would outlive its rotation. The upstream Kubernetes driver ignores it
// for the same reason. Nothing in this crate logs a whole DriverSandbox or
// DriverSandboxSpec either — every tracing call names scalar fields
// explicitly — so the secret cannot reach the logs by accident.
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

    /// Namespace a sandbox in `workspace` lives in, under the configured mode.
    fn namespace_for_workspace(&self, workspace: &str) -> Result<String, DriverError> {
        crate::workspace::namespace_for(&self.cfg, workspace)
    }

    /// Sandbox-CR API scoped to `ns`, or cluster-wide when `None`.
    fn sandboxes_api_for(&self, ns: Option<&str>) -> Api<DynamicObject> {
        match ns {
            Some(ns) => Api::namespaced_with(self.client.clone(), ns, &self.sandbox_ar),
            None => Api::all_with(self.client.clone(), &self.sandbox_ar),
        }
    }

    /// Namespace to search when only a sandbox id is known.
    ///
    /// `GetSandboxRequest` and `DeleteSandboxRequest` carry no workspace, so
    /// in `Shared` mode there is exactly one namespace to look in, and in the
    /// other modes there are many — hence the cluster-wide fallback, which
    /// the mode's ClusterRole permits.
    fn id_lookup_namespace(&self) -> Option<String> {
        match self.cfg.workspace_mode {
            WorkspaceMode::Shared => Some(self.cfg.namespace.clone()),
            WorkspaceMode::Managed | WorkspaceMode::Operator => None,
        }
    }

    /// Look a Sandbox CR up by its `openshell.ai/sandbox-id` label.
    ///
    /// The gateway addresses sandboxes by id and by *bare* name; it has no
    /// concept of our `{workspace}--{name}` object naming. The id label is
    /// therefore the only handle that survives the rename, which is why
    /// `get`/`delete` resolve through here instead of doing a direct name
    /// lookup. This mirrors the upstream Kubernetes driver.
    ///
    /// The returned object's own `metadata.namespace` is the source of truth
    /// for where the CR actually lives — callers that need to act on it
    /// again (patch, delete, find its pod) must read that field rather than
    /// re-deriving a namespace from `cfg`, or they silently target the wrong
    /// namespace under `Managed`/`Operator`.
    async fn find_by_sandbox_id(&self, sandbox_id: &str) -> Result<DynamicObject, DriverError> {
        let lp = ListParams::default().labels(&format!(
            "{LABEL_MANAGED_BY}={LABEL_MANAGED_BY_VALUE},{LABEL_SANDBOX_ID}={sandbox_id}"
        ));
        let ns = self.id_lookup_namespace();
        let list = self.sandboxes_api_for(ns.as_deref()).list(&lp).await?;
        list.items
            .into_iter()
            .next()
            .ok_or_else(|| DriverError::NotFound(sandbox_id.to_string()))
    }

    /// Resolve a sandbox id to its CR's Kubernetes object name and the
    /// namespace it actually lives in, per `find_by_sandbox_id`'s contract.
    async fn resolve_cr_location(&self, sandbox_id: &str) -> Result<(String, String), DriverError> {
        let obj = self.find_by_sandbox_id(sandbox_id).await?;
        let name = obj
            .metadata
            .name
            .clone()
            .ok_or_else(|| DriverError::NotFound(sandbox_id.to_string()))?;
        let namespace = obj
            .metadata
            .namespace
            .clone()
            .ok_or_else(|| DriverError::NotFound(sandbox_id.to_string()))?;
        Ok((name, namespace))
    }

    /// Patch the CR's operating state, carrying its resourceVersion as an
    /// optimistic-concurrency precondition.
    async fn patch_operating_state(
        &self,
        sandbox_id: &str,
        running: bool,
    ) -> Result<(), DriverError> {
        let obj = self.find_by_sandbox_id(sandbox_id).await?;
        let kube_name = obj
            .metadata
            .name
            .clone()
            .ok_or_else(|| DriverError::NotFound(sandbox_id.to_string()))?;
        let namespace = obj
            .metadata
            .namespace
            .clone()
            .ok_or_else(|| DriverError::NotFound(sandbox_id.to_string()))?;
        let resource_version = obj
            .metadata
            .resource_version
            .clone()
            .ok_or_else(|| DriverError::NotFound(sandbox_id.to_string()))?;

        // The CR's own apiVersion decides the payload shape. Reading it from
        // the object rather than assuming keeps this correct when the CRD
        // starts serving a newer version.
        let api_version = obj
            .types
            .as_ref()
            .and_then(|t| t.api_version.rsplit('/').next().map(str::to_string))
            .unwrap_or_else(|| crate::lifecycle::SANDBOX_V1ALPHA1.to_string());

        let patch =
            crate::lifecycle::operating_state_patch(&api_version, &resource_version, running);
        // Patch in the namespace the CR was actually found in, not
        // `cfg.namespace` — under `Managed`/`Operator` those can differ.
        self.sandboxes_api_for(Some(&namespace))
            .patch(&kube_name, &PatchParams::default(), &Patch::Merge(&patch))
            .await?;
        Ok(())
    }

    /// Poll until the sandbox's pod is gone, bounded by `stop_timeout_secs`.
    ///
    /// Assumes the agent-sandbox controller names the pod identically to the
    /// Sandbox CR (`kube_name` below is the CR's own name). If the
    /// controller ever named pods differently, `pod_api.get(&kube_name)`
    /// would 404 immediately, this function would return `Ok(())`, and
    /// `StopSandbox` would report success while the pod kept running —
    /// silently, and exactly the failure this poll exists to prevent.
    ///
    /// Verified empirically against a live cluster (not by test): pod
    /// `default--hello4`'s `ownerReferences` name the Sandbox CR
    /// `default--hello4` — same name. No automated test covers this
    /// assumption, because neither `scripts/interop-smoke.sh` nor the
    /// managed-mode smoke runs the agent-sandbox controller.
    async fn await_pod_gone(&self, sandbox_id: &str) -> Result<(), DriverError> {
        let deadline =
            std::time::Instant::now() + std::time::Duration::from_secs(self.cfg.stop_timeout_secs);

        loop {
            // Re-resolved every iteration (as before), and now also gives us
            // the CR's actual namespace so the Pod lookup below targets the
            // same namespace the CR — and therefore its pod — lives in,
            // rather than `cfg.namespace`.
            let (kube_name, namespace) = match self.find_by_sandbox_id(sandbox_id).await {
                Ok(o) => {
                    let name = o.metadata.name.clone().unwrap_or_default();
                    let ns = o
                        .metadata
                        .namespace
                        .clone()
                        .ok_or_else(|| DriverError::NotFound(sandbox_id.to_string()))?;
                    (name, ns)
                }
                // The CR vanished mid-stop; nothing left to wait for.
                Err(DriverError::NotFound(_)) => return Ok(()),
                Err(e) => return Err(e),
            };
            let pod_api: Api<k8s_openapi::api::core::v1::Pod> =
                Api::namespaced(self.client.clone(), &namespace);
            match pod_api.get(&kube_name).await {
                Err(kube::Error::Api(s)) if s.code == 404 => return Ok(()),
                Err(e) => return Err(e.into()),
                Ok(_) => {}
            }
            if std::time::Instant::now() >= deadline {
                return Err(DriverError::FailedPrecondition(format!(
                    "timed out after {}s waiting for sandbox {sandbox_id} to stop",
                    self.cfg.stop_timeout_secs
                )));
            }
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
    }

    /// Idempotent PVC create for a sandbox's `/workspace` mount.
    ///
    /// The claim is named from the *Kubernetes* object name
    /// (`{workspace}--{name}`), not the bare sandbox name, so two sandboxes
    /// sharing a name across OpenShell workspaces get distinct claims. Note
    /// the two unrelated senses of "workspace" here: the OpenShell tenancy
    /// boundary (part of the name) and the pod's `/workspace` mount (the
    /// `-workspace` suffix).
    ///
    /// Tolerates AlreadyExists (a previous create attempt succeeded but
    /// the Sandbox CR create or a follow-up step failed; second attempt
    /// finds the PVC waiting). All other API errors propagate.
    async fn ensure_sandbox_pvc(
        &self,
        sb: &DriverSandbox,
        namespace: &str,
    ) -> Result<(), DriverError> {
        let pvc_api: Api<k8s_openapi::api::core::v1::PersistentVolumeClaim> =
            Api::namespaced(self.client.clone(), namespace);
        let claim_name = format!(
            "{}-workspace",
            crate::workspace::kube_resource_name(self.cfg.workspace_mode, &sb.workspace, &sb.name)
        );

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
                    "namespace": namespace,
                    "labels": {
                        LABEL_MANAGED_BY: LABEL_MANAGED_BY_VALUE,
                        LABEL_SANDBOX_ID: sb.id,
                        LABEL_SANDBOX_NAME: sb.name,
                        LABEL_SANDBOX_WORKSPACE: sb.workspace,
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

    /// Create everything a sandbox needs in a managed workspace namespace.
    ///
    /// Steps 2 and 3 have no upstream counterpart. They are required here
    /// because this driver hard-depends on them: `verify_psa_label` fails
    /// without the PSA label, and `SANDBOX_SERVICE_ACCOUNT` is pinned into
    /// every pod spec, so a bare namespace produces pods that never start.
    ///
    /// Deliberately does **not** create a NetworkPolicy. The chart's sandbox
    /// NetworkPolicy (`templates/networkpolicy.yaml`) depends on Helm-only
    /// inputs — `.Values.gateway.*`, `.Release.Namespace`/`.Release.Name`,
    /// the `selectorLabels` helper, the `gatewayUpstreamEgress`/
    /// `bedrockBridge` blocks — none of which exist in `Config`. Porting it
    /// here would mean maintaining the same security policy in two
    /// languages that must never drift, and drift would mean a managed
    /// namespace silently getting weaker isolation than the shared one.
    /// Instead, `main.rs` refuses to start when `--workspace-mode managed`
    /// is combined with `--enable-network-policy=true`, so this gap is
    /// loud, not silent.
    async fn bootstrap_managed_namespace(&self, workspace: &str) -> Result<(), DriverError> {
        // Routed through `namespace_for_workspace` rather than calling
        // `managed_namespace` directly (same value under `Managed`) so this
        // gets `namespace_for`'s DNS-1123 charset check on `workspace`
        // before it becomes part of a namespace name — see that function's
        // doc comment for why every workspace-to-namespace path must go
        // through it.
        let ns = self.namespace_for_workspace(workspace)?;

        // 1 + 2: namespace, carrying both the ownership labels
        // `namespace_owned_by` (and a future DeleteWorkspace teardown)
        // check, and the PSA label sandbox pods need. The payload is built
        // by a pure function so it can be unit tested without a cluster.
        let ns_obj: Namespace =
            serde_json::from_value(managed_namespace_object(&self.cfg.gateway_id, workspace))
                .map_err(|e| {
                    DriverError::Internal(anyhow::anyhow!(
                        "managed namespace manifest build failed: {e}"
                    ))
                })?;
        self.create_or_verify_managed_namespace(&ns, workspace, ns_obj)
            .await?;

        // 3: the ServiceAccount every sandbox pod spec names.
        let sa_obj = serde_json::from_value(sandbox_service_account_object(&ns)).map_err(|e| {
            DriverError::Internal(anyhow::anyhow!(
                "sandbox service account manifest build failed: {e}"
            ))
        })?;
        create_tolerating_conflict(
            &Api::<ServiceAccount>::namespaced(self.client.clone(), &ns),
            sa_obj,
        )
        .await?;

        // Post-condition, not a precondition: the label was just applied, so a
        // failure here means something stripped it (e.g. a policy webhook).
        self.verify_psa_label(&ns).await?;
        Ok(())
    }

    /// Create the managed namespace, or — if one with this name already
    /// exists — confirm this driver is the one that owns it before doing
    /// anything else inside it.
    ///
    /// `crate::workspace::managed_namespace` joins `gateway_id` and
    /// `workspace` with a single dash to match upstream's naming
    /// convention (`openshell-{gateway_id}-{workspace}`), which means two
    /// distinct `(gateway_id, workspace)` pairs can derive the same
    /// namespace name — e.g. `("a", "b-c")` and `("a-b", "c")` both give
    /// `openshell-a-b-c`. A plain `AlreadyExists`-tolerant create (as used
    /// for the ServiceAccount below) would silently *adopt* whatever
    /// namespace is already there, including one created by a different,
    /// colliding gateway, and go on to place this gateway's ServiceAccount
    /// and tenant sandboxes inside it. That is the one state a retry
    /// cannot repair, since nothing else ever writes ownership labels onto
    /// a namespace that already existed — so on 409 this reads the
    /// namespace back and requires `namespace_owned_by` to hold before
    /// proceeding, rather than tolerating the conflict unconditionally.
    async fn create_or_verify_managed_namespace(
        &self,
        namespace: &str,
        workspace: &str,
        obj: Namespace,
    ) -> Result<(), DriverError> {
        let api: Api<Namespace> = Api::all(self.client.clone());
        match api.create(&PostParams::default(), &obj).await {
            Ok(_) => Ok(()),
            Err(kube::Error::Api(e)) if e.code == 409 => {
                let existing = api.get(namespace).await?;
                if namespace_owned_by(&existing, &self.cfg.gateway_id, workspace) {
                    Ok(())
                } else {
                    Err(DriverError::FailedPrecondition(format!(
                        "namespace {namespace} already exists but is not owned by this driver \
                         for gateway_id={gw:?} workspace={workspace:?} (expected labels \
                         {LABEL_MANAGED_BY}={LABEL_MANAGED_BY_VALUE}, {LABEL_GATEWAY_ID}={gw:?}, \
                         {LABEL_SANDBOX_WORKSPACE}={workspace:?}; found {found:?}). Refusing to \
                         place a ServiceAccount or sandboxes in a namespace this driver did not \
                         create — this can happen when two gateway_id/workspace pairs derive the \
                         same namespace name (managed_namespace joins them with a single dash).",
                        gw = self.cfg.gateway_id,
                        found = existing.metadata.labels.clone().unwrap_or_default(),
                    )))
                }
            }
            Err(e) => Err(DriverError::Kube(e)),
        }
    }

    /// Confirm a namespace carries the PSA label sandbox pods require.
    ///
    /// In `Managed` this is a POST-condition: `bootstrap_managed_namespace`
    /// just applied the label, so a failure here means something stripped it
    /// (a policy webhook, say). In `Operator` this is a genuine
    /// PRECONDITION: the platform team owns the namespace and must have
    /// labelled it themselves before the driver ever touches it.
    ///
    /// Kept as the provisioner's own check rather than a call into
    /// `PlatformEnricher::detect_psa`: the provisioner holds no enricher.
    /// The error wording mirrors `KymaEnricher::detect_psa` (`enricher.rs`)
    /// verbatim — the runbook quotes that message.
    async fn verify_psa_label(&self, namespace: &str) -> Result<(), DriverError> {
        let api: Api<Namespace> = Api::all(self.client.clone());
        let ns = api.get(namespace).await?;
        let enforce = ns
            .metadata
            .labels
            .as_ref()
            .and_then(|l| l.get("pod-security.kubernetes.io/enforce"))
            .cloned();
        if enforce.as_deref() == Some("privileged") {
            Ok(())
        } else {
            Err(DriverError::FailedPrecondition(format!(
                "namespace {namespace} must have label pod-security.kubernetes.io/enforce=privileged \
                 for the supervisor's elevated capabilities; current value: {:?}. Apply this label as \
                 cluster-admin: kubectl label ns {namespace} pod-security.kubernetes.io/enforce=privileged --overwrite",
                enforce.unwrap_or_else(|| "<absent>".to_string())
            )))
        }
    }

    /// Delete a managed workspace namespace, or decline to.
    ///
    /// This is the only code path in the driver that deletes a namespace,
    /// and deleting a namespace destroys everything inside it
    /// irreversibly. Four guardrails, all load-bearing:
    ///
    /// 1. The name is DERIVED from `cfg.gateway_id` + `workspace` by the
    ///    same `crate::workspace::managed_namespace` that
    ///    `bootstrap_managed_namespace` used to create it, so the target is
    ///    always the namespace this driver would have created for this
    ///    workspace. Read this narrowly: deriving PREFIXES, it does not
    ///    SANITISE. `workspace` is caller-supplied and is interpolated into
    ///    the name verbatim, and kube-core's `validate_name` only rejects
    ///    the empty string before splicing that name raw and unencoded into
    ///    the request path — so a workspace containing `/` and `..` can
    ///    still produce a path that dot-segment removal resolves onto some
    ///    other namespace, `kube-system` included. Guardrail 1 alone does
    ///    NOT stop that. Guardrail 3 does; see below.
    /// 2. A missing namespace is success, not a `NotFound` error, so a
    ///    retried or duplicated `DeleteWorkspace` is idempotent.
    /// 3. The ownership labels must match THIS gateway and workspace —
    ///    the same `namespace_owned_by` predicate the create side uses, so
    ///    the two answers cannot drift. A namespace that merely happens to
    ///    match the naming convention (a colliding `gateway_id`/`workspace`
    ///    pair, or an operator-made namespace) is logged and left alone.
    ///    Declining returns `Ok(())` rather than an error: teardown must
    ///    not wedge on a namespace it simply does not own.
    ///
    ///    This is also what makes guardrail 1's gap unexploitable, and it
    ///    is the guardrail to preserve most carefully. Kubernetes validates
    ///    label VALUES on write, so no namespace can ever carry an
    ///    `openshell.ai/sandbox-workspace` value containing `/`, `%` or
    ///    whitespace. A workspace string crafted to traverse therefore can
    ///    never equal the workspace label of any namespace that exists, so
    ///    the check declines — and if traversal did land the GET on
    ///    `kube-system`, that namespace carries none of the three labels
    ///    either. Ownership, not name derivation, is what keeps this off
    ///    other people's namespaces.
    /// 4. The delete carries a UID precondition, so a namespace deleted and
    ///    recreated between the `get` and the `delete` is not destroyed by a
    ///    decision taken about the object it replaced.
    async fn delete_managed_namespace(&self, workspace: &str) -> Result<(), DriverError> {
        // Guardrail 1. Routed through `namespace_for_workspace` (same value
        // as a direct `managed_namespace` call under `Managed`) so this also
        // gets `namespace_for`'s DNS-1123 charset check — see that
        // function's doc comment.
        let ns = self.namespace_for_workspace(workspace)?;
        let api: Api<Namespace> = Api::all(self.client.clone());

        // Guardrail 2.
        let existing = match api.get(&ns).await {
            Ok(n) => n,
            Err(kube::Error::Api(e)) if e.code == 404 => {
                tracing::info!(namespace = %ns, "managed workspace namespace already gone");
                return Ok(());
            }
            Err(e) => return Err(DriverError::Kube(e)),
        };

        // Guardrails 3 and 4, decided by a pure function so the decision is
        // unit testable without a cluster.
        let uid = match namespace_delete_decision(&existing, &self.cfg.gateway_id, workspace) {
            NamespaceDeleteDecision::DeletePinnedTo { uid } => uid,
            NamespaceDeleteDecision::Decline => {
                tracing::warn!(
                    namespace = %ns,
                    gateway_id = %self.cfg.gateway_id,
                    workspace = %workspace,
                    labels = ?existing.metadata.labels.clone().unwrap_or_default(),
                    "refusing to delete a namespace this driver does not own; \
                     leaving it untouched"
                );
                return Ok(());
            }
            NamespaceDeleteDecision::NoUid => {
                // Every object the API server returns has a uid, so this is
                // a "the cluster is not in the state I need" condition, not
                // an internal bug. Refusing beats deleting unpinned.
                return Err(DriverError::FailedPrecondition(format!(
                    "namespace {ns} carries this driver's ownership labels but was returned \
                     without a metadata.uid, so the delete cannot be pinned to the object \
                     that was inspected; refusing to delete without a UID precondition"
                )));
            }
        };

        let dp = DeleteParams {
            preconditions: Some(Preconditions {
                uid: Some(uid),
                resource_version: None,
            }),
            ..DeleteParams::default()
        };
        match api.delete(&ns, &dp).await {
            Ok(_) => {
                tracing::info!(namespace = %ns, "deleting managed workspace namespace");
                Ok(())
            }
            // Someone else finished the job between the get and the delete.
            Err(kube::Error::Api(e)) if e.code == 404 => {
                tracing::info!(namespace = %ns, "managed workspace namespace already gone");
                Ok(())
            }
            // Conflict. The expected cause is the UID precondition failing
            // — the namespace was deleted and a new one with the same name
            // took its place, so the object this call decided about is
            // gone, this teardown is done, and the replacement belongs to a
            // newer lifecycle that a stale decision must not destroy. It is
            // not the only cause, though: the apiserver also returns 409 for
            // "object has been modified" and for some admission and
            // finalizer conflicts. All of them mean the same thing here —
            // this decision no longer applies to what is on the server — so
            // the handling is the same, but the log carries `reason` rather
            // than asserting which one it was.
            Err(kube::Error::Api(e)) if e.code == 409 => {
                tracing::warn!(
                    namespace = %ns,
                    reason = %e.reason,
                    message = %e.message,
                    "conflict deleting managed workspace namespace (most likely the uid \
                     precondition failing because it was recreated between the ownership \
                     check and the delete); leaving it alone"
                );
                Ok(())
            }
            Err(e) => Err(DriverError::Kube(e)),
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
        // A `count: 0` GPU request is rejected in `validate_create` and again
        // in `create`, both of which run before we ever build a spec. Treating
        // the error as "no GPU" here is the safe fallback: it under-allocates
        // rather than silently handing out a device on a malformed request.
        let gpu_count = effective_gpu_count(spec.and_then(|s| s.resource_requirements.as_ref()))
            .unwrap_or(None);
        let resources = match template.and_then(|t| t.resources.as_ref()) {
            Some(res) => build_resources(res, gpu_count),
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
            let claim_name = format!(
                "{}-workspace",
                crate::workspace::kube_resource_name(
                    self.cfg.workspace_mode,
                    &sb.workspace,
                    &sb.name
                )
            );
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
        //
        // Per-sandbox `platform_config.host_users` overrides the
        // cluster-wide `cfg.enable_user_namespaces` default. Note the
        // inversion: `host_users: true` means "use the host user
        // namespace" (i.e. do NOT remap), so `use_user_namespaces =
        // !host_users`. Absent, or present with a non-bool value, falls
        // back to the cluster-wide default. Mirrors upstream
        // `driver.rs:3504-3505`:
        //   let use_user_namespaces = platform_config_bool(template, "host_users")
        //       .map_or(params.enable_user_namespaces, |host_users| !host_users);
        let host_users_override = template
            .and_then(|t| t.platform_config.as_ref())
            .and_then(|pc| pc.fields.get("host_users"))
            .and_then(|v| v.kind.as_ref())
            .and_then(bool_from_value_kind);
        let use_user_namespaces =
            host_users_override.map_or(self.cfg.enable_user_namespaces, |host_users| !host_users);
        if use_user_namespaces {
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
        driver_labels.insert(LABEL_MANAGED_BY.into(), LABEL_MANAGED_BY_VALUE.into());
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

        let mut sandbox_spec = json!({
            "podTemplate": {
                "metadata": {
                    "labels": labels,
                    "annotations": annotations,
                },
                "spec": pod_spec,
            }
        });

        // Optional `agentSocket` passthrough from the template. Set only
        // when non-empty so sandboxes that don't use it see no change to
        // the CR body. Mirrors upstream `driver.rs:3344-3349`:
        //   if !template.agent_socket_path.is_empty() {
        //       root.insert("agentSocket".to_string(), serde_json::json!(template.agent_socket_path));
        //   }
        if let Some(socket_path) = template
            .map(|t| t.agent_socket_path.as_str())
            .filter(|s| !s.is_empty())
        {
            sandbox_spec["agentSocket"] = Value::String(socket_path.to_string());
        }

        sandbox_spec
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
        // Inject the upstream pseudo-endpoint that the supervisor's
        // in-process inference router intercepts. NO `/v1` suffix —
        // Anthropic SDKs (and claude-code) append `/v1/messages`
        // themselves, so a `…/v1` value here would produce
        // `/v1/v1/messages` and the L7 router rejects it with
        // "connection not allowed by policy". OpenAI SDKs follow the
        // same convention. Confirmed in the supervisor's NET:OPEN log
        // (route table only matches `path=/v1/messages`).
        gw_env.insert(
            "ANTHROPIC_BASE_URL".into(),
            "https://inference.local".into(),
        );
        gw_env.insert("OPENAI_BASE_URL".into(), "https://inference.local".into());
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

    /// `namespace` is the already-resolved namespace this sandbox lives in
    /// (see `namespace_for_workspace`) — it is recorded verbatim in the
    /// `LABEL_SANDBOX_NAMESPACE` label/annotation and the object's own
    /// `metadata.namespace`, never re-derived from `cfg.namespace` here.
    fn build_dynamic_object(&self, sb: &DriverSandbox, namespace: &str) -> DynamicObject {
        let mut driver_labels: HashMap<String, String> = HashMap::new();
        driver_labels.insert(LABEL_SANDBOX_ID.into(), sb.id.clone());
        driver_labels.insert(LABEL_SANDBOX_NAME.into(), sb.name.clone());
        driver_labels.insert(LABEL_SANDBOX_NAMESPACE.into(), namespace.to_string());
        driver_labels.insert(LABEL_SANDBOX_WORKSPACE.into(), sb.workspace.clone());
        driver_labels.insert(LABEL_MANAGED_BY.into(), LABEL_MANAGED_BY_VALUE.into());
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

        // Identity is also written as annotations. Label *values* are capped
        // at 63 chars and restricted to `[A-Za-z0-9._-]`; annotations have no
        // such limit, so they are the lossless copy `object_to_driver_sandbox`
        // prefers when reading identity back.
        let annotations: std::collections::BTreeMap<String, String> = [
            (ANNOTATION_SANDBOX_ID.to_string(), sb.id.clone()),
            (LABEL_SANDBOX_ID.to_string(), sb.id.clone()),
            (LABEL_SANDBOX_NAME.to_string(), sb.name.clone()),
            (LABEL_SANDBOX_NAMESPACE.to_string(), namespace.to_string()),
            (LABEL_SANDBOX_WORKSPACE.to_string(), sb.workspace.clone()),
        ]
        .into_iter()
        .collect();

        // The CR is named `{workspace}--{name}` so sandboxes of the same name
        // in different workspaces cannot collide in a shared namespace. The
        // bare logical name lives in the labels/annotations above.
        let kube_name =
            crate::workspace::kube_resource_name(self.cfg.workspace_mode, &sb.workspace, &sb.name);
        let mut obj = DynamicObject::new(&kube_name, &self.sandbox_ar);
        obj.metadata.namespace = Some(namespace.to_string());
        obj.metadata.labels = Some(labels);
        obj.metadata.annotations = Some(annotations);
        obj.data = json!({ "spec": self.build_sandbox_spec(sb) });
        obj
    }
}

/// Namespace object for a managed workspace.
///
/// The three ownership labels are what `namespace_owned_by` checks — both
/// here, at create time, and (in a future task) before `DeleteWorkspace`
/// deletes anything. Deleting, or adopting, a namespace this driver didn't
/// create would be catastrophic; keep the write side (here) and that check
/// in sync.
#[must_use]
fn managed_namespace_object(gateway_id: &str, workspace: &str) -> serde_json::Value {
    serde_json::json!({
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {
            "name": crate::workspace::managed_namespace(gateway_id, workspace),
            "labels": {
                LABEL_MANAGED_BY: LABEL_MANAGED_BY_VALUE,
                LABEL_GATEWAY_ID: gateway_id,
                LABEL_SANDBOX_WORKSPACE: workspace,
                // verify_psa_label hard-fails without this, and every
                // sandbox pod needs privileged. The chart does NOT set
                // this label for the shared namespace either — there is
                // no pod-security reference in any template; per
                // docs/getting-started.md, the operator applies it by
                // hand as cluster-admin. Managed mode can't rely on a
                // manual per-namespace step, so the driver applies it
                // itself here.
                "pod-security.kubernetes.io/enforce": "privileged",
            }
        }
    })
}

/// Whether `ns` carries this driver's ownership labels for exactly this
/// `gateway_id`/`workspace` pair.
///
/// Pure predicate so both the create-time ownership check in
/// `create_or_verify_managed_namespace` and a future `DeleteWorkspace`
/// teardown can ask the same question the same way — and so a mismatch
/// between the two can't develop silently. Requires all three labels
/// (`LABEL_MANAGED_BY`, `LABEL_GATEWAY_ID`, `LABEL_SANDBOX_WORKSPACE`) to
/// match: a namespace this driver never touched (no labels at all) and a
/// namespace from a colliding `gateway_id`/`workspace` pair (labels
/// present but wrong) both return `false`.
#[must_use]
fn namespace_owned_by(ns: &Namespace, gateway_id: &str, workspace: &str) -> bool {
    let Some(labels) = ns.metadata.labels.as_ref() else {
        return false;
    };
    labels.get(LABEL_MANAGED_BY).map(String::as_str) == Some(LABEL_MANAGED_BY_VALUE)
        && labels.get(LABEL_GATEWAY_ID).map(String::as_str) == Some(gateway_id)
        && labels.get(LABEL_SANDBOX_WORKSPACE).map(String::as_str) == Some(workspace)
}

/// What `delete_managed_namespace` should do about a namespace it has just
/// read back from the API server.
///
/// Split out from the I/O so the two guardrails that decide whether a
/// namespace gets destroyed — ownership, and the UID the delete is pinned
/// to — are a pure function that can be unit tested without a cluster.
#[derive(Debug, PartialEq, Eq)]
enum NamespaceDeleteDecision {
    /// Owned by this gateway/workspace: delete it, with the delete pinned
    /// to this exact object via a UID precondition.
    DeletePinnedTo { uid: String },
    /// Not this driver's namespace. Leave it alone.
    Decline,
    /// Owned, but returned without a `metadata.uid`, so the delete cannot
    /// be pinned. Refuse rather than delete unpinned.
    NoUid,
}

/// Decide the fate of an existing namespace named for `gateway_id`/`workspace`.
///
/// Ownership is delegated to `namespace_owned_by` — the same predicate
/// `create_or_verify_managed_namespace` uses — deliberately, so the create
/// side and the delete side can never answer the ownership question
/// differently.
#[must_use]
fn namespace_delete_decision(
    ns: &Namespace,
    gateway_id: &str,
    workspace: &str,
) -> NamespaceDeleteDecision {
    if !namespace_owned_by(ns, gateway_id, workspace) {
        return NamespaceDeleteDecision::Decline;
    }
    match ns.metadata.uid.clone() {
        Some(uid) => NamespaceDeleteDecision::DeletePinnedTo { uid },
        None => NamespaceDeleteDecision::NoUid,
    }
}

/// The ServiceAccount `SANDBOX_SERVICE_ACCOUNT` names in every pod spec.
/// Mirrors `templates/sandbox-serviceaccount.yaml`, including the
/// no-automount decision: sandbox pods are user code, so a mounted SA
/// token would be a credential-leak surface for nothing.
#[must_use]
fn sandbox_service_account_object(namespace: &str) -> serde_json::Value {
    serde_json::json!({
        "apiVersion": "v1",
        "kind": "ServiceAccount",
        "metadata": {
            "name": SANDBOX_SERVICE_ACCOUNT,
            "namespace": namespace,
            "labels": { LABEL_MANAGED_BY: LABEL_MANAGED_BY_VALUE },
        },
        "automountServiceAccountToken": false
    })
}

/// `create`, treating an existing object as success.
///
/// Idempotence is not optional here: the gateway calls EnsureWorkspace before
/// every sandbox create, so the second call onwards always hits this path.
async fn create_tolerating_conflict<K>(api: &Api<K>, obj: K) -> Result<(), DriverError>
where
    K: kube::Resource + Clone + std::fmt::Debug + serde::de::DeserializeOwned + serde::Serialize,
    K::DynamicType: Default,
{
    match api.create(&PostParams::default(), &obj).await {
        Ok(_) => Ok(()),
        Err(kube::Error::Api(e)) if e.code == 409 => Ok(()),
        Err(e) => Err(DriverError::Kube(e)),
    }
}

fn string_from_value_kind(kind: &prost_types::value::Kind) -> Option<String> {
    match kind {
        prost_types::value::Kind::StringValue(s) => Some(s.clone()),
        _ => None,
    }
}

fn bool_from_value_kind(kind: &prost_types::value::Kind) -> Option<bool> {
    match kind {
        prost_types::value::Kind::BoolValue(b) => Some(*b),
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
        crate::workspace::validate_kube_resource_name(
            self.cfg.workspace_mode,
            &sb.workspace,
            &sb.name,
        )?;
        let namespace = self.namespace_for_workspace(&sb.workspace)?;

        if !self.cfg.sandbox_storage_size.is_empty() {
            self.ensure_sandbox_pvc(sb, &namespace).await?;
        }

        let obj = self.build_dynamic_object(sb, &namespace);
        self.sandboxes_api_for(Some(&namespace))
            .create(&PostParams::default(), &obj)
            .await?;
        tracing::info!(
            sandbox_id = %sb.id,
            sandbox_name = %sb.name,
            namespace = %namespace,
            "sandbox CR created"
        );
        Ok(())
    }

    async fn delete(&self, sandbox_id: &str) -> Result<(), DriverError> {
        // Resolve id -> CR name/namespace first: the gateway knows nothing
        // about our `{workspace}--{name}` object naming, so the id label is
        // the only stable handle we can delete by. The namespace comes from
        // the found object itself, not `cfg.namespace` — under
        // `Managed`/`Operator` they can differ.
        let (kube_name, namespace) = self.resolve_cr_location(sandbox_id).await?;

        let result = match self
            .sandboxes_api_for(Some(&namespace))
            .delete(&kube_name, &DeleteParams::default())
            .await
        {
            Ok(_) => Ok(()),
            // Lost a race with another delete between resolve and delete.
            Err(kube::Error::Api(s)) if s.code == 404 => {
                Err(DriverError::NotFound(sandbox_id.to_string()))
            }
            Err(e) => Err(e.into()),
        };

        // Best-effort PVC cleanup. We tolerate 404 (PVC was never
        // created or already gone) and propagate other errors only when
        // the Sandbox CR delete itself succeeded — if both fail, the
        // Sandbox-CR error is the more actionable one.
        if !self.cfg.sandbox_storage_size.is_empty() {
            let pvc_api: Api<k8s_openapi::api::core::v1::PersistentVolumeClaim> =
                Api::namespaced(self.client.clone(), &namespace);
            // Derived from the resolved CR name, not the bare sandbox name,
            // so it matches what `ensure_sandbox_pvc` actually created.
            let claim_name = format!("{kube_name}-workspace");
            match pvc_api.delete(&claim_name, &DeleteParams::default()).await {
                Ok(_) => {}
                Err(kube::Error::Api(s)) if s.code == 404 => {}
                Err(e) if result.is_ok() => return Err(e.into()),
                Err(e) => {
                    tracing::warn!(error = %e, sandbox_id = %sandbox_id, "PVC cleanup failed; sandbox-CR delete error takes precedence");
                }
            }
        }

        result
    }

    async fn get(&self, sandbox_id: &str) -> Result<DriverSandbox, DriverError> {
        let obj = self.find_by_sandbox_id(sandbox_id).await?;
        object_to_driver_sandbox(&obj).map_err(DriverError::InvalidArgument)
    }

    async fn list(&self) -> Result<Vec<DriverSandbox>, DriverError> {
        let lp =
            ListParams::default().labels(&format!("{LABEL_MANAGED_BY}={LABEL_MANAGED_BY_VALUE}"));
        let ns = self.id_lookup_namespace();
        let list = self.sandboxes_api_for(ns.as_deref()).list(&lp).await?;
        // Mirror upstream: one malformed CR must not break `list` for every
        // other sandbox, so unconvertible objects are logged and skipped.
        Ok(list
            .items
            .iter()
            .filter_map(|obj| match object_to_driver_sandbox(obj) {
                Ok(sb) => Some(sb),
                Err(e) => {
                    tracing::warn!(error = %e, "skipping unconvertible sandbox CR in list");
                    None
                }
            })
            .collect())
    }

    async fn watch(&self) -> Result<mpsc::Receiver<WatchEvent>, DriverError> {
        let ns = self.id_lookup_namespace();
        let api = self.sandboxes_api_for(ns.as_deref());
        let cfg = watcher::Config::default()
            .labels(&format!("{LABEL_MANAGED_BY}={LABEL_MANAGED_BY_VALUE}"));

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
                        // Skip, don't abort: a single CR missing the id/name/
                        // workspace labels must not tear down the watch for
                        // every other sandbox.
                        match object_to_driver_sandbox(&obj) {
                            Ok(sb) => WatchEvent::Updated(Box::new(sb)),
                            Err(e) => {
                                tracing::warn!(error = %e, "skipping unconvertible sandbox CR in watch");
                                continue;
                            }
                        }
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
        // Shared: scoped to `cfg.namespace`, matching the CR watcher above.
        // Otherwise cluster-wide — the `managed-by` label on the Sandbox CR
        // watcher already keeps the fan-in scoped to our own sandboxes; the
        // Event watcher itself has no such label to filter on server-side.
        let events_api: Api<CoreEvent> = match ns.as_deref() {
            Some(n) => Api::namespaced(self.client.clone(), n),
            None => Api::all(self.client.clone()),
        };
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
        // Reject a name that cannot become a DNS-1123 object name before the
        // gateway commits to the create — the API server would otherwise
        // reject it far later with a much less actionable message.
        crate::workspace::validate_kube_resource_name(
            self.cfg.workspace_mode,
            &sb.workspace,
            &sb.name,
        )?;
        // Also run this workspace through `namespace_for`'s own gate (charset
        // under Managed/Operator, allowlist membership under Operator) so a
        // request that would fail at the real `create()` call fails here
        // too, before the gateway commits to it. The resolved namespace
        // itself is unused; only the validation matters here.
        crate::workspace::namespace_for(&self.cfg, &sb.workspace)?;

        if let Some(spec) = sb.spec.as_ref() {
            // `count: 0` is an invalid request and surfaces as InvalidArgument.
            if let Some(count) = effective_gpu_count(spec.resource_requirements.as_ref())? {
                if !self.has_gpu_capacity(count).await? {
                    return Err(DriverError::FailedPrecondition(format!(
                        "no node has {count} allocatable {GPU_RESOURCE}"
                    )));
                }
            }
        }
        Ok(())
    }

    /// Whether any *single* node can satisfy a request for `count` GPUs.
    ///
    /// Deliberately per-node rather than a cluster-wide sum: a pod is
    /// scheduled onto one node, so two nodes with one GPU each cannot host a
    /// two-GPU sandbox. Summing would let such a request through validation
    /// only for the pod to sit Pending forever.
    async fn has_gpu_capacity(&self, count: u32) -> Result<bool, DriverError> {
        if !self.cfg.gpu_support {
            return Ok(false);
        }
        let nodes: Api<Node> = Api::all(self.client.clone());
        let list = nodes.list(&ListParams::default()).await?;
        for node in list.items {
            if let Some(alloc) = node.status.as_ref().and_then(|s| s.allocatable.as_ref()) {
                // Allocatable GPU counts are plain integers — no SI suffixes,
                // unlike cpu/memory — so a direct parse is sound here.
                if let Some(q) = alloc.get(GPU_RESOURCE) {
                    if q.0.parse::<u32>().unwrap_or(0) >= count {
                        return Ok(true);
                    }
                }
            }
        }
        Ok(false)
    }

    async fn start_sandbox(&self, sandbox_id: &str) -> Result<(), DriverError> {
        self.patch_operating_state(sandbox_id, true).await
    }

    async fn stop_sandbox(&self, sandbox_id: &str) -> Result<(), DriverError> {
        self.patch_operating_state(sandbox_id, false).await?;
        self.await_pod_gone(sandbox_id).await
    }

    async fn apply_apirule(
        &self,
        manifest: serde_json::Value,
        namespace: &str,
    ) -> Result<(), DriverError> {
        let gvk = GroupVersionKind {
            group: "gateway.kyma-project.io".into(),
            version: "v2".into(),
            kind: "APIRule".into(),
        };
        let ar = ApiResource::from_gvk_with_plural(&gvk, "apirules");
        let api: Api<DynamicObject> = Api::namespaced_with(self.client.clone(), namespace, &ar);

        let name = manifest
            .pointer("/metadata/name")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let mut obj = DynamicObject::new(name, &ar);
        obj.metadata.namespace = Some(namespace.to_string());
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
            namespace = %namespace,
            "APIRule created"
        );
        Ok(())
    }

    async fn ensure_workspace(&self, workspace: &str) -> Result<(), DriverError> {
        match self.cfg.workspace_mode {
            // Upstream: `Shared => {}`. The namespace is static and installed
            // by the chart; there is nothing to prepare.
            WorkspaceMode::Shared => Ok(()),
            WorkspaceMode::Managed => self.bootstrap_managed_namespace(workspace).await,
            // Upstream's Operator mode only checks the allowlist; it does
            // not bootstrap. `namespace_for` already performed that check
            // and returns `PermissionDenied` if `workspace` was not
            // allowlisted.
            //
            // `verify_psa_label` runs here as a genuine PRECONDITION
            // (unlike Managed, where it is a post-condition on a label the
            // driver itself just applied): the platform team owns this
            // namespace's contents, and its existing error message already
            // names the exact `kubectl label ns` command to run.
            WorkspaceMode::Operator => {
                let ns = crate::workspace::namespace_for(&self.cfg, workspace)?;
                self.verify_psa_label(&ns).await?;
                Ok(())
            }
        }
    }

    async fn delete_workspace(&self, workspace: &str) -> Result<(), DriverError> {
        match self.cfg.workspace_mode {
            // Neither mode created a namespace, so neither may remove one.
            // `Operator` especially: those namespaces belong to the platform
            // team and predate the driver. Mirrors
            // `workspace::workspace_delete_requires_namespace_access`, which
            // is true only for `Managed`.
            WorkspaceMode::Shared | WorkspaceMode::Operator => Ok(()),
            WorkspaceMode::Managed => self.delete_managed_namespace(workspace).await,
        }
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

    fn make_provisioner_with_user_namespaces(enable_user_namespaces: bool) -> KymaProvisioner {
        let cfg = Config {
            namespace: "test-ns".into(),
            enable_user_namespaces,
            ..Config::default()
        };
        let svc = tower::service_fn(|_req: http::Request<kube::client::Body>| async move {
            Ok::<_, std::convert::Infallible>(http::Response::new(kube::client::Body::empty()))
        });
        KymaProvisioner::new(Client::new(svc, "test-ns"), cfg)
    }

    fn make_sandbox(id: &str, name: &str, image: &str) -> DriverSandbox {
        DriverSandbox {
            id: id.into(),
            name: name.into(),
            // Every sandbox the gateway sends carries a workspace since
            // v0.0.91; an empty one is rejected by `validate_kube_resource_name`.
            workspace: "default".into(),
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

    /// Builds a `prost_types::Struct` with a single field, for populating
    /// `DriverSandboxTemplate.platform_config` in tests.
    fn platform_config_with(key: &str, kind: prost_types::value::Kind) -> prost_types::Struct {
        prost_types::Struct {
            fields: std::iter::once((key.to_string(), prost_types::Value { kind: Some(kind) }))
                .collect(),
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

    // ---------- platform_config.host_users overrides ----------
    //
    // Upstream (driver.rs:3504-3505):
    //   let use_user_namespaces = platform_config_bool(template, "host_users")
    //       .map_or(params.enable_user_namespaces, |host_users| !host_users);
    //
    // Note the inversion: `host_users: true` means "use the host user
    // namespace", i.e. `use_user_namespaces = false`.

    #[tokio::test]
    async fn build_sandbox_spec_host_users_key_absent_falls_back_to_cluster_default_off() {
        // platform_config is present (so the accessor walks into it) but the
        // "host_users" key itself is absent. Catches a mutant that treats
        // "platform_config is Some" as "override is present" instead of
        // checking the specific field.
        let p = make_provisioner_with_user_namespaces(false);
        let mut sb = make_sandbox("sb-1", "x", "img");
        sb.spec
            .as_mut()
            .unwrap()
            .template
            .as_mut()
            .unwrap()
            .platform_config = Some(platform_config_with(
            "unrelated",
            prost_types::value::Kind::StringValue("x".into()),
        ));
        let spec = p.build_sandbox_spec(&sb);
        assert!(spec["podTemplate"]["spec"].get("hostUsers").is_none());
    }

    #[tokio::test]
    async fn build_sandbox_spec_host_users_key_absent_falls_back_to_cluster_default_on() {
        let p = make_provisioner_with_user_namespaces(true);
        let mut sb = make_sandbox("sb-1", "x", "img");
        sb.spec
            .as_mut()
            .unwrap()
            .template
            .as_mut()
            .unwrap()
            .platform_config = Some(platform_config_with(
            "unrelated",
            prost_types::value::Kind::StringValue("x".into()),
        ));
        let spec = p.build_sandbox_spec(&sb);
        assert_eq!(spec["podTemplate"]["spec"]["hostUsers"], false);
    }

    #[tokio::test]
    async fn build_sandbox_spec_host_users_true_disables_user_namespaces_regardless_of_cluster_flag(
    ) {
        // `host_users: true` must win over the cluster-wide default in BOTH
        // directions. This is the critical inversion test: a backwards
        // `!host_users` (i.e. using `host_users` directly instead of its
        // negation) would set hostUsers=false here instead of leaving it
        // unset when the cluster flag is on.
        for cluster_default in [false, true] {
            let p = make_provisioner_with_user_namespaces(cluster_default);
            let mut sb = make_sandbox("sb-1", "x", "img");
            sb.spec
                .as_mut()
                .unwrap()
                .template
                .as_mut()
                .unwrap()
                .platform_config = Some(platform_config_with(
                "host_users",
                prost_types::value::Kind::BoolValue(true),
            ));
            let spec = p.build_sandbox_spec(&sb);
            assert!(
                spec["podTemplate"]["spec"].get("hostUsers").is_none(),
                "host_users:true must disable the namespace remap even when cluster default is {cluster_default}"
            );
        }
    }

    #[tokio::test]
    async fn build_sandbox_spec_host_users_false_enables_user_namespaces_regardless_of_cluster_flag(
    ) {
        // `host_users: false` must win over the cluster-wide default in BOTH
        // directions. This is the other half of the inversion test: a
        // backwards mapping would leave hostUsers unset here instead of
        // false when the cluster flag is off.
        for cluster_default in [false, true] {
            let p = make_provisioner_with_user_namespaces(cluster_default);
            let mut sb = make_sandbox("sb-1", "x", "img");
            sb.spec
                .as_mut()
                .unwrap()
                .template
                .as_mut()
                .unwrap()
                .platform_config = Some(platform_config_with(
                "host_users",
                prost_types::value::Kind::BoolValue(false),
            ));
            let spec = p.build_sandbox_spec(&sb);
            assert_eq!(
                spec["podTemplate"]["spec"]["hostUsers"], false,
                "host_users:false must enable the namespace remap even when cluster default is {cluster_default}"
            );
        }
    }

    #[tokio::test]
    async fn build_sandbox_spec_host_users_non_bool_value_treated_as_absent() {
        // A non-bool "host_users" value (e.g. a string) must be ignored,
        // exactly like upstream's `platform_config_bool_returns_none_for_non_bool`
        // (driver.rs:7100+). Falling back to the cluster default (on, here)
        // proves it is genuinely treated as absent rather than, say,
        // truthy-coerced.
        let p = make_provisioner_with_user_namespaces(true);
        let mut sb = make_sandbox("sb-1", "x", "img");
        sb.spec
            .as_mut()
            .unwrap()
            .template
            .as_mut()
            .unwrap()
            .platform_config = Some(platform_config_with(
            "host_users",
            prost_types::value::Kind::StringValue("true".into()),
        ));
        let spec = p.build_sandbox_spec(&sb);
        assert_eq!(spec["podTemplate"]["spec"]["hostUsers"], false);
    }

    // ---------- agent_socket_path passthrough ----------
    //
    // Upstream (driver.rs:3344-3349):
    //   if !template.agent_socket_path.is_empty() {
    //       root.insert("agentSocket".to_string(), serde_json::json!(template.agent_socket_path));
    //   }

    #[tokio::test]
    async fn build_sandbox_spec_agent_socket_path_set_when_non_empty() {
        let p = make_provisioner();
        let mut sb = make_sandbox("sb-1", "x", "img");
        sb.spec
            .as_mut()
            .unwrap()
            .template
            .as_mut()
            .unwrap()
            .agent_socket_path = "/var/run/openshell/agent.sock".into();
        let spec = p.build_sandbox_spec(&sb);
        assert_eq!(spec["agentSocket"], "/var/run/openshell/agent.sock");
    }

    #[tokio::test]
    async fn build_sandbox_spec_agent_socket_path_absent_when_empty() {
        // agent_socket_path defaults to "" (proto3 default). The key must
        // be entirely absent, not present as an empty string, so the CR
        // body is unchanged for every sandbox that doesn't set this field.
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "x", "img");
        let spec = p.build_sandbox_spec(&sb);
        assert!(spec.get("agentSocket").is_none());
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
        // Workspace-qualified, matching what `ensure_sandbox_pvc` creates.
        assert_eq!(
            ws["persistentVolumeClaim"]["claimName"],
            "default--my-sandbox-workspace"
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
        assert!(!p.has_gpu_capacity(1).await.unwrap());
    }

    #[tokio::test]
    async fn validate_create_passes_when_no_gpu_requested() {
        let p = make_provisioner();
        let sb = make_sandbox("sb-1", "x", "img");
        // No resource_requirements.gpu in the spec; no node check needed.
        p.validate_create(&sb).await.unwrap();
    }

    /// A zero GPU count must fail as a malformed request, and must do so
    /// *before* any node listing — otherwise the mock client would be hit.
    #[tokio::test]
    async fn validate_create_rejects_zero_gpu_count() {
        use computev1::pb::{GpuResourceRequirements, ResourceRequirements};

        let p = make_provisioner();
        let mut sb = make_sandbox("sb-1", "x", "img");
        sb.spec.as_mut().unwrap().resource_requirements = Some(ResourceRequirements {
            gpu: Some(GpuResourceRequirements { count: Some(0) }),
        });
        let err = p
            .validate_create(&sb)
            .await
            .expect_err("count 0 is invalid");
        assert!(matches!(err, DriverError::InvalidArgument(_)), "{err:?}");
    }

    #[tokio::test]
    async fn validate_create_rejects_overlong_object_name() {
        let p = make_provisioner();
        // 54 chars is the cap under the `default` workspace (63 - len - 2).
        let sb = make_sandbox("sb-1", &"a".repeat(55), "img");
        let err = p
            .validate_create(&sb)
            .await
            .expect_err("name should exceed DNS-1123 limit");
        assert!(matches!(err, DriverError::InvalidArgument(_)), "{err:?}");
    }

    /// The create-path half of the charset fix: under `Managed`, `workspace`
    /// becomes a namespace name reached via `namespace_for`, so
    /// `validate_create` (the `ValidateSandboxCreate` RPC) must reject a
    /// charset-invalid workspace before the gateway ever commits to
    /// `create()` — and must do so before any API call.
    #[tokio::test]
    async fn validate_create_rejects_charset_invalid_workspace_under_managed() {
        let (client, recorder) = recording_client(vec![]);
        let p = managed_provisioner(client);
        let mut sb = make_sandbox("sb-1", "x", "img");
        sb.workspace = "acme.dev".into();
        let err = p
            .validate_create(&sb)
            .await
            .expect_err("dot is not a valid DNS-1123 label");
        assert!(matches!(err, DriverError::InvalidArgument(_)), "{err:?}");
        assert!(
            recorder.lock().unwrap().is_empty(),
            "the charset check must short-circuit before any API call"
        );
    }

    /// The regression `validate_create` must not introduce: `Shared` never
    /// turns `workspace` into a namespace name, so a workspace containing a
    /// dot — accepted by this driver before this branch — must still pass
    /// `validate_create`.
    #[tokio::test]
    async fn validate_create_accepts_a_dotted_workspace_under_shared() {
        let p = make_provisioner();
        let mut sb = make_sandbox("sb-1", "x", "img");
        sb.workspace = "acme.dev".into();
        p.validate_create(&sb)
            .await
            .expect("Shared must accept a dotted workspace");
    }

    /// The CR must carry every label `object_to_driver_sandbox` reads back,
    /// or a sandbox we create becomes one we cannot list.
    #[tokio::test]
    async fn build_dynamic_object_round_trips_through_object_to_driver_sandbox() {
        let p = make_provisioner();
        let sb = make_sandbox("id-9", "round-trip", "img");
        // Ties the "test-ns" literal passed below to the real resolution
        // path `create()` actually uses (`namespace_for_workspace`), so a
        // regression there (e.g. passing `sb.workspace` instead) can't hide
        // behind a hardcoded literal in this test.
        assert_eq!(p.namespace_for_workspace("default").unwrap(), "test-ns");
        let obj = p.build_dynamic_object(&sb, "test-ns");

        assert_eq!(obj.metadata.name.as_deref(), Some("default--round-trip"));

        let back = object_to_driver_sandbox(&obj).expect("CR should be convertible");
        assert_eq!(back.id, "id-9");
        assert_eq!(back.name, "round-trip");
        assert_eq!(back.workspace, "default");
    }

    // ---------- managed-workspace bootstrap object builders ----------

    #[test]
    fn managed_namespace_carries_ownership_and_psa_labels() {
        let obj = managed_namespace_object("gw1", "team-a");
        let labels = &obj["metadata"]["labels"];
        assert_eq!(obj["metadata"]["name"], "openshell-gw1-team-a");
        assert_eq!(labels[LABEL_MANAGED_BY], LABEL_MANAGED_BY_VALUE);
        assert_eq!(labels[LABEL_GATEWAY_ID], "gw1");
        assert_eq!(labels[LABEL_SANDBOX_WORKSPACE], "team-a");
        // Without this, verify_psa_label fails and no sandbox pod can start.
        assert_eq!(labels["pod-security.kubernetes.io/enforce"], "privileged");
    }

    /// Would catch a mutation that swaps the gateway_id/workspace arguments
    /// at a call site: the namespace name embeds both in a fixed order, so a
    /// swap changes the derived name even though both values are still
    /// present somewhere in the object.
    #[test]
    fn managed_namespace_object_uses_the_derived_namespace_name() {
        let obj = managed_namespace_object("gw1", "team-a");
        assert_eq!(
            obj["metadata"]["name"],
            crate::workspace::managed_namespace("gw1", "team-a")
        );
    }

    // ---------- namespace ownership predicate ----------

    fn namespace_with_labels(labels: serde_json::Value) -> Namespace {
        serde_json::from_value(serde_json::json!({
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": { "name": "openshell-gw1-team-a", "labels": labels }
        }))
        .expect("must deserialize into k8s Namespace")
    }

    /// The accept path — this is what the second `EnsureWorkspace` call for
    /// an already-bootstrapped workspace must see, or every namespace this
    /// driver itself created would wrongly fail the ownership check.
    #[test]
    fn namespace_owned_by_accepts_matching_labels() {
        let ns = namespace_with_labels(serde_json::json!({
            LABEL_MANAGED_BY: LABEL_MANAGED_BY_VALUE,
            LABEL_GATEWAY_ID: "gw1",
            LABEL_SANDBOX_WORKSPACE: "team-a",
        }));
        assert!(namespace_owned_by(&ns, "gw1", "team-a"));
    }

    /// Would catch the managed-by check being dropped or short-circuited:
    /// only the gateway-id/workspace labels being right must not be enough.
    #[test]
    fn namespace_owned_by_rejects_wrong_managed_by_value() {
        let ns = namespace_with_labels(serde_json::json!({
            LABEL_MANAGED_BY: "someone-else",
            LABEL_GATEWAY_ID: "gw1",
            LABEL_SANDBOX_WORKSPACE: "team-a",
        }));
        assert!(!namespace_owned_by(&ns, "gw1", "team-a"));
    }

    /// The collision case the finding is about: a namespace another
    /// gateway created (right managed-by/workspace, wrong gateway_id) must
    /// not be adopted.
    #[test]
    fn namespace_owned_by_rejects_wrong_gateway_id() {
        let ns = namespace_with_labels(serde_json::json!({
            LABEL_MANAGED_BY: LABEL_MANAGED_BY_VALUE,
            LABEL_GATEWAY_ID: "gw-other",
            LABEL_SANDBOX_WORKSPACE: "team-a",
        }));
        assert!(!namespace_owned_by(&ns, "gw1", "team-a"));
    }

    /// Would catch the workspace comparison being dropped: right
    /// managed-by/gateway-id but the wrong workspace must still be denied.
    #[test]
    fn namespace_owned_by_rejects_wrong_workspace() {
        let ns = namespace_with_labels(serde_json::json!({
            LABEL_MANAGED_BY: LABEL_MANAGED_BY_VALUE,
            LABEL_GATEWAY_ID: "gw1",
            LABEL_SANDBOX_WORKSPACE: "team-b",
        }));
        assert!(!namespace_owned_by(&ns, "gw1", "team-a"));
    }

    /// A namespace this driver never touched at all — no labels whatsoever
    /// — must be denied too, not treated as a vacuous match. Catches an
    /// `unwrap_or(true)`-style bug in the `None` branch of the labels
    /// lookup.
    #[test]
    fn namespace_owned_by_rejects_namespace_with_no_labels() {
        let ns: Namespace = serde_json::from_value(serde_json::json!({
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": { "name": "openshell-gw1-team-a" }
        }))
        .unwrap();
        assert!(!namespace_owned_by(&ns, "gw1", "team-a"));
    }

    // ---------- namespace delete decision ----------

    fn namespace_with(labels: serde_json::Value, uid: Option<&str>) -> Namespace {
        let mut metadata = serde_json::json!({
            "name": "openshell-gw1-team-a",
            "labels": labels,
        });
        if let Some(uid) = uid {
            metadata["uid"] = serde_json::json!(uid);
        }
        serde_json::from_value(serde_json::json!({
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": metadata,
        }))
        .expect("must deserialize into k8s Namespace")
    }

    fn owned_labels() -> serde_json::Value {
        serde_json::json!({
            LABEL_MANAGED_BY: LABEL_MANAGED_BY_VALUE,
            LABEL_GATEWAY_ID: "gw1",
            LABEL_SANDBOX_WORKSPACE: "team-a",
        })
    }

    /// The one path that ends in a namespace being destroyed, and the UID
    /// it is pinned to must be the UID of the object whose labels were
    /// just checked. Would catch the precondition being dropped, or being
    /// filled from anything other than the inspected object.
    #[test]
    fn namespace_delete_decision_pins_the_delete_to_the_inspected_uid() {
        let ns = namespace_with(owned_labels(), Some("uid-1"));
        assert_eq!(
            namespace_delete_decision(&ns, "gw1", "team-a"),
            NamespaceDeleteDecision::DeletePinnedTo {
                uid: "uid-1".to_string()
            }
        );
    }

    /// A namespace that merely matches the naming convention — another
    /// gateway's, or a colliding gateway_id/workspace pair's — must never
    /// reach the delete call. Would catch the ownership check being
    /// bypassed on the teardown side while the create side still has it.
    #[test]
    fn namespace_delete_decision_declines_another_gateways_namespace() {
        let ns = namespace_with(
            serde_json::json!({
                LABEL_MANAGED_BY: LABEL_MANAGED_BY_VALUE,
                LABEL_GATEWAY_ID: "gw-other",
                LABEL_SANDBOX_WORKSPACE: "team-a",
            }),
            Some("uid-1"),
        );
        assert_eq!(
            namespace_delete_decision(&ns, "gw1", "team-a"),
            NamespaceDeleteDecision::Decline
        );
    }

    /// The catastrophic case: a namespace this driver never created, which
    /// happens to sit at the derived name. No labels, but a perfectly good
    /// uid — so a decision that looked only at the uid would delete it.
    #[test]
    fn namespace_delete_decision_declines_an_unlabelled_namespace() {
        let ns: Namespace = serde_json::from_value(serde_json::json!({
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": { "name": "openshell-gw1-team-a", "uid": "uid-1" }
        }))
        .unwrap();
        assert_eq!(
            namespace_delete_decision(&ns, "gw1", "team-a"),
            NamespaceDeleteDecision::Decline
        );
    }

    /// Owned, but with no uid to pin to. Deleting unpinned would race with
    /// a recreate, so the decision must be neither Delete nor Decline.
    #[test]
    fn namespace_delete_decision_refuses_to_delete_unpinned() {
        let ns = namespace_with(owned_labels(), None);
        assert_eq!(
            namespace_delete_decision(&ns, "gw1", "team-a"),
            NamespaceDeleteDecision::NoUid
        );
    }

    /// Covers `crate::workspace::managed_namespace` ONLY: whatever a caller
    /// puts in `workspace`, the derived name still begins with
    /// `openshell-{gateway_id}-`. That `delete_managed_namespace` actually
    /// uses this derived name is a separate claim, tested on the wire by
    /// `delete_managed_namespace_targets_the_derived_name_and_pins_the_uid`.
    ///
    /// Note what this does NOT show. Deriving prefixes; it does not
    /// sanitise. The hostile strings below stay inside the prefix as a
    /// STRING, but kube-core splices the name into the request path raw and
    /// unencoded (`validate_name` only rejects the empty string), so one
    /// containing `/` and `..` still goes on the wire and can resolve, after
    /// dot-segment removal, onto a different namespace. What makes that
    /// harmless is the ownership check, not this prefix: Kubernetes
    /// validates label values, so no namespace can carry a workspace label
    /// containing `/`, and `kube-system` carries none of the three labels
    /// regardless.
    #[test]
    fn managed_namespace_name_is_derived_not_supplied() {
        for hostile in [
            "kube-system",
            "../kube-system",
            "..%2fkube-system",
            "a/../../kube-system",
            "",
            " kube-system",
        ] {
            let ns = crate::workspace::managed_namespace("gw1", hostile);
            assert!(
                ns.starts_with("openshell-gw1-"),
                "workspace {hostile:?} escaped the derived prefix: {ns}"
            );
            assert_ne!(ns, "kube-system");
            assert_ne!(ns, "default");
        }
        // These names DO reach the API server — nothing validates them
        // client-side — and it is the server that rejects them as invalid
        // DNS-1123 labels, or (on a traversal-shaped string) resolves the
        // path elsewhere. Either way the ownership check has already had to
        // pass first, which for any of these strings it cannot.
    }

    /// The delete side must target exactly what the create side made.
    #[test]
    fn delete_target_matches_the_bootstrapped_namespace_name() {
        let created = managed_namespace_object("gw1", "team-a");
        assert_eq!(
            created["metadata"]["name"],
            crate::workspace::managed_namespace("gw1", "team-a")
        );
    }

    /// `Shared` shares one chart-installed namespace; deleting it would
    /// take every other workspace with it. `DeleteWorkspace` must be a
    /// no-op that performs no API call at all — the stub client here would
    /// fail any request it made.
    #[tokio::test]
    async fn delete_workspace_is_a_no_op_in_shared_mode() {
        let p = make_provisioner();
        assert_eq!(p.cfg.workspace_mode, WorkspaceMode::Shared);
        p.delete_workspace("team-a")
            .await
            .expect("shared mode must not touch the API server");
    }

    /// `Operator` namespaces belong to the platform team and predate the
    /// driver; it never created them and must never remove them.
    #[tokio::test]
    async fn delete_workspace_is_a_no_op_in_operator_mode() {
        let cfg = Config {
            workspace_mode: WorkspaceMode::Operator,
            gateway_id: "gw1".into(),
            ..Config::default()
        };
        let svc = tower::service_fn(|_req: http::Request<kube::client::Body>| async move {
            Ok::<_, std::convert::Infallible>(http::Response::new(kube::client::Body::empty()))
        });
        let p = KymaProvisioner::new(Client::new(svc, "test-ns"), cfg);
        p.delete_workspace("team-a")
            .await
            .expect("operator mode must not touch the API server");
    }

    // ---------- delete_managed_namespace, on the wire ----------
    //
    // The helper tests above cover the decisions in isolation. These cover
    // the composed function, where all four guardrails actually meet: they
    // assert what is sent to the API server, and — for the decline path —
    // that nothing is sent at all. A stub `tower::Service` stands in for the
    // apiserver; no cluster is involved.

    #[derive(Debug, Clone)]
    struct RecordedRequest {
        method: String,
        uri: String,
        body: String,
    }

    type Recorder = Arc<std::sync::Mutex<Vec<RecordedRequest>>>;

    /// A `Client` backed by a stub that records every request and answers
    /// them in order from `responses` (HTTP status, JSON body). Receiving
    /// more requests than there are canned responses panics, which is how
    /// "and it issued no DELETE" is enforced.
    fn recording_client(responses: Vec<(u16, String)>) -> (Client, Recorder) {
        let recorder: Recorder = Arc::new(std::sync::Mutex::new(Vec::new()));
        let queue = Arc::new(std::sync::Mutex::new(std::collections::VecDeque::from(
            responses,
        )));
        let rec = Arc::clone(&recorder);
        let svc = tower::service_fn(move |req: http::Request<kube::client::Body>| {
            let rec = Arc::clone(&rec);
            let queue = Arc::clone(&queue);
            async move {
                let (parts, body) = req.into_parts();
                let bytes = http_body_util::BodyExt::collect(body)
                    .await
                    .map(http_body_util::Collected::to_bytes)
                    .unwrap_or_default();
                rec.lock().unwrap().push(RecordedRequest {
                    method: parts.method.to_string(),
                    uri: parts.uri.to_string(),
                    body: String::from_utf8_lossy(&bytes).into_owned(),
                });
                let (code, payload) = queue
                    .lock()
                    .unwrap()
                    .pop_front()
                    .expect("stub apiserver received a request it was not primed for");
                Ok::<_, std::convert::Infallible>(
                    http::Response::builder()
                        .status(code)
                        .header("content-type", "application/json")
                        .body(kube::client::Body::from(payload.into_bytes()))
                        .unwrap(),
                )
            }
        });
        (Client::new(svc, "test-ns"), recorder)
    }

    fn managed_provisioner(client: Client) -> KymaProvisioner {
        let cfg = Config {
            workspace_mode: WorkspaceMode::Managed,
            gateway_id: "gw1".into(),
            namespace: "test-ns".into(),
            ..Config::default()
        };
        KymaProvisioner::new(client, cfg)
    }

    /// A namespace as the apiserver would return it, optionally carrying
    /// this driver's ownership labels and/or a uid.
    fn served_namespace(owned: bool, uid: Option<&str>) -> String {
        let mut metadata = serde_json::json!({ "name": "openshell-gw1-team-a" });
        if owned {
            metadata["labels"] = serde_json::json!({
                LABEL_MANAGED_BY: LABEL_MANAGED_BY_VALUE,
                LABEL_GATEWAY_ID: "gw1",
                LABEL_SANDBOX_WORKSPACE: "team-a",
            });
        }
        if let Some(uid) = uid {
            metadata["uid"] = serde_json::json!(uid);
        }
        serde_json::json!({
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": metadata,
        })
        .to_string()
    }

    fn served_status(code: u16, reason: &str) -> String {
        serde_json::json!({
            "apiVersion": "v1",
            "kind": "Status",
            "status": "Failure",
            "reason": reason,
            "message": format!("{reason} for namespaces \"openshell-gw1-team-a\""),
            "code": code,
        })
        .to_string()
    }

    /// Guardrail 2, on the composed function: a namespace that is already
    /// gone is success, so a retried DeleteWorkspace is idempotent. Would
    /// catch the 404 arm on the GET being removed or narrowed — with it
    /// gone this returns `Err(Kube)` instead.
    #[tokio::test]
    async fn delete_managed_namespace_treats_a_missing_namespace_as_success() {
        let (client, recorder) = recording_client(vec![(404, served_status(404, "NotFound"))]);
        managed_provisioner(client)
            .delete_managed_namespace("team-a")
            .await
            .expect("an already-absent namespace must be success, not NotFound");
        let seen = recorder.lock().unwrap().clone();
        assert_eq!(seen.len(), 1, "expected only the GET, saw {seen:?}");
        assert_eq!(seen[0].method, "GET");
    }

    /// Guardrails 1 and 4 together, as they appear on the wire: the DELETE
    /// must go to the DERIVED name, and must carry a uid precondition equal
    /// to the uid of the object the ownership check just inspected.
    ///
    /// Would catch the derived name being replaced by the raw workspace
    /// (the path would read `/api/v1/namespaces/team-a`), and would catch
    /// the precondition being dropped or filled from anywhere else.
    #[tokio::test]
    async fn delete_managed_namespace_targets_the_derived_name_and_pins_the_uid() {
        let (client, recorder) = recording_client(vec![
            (200, served_namespace(true, Some("uid-42"))),
            (200, served_namespace(true, Some("uid-42"))),
        ]);
        managed_provisioner(client)
            .delete_managed_namespace("team-a")
            .await
            .expect("an owned namespace must be deleted");

        let seen = recorder.lock().unwrap().clone();
        assert_eq!(seen.len(), 2, "expected a GET then a DELETE, saw {seen:?}");
        assert_eq!(seen[0].method, "GET");
        assert!(
            seen[0]
                .uri
                .starts_with("/api/v1/namespaces/openshell-gw1-team-a"),
            "the read must target the derived name, got {}",
            seen[0].uri
        );
        assert_eq!(seen[1].method, "DELETE");
        assert!(
            seen[1]
                .uri
                .starts_with("/api/v1/namespaces/openshell-gw1-team-a"),
            "the delete must target the derived name, got {}",
            seen[1].uri
        );
        let body: serde_json::Value =
            serde_json::from_str(&seen[1].body).expect("delete body must be JSON");
        assert_eq!(
            body["preconditions"]["uid"], "uid-42",
            "the delete must be pinned to the uid of the inspected object, got {body}"
        );
    }

    /// Guardrail 3 on the composed function, and the single most important
    /// assertion in this file: a namespace sitting at the derived name that
    /// this driver does not own is not merely tolerated, it is NOT DELETED.
    /// The stub is primed with one response only, so an attempted DELETE
    /// panics; the recorded-request count asserts it independently.
    #[tokio::test]
    async fn delete_managed_namespace_issues_no_delete_for_a_namespace_it_does_not_own() {
        let (client, recorder) =
            recording_client(vec![(200, served_namespace(false, Some("uid-9")))]);
        managed_provisioner(client)
            .delete_managed_namespace("team-a")
            .await
            .expect("declining must be Ok(()), so teardown cannot wedge");
        let seen = recorder.lock().unwrap().clone();
        assert_eq!(seen.len(), 1, "expected only the GET, saw {seen:?}");
        assert_eq!(seen[0].method, "GET");
        assert!(
            !seen.iter().any(|r| r.method == "DELETE"),
            "a namespace this driver does not own must never be deleted, saw {seen:?}"
        );
    }

    /// The `NoUid` branch end to end: owned, but the object came back with
    /// no uid, so the delete cannot be pinned. Must refuse rather than
    /// delete unpinned — and must issue no DELETE.
    #[tokio::test]
    async fn delete_managed_namespace_refuses_when_it_cannot_pin_the_uid() {
        let (client, recorder) = recording_client(vec![(200, served_namespace(true, None))]);
        let err = managed_provisioner(client)
            .delete_managed_namespace("team-a")
            .await
            .expect_err("an unpinnable delete must be refused");
        assert!(
            matches!(err, DriverError::FailedPrecondition(_)),
            "expected FailedPrecondition, got {err:?}"
        );
        let seen = recorder.lock().unwrap().clone();
        assert_eq!(seen.len(), 1, "expected only the GET, saw {seen:?}");
    }

    /// Guardrail 2 on the DELETE itself: someone else finished the job
    /// between the read and the write. Would catch the 404 arm on the
    /// delete being removed.
    #[tokio::test]
    async fn delete_managed_namespace_tolerates_a_404_on_the_delete() {
        let (client, _recorder) = recording_client(vec![
            (200, served_namespace(true, Some("uid-42"))),
            (404, served_status(404, "NotFound")),
        ]);
        managed_provisioner(client)
            .delete_managed_namespace("team-a")
            .await
            .expect("a namespace that vanished mid-delete is not an error");
    }

    /// A conflict on the delete — expected to be the uid precondition
    /// failing because the namespace was recreated, though the apiserver
    /// returns 409 for other reasons too. Either way this decision no
    /// longer applies, and the replacement must not be destroyed. Would
    /// catch the 409 arm being removed.
    #[tokio::test]
    async fn delete_managed_namespace_tolerates_a_conflict_on_the_delete() {
        let (client, _recorder) = recording_client(vec![
            (200, served_namespace(true, Some("uid-42"))),
            (409, served_status(409, "Conflict")),
        ]);
        managed_provisioner(client)
            .delete_managed_namespace("team-a")
            .await
            .expect("a conflict means this decision is stale, not that teardown failed");
    }

    /// The tolerance above must be narrow. A 403 — the shape an RBAC gap
    /// takes — must surface, not be swallowed as success. Would catch a
    /// catch-all `Err(_) => Ok(())`.
    #[tokio::test]
    async fn delete_managed_namespace_propagates_errors_it_does_not_expect() {
        let (client, _recorder) = recording_client(vec![(403, served_status(403, "Forbidden"))]);
        let err = managed_provisioner(client)
            .delete_managed_namespace("team-a")
            .await
            .expect_err("a 403 must not be reported as a successful teardown");
        assert!(
            matches!(err, DriverError::Kube(_)),
            "expected the kube error to surface, got {err:?}"
        );
    }

    /// Positive routing: `Managed` must actually reach
    /// `delete_managed_namespace`. The Shared/Operator tests above only
    /// prove the no-op arms; a regression turning `Managed` into a silent
    /// no-op too would pass every one of them. This fails if no request is
    /// made, or if it is made against the wrong name.
    #[tokio::test]
    async fn delete_workspace_routes_managed_mode_to_the_namespace_delete() {
        let (client, recorder) = recording_client(vec![(404, served_status(404, "NotFound"))]);
        managed_provisioner(client)
            .delete_workspace("team-a")
            .await
            .expect("managed teardown of an absent namespace is success");
        let seen = recorder.lock().unwrap().clone();
        assert_eq!(
            seen.len(),
            1,
            "managed mode must reach the API server, not silently no-op; saw {seen:?}"
        );
        assert!(
            seen[0]
                .uri
                .starts_with("/api/v1/namespaces/openshell-gw1-team-a"),
            "expected the derived namespace, got {}",
            seen[0].uri
        );
    }

    /// `delete_managed_namespace` (and, by the same construction,
    /// `bootstrap_managed_namespace`) is now routed through
    /// `namespace_for_workspace` rather than calling `managed_namespace`
    /// directly, so it inherits `namespace_for`'s DNS-1123 charset gate.
    /// This must reject before any API call — an invalid-charset workspace
    /// must never become part of a namespace name reached over the wire.
    #[tokio::test]
    async fn delete_workspace_managed_mode_rejects_charset_invalid_workspace_before_any_api_call() {
        let (client, recorder) = recording_client(vec![]);
        let err = managed_provisioner(client)
            .delete_workspace("acme.dev")
            .await
            .expect_err("dot is not a valid DNS-1123 label");
        assert!(matches!(err, DriverError::InvalidArgument(_)), "{err:?}");
        assert!(
            recorder.lock().unwrap().is_empty(),
            "the charset check must short-circuit before any API call"
        );
    }

    #[test]
    fn managed_service_account_does_not_automount_its_token() {
        let obj = sandbox_service_account_object("openshell-gw1-team-a");
        // Sandbox pods are user code; a mounted SA token is a credential
        // leak surface for nothing. Mirrors sandbox-serviceaccount.yaml.
        assert_eq!(obj["automountServiceAccountToken"], false);
        assert_eq!(obj["metadata"]["name"], SANDBOX_SERVICE_ACCOUNT);
        assert_eq!(obj["metadata"]["namespace"], "openshell-gw1-team-a");
        assert_eq!(
            obj["metadata"]["labels"][LABEL_MANAGED_BY],
            LABEL_MANAGED_BY_VALUE
        );
    }

    /// Both builders must deserialize into their real Kubernetes types
    /// without error — a typo in a field name would otherwise only surface
    /// at runtime against a live cluster, in `bootstrap_managed_namespace`.
    #[test]
    fn managed_namespace_object_deserializes_into_namespace_type() {
        let obj = managed_namespace_object("gw1", "team-a");
        let _: Namespace =
            serde_json::from_value(obj).expect("must deserialize into k8s Namespace");
    }

    #[test]
    fn sandbox_service_account_object_deserializes_into_service_account_type() {
        let obj = sandbox_service_account_object("openshell-gw1-team-a");
        let _: ServiceAccount =
            serde_json::from_value(obj).expect("must deserialize into k8s ServiceAccount");
    }

    fn operator_provisioner(client: Client, allowlist: &[&str]) -> KymaProvisioner {
        let cfg = Config {
            workspace_mode: WorkspaceMode::Operator,
            operator_namespace_allowlist: allowlist.iter().map(|s| (*s).to_string()).collect(),
            namespace: "test-ns".into(),
            ..Config::default()
        };
        KymaProvisioner::new(client, cfg)
    }

    /// A namespace as the apiserver would return it, carrying the PSA label
    /// (or not) but none of `Managed`'s ownership labels — `Operator`
    /// namespaces predate the driver and were never labelled by it.
    fn served_operator_namespace(name: &str, psa_labelled: bool) -> String {
        let mut metadata = serde_json::json!({ "name": name });
        if psa_labelled {
            metadata["labels"] =
                serde_json::json!({ "pod-security.kubernetes.io/enforce": "privileged" });
        }
        serde_json::json!({
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": metadata,
        })
        .to_string()
    }

    /// `namespace_for` must reject a non-allowlisted workspace before
    /// `ensure_workspace` ever reaches the API server — no bootstrap, no
    /// probe, nothing. The stub is primed with zero responses, so any
    /// request at all panics; the recorded-request count enforces it too.
    #[tokio::test]
    async fn ensure_workspace_operator_mode_rejects_a_non_allowlisted_workspace_before_any_api_call(
    ) {
        let (client, recorder) = recording_client(vec![]);
        let err = operator_provisioner(client, &["tenant-a"])
            .ensure_workspace("tenant-b")
            .await
            .expect_err("a non-allowlisted workspace must be denied");
        assert!(matches!(err, DriverError::PermissionDenied(_)), "{err:?}");
        assert!(
            recorder.lock().unwrap().is_empty(),
            "the allowlist check must short-circuit before any API call"
        );
    }

    /// The real behaviour this task adds: an allowlisted workspace resolves
    /// straight to that namespace (bare, undecorated — unlike `Managed`'s
    /// derived name) and `verify_psa_label` reads it as a precondition.
    #[tokio::test]
    async fn ensure_workspace_operator_mode_verifies_the_psa_label_on_the_allowlisted_namespace() {
        let (client, recorder) =
            recording_client(vec![(200, served_operator_namespace("tenant-a", true))]);
        operator_provisioner(client, &["tenant-a"])
            .ensure_workspace("tenant-a")
            .await
            .expect("an allowlisted, PSA-labelled namespace must succeed");
        let seen = recorder.lock().unwrap().clone();
        assert_eq!(seen.len(), 1, "expected only the GET, saw {seen:?}");
        assert_eq!(seen[0].method, "GET");
        assert!(
            seen[0].uri.starts_with("/api/v1/namespaces/tenant-a"),
            "Operator must use the bare workspace name, not a derived one, got {}",
            seen[0].uri
        );
    }

    /// The platform team owns this namespace's contents; if they never
    /// applied the PSA label, `ensure_workspace` must fail loudly rather
    /// than let sandbox pods land in a namespace where they can't start.
    #[tokio::test]
    async fn ensure_workspace_operator_mode_fails_when_the_namespace_lacks_the_psa_label() {
        let (client, _recorder) =
            recording_client(vec![(200, served_operator_namespace("tenant-a", false))]);
        let err = operator_provisioner(client, &["tenant-a"])
            .ensure_workspace("tenant-a")
            .await
            .expect_err("a namespace missing the PSA label must fail");
        assert!(matches!(err, DriverError::FailedPrecondition(_)), "{err:?}");
    }
}
