//! HTTP translation proxy: Claude Code Bedrock → SAP AI Core deployed
//! Anthropic models. See `main.rs` for the entrypoint and the crate
//! README for the deployment shape.

pub mod config;
pub mod error_mapper;
pub mod handlers;
pub mod model_resolver;
pub mod sap_auth;

pub use config::{Config, SapServiceKey};
pub use error_mapper::BedrockError;
pub use handlers::{router, AppState};
pub use model_resolver::{resolve, ResolveError};
pub use sap_auth::TokenCache;
