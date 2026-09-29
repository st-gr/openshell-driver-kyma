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

use crate::error::DriverError;
use crate::provisioner::SA_TOKEN_AUDIENCE;
use k8s_openapi::api::authentication::v1::{TokenReviewStatus, UserInfo};

/// Kubernetes-populated TokenReview extras identifying the presenting Pod.
pub const POD_NAME_EXTRA: &str = "authentication.kubernetes.io/pod-name";
pub const POD_UID_EXTRA: &str = "authentication.kubernetes.io/pod-uid";

const SA_USERNAME_PREFIX: &str = "system:serviceaccount:";

/// The Pod identity a verified sandbox credential resolves to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenIdentity {
    pub namespace: String,
    pub pod_name: String,
    pub pod_uid: String,
}

/// Reject an empty credential before spending an apiserver round trip on it.
pub fn reject_blank_credential(credential: &str) -> Result<(), DriverError> {
    if credential.trim().is_empty() {
        return Err(DriverError::Unauthenticated(
            "sandbox credential was empty".to_string(),
        ));
    }
    Ok(())
}

fn user_extra_one(user: &UserInfo, key: &str) -> Result<String, DriverError> {
    user.extra
        .as_ref()
        .and_then(|extra| extra.get(key))
        .and_then(|values| match values.as_slice() {
            [single] => Some(single.clone()),
            _ => None,
        })
        .ok_or_else(|| {
            DriverError::PermissionDenied(format!(
                "sandbox credential is missing exactly one {key}"
            ))
        })
}

/// Validate a TokenReview result and extract the presenting Pod's identity.
///
/// `Ok(None)` means the apiserver did not authenticate the token at all, which
/// the caller reports as a plain rejection. `Err` means the token authenticated
/// but is not one this driver accepts.
pub fn token_review_identity(
    status: &TokenReviewStatus,
    expected_service_account: &str,
) -> Result<Option<TokenIdentity>, DriverError> {
    if status.authenticated != Some(true) {
        return Ok(None);
    }
    if !status
        .audiences
        .as_deref()
        .unwrap_or_default()
        .iter()
        .any(|audience| audience == SA_TOKEN_AUDIENCE)
    {
        return Err(DriverError::Unauthenticated(
            "sandbox credential audience not accepted".to_string(),
        ));
    }
    let user = status
        .user
        .as_ref()
        .ok_or_else(|| DriverError::PermissionDenied("TokenReview returned no user".to_string()))?;
    let (namespace, service_account) = user
        .username
        .as_deref()
        .and_then(|username| username.strip_prefix(SA_USERNAME_PREFIX))
        .and_then(|rest| rest.split_once(':'))
        .ok_or_else(|| {
            DriverError::PermissionDenied(
                "sandbox credential is not a ServiceAccount token".to_string(),
            )
        })?;
    if service_account != expected_service_account {
        return Err(DriverError::PermissionDenied(
            "sandbox credential ServiceAccount is not accepted".to_string(),
        ));
    }
    Ok(Some(TokenIdentity {
        namespace: namespace.to_string(),
        pod_name: user_extra_one(user, POD_NAME_EXTRA)?,
        pod_uid: user_extra_one(user, POD_UID_EXTRA)?,
    }))
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

    use k8s_openapi::api::authentication::v1::{TokenReviewStatus, UserInfo};
    use std::collections::BTreeMap;

    fn status_for(sa: &str, ns: &str, pod: &str, uid: &str, audience: &str) -> TokenReviewStatus {
        let mut extra = BTreeMap::new();
        extra.insert(POD_NAME_EXTRA.to_string(), vec![pod.to_string()]);
        extra.insert(POD_UID_EXTRA.to_string(), vec![uid.to_string()]);
        TokenReviewStatus {
            authenticated: Some(true),
            audiences: Some(vec![audience.to_string()]),
            user: Some(UserInfo {
                username: Some(format!("system:serviceaccount:{ns}:{sa}")),
                extra: Some(extra),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    #[test]
    fn accepts_a_well_formed_sandbox_token() {
        let s = status_for(
            "sandbox-sa",
            "openshell",
            "sb-pod",
            "pod-uid",
            SA_TOKEN_AUDIENCE,
        );
        let id = token_review_identity(&s, "sandbox-sa").unwrap().unwrap();
        assert_eq!(id.namespace, "openshell");
        assert_eq!(id.pod_name, "sb-pod");
        assert_eq!(id.pod_uid, "pod-uid");
    }

    #[test]
    fn unauthenticated_token_yields_none() {
        let mut s = status_for("sandbox-sa", "openshell", "p", "u", SA_TOKEN_AUDIENCE);
        s.authenticated = Some(false);
        assert!(token_review_identity(&s, "sandbox-sa").unwrap().is_none());
    }

    #[test]
    fn wrong_audience_is_rejected() {
        let s = status_for("sandbox-sa", "openshell", "p", "u", "some-other-audience");
        let err = token_review_identity(&s, "sandbox-sa").unwrap_err();
        assert!(
            matches!(err, DriverError::Unauthenticated(_)),
            "got {err:?}"
        );
    }

    #[test]
    fn a_different_service_account_is_rejected() {
        let s = status_for("some-other-sa", "openshell", "p", "u", SA_TOKEN_AUDIENCE);
        let err = token_review_identity(&s, "sandbox-sa").unwrap_err();
        assert!(
            matches!(err, DriverError::PermissionDenied(_)),
            "got {err:?}"
        );
    }

    #[test]
    fn a_non_service_account_user_is_rejected() {
        let mut s = status_for("sandbox-sa", "openshell", "p", "u", SA_TOKEN_AUDIENCE);
        s.user.as_mut().unwrap().username = Some("kubernetes-admin".into());
        let err = token_review_identity(&s, "sandbox-sa").unwrap_err();
        assert!(
            matches!(err, DriverError::PermissionDenied(_)),
            "got {err:?}"
        );
    }

    #[test]
    fn missing_pod_extras_are_rejected() {
        let mut s = status_for("sandbox-sa", "openshell", "p", "u", SA_TOKEN_AUDIENCE);
        s.user.as_mut().unwrap().extra = None;
        let err = token_review_identity(&s, "sandbox-sa").unwrap_err();
        assert!(
            matches!(err, DriverError::PermissionDenied(_)),
            "got {err:?}"
        );
    }

    // Review Focus 5: rejected before any apiserver call.
    #[test]
    fn blank_credentials_are_rejected_without_calling_the_apiserver() {
        for candidate in ["", "   ", "\t\n"] {
            let err = reject_blank_credential(candidate).unwrap_err();
            assert!(
                matches!(err, DriverError::Unauthenticated(_)),
                "credential {candidate:?} gave {err:?}"
            );
        }
        assert!(reject_blank_credential("a-real-token").is_ok());
    }
}
