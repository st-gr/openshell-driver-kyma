//! Bridge runtime configuration.
//!
//! Three credential sources, in precedence order (highest first):
//! 1. `SAP_AI_CORE_SERVICE_KEY_FILE=<path>` — read + parse the JSON.
//!    This is the chart's path; the Helm chart mounts a Secret as a
//!    file at `/etc/sap-aicore/service-key.json`.
//! 2. `SAP_AI_CORE_SERVICE_KEY_JSON=<raw json>` — same JSON shape, in
//!    a single env var. Useful for `cargo run` testing.
//! 3. Individual env vars: `SAP_AI_CORE_CLIENT_ID`,
//!    `SAP_AI_CORE_CLIENT_SECRET`, `SAP_AI_CORE_TOKEN_URL`,
//!    `SAP_AI_CORE_API_URL`. Fallback for the prompt's original env-only
//!    shape.
//!
//! Whichever source provides ALL four required fields wins. The bridge
//! refuses to start if no source is complete; the error names which
//! field was missing and which source was tried.

use anyhow::{anyhow, bail, Context, Result};
use serde::Deserialize;
use std::collections::HashMap;
use std::env;
use std::path::Path;

/// Parsed SAP BTP service key (relevant subset).
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct SapServiceKey {
    pub clientid: String,
    pub clientsecret: String,
    pub url: String,
    pub serviceurls: ServiceUrls,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct ServiceUrls {
    #[serde(rename = "AI_API_URL")]
    pub ai_api_url: String,
}

/// Bridge runtime configuration.
#[derive(Debug, Clone)]
pub struct Config {
    pub bind_address: String,
    pub port: u16,
    /// URL prefix the bridge mounts its routes under (e.g. `/saic-aws-bedrock`).
    /// Stripped before path-mapping into SAP's `/v2/inference/...` shape.
    pub path_prefix: String,
    pub resource_group: String,
    pub sap_key: SapServiceKey,
    /// Bedrock-id → SAP-deployment-id. Empty when only `default_deployment`
    /// is set.
    pub model_map: HashMap<String, String>,
    /// Single-deployment override; consulted only when `model_map` lookup
    /// misses.
    pub default_deployment: Option<String>,
    pub log_level: String,
}

impl Config {
    /// Build a `Config` from process environment variables.
    pub fn from_env() -> Result<Self> {
        let sap_key = load_sap_key()?;

        let bind_address = env::var("BIND_ADDRESS").unwrap_or_else(|_| "0.0.0.0".to_string());
        let port = env::var("PORT")
            .ok()
            .map(|s| s.parse::<u16>().context("PORT must be a u16"))
            .transpose()?
            .unwrap_or(8787);
        let path_prefix =
            env::var("BRIDGE_PATH_PREFIX").unwrap_or_else(|_| "/saic-aws-bedrock".to_string());
        let resource_group =
            env::var("SAP_AI_CORE_RESOURCE_GROUP").unwrap_or_else(|_| "default".to_string());
        let log_level = env::var("BRIDGE_LOG_LEVEL").unwrap_or_else(|_| "info".to_string());

        let model_map = match env::var("MODEL_MAP_JSON").ok() {
            Some(s) if !s.is_empty() => serde_json::from_str::<HashMap<String, String>>(&s)
                .context(
                    "MODEL_MAP_JSON is not a valid JSON object of <bedrock-id>:<deployment-id>",
                )?,
            _ => HashMap::new(),
        };
        let default_deployment = env::var("SAP_DEPLOYMENT_ID").ok().filter(|s| !s.is_empty());

        if model_map.is_empty() && default_deployment.is_none() {
            bail!(
                "no model routing configured: set either MODEL_MAP_JSON \
                 (object of bedrock-id -> deployment-id) or SAP_DEPLOYMENT_ID"
            );
        }

        Ok(Self {
            bind_address,
            port,
            path_prefix,
            resource_group,
            sap_key,
            model_map,
            default_deployment,
            log_level,
        })
    }
}

fn load_sap_key() -> Result<SapServiceKey> {
    if let Some(path) = env::var_os("SAP_AI_CORE_SERVICE_KEY_FILE") {
        let path = Path::new(&path).to_owned();
        let bytes = std::fs::read(&path).with_context(|| {
            format!(
                "SAP_AI_CORE_SERVICE_KEY_FILE points at {} but the file is unreadable",
                path.display()
            )
        })?;
        let key: SapServiceKey = serde_json::from_slice(&bytes).with_context(|| {
            format!(
                "SAP_AI_CORE_SERVICE_KEY_FILE ({}) is not a valid SAP BTP service-key JSON \
                 (need clientid, clientsecret, url, serviceurls.AI_API_URL)",
                path.display()
            )
        })?;
        return Ok(key);
    }

    if let Ok(s) = env::var("SAP_AI_CORE_SERVICE_KEY_JSON") {
        if !s.is_empty() {
            let key: SapServiceKey = serde_json::from_str(&s).context(
                "SAP_AI_CORE_SERVICE_KEY_JSON is not a valid SAP BTP service-key JSON \
                 (need clientid, clientsecret, url, serviceurls.AI_API_URL)",
            )?;
            return Ok(key);
        }
    }

    // Fallback: assemble from individual env vars.
    let pull = |name: &str, source_label: &str| -> Result<String> {
        env::var(name)
            .with_context(|| format!("missing {name} (source: {source_label})"))
            .and_then(|v| {
                if v.is_empty() {
                    Err(anyhow!("{name} is empty (source: {source_label})"))
                } else {
                    Ok(v)
                }
            })
    };
    let label = "individual env vars (fallback after \
                 SAP_AI_CORE_SERVICE_KEY_FILE and SAP_AI_CORE_SERVICE_KEY_JSON)";
    Ok(SapServiceKey {
        clientid: pull("SAP_AI_CORE_CLIENT_ID", label)?,
        clientsecret: pull("SAP_AI_CORE_CLIENT_SECRET", label)?,
        url: pull("SAP_AI_CORE_TOKEN_URL", label)?,
        serviceurls: ServiceUrls {
            ai_api_url: pull("SAP_AI_CORE_API_URL", label)?,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    /// Serialize tests in this module — they all mutate process env.
    fn env_lock() -> &'static Mutex<()> {
        static L: OnceLock<Mutex<()>> = OnceLock::new();
        L.get_or_init(|| Mutex::new(()))
    }

    fn clear_sap_env() {
        for var in [
            "SAP_AI_CORE_SERVICE_KEY_FILE",
            "SAP_AI_CORE_SERVICE_KEY_JSON",
            "SAP_AI_CORE_CLIENT_ID",
            "SAP_AI_CORE_CLIENT_SECRET",
            "SAP_AI_CORE_TOKEN_URL",
            "SAP_AI_CORE_API_URL",
            "SAP_AI_CORE_RESOURCE_GROUP",
            "SAP_DEPLOYMENT_ID",
            "MODEL_MAP_JSON",
            "BRIDGE_PATH_PREFIX",
            "BRIDGE_LOG_LEVEL",
            "PORT",
            "BIND_ADDRESS",
        ] {
            env::remove_var(var);
        }
    }

    fn sample_key_json() -> &'static str {
        r#"{
          "clientid": "sb-test-client",
          "clientsecret": "test-secret",
          "url": "https://test-tenant.authentication.eu10.hana.ondemand.com",
          "serviceurls": {
            "AI_API_URL": "https://api.ai.eu10.hana.ondemand.com"
          }
        }"#
    }

    #[test]
    fn loads_from_file_path() {
        let _g = env_lock().lock().unwrap_or_else(|e| e.into_inner());
        clear_sap_env();
        let f = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(f.path(), sample_key_json()).unwrap();
        env::set_var("SAP_AI_CORE_SERVICE_KEY_FILE", f.path());
        env::set_var("SAP_DEPLOYMENT_ID", "dummy-dep-id");

        let cfg = Config::from_env().expect("config builds");
        assert_eq!(cfg.sap_key.clientid, "sb-test-client");
        assert_eq!(cfg.sap_key.clientsecret, "test-secret");
        assert_eq!(
            cfg.sap_key.serviceurls.ai_api_url,
            "https://api.ai.eu10.hana.ondemand.com"
        );
    }

    #[test]
    fn loads_from_json_env_when_no_file() {
        let _g = env_lock().lock().unwrap_or_else(|e| e.into_inner());
        clear_sap_env();
        env::set_var("SAP_AI_CORE_SERVICE_KEY_JSON", sample_key_json());
        env::set_var("SAP_DEPLOYMENT_ID", "dummy-dep-id");

        let cfg = Config::from_env().expect("config builds");
        assert_eq!(cfg.sap_key.clientid, "sb-test-client");
    }

    #[test]
    fn file_path_wins_over_json_env() {
        let _g = env_lock().lock().unwrap_or_else(|e| e.into_inner());
        clear_sap_env();
        let f = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(f.path(), sample_key_json()).unwrap();
        env::set_var("SAP_AI_CORE_SERVICE_KEY_FILE", f.path());

        // A *different* clientid in the JSON env. The file should win.
        env::set_var(
            "SAP_AI_CORE_SERVICE_KEY_JSON",
            r#"{"clientid":"OVERRIDDEN","clientsecret":"x","url":"https://a","serviceurls":{"AI_API_URL":"https://b"}}"#,
        );
        env::set_var("SAP_DEPLOYMENT_ID", "dummy-dep-id");

        let cfg = Config::from_env().expect("config builds");
        assert_eq!(cfg.sap_key.clientid, "sb-test-client");
    }

    #[test]
    fn json_env_wins_over_individual_vars() {
        let _g = env_lock().lock().unwrap_or_else(|e| e.into_inner());
        clear_sap_env();
        env::set_var("SAP_AI_CORE_SERVICE_KEY_JSON", sample_key_json());
        env::set_var("SAP_AI_CORE_CLIENT_ID", "OVERRIDDEN");
        env::set_var("SAP_AI_CORE_CLIENT_SECRET", "OVERRIDDEN");
        env::set_var("SAP_AI_CORE_TOKEN_URL", "https://overridden.example");
        env::set_var("SAP_AI_CORE_API_URL", "https://overridden.example");
        env::set_var("SAP_DEPLOYMENT_ID", "dummy-dep-id");

        let cfg = Config::from_env().expect("config builds");
        assert_eq!(cfg.sap_key.clientid, "sb-test-client");
    }

    #[test]
    fn falls_back_to_individual_vars() {
        let _g = env_lock().lock().unwrap_or_else(|e| e.into_inner());
        clear_sap_env();
        env::set_var("SAP_AI_CORE_CLIENT_ID", "id-from-env");
        env::set_var("SAP_AI_CORE_CLIENT_SECRET", "secret-from-env");
        env::set_var(
            "SAP_AI_CORE_TOKEN_URL",
            "https://test.authentication.eu10.hana.ondemand.com",
        );
        env::set_var(
            "SAP_AI_CORE_API_URL",
            "https://api.ai.eu10.hana.ondemand.com",
        );
        env::set_var("SAP_DEPLOYMENT_ID", "dummy-dep-id");

        let cfg = Config::from_env().expect("config builds");
        assert_eq!(cfg.sap_key.clientid, "id-from-env");
        assert_eq!(cfg.sap_key.clientsecret, "secret-from-env");
    }

    #[test]
    fn missing_field_in_individual_vars_names_field_and_source() {
        let _g = env_lock().lock().unwrap_or_else(|e| e.into_inner());
        clear_sap_env();
        env::set_var("SAP_AI_CORE_CLIENT_ID", "id-from-env");
        // CLIENT_SECRET intentionally missing.
        env::set_var(
            "SAP_AI_CORE_TOKEN_URL",
            "https://test.authentication.eu10.hana.ondemand.com",
        );
        env::set_var(
            "SAP_AI_CORE_API_URL",
            "https://api.ai.eu10.hana.ondemand.com",
        );
        env::set_var("SAP_DEPLOYMENT_ID", "dummy-dep-id");

        let err = Config::from_env().unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("SAP_AI_CORE_CLIENT_SECRET"),
            "error should name the missing field: {msg}"
        );
        assert!(
            msg.contains("individual env vars"),
            "error should name the source it tried: {msg}"
        );
    }

    #[test]
    fn refuses_when_no_routing_configured() {
        let _g = env_lock().lock().unwrap_or_else(|e| e.into_inner());
        clear_sap_env();
        env::set_var("SAP_AI_CORE_SERVICE_KEY_JSON", sample_key_json());
        // Neither MODEL_MAP_JSON nor SAP_DEPLOYMENT_ID set.

        let err = Config::from_env().unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("MODEL_MAP_JSON") && msg.contains("SAP_DEPLOYMENT_ID"),
            "error should mention both routing options: {msg}"
        );
    }

    #[test]
    fn parses_model_map_json() {
        let _g = env_lock().lock().unwrap_or_else(|e| e.into_inner());
        clear_sap_env();
        env::set_var("SAP_AI_CORE_SERVICE_KEY_JSON", sample_key_json());
        env::set_var(
            "MODEL_MAP_JSON",
            r#"{"claude-opus-4.7":"d-opus","claude-haiku-4.5":"d-haiku"}"#,
        );

        let cfg = Config::from_env().expect("config builds");
        assert_eq!(
            cfg.model_map.get("claude-opus-4.7").map(String::as_str),
            Some("d-opus")
        );
        assert_eq!(
            cfg.model_map.get("claude-haiku-4.5").map(String::as_str),
            Some("d-haiku")
        );
        assert!(cfg.default_deployment.is_none());
    }

    #[test]
    fn defaults_for_optional_fields() {
        let _g = env_lock().lock().unwrap_or_else(|e| e.into_inner());
        clear_sap_env();
        env::set_var("SAP_AI_CORE_SERVICE_KEY_JSON", sample_key_json());
        env::set_var("SAP_DEPLOYMENT_ID", "dummy-dep-id");

        let cfg = Config::from_env().expect("config builds");
        assert_eq!(cfg.bind_address, "0.0.0.0");
        assert_eq!(cfg.port, 8787);
        assert_eq!(cfg.path_prefix, "/saic-aws-bedrock");
        assert_eq!(cfg.resource_group, "default");
        assert_eq!(cfg.log_level, "info");
    }
}
