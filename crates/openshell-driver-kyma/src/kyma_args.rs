// SPDX-License-Identifier: Apache-2.0

//! Kyma-layer options. Every flag starts with `--kyma-` and every environment
//! variable with `OPENSHELL_KYMA_`, so they can never collide with upstream's.

use openshell_core::sandbox_env::LOG_LEVEL;

use crate::enrich::{EnrichConfig, CLAUDE_TELEMETRY_ENV};

/// Environment names with this prefix belong to OpenShell; upstream drops them
/// from the sandbox environment except [`LOG_LEVEL`].
const RESERVED_ENV_PREFIX: &str = "OPENSHELL_";

/// Kyma options, flattened next to [`crate::upstream_args::UpstreamArgs`].
#[derive(clap::Args, Debug, Clone)]
pub struct KymaArgs {
    /// Let Istio inject a sidecar into sandbox workloads (label value "true").
    #[arg(long, env = "OPENSHELL_KYMA_ISTIO_INJECT_SANDBOXES")]
    pub kyma_istio_inject_sandboxes: bool,

    /// Add CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 to every sandbox.
    #[arg(long, env = "OPENSHELL_KYMA_DISABLE_CLAUDE_TELEMETRY")]
    pub kyma_disable_claude_telemetry: bool,

    /// KEY=VALUE added to every sandbox's environment. Repeatable. Both the
    /// flag and the environment variable split on commas (`A=1,B=2`), so a
    /// value cannot contain one; set such a variable per sandbox through the
    /// caller's template environment. `OPENSHELL_*` keys other than
    /// `OPENSHELL_LOG_LEVEL` are rejected because upstream strips them. On
    /// duplicate keys the first wins, and an explicit entry beats
    /// --kyma-disable-claude-telemetry.
    #[arg(long, env = "OPENSHELL_KYMA_SANDBOX_ENV", value_delimiter = ',')]
    pub kyma_sandbox_env: Vec<String>,

    /// Expose each sandbox's port 8080 through a Kyma APIRule.
    #[arg(long, env = "OPENSHELL_KYMA_ENABLE_APIRULE")]
    pub kyma_enable_apirule: bool,

    /// Domain for APIRule hosts (`<workspace>--<name>.<domain>`). Required with
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
        self.sandbox_env()?;
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

    /// Hook 1's configuration.
    ///
    /// # Panics
    ///
    /// If an `--kyma-sandbox-env` entry is invalid. Call it only after
    /// [`KymaArgs::validate`] succeeded.
    pub fn enrich_config(&self) -> EnrichConfig {
        let mut environment = self
            .sandbox_env()
            .expect("validate() must succeed before enrich_config()");
        if self.kyma_disable_claude_telemetry {
            environment.push((CLAUDE_TELEMETRY_ENV.to_string(), "1".to_string()));
        }
        EnrichConfig {
            istio_inject: self.kyma_istio_inject_sandboxes,
            environment,
        }
    }

    /// The `--kyma-sandbox-env` entries as pairs. The one parser behind both
    /// [`KymaArgs::validate`] and [`KymaArgs::enrich_config`], so they cannot
    /// disagree about what a valid entry is.
    fn sandbox_env(&self) -> Result<Vec<(String, String)>, String> {
        self.kyma_sandbox_env
            .iter()
            .map(|entry| {
                let (key, value) = entry
                    .split_once('=')
                    .filter(|(key, _)| !key.is_empty())
                    .ok_or_else(|| {
                        format!(
                            "--kyma-sandbox-env entry `{entry}` must be KEY=VALUE with a non-empty KEY"
                        )
                    })?;
                if key.starts_with(RESERVED_ENV_PREFIX) && key != LOG_LEVEL {
                    return Err(format!(
                        "--kyma-sandbox-env entry `{entry}` uses a reserved {RESERVED_ENV_PREFIX}* \
                         key: upstream strips it from the sandbox environment (only {LOG_LEVEL} is kept)"
                    ));
                }
                Ok((key.to_string(), value.to_string()))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enrich::enrich;
    use clap::Parser;
    use openshell_core::proto::compute::v1::DriverSandbox;
    use std::sync::{Mutex, MutexGuard, PoisonError};

    #[derive(Parser)]
    struct Probe {
        #[command(flatten)]
        kyma: KymaArgs,
    }

    /// clap reads OPENSHELL_KYMA_* from the process environment, which the
    /// tests share: every parse here holds this lock, so a test that sets one
    /// cannot leak it into another's parse.
    static ENV: Mutex<()> = Mutex::new(());

    fn env_lock() -> MutexGuard<'static, ()> {
        ENV.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn parse_locked(argv: &[&str]) -> KymaArgs {
        let mut full = vec!["openshell-driver-kyma"];
        full.extend_from_slice(argv);
        Probe::try_parse_from(full)
            .expect("arguments should parse")
            .kyma
    }

    fn parse(argv: &[&str]) -> KymaArgs {
        let _env = env_lock();
        parse_locked(argv)
    }

    /// Sets one environment variable while alive, under the lock, and removes it
    /// on drop, even when the test fails.
    struct EnvVar {
        name: &'static str,
        _lock: MutexGuard<'static, ()>,
    }

    impl EnvVar {
        fn set(name: &'static str, value: &str) -> Self {
            let lock = env_lock();
            std::env::set_var(name, value);
            Self { name, _lock: lock }
        }
    }

    impl Drop for EnvVar {
        fn drop(&mut self) {
            std::env::remove_var(self.name);
        }
    }

    // The chart passes the list through the environment variable, not the
    // flag: clap must split the variable on commas too.
    #[test]
    fn sandbox_env_variable_splits_on_commas() {
        let _var = EnvVar::set("OPENSHELL_KYMA_SANDBOX_ENV", "A=1,B=x=y");
        let args = parse_locked(&[]);
        assert!(args.validate().is_ok());
        assert_eq!(
            args.enrich_config().environment,
            vec![
                ("A".to_string(), "1".to_string()),
                ("B".to_string(), "x=y".to_string())
            ]
        );
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
    fn reserved_openshell_keys_are_rejected_except_log_level() {
        let err = parse(&["--kyma-sandbox-env", "OPENSHELL_FOO=bar"])
            .validate()
            .unwrap_err();
        assert!(
            err.contains("OPENSHELL_FOO=bar"),
            "must name the entry: {err}"
        );
        assert!(err.contains("upstream strips"), "must say why: {err}");

        let args = parse(&["--kyma-sandbox-env", "OPENSHELL_LOG_LEVEL=debug"]);
        assert!(args.validate().is_ok());
        assert_eq!(
            args.enrich_config().environment,
            vec![("OPENSHELL_LOG_LEVEL".to_string(), "debug".to_string())]
        );
    }

    // Both the flag and the environment variable split on commas; the Helm
    // chart relies on it to pass a list through OPENSHELL_KYMA_SANDBOX_ENV.
    #[test]
    fn sandbox_env_splits_on_commas() {
        let args = parse(&["--kyma-sandbox-env", "A=1,B=2"]);
        assert!(args.validate().is_ok());
        assert_eq!(
            args.enrich_config().environment,
            vec![
                ("A".to_string(), "1".to_string()),
                ("B".to_string(), "2".to_string())
            ]
        );
    }

    #[test]
    fn first_duplicate_wins_and_explicit_entry_beats_the_telemetry_flag() {
        let explicit_telemetry = format!("{CLAUDE_TELEMETRY_ENV}=0");
        let args = parse(&[
            "--kyma-disable-claude-telemetry",
            "--kyma-sandbox-env",
            "A=first",
            "--kyma-sandbox-env",
            "A=second",
            "--kyma-sandbox-env",
            explicit_telemetry.as_str(),
        ]);
        let mut sandbox = DriverSandbox::default();
        enrich(&mut sandbox, &args.enrich_config());
        let environment = sandbox.spec.unwrap().template.unwrap().environment;
        assert_eq!(environment["A"], "first");
        assert_eq!(environment[CLAUDE_TELEMETRY_ENV], "0");
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
