// SPDX-License-Identifier: Apache-2.0

//! The production [`KymaHooks`]: request enrichment now; exposure and
//! namespace labelling join in later tasks.

use openshell_core::proto::compute::v1::DriverSandbox;
use tonic::Status;

use crate::enrich::{enrich, EnrichConfig};
use crate::service::KymaHooks;

pub struct KymaHookSet {
    enrich: EnrichConfig,
}

impl KymaHookSet {
    pub fn new(enrich: EnrichConfig) -> Self {
        Self { enrich }
    }
}

#[tonic::async_trait]
impl KymaHooks for KymaHookSet {
    fn enrich(&self, sandbox: &mut DriverSandbox) {
        enrich(sandbox, &self.enrich);
    }

    async fn after_create(&self, _sandbox: DriverSandbox) {}

    async fn after_ensure_workspace(&self, _workspace: &str) -> Result<(), Status> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enrich::{ISTIO_INJECT_LABEL, KAGENTI_TYPE_LABEL, KAGENTI_TYPE_VALUE};

    #[test]
    fn enrich_hook_applies_the_configured_enrichment() {
        let hooks = KymaHookSet::new(EnrichConfig {
            istio_inject: true,
            environment: vec![("KEY".to_string(), "value".to_string())],
        });
        let mut sandbox = DriverSandbox::default();
        KymaHooks::enrich(&hooks, &mut sandbox);
        let template = sandbox.spec.unwrap().template.unwrap();
        assert_eq!(template.labels[ISTIO_INJECT_LABEL], "true");
        assert_eq!(template.labels[KAGENTI_TYPE_LABEL], KAGENTI_TYPE_VALUE);
        assert_eq!(template.environment["KEY"], "value");
    }
}
