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
/// # Errors
/// `PermissionDenied` when the mode is `Operator` and `workspace` is not in
/// the configured allowlist.
pub fn namespace_for(cfg: &Config, workspace: &str) -> Result<String, DriverError> {
    match cfg.workspace_mode {
        WorkspaceMode::Shared => Ok(cfg.namespace.clone()),
        WorkspaceMode::Managed => Ok(managed_namespace(&cfg.gateway_id, workspace)),
        WorkspaceMode::Operator => {
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
        managed.gateway_id = "gw1".into();
        assert!(validate_workspace_mode(&managed).is_ok());

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
}
