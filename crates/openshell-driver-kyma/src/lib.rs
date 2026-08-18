//! openshell-driver-kyma — Rust port of the OpenShell ComputeDriver gRPC
//! service for SAP BTP Kyma clusters.
//!
//! Module layout mirrors the reference Go OpenShift driver. Each module is
//! documented inline; see `docs/superpowers/specs/` and `docs/superpowers/plans/`
//! for the design rationale and implementation order.

pub mod config;
pub mod driver;
pub mod enricher;
pub mod error;
pub mod helpers;
pub mod interfaces;
pub mod lifecycle;
pub mod metrics;
pub mod provisioner;
pub mod workspace;
