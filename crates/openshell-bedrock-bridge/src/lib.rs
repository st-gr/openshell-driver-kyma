//! HTTP translation proxy: Claude Code Bedrock → SAP AI Core deployed
//! Anthropic models. See `main.rs` for the entrypoint and the crate
//! README for the deployment shape.

pub mod config;
pub mod model_resolver;
pub mod sap_auth;

pub use config::{Config, SapServiceKey};
pub use model_resolver::{resolve, ResolveError};
pub use sap_auth::TokenCache;
