## Summary

Adds an opt-in `--compute-driver-socket=<path>` flag (env `OPENSHELL_COMPUTE_DRIVER_SOCKET`) to the gateway. When set, the gateway dispatches sandbox-lifecycle gRPC to an out-of-tree compute driver speaking the existing `compute_driver.proto` contract over a Unix domain socket, instead of constructing one of the four built-in drivers (Kubernetes / Podman / Docker / VM). This unblocks operators running OpenShell on Kubernetes distributions whose CRD/RBAC shape the in-tree Kubernetes driver doesn't fit (e.g. SAP Kyma, Gardener-flavored clusters), without forking the gateway forever.

## Related Issue

Supersedes the closed draft #1604 (same author, same patch shape — re-opened as a non-draft after rebasing onto current `main`, addressing review-friction items, and landing all four commits with DCO sign-off).

The use case — supporting out-of-tree compute drivers for OpenShell distributions whose CRD/RBAC shape doesn't fit the in-tree Kubernetes driver — is also what `cheese-head` was vouched for in #1345 (a different mechanism but same goal).

## Changes

- `crates/openshell-core/src/config.rs`: adds `External(PathBuf)` variant to `ComputeDriverKind`. Drops the `Copy` derive and `const fn as_str(self)` (both incompatible with a `PathBuf`-carrying variant). `FromStr` accepts `external:<path>` and rejects bare `external` with a message pointing at the CLI flag.
- `crates/openshell-server/src/cli.rs`:
  - Adds the `--compute-driver-socket=<path>` flag (env `OPENSHELL_COMPUTE_DRIVER_SOCKET`) on `RunArgs`.
  - Adds `effective_single_driver`: when the socket flag is set, pin `ComputeDriverKind::External(<path>)` and skip both the `--drivers` list and the auto-detection probe.
- `crates/openshell-server/src/config_file.rs`: surfaces the new field through the config-file path.
- `crates/openshell-server/src/lib.rs`: in `build_compute_runtime`, when `ComputeDriverKind::External(<path>)` is the configured driver, connect a `tonic::Channel` to the supplied UDS via `hyper-util::TokioIo` and wrap it in `RemoteComputeDriver` — the same proxy already used for the VM driver. Replaces the previous `unimplemented!()` placeholder.
- `crates/openshell-server/src/compute/mod.rs`: small wiring additions to expose the UDS-channel construction path.

## Out of scope (intentional)

- **No new in-tree compute driver implementations.** This PR only adds the protocol surface (`External(PathBuf)` + UDS dispatch). Operators bring their own driver process and point `--compute-driver-socket` at its socket path. A reference driver for SAP Kyma lives at [`st-gr/openshell-driver-kyma`](https://github.com/st-gr/openshell-driver-kyma), reusing this PR's gRPC contract.
- **No `compute_driver.proto` changes.** The existing protocol is reused verbatim — the same one already used by the in-tree VM driver to talk to its tonic peer.
- **No security model changes.** UDS endpoint security is the operator's responsibility (filesystem permissions, sidecar isolation, etc.) — same posture as `--drivers vm`.

## Testing

- Existing `cargo check -p openshell-core -p openshell-server` passes (build verified inside `Dockerfile.gateway` after adding `libclang-dev`/`libz3-dev` for upstream's existing transitive bindgen + z3-sys deps — separate from this PR).
- The forked gateway image carrying these patches has been running against a real Kubernetes cluster (Gardener-managed Kyma) with the [`st-gr/openshell-driver-kyma`](https://github.com/st-gr/openshell-driver-kyma) driver since 2026-05-28: Sandbox CR creation, `openshell sandbox exec`, `openshell sandbox upload/download` all work.
- `cargo clippy --no-deps -p openshell-core -p openshell-server --all-targets -- -D warnings` clean.

- [x] Unit tests added/updated *(the `FromStr` parser for the new variant is covered by the existing config-roundtrip tests; happy to add additional cases if reviewers want explicit `external:<path>` parse coverage)*
- [ ] E2E tests added/updated *(none — running an `External` driver in CI would require shipping a stub driver binary; suggesting to defer until at least one in-tree consumer wants to test against it)*
- [ ] `mise run pre-commit` passes *(not run — `mise` not available in author's dev environment; happy to address any specific check failures CI surfaces)*

## Operator context

The forked gateway image at `ghcr.io/st-gr/openshell-gateway` (carrying these patches plus the in-tree `Dockerfile.gateway`) has been driving production-shaped Kubernetes clusters with the [`st-gr/openshell-driver-kyma`](https://github.com/st-gr/openshell-driver-kyma) compute driver since 2026-05-28. The flag has needed zero changes since it landed — the API shape is stable. Merging this PR lets the driver consume the unmodified upstream gateway image, retiring the fork.

## Checklist

- [x] Follows [Conventional Commits](https://www.conventionalcommits.org/) (`feat(core):` / `feat(server):` / `docs(core,server):`)
- [x] Commits are signed off (DCO)
- [ ] Architecture docs updated *(no change to existing docs — happy to add an "out-of-tree compute drivers" section to the relevant `docs/` page if reviewers want it in this PR rather than a doc-only follow-up.)*
