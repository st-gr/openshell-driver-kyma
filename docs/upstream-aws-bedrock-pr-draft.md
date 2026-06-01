# Upstream PR draft: add `aws-bedrock` as a recognized inference provider

**Target:** `NVIDIA/OpenShell` `main` branch.
**Status:** Draft / not yet filed. Maintained here as a reference for future work.

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

## Concrete change set

### 1. `crates/openshell-sandbox/src/l7/inference.rs` — extend `default_patterns()`

Add two new patterns:

```rust
InferenceApiPattern {
    method: "POST".to_string(),
    path_glob: "/model/*/invoke".to_string(),
    protocol: "aws_bedrock_invoke".to_string(),
    kind: "messages".to_string(),
},
InferenceApiPattern {
    method: "POST".to_string(),
    path_glob: "/model/*/invoke-with-response-stream".to_string(),
    protocol: "aws_bedrock_invoke_stream".to_string(),
    kind: "messages".to_string(),
},
```

The current `detect_inference_pattern` glob matcher only supports a
trailing `/*` suffix. These patterns have the `*` in the middle. The
matcher needs to be extended to handle one (and only one) middle
`/*/` segment, treating the segment as an opaque bedrock model id.

```rust
pub fn detect_inference_pattern<'a>(
    method: &str,
    path: &str,
    patterns: &'a [InferenceApiPattern],
) -> Option<&'a InferenceApiPattern> {
    let path_only = path.split('?').next().unwrap_or(path);
    patterns.iter().find(|p| {
        if !method.eq_ignore_ascii_case(&p.method) {
            return false;
        }
        match_glob(&p.path_glob, path_only)
    })
}

fn match_glob(glob: &str, path: &str) -> bool {
    // Trailing wildcard: existing behavior.
    if let Some(prefix) = glob.strip_suffix("/*") {
        return path == prefix
            || path
                .strip_prefix(prefix)
                .is_some_and(|s| s.starts_with('/'));
    }
    // Middle wildcard: split once on "/*/", require both sides to anchor.
    if let Some((before, after)) = glob.split_once("/*/") {
        let Some(rest) = path.strip_prefix(before) else {
            return false;
        };
        let Some(rest) = rest.strip_prefix('/') else {
            return false;
        };
        // Match exactly one path segment (no further '/'), then suffix.
        let Some(slash_at) = rest.find('/') else {
            return false;
        };
        return rest[slash_at..] == format!("/{}", after.trim_start_matches('/'));
    }
    // Exact match.
    path == glob
}
```

Add unit tests for `/model/<id>/invoke` paths matching, `/model//invoke`
not matching (empty segment), `/model/foo/bar/invoke` not matching
(multi-segment), and query-string stripping.

### 2. `providers/aws-bedrock.yaml` — new provider profile

```yaml
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

id: aws-bedrock
display_name: AWS Bedrock
description: Anthropic + Mistral + Llama models served via the AWS Bedrock InvokeModel API
category: inference
inference_capable: true
credentials:
  - name: aws_access_key_id
    description: AWS access key id used for SigV4 signing
    env_vars: [AWS_ACCESS_KEY_ID]
    required: true
    auth_style: sigv4
  - name: aws_secret_access_key
    description: AWS secret access key used for SigV4 signing
    env_vars: [AWS_SECRET_ACCESS_KEY]
    required: true
    auth_style: sigv4
  - name: aws_session_token
    description: Optional session token for temporary credentials (STS, IAM Roles)
    env_vars: [AWS_SESSION_TOKEN]
    required: false
    auth_style: sigv4
  - name: aws_region
    description: AWS region the Bedrock endpoint resolves into
    env_vars: [AWS_REGION, AWS_DEFAULT_REGION]
    required: true
    auth_style: config
discovery:
  credentials: [aws_access_key_id, aws_secret_access_key, aws_region]
endpoints:
  - host: bedrock-runtime.{region}.amazonaws.com
    port: 443
    protocol: rest
    access: read-write
    enforcement: enforce
binaries: [/usr/bin/claude, /usr/local/bin/claude]
```

Notes:
- The `{region}` placeholder in `host` is consistent with how
  `bedrock-runtime` endpoints are derived. If the YAML loader doesn't
  yet support placeholders, the alternative is to leave the host
  field as a wildcard pattern and let the operator override
  per-deployment via `BEDROCK_BASE_URL` (mirroring the existing
  `ANTHROPIC_BASE_URL` config-key shape used by the anthropic
  provider).
- A new `auth_style: sigv4` is introduced. The router needs to know
  it has to compute a SigV4 signature on the way out; the existing
  `header` and `bearer` styles don't fit. Implementation: add a
  SigV4 signer in `crates/openshell-router` that takes the path,
  body, region, and credentials and emits the `Authorization` and
  `X-Amz-*` headers. AWS publishes a stable spec; `aws-sigv4` (Rust
  crate) is the obvious dependency.
- A `BEDROCK_BASE_URL` config-key (operator override) lets the
  router target alternate endpoints — direct AWS, an in-cluster
  Bedrock-compatible bridge, LiteLLM. Same shape as the
  `ANTHROPIC_BASE_URL` override for the anthropic provider.

### 3. `crates/openshell-providers/src/providers/aws_bedrock.rs` — discovery spec

```rust
// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

use crate::ProviderDiscoverySpec;

pub const SPEC: ProviderDiscoverySpec = ProviderDiscoverySpec {
    id: "aws-bedrock",
    credential_env_vars: &[
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_REGION",
    ],
};

test_discovers_env_credential!(
    discovers_aws_bedrock_env_credentials,
    "AWS_ACCESS_KEY_ID",
    "AKIA-test-key"
);
```

And in `crates/openshell-providers/src/providers/mod.rs`:

```rust
pub mod aws_bedrock;
```

### 4. `crates/openshell-router` — register the protocol

Where the router currently dispatches `anthropic_messages` and
`openai_chat_completions` to the right backend, add the two new
protocol strings (`aws_bedrock_invoke`, `aws_bedrock_invoke_stream`)
and route them to the SigV4 backend (#2 above). The streaming
variant sets `Accept: application/vnd.amazon.eventstream` outbound;
the non-streaming variant doesn't.

Both protocols share a `kind: "messages"` so existing OCSF logging
and quota accounting (which key on `kind`) continues to work.

### 5. CLI / TUI updates

- `crates/openshell-cli/tests/provider_commands_integration.rs` —
  add an integration test that creates an `aws-bedrock` provider,
  attaches it to a sandbox, and asserts the bundle includes the
  credential keys.
- `crates/openshell-tui/src/ui/create_provider.rs` — add the
  `aws-bedrock` choice to the provider type picker.

### 6. Docs

- `docs/sandboxes/manage-providers.mdx` — add a section showing
  `openshell provider create --type aws-bedrock --credential ... `
  with both the AWS-default and `BEDROCK_BASE_URL`-override forms.
- `docs/sandboxes/providers-v2.mdx` — table of supported provider
  types gains a row for `aws-bedrock`.

## Test plan

Tier-1 (unit, in-tree):
- Glob matcher accepts `/model/anthropic.claude-opus-4-7/invoke` and
  rejects `/model//invoke` and `/model/a/b/invoke`.
- Discovery spec picks up `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
  `AWS_REGION` from env and skips a discovery if any are missing.
- SigV4 signer regression test against AWS's published canonical
  request fixtures.

Tier-2 (integration):
- `e2e/rust/tests/provider_auto_create.rs` extends to register an
  `aws-bedrock` provider with mocked AWS_* env vars.
- New `e2e/python/test_sandbox_providers.py` case: create an
  `aws-bedrock` provider, verify a sandbox sees the right env in its
  bundle, and verify a `POST /model/{id}/invoke` from inside the
  sandbox reaches a wiremock backend.

Tier-3 (live):
- Internal smoke against AWS Bedrock with a real sub-account.

## What this PR explicitly does NOT do

- Does not add a Bedrock-shape ↔ Anthropic-shape body translator.
  The router treats both protocols as opaque pass-through; if the
  operator's upstream is a real AWS Bedrock endpoint they speak
  Bedrock natively, if it's an in-cluster bridge the bridge does any
  translation it needs server-side.
- Does not add `BEDROCK_BASE_URL` placeholder substitution if the
  YAML profile loader doesn't support placeholders yet — that's a
  separate small infra change. As a stop-gap the loader can accept
  a literal hostname and treat the operator's `BEDROCK_BASE_URL`
  config-key override as authoritative when set.

## Why we want this (operator context)

We're shipping an in-cluster SAP AI Core ↔ Bedrock translation bridge
in `st-gr/openshell-driver-kyma`. SAP exposes Anthropic models behind
the Bedrock InvokeModel schema with XSUAA bearer auth. Without this
PR our bridge has to do its own protocol translation and register as
`--type anthropic` with `/v1/messages` on the inside, which means it
carries a 200-line Anthropic→Bedrock body translator and a
field-denylist for fields the SAP gateway rejects. With this PR the
bridge becomes a path-translating + auth-substituting pass-through
(no body work), and operators using direct AWS Bedrock or a different
Bedrock-compatible proxy benefit from the same plumbing.
