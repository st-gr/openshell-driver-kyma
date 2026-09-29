// SPDX-License-Identifier: Apache-2.0

//! OpenShell compute driver for SAP BTP Kyma.
//!
//! Upstream NVIDIA OpenShell's Kubernetes driver does all the compute work;
//! this crate mirrors its option surface and wraps its gRPC service with a
//! small Kyma layer. See `docs/superpowers/specs/2026-09-29-upstream-driver-parity-design.md`.

pub mod enrich;
pub mod exposure;
pub mod health;
pub mod hooks;
pub mod kyma_args;
pub mod service;
#[cfg(test)]
pub(crate) mod test_support;
pub mod upstream_args;
