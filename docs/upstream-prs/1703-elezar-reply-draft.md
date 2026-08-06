# Reply to elezar's CHANGES_REQUESTED on PR #1703

**Status:** STALE — DO NOT POST. Draft regenerated 2026-06-06 from the plan-mode plan, not realising the conversation had already moved past it. The reply text below was actually posted by st-gr on 2026-06-05 04:43 ([comment 4628271549](https://github.com/NVIDIA/OpenShell/pull/1703#issuecomment-4628271549)) and was subsequently SUPERSEDED — see "What actually happened" below.

**Original context:** elezar (NVIDIA) left a `CHANGES_REQUESTED` review on 2026-06-03, no inline comments, asking us to reformulate the surface as a named driver endpoint — user supplies `(driver_name, socket_path)`, gateway selects by name, and `GetCapabilities.driver_name` validates the user-supplied name. References RFC #1589 (driver-config passthrough, keyed by exact driver name) and notes the in-tree `vm` driver already speaks UDS — we'd be extending that pattern, not adding a parallel one.

## What actually happened (timeline since the plan was written)

1. **2026-06-05 04:43** — st-gr posted the reply text below verbatim. ([link](https://github.com/NVIDIA/OpenShell/pull/1703#issuecomment-4628271549))
2. **2026-06-05 07:06** — drew (collaborator) +1'd: prefer to avoid the `External` enum variant entirely; like the `<name>@<socket>` shape but defer to a follow-up; rely on `GetCapabilities.driver_name`; leave the four in-tree drivers as-is. ([link](https://github.com/NVIDIA/OpenShell/pull/1703#issuecomment-4629050194))
3. **2026-06-05 09:57** — st-gr summarised the convergence: drop `External(PathBuf)` entirely; use `Config.external_compute_driver_socket: Option<PathBuf>` instead of an enum variant; keep `--compute-driver-socket=<path>` as a single flag (no name); log `GetCapabilities.driver_name` for diagnostics, no validation; defer `<name>@<socket>` to a follow-up. ([link](https://github.com/NVIDIA/OpenShell/pull/1703#issuecomment-4630317704))
4. **2026-06-05 11:17** — st-gr force-pushed the rewrite (`b1ed3629`) and refreshed the PR body. Branch is now 4 commits: `feat(core)` adds `Config.external_compute_driver_socket`, `feat(server)` adds the CLI flag, `feat(server)` wires the UDS dispatch via `connect_external_compute_driver`, `docs(compute)` updates the architecture table. No `External` variant. `from_driver` takes `Option<ComputeDriverKind>`. ([link](https://github.com/NVIDIA/OpenShell/pull/1703#issuecomment-4631013516))
5. **2026-06-05 16:56–17:16** — DCO sign + `recheck`.

## Current state (read on 2026-06-06)

- PR head: `b1ed3629d9f5f46ba472e76e6687ed6de1a5a54c` on `feat/external-compute-driver-socket`
- elezar's `CHANGES_REQUESTED` is still attached to `1c6663d3` (pre-rewrite). Not yet re-reviewed.
- drew's +1 was on the direction, not on the post-rewrite SHA.
- CI: DCO ✅, gate statuses ✅. `Branch Checks` and `Helm Lint` are `pending — Waiting for /ok to test mirror`. Last `/ok to test` was on `8689967` from 2026-06-03; the current HEAD has not been re-vetted.
- No new outbound action required from us until either reviewer responds.

---

## Reply text (already posted — historical, do NOT re-post)

---

## Reply text

> Thanks for the steer. Agree the named-driver-endpoint framing is the right shape — it lines up with #1589's name-keyed `driver_config` and avoids locking in a fifth `ComputeDriverKind` variant that #1589 would then have to undo.
>
> Concrete proposal for this PR, scoped to keep the change narrow:
>
> - **Core:** `ComputeDriverKind::External(PathBuf)` → `ComputeDriverKind::External { name: String, socket: PathBuf }`. The other four variants stay bare. `FromStr` accepts `external:<name>@<path>`; `Display` round-trips the same.
> - **CLI:** add `--compute-driver-name=<name>` (env `OPENSHELL_COMPUTE_DRIVER_NAME`) paired with the existing `--compute-driver-socket`. Both required when either is set; the pair pins `External { name, socket }` and skips `--drivers` / auto-detect.
> - **Validation:** on startup, after the tonic channel connects, the gateway calls `GetCapabilities` and fails fast if `response.driver_name != name`. (`GetCapabilitiesResponse.driver_name` already exists on `compute_driver.proto:49` — no proto change needed.)
> - **Trust boundary:** unchanged — operator-owned UDS file permissions, same posture as the in-tree `vm` driver.
>
> One scope question before I push: should this PR generalise the dispatch beyond `External` — e.g. fold `Vm` into the same name-keyed path so the registry is uniform — or keep that for the #1589 follow-up and leave the four in-tree variants as-is? My read is the latter (this PR stays the minimum that earns the named-endpoint shape; #1589 or a successor RFC handles the full name-keyed registry). Happy to expand if you'd prefer it land in one go.

---

## Why this version (notes for the user, not for posting)

- **Acknowledges direction first.** elezar's framing is already aligned with #1589, so the reply opens by agreeing rather than negotiating shape.
- **Concrete-and-bounded proposal.** Lists exactly the surfaces touched (`config.rs`, `cli.rs`, channel-construction, `GetCapabilities`) so elezar can either ack the scope or push back on a specific bullet.
- **Calls out the "no proto change" fact.** `GetCapabilitiesResponse.driver_name` exists already (`compute_driver.proto:49`); naming this in the reply heads off the natural "does this need a proto bump?" question.
- **Asks one targeted scope question, not several.** The only ambiguity in elezar's review is whether the four bare in-tree variants should fold into the same shape now or later. Asking costs one round-trip; guessing wrong costs a force-push and a thread of correction.
- **Gives a default answer.** "My read is the latter" — so if elezar doesn't reply, the implication is we proceed with the narrow scope. Doesn't force them into the loop if they don't want to be.

## What we're NOT saying in the reply

- We don't mention the deployment-staleness bug (phase-stuck on `:latest`). That's a separate fork-internal issue, not part of #1703.
- We don't propose dropping the two fork-only commits (`0797e19f`, `c1d227b6`) — that's a branch-hygiene step we do silently before force-pushing, not something to discuss in the PR thread.
- We don't volunteer to file a new tracking issue. elezar may or may not want one; if they do, they'll ask.

## After posting

Plan-mode plan still applies (`/Users/grundmanns/.claude/plans/looks-like-you-need-twinkling-finch.md`):

1. **Wait for elezar's scope answer** before pushing code.
2. Once scope is confirmed: implement on `upstream-pr/external-compute-driver-socket` (in fork repo). Single new commit per the plan; verify with `cargo fmt`, `cargo clippy -D warnings`, `cargo test -p openshell-core compute_driver_kind`, and the CLI/config_file test suites.
3. Drop the two fork-only commits (`0797e19f build(gateway): Dockerfile + GHCR release workflow`, `c1d227b6 fix(gateway): bin target is openshell-gateway, package is openshell-server`) via interactive rebase before force-push.
4. Force-push with `--force-with-lease`, `gh pr edit 1703` to update the body, then re-request elezar's review.

All push/post/edit actions require user approval per the standing session rule.
