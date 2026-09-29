// SPDX-License-Identifier: Apache-2.0

//! Kyma-layer options. Every flag starts with `--kyma-` and every environment
//! variable with `OPENSHELL_KYMA_`, so they can never collide with upstream's.

use crate::enrich::{EnrichConfig, CLAUDE_TELEMETRY_ENV};

/// Kyma options, flattened next to [`crate::upstream_args::UpstreamArgs`].
#[derive(clap::Args, Debug, Clone, Default)]
pub struct KymaArgs {
    /// Let Istio inject a sidecar into sandbox workloads (label value "true").
    #[arg(long, env = "OPENSHELL_KYMA_ISTIO_INJECT_SANDBOXES")]
    pub kyma_istio_inject_sandboxes: bool,

    /// Add CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 to every sandbox.
    #[arg(long, env = "OPENSHELL_KYMA_DISABLE_CLAUDE_TELEMETRY")]
    pub kyma_disable_claude_telemetry: bool,

    /// KEY=VALUE added to every sandbox's environment. Repeatable; the
    /// environment variable takes a comma-separated list.
    #[arg(long, env = "OPENSHELL_KYMA_SANDBOX_ENV", value_delimiter = ',')]
    pub kyma_sandbox_env: Vec<String>,

    /// Expose each sandbox's port 8080 through a Kyma APIRule.
    #[arg(long, env = "OPENSHELL_KYMA_ENABLE_APIRULE")]
    pub kyma_enable_apirule: bool,

    /// Domain for APIRule hosts (`<sandbox>.<domain>`). Required with
    /// --kyma-enable-apirule.
    #[arg(long, env = "OPENSHELL_KYMA_CLUSTER_DOMAIN", default_value = "")]
    pub kyma_cluster_domain: String,

    /// Namespace of the Istio ingress gateway that APIRule traffic arrives from.
    #[arg(
        long,
        env = "OPENSHELL_KYMA_INGRESS_NAMESPACE",
        default_value = "istio-system"
    )]
    pub kyma_ingress_namespace: String,

    /// Pod Security level applied to namespaces the driver creates in Managed
    /// mode. Empty leaves them unlabelled.
    #[arg(long, env = "OPENSHELL_KYMA_WORKSPACE_PSA_LEVEL", default_value = "")]
    pub kyma_workspace_psa_level: String,

    /// Port for /healthz and /readyz.
    #[arg(long, env = "OPENSHELL_KYMA_HEALTH_PORT", default_value_t = 9090)]
    pub kyma_health_port: u16,
}

impl KymaArgs {
    /// Reject combinations that would misbehave at runtime, naming the culprit.
    pub fn validate(&self) -> Result<(), String> {
        for entry in &self.kyma_sandbox_env {
            match entry.split_once('=') {
                Some((key, _)) if !key.is_empty() => {}
                _ => {
                    return Err(format!(
                        "--kyma-sandbox-env entry `{entry}` must be KEY=VALUE with a non-empty KEY"
                    ))
                }
            }
        }
        if self.kyma_enable_apirule && self.kyma_cluster_domain.is_empty() {
            return Err(
                "--kyma-cluster-domain is required when --kyma-enable-apirule is set".into(),
            );
        }
        if !matches!(
            self.kyma_workspace_psa_level.as_str(),
            "" | "privileged" | "baseline" | "restricted"
        ) {
            return Err(format!(
                "--kyma-workspace-psa-level `{}` is not a Pod Security level \
                 (privileged, baseline, restricted, or empty)",
                self.kyma_workspace_psa_level
            ));
        }
        Ok(())
    }

    /// Hook 1's configuration. Call only after [`KymaArgs::validate`] succeeded.
    pub fn enrich_config(&self) -> EnrichConfig {
        let mut environment: Vec<(String, String)> = self
            .kyma_sandbox_env
            .iter()
            .filter_map(|entry| entry.split_once('='))
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect();
        if self.kyma_disable_claude_telemetry {
            environment.push((CLAUDE_TELEMETRY_ENV.to_string(), "1".to_string()));
        }
        EnrichConfig {
            istio_inject: self.kyma_istio_inject_sandboxes,
            environment,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[derive(Parser)]
    struct Probe {
        #[command(flatten)]
        kyma: KymaArgs,
    }

    fn parse(argv: &[&str]) -> KymaArgs {
        let mut full = vec!["openshell-driver-kyma"];
        full.extend_from_slice(argv);
        Probe::try_parse_from(full)
            .expect("arguments should parse")
            .kyma
    }

    #[test]
    fn defaults() {
        let args = parse(&[]);
        assert!(!args.kyma_istio_inject_sandboxes);
        assert!(!args.kyma_enable_apirule);
        assert_eq!(args.kyma_ingress_namespace, "istio-system");
        assert_eq!(args.kyma_workspace_psa_level, "");
        assert_eq!(args.kyma_health_port, 9090);
        assert!(args.validate().is_ok());
    }

    #[test]
    fn telemetry_flag_and_sandbox_env_become_enrichment_environment() {
        let args = parse(&[
            "--kyma-disable-claude-telemetry",
            "--kyma-sandbox-env",
            "ANTHROPIC_BASE_URL=http://proxy:8080/anthropic",
            "--kyma-sandbox-env",
            "ANTHROPIC_MODEL=claude-opus-4-7",
        ]);
        let config = args.enrich_config();
        assert!(config.environment.contains(&(
            "ANTHROPIC_BASE_URL".to_string(),
            "http://proxy:8080/anthropic".to_string()
        )));
        assert!(config
            .environment
            .contains(&("ANTHROPIC_MODEL".to_string(), "claude-opus-4-7".to_string())));
        assert!(config
            .environment
            .contains(&(CLAUDE_TELEMETRY_ENV.to_string(), "1".to_string())));
    }

    #[test]
    fn sandbox_env_value_may_contain_equals_signs() {
        let args = parse(&["--kyma-sandbox-env", "OPTS=a=b"]);
        assert!(args.validate().is_ok());
        assert_eq!(
            args.enrich_config().environment,
            vec![("OPTS".to_string(), "a=b".to_string())]
        );
    }

    // Review Focus 2.
    #[test]
    fn malformed_sandbox_env_is_rejected_by_name() {
        for bad in ["NO_EQUALS", "=value"] {
            let err = parse(&["--kyma-sandbox-env", bad]).validate().unwrap_err();
            assert!(err.contains(bad), "error must name the entry: {err}");
        }
    }

    #[test]
    fn apirule_requires_a_cluster_domain() {
        let err = parse(&["--kyma-enable-apirule"]).validate().unwrap_err();
        assert!(err.contains("--kyma-cluster-domain"), "{err}");
        assert!(parse(&[
            "--kyma-enable-apirule",
            "--kyma-cluster-domain",
            "example.org"
        ])
        .validate()
        .is_ok());
    }

    #[test]
    fn psa_level_must_be_a_pod_security_level() {
        for ok in ["", "privileged", "baseline", "restricted"] {
            assert!(
                parse(&["--kyma-workspace-psa-level", ok])
                    .validate()
                    .is_ok(),
                "{ok}"
            );
        }
        let err = parse(&["--kyma-workspace-psa-level", "strict"])
            .validate()
            .unwrap_err();
        assert!(err.contains("strict"), "{err}");
    }
}
