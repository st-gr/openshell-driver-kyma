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
