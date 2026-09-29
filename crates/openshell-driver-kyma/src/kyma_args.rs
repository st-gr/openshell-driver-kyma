// SPDX-License-Identifier: Apache-2.0

//! Kyma-layer options. Every flag starts with `--kyma-` and every environment
//! variable with `OPENSHELL_KYMA_`, so they can never collide with upstream's.

/// Kyma options, flattened next to [`crate::upstream_args::UpstreamArgs`].
#[derive(clap::Args, Debug, Clone, Default)]
pub struct KymaArgs {}
