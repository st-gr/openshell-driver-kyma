//! Workspace tenancy modes.
//!
//! Upstream's Kubernetes driver models three modes
//! (`crates/openshell-driver-kubernetes/src/config.rs:99`). This driver has
//! always been a correct `Shared`-mode driver; this module makes that one
//! branch of an explicit abstraction rather than an implicit assumption.
//!
//! Every function here returns today's value under `Shared`, which is what
//! makes the mode work safe to land on a live cluster.

use crate::config::Config;
use crate::error::DriverError;

/// Longest name Kubernetes accepts for a DNS-1123 label.
const MAX_KUBE_NAME_LEN: usize = 63;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, clap::ValueEnum)]
#[clap(rename_all = "lower")]
pub enum WorkspaceMode {
    /// One static namespace, `{workspace}--{name}` object names.
    #[default]
    Shared,
    /// One driver-created namespace per workspace, bare object names.
    Managed,
    /// Pre-existing allowlisted namespaces, bare object names.
    Operator,
}

/// `openshell-{gateway_id}-{workspace}`, matching upstream's convention.
#[must_use]
pub fn managed_namespace(gateway_id: &str, workspace: &str) -> String {
    format!("openshell-{gateway_id}-{workspace}")
}

/// Namespace a sandbox in `workspace` belongs in.
///
/// Under `Managed`/`Operator`, `workspace` becomes a Kubernetes namespace
/// *name* and is therefore a path segment on every namespaced API call this
/// driver makes for it (`kube-core`'s `validate_name` only rejects the empty
/// string before splicing the name raw and unencoded into the request URL).
/// This is the one place that check needs to live: every caller that turns a
/// `workspace` into a namespace — `create`, `validate_create` (both via
/// `namespace_for_workspace`/direct call), `ensure_workspace`/
/// `delete_workspace`'s `Operator` arm, and (via
/// `KymaProvisioner::namespace_for_workspace`, reused in place of a direct
/// `managed_namespace` call) `Managed`'s `bootstrap_managed_namespace`/
/// `delete_managed_namespace` — routes through here, so validating here
/// covers all of them at once and the checks cannot drift apart.
///
/// `Shared` never uses `workspace` for anything (`cfg.namespace` is
/// returned unconditionally), so it is intentionally exempt: this must not
/// narrow what `Shared` accepts, since `Shared` is the mode every existing
/// install runs today.
///
/// # Errors
/// `InvalidArgument` when the mode is `Managed`/`Operator` and `workspace`
/// is not a DNS-1123 label. `PermissionDenied` when the mode is `Operator`
/// and `workspace` is not in the configured allowlist.
pub fn namespace_for(cfg: &Config, workspace: &str) -> Result<String, DriverError> {
    match cfg.workspace_mode {
        WorkspaceMode::Shared => Ok(cfg.namespace.clone()),
        WorkspaceMode::Managed => {
            require_dns1123_workspace(workspace)?;
            Ok(managed_namespace(&cfg.gateway_id, workspace))
        }
        WorkspaceMode::Operator => {
            require_dns1123_workspace(workspace)?;
            if cfg
                .operator_namespace_allowlist
                .iter()
                .any(|ns| ns == workspace)
            {
                Ok(workspace.to_string())
            } else {
                Err(DriverError::PermissionDenied(format!(
                    "workspace '{workspace}' is not in the operator namespace allowlist"
                )))
            }
        }
    }
}

/// Kubernetes object name for a sandbox.
///
/// Only `Shared` qualifies the name: it is the mode where several workspaces
/// share one namespace, so the name is the only thing preventing a collision.
#[must_use]
pub fn kube_resource_name(mode: WorkspaceMode, workspace: &str, name: &str) -> String {
    match mode {
        WorkspaceMode::Shared => format!("{workspace}--{name}"),
        WorkspaceMode::Managed | WorkspaceMode::Operator => name.to_string(),
    }
}

/// Whether `DeleteWorkspace` may touch namespaces. Only `Managed` created
/// one, so only `Managed` may delete one.
#[must_use]
pub fn workspace_delete_requires_namespace_access(mode: WorkspaceMode) -> bool {
    matches!(mode, WorkspaceMode::Managed)
}

/// Startup validation, mirroring upstream's `validate_workspace_mode`.
///
/// # Errors
/// `InvalidArgument` when `managed` has no DNS-1123 `gateway_id`, or when
/// `operator` has an empty allowlist.
pub fn validate_workspace_mode(cfg: &Config) -> Result<(), DriverError> {
    match cfg.workspace_mode {
        WorkspaceMode::Shared => Ok(()),
        WorkspaceMode::Managed => {
            if cfg.gateway_id.is_empty() {
                return Err(DriverError::InvalidArgument(
                    "--workspace-mode managed requires --gateway-id".to_string(),
                ));
            }
            if !is_dns1123_label(&cfg.gateway_id) {
                return Err(DriverError::InvalidArgument(format!(
                    "--gateway-id '{}' is not a DNS-1123 label; it becomes part of \
                     every managed namespace name",
                    cfg.gateway_id
                )));
            }
            Ok(())
        }
        WorkspaceMode::Operator => {
            if cfg.operator_namespace_allowlist.is_empty() {
                return Err(DriverError::InvalidArgument(
                    "--workspace-mode operator requires a non-empty \
                     --operator-namespace-allowlist"
                        .to_string(),
                ));
            }
            Ok(())
        }
    }
}

/// Validate the object name a mode would produce.
///
/// # Errors
/// `InvalidArgument` when the workspace is empty (only meaningful for
/// `Shared`, where it would produce a leading `--`), or when the resulting
/// name exceeds the DNS-1123 limit.
pub fn validate_kube_resource_name(
    mode: WorkspaceMode,
    workspace: &str,
    name: &str,
) -> Result<(), DriverError> {
    if workspace.is_empty() {
        return Err(DriverError::InvalidArgument(
            "sandbox workspace is required".to_string(),
        ));
    }
    let combined = kube_resource_name(mode, workspace, name);
    if combined.len() > MAX_KUBE_NAME_LEN {
        return Err(DriverError::InvalidArgument(format!(
            "combined Kubernetes resource name '{combined}' is {} characters, \
             exceeding the DNS-1123 limit of {MAX_KUBE_NAME_LEN}",
            combined.len()
        )));
    }
    Ok(())
}

/// Validate a caller-supplied `workspace` string at the gRPC boundary, for
/// the `EnsureWorkspace`/`DeleteWorkspace` RPCs.
///
/// Mode-aware, matching `namespace_for`'s own gate (this is a second,
/// earlier check that exists purely for a better error message at the RPC
/// boundary; `namespace_for` is what actually protects every path — see its
/// doc comment):
///
/// - Under `Managed`/`Operator`, `workspace` becomes a Kubernetes resource
///   *name* — interpolated into the request URL path raw and unencoded,
///   since `kube-core`'s own `validate_name` only rejects the empty string.
///   Requiring a DNS-1123 label here closes that off: a traversal-shaped
///   workspace like `a/../../../api/v1/...` is rejected before it ever
///   reaches `kube::Api`.
/// - Under `Shared`, `namespace_for` ignores `workspace` entirely (it always
///   returns `cfg.namespace`), so this must not narrow what `Shared`
///   accepts beyond what it always required: non-empty. Before this
///   function existed, `EnsureWorkspace`/`DeleteWorkspace` returned
///   `Unimplemented` (swallowed by the gateway) for every mode, so `Shared`
///   accepted any non-empty workspace string, dots included — e.g.
///   `acme.dev`. A strict DNS-1123 check here would silently reject that
///   workspace today, which is the regression this mode-awareness exists to
///   undo.
///
/// # Errors
/// Under `Shared`: `InvalidArgument` when `workspace` is empty.
/// Under `Managed`/`Operator`: `InvalidArgument` when `workspace` is not a
/// DNS-1123 label (empty, contains anything other than lowercase ASCII
/// letters/digits/hyphens, starts/ends with a hyphen, or exceeds 63
/// characters).
pub fn validate_workspace_name(mode: WorkspaceMode, workspace: &str) -> Result<(), DriverError> {
    match mode {
        WorkspaceMode::Shared => {
            if workspace.is_empty() {
                Err(DriverError::InvalidArgument(
                    "workspace is required".to_string(),
                ))
            } else {
                Ok(())
            }
        }
        WorkspaceMode::Managed | WorkspaceMode::Operator => require_dns1123_workspace(workspace),
    }
}

/// Strict DNS-1123 label check, shared by `namespace_for`'s `Managed`/
/// `Operator` arms (the actual protection: every path that turns
/// `workspace` into a namespace name routes through `namespace_for`) and
/// `validate_workspace_name`'s `Managed`/`Operator` arm (the earlier,
/// better-worded gRPC-boundary error). Kept as one function so the two
/// checks cannot drift apart.
fn require_dns1123_workspace(workspace: &str) -> Result<(), DriverError> {
    if is_dns1123_label(workspace) {
        Ok(())
    } else {
        Err(DriverError::InvalidArgument(format!(
            "workspace '{workspace}' is not a valid DNS-1123 label: it must be \
             non-empty, at most {MAX_KUBE_NAME_LEN} characters, contain only \
             lowercase ASCII letters, digits, and hyphens, and not start or \
             end with a hyphen"
        )))
    }
}

fn is_dns1123_label(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MAX_KUBE_NAME_LEN
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && !s.starts_with('-')
        && !s.ends_with('-')
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    fn cfg_with(mode: WorkspaceMode) -> Config {
        let mut c = Config::parse_from(["driver"]);
        c.workspace_mode = mode;
        c
    }

    #[test]
    fn shared_is_the_default_mode() {
        assert_eq!(
            Config::parse_from(["driver"]).workspace_mode,
            WorkspaceMode::Shared
        );
    }

    /// The property the whole design rests on: an existing install that sets
    /// no new value behaves exactly as it does today.
    #[test]
    fn shared_reproduces_todays_behaviour() {
        let c = cfg_with(WorkspaceMode::Shared);
        assert_eq!(namespace_for(&c, "default").unwrap(), c.namespace);
        assert_eq!(
            kube_resource_name(WorkspaceMode::Shared, "default", "hello"),
            "default--hello"
        );
    }

    #[test]
    fn managed_derives_a_namespace_and_uses_bare_names() {
        let mut c = cfg_with(WorkspaceMode::Managed);
        c.gateway_id = "gw1".into();
        assert_eq!(namespace_for(&c, "team-a").unwrap(), "openshell-gw1-team-a");
        assert_eq!(
            kube_resource_name(WorkspaceMode::Managed, "team-a", "hello"),
            "hello"
        );
    }

    #[test]
    fn operator_accepts_only_allowlisted_workspaces() {
        let mut c = cfg_with(WorkspaceMode::Operator);
        c.operator_namespace_allowlist = vec!["tenant-a".into()];
        assert_eq!(namespace_for(&c, "tenant-a").unwrap(), "tenant-a");
        let err = namespace_for(&c, "kube-system").expect_err("must be denied");
        assert!(matches!(err, DriverError::PermissionDenied(_)));

        // A strict substring of an allowlisted entry must not match.
        let err = namespace_for(&c, "tenant").expect_err("substring must be denied");
        assert!(matches!(err, DriverError::PermissionDenied(_)));

        // A workspace that strictly contains an allowlisted entry must not
        // match either — this rules out both `ns.contains(workspace)` and
        // `workspace.contains(ns)` style bugs.
        let err = namespace_for(&c, "tenant-a-extra").expect_err("superstring must be denied");
        assert!(matches!(err, DriverError::PermissionDenied(_)));

        // Uppercase is not a valid DNS-1123 label, so under Operator this is
        // now caught by the charset gate before the allowlist comparison
        // ever runs — it is rejected either way, just as `InvalidArgument`
        // rather than `PermissionDenied`. (A same-charset case difference
        // can't be constructed here: DNS-1123 forbids uppercase entirely,
        // which is exactly why the allowlist comparison being case-sensitive
        // no longer matters for this input.)
        let err = namespace_for(&c, "TENANT-A").expect_err("must be denied");
        assert!(matches!(err, DriverError::InvalidArgument(_)));
    }

    /// The exact hole `namespace_for`'s charset gate closes for `Operator`:
    /// a traversal- or otherwise invalid-shaped workspace must never reach
    /// the allowlist comparison, let alone be returned as a namespace name.
    #[test]
    fn operator_rejects_invalid_charset_workspace_before_the_allowlist_check() {
        let mut c = cfg_with(WorkspaceMode::Operator);
        c.operator_namespace_allowlist = vec!["tenant-a".into()];
        let err = namespace_for(&c, "a/../../../../api/v1/namespaces/kube-system")
            .expect_err("traversal-shaped workspace must be rejected");
        assert!(matches!(err, DriverError::InvalidArgument(_)));
    }

    /// Same property, but for `Managed`: an invalid-charset workspace must
    /// never reach `managed_namespace` and become part of a namespace name.
    #[test]
    fn managed_rejects_invalid_charset_workspace() {
        let mut c = cfg_with(WorkspaceMode::Managed);
        c.gateway_id = "gw1".into();
        let err = namespace_for(&c, "acme.dev").expect_err("dot is not DNS-1123");
        assert!(matches!(err, DriverError::InvalidArgument(_)));
    }

    /// The regression this whole fix undoes: `Shared` must accept every
    /// workspace it accepted before this branch, including one containing a
    /// dot (a valid Sandbox CR name character, just not a valid DNS-1123
    /// label) — `namespace_for` ignores `workspace` entirely under `Shared`,
    /// so no charset gate ever runs for it.
    #[test]
    fn shared_accepts_a_workspace_containing_a_dot() {
        let c = cfg_with(WorkspaceMode::Shared);
        assert_eq!(namespace_for(&c, "acme.dev").unwrap(), c.namespace);
    }

    /// The separator is two dashes so a single-dash workspace or sandbox name
    /// cannot forge a collision.
    #[test]
    fn shared_names_cannot_collide_across_workspaces() {
        assert_ne!(
            kube_resource_name(WorkspaceMode::Shared, "a-b", "c"),
            kube_resource_name(WorkspaceMode::Shared, "a", "b-c")
        );
    }

    #[test]
    fn only_managed_may_delete_namespaces() {
        assert!(!workspace_delete_requires_namespace_access(
            WorkspaceMode::Shared
        ));
        assert!(workspace_delete_requires_namespace_access(
            WorkspaceMode::Managed
        ));
        assert!(!workspace_delete_requires_namespace_access(
            WorkspaceMode::Operator
        ));
    }

    #[test]
    fn startup_validation_rejects_incomplete_configs() {
        assert!(validate_workspace_mode(&cfg_with(WorkspaceMode::Shared)).is_ok());

        let mut managed = cfg_with(WorkspaceMode::Managed);
        assert!(validate_workspace_mode(&managed).is_err(), "no gateway_id");
        managed.gateway_id = "Bad_ID".into();
        assert!(validate_workspace_mode(&managed).is_err(), "not DNS-1123");
        managed.gateway_id = "-gw1".into();
        assert!(validate_workspace_mode(&managed).is_err(), "leading hyphen");
        managed.gateway_id = "gw1-".into();
        assert!(
            validate_workspace_mode(&managed).is_err(),
            "trailing hyphen"
        );
        managed.gateway_id = "a".repeat(64);
        assert!(validate_workspace_mode(&managed).is_err(), "over-length");
        managed.gateway_id = "gw1".into();
        assert!(validate_workspace_mode(&managed).is_ok());
        managed.gateway_id = "gw-1".into();
        assert!(
            validate_workspace_mode(&managed).is_ok(),
            "valid id with an internal hyphen must still pass"
        );

        let mut operator = cfg_with(WorkspaceMode::Operator);
        assert!(
            validate_workspace_mode(&operator).is_err(),
            "empty allowlist"
        );
        operator.operator_namespace_allowlist = vec!["tenant-a".into()];
        assert!(validate_workspace_mode(&operator).is_ok());
    }

    #[test]
    fn name_length_is_checked_against_the_name_the_mode_produces() {
        let long = "a".repeat(60);
        // Shared adds "default--" (9 chars), so 60 is over the limit...
        assert!(validate_kube_resource_name(WorkspaceMode::Shared, "default", &long).is_err());
        // ...but Managed uses the bare name, so the same input is fine.
        assert!(validate_kube_resource_name(WorkspaceMode::Managed, "default", &long).is_ok());
        assert!(validate_kube_resource_name(WorkspaceMode::Shared, "", "hello").is_err());
    }

    /// Pins both sides of the DNS-1123 boundary under `Shared`. Exactly 63
    /// combined characters must be accepted; 64 must not. Without the
    /// positive case, changing the length check from `>` to `>=` would still
    /// pass the rest of the suite.
    #[test]
    fn shared_name_at_exactly_the_dns1123_limit_is_accepted() {
        let at_limit = "a".repeat(MAX_KUBE_NAME_LEN - "default".len() - 2);
        assert_eq!(
            kube_resource_name(WorkspaceMode::Shared, "default", &at_limit).len(),
            MAX_KUBE_NAME_LEN
        );
        assert!(validate_kube_resource_name(WorkspaceMode::Shared, "default", &at_limit).is_ok());

        let over = format!("{at_limit}a");
        assert!(validate_kube_resource_name(WorkspaceMode::Shared, "default", &over).is_err());
    }

    #[test]
    fn validate_workspace_name_managed_operator_accepts_realistic_values() {
        for mode in [WorkspaceMode::Managed, WorkspaceMode::Operator] {
            for ws in ["default", "ws-a", "team-a", "tenant-a", "a", "a-1-b"] {
                assert!(
                    validate_workspace_name(mode, ws).is_ok(),
                    "expected {ws:?} to be accepted under {mode:?}"
                );
            }
        }
    }

    /// The exact hole this closes for `Managed`/`Operator`: a traversal-
    /// shaped workspace string that would otherwise be spliced raw into a
    /// `kube::Api` request path.
    #[test]
    fn validate_workspace_name_managed_operator_rejects_path_traversal() {
        for mode in [WorkspaceMode::Managed, WorkspaceMode::Operator] {
            let err = validate_workspace_name(mode, "a/../../../../api/v1/namespaces/kube-system")
                .expect_err("traversal-shaped workspace must be rejected");
            assert!(matches!(err, DriverError::InvalidArgument(_)));
        }
    }

    /// Every mode rejects an empty workspace — `Managed`/`Operator` via the
    /// DNS-1123 gate, `Shared` via its own explicit emptiness check.
    #[test]
    fn validate_workspace_name_rejects_empty_in_every_mode() {
        for mode in [
            WorkspaceMode::Shared,
            WorkspaceMode::Managed,
            WorkspaceMode::Operator,
        ] {
            assert!(
                validate_workspace_name(mode, "").is_err(),
                "expected empty workspace to be rejected under {mode:?}"
            );
        }
    }

    #[test]
    fn validate_workspace_name_managed_operator_rejects_invalid_characters_and_shape() {
        for mode in [WorkspaceMode::Managed, WorkspaceMode::Operator] {
            for ws in [
                "Default",       // uppercase
                "team_a",        // underscore
                "-team-a",       // leading hyphen
                "team-a-",       // trailing hyphen
                "acme.dev",      // dot — a valid Sandbox CR name char, not DNS-1123
                &"a".repeat(64), // over 63 characters
            ] {
                assert!(
                    validate_workspace_name(mode, ws).is_err(),
                    "expected {ws:?} to be rejected under {mode:?}"
                );
            }
        }
    }

    /// The regression this fix undoes, at the gRPC-boundary check
    /// (`EnsureWorkspace`/`DeleteWorkspace`) rather than at `namespace_for`:
    /// before this branch, those RPCs returned `Unimplemented` under every
    /// mode (swallowed by the gateway), so `Shared` accepted any non-empty
    /// workspace string — a dot included, e.g. a Sandbox CR named for the
    /// workspace `acme.dev`. A mode-blind strict DNS-1123 check would reject
    /// that today; `Shared` must still accept it.
    #[test]
    fn validate_workspace_name_shared_mode_accepts_a_workspace_containing_a_dot() {
        assert!(validate_workspace_name(WorkspaceMode::Shared, "acme.dev").is_ok());
    }
}
