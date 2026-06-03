## Summary

Adds `aws-bedrock` as a recognized inference protocol in the supervisor's L7 router and the providers catalog so operators can register a Bedrock-shaped upstream as `--type aws-bedrock` and route Claude Code Bedrock-mode traffic (`POST /model/{id}/invoke[-with-response-stream]`) through `inference.local`. Without this, sandboxes hit `403 "connection not allowed by policy"` because no L7 pattern matches Bedrock URLs. The canonical no-SigV4 use case is **SAP AI Core deployed Bedrock models** (Anthropic models behind a Bedrock-shape API with XSUAA bearer auth instead of SigV4); operators wanting **real AWS Bedrock** additionally need #1630's proxy-side SigV4 signing.

## Related Issue

Complementary to #1630 ("Sigv4 credential signing"). #1630 adds proxy-side SigV4 re-signing as a `credential_signing: sigv4` policy field. **This PR is the URL-pattern half**: the supervisor's L7 router needs to recognize Bedrock InvokeModel paths *before* anything can be signed, regardless of whether the upstream needs SigV4. The two patches don't touch the same files; they're complementary, not overlapping.

No upstream tracking issue filed — happy to file one if reviewers prefer.

## Changes

- `crates/openshell-sandbox/src/l7/inference.rs`:
  - Adds two patterns to `default_patterns()`: `POST /model/*/invoke` (`aws_bedrock_invoke`) and `POST /model/*/invoke-with-response-stream` (`aws_bedrock_invoke_stream`).
  - Extends `detect_inference_pattern` to support a single middle `/*/` glob in addition to the existing trailing `/*`. The middle wildcard matches exactly one non-empty path segment containing no `/` — `/model//invoke` and `/model/a/b/invoke` both no-match.
- `providers/aws-bedrock.yaml`: new YAML profile declaring four credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`) and a default endpoint of `bedrock-runtime.us-east-1.amazonaws.com:443`. Operators in other regions or pointing at non-AWS Bedrock-compatible upstreams override per-deployment via the operator-supplied `BEDROCK_BASE_URL` config-key (mirroring how the `anthropic` provider accepts `ANTHROPIC_BASE_URL`).
- `crates/openshell-providers/src/providers/aws_bedrock.rs`: the `ProviderDiscoverySpec` so `--auto-providers` picks up `AWS_*` env vars from local credentials.
- `crates/openshell-providers/src/{providers/mod.rs,lib.rs,profiles.rs}`: register the new module + SPEC + YAML.

## Testing

- [ ] `mise run pre-commit` passes — *not run end-to-end (`mise` not on author's dev environment), but the equivalent rust pieces verified independently:* `cargo fmt --all -- --check` clean; `cargo clippy --no-deps -p openshell-providers -p openshell-sandbox --all-targets -- -D warnings` clean.
- [x] Unit tests added/updated — *7 new pattern-matcher tests in `crates/openshell-sandbox/src/l7/inference.rs::tests` cover positive path, query-string handling, GET rejection, empty-segment rejection, multi-segment rejection, unknown-action rejection. Provider-discovery test follows the existing `test_discovers_env_credential!` macro convention.* `cargo test -p openshell-sandbox --lib l7::inference`: 40 passed; `cargo test -p openshell-providers`: 35 passed.
- [ ] E2E tests added/updated — *none — running an `aws-bedrock` provider end-to-end requires either real AWS Bedrock with SigV4 (covered by #1630) or a Bedrock-compatible stub backend. Deferring the E2E test to whichever PR lands second so it can exercise the full URL-pattern + auth path together.*

## Checklist

- [x] Follows [Conventional Commits](https://www.conventionalcommits.org/) (`feat(sandbox):`, `feat(providers):`)
- [x] Commits are signed off (DCO)
- [ ] Architecture docs updated — *no surgical place to add a row that wouldn't pre-empt #1630's signing scope. The new patterns sit alongside the existing OpenAI/Anthropic ones in `default_patterns()`; the new YAML profile follows the same shape as `claude-code.yaml` / `nvidia.yaml`. Happy to add a paragraph to `docs/sandboxes/manage-providers.mdx` (or another spot reviewers prefer) in this PR rather than a doc-only follow-up.*

---

## Notes for reviewers

**Use cases (which PRs you need for which upstream):**

| Upstream | What you need | Why |
|---|---|---|
| **SAP AI Core deployed Bedrock** (XSUAA bearer; no SigV4) | This PR alone | The bridge ignores inbound auth and mints XSUAA outbound; the supervisor's L7 router only needs to recognize Bedrock URL patterns, which this PR adds. |
| **In-cluster translating bridge** (LiteLLM in Bedrock-emulation mode, custom Bedrock-compatible proxy that authenticates separately) | This PR alone | Same shape as SAP — operator's bridge handles upstream auth; the proxy just needs URL-pattern recognition. |
| **Real AWS Bedrock** (SigV4 enforced at AWS) | This PR **plus** #1630 | This PR adds the URL-pattern recognition; #1630 adds proxy-side SigV4 signing via the `credential_signing: sigv4` policy field. The two are complementary; this PR is the prerequisite that makes #1630's signing applicable to Bedrock paths. |

In all three cases, `provider create --type aws-bedrock` requires `--no-verify` until a Bedrock-aware arm is added to `validation_probe()` in `crates/openshell-router/src/backend.rs`. That extension is left for a follow-up PR to keep this one focused on the URL-pattern + provider-registration changes.

**Out of scope (intentional):**

- **SigV4 signing.** Already addressed in #1630.
- **`{region}` placeholder substitution in the YAML loader.** Operators override per-deployment via `BEDROCK_BASE_URL` config-key the same way `ANTHROPIC_BASE_URL` works for the `anthropic` provider.
- **Body translation between Bedrock InvokeModel and other inference shapes.** The router treats matched requests as opaque pass-through.
- **CLI / TUI surface updates.** Operators can already create the provider via `openshell provider create --type aws-bedrock` because the registry recognizes the new id; surfacing it in the TUI's provider-type picker is a follow-up.

**Operator context:**

The [`st-gr/openshell-driver-kyma`](https://github.com/st-gr/openshell-driver-kyma) Helm chart currently registers its SAP AI Core ↔ Bedrock translation bridge as `--type anthropic` with `/v1/messages` on the inside, because `aws-bedrock` isn't a recognized provider type. The chart therefore carries a server-side Anthropic→Bedrock body translator and a denylist for Anthropic-API-only fields the SAP gateway rejects. After this PR, the bridge becomes a path-translating + auth-substituting pass-through with no body work — the chart's translator code goes away.
