> **Status (archival):** Merged as
> [NVIDIA/OpenShell#1703](https://github.com/NVIDIA/OpenShell/pull/1703)
> on 2026-06-26. This is the as-submitted PR body, kept for the record.
> The fork gateway image it references
> (`ghcr.io/st-gr/openshell-gateway`) has since been retired — the chart
> now runs the unmodified upstream `ghcr.io/nvidia/openshell/gateway`.

## Summary

Adds an opt-in `--compute-driver-socket=<path>` flag (env `OPENSHELL_COMPUTE_DRIVER_SOCKET`) to the gateway. When set, the gateway dispatches sandbox lifecycle to an out-of-tree compute driver speaking the existing `compute_driver.proto` contract over a Unix domain socket, instead of one of the four built-in drivers (Kubernetes / Podman / Docker / VM).

## Related Issue

Supersedes the closed draft #1604 (same author, same patch shape — re-opened as a non-draft after rebasing onto current `main`, with all commits DCO-signed and st-gr-attributed). Same direction as `cheese-head`'s vouch in #1345 ("extend or provide new out-of-tree compute drivers to OpenShell").

No upstream tracking issue filed — happy to file one if reviewers prefer.

## Changes

- `crates/openshell-core/src/config.rs`: adds `External(PathBuf)` variant to `ComputeDriverKind`. Drops the `Copy` derive and `const fn as_str(self)` (both incompatible with `PathBuf`). `FromStr` accepts `external:<path>` (case-insensitive prefix) and rejects bare `external` with a message pointing at the CLI flag.
- `crates/openshell-server/src/cli.rs`: adds `--compute-driver-socket=<path>` flag (env `OPENSHELL_COMPUTE_DRIVER_SOCKET`) on `RunArgs`. When set, pins `ComputeDriverKind::External(<path>)` and skips both `--drivers` and the auto-detection probe.
- `crates/openshell-server/src/config_file.rs`: surfaces the new field through the config-file path.
- `crates/openshell-server/src/lib.rs` / `crates/openshell-server/src/compute/mod.rs`: in `build_compute_runtime`, the `External(<path>)` arm connects a `tonic::Channel` to the UDS via `hyper-util::TokioIo` and wraps it in `RemoteComputeDriver` — the same proxy used by the in-tree VM driver.
- `architecture/compute-runtimes.md`: adds an "External" row to the Runtime Summary table, describing the trust boundary (operator-owned UDS file permissions) and the activation flag.

## Testing

- [ ] `mise run pre-commit` passes — *not run end-to-end (`mise` not on author's dev environment), but the equivalent rust pieces verified independently:* `cargo fmt --all -- --check` clean; `cargo clippy --no-deps -p openshell-core -p openshell-server --all-targets -- -D warnings` clean.
- [x] Unit tests added/updated — *9 `compute_driver_kind_*` tests in `crates/openshell-core/src/config.rs::tests` cover the new variant: parses `external:<path>`, rejects bare `external` and empty path, displays as `external:<path>`, round-trips through `FromStr`+`Display`, and is case-insensitive on the prefix. Plus 3 CLI-arg tests for the new flag (presence, override-of-drivers, env-var binding).*
- [ ] E2E tests added/updated — *none — running an `External` driver in CI would require shipping a stub driver binary; deferring until at least one in-tree consumer wants to test against it. The patch is exercised in production at SAP via the [`st-gr/openshell-driver-kyma`](https://github.com/st-gr/openshell-driver-kyma) reference driver running against a Gardener-managed Kyma cluster since 2026-05-28 (sandbox CR creation, `openshell sandbox exec`, `openshell sandbox upload/download` all work).*

## Checklist

- [x] Follows [Conventional Commits](https://www.conventionalcommits.org/) (`feat(core):`, `feat(server):`, `docs(core,server):`, `docs(arch):`)
- [x] Commits are signed off (DCO)
- [x] Architecture docs updated — *added "External" row to `architecture/compute-runtimes.md::Runtime Summary`. Per-runtime implementation-notes section is intentionally NOT extended for `External` because external drivers ship their own documentation; the reference implementation lives at [`st-gr/openshell-driver-kyma`](https://github.com/st-gr/openshell-driver-kyma).*

---

## Notes for reviewers

**Out of scope (intentional):**

- **No new in-tree compute driver implementations.** This PR only adds the protocol surface (`External(PathBuf)` + UDS dispatch). Operators bring their own driver process and point `--compute-driver-socket` at its socket path.
- **No `compute_driver.proto` changes.** The existing protocol is reused verbatim — the same one already used by the in-tree VM driver to talk to its tonic peer.
- **No security model changes.** UDS endpoint security is the operator's responsibility (filesystem permissions, sidecar isolation), matching the `--drivers vm` posture.
- **No new dependencies.** `hyper-util` is already in the workspace `Cargo.toml`; the patch reuses it via the same `TokioIo` connector path the VM driver uses.

**Operator context:**

The forked gateway image at `ghcr.io/st-gr/openshell-gateway` (carrying these patches plus an in-tree `Dockerfile.gateway`) has been driving production-shaped Kubernetes clusters with the [`st-gr/openshell-driver-kyma`](https://github.com/st-gr/openshell-driver-kyma) compute driver since 2026-05-28. The flag has needed zero changes since it landed — the API shape is stable. Merging this PR lets the driver consume the unmodified upstream gateway image, retiring the fork.
