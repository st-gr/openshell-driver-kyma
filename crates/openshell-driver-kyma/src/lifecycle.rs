//! Sandbox operating-state transitions (start/stop).
//!
//! The Sandbox CR expresses "running" differently per API version, so the
//! patch payload is built here as a pure function and unit-tested across
//! both. Mirrors upstream's `sandbox_operating_state_patch`
//! (openshell-driver-kubernetes/src/driver.rs:4254).

use serde_json::{json, Value};

/// API version served by the agent-sandbox CRD this cluster installs today.
pub const SANDBOX_V1ALPHA1: &str = "v1alpha1";
/// Newer API version. Not served by the installed CRD yet; implemented so a
/// future CRD upgrade does not silently patch a field the new version ignores.
pub const SANDBOX_V1BETA1: &str = "v1beta1";

/// Build the merge patch that starts or stops a sandbox.
///
/// `resource_version` is carried as an optimistic-concurrency precondition:
/// if the CR changed since it was read, the API server rejects the patch
/// rather than clobbering a concurrent update.
#[must_use]
pub fn operating_state_patch(api_version: &str, resource_version: &str, running: bool) -> Value {
    if api_version == SANDBOX_V1BETA1 {
        json!({
            "metadata": {"resourceVersion": resource_version},
            "spec": {"operatingMode": if running { "Running" } else { "Suspended" }}
        })
    } else {
        json!({
            "metadata": {"resourceVersion": resource_version},
            "spec": {"replicas": i32::from(running)}
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn v1alpha1_uses_replicas() {
        let stop = operating_state_patch(SANDBOX_V1ALPHA1, "42", false);
        assert_eq!(stop["spec"]["replicas"], 0);
        assert_eq!(stop["metadata"]["resourceVersion"], "42");
        let start = operating_state_patch(SANDBOX_V1ALPHA1, "42", true);
        assert_eq!(start["spec"]["replicas"], 1);
    }

    #[test]
    fn v1beta1_uses_operating_mode() {
        let stop = operating_state_patch(SANDBOX_V1BETA1, "7", false);
        assert_eq!(stop["spec"]["operatingMode"], "Suspended");
        let start = operating_state_patch(SANDBOX_V1BETA1, "7", true);
        assert_eq!(start["spec"]["operatingMode"], "Running");
    }

    /// An unknown version must fall back to the version the CRD actually
    /// serves today rather than emitting a field nothing understands.
    #[test]
    fn unknown_version_falls_back_to_replicas() {
        let p = operating_state_patch("v2thing", "1", true);
        assert_eq!(p["spec"]["replicas"], 1);
        assert!(p["spec"].get("operatingMode").is_none());
    }

    /// The precondition must always be present; without it a concurrent
    /// update would be silently clobbered.
    #[test]
    fn resource_version_precondition_always_present() {
        for v in [SANDBOX_V1ALPHA1, SANDBOX_V1BETA1] {
            for running in [true, false] {
                let p = operating_state_patch(v, "abc", running);
                assert_eq!(
                    p["metadata"]["resourceVersion"], "abc",
                    "{v} running={running}"
                );
            }
        }
    }
}
