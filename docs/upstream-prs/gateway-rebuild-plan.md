# Gateway rebuild + redeploy plan

**Status:** DRAFT — local build running. Push/deploy actions require user approval.

## Background

Cluster is running `ghcr.io/st-gr/openshell-gateway:latest` (digest `sha256:ebff5977...`) with `pullPolicy: IfNotPresent`. The image was built from fork `origin/main` HEAD `163a7881`, which is **40 commits behind upstream/main**. Two upstream fixes that are missing in the deployed image are almost certainly causing the phase-stuck-at-Unspecified bug:

| Upstream commit | What it fixes |
|---|---|
| `d01d1065` (PR #1565, 2026-05-29, Derek Carr) | Squash-merged with the proto refactor; includes `fix(server): preserve sandbox status on statusless driver updates` — old code reset stored phase/conditions when a driver update arrived without a status payload (e.g. before agent-sandbox controller writes `.status.conditions`). |
| `97986d90` (PR #1765, 2026-06-05, Shiju) | `fix(server): resume unspecified sandbox phase` — startup resume sweep skipped Unspecified rows; treats Unspecified as running so the sweep reconciles from live driver state. |

## Local build attempt — FAILED

Tried first on `/Users/grundmanns/Documents/repos/acode/openshell-fork` local branch `local/gateway-build` (origin/main + upstream/main merged), command:

```sh
docker buildx build --platform linux/amd64 -f Dockerfile.gateway -t openshell-gateway:local-build --load .
```

**Result:** failed at `cargo chef cook` after ~34000s wall (9.4 hrs of QEMU CPU). Root cause: `aws-lc-sys-0.40.0` compiles `sha3_keccak4_f1600_alt.S` (x86_64 AT&T SHA3 ASM) using `cc`; under QEMU x86_64 emulation, `cc1` hits an internal compiler error / segfault. Reproducible — known QEMU/GCC interaction with this ASM file. No workaround in `Dockerfile.gateway` short of switching the build host architecture or replacing `aws-lc` with `ring`.

**Implication:** local cross-build on this Apple Silicon Mac is not viable. Path A (local docker push) is dead. Use Path B.

## Deploy path: CI rebuild on fork main

```sh
# inside /Users/grundmanns/Documents/repos/acode/openshell-fork on local/gateway-build
git log origin/main..HEAD --oneline            # ← read-only, sanity-check what we're about to push
git push origin local/gateway-build:main       # ← REQUIRES USER APPROVAL (writes fork main)
# release-gateway.yml triggers: native linux/amd64 (and arm64) runner build, no QEMU.
gh run watch --exit-status                     # ← read-only, OK
```

**What this includes (40 commits from upstream/main):**
- `97986d90` PR #1765 — resume Unspecified phase (startup sweep)
- `d01d1065` PR #1565 — preserve sandbox status on statusless driver updates (the bug)
- `c3964a65` PR #1744 — kubernetes driver config passthrough
- `e26a1b1f` PR #1767 — sandbox AppArmor profile fix
- 36 other upstream commits since 2026-05-26

**Tags produced** (per `release-gateway.yml`):
- `ghcr.io/st-gr/openshell-gateway:<sha>` — exact SHA tag
- `ghcr.io/st-gr/openshell-gateway:latest` — moving tag (only updated when pushing to main)

**Risks:** the merge commit picks up everything between origin/main and upstream/main. If anything in those 40 commits breaks the gateway behavior we depend on, fork main is what holds it. Mitigation: the `:latest` we replace is already broken; this can't be worse for the cluster, and the new SHA tag is what we'll pin in Helm so the moving `:latest` is decorative.

**Pre-push verification options** (none of which catch the runtime issues that caused this rebuild in the first place — those would only surface in cluster):

```sh
# fork dev container — runs in container per memory rule
cd /Users/grundmanns/Documents/repos/acode/openshell-fork
mise run pre-commit                            # cargo fmt + clippy + tests
# OR minimum viable check:
cargo build --release -p openshell-server      # native arm64 build, doesn't catch amd64-specific bugs
```

## Helm values change

Once we have the new digest (either path), update `deploy/helm/openshell-driver-kyma/values.yaml:160`:

```yaml
gateway:
  image:
    repository: ghcr.io/st-gr/openshell-gateway
    tag: "sha256:<NEW-DIGEST>"        # ← was "latest"
    pullPolicy: IfNotPresent          # OK now that tag is digest-pinned
```

`_helpers.tpl:77-83` already supports digest pinning — when `tag` starts with `sha256:`, it renders `repo@sha256:...`.

## Rollout

```sh
kubectl set image deploy/ods-openshell-driver-kyma \
    -n openshell-system \
    gateway=ghcr.io/st-gr/openshell-gateway@sha256:<NEW-DIGEST>     # ← REQUIRES USER APPROVAL (cluster write)
kubectl rollout status deploy/ods-openshell-driver-kyma -n openshell-system
```

Or `helm upgrade ods` once `values.yaml` is committed.

## Verification

After rollout, recreate the sandbox and confirm phase reaches Ready:

```sh
openshell sandbox delete claude-files          # cleanup stuck instance
openshell sandbox create --name claude-files --from ghcr.io/st-gr/sandbox-claude:latest \
    --provider claude-code --auto-providers --policy ./claude-policy.yaml -- sleep infinity
# Should hit Ready in ~30s (vs stuck at Unspecified before)
openshell sandbox list                          # PHASE column should be "Ready"
```

If phase still doesn't progress, the bug is in a different code path than #1565/#1765 and we need to dig further.

## Why this is NOT a PR #1703 code change

PR #1703's branch (`upstream-pr/external-compute-driver-socket`) only touches:
- `crates/openshell-core/src/config.rs` — `External(PathBuf)` variant
- `crates/openshell-server/src/cli.rs` — `--compute-driver-socket` flag
- `crates/openshell-server/src/config_file.rs` — file plumbing
- `crates/openshell-server/src/compute/mod.rs::connect_external_compute_driver` — UDS dispatch
- `crates/openshell-server/src/lib.rs` — match arm
- `architecture/compute-runtimes.md` — docs

Phase derivation lives in `compute/mod.rs::derive_phase` and `apply_sandbox_update_locked`. Those weren't modified by PR #1703, and the upstream fixes are already merged separately. Squeezing them into #1703 would expand scope and confuse the named-driver-endpoint refactor elezar asked for.

**Recommendation:** keep the rebuild as a fork-internal deployment refresh; PR #1703 stays focused on elezar's named-endpoint feedback.
