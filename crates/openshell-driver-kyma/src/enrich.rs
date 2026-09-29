// SPDX-License-Identifier: Apache-2.0

//! Hook 1: Kyma pod-level settings added to a sandbox before upstream sees it.
//!
//! Upstream copies `template.labels` onto the workload and merges
//! `template.environment` into its environment (`build_sandbox_env`), so
//! editing the request is enough — no pod patching, no webhook. Keys the caller
//! already set are never overwritten. Upstream applies `spec.environment` after
//! `template.environment`, so a caller's spec environment also outranks
//! enrichment.

use openshell_core::proto::compute::v1::DriverSandbox;

/// Istio must not inject a sidecar into sandbox workloads: upstream's workload
/// fence gives them no egress, and the sidecar would sit outside the boundary.
pub const ISTIO_INJECT_LABEL: &str = "sidecar.istio.io/inject";
pub const KAGENTI_TYPE_LABEL: &str = "kagenti.io/type";
pub const KAGENTI_TYPE_VALUE: &str = "agent";
pub const CLAUDE_TELEMETRY_ENV: &str = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC";

/// What hook 1 adds to every sandbox.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct EnrichConfig {
    /// Value of the `sidecar.istio.io/inject` label.
    pub istio_inject: bool,
    /// Environment added to the sandbox template.
    pub environment: Vec<(String, String)>,
}

/// Add Kyma labels and environment to `sandbox`, never overwriting a key the
/// caller set.
pub fn enrich(sandbox: &mut DriverSandbox, config: &EnrichConfig) {
    let template = sandbox
        .spec
        .get_or_insert_with(Default::default)
        .template
        .get_or_insert_with(Default::default);
    template
        .labels
        .entry(ISTIO_INJECT_LABEL.to_string())
        .or_insert_with(|| config.istio_inject.to_string());
    template
        .labels
        .entry(KAGENTI_TYPE_LABEL.to_string())
        .or_insert_with(|| KAGENTI_TYPE_VALUE.to_string());
    for (key, value) in &config.environment {
        template
            .environment
            .entry(key.clone())
            .or_insert_with(|| value.clone());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openshell_core::proto::compute::v1::{DriverSandboxSpec, DriverSandboxTemplate};

    fn config() -> EnrichConfig {
        EnrichConfig {
            istio_inject: false,
            environment: vec![(
                "ANTHROPIC_BASE_URL".to_string(),
                "http://proxy:8080".to_string(),
            )],
        }
    }

    #[test]
    fn adds_labels_and_environment_to_a_bare_sandbox() {
        let mut sandbox = DriverSandbox {
            id: "sb-1".to_string(),
            ..Default::default()
        };
        enrich(&mut sandbox, &config());
        let template = sandbox.spec.unwrap().template.unwrap();
        assert_eq!(template.labels[ISTIO_INJECT_LABEL], "false");
        assert_eq!(template.labels[KAGENTI_TYPE_LABEL], KAGENTI_TYPE_VALUE);
        assert_eq!(
            template.environment["ANTHROPIC_BASE_URL"],
            "http://proxy:8080"
        );
    }

    #[test]
    fn istio_injection_can_be_requested() {
        let mut sandbox = DriverSandbox::default();
        enrich(
            &mut sandbox,
            &EnrichConfig {
                istio_inject: true,
                environment: vec![],
            },
        );
        let template = sandbox.spec.unwrap().template.unwrap();
        assert_eq!(template.labels[ISTIO_INJECT_LABEL], "true");
    }

    // Review Focus 1.
    #[test]
    fn caller_values_win_over_enrichment() {
        let mut template = DriverSandboxTemplate::default();
        template
            .labels
            .insert(ISTIO_INJECT_LABEL.to_string(), "true".to_string());
        template
            .environment
            .insert("ANTHROPIC_BASE_URL".to_string(), "http://mine".to_string());
        let mut sandbox = DriverSandbox {
            spec: Some(DriverSandboxSpec {
                template: Some(template),
                ..Default::default()
            }),
            ..Default::default()
        };
        enrich(&mut sandbox, &config());
        let template = sandbox.spec.unwrap().template.unwrap();
        assert_eq!(template.labels[ISTIO_INJECT_LABEL], "true");
        assert_eq!(template.labels[KAGENTI_TYPE_LABEL], KAGENTI_TYPE_VALUE);
        assert_eq!(template.environment["ANTHROPIC_BASE_URL"], "http://mine");
    }

    #[test]
    fn keeps_existing_spec_fields() {
        let mut sandbox = DriverSandbox {
            spec: Some(DriverSandboxSpec {
                log_level: "debug".to_string(),
                ..Default::default()
            }),
            ..Default::default()
        };
        enrich(&mut sandbox, &config());
        assert_eq!(sandbox.spec.unwrap().log_level, "debug");
    }
}
