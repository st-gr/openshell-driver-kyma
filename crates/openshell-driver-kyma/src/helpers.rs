//! Conversions between Kubernetes `DynamicObject`s and the driver-native
//! proto messages, plus small map/env helpers shared by the provisioner
//! and the enricher.

use crate::error::DriverError;
use computev1::pb::{
    DriverCondition, DriverResourceRequirements, DriverSandbox, DriverSandboxStatus,
    ResourceRequirements,
};
use kube::core::DynamicObject;
use serde_json::{Map, Value};
use std::collections::HashMap;

pub const LABEL_SANDBOX_ID: &str = "openshell.ai/sandbox-id";
pub const LABEL_SANDBOX_NAME: &str = "openshell.ai/sandbox-name";
pub const LABEL_SANDBOX_NAMESPACE: &str = "openshell.ai/sandbox-namespace";
pub const LABEL_SANDBOX_WORKSPACE: &str = "openshell.ai/sandbox-workspace";

/// Read an identity value from the CR, preferring the annotation over the
/// label. Mirrors upstream's `annotation_or_label`: label *values* are capped
/// at 63 chars and restricted to `[A-Za-z0-9._-]`, so the annotation copy is
/// the lossless one when a value would not survive as a label.
fn annotation_or_label(obj: &DynamicObject, key: &str) -> Option<String> {
    obj.metadata
        .annotations
        .as_ref()
        .and_then(|a| a.get(key).cloned())
        .filter(|v| !v.is_empty())
        .or_else(|| {
            obj.metadata
                .labels
                .as_ref()
                .and_then(|l| l.get(key).cloned())
                .filter(|v| !v.is_empty())
        })
}

/// Convert a Sandbox CR `DynamicObject` into a `DriverSandbox` proto message.
///
/// Identity (`id`, `name`, `workspace`) comes from the CR's labels/annotations,
/// **not** from `metadata.name`. Since v0.0.91 the CR is named
/// `{workspace}--{name}` for collision safety across workspaces, so
/// `metadata.name` is a derived object name and reporting it as the sandbox
/// name would hand the gateway `default--foo` instead of `foo`. Upstream's
/// `sandbox_from_object` reads the labels for exactly this reason.
///
/// Status fields come from `status.{sandboxName,agentPod,agentFd,sandboxFd,
/// conditions}`. A non-nil `metadata.deletionTimestamp` means the controller
/// has begun teardown; surface that as `status.deleting = true`.
///
/// # Errors
/// Returns `Err` when a required identity label is missing — including CRs
/// created before the v0.0.91 workspace migration, which carry no workspace.
/// Callers list/watch should skip such objects rather than fail outright.
pub fn object_to_driver_sandbox(obj: &DynamicObject) -> Result<DriverSandbox, String> {
    let kube_name = obj.metadata.name.clone().unwrap_or_default();

    let Some(sandbox_id) = annotation_or_label(obj, LABEL_SANDBOX_ID) else {
        return Err(format!("object {kube_name} missing sandbox id"));
    };
    let Some(name) = annotation_or_label(obj, LABEL_SANDBOX_NAME) else {
        return Err(format!("object {kube_name} missing sandbox name"));
    };
    let Some(workspace) = annotation_or_label(obj, LABEL_SANDBOX_WORKSPACE) else {
        return Err(format!("object {kube_name} missing sandbox workspace"));
    };

    let mut sb = DriverSandbox {
        id: sandbox_id,
        name,
        namespace: obj.metadata.namespace.clone().unwrap_or_default(),
        workspace,
        ..Default::default()
    };

    if let Some(status_value) = obj.data.get("status") {
        if let Some(status_obj) = status_value.as_object() {
            sb.status = Some(status_from_map(status_obj));
        }
    }

    if obj.metadata.deletion_timestamp.is_some() {
        sb.status
            .get_or_insert_with(DriverSandboxStatus::default)
            .deleting = true;
    }

    Ok(sb)
}

fn status_from_map(status: &Map<String, Value>) -> DriverSandboxStatus {
    let mut ds = DriverSandboxStatus::default();

    if let Some(v) = status.get("sandboxName").and_then(Value::as_str) {
        ds.sandbox_name = v.to_string();
    }
    if let Some(v) = status.get("agentPod").and_then(Value::as_str) {
        ds.instance_id = v.to_string();
    }
    if let Some(v) = status.get("agentFd").and_then(Value::as_str) {
        ds.agent_fd = v.to_string();
    }
    if let Some(v) = status.get("sandboxFd").and_then(Value::as_str) {
        ds.sandbox_fd = v.to_string();
    }

    if let Some(arr) = status.get("conditions").and_then(Value::as_array) {
        for c in arr {
            let Some(cmap) = c.as_object() else { continue };
            ds.conditions.push(DriverCondition {
                r#type: get_string(cmap, "type"),
                status: get_string(cmap, "status"),
                reason: get_string(cmap, "reason"),
                message: get_string(cmap, "message"),
                last_transition_time: get_string(cmap, "lastTransitionTime"),
            });
        }
    }

    ds
}

/// Safely extract a string value from a JSON map, accepting numeric
/// representations as a fallback (mirrors the Go reference's behavior).
#[must_use]
pub fn get_string(m: &Map<String, Value>, key: &str) -> String {
    match m.get(key) {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(other) => other.to_string(),
    }
}

/// Merge spec-level and template-level environment maps and produce a JSON
/// array of `{name, value}` objects suitable for a Kubernetes container
/// `env` field. Spec entries override template entries.
#[must_use]
pub fn build_env_list(
    spec_env: &HashMap<String, String>,
    tmpl_env: &HashMap<String, String>,
) -> Vec<Value> {
    let mut merged: HashMap<&str, &str> = HashMap::new();
    for (k, v) in tmpl_env {
        merged.insert(k.as_str(), v.as_str());
    }
    for (k, v) in spec_env {
        merged.insert(k.as_str(), v.as_str());
    }
    let mut out: Vec<Value> = merged
        .into_iter()
        .map(|(k, v)| serde_json::json!({ "name": k, "value": v }))
        .collect();
    // Stable order so tests are deterministic.
    out.sort_by(|a, b| {
        a["name"]
            .as_str()
            .unwrap_or("")
            .cmp(b["name"].as_str().unwrap_or(""))
    });
    out
}

/// Resolve the effective GPU count from a spec's `resource_requirements`.
///
/// Mirrors upstream's `openshell_core::gpu::{driver_gpu_requirements,
/// effective_driver_gpu_count}` (NVIDIA/OpenShell v0.0.91) exactly, including
/// the error string, so gateway-side UX matches the in-tree drivers:
///
/// - no `resource_requirements`, or no `gpu` inside it, => `None` (no GPU)
/// - `gpu` present with `count` omitted                 => `Some(1)`
/// - `gpu` present with `count == 0`                    => error
///
/// Upstream replaced the old `bool gpu = 9` with `ResourceRequirements` at the
/// same field number in v0.0.91 — a wire-breaking change, which is why this
/// must be read as a message and never as a bool.
///
/// # Errors
/// Returns `DriverError::InvalidArgument` when a GPU is requested with count 0.
pub fn effective_gpu_count(
    resources: Option<&ResourceRequirements>,
) -> Result<Option<u32>, DriverError> {
    let Some(gpu) = resources.and_then(|r| r.gpu.as_ref()) else {
        return Ok(None);
    };
    let count = gpu.count.unwrap_or(1);
    if count == 0 {
        return Err(DriverError::InvalidArgument(
            "gpu count must be greater than 0".to_string(),
        ));
    }
    Ok(Some(count))
}

/// Convert proto `DriverResourceRequirements` and a GPU count into a JSON
/// `resources` map for a Kubernetes container spec. A `gpu_count` of `None`
/// (or `Some(0)`, which callers should have rejected earlier) emits no
/// `nvidia.com/gpu` limit.
#[must_use]
pub fn build_resources(res: &DriverResourceRequirements, gpu_count: Option<u32>) -> Value {
    let mut requests = Map::new();
    let mut limits = Map::new();

    if !res.cpu_request.is_empty() {
        requests.insert("cpu".into(), Value::String(res.cpu_request.clone()));
    }
    if !res.memory_request.is_empty() {
        requests.insert("memory".into(), Value::String(res.memory_request.clone()));
    }
    if !res.cpu_limit.is_empty() {
        limits.insert("cpu".into(), Value::String(res.cpu_limit.clone()));
    }
    if !res.memory_limit.is_empty() {
        limits.insert("memory".into(), Value::String(res.memory_limit.clone()));
    }
    if let Some(count) = gpu_count.filter(|c| *c > 0) {
        limits.insert("nvidia.com/gpu".into(), Value::String(count.to_string()));
    }

    let mut out = Map::new();
    if !requests.is_empty() {
        out.insert("requests".into(), Value::Object(requests));
    }
    if !limits.is_empty() {
        out.insert("limits".into(), Value::Object(limits));
    }
    Value::Object(out)
}

/// Merge two string maps. Values in `b` override values in `a`. Returned as
/// a JSON map so it slots straight into a pod-template label block.
#[must_use]
pub fn merge_maps(a: &HashMap<String, String>, b: &HashMap<String, String>) -> Map<String, Value> {
    let mut out = Map::new();
    for (k, v) in a {
        out.insert(k.clone(), Value::String(v.clone()));
    }
    for (k, v) in b {
        out.insert(k.clone(), Value::String(v.clone()));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use kube::core::{DynamicObject, ObjectMeta, TypeMeta};
    use serde_json::json;

    fn dynamic_object_from_json(v: Value) -> DynamicObject {
        let metadata: ObjectMeta = serde_json::from_value(v["metadata"].clone()).unwrap();
        let mut obj = DynamicObject::new(
            metadata.name.as_deref().unwrap_or(""),
            &kube::api::ApiResource {
                group: "agents.x-k8s.io".into(),
                version: "v1alpha1".into(),
                api_version: "agents.x-k8s.io/v1alpha1".into(),
                kind: "Sandbox".into(),
                plural: "sandboxes".into(),
            },
        );
        obj.types = Some(TypeMeta {
            api_version: "agents.x-k8s.io/v1alpha1".into(),
            kind: "Sandbox".into(),
        });
        obj.metadata = metadata;
        if let Some(status) = v.get("status") {
            obj.data = json!({ "status": status });
        }
        obj
    }

    /// The bare sandbox name comes from the label, NOT from `metadata.name`
    /// — the CR is named `{workspace}--{name}` and the gateway only ever
    /// knows the bare name. Reporting `ws-a--sb-1` here would make every
    /// subsequent gateway lookup miss.
    #[test]
    fn identity_extracted_from_labels_not_object_name() {
        let obj = dynamic_object_from_json(json!({
            "metadata": {
                "name": "ws-a--sb-1",
                "namespace": "ns-1",
                "labels": {
                    "openshell.ai/sandbox-id": "id-123",
                    "openshell.ai/sandbox-name": "sb-1",
                    "openshell.ai/sandbox-workspace": "ws-a"
                }
            }
        }));
        let sb = object_to_driver_sandbox(&obj).unwrap();
        assert_eq!(sb.id, "id-123");
        assert_eq!(sb.name, "sb-1");
        assert_eq!(sb.workspace, "ws-a");
        assert_eq!(sb.namespace, "ns-1");
    }

    #[test]
    fn missing_identity_labels_are_an_error_not_a_panic() {
        let obj = dynamic_object_from_json(json!({
            "metadata": { "name": "orphan", "namespace": "ns-1" }
        }));
        let err = object_to_driver_sandbox(&obj).expect_err("should reject unlabelled CR");
        assert!(
            err.contains("orphan"),
            "error should name the object: {err}"
        );
    }

    #[test]
    fn agent_pod_becomes_instance_id() {
        let obj = dynamic_object_from_json(json!({
            "metadata": { "name": "sb-2", "namespace": "ns", "labels": { "openshell.ai/sandbox-id": "id-sb-2", "openshell.ai/sandbox-name": "sb-2", "openshell.ai/sandbox-workspace": "default" } },
            "status": { "agentPod": "pod-xyz", "sandboxName": "sb-2-cr" }
        }));
        let sb = object_to_driver_sandbox(&obj).unwrap();
        let st = sb.status.unwrap();
        assert_eq!(st.instance_id, "pod-xyz");
        assert_eq!(st.sandbox_name, "sb-2-cr");
    }

    #[test]
    fn conditions_array_is_extracted() {
        let obj = dynamic_object_from_json(json!({
            "metadata": { "name": "sb-3", "namespace": "ns", "labels": { "openshell.ai/sandbox-id": "id-sb-3", "openshell.ai/sandbox-name": "sb-3", "openshell.ai/sandbox-workspace": "default" } },
            "status": {
                "conditions": [
                    {
                        "type": "Ready",
                        "status": "True",
                        "reason": "PodScheduled",
                        "message": "scheduled",
                        "lastTransitionTime": "2026-05-27T00:00:00Z"
                    },
                    {
                        "type": "Available",
                        "status": "False"
                    }
                ]
            }
        }));
        let sb = object_to_driver_sandbox(&obj).unwrap();
        let st = sb.status.unwrap();
        assert_eq!(st.conditions.len(), 2);
        assert_eq!(st.conditions[0].r#type, "Ready");
        assert_eq!(st.conditions[0].status, "True");
        assert_eq!(st.conditions[0].reason, "PodScheduled");
        assert_eq!(st.conditions[1].r#type, "Available");
        assert_eq!(st.conditions[1].status, "False");
    }

    #[test]
    fn deletion_timestamp_marks_status_deleting() {
        let obj = dynamic_object_from_json(json!({
            "metadata": {
                "name": "sb-4",
                "namespace": "ns",
                "deletionTimestamp": "2026-05-27T00:00:00Z",
                "labels": {
                    "openshell.ai/sandbox-id": "id-sb-4",
                    "openshell.ai/sandbox-name": "sb-4",
                    "openshell.ai/sandbox-workspace": "default"
                }
            }
        }));
        let sb = object_to_driver_sandbox(&obj).unwrap();
        let st = sb.status.unwrap();
        assert!(st.deleting);
    }

    #[test]
    fn build_env_list_spec_overrides_template() {
        let mut tmpl = HashMap::new();
        tmpl.insert("FOO".into(), "tmpl".into());
        tmpl.insert("BAR".into(), "tmpl-bar".into());
        let mut spec = HashMap::new();
        spec.insert("FOO".into(), "spec".into());
        let env = build_env_list(&spec, &tmpl);
        assert_eq!(env.len(), 2);
        let foo = env.iter().find(|v| v["name"] == "FOO").unwrap();
        assert_eq!(foo["value"], "spec");
        let bar = env.iter().find(|v| v["name"] == "BAR").unwrap();
        assert_eq!(bar["value"], "tmpl-bar");
    }

    /// Upstream's `effective_driver_gpu_count` semantics, pinned. The
    /// omitted-count-means-one rule is easy to get wrong in the direction of
    /// silently allocating zero GPUs for a request that asked for a GPU.
    #[test]
    fn effective_gpu_count_matches_upstream_semantics() {
        use computev1::pb::{GpuResourceRequirements, ResourceRequirements};

        // No resource_requirements at all -> no GPU.
        assert_eq!(effective_gpu_count(None).unwrap(), None);

        // resource_requirements present but no gpu block -> no GPU.
        let no_gpu = ResourceRequirements::default();
        assert_eq!(effective_gpu_count(Some(&no_gpu)).unwrap(), None);

        // gpu block with no count -> exactly one GPU.
        let implicit = ResourceRequirements {
            gpu: Some(GpuResourceRequirements::default()),
        };
        assert_eq!(effective_gpu_count(Some(&implicit)).unwrap(), Some(1));

        // Explicit count is honoured.
        let explicit = ResourceRequirements {
            gpu: Some(GpuResourceRequirements { count: Some(4) }),
        };
        assert_eq!(effective_gpu_count(Some(&explicit)).unwrap(), Some(4));

        // count == 0 is a malformed request, not "no GPU".
        let zero = ResourceRequirements {
            gpu: Some(GpuResourceRequirements { count: Some(0) }),
        };
        let err = effective_gpu_count(Some(&zero)).expect_err("count 0 must be rejected");
        assert!(matches!(err, DriverError::InvalidArgument(_)), "{err:?}");
    }

    #[test]
    fn build_resources_emits_requests_and_limits() {
        let res = DriverResourceRequirements {
            cpu_request: "100m".into(),
            memory_request: "128Mi".into(),
            cpu_limit: "500m".into(),
            memory_limit: "512Mi".into(),
        };
        let r = build_resources(&res, None);
        assert_eq!(r["requests"]["cpu"], "100m");
        assert_eq!(r["requests"]["memory"], "128Mi");
        assert_eq!(r["limits"]["cpu"], "500m");
        assert_eq!(r["limits"]["memory"], "512Mi");
        assert!(r["limits"].get("nvidia.com/gpu").is_none());
    }

    #[test]
    fn build_resources_adds_gpu_limit_when_requested() {
        let res = DriverResourceRequirements::default();
        let r = build_resources(&res, Some(1));
        assert_eq!(r["limits"]["nvidia.com/gpu"], "1");
    }

    #[test]
    fn build_resources_emits_requested_gpu_count() {
        let res = DriverResourceRequirements::default();
        let r = build_resources(&res, Some(4));
        assert_eq!(r["limits"]["nvidia.com/gpu"], "4");
    }

    #[test]
    fn merge_maps_b_overrides_a() {
        let mut a = HashMap::new();
        a.insert("k".into(), "a".into());
        a.insert("only-a".into(), "ya".into());
        let mut b = HashMap::new();
        b.insert("k".into(), "b".into());
        b.insert("only-b".into(), "yb".into());
        let merged = merge_maps(&a, &b);
        assert_eq!(merged["k"], "b");
        assert_eq!(merged["only-a"], "ya");
        assert_eq!(merged["only-b"], "yb");
    }

    #[test]
    fn get_string_handles_missing_string_and_number() {
        let mut m = Map::new();
        m.insert("s".into(), Value::String("hello".into()));
        m.insert("n".into(), Value::Number(serde_json::Number::from(42)));
        assert_eq!(get_string(&m, "s"), "hello");
        assert_eq!(get_string(&m, "n"), "42");
        assert_eq!(get_string(&m, "missing"), "");
    }
}
