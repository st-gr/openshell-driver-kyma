//! `KymaEnricher` — the `PlatformEnricher` impl with Kyma-specific
//! behaviors: Pod Security Admission (PSA) detection, Istio sidecar
//! injection toggle, and optional `APIRule` rendering.
//!
//! Like the provisioner, HTTP-touching methods (`detect_psa`) are exercised
//! by the Tier-3 live-cluster tests; this file's unit tests cover the pure
//! mutation logic.

use crate::config::Config;
use crate::error::DriverError;
use crate::interfaces::PlatformEnricher;
use async_trait::async_trait;
use k8s_openapi::api::core::v1::Namespace;
use kube::{api::Api, Client};
use serde_json::{json, Value};

const PSA_LABEL: &str = "pod-security.kubernetes.io/enforce";
const REQUIRED_PSA_VALUE: &str = "privileged";
const ISTIO_INJECT_LABEL: &str = "sidecar.istio.io/inject";

/// `KymaEnricher` adapts the pod template and renders the optional APIRule.
pub struct KymaEnricher {
    client: Client,
    cfg: Config,
}

impl KymaEnricher {
    /// Build an enricher around an existing `kube::Client` and `Config`.
    #[must_use]
    pub fn new(client: Client, cfg: Config) -> Self {
        Self { client, cfg }
    }
}

#[async_trait]
impl PlatformEnricher for KymaEnricher {
    async fn detect_psa(&self, namespace: &str) -> Result<String, DriverError> {
        let ns_api: Api<Namespace> = Api::all(self.client.clone());
        let ns = ns_api.get(namespace).await.map_err(|e| match e {
            kube::Error::Api(s) if s.code == 404 => {
                DriverError::FailedPrecondition(format!("namespace {namespace} not found"))
            }
            other => DriverError::Kube(other),
        })?;

        let value = ns
            .metadata
            .labels
            .as_ref()
            .and_then(|l| l.get(PSA_LABEL))
            .cloned()
            .unwrap_or_default();

        if value != REQUIRED_PSA_VALUE {
            return Err(DriverError::FailedPrecondition(format!(
                "namespace {namespace} must have label {PSA_LABEL}=privileged for the supervisor's elevated capabilities; current value: {:?}. Apply this label as cluster-admin: kubectl label ns {namespace} {PSA_LABEL}=privileged --overwrite",
                if value.is_empty() { "<absent>".into() } else { value.clone() }
            )));
        }

        Ok(value)
    }

    async fn enrich_pod_template(
        &self,
        mut template: Value,
        _namespace: &str,
    ) -> Result<Value, DriverError> {
        // Ensure metadata.labels exists.
        let metadata = template
            .as_object_mut()
            .and_then(|t| {
                t.entry("metadata")
                    .or_insert_with(|| json!({}))
                    .as_object_mut()
            })
            .ok_or_else(|| {
                DriverError::Internal(anyhow::anyhow!("pod template has no metadata object"))
            })?;

        let labels = metadata
            .entry("labels")
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .ok_or_else(|| {
                DriverError::Internal(anyhow::anyhow!(
                    "pod template metadata.labels is not an object"
                ))
            })?;

        if !self.cfg.istio_inject_sandboxes {
            // Stamp the deny-injection label so Istio leaves the pod alone,
            // even if the namespace has injection enabled.
            labels.insert(ISTIO_INJECT_LABEL.into(), Value::String("false".into()));
        } else {
            // Explicitly remove any prior value we added so the namespace's
            // default applies.
            labels.remove(ISTIO_INJECT_LABEL);
        }

        Ok(template)
    }

    fn render_apirule(&self, sandbox_id: &str, sandbox_name: &str) -> Option<Value> {
        if !self.cfg.enable_apirule {
            return None;
        }

        let domain = if self.cfg.cluster_domain.is_empty() {
            // The driver tries to discover the cluster domain at startup
            // when the operator hasn't set --cluster-domain. If still empty
            // here, fall back to a synthetic placeholder so render output
            // remains well-formed; the runtime startup check rejects this
            // configuration before any APIRule is created.
            "cluster.local".to_string()
        } else {
            self.cfg.cluster_domain.clone()
        };

        let host = format!("{sandbox_name}.{domain}");
        let svc_name = format!("{sandbox_name}-svc");

        Some(json!({
            "apiVersion": "gateway.kyma-project.io/v2",
            "kind": "APIRule",
            "metadata": {
                "name": sandbox_name,
                "namespace": self.cfg.namespace,
                "labels": {
                    "openshell.ai/managed-by": "openshell",
                    "openshell.ai/sandbox-id": sandbox_id,
                }
            },
            "spec": {
                "gateway": "kyma-system/kyma-gateway",
                "hosts": [host],
                "service": {
                    "name": svc_name,
                    "port": 8080
                },
                "rules": [
                    {
                        "path": "/*",
                        "methods": ["GET", "POST"],
                        "noAuth": true
                    }
                ]
            }
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_enricher(cfg: Config) -> KymaEnricher {
        let svc = tower::service_fn(|_req: http::Request<kube::client::Body>| async move {
            Ok::<_, std::convert::Infallible>(http::Response::new(kube::client::Body::empty()))
        });
        let client = Client::new(svc, cfg.namespace.clone());
        KymaEnricher::new(client, cfg)
    }

    #[tokio::test]
    async fn enrich_adds_istio_inject_false_label_when_disabled() {
        let e = make_enricher(Config {
            namespace: "ns".into(),
            istio_inject_sandboxes: false,
            ..Config::default()
        });
        let template = json!({
            "metadata": { "labels": { "existing": "v" } },
            "spec": { "containers": [] }
        });
        let out = e.enrich_pod_template(template, "ns").await.unwrap();
        assert_eq!(out["metadata"]["labels"]["existing"], "v");
        assert_eq!(
            out["metadata"]["labels"]["sidecar.istio.io/inject"],
            "false"
        );
    }

    #[tokio::test]
    async fn enrich_does_not_touch_label_when_inject_enabled() {
        let e = make_enricher(Config {
            namespace: "ns".into(),
            istio_inject_sandboxes: true,
            ..Config::default()
        });
        let template = json!({
            "metadata": { "labels": { "existing": "v" } },
            "spec": {}
        });
        let out = e.enrich_pod_template(template, "ns").await.unwrap();
        assert_eq!(out["metadata"]["labels"]["existing"], "v");
        assert!(out["metadata"]["labels"]
            .get("sidecar.istio.io/inject")
            .is_none());
    }

    #[tokio::test]
    async fn enrich_creates_metadata_labels_when_missing() {
        let e = make_enricher(Config {
            namespace: "ns".into(),
            istio_inject_sandboxes: false,
            ..Config::default()
        });
        let template = json!({ "spec": {} });
        let out = e.enrich_pod_template(template, "ns").await.unwrap();
        assert_eq!(
            out["metadata"]["labels"]["sidecar.istio.io/inject"],
            "false"
        );
    }

    #[tokio::test]
    async fn render_apirule_returns_none_when_flag_disabled() {
        let e = make_enricher(Config {
            namespace: "ns".into(),
            enable_apirule: false,
            cluster_domain: "example.com".into(),
            ..Config::default()
        });
        assert!(e.render_apirule("id-1", "sb-1").is_none());
    }

    #[tokio::test]
    async fn render_apirule_emits_v2_manifest_when_enabled() {
        let e = make_enricher(Config {
            namespace: "openshell-system".into(),
            enable_apirule: true,
            cluster_domain: "example.com".into(),
            ..Config::default()
        });
        let m = e.render_apirule("id-1", "sb-1").unwrap();
        assert_eq!(m["apiVersion"], "gateway.kyma-project.io/v2");
        assert_eq!(m["kind"], "APIRule");
        assert_eq!(m["metadata"]["name"], "sb-1");
        assert_eq!(m["metadata"]["namespace"], "openshell-system");
        assert_eq!(m["metadata"]["labels"]["openshell.ai/sandbox-id"], "id-1");
        assert_eq!(m["spec"]["hosts"][0], "sb-1.example.com");
        assert_eq!(m["spec"]["service"]["name"], "sb-1-svc");
        assert_eq!(m["spec"]["service"]["port"], 8080);
        assert_eq!(m["spec"]["rules"][0]["path"], "/*");
        let methods: Vec<&str> = m["spec"]["rules"][0]["methods"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert_eq!(methods, vec!["GET", "POST"]);
        assert_eq!(m["spec"]["rules"][0]["noAuth"], true);
    }

    #[tokio::test]
    async fn render_apirule_uses_fallback_domain_when_cluster_domain_empty() {
        let e = make_enricher(Config {
            namespace: "ns".into(),
            enable_apirule: true,
            cluster_domain: String::new(),
            ..Config::default()
        });
        let m = e.render_apirule("id-1", "sb-1").unwrap();
        assert_eq!(m["spec"]["hosts"][0], "sb-1.cluster.local");
    }
}
