//! `openshell-bedrock-bridge` entrypoint. See `lib.rs` for the public API.

use anyhow::Result;
use openshell_bedrock_bridge::{router, AppState, Config};
use tokio::net::TcpListener;
use tracing_subscriber::{fmt, EnvFilter};

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing();

    let config = Config::from_env()?;
    let bind = format!("{}:{}", config.bind_address, config.port);
    tracing::info!(
        bind = %bind,
        resource_group = %config.resource_group,
        models = ?config.model_map.keys().collect::<Vec<_>>(),
        default_deployment = ?config.default_deployment,
        "openshell-bedrock-bridge starting (POST /v1/messages)"
    );

    let http = reqwest::Client::builder()
        .user_agent(concat!(
            "openshell-bedrock-bridge/",
            env!("CARGO_PKG_VERSION")
        ))
        .build()?;

    let app = router(AppState::new(config, http));
    let listener = TcpListener::bind(&bind).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

fn init_tracing() {
    let filter = EnvFilter::try_from_env("BRIDGE_LOG_LEVEL")
        .or_else(|_| EnvFilter::try_from_default_env())
        .unwrap_or_else(|_| EnvFilter::new("info"));
    fmt().with_env_filter(filter).with_target(false).init();
}
