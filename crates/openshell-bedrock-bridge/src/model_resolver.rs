//! Model-id → SAP deployment-id lookup.
//!
//! Pure resolver. The bridge accepts arbitrary string keys per the
//! prompt's spec — no allowlist, no shape validation — because Claude
//! Code passes whatever the operator put in `ANTHROPIC_MODEL` etc.
//! verbatim. The proxy's job is just to look it up.

use std::collections::HashMap;

/// Resolve a Bedrock-style model id to a SAP AI Core deployment id.
///
/// `map` is the operator-supplied `MODEL_MAP_JSON` table. `default_dep`
/// is the optional `SAP_DEPLOYMENT_ID` fallback applied to every miss.
pub fn resolve<'a>(
    model_id: &str,
    map: &'a HashMap<String, String>,
    default_dep: Option<&'a str>,
) -> Result<&'a str, ResolveError> {
    if let Some(found) = map.get(model_id) {
        return Ok(found.as_str());
    }
    if let Some(d) = default_dep {
        return Ok(d);
    }
    Err(ResolveError::NotFound(model_id.to_string()))
}

#[derive(Debug, thiserror::Error)]
pub enum ResolveError {
    #[error("Unknown model id {0}")]
    NotFound(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map_of(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn map_hit_returns_deployment_id() {
        let m = map_of(&[("claude-opus-4.7", "d-opus")]);
        assert_eq!(resolve("claude-opus-4.7", &m, None).unwrap(), "d-opus");
    }

    #[test]
    fn map_miss_falls_back_to_default() {
        let m = HashMap::new();
        assert_eq!(
            resolve("anything", &m, Some("d-fallback")).unwrap(),
            "d-fallback"
        );
    }

    #[test]
    fn map_miss_without_default_errors() {
        let m = HashMap::new();
        let err = resolve("anything", &m, None).unwrap_err();
        assert!(format!("{err}").contains("anything"));
    }

    #[test]
    fn arbitrary_string_keys_accepted() {
        // The prompt explicitly says no allowlist; operator-chosen names
        // (Bedrock ids, friendly names, gibberish) all work as keys.
        let m = map_of(&[
            ("claude-opus-4.7", "d-friendly-opus"),
            (
                "us.anthropic.claude-haiku-4-5-20251001-v1:0",
                "d-bedrock-haiku",
            ),
            ("my-team-default-model", "d-team"),
        ]);
        assert_eq!(
            resolve("claude-opus-4.7", &m, None).unwrap(),
            "d-friendly-opus"
        );
        assert_eq!(
            resolve("us.anthropic.claude-haiku-4-5-20251001-v1:0", &m, None).unwrap(),
            "d-bedrock-haiku"
        );
        assert_eq!(
            resolve("my-team-default-model", &m, None).unwrap(),
            "d-team"
        );
    }

    #[test]
    fn map_takes_precedence_over_default() {
        let m = map_of(&[("specific", "d-specific")]);
        assert_eq!(
            resolve("specific", &m, Some("d-fallback")).unwrap(),
            "d-specific"
        );
    }

    #[test]
    fn unknown_id_with_only_default_uses_default() {
        let m = map_of(&[("x", "d-x")]);
        assert_eq!(
            resolve("not-x", &m, Some("d-fallback")).unwrap(),
            "d-fallback"
        );
    }
}
