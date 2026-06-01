//! HTTP translation proxy: Claude Code Anthropic-shape `/v1/messages`
//! → SAP AI Core deployed Anthropic models (Bedrock InvokeModel
//! protocol). See `main.rs` for the entrypoint.

pub mod config;
pub mod error_mapper;
pub mod handlers;
pub mod model_resolver;
pub mod sap_auth;
pub mod translator;

pub use config::{Config, SapServiceKey};
pub use error_mapper::BedrockError;
pub use handlers::{router, AppState};
pub use model_resolver::{resolve, ResolveError};
pub use sap_auth::TokenCache;
pub use translator::{translate, TranslateError, Translated};
