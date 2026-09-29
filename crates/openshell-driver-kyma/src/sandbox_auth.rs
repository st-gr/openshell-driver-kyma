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
use serde::Serialize;
use std::collections::BTreeMap;

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
///
/// Only the ServiceAccount *name* is validated here. The returned
/// `TokenIdentity::namespace` is UNVALIDATED: a same-named ServiceAccount in
/// another namespace is accepted, so the caller must admit the namespace
/// before trusting the identity.
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
    if namespace.is_empty() {
        return Err(DriverError::PermissionDenied(
            "sandbox credential has an empty namespace".to_string(),
        ));
    }
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

/// Reject a credential from a namespace this driver does not serve.
///
/// An empty `served` list means "not namespace-constrained" (cluster-wide
/// modes); binding is then carried entirely by `admit_owner`.
pub fn admit_namespace(namespace: &str, served: &[String]) -> Result<(), DriverError> {
    if served.is_empty() || served.iter().any(|candidate| candidate == namespace) {
        return Ok(());
    }
    Err(DriverError::PermissionDenied(
        "sandbox credential namespace is not served by this driver".to_string(),
    ))
}

/// Confirm the Sandbox CR resolved from a Pod's label lives in the Pod's
/// namespace and carries the same sandbox-id label.
///
/// This is a consistency check, not the trust binding: the CR is looked up *by*
/// that label, so on its own it cannot detect a Pod that lies about its label.
/// It still matters in the cluster-wide modes, where it stops a Pod from
/// borrowing a same-id CR in another namespace. The binding itself is
/// `admit_pod_owner`.
pub fn admit_owner(
    pod_namespace: &str,
    pod_sandbox_id: &str,
    cr_namespace: &str,
    cr_sandbox_id: Option<&str>,
) -> Result<(), DriverError> {
    if cr_namespace != pod_namespace {
        return Err(DriverError::PermissionDenied(
            "authenticated pod and its sandbox are in different namespaces".to_string(),
        ));
    }
    match cr_sandbox_id {
        Some(found) if found == pod_sandbox_id => Ok(()),
        _ => Err(DriverError::PermissionDenied(
            "authenticated pod is not owned by this sandbox".to_string(),
        )),
    }
}

/// Bind a Pod to the Sandbox CR its label nominated, via ownerReferences.
///
/// The Pod's sandbox-id label only identifies a *candidate* CR; it is
/// caller-visible metadata and proves nothing. The controller-set
/// ownerReference (kind `Sandbox`, UID of the CR) is what binds, because
/// sandbox code cannot write it. `owner_refs` holds `(kind, uid)` pairs.
pub fn admit_pod_owner(cr_uid: &str, owner_refs: &[(String, String)]) -> Result<(), DriverError> {
    if owner_refs
        .iter()
        .any(|(kind, uid)| kind == "Sandbox" && uid == cr_uid)
    {
        return Ok(());
    }
    Err(DriverError::PermissionDenied(
        "authenticated pod is not owned by the sandbox it names".to_string(),
    ))
}

/// Map a failed Pod lookup. A 403 means the driver's ServiceAccount lacks the
/// `pods` get grant, a deployment fault rather than a bad credential.
#[must_use]
pub fn map_pod_lookup_error(error: kube::Error) -> DriverError {
    if let kube::Error::Api(response) = &error {
        if response.code == 403 {
            return DriverError::Unavailable(
                "Kubernetes rejected the Pod lookup (403); the driver ServiceAccount \
                 needs get on pods"
                    .to_string(),
            );
        }
    }
    DriverError::Kube(error)
}

/// A sandbox that disappears between authentication and lookup is a race a
/// client loses, not a server fault — report it as a rejection so it cannot be
/// mistaken for an outage.
#[must_use]
pub fn map_sandbox_lookup_error(error: DriverError) -> DriverError {
    match error {
        DriverError::NotFound(_) => DriverError::PermissionDenied(
            "sandbox for the authenticated pod no longer exists".to_string(),
        ),
        other => other,
    }
}

/// Map a failed TokenReview call onto a status an operator can act on.
///
/// A 403 here means this driver's ServiceAccount is missing the `tokenreviews`
/// create grant, which is a deployment fault. Reporting it as a rejected
/// credential would make a misconfigured install look like an attack.
#[must_use]
pub fn map_token_review_error(error: &kube::Error) -> DriverError {
    if let kube::Error::Api(response) = error {
        if response.code == 403 {
            return DriverError::Unavailable(
                "Kubernetes rejected the TokenReview call (403); the driver ServiceAccount \
                 needs create on tokenreviews"
                    .to_string(),
            );
        }
    }
    DriverError::Unavailable("Kubernetes TokenReview call failed".to_string())
}

#[derive(Serialize)]
struct ResourceAdmission<'a> {
    enabled: bool,
    required_labels: &'a BTreeMap<String, String>,
}

#[derive(Serialize)]
struct DriverAdmission<'a> {
    allow_driver_config: bool,
    resource_admission: ResourceAdmission<'a>,
}

/// Acknowledgement of the gateway's effective resource-admission policy.
///
/// The gateway builds the same policy from `[openshell.drivers.kyma]` and
/// rejects the driver at startup unless this string matches byte-for-byte, so
/// the wire format mirrors upstream's `DriverAdmissionConfig::acknowledgement`:
/// the literal `v1:` followed by the serialised policy. `BTreeMap` keeps key
/// order deterministic, which the equality check depends on.
#[must_use]
pub fn admission_acknowledgement(
    allow_driver_config: bool,
    admission_enabled: bool,
    required_labels: &BTreeMap<String, String>,
) -> String {
    let policy = DriverAdmission {
        allow_driver_config,
        resource_admission: ResourceAdmission {
            enabled: admission_enabled,
            required_labels,
        },
    };
    format!(
        "v1:{}",
        serde_json::to_string(&policy).expect("admission policy is plain data")
    )
}

/// Upstream's default `required_labels`, which apply when the gateway config
/// omits `resource_admission`. The workspace label's value is the literal
/// placeholder upstream substitutes per workspace.
///
/// Reported unconditionally: a gateway that customises `required_labels`
/// will fail the handshake against this value.
#[must_use]
pub fn default_required_labels() -> BTreeMap<String, String> {
    BTreeMap::from([
        (
            "openshell.ai/sandbox-attachable".to_string(),
            "true".to_string(),
        ),
        (
            "openshell.ai/sandbox-attachable-workspace".to_string(),
            "${workspace}".to_string(),
        ),
    ])
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

    // Review Focus 5: blank credentials never reach the apiserver.
    #[test]
    fn blank_credentials_are_rejected() {
        for candidate in ["", "   ", "\t\n"] {
            let err = reject_blank_credential(candidate).unwrap_err();
            assert!(
                matches!(err, DriverError::Unauthenticated(_)),
                "credential {candidate:?} gave {err:?}"
            );
        }
        assert!(reject_blank_credential("a-real-token").is_ok());
    }

    fn denied(s: &TokenReviewStatus) -> bool {
        matches!(
            token_review_identity(s, "sandbox-sa"),
            Err(DriverError::PermissionDenied(_))
        )
    }

    fn base() -> TokenReviewStatus {
        status_for("sandbox-sa", "openshell", "p", "u", SA_TOKEN_AUDIENCE)
    }

    // Finding 1: the namespace is returned unvalidated; the caller must admit it.
    #[test]
    fn foreign_namespace_is_returned_verbatim_for_the_caller_to_admit() {
        let s = status_for("sandbox-sa", "foreign-ns", "p", "u", SA_TOKEN_AUDIENCE);
        let id = token_review_identity(&s, "sandbox-sa").unwrap().unwrap();
        assert_eq!(id.namespace, "foreign-ns");
    }

    // Finding 2: exactly one value per pod extra.
    #[test]
    fn pod_uid_extra_missing_is_rejected() {
        let mut s = base();
        s.user
            .as_mut()
            .unwrap()
            .extra
            .as_mut()
            .unwrap()
            .remove(POD_UID_EXTRA);
        assert!(denied(&s));
    }

    #[test]
    fn pod_name_extra_missing_is_rejected() {
        let mut s = base();
        s.user
            .as_mut()
            .unwrap()
            .extra
            .as_mut()
            .unwrap()
            .remove(POD_NAME_EXTRA);
        assert!(denied(&s));
    }

    #[test]
    fn empty_pod_extra_values_are_rejected() {
        for key in [POD_NAME_EXTRA, POD_UID_EXTRA] {
            let mut s = base();
            s.user
                .as_mut()
                .unwrap()
                .extra
                .as_mut()
                .unwrap()
                .insert(key.into(), vec![]);
            assert!(denied(&s), "empty values for {key}");
        }
    }

    #[test]
    fn multiple_pod_extra_values_are_rejected() {
        for key in [POD_NAME_EXTRA, POD_UID_EXTRA] {
            let mut s = base();
            s.user
                .as_mut()
                .unwrap()
                .extra
                .as_mut()
                .unwrap()
                .insert(key.into(), vec!["a".into(), "b".into()]);
            assert!(denied(&s), "two values for {key}");
        }
    }

    // Finding 3: audience matching is exact membership.
    #[test]
    fn missing_or_empty_audiences_are_rejected() {
        for auds in [None, Some(vec![])] {
            let mut s = base();
            s.audiences = auds;
            let err = token_review_identity(&s, "sandbox-sa").unwrap_err();
            assert!(
                matches!(err, DriverError::Unauthenticated(_)),
                "got {err:?}"
            );
        }
    }

    #[test]
    fn multiple_audiences_including_ours_are_accepted() {
        let mut s = base();
        s.audiences = Some(vec!["other".into(), SA_TOKEN_AUDIENCE.into()]);
        assert!(token_review_identity(&s, "sandbox-sa").unwrap().is_some());
    }

    #[test]
    fn near_miss_audience_is_rejected() {
        let s = status_for("sandbox-sa", "openshell", "p", "u", "openshell-gateway-x");
        let err = token_review_identity(&s, "sandbox-sa").unwrap_err();
        assert!(
            matches!(err, DriverError::Unauthenticated(_)),
            "got {err:?}"
        );
    }

    // Finding 4: username parsing branches.
    #[test]
    fn missing_user_is_rejected() {
        let mut s = base();
        s.user = None;
        assert!(denied(&s));
    }

    #[test]
    fn missing_username_is_rejected() {
        let mut s = base();
        s.user.as_mut().unwrap().username = None;
        assert!(denied(&s));
    }

    #[test]
    fn username_without_a_second_colon_is_rejected() {
        let mut s = base();
        s.user.as_mut().unwrap().username = Some("system:serviceaccount:ns".into());
        assert!(denied(&s));
    }

    #[test]
    fn service_account_name_with_an_extra_colon_is_rejected() {
        let mut s = base();
        s.user.as_mut().unwrap().username = Some("system:serviceaccount:ns:sandbox-sa:x".into());
        assert!(denied(&s));
    }

    // Finding 5: unauthenticated wins, and is checked before the audience.
    #[test]
    fn authenticated_none_yields_none() {
        let mut s = base();
        s.authenticated = None;
        assert!(token_review_identity(&s, "sandbox-sa").unwrap().is_none());
    }

    #[test]
    fn unauthenticated_beats_a_wrong_audience() {
        let mut s = status_for("sandbox-sa", "openshell", "p", "u", "some-other-audience");
        s.authenticated = Some(false);
        assert!(token_review_identity(&s, "sandbox-sa").unwrap().is_none());
    }

    // Finding 6: an empty namespace is rejected outright.
    #[test]
    fn empty_namespace_is_rejected() {
        let mut s = base();
        s.user.as_mut().unwrap().username = Some("system:serviceaccount::sandbox-sa".into());
        assert!(denied(&s));
    }

    // Review Focus 1: SA names are not unique across namespaces.
    #[test]
    fn a_namespace_this_driver_does_not_serve_is_rejected() {
        let err = admit_namespace("someone-elses-ns", &["openshell".to_string()]).unwrap_err();
        assert!(
            matches!(err, DriverError::PermissionDenied(_)),
            "got {err:?}"
        );
        assert!(admit_namespace("openshell", &["openshell".to_string()]).is_ok());
    }

    #[test]
    fn an_empty_served_namespace_list_admits_any_namespace() {
        // Cluster-wide modes do not constrain the namespace here; ownership
        // validation is what binds the pod to the sandbox.
        assert!(admit_namespace("anything", &[]).is_ok());
    }

    // Review Focus 2: the Pod's sandbox-id label is caller-visible metadata.
    // It is only trustworthy once the Sandbox CR it names agrees that it owns
    // that id, and lives in the same namespace as the Pod.
    #[test]
    fn a_cr_that_claims_a_different_sandbox_id_is_rejected() {
        let err = admit_owner("openshell", "sb-1", "openshell", Some("sb-2")).unwrap_err();
        assert!(
            matches!(err, DriverError::PermissionDenied(_)),
            "got {err:?}"
        );
    }

    #[test]
    fn a_cr_with_no_sandbox_id_label_is_rejected() {
        let err = admit_owner("openshell", "sb-1", "openshell", None).unwrap_err();
        assert!(
            matches!(err, DriverError::PermissionDenied(_)),
            "got {err:?}"
        );
    }

    #[test]
    fn a_cr_in_a_different_namespace_than_the_pod_is_rejected() {
        let err = admit_owner("openshell", "sb-1", "other-ns", Some("sb-1")).unwrap_err();
        assert!(
            matches!(err, DriverError::PermissionDenied(_)),
            "got {err:?}"
        );
    }

    #[test]
    fn a_matching_cr_in_the_pods_namespace_is_admitted() {
        assert!(admit_owner("openshell", "sb-1", "openshell", Some("sb-1")).is_ok());
    }

    // Review Focus 3: a sandbox deleted mid-bootstrap is a normal race.
    #[test]
    fn a_vanished_sandbox_is_a_rejection_not_a_server_fault() {
        let mapped = map_sandbox_lookup_error(DriverError::NotFound("gone".into()));
        assert!(
            matches!(mapped, DriverError::PermissionDenied(_)),
            "got {mapped:?}"
        );
        // Anything else keeps its own code.
        let mapped = map_sandbox_lookup_error(DriverError::Unavailable("apiserver".into()));
        assert!(
            matches!(mapped, DriverError::Unavailable(_)),
            "got {mapped:?}"
        );
    }

    // Review Focus 4: a missing RBAC grant must not read as a bad credential.
    #[test]
    fn a_forbidden_tokenreview_is_unavailable_not_unauthenticated() {
        let forbidden = kube::Error::Api(Box::new(
            kube::core::Status::failure("forbidden", "Forbidden").with_code(403),
        ));
        let mapped = map_token_review_error(&forbidden);
        assert!(
            matches!(mapped, DriverError::Unavailable(_)),
            "got {mapped:?}"
        );
        assert!(
            mapped.to_string().contains("tokenreviews"),
            "the message must point an operator at the RBAC grant: {mapped}"
        );
    }

    // Finding 1: the pod's sandbox-id label only nominates a candidate CR; the
    // controller-set ownerReference UID is what binds the pod to it.
    fn refs(items: &[(&str, &str)]) -> Vec<(String, String)> {
        items
            .iter()
            .map(|(k, u)| ((*k).to_string(), (*u).to_string()))
            .collect()
    }

    #[test]
    fn an_owner_reference_with_the_right_kind_and_uid_is_admitted() {
        assert!(admit_pod_owner("cr-uid", &refs(&[("Sandbox", "cr-uid")])).is_ok());
    }

    #[test]
    fn an_owner_reference_with_a_different_uid_is_rejected() {
        let err = admit_pod_owner("cr-uid", &refs(&[("Sandbox", "other")])).unwrap_err();
        assert!(
            matches!(err, DriverError::PermissionDenied(_)),
            "got {err:?}"
        );
    }

    #[test]
    fn an_owner_reference_of_a_different_kind_is_rejected() {
        let err = admit_pod_owner("cr-uid", &refs(&[("ReplicaSet", "cr-uid")])).unwrap_err();
        assert!(
            matches!(err, DriverError::PermissionDenied(_)),
            "got {err:?}"
        );
    }

    #[test]
    fn no_owner_references_is_rejected() {
        let err = admit_pod_owner("cr-uid", &[]).unwrap_err();
        assert!(
            matches!(err, DriverError::PermissionDenied(_)),
            "got {err:?}"
        );
    }

    #[test]
    fn one_matching_reference_among_several_is_admitted() {
        let owners = refs(&[("ReplicaSet", "x"), ("Sandbox", "cr-uid"), ("Sandbox", "y")]);
        assert!(admit_pod_owner("cr-uid", &owners).is_ok());
    }

    // Finding 2: a missing pods RBAC grant is a deployment fault.
    #[test]
    fn a_forbidden_pod_lookup_is_unavailable_and_names_pods() {
        let forbidden = kube::Error::Api(Box::new(kube::core::Status {
            code: 403,
            message: "forbidden".to_string(),
            reason: "Forbidden".to_string(),
            ..Default::default()
        }));
        let mapped = map_pod_lookup_error(forbidden);
        assert!(
            matches!(mapped, DriverError::Unavailable(_)),
            "got {mapped:?}"
        );
        assert!(mapped.to_string().contains("pods"), "{mapped}");
    }

    #[test]
    fn other_pod_lookup_failures_keep_their_kube_mapping() {
        let mapped = map_pod_lookup_error(kube::Error::Api(Box::new(kube::core::Status {
            code: 500,
            ..Default::default()
        })));
        assert!(matches!(mapped, DriverError::Kube(_)), "got {mapped:?}");
    }

    #[test]
    fn acknowledgement_uses_upstreams_versioned_json_format() {
        let mut labels = BTreeMap::new();
        labels.insert(
            "openshell.ai/sandbox-attachable".to_string(),
            "true".to_string(),
        );
        let ack = admission_acknowledgement(true, true, &labels);
        assert_eq!(
            ack,
            r#"v1:{"allow_driver_config":true,"resource_admission":{"enabled":true,"required_labels":{"openshell.ai/sandbox-attachable":"true"}}}"#
        );
    }

    #[test]
    fn acknowledgement_sorts_keys_regardless_of_insertion_order() {
        // The gateway re-reads capabilities and fails if the value changed, so
        // key order must come from sorting, not from insertion order.
        let mut labels = BTreeMap::new();
        for k in ["d", "c", "b", "a"] {
            labels.insert(k.to_string(), k.to_uppercase());
        }
        assert_eq!(
            admission_acknowledgement(false, true, &labels),
            r#"v1:{"allow_driver_config":false,"resource_admission":{"enabled":true,"required_labels":{"a":"A","b":"B","c":"C","d":"D"}}}"#
        );
    }

    #[test]
    fn production_acknowledgement_is_pinned_to_the_exact_wire_string() {
        // Literal on purpose: the gateway compares this byte-for-byte with the
        // policy it derives itself, so any drift must fail here, not at
        // gateway startup.
        assert_eq!(
            admission_acknowledgement(true, true, &default_required_labels()),
            r#"v1:{"allow_driver_config":true,"resource_admission":{"enabled":true,"required_labels":{"openshell.ai/sandbox-attachable":"true","openshell.ai/sandbox-attachable-workspace":"${workspace}"}}}"#
        );
    }
}
