# Upstream PR: add `aws-bedrock` as a recognized inference provider

**Target:** `NVIDIA/OpenShell` `main` branch.
**Source branch:** [`st-gr/OpenShell:feat/aws-bedrock-provider`](https://github.com/st-gr/OpenShell/tree/feat/aws-bedrock-provider).
**Status:** Branch pushed. PR not yet opened.

## Problem statement

The OpenShell supervisor's L7 router intercepts traffic to `inference.local`
in sandbox pods and routes it to operator-configured upstream providers.
Today the router recognizes URL patterns for OpenAI, Anthropic
Messages, and model discovery — but not the AWS Bedrock InvokeModel
shape (`POST /model/{id}/invoke[-with-response-stream]`).

That means a sandbox running Claude Code in its native Bedrock mode
(`CLAUDE_CODE_USE_BEDROCK=1`) emits requests the supervisor refuses
with `403 "connection not allowed by policy"`. Operators who want
Claude Code talking to a Bedrock-shaped upstream — direct AWS
Bedrock, an in-cluster Bedrock-compatible bridge, or LiteLLM in
Bedrock-emulation mode — currently have no way to do it through the
supervisor's L7 router. They have to bypass `inference.local` and dial
the upstream directly, which loses the router's rate-limit, audit, and
secret-substitution machinery.

This PR adds `aws-bedrock` as a first-class inference protocol so
those operators can register an upstream as `--type aws-bedrock` and
have the supervisor route InvokeModel traffic the same way it routes
OpenAI/Anthropic traffic today.

## What this PR ships

Two commits on top of `upstream/main`:

1. **`feat(sandbox): allow AWS Bedrock InvokeModel paths through the L7 router`** — adds
   `POST /model/*/invoke` and `POST /model/*/invoke-with-response-stream` to
   `default_patterns()` in `crates/openshell-sandbox/src/l7/inference.rs`. To
   support the wildcard model id, `detect_inference_pattern` is extended with
   a middle-`/*/` glob form (in addition to the existing trailing `/*`). The
   wildcard segment is constrained to a single non-empty path component, so
   `/model//invoke` and `/model/a/b/invoke` both no-match — preventing path
   traversal. Seven new tests cover the positive path, query-string handling,
   GET rejection, empty-segment rejection, multi-segment rejection, and
   unknown-action rejection.

2. **`feat(providers): add aws-bedrock provider profile + discovery spec`** — adds:
   - `providers/aws-bedrock.yaml`: YAML profile declaring four credentials
     (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN,
     AWS_REGION). Default endpoint targets `bedrock-runtime.us-east-1.amazonaws.com:443`.
   - `crates/openshell-providers/src/providers/aws_bedrock.rs`:
     `ProviderDiscoverySpec` so `--auto-providers` picks up AWS_* env vars.
   - Registration in `crates/openshell-providers/src/providers/mod.rs`,
     `crates/openshell-providers/src/lib.rs`, and the
     `BUILT_IN_PROFILE_YAMLS` array in `crates/openshell-providers/src/profiles.rs`.

## Test results (in-tree)

```
cargo test -p openshell-providers
test result: ok. 35 passed; 0 failed
cargo test -p openshell-sandbox --lib l7::inference
test result: ok. 40 passed; 0 failed
cargo clippy --no-deps -p openshell-providers --all-targets -- -D warnings
clean
cargo clippy --no-deps -p openshell-sandbox --all-targets -- -D warnings
clean
```

## What this PR explicitly does NOT include

These are deliberately separated as follow-ups so this PR stays small
and reviewable. None of them block the use case (an operator running a
Bedrock-compatible bridge or upstream that accepts Bedrock-shape
requests at `/model/{id}/invoke[-with-response-stream]`).

- **SigV4 signer in `openshell-router`.** The `aws-bedrock` profile
  doesn't yet declare an `auth_style: sigv4` because today's profile
  validator doesn't know that style. A follow-up PR adds the
  validator branch + an outbound SigV4 signer using the `aws-sigv4`
  crate. Operators whose upstream doesn't need SigV4 (e.g. an
  in-cluster bridge that authenticates separately to AWS or to a
  non-AWS backend) can use this PR as-is — the bridge handles auth
  on its side.
- **`BEDROCK_BASE_URL` config-key + `{region}` placeholder
  substitution.** The YAML's `host` is a literal default
  (`bedrock-runtime.us-east-1.amazonaws.com`). Operators in other
  regions or pointing at non-AWS Bedrock-compatible upstreams can
  override per-deployment via an operator-supplied
  `BEDROCK_BASE_URL` config-key, mirroring how the `anthropic`
  provider accepts `ANTHROPIC_BASE_URL`. Adding placeholder
  substitution to the YAML loader is a separate small infra change.
- **Body translation** between Bedrock InvokeModel shape and other
  inference shapes. The router treats matched requests as opaque
  pass-through; if the operator's upstream is real AWS Bedrock it
  speaks Bedrock natively, if it's a translating bridge the bridge
  does any conversion server-side.
- **CLI / TUI surface updates** (e.g. adding `aws-bedrock` to the
  TUI's provider-type picker). Operators can already create the
  provider via `openshell provider create --type aws-bedrock`
  because the registry recognizes the new id.

## Operator context (why we want this)

We're shipping an in-cluster SAP AI Core ↔ Bedrock translation bridge
in `st-gr/openshell-driver-kyma`. SAP exposes Anthropic models behind
the Bedrock InvokeModel schema with XSUAA bearer auth (no SigV4).
Without this PR our bridge has to do its own protocol translation and
register as `--type anthropic` at `/v1/messages` on the inside, which
means it carries an Anthropic→Bedrock body translator and a
field-denylist for Anthropic-API-only fields the SAP gateway rejects
(e.g. `context_management`, `mcp_servers`). With this PR the bridge
becomes a path-translating + auth-substituting pass-through (no body
work), and operators using direct AWS Bedrock or a different
Bedrock-compatible proxy benefit from the same plumbing.

## How to file the PR

```bash
gh pr create \
  --repo NVIDIA/OpenShell \
  --base main \
  --head st-gr:feat/aws-bedrock-provider \
  --title "feat(sandbox,providers): add aws-bedrock as a recognized inference provider" \
  --body "$(...)"
```

PR-body content can be assembled from the "Problem statement", "What
this PR ships", and "Operator context" sections of this file.
