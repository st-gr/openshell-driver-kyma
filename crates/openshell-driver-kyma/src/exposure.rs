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

use kube::api::{Api, ApiResource, DynamicObject, ListParams, Patch, PatchParams, PostParams};
use kube::core::GroupVersionKind;
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

pub fn apirule_manifest(owner: &SandboxOwner, sandbox_id: &str, cluster_domain: &str) -> Value {
    json!({
        "apiVersion": "gateway.kyma-project.io/v2",
        "kind": "APIRule",
        "metadata": metadata(owner, &owner.name, sandbox_id),
        "spec": {
            "gateway": KYMA_GATEWAY,
            // Workspace-qualified, so two sandboxes named `dev` in different
            // workspaces never claim the same host.
            "hosts": [format!("{}.{cluster_domain}", owner.name)],
            "service": {"name": service_name(&owner.name), "port": EXPOSE_PORT},
            "rules": [{"path": "/*", "methods": ["GET", "POST"], "noAuth": true}],
        },
    })
}

fn failure_event_manifest(owner: &SandboxOwner, message: &str) -> Value {
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
    pub async fn reconcile(&self, sandbox_id: &str) -> Result<(), ExposureError> {
        let owner = self.find_owner(sandbox_id).await?;
        if let Err(error) = self.expose(&owner, sandbox_id).await {
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
        let object = list
            .items
            .into_iter()
            .next()
            .ok_or_else(|| ExposureError::SandboxNotFound(sandbox_id.to_string()))?;
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
        api.list(&ListParams::default().labels(&format!("{SANDBOX_ID_LABEL}={sandbox_id}")))
            .await
    }

    async fn expose(&self, owner: &SandboxOwner, sandbox_id: &str) -> Result<(), ExposureError> {
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
            apirule_manifest(owner, sandbox_id, &self.config.cluster_domain),
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
        let event: DynamicObject =
            serde_json::from_value(failure_event_manifest(owner, &error.to_string()))
                .map_err(kube::Error::SerdeError)?;
        api.create(&PostParams::default(), &event).await.map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::mock_client;

    fn owner() -> SandboxOwner {
        SandboxOwner {
            namespace: "sandboxes".to_string(),
            name: "ws--sb".to_string(),
            uid: "cr-uid".to_string(),
            api_version: "agents.x-k8s.io/v1beta1".to_string(),
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
    }

    fn not_found() -> String {
        json!({
            "kind": "Status", "apiVersion": "v1", "metadata": {},
            "status": "Failure", "reason": "NotFound", "code": 404,
            "message": "the server could not find the requested resource"
        })
        .to_string()
    }

    fn respond(scenario: Scenario) -> impl Fn(&str) -> (u16, String) + Send + Sync + 'static {
        move |line: &str| {
            if line.starts_with("GET ") && line.ends_with("/sandboxes") {
                let only_v1alpha1 = matches!(scenario, Scenario::OnlyV1Alpha1);
                if only_v1alpha1 && line.contains("/v1beta1/") {
                    return (404, not_found());
                }
                let api_version = if only_v1alpha1 {
                    "agents.x-k8s.io/v1alpha1"
                } else {
                    "agents.x-k8s.io/v1beta1"
                };
                let items = match scenario {
                    Scenario::NoSandbox => json!([]),
                    _ => json!([{
                        "apiVersion": api_version,
                        "kind": "Sandbox",
                        "metadata": {"name": "ws--sb", "namespace": "sandboxes", "uid": "cr-uid"}
                    }]),
                };
                let list = json!({
                    "apiVersion": api_version,
                    "kind": "SandboxList",
                    "metadata": {},
                    "items": items
                });
                return (200, list.to_string());
            }
            if matches!(scenario, Scenario::ApiRuleRejected) && line.contains("/apirules/") {
                return (404, not_found());
            }
            (
                200,
                json!({"apiVersion": "v1", "kind": "Object", "metadata": {"name": "ok"}})
                    .to_string(),
            )
        }
    }

    fn lines(
        seen: &std::sync::Arc<std::sync::Mutex<Vec<crate::test_support::Recorded>>>,
    ) -> Vec<String> {
        seen.lock()
            .unwrap()
            .iter()
            .map(|r| r.line.clone())
            .collect()
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
            apirule_manifest(&owner, "sb-id", "example.org"),
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
        let rule = apirule_manifest(&owner(), "sb-id", "example.org");
        assert_eq!(rule["apiVersion"], "gateway.kyma-project.io/v2");
        assert_eq!(rule["spec"]["hosts"], json!(["ws--sb.example.org"]));
        assert_eq!(rule["spec"]["service"]["name"], "ws--sb-svc");
        assert_eq!(rule["spec"]["service"]["port"], EXPOSE_PORT);
        assert_eq!(rule["spec"]["gateway"], KYMA_GATEWAY);
    }

    #[tokio::test]
    async fn reconcile_applies_service_policy_and_apirule_in_order() {
        let (client, seen) = mock_client(respond(Scenario::Ok));
        ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile("sb-id")
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

    // Review Focus 4.
    #[tokio::test]
    async fn shared_mode_lookup_is_namespaced() {
        let (client, seen) = mock_client(respond(Scenario::Ok));
        ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile("sb-id")
            .await
            .unwrap();
        assert!(lines(&seen)[0].contains("/namespaces/sandboxes/sandboxes"));

        let (client, seen) = mock_client(respond(Scenario::Ok));
        ExposureReconciler::new(client, config(None))
            .reconcile("sb-id")
            .await
            .unwrap();
        assert_eq!(
            lines(&seen)[0],
            "GET /apis/agents.x-k8s.io/v1beta1/sandboxes"
        );
    }

    // Review Focus 3.
    #[tokio::test]
    async fn apirule_failure_emits_a_warning_event() {
        let (client, seen) = mock_client(respond(Scenario::ApiRuleRejected));
        let err = ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile("sb-id")
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

    #[tokio::test]
    async fn missing_sandbox_is_reported_without_an_event() {
        let (client, seen) = mock_client(respond(Scenario::NoSandbox));
        let err = ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile("sb-id")
            .await
            .unwrap_err();
        assert!(matches!(err, ExposureError::SandboxNotFound(_)));
        assert!(lines(&seen).iter().all(|line| !line.starts_with("POST ")));
    }

    // R26: mirror upstream's Sandbox API version fallback.
    #[tokio::test]
    async fn sandbox_lookup_falls_back_to_v1alpha1_on_404() {
        let (client, seen) = mock_client(respond(Scenario::OnlyV1Alpha1));
        ExposureReconciler::new(client, config(Some("sandboxes")))
            .reconcile("sb-id")
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
            let manifest: Value = serde_json::from_str(&patch.body).expect("a JSON manifest");
            assert_eq!(
                manifest["metadata"]["ownerReferences"][0]["apiVersion"],
                "agents.x-k8s.io/v1alpha1",
                "{}",
                patch.line
            );
        }
    }
}
