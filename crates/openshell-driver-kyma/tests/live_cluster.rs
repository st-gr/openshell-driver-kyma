//! Tier-3 live-cluster integration tests.
//!
//! These tests provision real Sandbox CRs against a real Kubernetes cluster
//! (typically a Kyma cluster). They are **gated** behind the `integration`
//! Cargo feature so they only compile when explicitly requested:
//!
//! ```sh
//! INTEGRATION_TEST_NAMESPACE=openshell-driver-test \
//!   cargo test -p openshell-driver-kyma --test live_cluster \
//!     --features integration -- --test-threads=1
//! ```
//!
//! Safety contract — these tests REFUSE to run in any system namespace.
//! The deny-list is hardcoded for well-known system namespaces (default,
//! kube-system, kube-public, kube-node-lease, istio-system, kyma-system,
//! agent-sandbox-system) and is extensible at runtime via the
//! `INTEGRATION_TEST_NAMESPACE_DENYLIST` env var (comma-separated). If the
//! configured namespace is denied, the harness panics before any HTTP
//! traffic is generated.

#![cfg(all(unix, feature = "integration"))]

use computev1::pb::{
    CreateSandboxRequest, DeleteSandboxRequest, DriverSandbox, DriverSandboxSpec,
    DriverSandboxTemplate, GetSandboxRequest, ListSandboxesRequest,
};
use computev1::pb::compute_driver_server::ComputeDriver;
use k8s_openapi::api::core::v1::Namespace;
use kube::{
    api::{Api, ListParams, PatchParams, PostParams},
    core::{ApiResource, DynamicObject, GroupVersionKind, ObjectMeta},
    Client,
};
use openshell_driver_kyma::{
    config::Config,
    driver::Driver,
    enricher::KymaEnricher,
    interfaces::{DriverMetrics, PlatformEnricher, SandboxProvisioner},
    metrics::PrometheusMetrics,
    provisioner::KymaProvisioner,
};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tonic::Request;

const SANDBOX_GROUP: &str = "agents.x-k8s.io";
const SANDBOX_VERSION: &str = "v1alpha1";
const SANDBOX_KIND: &str = "Sandbox";
const SANDBOX_PLURAL: &str = "sandboxes";
const PSA_LABEL: &str = "pod-security.kubernetes.io/enforce";
const MANAGED_BY: &str = "openshell.ai/managed-by";

const SYSTEM_DENYLIST: &[&str] = &[
    "default",
    "kube-system",
    "kube-public",
    "kube-node-lease",
    "istio-system",
    "kyma-system",
    "agent-sandbox-system",
];

/// Read the test namespace from `INTEGRATION_TEST_NAMESPACE`, panicking if
/// the value is on the deny-list. Operators can extend the deny-list at
/// runtime via `INTEGRATION_TEST_NAMESPACE_DENYLIST` (comma-separated).
fn integration_namespace() -> Option<String> {
    let ns = std::env::var("INTEGRATION_TEST_NAMESPACE").ok()?;
    let ns = ns.trim().to_string();
    if ns.is_empty() {
        return None;
    }

    let mut denylist: Vec<String> = SYSTEM_DENYLIST.iter().map(|s| (*s).into()).collect();
    if let Ok(extra) = std::env::var("INTEGRATION_TEST_NAMESPACE_DENYLIST") {
        for n in extra.split(',') {
            let n = n.trim();
            if !n.is_empty() {
                denylist.push(n.to_string());
            }
        }
    }

    if denylist.iter().any(|d| d == &ns) {
        panic!(
            "Refusing to run integration tests against denylisted namespace {ns:?}.\n\
             System denylist: {SYSTEM_DENYLIST:?}\n\
             Set INTEGRATION_TEST_NAMESPACE to a project-owned namespace and\n\
             optionally extend the denylist via INTEGRATION_TEST_NAMESPACE_DENYLIST."
        );
    }
    Some(ns)
}

fn sandbox_api_resource() -> ApiResource {
    ApiResource::from_gvk_with_plural(
        &GroupVersionKind {
            group: SANDBOX_GROUP.into(),
            version: SANDBOX_VERSION.into(),
            kind: SANDBOX_KIND.into(),
        },
        SANDBOX_PLURAL,
    )
}

/// Build a kube::Client from the ambient env (incluster or kubeconfig).
async fn build_client() -> Client {
    if let Ok(config) = kube::Config::incluster() {
        return Client::try_from(config).expect("client from incluster config");
    }
    let config = kube::Config::infer().await.expect("infer kubeconfig");
    Client::try_from(config).expect("client from kubeconfig")
}

/// Verify the Sandbox CRD is installed; returns `true` if reachable.
async fn sandbox_crd_present(client: &Client) -> bool {
    let ar = sandbox_api_resource();
    // Try a list with limit=1 in a known-safe namespace; any response
    // (including empty) means the CRD is registered.
    let api: Api<DynamicObject> =
        Api::namespaced_with(client.clone(), "default", &ar);
    api.list(&ListParams::default().limit(1)).await.is_ok()
}

/// Ensure the test namespace exists and is labeled
/// `pod-security.kubernetes.io/enforce: privileged`. Idempotent.
async fn ensure_test_namespace(client: &Client, ns: &str) {
    let ns_api: Api<Namespace> = Api::all(client.clone());

    // Create or patch.
    if ns_api.get(ns).await.is_err() {
        let mut labels = BTreeMap::new();
        labels.insert(PSA_LABEL.into(), "privileged".into());
        labels.insert(MANAGED_BY.into(), "openshell-driver-kyma-test".into());
        let body = Namespace {
            metadata: ObjectMeta {
                name: Some(ns.into()),
                labels: Some(labels),
                ..Default::default()
            },
            ..Default::default()
        };
        ns_api
            .create(&PostParams::default(), &body)
            .await
            .expect("create test namespace");
    } else {
        // Patch the PSA label in case it was removed.
        let patch = serde_json::json!({
            "metadata": { "labels": { PSA_LABEL: "privileged" } }
        });
        ns_api
            .patch(
                ns,
                &PatchParams::apply("openshell-driver-kyma-test").force(),
                &kube::api::Patch::Apply(&patch),
            )
            .await
            .expect("patch PSA label");
    }
}

/// Setup helper used at the top of each test. Returns `None` if the
/// integration env-var is unset (test is skipped).
async fn setup_integration() -> Option<(Driver, Client, String)> {
    let ns = match integration_namespace() {
        Some(n) => n,
        None => {
            eprintln!(
                "INTEGRATION_TEST_NAMESPACE not set; skipping live cluster tests."
            );
            return None;
        }
    };

    let client = build_client().await;

    if !sandbox_crd_present(&client).await {
        eprintln!(
            "Sandbox CRD ({SANDBOX_GROUP}/{SANDBOX_VERSION}) not installed on the\n\
             cluster; skipping live cluster tests.\n\
             Install with:\n  kubectl apply -f \\\n    https://raw.githubusercontent.com/kubernetes-sigs/agent-sandbox/main/k8s/crds/agents.x-k8s.io_sandboxes.yaml"
        );
        return None;
    }

    ensure_test_namespace(&client, &ns).await;

    let cfg = Config {
        namespace: ns.clone(),
        ..Config::default()
    };
    let provisioner =
        Arc::new(KymaProvisioner::new(client.clone(), cfg.clone())) as Arc<dyn SandboxProvisioner>;
    let enricher =
        Arc::new(KymaEnricher::new(client.clone(), cfg.clone())) as Arc<dyn PlatformEnricher>;
    let metrics = Arc::new(PrometheusMetrics::new().unwrap()) as Arc<dyn DriverMetrics>;
    let driver = Driver::new_with_deps(provisioner, enricher, metrics, cfg);

    Some((driver, client, ns))
}

/// Best-effort cleanup: delete every Sandbox CR in the test namespace
/// labeled `openshell.ai/managed-by=openshell`. Called at the end of
/// each test via a guard.
async fn cleanup_sandboxes(client: &Client, ns: &str) {
    let ar = sandbox_api_resource();
    let api: Api<DynamicObject> = Api::namespaced_with(client.clone(), ns, &ar);
    let lp = ListParams::default().labels(&format!("{MANAGED_BY}=openshell"));
    if let Ok(list) = api.list(&lp).await {
        for item in list.items {
            if let Some(name) = item.metadata.name {
                let _ = api.delete(&name, &Default::default()).await;
            }
        }
    }
}

fn unique_name(prefix: &str) -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{prefix}-{nanos}")
}

fn make_create_request(name: &str, image: &str) -> CreateSandboxRequest {
    CreateSandboxRequest {
        sandbox: Some(DriverSandbox {
            id: format!("id-{name}"),
            name: name.into(),
            spec: Some(DriverSandboxSpec {
                template: Some(DriverSandboxTemplate {
                    image: image.into(),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        }),
    }
}

// ---------------------------------------------------------------------------
// Deny-list tests (do not require a cluster)
// ---------------------------------------------------------------------------

#[test]
#[should_panic(expected = "denylisted")]
fn denylist_kube_system_panics() {
    std::env::set_var("INTEGRATION_TEST_NAMESPACE", "kube-system");
    let _ = integration_namespace();
}

#[test]
#[should_panic(expected = "denylisted")]
fn denylist_extra_via_env_panics() {
    std::env::set_var("INTEGRATION_TEST_NAMESPACE", "verboten");
    std::env::set_var("INTEGRATION_TEST_NAMESPACE_DENYLIST", "verboten,other");
    let _ = integration_namespace();
}

// ---------------------------------------------------------------------------
// Live tests — skip silently when INTEGRATION_TEST_NAMESPACE is unset.
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn test_create_and_list_sandbox() {
    let Some((driver, client, ns)) = setup_integration().await else { return; };
    let name = unique_name("create-list");

    driver
        .create_sandbox(Request::new(make_create_request(&name, "agent:1.0")))
        .await
        .expect("create");

    let list = driver
        .list_sandboxes(Request::new(ListSandboxesRequest {}))
        .await
        .expect("list")
        .into_inner();
    assert!(
        list.sandboxes.iter().any(|s| s.name == name),
        "sandbox {name} not found in list"
    );

    cleanup_sandboxes(&client, &ns).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn test_get_sandbox() {
    let Some((driver, client, ns)) = setup_integration().await else { return; };
    let name = unique_name("get");

    driver
        .create_sandbox(Request::new(make_create_request(&name, "agent:1.0")))
        .await
        .expect("create");

    let got = driver
        .get_sandbox(Request::new(GetSandboxRequest {
            sandbox_id: format!("id-{name}"),
            sandbox_name: name.clone(),
        }))
        .await
        .expect("get")
        .into_inner();
    let sb = got.sandbox.expect("sandbox in response");
    assert_eq!(sb.name, name);
    assert_eq!(sb.id, format!("id-{name}"));
    assert_eq!(sb.namespace, ns);

    cleanup_sandboxes(&client, &ns).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn test_delete_sandbox_idempotent() {
    let Some((driver, client, ns)) = setup_integration().await else { return; };
    let name = unique_name("delete");

    driver
        .create_sandbox(Request::new(make_create_request(&name, "agent:1.0")))
        .await
        .expect("create");

    let r = driver
        .delete_sandbox(Request::new(DeleteSandboxRequest {
            sandbox_id: format!("id-{name}"),
            sandbox_name: name.clone(),
        }))
        .await
        .expect("delete")
        .into_inner();
    assert!(r.deleted);

    // Second delete on the same name returns Deleted=false (idempotent).
    let r = driver
        .delete_sandbox(Request::new(DeleteSandboxRequest {
            sandbox_id: format!("id-{name}"),
            sandbox_name: name,
        }))
        .await
        .expect("second delete")
        .into_inner();
    assert!(!r.deleted);

    cleanup_sandboxes(&client, &ns).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn test_verify_labels_and_supervisor_init_container() {
    let Some((driver, client, ns)) = setup_integration().await else { return; };
    let name = unique_name("verify");

    driver
        .create_sandbox(Request::new(make_create_request(&name, "agent:1.0")))
        .await
        .expect("create");

    // Read raw CR via the dynamic client to inspect the label set + spec.
    let ar = sandbox_api_resource();
    let api: Api<DynamicObject> = Api::namespaced_with(client.clone(), &ns, &ar);
    let obj = api.get(&name).await.expect("read CR");

    // Required labels.
    let labels = obj.metadata.labels.expect("labels present");
    assert_eq!(labels.get("openshell.ai/managed-by").map(|s| s.as_str()), Some("openshell"));
    assert_eq!(labels.get("kagenti.io/type").map(|s| s.as_str()), Some("agent"));
    assert_eq!(labels.get("openshell.ai/sandbox-id").map(|s| s.as_str()), Some(format!("id-{name}").as_str()));

    // Supervisor init container.
    let init = obj
        .data
        .pointer("/spec/podTemplate/spec/initContainers/0/name")
        .and_then(|v| v.as_str());
    assert_eq!(init, Some("supervisor-init"), "init container missing in {:?}", obj.data);

    // Istio inject label stamped on the pod template (default cfg has it disabled).
    let inject = obj
        .data
        .pointer("/spec/podTemplate/metadata/labels/sidecar.istio.io~1inject")
        .and_then(|v| v.as_str());
    assert_eq!(inject, Some("false"));

    cleanup_sandboxes(&client, &ns).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn test_e2e_sandbox_reaches_ready_or_records_status() {
    // E2E smoke: create a sandbox and wait for the agent-sandbox controller
    // to push a status. We don't require Ready=True (the controller may
    // need image pulls or scheduling) but we DO require the controller
    // observes the CR within 60s.
    let Some((driver, client, ns)) = setup_integration().await else { return; };
    let name = unique_name("e2e");

    driver
        .create_sandbox(Request::new(make_create_request(
            &name,
            "ghcr.io/nvidia/openshell-community/sandboxes/base:latest",
        )))
        .await
        .expect("create");

    let ar = sandbox_api_resource();
    let api: Api<DynamicObject> = Api::namespaced_with(client.clone(), &ns, &ar);

    let deadline = Instant::now() + Duration::from_secs(60);
    let mut observed_status = false;
    while Instant::now() < deadline {
        if let Ok(obj) = api.get(&name).await {
            if obj.data.get("status").is_some() {
                observed_status = true;
                break;
            }
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    assert!(
        observed_status,
        "agent-sandbox controller did not write a status within 60s; \
         is the controller installed?"
    );

    cleanup_sandboxes(&client, &ns).await;
}
