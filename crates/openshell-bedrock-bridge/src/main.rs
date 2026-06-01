//! `openshell-bedrock-bridge` — HTTP translation proxy.
//!
//! Accepts Bedrock-shape POSTs at `/saic-aws-bedrock/model/{id}/invoke[-with-response-stream]`,
//! exchanges a SAP BTP service key for an XSUAA bearer token, forwards the
//! request body to `${SAP_AI_CORE_API_URL}/v2/inference/deployments/{deploymentId}/{subpath}`,
//! and pipes the response body byte-for-byte back. SAP AI Core's deployed
//! Bedrock models emit native `application/vnd.amazon.eventstream` binary
//! framing when asked, so the bridge needs no wire-format translation.
//!
//! See `docs/walkthrough-claude-files.md` and the Helm chart's
//! `bedrockBridge` values block for deployment context.

fn main() {
    println!(
        "openshell-bedrock-bridge {} — TODO: wire HTTP server",
        env!("CARGO_PKG_VERSION")
    );
}
