## Summary

Adds `aws-bedrock` as a recognized inference protocol in the supervisor's L7 router and the providers catalog, so operators can register a Bedrock-shaped upstream as `--type aws-bedrock` and route Claude Code Bedrock-mode traffic (`POST /model/{id}/invoke[-with-response-stream]`) through `inference.local` the same way OpenAI and Anthropic upstreams work today. Without this, sandboxes hit `403 "connection not allowed by policy"` because no L7 pattern matches Bedrock URLs. The canonical no-SigV4 use case is **SAP AI Core deployed Bedrock models** (Anthropic models behind a Bedrock-shape API with XSUAA bearer auth instead of SigV4); operators wanting **real AWS Bedrock** additionally need #1630's proxy-side SigV4 signing.

## Use cases

| Upstream | What you need | Why |
|---|---|---|
| **SAP AI Core deployed Bedrock** (XSUAA bearer; no SigV4) | This PR alone | The bridge ignores inbound auth and mints XSUAA outbound; the supervisor's L7 router only needs to recognize Bedrock URL patterns, which this PR adds. |
| **In-cluster translating bridge** (LiteLLM in Bedrock-emulation mode, custom Bedrock-compatible proxy that authenticates separately) | This PR alone | Same shape as SAP — operator's bridge handles upstream auth; the proxy just needs URL-pattern recognition. |
| **Real AWS Bedrock** (SigV4 enforced at AWS) | This PR **plus** #1630 | This PR adds the URL-pattern recognition; #1630 adds proxy-side SigV4 signing via the `credential_signing: sigv4` policy field. The two are complementary; this PR is the prerequisite that makes #1630's signing applicable to Bedrock paths. |

In all three cases, `provider create --type aws-bedrock` requires `--no-verify` until a Bedrock-aware arm is added to `validation_probe()` in `crates/openshell-router/src/backend.rs`. That extension is left for a follow-up PR to keep this one focused on the URL-pattern + provider-registration changes.

## Related Issue

Complementary to #1630 ("Sigv4 credential signing", currently closed pending vouch) — that PR adds proxy-side AWS SigV4 re-signing as a `credential_signing: sigv4` policy field. **This PR is the URL-pattern half**: the supervisor's L7 router needs to recognize Bedrock InvokeModel paths *before* anything can be signed, regardless of whether the upstream needs SigV4. Both PRs together unlock direct AWS Bedrock; this PR alone unlocks Bedrock-compatible upstreams that don't need SigV4 (in-cluster translating bridges, LiteLLM in Bedrock-emulation mode, etc.). The two patches don't touch the same files.

(no upstream issue filed — happy to file one if reviewers prefer.)

## Changes

- `crates/openshell-sandbox/src/l7/inference.rs`:
  - Adds two patterns to `default_patterns()`: `POST /model/*/invoke` (`aws_bedrock_invoke`) and `POST /model/*/invoke-with-response-stream` (`aws_bedrock_invoke_stream`).
  - Extends `detect_inference_pattern` to support a single middle `/*/` glob in addition to the existing trailing `/*`. The middle wildcard matches exactly one non-empty path segment containing no `/` — `/model//invoke` and `/model/a/b/invoke` both no-match.
  - 7 new unit tests cover the positive path, query-string handling, GET rejection, empty-segment rejection, multi-segment rejection, and unknown-action rejection.
- `providers/aws-bedrock.yaml`: new YAML profile declaring four credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`) and a default endpoint of `bedrock-runtime.us-east-1.amazonaws.com:443`. Operators in other regions or pointing at non-AWS Bedrock-compatible upstreams override per-deployment via an operator-supplied `BEDROCK_BASE_URL` config-key (mirroring how the `anthropic` provider accepts `ANTHROPIC_BASE_URL`).
- `crates/openshell-providers/src/providers/aws_bedrock.rs`: the `ProviderDiscoverySpec` so `--auto-providers` picks up `AWS_*` env vars from local credentials.
- `crates/openshell-providers/src/providers/mod.rs`: register the module.
- `crates/openshell-providers/src/lib.rs`: register the SPEC in the default registry.
- `crates/openshell-providers/src/profiles.rs`: include the new YAML in `BUILT_IN_PROFILE_YAMLS`.

## Out of scope (intentional)

These are intentionally not in this PR so it stays small and focused. None of them block the use case (a Bedrock-compatible upstream that accepts plain Bedrock-shape requests at `/model/{id}/invoke[-with-response-stream]`):

- **SigV4 signing.** Already addressed in #1630, which adds a `credential_signing: sigv4` policy field with proxy-side AWS-SDK signing. This PR's URL-pattern matcher is the prerequisite that makes #1630's signing applicable to Bedrock paths; the two are complementary, not overlapping.
- **`BEDROCK_BASE_URL` config-key + `{region}` placeholder substitution in the YAML loader.** The YAML's `host` is currently a literal default; operators override per-deployment via the operator-supplied config-key the same way `ANTHROPIC_BASE_URL` works for the `anthropic` provider. Adding placeholder substitution to the loader is a separate small infra change.
- **Body translation between Bedrock InvokeModel and other inference shapes.** The router treats matched requests as opaque pass-through. If the operator's upstream is real AWS Bedrock it speaks Bedrock natively; if it's a translating bridge the bridge does any conversion server-side.
- **CLI / TUI surface updates.** Operators can already create the provider via `openshell provider create --type aws-bedrock` because the registry recognizes the new id; surfacing it in the TUI's provider-type picker is a follow-up.

## Testing

```
cargo test -p openshell-sandbox --lib l7::inference
test result: ok. 40 passed; 0 failed; 0 ignored

cargo test -p openshell-providers
test result: ok. 35 passed; 0 failed; 0 ignored

cargo clippy --no-deps -p openshell-providers --all-targets -- -D warnings
clean

cargo clippy --no-deps -p openshell-sandbox --all-targets -- -D warnings
clean
```

The 7 new pattern-matcher tests are in `crates/openshell-sandbox/src/l7/inference.rs`'s existing `mod tests`. The provider-discovery test follows the existing `test_discovers_env_credential!` macro convention used by every other provider in the catalog.

- [x] Unit tests added/updated
- [ ] E2E tests added/updated *(none added — running an `aws-bedrock` provider end-to-end requires either a real AWS endpoint with SigV4 signing — addressed by #1630 — or a Bedrock-compatible stub backend. Suggesting to defer the E2E test to whichever PR lands second so it can exercise the full URL-pattern + auth path together.)*
- [ ] `mise run pre-commit` passes *(not run — `mise` not available in author's dev environment; happy to address any specific check failures the CI surfaces)*

## Operator context

Concrete impact: the [`st-gr/openshell-driver-kyma`](https://github.com/st-gr/openshell-driver-kyma) Helm chart currently registers its SAP AI Core ↔ Bedrock translation bridge as `--type anthropic` with `/v1/messages` on the inside, because `aws-bedrock` isn't a recognized provider type. The chart therefore carries a server-side Anthropic→Bedrock body translator and a denylist for Anthropic-API-only fields the SAP gateway rejects. After this PR, the bridge becomes a path-translating + auth-substituting pass-through with no body work — the chart's translator code goes away.

## Checklist

- [x] Follows [Conventional Commits](https://www.conventionalcommits.org/) (`feat(sandbox):` / `feat(providers):`)
- [x] Commits are signed off (DCO)
- [ ] Architecture docs updated *(none changed — the new patterns sit alongside the existing OpenAI/Anthropic ones in `default_patterns()` and the new YAML profile follows the same shape as `claude-code.yaml` / `nvidia.yaml`. Happy to add a paragraph to `docs/sandboxes/manage-providers.mdx` if reviewers want one in this PR rather than a doc-only follow-up.)*
