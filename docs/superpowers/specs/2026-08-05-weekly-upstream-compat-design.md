# Weekly upstream-compatibility automation — design

**Date:** 2026-08-05
**Status:** approved, not yet implemented

## Problem

`openshell-driver-kyma` implements NVIDIA OpenShell's `ComputeDriver` gRPC
contract. Upstream moves faster than this repo notices.

The vendored protos sat at `v0.0.91` for two months while upstream reached
`v0.0.97`. Nothing was broken, but only by luck: the two wire-level changes in
that window happened to be ones this deployment never exercised. Confirming
that took reading upstream's gateway source by hand to establish that
`Unimplemented` is mapped to an empty list rather than treated as an error.

`scripts/check-proto-drift.sh` now reports when upstream is ahead, but it is
only run when someone remembers to run it, and it compares *files*. A file
comparison cannot answer the question that actually matters.

### The goal is outward-facing

The requirement is not "keep the operator's cluster working". It is:

> **Anyone running the latest upstream OpenShell must be able to use this
> driver.**

That is a stronger claim, and a proto diff does not establish it. Syncing the
pin proves the driver *compiles* against latest protos. It does not prove a
real latest gateway *accepts* it. The gap between those two statements is
exactly where the v0.0.97 uncertainty lived.

### Bleeding edge is the default

This repo tracks upstream head. Pinning to an older gateway is an exception,
used only when upstream itself is broken, and it is recorded in version
control rather than in someone's memory.

## Solution overview

A scheduled job every Sunday that checks four upstream surfaces, proves
compatibility against a **real** latest gateway, and — when something moved —
invokes Claude Code (on the operator's Max subscription) to perform the sync
and open a pull request.

Feasibility is established:

- The Claude Code GitHub Action supports subscription auth via a
  `CLAUDE_CODE_OAUTH_TOKEN` secret produced by `claude setup-token`. No API
  key and no console billing.
- `anthropics/claude-code-action@v1` runs in automation mode on any trigger,
  including `schedule`.
- Detection largely exists already: `scripts/check-proto-drift.sh` and
  `scripts/vendor-proto.sh`.

## Architecture

```
.github/workflows/
  interop-smoke.yml    reusable (workflow_call), input: gateway_ref
  upstream-sync.yml    Sunday cron + workflow_dispatch
  branch-checks.yml    existing; gains a call to interop-smoke

.github/upstream-compat.env    the one knob (see below)
```

### The knob

```ini
# .github/upstream-compat.env
# Gateway version the interop smoke tests against.
#   latest      = track bleeding edge (default, preferred)
#   v0.0.NN     = ONLY when upstream is broken and blocking PRs.
#                 Revert as soon as upstream is fixed.
GATEWAY_REF=latest
```

Both workflows read it. `latest` is the steady state. Flipping it to a version
is a reviewable one-line commit, so "upstream was broken during this window"
becomes a fact in history rather than tribal knowledge.

#### What `latest` resolves to

`latest` means **the newest upstream semver release tag** (`vN.N.NN`),
discovered with `git ls-remote --tags` — the mechanism
`latest_upstream_tag()` in `scripts/proto-lib.sh` already uses. It explicitly
does **not** mean the mutable `:latest` container tag.

That distinction is not pedantic. The supervisor image tracked `:latest` until
chart 0.3.0 and moved twice in one week, silently handing every new sandbox an
unreviewed privileged binary. A compatibility job that resolved `latest`
through a mutable tag would inherit exactly that failure mode, and would not
be reproducible across re-runs.

Once resolved to a tag, the workflow resolves that tag to an **immutable
digest** before `helm install`. Re-running the same commit therefore tests the
same bytes, and the digest is what any resulting PR writes into
`values.yaml`.

**Accepted tradeoff:** while `GATEWAY_REF=latest`, an upstream release that
breaks the contract turns unrelated PRs red. This is the cost of tracking
bleeding edge and is accepted deliberately. The knob is the remedy, and
flipping it takes one commit.

This differs from `check-proto-drift.sh`, which deliberately compares against
the *pinned* ref and never fails on an upstream release. That asymmetry is
intentional: the drift script guards the vendored files, where surprise
failures help nobody; the interop smoke guards the compatibility promise,
where a surprise failure is the whole point.

### Two pins, related but distinct

| Pin | Lives in | Means |
|---|---|---|
| proto ref | `proto/UPSTREAM.lock` | which upstream the protos are vendored from |
| gateway ref | `.github/upstream-compat.env` | which gateway the smoke tests against |

In steady state both track latest and converge. They diverge only between an
upstream release and the sync PR merging — and detecting that divergence is
the job's purpose.

## Component 1: `interop-smoke.yml`

Reusable workflow. Input: `gateway_ref`. Called by `branch-checks` (every PR)
and by `upstream-sync` (Sunday). Both pass the value from
`.github/upstream-compat.env`.

```
1. kind create cluster
2. kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/\
     agent-sandbox/main/k8s/crds/agents.x-k8s.io_sandboxes.yaml
3. kubectl create ns openshell-system
   kubectl label ns openshell-system \
     pod-security.kubernetes.io/enforce=privileged
4. docker build -f deploy/Dockerfile  ->  kind load docker-image
5. helm install ods deploy/helm/openshell-driver-kyma \
     --set gateway.enabled=true \
     --set gateway.image.tag=<gateway_ref resolved to a digest> \
     --set image.tag=<locally built>
6. uv tool install openshell==<latest>
7. assertions
8. kind delete cluster   (always, including on failure)
```

Steps 2 and 3 satisfy preconditions the chart already encodes: the
`pre-install-crd-check` Job aborts the install without the CRD, and the driver
refuses to start without the PSA label.

Step 5 installs the **actual Helm chart** rather than hand-assembling gateway
arguments. This avoids a second copy of the gateway configuration drifting
out of sync with `templates/deployment.yaml`, and it exercises the path a
third party would actually take — which is the thing being safeguarded.

Step 6 installs the current CLI, so the CLI surface is covered by the same
assertions rather than needing its own check.

### Assertions

1. **`openshell status` reports Connected, the gateway version, and driver
   `kyma`.** Load-bearing. Reaching it proves the gateway completed
   `GetCapabilities` *and* got a tolerable answer to
   `GetGatewayListenerRequirements` — a non-`Unimplemented` error there aborts
   driver initialisation (`openshell-server/src/compute/mod.rs:588`). A broken
   contract cannot produce a Connected status.
2. **A Sandbox CR appears, named `default--<name>`, carrying all six identity
   labels** (`sandbox-id`, `sandbox-name`, `sandbox-namespace`,
   `sandbox-workspace`, `managed-by`, `kagenti.io/type`). Catches naming and
   label regressions that would make the gateway lose track of sandboxes.
3. **No `ERROR` in gateway or driver logs.**
4. **`openshell sandbox list` round-trips the bare name**, proving the gateway
   resolves what the driver created.

### Two implementation constraints

- **`openshell sandbox create` blocks and does not return**, even after the
  sandbox is Ready. The smoke runs it backgrounded and polls `kubectl` for the
  CR. A naive run-and-wait hangs until the job timeout.
- **The smoke stops at "CR created", not "pod Ready".** Reaching Ready needs
  the supervisor running privileged with `SYS_ADMIN` and netns setup inside
  kind-in-Docker. That is the fragile part, and a weekly job that cries wolf
  gets ignored — costing more than the coverage gains.

## Component 2: `upstream-sync.yml`

Sunday 03:00 UTC, plus `workflow_dispatch`.

```
1. check-proto-drift.sh                              (script, no LLM)
2. resolve newest release tag -> immutable digests for
   gateway + supervisor; newest openshell CLI version (script)
3. interop smoke vs GATEWAY_REF                      (kind + chart)

nothing moved AND smoke green  ->  exit 0. No PR, no tokens.
anything moved OR smoke red    ->  invoke Claude with the evidence
                                   -> sync, verify, open PR
```

Claude is invoked only when steps 1–3 found something, so token spend tracks
how often upstream actually moves rather than how often the cron fires.

**Input handed to Claude:** drift-check output, the proto diff, the smoke's
failure log if it failed, the new digests, and the upstream release notes
between the two refs.

**Work requested:** re-vendor via `make proto-vendor`, make it compile,
implement whatever the contract added, fix tests, update digests in
`values.yaml`, bump versions, write the CHANGELOG entry.

Release notes are the one surface no script can judge, which is why they are
read at this point rather than checked mechanically in step 1.

### Guardrails

- **No push to `main`, ever.** Work happens on a branch; output is a PR.
- **`--max-turns` capped.** On cap, opens a *draft* PR with partial work and a
  note on where it stopped.
- **No cluster credentials in CI.** The runner touches a throwaway `kind`
  cluster only. The real Kyma cluster, gateway endpoint, and API keys are
  never in reach.
- **`proto/` must not be hand-edited.** The prompt directs Claude through
  `make proto-vendor`. Hand-editing vendored protos is exactly what
  `check-proto-drift.sh` catches — and it would catch Claude too.
- **Concurrency group**, so a long run cannot overlap the next.

### What a green PR does and does not mean

A green PR means: the driver compiles, its tests pass, and a real latest
gateway completed the handshake.

It does **not** mean the sandbox reaches Ready on a real Kyma cluster. That
still requires a manual `helm upgrade` and inference check. This job narrows
what must be verified by hand; it does not eliminate it.

## Auth and secrets

| Secret | Source | Used for |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | `claude setup-token` locally | Claude, on the Max subscription |
| `GITHUB_TOKEN` | built-in, no setup | branch push + PR creation |

Neither is a Personal Access Token, satisfying the standing no-PATs-in-CI
rule. GitHub permissions required: `contents: write`, `pull-requests: write`.

**Exactly one of these is a repository secret you maintain.** `GITHUB_TOKEN`
is minted automatically for each workflow run and expires when the job ends —
nothing to create, store, or rotate. `CLAUDE_CODE_OAUTH_TOKEN` is created once
with `claude setup-token` and **does expire**; its expiry date is recorded in
the runbook at setup time so renewal is a calendar item rather than a
surprise, and an expired token fails the job loudly rather than silently.

### GITHUB_TOKEN does not trigger downstream workflows

GitHub deliberately suppresses workflow triggers for events raised by
`GITHUB_TOKEN`, to prevent recursion. A PR opened by this job will **not**
auto-run `branch-checks`.

**Resolution: run the full gate inline before opening the PR.** The job
already runs `fmt`, `clippy`, the test suite, and the interop smoke to know
whether the sync worked, so the PR is pre-verified on arrival. Coverage is
equivalent; the PR simply shows no check marks. Closing and reopening it
triggers `branch-checks` if the badges are wanted.

Rejected alternative: a custom GitHub App token via
`actions/create-github-app-token`, which would make PRs behave like human ones
and trigger everything. Costs an App registration and two more secrets for no
additional verification. Available as a later upgrade if the missing check
marks prove annoying in review.

## Security model

The concern: this repo is public, so anyone can open a pull request. A weekly
job holding a subscription credential must not become a way to steal it.

### Safe by construction, not by policy

| Workflow | Secrets it holds | Fork-triggerable? |
|---|---|---|
| `interop-smoke.yml` | **none** | yes — and there is nothing to steal |
| `branch-checks.yml` | none | yes |
| `upstream-sync.yml` | `CLAUDE_CODE_OAUTH_TOKEN` | **no** |

The important property is the first row: the interop smoke needs no secrets
whatsoever. It builds an image, runs `kind`, installs the chart. Its safety
does not depend on GitHub's fork rules holding.

`upstream-sync.yml` is the only workflow with the Claude token, and it runs
only on `schedule` and `workflow_dispatch`. Scheduled workflows always execute
from the **default branch**, so a pull request that modifies that file cannot
cause the modified version to run until it is merged. `workflow_dispatch`
requires write access.

### Prohibited triggers

`upstream-sync.yml` must **never** use `pull_request_target` or
`issue_comment`. Both run in the base-repository context *with* secrets while
being influenced by outside input — `pull_request_target` by fork code,
`issue_comment` by anyone who can type `@claude`. Neither appears in this repo
today, and this design does not introduce them. Adding an `@claude`-on-comment
trigger would hand subscription access to any commenter.

### Defence in depth

GitHub does not pass repository secrets to workflows triggered by a fork pull
request, and grants those runs a read-only `GITHUB_TOKEN`
(<https://docs.github.com/en/actions/reference/security/secure-use>). This
backstops the structural argument above rather than carrying it.

Repository hardening to keep in place:

- default workflow permissions `read` (already set), with `contents: write`
  and `pull-requests: write` requested explicitly in `upstream-sync.yml` only,
  where the escalation is visible in the file and reviewable
- "Send write tokens to workflows from pull requests" left **off** — enabling
  it would defeat the read-only guarantee for fork PRs
- "Approve pull request reviews" left off (already set)

### Residual risk: prompt injection

The real exposure is not credential theft but **prompt injection from
upstream**. On Sunday, Claude reads upstream release notes, proto diffs, and
smoke logs — content this repository does not control — while holding write
access to a branch. A compromised or malicious upstream release note could
contain text crafted as instructions.

Bounded by the existing guardrails, which exist for this reason as much as for
runaway-loop protection:

- branch-only; `main` is never written
- every sync PR is reviewed by a human before merge
- `--max-turns` capped
- no cluster credentials on the runner, so the blast radius stops at a PR
- fetched upstream content is to be framed in the prompt as **data to
  analyse, never as instructions to follow**

This is a real risk that is mitigated, not eliminated. The mitigation that
actually matters is the human review gate.

## Failure handling

| Condition | Behaviour |
|---|---|
| Upstream unreachable | Log "unknown", exit 0. Never a false "up to date" — same rule as `check-proto-drift.sh`. |
| `CLAUDE_CODE_OAUTH_TOKEN` expired | **Fail loudly.** These tokens expire; a silently-dead weekly job is worse than none, because it implies coverage that is not there. |
| Claude hits `--max-turns` | Draft PR with partial work and a note on where it stopped. |
| Sync attempted, tests still red | Draft PR with the failing output in the body. The attempt is visible rather than discarded. |
| Smoke red against latest, protos unchanged | The interesting case: a behavioural break with no proto diff. Claude investigates, and either fixes it or opens an issue recommending `GATEWAY_REF` be set to the last good version. |
| `kind`/CRD infrastructure flake | Retry once, then fail as *infrastructure*, reported distinctly from a real incompatibility so a flake never reads as an upstream break. |

## Cost

Public repo, so runner minutes are free. Claude runs only in weeks where
something moved; the drift check and smoke are plain scripts. Expected to be a
handful of Claude invocations per year, well inside a Max subscription.

## Operational documentation

The automation is useless if the maintainer cannot tell what it wants from
them. A runbook is a **deliverable of this work**, not an afterthought:
`docs/internal/runbook-upstream-sync.md`.

It lives under `docs/internal/` because it is maintainer tooling. It must not
be cross-linked from the reader-facing tutorials
(`docs/tutorial-anthropic-direct.md`, `docs/getting-started.md`) — those are
for someone installing the driver, who has no use for CI internals.

The runbook covers, for each situation, what the maintainer does:

| Situation | What the maintainer does |
|---|---|
| Sunday PR is green | Review the diff, merge, then roll out to the cluster manually (`helm upgrade` + inference check). CI never touches the cluster. |
| Sunday PR is a **draft** | Claude hit `--max-turns` or could not get tests green. Body says where it stopped. Finish by hand or close it. |
| Smoke red, protos unchanged | Behavioural break upstream with no proto diff. Decide: fix forward, or set `GATEWAY_REF` to the last good version to unblock PRs. |
| PRs suddenly red after an upstream release | Upstream is broken. Set `GATEWAY_REF=v0.0.NN` (last good), commit, revert once upstream is fixed. This is the documented escape hatch. |
| Job fails with an auth error | `CLAUDE_CODE_OAUTH_TOKEN` expired. Re-run `claude setup-token`, update the secret, record the new expiry. |
| Job reports an infrastructure flake | `kind`/CRD failure, not an upstream break. Re-run. Escalate only if it repeats. |
| Nothing happened for weeks | Expected. No PR means nothing moved. Confirm liveness via the run history, which shows a green no-op each Sunday. |

It also records the setup steps, because they are one-time and easily
forgotten: generating the OAuth token, adding the secret, **noting its expiry
date**, and the repository hardening settings listed under Security model.

The "nothing happened" row matters more than it looks. The dangerous failure
of a weekly job is silence that means "broken" being read as silence that
means "fine" — the same failure that let the protos drift for two months. The
green no-op run is the liveness signal.

## Testing the automation itself

Both workflows expose `workflow_dispatch`, so they can be exercised on demand
rather than waiting a week to find a YAML typo.

Validation follows the both-directions rule used on the drift guard — prove it
passes when it should *and* fails when it should, before trusting it:

1. **Must pass:** run the smoke against the current pin, where the answer is
   already known to be green. Red here means the harness is wrong, not
   upstream.
2. **Must fail:** set `GATEWAY_REF=v0.0.91` while the protos sit at `v0.0.97`,
   and confirm a genuine mismatch is detected.
3. **Must not false-positive:** run `upstream-sync` when nothing has moved and
   confirm it exits 0 without invoking Claude and without opening a PR.

## Out of scope

- **Cluster rollout.** `helm upgrade` against the real Kyma cluster, and the
  `claude -p` inference check, stay manual. CI holds no cluster credentials by
  design.
- **Sandbox-Ready in the smoke.** See the constraint above.
- **Version-matrix testing** across latest / latest-1 / pinned. Stronger, but
  triples runtime to defend a support window nobody has asked for. Revisit if
  the driver gains outside users.
- **Auto-merge.** Every sync is reviewed by a human.
