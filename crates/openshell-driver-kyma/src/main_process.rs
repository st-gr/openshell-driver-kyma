//! Driver -> supervisor contract for the sandbox's canonical main process.
//!
//! Faithful reimplementation of `MainProcessConfig` and the
//! `OPENSHELL_MAIN_PROCESS_SPEC` transport from NVIDIA/OpenShell
//! `crates/openshell-core/src/sandbox_env.rs`, at `v0.0.111`
//! (commit `20d2e867e0e25b24d383a78dd362ba5647ef12c8`).
//!
//! Not vendored wholesale under `src/vendor/`, unlike `driver_mounts.rs`.
//! That file also carries the ~20 other supervisor env-var constants we do
//! not set, and a `base64url:` transport that exists only for VM-style
//! drivers whose env plumbing cannot preserve spaces -- adopting it would
//! mean a new `base64` dependency for a code path this driver never takes.
//! Kubernetes preserves spaces in a Pod's env values, so upstream's own
//! Kubernetes driver uses the plain-JSON form, and so do we.
//!
//! The wire format is what actually has to match, and
//! `wire_format_matches_upstream` pins it byte-for-byte.
//!
//! Replaces `OPENSHELL_SANDBOX_COMMAND`, which upstream carried through
//! `v0.0.109` and removed by `v0.0.111`.

use computev1::pb::DriverSandboxSpec;
use serde::{Deserialize, Serialize};

/// Versioned specification for the exact canonical main process.
///
/// Upstream note: "Most drivers use JSON directly. Transports that cannot
/// preserve spaces in environment values may use the `base64url:`-prefixed
/// representation." This driver is in the former group.
pub const MAIN_PROCESS_SPEC: &str = "OPENSHELL_MAIN_PROCESS_SPEC";

/// Lossless driver-to-supervisor representation of the canonical process.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct MainProcessConfig {
    pub version: u32,
    pub command: Vec<String>,
    pub tty: bool,
}

impl MainProcessConfig {
    pub const VERSION: u32 = 1;

    /// Upstream's fallback when no command was requested. The supervisor
    /// applies the identical default when the variable is absent, so this
    /// only matters for keeping what we send explicit.
    #[must_use]
    pub fn scratch() -> Self {
        Self {
            version: Self::VERSION,
            command: vec!["/bin/bash".to_string(), "-l".to_string()],
            tty: true,
        }
    }

    /// An empty `command` means "no command requested" and falls back to
    /// `scratch()`; `tty` is only honoured alongside an explicit command,
    /// matching upstream's guard exactly.
    #[must_use]
    pub fn from_driver_spec(spec: Option<&DriverSandboxSpec>) -> Self {
        match spec {
            Some(spec) if !spec.command.is_empty() => Self {
                version: Self::VERSION,
                command: spec.command.clone(),
                tty: spec.tty,
            },
            None | Some(_) => Self::scratch(),
        }
    }

    /// Encode the versioned driver-to-supervisor transport.
    pub fn encode_driver_spec(
        spec: Option<&DriverSandboxSpec>,
    ) -> Result<String, serde_json::Error> {
        serde_json::to_string(&Self::from_driver_spec(spec))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pins the exact bytes upstream's supervisor parses. Field names,
    /// field order and JSON shape are the contract -- a rename or a
    /// reordering here is a wire break, not a refactor. Compared against
    /// `MainProcessConfig` in openshell-core at v0.0.111.
    #[test]
    fn wire_format_matches_upstream() {
        let spec = DriverSandboxSpec {
            command: vec!["/bin/sh".into(), "-c".into(), "printf '%s' 'a b'".into()],
            tty: false,
            ..Default::default()
        };
        let encoded = MainProcessConfig::encode_driver_spec(Some(&spec)).unwrap();
        assert_eq!(
            encoded,
            r#"{"version":1,"command":["/bin/sh","-c","printf '%s' 'a b'"],"tty":false}"#
        );
    }

    /// Upstream guards on `!spec.command.is_empty()`, so an empty command
    /// falls back to scratch and a `tty` set alongside it is NOT honoured.
    #[test]
    fn empty_command_falls_back_to_scratch_ignoring_tty() {
        let spec = DriverSandboxSpec {
            command: vec![],
            tty: false,
            ..Default::default()
        };
        let cfg = MainProcessConfig::from_driver_spec(Some(&spec));
        assert_eq!(cfg, MainProcessConfig::scratch());
        assert!(
            cfg.tty,
            "scratch keeps tty on even when the spec said false"
        );
    }

    #[test]
    fn absent_spec_falls_back_to_scratch() {
        assert_eq!(
            MainProcessConfig::from_driver_spec(None),
            MainProcessConfig::scratch()
        );
    }
}
