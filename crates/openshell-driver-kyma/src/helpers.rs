//! Conversions between Kubernetes `DynamicObject`s and the driver-native
//! proto messages, plus small map/env helpers shared by the provisioner
//! and the enricher.

use computev1::pb::{
    DriverCondition, DriverResourceRequirements, DriverSandbox, DriverSandboxStatus,
};
use kube::core::DynamicObject;
use serde_json::{Map, Value};
use std::collections::HashMap;

const LABEL_SANDBOX_ID: &str = "openshell.ai/sandbox-id";

/// Convert a Sandbox CR `DynamicObject` into a `DriverSandbox` proto message.
///
/// The CR carries the stable sandbox id in the `openshell.ai/sandbox-id`
/// label (set by the driver at create time) and exposes status fields under
/// `status.{sandboxName,agentPod,agentFd,sandboxFd,conditions}`. A non-nil
/// `metadata.deletionTimestamp` means the controller has begun teardown;
/// surface that as `status.deleting = true`.
#[must_use]
pub fn object_to_driver_sandbox(obj: &DynamicObject) -> DriverSandbox {
    let sandbox_id = obj
        .metadata
        .labels
        .as_ref()
        .and_then(|l| l.get(LABEL_SANDBOX_ID).cloned())
        .unwrap_or_default();

    let mut sb = DriverSandbox {
        id: sandbox_id,
        name: obj.metadata.name.clone().unwrap_or_default(),
        namespace: obj.metadata.namespace.clone().unwrap_or_default(),
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

    sb
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

/// Convert proto `DriverResourceRequirements` and a GPU flag into a JSON
/// `resources` map for a Kubernetes container spec.
#[must_use]
pub fn build_resources(res: &DriverResourceRequirements, gpu: bool) -> Value {
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
    if gpu {
        limits.insert("nvidia.com/gpu".into(), Value::String("1".into()));
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
pub fn merge_maps(
    a: &HashMap<String, String>,
    b: &HashMap<String, String>,
) -> Map<String, Value> {
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

    #[test]
    fn id_extracted_from_label() {
        let obj = dynamic_object_from_json(json!({
            "metadata": {
                "name": "sb-1",
                "namespace": "ns-1",
                "labels": { "openshell.ai/sandbox-id": "id-123" }
            }
        }));
        let sb = object_to_driver_sandbox(&obj);
        assert_eq!(sb.id, "id-123");
        assert_eq!(sb.name, "sb-1");
        assert_eq!(sb.namespace, "ns-1");
    }

    #[test]
    fn agent_pod_becomes_instance_id() {
        let obj = dynamic_object_from_json(json!({
            "metadata": { "name": "sb-2", "namespace": "ns" },
            "status": { "agentPod": "pod-xyz", "sandboxName": "sb-2-cr" }
        }));
        let sb = object_to_driver_sandbox(&obj);
        let st = sb.status.unwrap();
        assert_eq!(st.instance_id, "pod-xyz");
        assert_eq!(st.sandbox_name, "sb-2-cr");
    }

    #[test]
    fn conditions_array_is_extracted() {
        let obj = dynamic_object_from_json(json!({
            "metadata": { "name": "sb-3", "namespace": "ns" },
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
        let sb = object_to_driver_sandbox(&obj);
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
                "deletionTimestamp": "2026-05-27T00:00:00Z"
            }
        }));
        let sb = object_to_driver_sandbox(&obj);
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

    #[test]
    fn build_resources_emits_requests_and_limits() {
        let res = DriverResourceRequirements {
            cpu_request: "100m".into(),
            memory_request: "128Mi".into(),
            cpu_limit: "500m".into(),
            memory_limit: "512Mi".into(),
        };
        let r = build_resources(&res, false);
        assert_eq!(r["requests"]["cpu"], "100m");
        assert_eq!(r["requests"]["memory"], "128Mi");
        assert_eq!(r["limits"]["cpu"], "500m");
        assert_eq!(r["limits"]["memory"], "512Mi");
        assert!(r["limits"].get("nvidia.com/gpu").is_none());
    }

    #[test]
    fn build_resources_adds_gpu_limit_when_requested() {
        let res = DriverResourceRequirements::default();
        let r = build_resources(&res, true);
        assert_eq!(r["limits"]["nvidia.com/gpu"], "1");
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
