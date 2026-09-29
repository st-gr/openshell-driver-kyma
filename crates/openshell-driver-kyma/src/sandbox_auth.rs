// SPDX-License-Identifier: Apache-2.0

//! Sandbox bootstrap authentication: runtime identity formatting and
//! TokenReview response validation.
//!
//! Everything here is pure — no Kubernetes API calls — so the whole module is
//! unit-testable. `provisioner.rs` owns the I/O and calls into this.

/// URI scheme for this driver's runtime identities.
///
/// Upstream's Kubernetes driver uses `kubernetes://{ns}/{cr_uid}/{pod_uid}`.
/// This driver omits the pod UID: the Sandbox CR is created here but its Pod is
/// created afterwards by the agent-sandbox controller, so no Pod UID exists at
/// `CreateSandbox` time, and the CR outlives Pod replacement. Pod-level binding
/// is enforced instead at authentication time, by checking that the presenting
/// Pod is owned by this CR.
pub const RUNTIME_IDENTITY_SCHEME: &str = "kyma";

/// Opaque, stable identity of the compute resource backing a sandbox.
///
/// The gateway persists the value returned by `CreateSandbox`/`StartSandbox`
/// and compares it byte-for-byte with the value `AuthenticateSandbox` returns.
/// Every producer must go through this function so the three can never drift.
#[must_use]
pub fn runtime_identity(namespace: &str, sandbox_uid: &str) -> String {
    format!("{RUNTIME_IDENTITY_SCHEME}://{namespace}/{sandbox_uid}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_identity_has_the_documented_shape() {
        assert_eq!(
            runtime_identity("openshell", "abc-123"),
            "kyma://openshell/abc-123"
        );
    }

    #[test]
    fn runtime_identity_is_stable_for_the_same_inputs() {
        assert_eq!(
            runtime_identity("ns", "uid"),
            runtime_identity("ns", "uid"),
            "the gateway compares this value for equality across calls"
        );
    }
}
