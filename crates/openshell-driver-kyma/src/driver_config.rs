//! Typed schema and validation for `DriverSandboxTemplate.driver_config`
//! (proto field 12, a `google.protobuf.Struct`).
//!
//! This is the structured channel through which a caller configures
//! Kyma-specific pod knobs (node selector, runtime class, extra volumes and
//! mounts, resource overrides). The wire shape mirrors upstream NVIDIA
//! OpenShell's in-tree Kubernetes driver
//! (`crates/openshell-driver-kubernetes/src/driver.rs` in st-gr/OpenShell,
//! `KubernetesSandboxDriverConfig` and friends) so the same `driver_config`
//! payload a caller sends to the upstream Kubernetes driver decodes and
//! validates the same way here — it is a contract, not an implementation
//! detail we're free to reshape.
//!
//! This module is intentionally self-contained in the sense that matters:
//! pure decode + validate, no Kubernetes API calls, no I/O. It does read
//! three `pub(crate)` constants from `provisioner.rs` (see
//! `RESERVED_VOLUME_NAMES` below) rather than restating their values, so
//! the two can never silently disagree. Nothing in this crate constructs a
//! `DriverConfig` yet; a later change wires `DriverConfig::from_template`
//! into `KymaProvisioner::build_sandbox_spec` and applies the validated
//! fields to the pod spec.
//!
//! `#[serde(deny_unknown_fields)]` on every struct here is deliberate and
//! must not be dropped: silently accepting an unknown key would let a
//! caller believe a setting took effect when it did not.

use crate::error::DriverError;
use crate::provisioner::{
    SA_TOKEN_MOUNT_PATH, SA_TOKEN_VOLUME, SUPERVISOR_VOLUME, WORKSPACE_VOLUME,
};
use crate::vendor::driver_mounts;
use serde::Deserialize;
use std::collections::{BTreeMap, HashSet};
use std::path::Path;

/// Volume names this driver manages itself.
///
/// Upstream reserves its *own* managed volume names here
/// (`openshell-client-tls`, `openshell-sa-token`, `spiffe-workload-api`,
/// its supervisor volume, its workspace volume). Ours are different because
/// this driver's pod shape is different — no client-TLS or SPIFFE volumes —
/// and, critically, this list is not a second copy of the three names it
/// does use: each entry is the actual `pub(crate)` constant `provisioner.rs`
/// uses to create that volume, not a restated string literal. If someone
/// renames `SUPERVISOR_VOLUME` there, this list renames with it — a
/// hardcoded copy would instead silently stop protecting the volume, which
/// is exactly the failure mode this indirection exists to rule out.
/// `reserved_volume_names_match_provisioner_managed_volumes` in the test
/// module pins this relationship down explicitly.
///
/// A caller-supplied volume with one of these names would silently shadow
/// (or fail to schedule alongside) a volume this driver itself creates,
/// which would break every sandbox — hence rejecting it here rather than
/// downstream.
const RESERVED_VOLUME_NAMES: &[&str] = &[SUPERVISOR_VOLUME, SA_TOKEN_VOLUME, WORKSPACE_VOLUME];

/// Root of the typed `driver_config` schema.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct DriverConfig {
    pub pod: PodConfig,
    pub containers: ContainersConfig,
    pub volumes: Vec<VolumeConfig>,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct PodConfig {
    pub node_selector: BTreeMap<String, String>,
    pub runtime_class_name: String,
    /// Left as opaque JSON: `k8s_openapi::api::core::v1::Toleration` has its
    /// own `Deserialize`, but decoding through it here would mean a
    /// caller's typo produces `deny_unknown_fields`'s blunt "unknown field"
    /// rather than a useful message. Left for the pod-spec-wiring task,
    /// which applies these directly to the pod template as JSON anyway.
    pub tolerations: Vec<serde_json::Value>,
    pub priority_class_name: String,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ContainersConfig {
    pub agent: ContainerConfig,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ContainerConfig {
    pub resources: ContainerResourcesConfig,
    pub volume_mounts: Vec<VolumeMountConfig>,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ContainerResourcesConfig {
    pub requests: BTreeMap<String, String>,
    pub limits: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct VolumeConfig {
    pub name: String,
    pub persistent_volume_claim: PersistentVolumeClaimConfig,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct PersistentVolumeClaimConfig {
    pub claim_name: String,
    pub read_only: bool,
}

impl Default for PersistentVolumeClaimConfig {
    fn default() -> Self {
        Self {
            claim_name: String::new(),
            read_only: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct VolumeMountConfig {
    pub name: String,
    pub mount_path: String,
    pub sub_path: Option<String>,
    pub read_only: bool,
}

impl Default for VolumeMountConfig {
    fn default() -> Self {
        Self {
            name: String::new(),
            mount_path: String::new(),
            sub_path: None,
            read_only: true,
        }
    }
}

impl DriverConfig {
    /// Decode and validate `template.driver_config`. An absent field (the
    /// common case today, since nothing sends it yet) yields the default
    /// config with no error — mirrors upstream's `from_template`.
    ///
    /// `supervisor_mount_path` must be the caller's `cfg.supervisor_mount_path`
    /// (`--supervisor-mount-path`, default `/opt/openshell/bin`): it is
    /// configurable per driver instance, so it cannot be a constant in this
    /// module the way `SA_TOKEN_MOUNT_PATH` can — it has to come from the
    /// caller who knows the running configuration.
    pub fn from_template(
        template: &computev1::pb::DriverSandboxTemplate,
        supervisor_mount_path: &str,
    ) -> Result<Self, DriverError> {
        let Some(config) = template.driver_config.as_ref() else {
            return Ok(Self::default());
        };
        Self::from_struct(config, supervisor_mount_path)
    }

    fn from_struct(
        config: &prost_types::Struct,
        supervisor_mount_path: &str,
    ) -> Result<Self, DriverError> {
        let json = serde_json::Value::Object(struct_to_json_object(config));
        let config: Self = serde_json::from_value(json)
            .map_err(|err| invalid(format!("invalid driver_config: {err}")))?;
        config.validate(supervisor_mount_path)?;
        Ok(config)
    }

    fn validate(&self, supervisor_mount_path: &str) -> Result<(), DriverError> {
        validate_volumes(&self.volumes)?;
        validate_volume_mounts(
            &self.volumes,
            &self.containers.agent.volume_mounts,
            supervisor_mount_path,
        )
    }

    /// True when the caller declared a mount at or under the workspace
    /// root (`/sandbox`). A later task uses this to decide whether the
    /// driver still injects its own workspace PVC mount, or defers to the
    /// caller's explicit one.
    #[must_use]
    pub fn has_explicit_sandbox_data_mount(&self) -> bool {
        self.containers.agent.volume_mounts.iter().any(|mount| {
            driver_mounts::path_is_or_under(
                Path::new(&mount.mount_path),
                Path::new(driver_mounts::DEFAULT_WORKSPACE_ROOT),
            )
        })
    }
}

fn invalid(message: impl Into<String>) -> DriverError {
    DriverError::InvalidArgument(message.into())
}

/// Rule 1-4: DNS-1123 label name, reserved-name rejection, no duplicate
/// names, DNS-1123-subdomain PVC claim name.
fn validate_volumes(volumes: &[VolumeConfig]) -> Result<(), DriverError> {
    let mut names = HashSet::new();
    for volume in volumes {
        validate_dns1123_label(&volume.name, "volumes[].name")?;
        let name = volume.name.as_str();
        if RESERVED_VOLUME_NAMES.contains(&name) {
            return Err(invalid(format!(
                "volume name '{name}' is reserved for OpenShell-managed volumes"
            )));
        }
        if !names.insert(name) {
            return Err(invalid(format!("duplicate driver_config volume '{name}'")));
        }
        validate_dns1123_subdomain(
            &volume.persistent_volume_claim.claim_name,
            "volumes[].persistent_volume_claim.claim_name",
        )?;
    }
    Ok(())
}

/// Rule 5-11: DNS-1123 label mount name, must reference a declared volume,
/// `read_only=false` against a `read_only=true` PVC is rejected, container
/// mount target validates, workspace mount target validates, no duplicate
/// normalized mount targets, sub-path (if present) validates.
///
/// Plus two driver-specific checks beyond the eleven ported rules, mirroring
/// how upstream protects its own static paths from a *different* call site
/// (`validate_kubernetes_protected_path_conflicts`, not part of what this
/// module ports): a mount must not overlap the projected SA-token mount
/// (`SA_TOKEN_MOUNT_PATH`, fixed) or the supervisor-binary mount
/// (`supervisor_mount_path`, configurable). Either overlap would break or
/// subvert the sandbox — the SA token is what the supervisor authenticates
/// to the gateway with, and the supervisor binary is what runs at all.
fn validate_volume_mounts(
    volumes: &[VolumeConfig],
    volume_mounts: &[VolumeMountConfig],
    supervisor_mount_path: &str,
) -> Result<(), DriverError> {
    let mut volume_read_only = BTreeMap::new();
    for volume in volumes {
        volume_read_only.insert(
            volume.name.as_str(),
            volume.persistent_volume_claim.read_only,
        );
    }

    let mut mount_paths = HashSet::new();
    for mount in volume_mounts {
        validate_dns1123_label(&mount.name, "containers.agent.volume_mounts[].name")?;
        let volume_name = mount.name.as_str();
        let Some(volume_is_read_only) = volume_read_only.get(volume_name) else {
            return Err(invalid(format!(
                "volume mount references unknown driver_config volume '{volume_name}'"
            )));
        };
        if *volume_is_read_only && !mount.read_only {
            return Err(invalid(format!(
                "volume mount '{volume_name}' cannot set read_only=false because the PVC volume is read_only=true"
            )));
        }

        driver_mounts::validate_container_mount_target(&mount.mount_path).map_err(invalid)?;
        driver_mounts::validate_workspace_mount_target(
            &mount.mount_path,
            driver_mounts::DEFAULT_WORKSPACE_ROOT,
        )
        .map_err(invalid)?;
        driver_mounts::validate_mount_control_path(&mount.mount_path, SA_TOKEN_MOUNT_PATH)
            .map_err(invalid)?;
        driver_mounts::validate_mount_control_path(&mount.mount_path, supervisor_mount_path)
            .map_err(invalid)?;
        let normalized_mount_path = driver_mounts::normalize_mount_target(&mount.mount_path);
        if !mount_paths.insert(normalized_mount_path.clone()) {
            return Err(invalid(format!(
                "duplicate driver_config mount target '{normalized_mount_path}'"
            )));
        }

        if let Some(sub_path) = mount.sub_path.as_ref() {
            driver_mounts::validate_mount_subpath(sub_path).map_err(invalid)?;
        }
    }
    Ok(())
}

// Ported from upstream driver.rs (same commit as vendor/UPSTREAM.lock):
// there is no shared Kubernetes-name helper crate to depend on, and
// upstream's own copy carries the same "TODO: replace with an
// openshell_core helper once available" note.
fn is_dns_1123_label(s: &str) -> bool {
    let len = s.len();
    if len == 0 || len > 63 {
        return false;
    }
    let bytes = s.as_bytes();
    if !bytes[0].is_ascii_lowercase() && !bytes[0].is_ascii_digit() {
        return false;
    }
    if !bytes[len - 1].is_ascii_lowercase() && !bytes[len - 1].is_ascii_digit() {
        return false;
    }
    bytes
        .iter()
        .all(|&b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

fn is_dns_1123_subdomain(value: &str) -> bool {
    value.len() <= 253 && value.split('.').all(is_dns_1123_label)
}

fn validate_dns1123_label(value: &str, field: &str) -> Result<(), DriverError> {
    if is_dns_1123_label(value) {
        Ok(())
    } else {
        Err(invalid(format!(
            "{field} must be a DNS-1123 label: use lowercase alphanumeric characters or '-', start and end with an alphanumeric character, and use at most 63 characters"
        )))
    }
}

fn validate_dns1123_subdomain(value: &str, field: &str) -> Result<(), DriverError> {
    if is_dns_1123_subdomain(value) {
        Ok(())
    } else {
        Err(invalid(format!(
            "{field} must be a DNS-1123 subdomain: use lowercase alphanumeric characters, '-' or '.', start and end with an alphanumeric character, and use at most 253 characters"
        )))
    }
}

// --- google.protobuf.Struct -> serde_json::Value -------------------------
//
// Upstream's equivalent (`openshell_core::proto_struct::struct_to_json_object`
// / `value_to_json`) lives in a workspace-internal crate we don't depend on
// (see the module doc on why this crate doesn't pull in openshell-core).
// `provisioner.rs`'s `bool_from_value_kind`/`string_from_value_kind` don't
// suffice here: they extract a single scalar out of one already-known
// `prost_types::value::Kind`, not a whole nested Struct into JSON, so this
// is a fresh, general conversion rather than a reuse of either.

fn struct_to_json_object(
    config: &prost_types::Struct,
) -> serde_json::Map<String, serde_json::Value> {
    config
        .fields
        .iter()
        .map(|(key, value)| (key.clone(), value_to_json(value)))
        .collect()
}

fn value_to_json(value: &prost_types::Value) -> serde_json::Value {
    match value.kind.as_ref() {
        Some(prost_types::value::Kind::NumberValue(num)) => serde_json::Number::from_f64(*num)
            .map_or(serde_json::Value::Null, serde_json::Value::Number),
        Some(prost_types::value::Kind::StringValue(val)) => serde_json::Value::String(val.clone()),
        Some(prost_types::value::Kind::BoolValue(val)) => serde_json::Value::Bool(*val),
        Some(prost_types::value::Kind::StructValue(val)) => {
            serde_json::Value::Object(struct_to_json_object(val))
        }
        Some(prost_types::value::Kind::ListValue(list)) => {
            serde_json::Value::Array(list.values.iter().map(value_to_json).collect())
        }
        Some(prost_types::value::Kind::NullValue(_)) | None => serde_json::Value::Null,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use computev1::pb::DriverSandboxTemplate;
    use serde_json::json;

    // Matches config.rs's `Config::supervisor_mount_path` default, so most
    // tests exercise the realistic case. `rejects_mount_overlapping_supervisor_mount_configured_non_default`
    // uses a different value specifically to prove this is genuinely
    // parameterised, not hardcoded.
    const TEST_SUPERVISOR_MOUNT_PATH: &str = "/opt/openshell/bin";

    // --- test-only encode direction: serde_json::Value -> Struct ---------
    // The mirror of struct_to_json_object/value_to_json above. Production
    // code never needs to build a Struct, only decode one, so this stays
    // test-only rather than shipping an unused encode path.

    fn json_struct(value: serde_json::Value) -> prost_types::Struct {
        let serde_json::Value::Object(object) = value else {
            panic!("expected a JSON object");
        };
        prost_types::Struct {
            fields: object
                .into_iter()
                .map(|(key, value)| (key, json_to_value(value)))
                .collect(),
        }
    }

    fn json_to_value(value: serde_json::Value) -> prost_types::Value {
        use prost_types::value::Kind;
        let kind = match value {
            serde_json::Value::Null => Kind::NullValue(0),
            serde_json::Value::Bool(b) => Kind::BoolValue(b),
            serde_json::Value::Number(n) => {
                Kind::NumberValue(n.as_f64().expect("test numbers fit in f64"))
            }
            serde_json::Value::String(s) => Kind::StringValue(s),
            serde_json::Value::Array(values) => Kind::ListValue(prost_types::ListValue {
                values: values.into_iter().map(json_to_value).collect(),
            }),
            serde_json::Value::Object(object) => Kind::StructValue(json_struct(json!(object))),
        };
        prost_types::Value { kind: Some(kind) }
    }

    fn template_with(driver_config: serde_json::Value) -> DriverSandboxTemplate {
        DriverSandboxTemplate {
            driver_config: Some(json_struct(driver_config)),
            ..Default::default()
        }
    }

    fn valid_volume_and_mount() -> serde_json::Value {
        json!({
            "volumes": [{
                "name": "user-data",
                "persistent_volume_claim": {"claim_name": "pvc-user-data", "read_only": true}
            }],
            "containers": {
                "agent": {
                    "volume_mounts": [{
                        "name": "user-data",
                        "mount_path": "/data",
                        "read_only": true
                    }]
                }
            }
        })
    }

    // Catches: any field rename/reorder, a wrong default, or the decode
    // path silently dropping data.
    #[test]
    fn valid_config_round_trips() {
        let template = template_with(json!({
            "pod": {
                "node_selector": {"disktype": "ssd"},
                "runtime_class_name": "gvisor",
                "tolerations": [{"key": "dedicated", "operator": "Equal", "value": "gpu"}],
                "priority_class_name": "high"
            },
            "containers": {
                "agent": {
                    "resources": {
                        "requests": {"cpu": "500m"},
                        "limits": {"cpu": "1"}
                    },
                    "volume_mounts": [{
                        "name": "user-data",
                        "mount_path": "/data",
                        "sub_path": "nested",
                        "read_only": true
                    }]
                }
            },
            "volumes": [{
                "name": "user-data",
                "persistent_volume_claim": {"claim_name": "pvc-user-data", "read_only": true}
            }]
        }));

        let config = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .expect("valid config must decode");

        assert_eq!(config.pod.node_selector["disktype"], "ssd");
        assert_eq!(config.pod.runtime_class_name, "gvisor");
        assert_eq!(config.pod.priority_class_name, "high");
        assert_eq!(config.pod.tolerations.len(), 1);
        assert_eq!(config.containers.agent.resources.requests["cpu"], "500m");
        assert_eq!(config.containers.agent.resources.limits["cpu"], "1");
        assert_eq!(config.containers.agent.volume_mounts[0].name, "user-data");
        assert_eq!(config.containers.agent.volume_mounts[0].mount_path, "/data");
        assert_eq!(
            config.containers.agent.volume_mounts[0].sub_path.as_deref(),
            Some("nested")
        );
        assert!(config.containers.agent.volume_mounts[0].read_only);
        assert_eq!(config.volumes[0].name, "user-data");
        assert_eq!(
            config.volumes[0].persistent_volume_claim.claim_name,
            "pvc-user-data"
        );
    }

    // Rule 1. Catches: dropping validate_dns1123_label on the volume name,
    // or loosening it (e.g. allowing uppercase or underscores).
    #[test]
    fn rejects_volume_name_not_dns1123_label() {
        let template = template_with(json!({
            "volumes": [{
                "name": "User_Data",
                "persistent_volume_claim": {"claim_name": "pvc-user-data"}
            }]
        }));

        let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .unwrap_err()
            .to_string();

        assert!(err.contains("volumes[].name"), "got: {err}");
        assert!(err.contains("DNS-1123 label"), "got: {err}");
    }

    // Rule 2. Catches: reserving upstream's volume names instead of ours,
    // or dropping the reserved-name check entirely (would let a caller's
    // volume shadow the supervisor-binary mount and break every sandbox).
    #[test]
    fn rejects_reserved_volume_name() {
        for reserved in RESERVED_VOLUME_NAMES {
            let template = template_with(json!({
                "volumes": [{
                    "name": reserved,
                    "persistent_volume_claim": {"claim_name": "pvc-user-data"}
                }]
            }));

            let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
                .unwrap_err()
                .to_string();

            assert!(
                err.contains("is reserved for OpenShell-managed volumes"),
                "expected reserved name {reserved:?} to be rejected, got: {err}"
            );
        }
    }

    // Rule 3. Catches: using a Vec/no-op instead of a HashSet, so a second
    // volume with the same name silently wins/loses instead of erroring.
    #[test]
    fn rejects_duplicate_volume_names() {
        let template = template_with(json!({
            "volumes": [
                {"name": "user-data", "persistent_volume_claim": {"claim_name": "pvc-a"}},
                {"name": "user-data", "persistent_volume_claim": {"claim_name": "pvc-b"}}
            ]
        }));

        let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .unwrap_err()
            .to_string();

        assert!(
            err.contains("duplicate driver_config volume 'user-data'"),
            "got: {err}"
        );
    }

    // Rule 4. Catches: validating the claim name with the label (not
    // subdomain) rule, which would wrongly reject a dotted claim name.
    #[test]
    fn rejects_pvc_claim_name_not_dns1123_subdomain() {
        let template = template_with(json!({
            "volumes": [{
                "name": "user-data",
                "persistent_volume_claim": {"claim_name": "Pvc_User_Data"}
            }]
        }));

        let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .unwrap_err()
            .to_string();

        assert!(
            err.contains("volumes[].persistent_volume_claim.claim_name"),
            "got: {err}"
        );
        assert!(err.contains("DNS-1123 subdomain"), "got: {err}");

        // A dotted subdomain name is exactly what the label rule would
        // reject and the subdomain rule must accept, so also prove the
        // positive case uses the right rule.
        let template = template_with(json!({
            "volumes": [{
                "name": "user-data",
                "persistent_volume_claim": {"claim_name": "pvc.user-data.123"}
            }]
        }));
        DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .expect("dotted subdomain claim name must validate");
    }

    // Rule 5. Catches: forgetting to validate the mount name at all.
    #[test]
    fn rejects_mount_name_not_dns1123_label() {
        let mut config = valid_volume_and_mount();
        config["containers"]["agent"]["volume_mounts"][0]["name"] = json!("User_Data");
        let template = template_with(config);

        let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .unwrap_err()
            .to_string();

        assert!(
            err.contains("containers.agent.volume_mounts[].name"),
            "got: {err}"
        );
        assert!(err.contains("DNS-1123 label"), "got: {err}");
    }

    // Rule 6. Catches: skipping the "does this mount reference a declared
    // volume" check, which would let a mount silently reference nothing.
    #[test]
    fn rejects_mount_referencing_unknown_volume() {
        let template = template_with(json!({
            "containers": {
                "agent": {
                    "volume_mounts": [{"name": "missing-data", "mount_path": "/data"}]
                }
            }
        }));

        let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .unwrap_err()
            .to_string();

        assert!(
            err.contains("references unknown driver_config volume 'missing-data'"),
            "got: {err}"
        );
    }

    // Rule 7. Catches: dropping the read_only cross-check, which would let
    // a caller declare write access to a PVC volume mounted read-only.
    #[test]
    fn rejects_read_write_mount_for_read_only_pvc() {
        let mut config = valid_volume_and_mount();
        config["volumes"][0]["persistent_volume_claim"]["read_only"] = json!(true);
        config["containers"]["agent"]["volume_mounts"][0]["read_only"] = json!(false);
        let template = template_with(config);

        let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .unwrap_err()
            .to_string();

        assert!(err.contains("cannot set read_only=false"), "got: {err}");
    }

    // Rule 8. Catches: not calling validate_container_mount_target at all,
    // which would let a mount shadow the supervisor binary under
    // /opt/openshell (a CONTROL_ROOTS entry in vendor/driver_mounts.rs).
    #[test]
    fn rejects_mount_target_conflicting_with_control_root() {
        let mut config = valid_volume_and_mount();
        config["containers"]["agent"]["volume_mounts"][0]["mount_path"] =
            json!("/opt/openshell/bin");
        let template = template_with(config);

        let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .unwrap_err()
            .to_string();

        assert!(
            err.contains("conflicts with reserved OpenShell path"),
            "got: {err}"
        );
    }

    // Rule 9. Catches: not calling validate_workspace_mount_target, which
    // would let a caller's mount silently replace the /sandbox workspace
    // root this driver's own optional workspace PVC also mounts at.
    #[test]
    fn rejects_mount_target_at_workspace_root() {
        let mut config = valid_volume_and_mount();
        config["containers"]["agent"]["volume_mounts"][0]["mount_path"] = json!("/sandbox");
        let template = template_with(config);

        let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .unwrap_err()
            .to_string();

        assert!(
            err.contains("reserved for the OpenShell workspace"),
            "got: {err}"
        );
    }

    // Fix round 1, check A. Catches: not calling validate_mount_control_path
    // against SA_TOKEN_MOUNT_PATH at all, which would let a caller's mount
    // replace the projected ServiceAccount token the supervisor
    // authenticates to the gateway with.
    #[test]
    fn rejects_mount_overlapping_sa_token_path_exact() {
        let mut config = valid_volume_and_mount();
        config["containers"]["agent"]["volume_mounts"][0]["mount_path"] =
            json!(SA_TOKEN_MOUNT_PATH);
        let template = template_with(config);

        let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .unwrap_err()
            .to_string();

        assert!(
            err.contains("conflicts with OpenShell control path"),
            "got: {err}"
        );
        assert!(err.contains(SA_TOKEN_MOUNT_PATH), "got: {err}");
    }

    // Fix round 1, check A. Catches: only checking exact equality instead of
    // "contains or is contained by" — a mount one level under the SA token
    // path would still shadow it via the kubelet's directory-mount semantics.
    #[test]
    fn rejects_mount_overlapping_sa_token_path_under() {
        let mut config = valid_volume_and_mount();
        config["containers"]["agent"]["volume_mounts"][0]["mount_path"] =
            json!(format!("{SA_TOKEN_MOUNT_PATH}/token"));
        let template = template_with(config);

        let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .unwrap_err()
            .to_string();

        assert!(
            err.contains("conflicts with OpenShell control path"),
            "got: {err}"
        );
    }

    // Fix round 1, check A. Catches: checking only "is the mount under the
    // control path", missing the reverse direction — a mount at a *parent*
    // of the control path would also make the SA token disappear from where
    // the supervisor expects it.
    #[test]
    fn rejects_mount_overlapping_sa_token_path_containing() {
        let mut config = valid_volume_and_mount();
        config["containers"]["agent"]["volume_mounts"][0]["mount_path"] = json!("/var/run/secrets");
        let template = template_with(config);

        let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .unwrap_err()
            .to_string();

        assert!(
            err.contains("conflicts with OpenShell control path"),
            "got: {err}"
        );
    }

    // Fix round 1, check B. Uses a configured supervisor_mount_path that is
    // NOT the /opt/openshell/bin default, and NOT under any vendor/
    // driver_mounts.rs CONTROL_ROOTS entry — so this can only be rejected by
    // the parameterised control-path check, not by rule 8's container mount
    // target check. Catches: hardcoding the default path (or the CONTROL_ROOTS
    // constant) instead of genuinely threading the caller's configured value.
    #[test]
    fn rejects_mount_overlapping_supervisor_mount_configured_non_default_exact() {
        let mut config = valid_volume_and_mount();
        config["containers"]["agent"]["volume_mounts"][0]["mount_path"] =
            json!("/custom/supervisor");
        let template = template_with(config);

        let err = DriverConfig::from_template(&template, "/custom/supervisor")
            .unwrap_err()
            .to_string();

        assert!(
            err.contains("conflicts with OpenShell control path"),
            "got: {err}"
        );
        assert!(err.contains("/custom/supervisor"), "got: {err}");
    }

    // Fix round 1, check B. Same non-default path; mount nested under it.
    // Catches: exact-equality-only comparison missing a mount one level in.
    #[test]
    fn rejects_mount_overlapping_supervisor_mount_configured_non_default_under() {
        let mut config = valid_volume_and_mount();
        config["containers"]["agent"]["volume_mounts"][0]["mount_path"] =
            json!("/custom/supervisor/openshell-sandbox");
        let template = template_with(config);

        let err = DriverConfig::from_template(&template, "/custom/supervisor")
            .unwrap_err()
            .to_string();

        assert!(
            err.contains("conflicts with OpenShell control path"),
            "got: {err}"
        );
    }

    // Fix round 1, check B. Same non-default path; mount at a parent of it.
    // Catches: missing the reverse "contains" direction.
    #[test]
    fn rejects_mount_overlapping_supervisor_mount_configured_non_default_containing() {
        let mut config = valid_volume_and_mount();
        config["containers"]["agent"]["volume_mounts"][0]["mount_path"] = json!("/custom");
        let template = template_with(config);

        let err = DriverConfig::from_template(&template, "/custom/supervisor")
            .unwrap_err()
            .to_string();

        assert!(
            err.contains("conflicts with OpenShell control path"),
            "got: {err}"
        );
    }

    // Fix round 1, check C. This assertion is definitionally true today
    // because RESERVED_VOLUME_NAMES is built *from* these same provisioner.rs
    // constants (not restated literals) — see the doc comment above
    // RESERVED_VOLUME_NAMES. Catches: a future edit that reintroduces a
    // hardcoded string literal into RESERVED_VOLUME_NAMES that then drifts
    // from the real constant, silently unprotecting a volume this driver
    // manages.
    #[test]
    fn reserved_volume_names_match_provisioner_managed_volumes() {
        assert_eq!(
            RESERVED_VOLUME_NAMES,
            [SUPERVISOR_VOLUME, SA_TOKEN_VOLUME, WORKSPACE_VOLUME]
        );
    }

    // Pins down the guarantee provisioner.rs's `agent_mounts.extend(...)`
    // comment relies on but that this module does not otherwise state
    // directly: an agent volume mount can never end up named one of
    // RESERVED_VOLUME_NAMES (SUPERVISOR_VOLUME/"supervisor-bin",
    // SA_TOKEN_VOLUME, WORKSPACE_VOLUME), i.e. it can never collide with a
    // volume this driver manages itself. Two independent checks combine to
    // make that true, and each half below exercises one of them in
    // isolation:
    //
    //   - half 1: rule 2 (validate_volumes) rejects *declaring* a volume
    //     under a reserved name, even when a mount also references it.
    //     Catches: removing the RESERVED_VOLUME_NAMES check from
    //     validate_volumes — without this half, a caller could declare
    //     e.g. a "supervisor-bin" PVC volume and this test's first
    //     assertion would fail (the config would decode instead of erroring).
    //
    //   - half 2: rule 6 (validate_volume_mounts) rejects a mount that
    //     names a reserved name directly with *no* matching volume
    //     declared — the only way such a mount could ever be attempted,
    //     since half 1 means the volume itself can never be declared.
    //     Catches: removing the "mount must reference a declared volume"
    //     check — without this half, a mount named "supervisor-bin" would
    //     decode successfully with no volume behind it at all, and this
    //     test's second assertion would fail.
    #[test]
    fn agent_volume_mounts_disjoint_from_driver_config_reserved_names() {
        for reserved in RESERVED_VOLUME_NAMES {
            let template = template_with(json!({
                "volumes": [{
                    "name": reserved,
                    "persistent_volume_claim": {"claim_name": "pvc-reserved"}
                }],
                "containers": {
                    "agent": {
                        "volume_mounts": [{
                            "name": reserved,
                            "mount_path": "/data",
                            "read_only": true
                        }]
                    }
                }
            }));
            let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
                .unwrap_err()
                .to_string();
            assert!(
                err.contains("is reserved for OpenShell-managed volumes"),
                "expected declaring volume {reserved:?} to be rejected, got: {err}"
            );

            let template = template_with(json!({
                "containers": {
                    "agent": {
                        "volume_mounts": [{
                            "name": reserved,
                            "mount_path": "/data",
                            "read_only": true
                        }]
                    }
                }
            }));
            let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
                .unwrap_err()
                .to_string();
            assert!(
                err.contains(&format!("references unknown driver_config volume '{reserved}'")),
                "expected mount naming {reserved:?} with no declared volume to be rejected, got: {err}"
            );
        }
    }

    // Rule 10. Catches: comparing raw (unnormalized) mount paths, which
    // would let "/data" and "/data/" coexist as if they were different
    // targets.
    #[test]
    fn rejects_duplicate_normalized_mount_targets() {
        let template = template_with(json!({
            "volumes": [{
                "name": "user-data",
                "persistent_volume_claim": {"claim_name": "pvc-user-data"}
            }],
            "containers": {
                "agent": {
                    "volume_mounts": [
                        {"name": "user-data", "mount_path": "/data"},
                        {"name": "user-data", "mount_path": "/data/"}
                    ]
                }
            }
        }));

        let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .unwrap_err()
            .to_string();

        assert!(
            err.contains("duplicate driver_config mount target '/data'"),
            "got: {err}"
        );
    }

    // Rule 11. Catches: not validating sub_path, which would let a caller
    // escape the mount via "..".
    #[test]
    fn rejects_invalid_mount_subpath() {
        for sub_path in ["/absolute", "../escape"] {
            let mut config = valid_volume_and_mount();
            config["containers"]["agent"]["volume_mounts"][0]["sub_path"] = json!(sub_path);
            let template = template_with(config);

            let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
                .unwrap_err()
                .to_string();

            assert!(
                err.contains("mount subpath must be relative"),
                "expected sub_path {sub_path:?} to be rejected, got: {err}"
            );
        }
    }

    // Proves deny_unknown_fields is actually live, not just declared.
    // Catches: a serde attribute typo, or #[serde(default)] silently
    // overriding deny_unknown_fields for a nested struct.
    #[test]
    fn rejects_unknown_field() {
        let template = template_with(json!({"cdi_devices": ["nvidia.com/gpu=0"]}));

        let err = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .unwrap_err()
            .to_string();

        assert!(err.contains("unknown field"), "got: {err}");
    }

    // Catches: from_template treating an absent driver_config as an error
    // instead of "no config", which would break every sandbox created
    // before this feature existed (the overwhelming majority today).
    #[test]
    fn absent_driver_config_yields_default() {
        let template = DriverSandboxTemplate::default();

        let config = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .expect("absent config must not error");

        assert_eq!(config, DriverConfig::default());

        let template = template_with(json!({}));
        let config = DriverConfig::from_template(&template, TEST_SUPERVISOR_MOUNT_PATH)
            .expect("empty config must not error");
        assert_eq!(config, DriverConfig::default());
    }

    // Catches: has_explicit_sandbox_data_mount using an inequality instead
    // of path_is_or_under's "equal or under" semantics.
    #[test]
    fn has_explicit_sandbox_data_mount_true_at_workspace_root() {
        let config = DriverConfig {
            containers: ContainersConfig {
                agent: ContainerConfig {
                    volume_mounts: vec![VolumeMountConfig {
                        name: "user-data".to_string(),
                        mount_path: "/sandbox".to_string(),
                        ..Default::default()
                    }],
                    ..Default::default()
                },
            },
            ..Default::default()
        };

        assert!(config.has_explicit_sandbox_data_mount());
    }

    // Catches: has_explicit_sandbox_data_mount using exact equality only,
    // missing mounts nested under the workspace root.
    #[test]
    fn has_explicit_sandbox_data_mount_true_under_workspace_root() {
        let config = DriverConfig {
            containers: ContainersConfig {
                agent: ContainerConfig {
                    volume_mounts: vec![VolumeMountConfig {
                        name: "user-data".to_string(),
                        mount_path: "/sandbox/project".to_string(),
                        ..Default::default()
                    }],
                    ..Default::default()
                },
            },
            ..Default::default()
        };

        assert!(config.has_explicit_sandbox_data_mount());
    }

    // Catches: has_explicit_sandbox_data_mount matching on a substring
    // (e.g. "/sandbox-other") instead of a proper path-component check.
    #[test]
    fn has_explicit_sandbox_data_mount_false_elsewhere() {
        let config = DriverConfig {
            containers: ContainersConfig {
                agent: ContainerConfig {
                    volume_mounts: vec![VolumeMountConfig {
                        name: "user-data".to_string(),
                        mount_path: "/data".to_string(),
                        ..Default::default()
                    }],
                    ..Default::default()
                },
            },
            ..Default::default()
        };

        assert!(!config.has_explicit_sandbox_data_mount());
    }
}
