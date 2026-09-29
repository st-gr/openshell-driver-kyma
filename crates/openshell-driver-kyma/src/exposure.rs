// SPDX-License-Identifier: Apache-2.0

//! Hook 2: expose a sandbox's port 8080 through a Kyma APIRule.
//!
//! Upstream fences sandbox workloads (`openshell-sandbox-workloads`): they
//! accept ingress only from supervisor pods on the boundary port and have no
//! egress. Direct HTTPS exposure is therefore an explicit, opt-in exception to
//! upstream's isolation — a Service selecting the workload by upstream's
//! boundary labels, a NetworkPolicy admitting only the Istio ingress gateway on
//! 8080, and the APIRule. All three are owner-referenced to the Sandbox CR, so
//! Kubernetes deletes them with it, and labelled as ours so they never look
//! like upstream's objects.

use k8s_openapi::chrono::{SecondsFormat, Utc};
use kube::api::{Api, ApiResource, DynamicObject, ListParams, Patch, PatchParams, PostParams};
use kube::core::GroupVersionKind;
use openshell_core::driver_utils::{LABEL_MANAGED_BY, LABEL_MANAGED_BY_VALUE, LABEL_SANDBOX_ID};
use openshell_core::proto::compute::v1::DriverSandbox;
use serde_json::{json, Value};

pub const MANAGED_BY_LABEL: &str = "app.kubernetes.io/managed-by";
pub const MANAGED_BY_VALUE: &str = "openshell-driver-kyma";
pub const SANDBOX_ID_LABEL: &str = "openshell.ai/sandbox-id";
/// Upstream's boundary labels (`openshell-driver-kubernetes/src/isolation.rs`).
/// Selecting on `openshell.ai/sandbox-id` alone would also match the supervisor pod.
pub const BOUNDARY_PAIR_LABEL: &str = "openshell.ai/boundary-pair";
pub const BOUNDARY_ROLE_LABEL: &str = "openshell.ai/boundary-role";
pub const WORKLOAD_ROLE: &str = "workload";
pub const EXPOSE_PORT: i32 = 8080;
pub const KYMA_GATEWAY: &str = "kyma-system/kyma-gateway";
const FIELD_MANAGER: &str = "openshell-driver-kyma";
const SANDBOX_GROUP: &str = "agents.x-k8s.io";
/// Upstream's own probe order (`SANDBOX_VERSIONS` in its `driver.rs`): try
/// `v1beta1`, fall back to `v1alpha1` only when the API answers 404.
const SANDBOX_VERSION_V1BETA1: &str = "v1beta1";
const SANDBOX_VERSION_V1ALPHA1: &str = "v1alpha1";

/// The Sandbox CR the exposure objects belong to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SandboxOwner {
    pub namespace: String,
    pub name: String,
    pub uid: String,
    /// The `group/version` the CR was found at (`agents.x-k8s.io/v1beta1` or
    /// `agents.x-k8s.io/v1alpha1`, whichever the cluster serves), so the
    /// ownerReferences and the Event name the version upstream itself uses.
    pub api_version: String,
}

impl SandboxOwner {
    fn owner_reference(&self) -> Value {
        json!({
            "apiVersion": self.api_version,
            "kind": "Sandbox",
            "name": self.name,
            "uid": self.uid,
        })
    }
}

#[derive(Debug, Clone)]
pub struct ExposureConfig {
    pub cluster_domain: String,
    pub ingress_namespace: String,
    /// `Some(namespace)` in Shared mode, where the driver's RBAC is namespaced;
    /// `None` searches all namespaces (Managed and Operator modes).
    pub search_namespace: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum ExposureError {
    #[error("no Sandbox resource carries {SANDBOX_ID_LABEL}={0}")]
    SandboxNotFound(String),
    #[error(
        "{count} Sandbox resources carry {SANDBOX_ID_LABEL}={sandbox_id}; expected exactly one"
    )]
    AmbiguousSandbox { sandbox_id: String, count: usize },
    #[error("the Sandbox resource for {0} has no namespace, name or uid")]
    IncompleteSandbox(String),
    #[error("{what}: {source}")]
    Kube {
        what: String,
        #[source]
        source: kube::Error,
    },
}

pub fn service_name(kube_name: &str) -> String {
    format!("{kube_name}-svc")
}

pub fn policy_name(kube_name: &str) -> String {
    format!("{kube_name}-expose")
}

/// The APIRule host's first label: `{workspace}--{name}` in every workspace
/// mode. That is upstream's Shared-mode resource name (so it equals the CR
/// name there), but in Managed and Operator mode the CR is named just `{name}`
/// in a per-workspace namespace, and two workspaces may both have a `dev`.
pub fn host_label(workspace: &str, name: &str) -> String {
    format!("{workspace}--{name}")
}

fn labels(sandbox_id: &str) -> Value {
    json!({ MANAGED_BY_LABEL: MANAGED_BY_VALUE, SANDBOX_ID_LABEL: sandbox_id })
}

fn workload_selector(sandbox_id: &str) -> Value {
    // Upstream's `pair_label_value` lowercases the sandbox id.
    json!({
        BOUNDARY_PAIR_LABEL: sandbox_id.to_ascii_lowercase(),
        BOUNDARY_ROLE_LABEL: WORKLOAD_ROLE,
    })
}

fn metadata(owner: &SandboxOwner, name: &str, sandbox_id: &str) -> Value {
    json!({
        "name": name,
        "namespace": owner.namespace,
        "labels": labels(sandbox_id),
        "ownerReferences": [owner.owner_reference()],
    })
}

pub fn service_manifest(owner: &SandboxOwner, sandbox_id: &str) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": metadata(owner, &service_name(&owner.name), sandbox_id),
        "spec": {
            "selector": workload_selector(sandbox_id),
            "ports": [{"name": "http", "protocol": "TCP", "port": EXPOSE_PORT, "targetPort": EXPOSE_PORT}],
        },
    })
}

pub fn ingress_policy_manifest(
    owner: &SandboxOwner,
    sandbox_id: &str,
    ingress_namespace: &str,
) -> Value {
    json!({
        "apiVersion": "networking.k8s.io/v1",
        "kind": "NetworkPolicy",
        "metadata": metadata(owner, &policy_name(&owner.name), sandbox_id),
        "spec": {
            "podSelector": {"matchLabels": workload_selector(sandbox_id)},
            "policyTypes": ["Ingress"],
            "ingress": [{
                "from": [{
                    "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": ingress_namespace}},
                    "podSelector": {"matchLabels": {"istio": "ingressgateway"}},
                }],
                "ports": [{"protocol": "TCP", "port": EXPOSE_PORT}],
            }],
        },
    })
}

pub fn apirule_manifest(
    owner: &SandboxOwner,
    sandbox_id: &str,
    host_label: &str,
    cluster_domain: &str,
) -> Value {
    json!({
        "apiVersion": "gateway.kyma-project.io/v2",
        "kind": "APIRule",
        "metadata": metadata(owner, &owner.name, sandbox_id),
        "spec": {
            "gateway": KYMA_GATEWAY,
            // `host_label` is workspace-qualified; `owner.name` is not in Managed
            // and Operator mode, where it would collide across workspaces.
            "hosts": [format!("{host_label}.{cluster_domain}")],
            "service": {"name": service_name(&owner.name), "port": EXPOSE_PORT},
            "rules": [{"path": "/*", "methods": ["GET", "POST"], "noAuth": true}],
        },
    })
}

fn failure_event_manifest(owner: &SandboxOwner, message: &str, timestamp: &str) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": "Event",
        "metadata": {"generateName": format!("{}-expose-", owner.name), "namespace": owner.namespace},
        "involvedObject": {
            "apiVersion": owner.api_version,
            "kind": "Sandbox",
            "name": owner.name,
            "namespace": owner.namespace,
            "uid": owner.uid,
        },
        "type": "Warning",
        "reason": "ExposureFailed",
        "message": message,
        "count": 1,
        "firstTimestamp": timestamp,
        "lastTimestamp": timestamp,
        "source": {"component": FIELD_MANAGER},
    })
}

fn resource(group: &str, version: &str, kind: &str, plural: &str) -> ApiResource {
    ApiResource::from_gvk_with_plural(&GroupVersionKind::gvk(group, version, kind), plural)
}

pub struct ExposureReconciler {
    client: kube::Client,
    config: ExposureConfig,
}

impl ExposureReconciler {
    pub fn new(client: kube::Client, config: ExposureConfig) -> Self {
        Self { client, config }
    }

    /// Find the sandbox's CR, expose it, and on failure record a Warning Event
    /// on the CR. Never retried here: the sandbox itself is healthy either way.
    ///
    /// Runs in a detached task after `CreateSandbox`, where a panic would be
    /// lost, so nothing on this path may panic: every failure is an `Err`.
    pub async fn reconcile(&self, sandbox: &DriverSandbox) -> Result<(), ExposureError> {
        let sandbox_id = sandbox.id.as_str();
        let owner = self.find_owner(sandbox_id).await?;
        let host_label = host_label(&sandbox.workspace, &sandbox.name);
        if let Err(error) = self.expose(&owner, sandbox_id, &host_label).await {
            if let Err(event_error) = self.report_failure(&owner, &error).await {
                tracing::warn!(sandbox_id, error = %event_error, "could not record the exposure failure as an Event");
            }
            return Err(error);
        }
        Ok(())
    }

    async fn find_owner(&self, sandbox_id: &str) -> Result<SandboxOwner, ExposureError> {
        // Same probe order as upstream: `v1beta1`, then `v1alpha1`, moving on
        // only when the API answers 404 (the version is not served).
        let (version, listed) = match self
            .list_sandboxes(SANDBOX_VERSION_V1BETA1, sandbox_id)
            .await
        {
            Err(kube::Error::Api(response)) if response.code == 404 => (
                SANDBOX_VERSION_V1ALPHA1,
                self.list_sandboxes(SANDBOX_VERSION_V1ALPHA1, sandbox_id)
                    .await,
            ),
            listed => (SANDBOX_VERSION_V1BETA1, listed),
        };
        let list = listed.map_err(|source| ExposureError::Kube {
            what: format!("listing Sandbox resources at {SANDBOX_GROUP}/{version}"),
            source,
        })?;
        // Exactly one CR may carry the id: exposing the wrong one would publish
        // some other sandbox.
        let mut items = list.items;
        let count = items.len();
        let object = match (count, items.pop()) {
            (1, Some(object)) => object,
            (0, _) => return Err(ExposureError::SandboxNotFound(sandbox_id.to_string())),
            _ => {
                return Err(ExposureError::AmbiguousSandbox {
                    sandbox_id: sandbox_id.to_string(),
                    count,
                })
            }
        };
        match (
            object.metadata.namespace,
            object.metadata.name,
            object.metadata.uid,
        ) {
            (Some(namespace), Some(name), Some(uid)) => Ok(SandboxOwner {
                namespace,
                name,
                uid,
                api_version: format!("{SANDBOX_GROUP}/{version}"),
            }),
            _ => Err(ExposureError::IncompleteSandbox(sandbox_id.to_string())),
        }
    }

    async fn list_sandboxes(
        &self,
        version: &str,
        sandbox_id: &str,
    ) -> Result<kube::core::ObjectList<DynamicObject>, kube::Error> {
        let sandboxes = resource(SANDBOX_GROUP, version, "Sandbox", "sandboxes");
        let api: Api<DynamicObject> = match &self.config.search_namespace {
            Some(namespace) => Api::namespaced_with(self.client.clone(), namespace, &sandboxes),
            None => Api::all_with(self.client.clone(), &sandboxes),
        };
        // Upstream's own lookup pairs the id with its managed-by label.
        let selector =
            format!("{LABEL_MANAGED_BY}={LABEL_MANAGED_BY_VALUE},{LABEL_SANDBOX_ID}={sandbox_id}");
        api.list(&ListParams::default().labels(&selector)).await
    }

    async fn expose(
        &self,
        owner: &SandboxOwner,
        sandbox_id: &str,
        host_label: &str,
    ) -> Result<(), ExposureError> {
        self.apply(
            resource("", "v1", "Service", "services"),
            owner,
            &service_name(&owner.name),
            service_manifest(owner, sandbox_id),
            "applying the exposure Service",
        )
        .await?;
        self.apply(
            resource(
                "networking.k8s.io",
                "v1",
                "NetworkPolicy",
                "networkpolicies",
            ),
            owner,
            &policy_name(&owner.name),
            ingress_policy_manifest(owner, sandbox_id, &self.config.ingress_namespace),
            "applying the ingress NetworkPolicy",
        )
        .await?;
        self.apply(
            resource("gateway.kyma-project.io", "v2", "APIRule", "apirules"),
            owner,
            &owner.name,
            apirule_manifest(owner, sandbox_id, host_label, &self.config.cluster_domain),
            "applying the APIRule",
        )
        .await
    }

    async fn apply(
        &self,
        api_resource: ApiResource,
        owner: &SandboxOwner,
        name: &str,
        manifest: Value,
        what: &str,
    ) -> Result<(), ExposureError> {
        let api: Api<DynamicObject> =
            Api::namespaced_with(self.client.clone(), &owner.namespace, &api_resource);
        api.patch(
            name,
            &PatchParams::apply(FIELD_MANAGER).force(),
            &Patch::Apply(&manifest),
        )
        .await
        .map(|_| ())
        .map_err(|source| ExposureError::Kube {
            what: what.into(),
            source,
        })
    }

    async fn report_failure(
        &self,
        owner: &SandboxOwner,
        error: &ExposureError,
    ) -> Result<(), kube::Error> {
        let api: Api<DynamicObject> = Api::namespaced_with(
            self.client.clone(),
            &owner.namespace,
            &resource("", "v1", "Event", "events"),
        );
        let now = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
        let event: DynamicObject =
            serde_json::from_value(failure_event_manifest(owner, &error.to_string(), &now))
                .map_err(kube::Error::SerdeError)?;
        api.create(&PostParams::default(), &event).await.map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{mock_client, Recorded};
    use std::sync::{Arc, Mutex};

    fn owner() -> SandboxOwner {
        SandboxOwner {
            namespace: "sandboxes".to_string(),
            name: "ws--sb".to_string(),
            uid: "cr-uid".to_string(),
            api_version: "agents.x-k8s.io/v1beta1".to_string(),
        }
    }

    /// What the gateway hands `after_create`: in Shared mode the CR is named
    /// `{workspace}--{name}`, i.e. `ws--sb` here.
    fn sandbox(workspace: &str, name: &str) -> DriverSandbox {
        DriverSandbox {
            id: "sb-id".to_string(),
            name: name.to_string(),
            workspace: workspace.to_string(),
            ..Default::default()
        }
    }

    fn config(search_namespace: Option<&str>) -> ExposureConfig {
        ExposureConfig {
            cluster_domain: "example.org".to_string(),
            ingress_namespace: "istio-system".to_string(),
            search_namespace: search_namespace.map(str::to_string),
        }
    }

    enum Scenario {
        Ok,
        ApiRuleRejected,
        NoSandbox,
        /// The cluster serves the Sandbox CRD at `v1alpha1` only.
        OnlyV1Alpha1,
        /// `OnlyV1Alpha1`, and the APIRule is rejected.
        OnlyV1Alpha1ApiRuleRejected,
        /// Neither Sandbox API version is served.
        NoSandboxApi,
        /// Two Sandbox CRs carry the sandbox id.
        TwoSandboxes,
        /// Managed mode: the CR is named bare (`dev`) in the workspace's own namespace.
        Managed(&'static str),
    }

    fn not_found() -> String {
        json!({
            "kind": "Status", "apiVersion": "v1", "metadata": {},
            "status": "Failure", "reason": "NotFound", "code": 404,
            "message": "the server could not find the requested resource"
        })
        .to_string()
    }

    fn sandbox_cr(api_version: &str, namespace: &str, name: &str, uid: &str) -> Value {
        json!({
            "apiVersion": api_version,
            "kind": "Sandbox",
            "metadata": {"name": name, "namespace": namespace, "uid": uid}
        })
    }

    fn respond(scenario: Scenario) -> impl Fn(&str) -> (u16, String) + Send + Sync + 'static {
        move |line: &str| {
            if line.starts_with("GET ") && line.ends_with("/sandboxes") {
                let only_v1alpha1 = matches!(
                    scenario,
                    Scenario::OnlyV1Alpha1 | Scenario::OnlyV1Alpha1ApiRuleRejected
                );
                if matches!(scenario, Scenario::NoSandboxApi)
                    || (only_v1alpha1 && line.contains("/v1beta1/"))
                {
                    return (404, not_found());
                }
                let api_version = if only_v1alpha1 {
                    "agents.x-k8s.io/v1alpha1"
                } else {
                    "agents.x-k8s.io/v1beta1"
                };
                let cr = |namespace: &str, name: &str, uid: &str| {
                    sandbox_cr(api_version, namespace, name, uid)
                };
                let items = match scenario {
                    Scenario::NoSandbox => json!([]),
                    Scenario::TwoSandboxes => json!([
                        cr("sandboxes", "ws--sb", "cr-uid"),
                        cr("sandboxes", "ws--sb-2", "cr-uid-2")
                    ]),
                    Scenario::Managed(workspace) => {
                        json!([cr(workspace, "dev", &format!("uid-{workspace}"))])
                    }
                    _ => json!([cr("sandboxes", "ws--sb", "cr-uid")]),
                };
                let list = json!({
                    "apiVersion": api_version,
                    "kind": "SandboxList",
                    "metadata": {},
                    "items": items
                });
                return (200, list.to_string());
            }
            if matches!(
                scenario,
                Scenario::ApiRuleRejected | Scenario::OnlyV1Alpha1ApiRuleRejected
            ) && line.contains("/apirules/")
            {
                return (404, not_found());
            }
            (
                200,
                json!({"apiVersion": "v1", "kind": "Object", "metadata": {"name": "ok"}})
                    .to_string(),
            )
        }
    }

    fn lines(seen: &Arc<Mutex<Vec<Recorded>>>) -> Vec<String> {
        seen.lock()
            .unwrap()
            .iter()
            .map(|r| r.line.clone())
            .collect()
    }

    /// The query string with the characters `kube` percent-encodes in a label
    /// selector turned back, so assertions read like the selector.
    fn decoded(query: &str) -> String {
        query
            .replace("%2F", "/")
            .replace("%3D", "=")
            .replace("%2C", ",")
    }

    fn json_body(recorded: &Recorded) -> Value {
        serde_json::from_str(&recorded.body).expect("a JSON body")
    }

    #[test]
    fn service_selects_only_the_workload_pod() {
        let service = service_manifest(&owner(), "SB-ID");
        let selector = &service["spec"]["selector"];
        assert_eq!(selector[BOUNDARY_PAIR_LABEL], "sb-id");
        assert_eq!(selector[BOUNDARY_ROLE_LABEL], WORKLOAD_ROLE);
        assert!(
            selector.get(SANDBOX_ID_LABEL).is_none(),
            "sandbox-id would also match the supervisor"
        );
        assert_eq!(service["spec"]["ports"][0]["port"], EXPOSE_PORT);
        assert_eq!(service["metadata"]["name"], "ws--sb-svc");
    }

    #[test]
    fn objects_are_labelled_as_ours_and_owned_by_the_sandbox() {
        let owner = owner();
        for manifest in [
            service_manifest(&owner, "sb-id"),
            ingress_policy_manifest(&owner, "sb-id", "istio-system"),
            apirule_manifest(&owner, "sb-id", "ws--sb", "example.org"),
        ] {
            let labels = &manifest["metadata"]["labels"];
            assert_eq!(labels[MANAGED_BY_LABEL], MANAGED_BY_VALUE);
            assert_eq!(labels[SANDBOX_ID_LABEL], "sb-id");
            assert!(
                labels.get("openshell.ai/managed-by").is_none(),
                "must never look like upstream's"
            );
            let reference = &manifest["metadata"]["ownerReferences"][0];
            assert_eq!(reference["kind"], "Sandbox");
            assert_eq!(reference["uid"], "cr-uid");
            assert_eq!(reference["apiVersion"], "agents.x-k8s.io/v1beta1");
            assert_eq!(manifest["metadata"]["namespace"], "sandboxes");
        }
    }

    #[test]
    fn ingress_policy_admits_only_the_istio_gateway_on_8080() {
        let policy = ingress_policy_manifest(&owner(), "sb-id", "istio-system");
        assert_eq!(
            policy["spec"]["policyTypes"],
            json!(["Ingress"]),
            "must never touch egress"
        );
        assert_eq!(
            policy["spec"]["podSelector"]["matchLabels"][BOUNDARY_ROLE_LABEL],
            WORKLOAD_ROLE
        );
        let from = &policy["spec"]["ingress"][0]["from"][0];
        assert_eq!(
            from["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"],
            "istio-system"
        );
        assert_eq!(
            from["podSelector"]["matchLabels"]["istio"],
            "ingressgateway"
        );
        assert_eq!(
            policy["spec"]["ingress"][0]["ports"][0]["port"],
            EXPOSE_PORT
        );
        assert_eq!(policy["metadata"]["name"], "ws--sb-expose");
    }

    #[test]
    fn apirule_host_uses_the_workspace_qualified_name() {
        let rule = apirule_manifest(&owner(), "sb-id", "ws--sb", "example.org");
        assert_eq!(rule["apiVersion"], "gateway.kyma-project.io/v2");
        assert_eq!(rule["spec"]["hosts"], json!(["ws--sb.example.org"]));
        assert_eq!(rule["spec"]["service"]["name"], "ws--sb-svc");
        assert_eq!(rule["spec"]["service"]["port"], EXPOSE_PORT);
        assert_eq!(rule["spec"]["gateway"], KYMA_GATEWAY);
    }

    #[test]
    fn host_label_is_workspace_and_name_in_every_mode() {
        assert_eq!(host_label("a", "dev"), "a--dev");
    }

    #[tokio::test]
    async fn reconcile_applies_service_policy_and_apirule_in_order() {
        let (client, seen) = mock_client(respond(Scenario::Ok));
        ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile(&sandbox("ws", "sb"))
            .await
            .expect("exposure succeeds");
        assert_eq!(
            lines(&seen),
            vec![
                "GET /apis/agents.x-k8s.io/v1beta1/namespaces/sandboxes/sandboxes",
                "PATCH /api/v1/namespaces/sandboxes/services/ws--sb-svc",
                "PATCH /apis/networking.k8s.io/v1/namespaces/sandboxes/networkpolicies/ws--sb-expose",
                "PATCH /apis/gateway.kyma-project.io/v2/namespaces/sandboxes/apirules/ws--sb",
            ]
        );
    }

    #[tokio::test]
    async fn lookup_and_apply_carry_the_expected_query_parameters() {
        let (client, seen) = mock_client(respond(Scenario::Ok));
        ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile(&sandbox("ws", "sb"))
            .await
            .expect("exposure succeeds");
        let recorded = seen.lock().unwrap().clone();
        // Upstream's own lookup pairs managed-by with the id; so must ours.
        assert!(
            decoded(&recorded[0].query).contains(
                "labelSelector=openshell.ai/managed-by=openshell,openshell.ai/sandbox-id=sb-id"
            ),
            "{}",
            recorded[0].query
        );
        let patches: Vec<_> = recorded
            .iter()
            .filter(|r| r.line.starts_with("PATCH "))
            .collect();
        assert_eq!(patches.len(), 3);
        for patch in patches {
            assert!(
                patch.query.contains("fieldManager=openshell-driver-kyma"),
                "{}: {}",
                patch.line,
                patch.query
            );
            assert!(
                patch.query.contains("force=true"),
                "{}: {}",
                patch.line,
                patch.query
            );
        }
    }

    // Review Focus 4.
    #[tokio::test]
    async fn shared_mode_lookup_is_namespaced() {
        let (client, seen) = mock_client(respond(Scenario::Ok));
        ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile(&sandbox("ws", "sb"))
            .await
            .unwrap();
        assert!(lines(&seen)[0].contains("/namespaces/sandboxes/sandboxes"));

        let (client, seen) = mock_client(respond(Scenario::Ok));
        ExposureReconciler::new(client, config(None))
            .reconcile(&sandbox("ws", "sb"))
            .await
            .unwrap();
        assert_eq!(
            lines(&seen)[0],
            "GET /apis/agents.x-k8s.io/v1beta1/sandboxes"
        );
    }

    // Two workspaces may each have a sandbox `dev`; in Managed mode both CRs
    // are named `dev` (in their own namespaces), so the host must not be.
    #[tokio::test]
    async fn managed_mode_hosts_never_collide_across_workspaces() {
        let mut hosts = Vec::new();
        for workspace in ["a", "b"] {
            let (client, seen) = mock_client(respond(Scenario::Managed(workspace)));
            ExposureReconciler::new(client, config(None))
                .reconcile(&sandbox(workspace, "dev"))
                .await
                .expect("exposure succeeds");
            let recorded = seen.lock().unwrap().clone();
            let rule = recorded
                .iter()
                .find(|r| r.line.contains("/apirules/"))
                .expect("an APIRule was applied");
            assert_eq!(
                rule.line,
                format!(
                    "PATCH /apis/gateway.kyma-project.io/v2/namespaces/{workspace}/apirules/dev"
                )
            );
            hosts.push(json_body(rule)["spec"]["hosts"][0].clone());
        }
        assert_eq!(
            hosts,
            [json!("a--dev.example.org"), json!("b--dev.example.org")]
        );
    }

    // Review Focus 3.
    #[tokio::test]
    async fn apirule_failure_emits_a_warning_event() {
        let (client, seen) = mock_client(respond(Scenario::ApiRuleRejected));
        let err = ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile(&sandbox("ws", "sb"))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("APIRule"), "{err}");
        let recorded = seen.lock().unwrap().clone();
        let event = recorded
            .iter()
            .find(|r| r.line == "POST /api/v1/namespaces/sandboxes/events")
            .expect("a Warning Event was recorded");
        assert!(event.body.contains("\"Warning\""), "{}", event.body);
        assert!(event.body.contains("ExposureFailed"), "{}", event.body);
        assert!(
            event.body.contains("cr-uid"),
            "event must point at the Sandbox: {}",
            event.body
        );
    }

    // `kubectl describe` shows an Event's age from these.
    #[tokio::test]
    async fn failure_event_carries_timestamps_and_a_count() {
        let (client, seen) = mock_client(respond(Scenario::ApiRuleRejected));
        ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile(&sandbox("ws", "sb"))
            .await
            .unwrap_err();
        let recorded = seen.lock().unwrap().clone();
        let event = json_body(
            recorded
                .iter()
                .find(|r| r.line.starts_with("POST "))
                .expect("a Warning Event was recorded"),
        );
        let first = event["firstTimestamp"].as_str().expect("firstTimestamp");
        let last = event["lastTimestamp"].as_str().expect("lastTimestamp");
        assert_eq!(first, last);
        // RFC 3339, second precision, UTC: 2026-09-29T07:33:00Z
        let bytes = first.as_bytes();
        assert_eq!(bytes.len(), 20, "{first}");
        assert_eq!(
            (bytes[4], bytes[7], bytes[10]),
            (b'-', b'-', b'T'),
            "{first}"
        );
        assert_eq!(
            (bytes[13], bytes[16], bytes[19]),
            (b':', b':', b'Z'),
            "{first}"
        );
        assert_eq!(event["count"], 1);
    }

    #[tokio::test]
    async fn missing_sandbox_is_reported_without_an_event() {
        let (client, seen) = mock_client(respond(Scenario::NoSandbox));
        let err = ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile(&sandbox("ws", "sb"))
            .await
            .unwrap_err();
        assert!(matches!(err, ExposureError::SandboxNotFound(_)));
        assert!(lines(&seen).iter().all(|line| !line.starts_with("POST ")));
    }

    #[tokio::test]
    async fn several_matching_sandboxes_are_reported_not_guessed() {
        let (client, seen) = mock_client(respond(Scenario::TwoSandboxes));
        let err = ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile(&sandbox("ws", "sb"))
            .await
            .unwrap_err();
        assert!(
            matches!(&err, ExposureError::AmbiguousSandbox { count: 2, .. }),
            "{err}"
        );
        let message = err.to_string();
        assert!(
            message.contains("sb-id") && message.contains('2'),
            "{message}"
        );
        assert_eq!(
            lines(&seen).len(),
            1,
            "nothing is applied for an ambiguous sandbox"
        );
    }

    // R26: mirror upstream's Sandbox API version fallback.
    #[tokio::test]
    async fn sandbox_lookup_falls_back_to_v1alpha1_on_404() {
        let (client, seen) = mock_client(respond(Scenario::OnlyV1Alpha1));
        ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile(&sandbox("ws", "sb"))
            .await
            .expect("exposure succeeds");
        assert_eq!(
            lines(&seen),
            vec![
                "GET /apis/agents.x-k8s.io/v1beta1/namespaces/sandboxes/sandboxes",
                "GET /apis/agents.x-k8s.io/v1alpha1/namespaces/sandboxes/sandboxes",
                "PATCH /api/v1/namespaces/sandboxes/services/ws--sb-svc",
                "PATCH /apis/networking.k8s.io/v1/namespaces/sandboxes/networkpolicies/ws--sb-expose",
                "PATCH /apis/gateway.kyma-project.io/v2/namespaces/sandboxes/apirules/ws--sb",
            ]
        );
        let recorded = seen.lock().unwrap().clone();
        let patches: Vec<_> = recorded
            .iter()
            .filter(|r| r.line.starts_with("PATCH "))
            .collect();
        assert_eq!(patches.len(), 3);
        for patch in patches {
            assert_eq!(
                json_body(patch)["metadata"]["ownerReferences"][0]["apiVersion"],
                "agents.x-k8s.io/v1alpha1",
                "{}",
                patch.line
            );
        }
    }

    #[tokio::test]
    async fn fallback_failure_event_names_the_v1alpha1_sandbox() {
        let (client, seen) = mock_client(respond(Scenario::OnlyV1Alpha1ApiRuleRejected));
        ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile(&sandbox("ws", "sb"))
            .await
            .unwrap_err();
        let recorded = seen.lock().unwrap().clone();
        let event = json_body(
            recorded
                .iter()
                .find(|r| r.line == "POST /api/v1/namespaces/sandboxes/events")
                .expect("a Warning Event was recorded"),
        );
        assert_eq!(
            event["involvedObject"]["apiVersion"],
            "agents.x-k8s.io/v1alpha1"
        );
    }

    #[tokio::test]
    async fn both_sandbox_api_versions_missing_fails_without_writes() {
        let (client, seen) = mock_client(respond(Scenario::NoSandboxApi));
        let err = ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile(&sandbox("ws", "sb"))
            .await
            .unwrap_err();
        assert!(matches!(err, ExposureError::Kube { .. }), "{err}");
        assert_eq!(
            lines(&seen),
            vec![
                "GET /apis/agents.x-k8s.io/v1beta1/namespaces/sandboxes/sandboxes",
                "GET /apis/agents.x-k8s.io/v1alpha1/namespaces/sandboxes/sandboxes",
            ]
        );
    }
}
