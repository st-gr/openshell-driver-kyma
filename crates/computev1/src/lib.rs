//! Generated tonic + prost code for the OpenShell ComputeDriver service.
//!
//! The proto schema is vendored from NVIDIA/OpenShell at
//! `proto/compute_driver.proto` (Apache-2.0). All types under `pb::` are
//! emitted by `tonic-prost-build` at compile time and never committed to
//! source control.

#![allow(clippy::all, clippy::pedantic, clippy::nursery, clippy::restriction)]

// `compute_driver.proto` now imports `extension.proto` (PeerMetadata) and
// `sandbox.proto` (SandboxPolicy, which itself imports `datamodel.proto`).
// prost/tonic generate cross-package references as `super::` paths that
// assume a Rust module tree mirroring the protobuf package tree, so these
// have to live in a nested `openshell::{compute,extension,sandbox,datamodel}::v1`
// hierarchy rather than each in its own flat module.
pub mod openshell {
    pub mod compute {
        pub mod v1 {
            tonic::include_proto!("openshell.compute.v1");
        }
    }
    pub mod extension {
        pub mod v1 {
            tonic::include_proto!("openshell.extension.v1");
        }
    }
    pub mod sandbox {
        pub mod v1 {
            tonic::include_proto!("openshell.sandbox.v1");
        }
    }
    pub mod datamodel {
        pub mod v1 {
            tonic::include_proto!("openshell.datamodel.v1");
        }
    }
}

// Flattened re-export so existing call sites can keep writing
// `computev1::pb::DriverSandbox` / `computev1::pb::PeerMetadata` without
// caring which upstream .proto package a type came from. None of the four
// vendored files declare colliding message names.
pub mod pb {
    pub use crate::openshell::compute::v1::*;
    pub use crate::openshell::datamodel::v1::*;
    pub use crate::openshell::extension::v1::*;
    pub use crate::openshell::sandbox::v1::*;
}

pub use pb::compute_driver_client;
pub use pb::compute_driver_server;
