# Runbook: weekly upstream-compatibility sync

Maintainer documentation for `.github/workflows/upstream-sync.yml` and
`.github/workflows/interop-smoke.yml`.

**Not for driver users.** Do not link this from `docs/tutorial-anthropic-direct.md`
or `docs/getting-started.md` — those are for someone installing the driver,
who has no use for CI internals.

## What runs, and when

| Workflow | Trigger | Holds secrets? |
|---|---|---|
| `interop-smoke` | called by `branch-checks` on every PR; manual | **no** |
| `upstream-sync` | **Mondays 09:30 UTC**; manual | `CLAUDE_CODE_OAUTH_TOKEN` |

`upstream-sync` invokes Claude **only** when the protos are behind, the
pinned image digests are stale, or the interop smoke failed. Most weeks it
is a green no-op costing no tokens.

## Situations

### Weekly PR is green

Review the diff as you would any PR — pay attention to whatever upstream
added, since that is the part Claude wrote from scratch. Merge.

Then **roll out to the cluster manually.** CI holds no cluster credentials, so
this step is never automated:

```bash
helm -n openshell-system upgrade ods deploy/helm/openshell-driver-kyma \
  --reuse-values \
  --set image.tag=sha256:<new driver digest> \
  --set gateway.image.tag=sha256:<new gateway digest> \
  --set driver.supervisorImage=ghcr.io/nvidia/openshell/supervisor@sha256:<new supervisor digest>
```

Pass all three explicitly. `--reuse-values` carries forward the **old chart's**
defaults, so a changed default in `values.yaml` is silently ignored — this has
already happened once, where the driver kept injecting `supervisor:latest`
after an upgrade that appeared to succeed.

Verify:

```bash
kubectl -n openshell-system get deploy ods-openshell-driver-kyma \
  -o jsonpath='{range .spec.template.spec.containers[*]}{.name}: {.image}{"\n"}{end}'
openshell sandbox exec --name <sandbox> -- claude -p --model claude-opus-4-7 "Reply with exactly OK"
```

### Weekly PR is a draft

The PR body's "Local gate" row tells you the gate failed (it only ever renders
`passed` or `FAILED — see the 'Run the full gate' step`; it cannot tell you
*why*). To find out whether Claude hit `--max-turns` mid-task or finished but
left the gate red, read the "Let Claude perform the sync" step's log in the
run — a turn-cap cutoff ends abruptly mid-transcript, a completed-but-failing
attempt runs to the end of the prompt and then the separate "Run the full
gate" step reports the failure. Finish it by hand or close it — do not merge
a draft.

### Interop smoke red, protos unchanged

The interesting case: a behavioural break upstream with no proto diff. Decide:

- fix forward (usually a driver change), or
- pin `GATEWAY_REF` to the last good version to unblock PRs while you work.

**What a real incompatibility looks like** (exercised 2026-08-05 with a
deliberately broken driver, not guessed):

The gateway container fails to start, crashloops, and `helm install --wait`
times out:

```
Error: INSTALLATION FAILED: context deadline exceeded
FAIL: helm install failed
--- pods ---
ods-openshell-driver-kyma-...  1/2  CrashLoopBackOff
--- gateway log ---
... Compute driver connected  configured_driver=kyma advertised_driver=kyma
Error: × execution error: failed to create compute runtime: <the driver's error>
```

A contract break surfaces at the **helm install** step, before any ASSERT
runs. Read the `--- gateway log ---` block: the line after "Compute driver
connected" names the cause.

Two traps this exposed:

- **"Compute driver connected" does not prove the contract is satisfied.**
  The gateway logs it *before* calling `GetGatewayListenerRequirements`
  (`openshell-server/src/compute/mod.rs:608` vs `:617`). A driver that breaks
  that RPC still emits the line, then kills the gateway moments later.
- **`gateway_ref=v0.0.91` is NOT a negative test.** It passes: v0.0.97 only
  *added* an RPC and an older gateway never calls it, so the driver is
  genuinely backward compatible. Verified green against v0.0.91 and v0.0.99
  alike. To exercise the failure path, break the driver on a scratch branch
  and dispatch the smoke against that branch.

### Unrelated PRs suddenly red after an upstream release

Upstream is broken. Pin, and record why:

```bash
# .github/upstream-compat.env
GATEWAY_REF=v0.0.NN   # last known good
```

Commit with a message saying what upstream broke. **Revert as soon as upstream
is fixed** — leaving the pin in place silently reintroduces the two-month
drift this automation exists to prevent.

### Job fails with an authentication error

`CLAUDE_CODE_OAUTH_TOKEN` has expired.

```bash
claude setup-token
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo st-gr/openshell-driver-kyma
```

Token created: **2026-08-05** · Expires: **2026-08-05 + 1 year (2027-08-05)**

Put a calendar reminder a couple of weeks before that date. An expired token
fails the job loudly by design, but "loudly" still means a red run nobody is
watching at 09:30 UTC on a Monday.

`claude setup-token` prints both dates when it runs; neither is recoverable
from `gh secret list` after the fact (it only reports when the secret value
was last written, not the token's own expiry), so record them here at
rotation time or you will have to rotate blind next time this section is
consulted.

Update those dates here whenever you rotate. The job fails loudly on an
expired token by design: a silently-dead weekly check is worse than none,
because you would believe you were covered.

### Job fails but every step looks green

Seen 2026-08-09. The step list shows Claude, the gate and the PR step all
succeeded, and only "Fail the job if the sync did not complete cleanly" is red.

**The step list is lying to you.** `continue-on-error: true` on the Claude step
means GitHub reports its *conclusion* as success while its *outcome* — what the
guard actually tests — was failure. Read the guard's message: it prints
`claude=<outcome> gate=<outcome>`.

**Then read the Claude step's log, not its status.** The telltale signature of
a subscription usage limit:

```
"is_error": true,
"duration_ms": 381,
"num_turns": 1,
"total_cost_usd": 0
```

One turn, sub-second, zero cost — Claude was refused before doing any work.
Nothing in this repository is broken. **Re-dispatch after the quota resets**
(1:00 AM America/Los_Angeles). The schedule already targets Monday 09:30 UTC
for that reason.

Contrast with a genuine cutoff, which spends real money and turns:
`subtype: error_max_turns`, `num_turns: 41`, `total_cost_usd: 1.40`. That one
needs a higher `--max-turns` or a smaller task — not a retry.

Note the gate no longer runs when Claude fails. It used to, and it passed —
because an untouched tree naturally passes fmt/clippy/test. That "success" said
nothing about the sync and made this failure harder to read.

### Job reports an infrastructure flake

`kind` or CRD setup failed rather than an assertion. Re-run. Escalate only if
it repeats — infra failures are reported distinctly from incompatibilities so
a flake never reads as an upstream break.

### Nothing has happened for weeks

**Expected.** No PR means nothing moved. Confirm liveness rather than assuming:

```bash
gh run list --workflow=upstream-sync.yml --limit 5
```

You should see a green run each Monday. Silence that means "broken" being read
as silence that means "fine" is the exact failure that let the protos drift
for two months.

## One-time setup

1. **No Claude GitHub App is needed.** `upstream-sync.yml` passes
   `github_token` to `claude-code-action`; `action.yml` documents that input
   as "optional if using GitHub App" — the App is the *alternative* to a
   token, not a prerequisite.

   Omit it and the action tries to exchange its OIDC token for a Claude-App
   token, failing with `Claude Code is not installed on this repository`.
   Installing the App instead steers a personal account into Claude org
   settings that demand a Team/Enterprise plan. Don't; keep passing the token.

   The job also needs `id-token: write` (already set), or it fails earlier
   with `Could not fetch an OIDC token`.

2. `claude setup-token` locally; store as `CLAUDE_CODE_OAUTH_TOKEN` via
   `gh secret set`. Record the expiry above.
3. Keep repository hardening in place:
   ```bash
   gh api repos/st-gr/openshell-driver-kyma/actions/permissions/workflow \
     --jq '{default_workflow_permissions, can_approve_pull_request_reviews}'
   # expect: {"can_approve_pull_request_reviews": true,
   #          "default_workflow_permissions": "read"}
   ```

   `can_approve_pull_request_reviews` must be **true**, despite the name. The
   single GitHub toggle "Allow GitHub Actions to create and approve pull
   requests" governs both creating and approving. With it off, the sync job
   does all its work, pushes the branch, then dies on the final step with
   `GitHub Actions is not permitted to create or approve pull requests` —
   which is exactly what happened on 2026-08-05.

   Trade-off: it also lets Actions *approve* PRs. Harmless while `main`
   requires no reviews. **If you enable required-review branch protection
   (step 5), revisit this** — Actions could otherwise self-approve through it.
   `default_workflow_permissions` stays `read`; only the sync job escalates,
   and only to `contents` / `pull-requests` / `id-token`.
4. Leave **"Send write tokens to workflows from pull requests" off.** Enabling
   it would give fork PRs a writable `GITHUB_TOKEN`.
5. **Turn on branch protection for `main`, requiring changes to go through a
   pull request.** As of this writing (recheck with the commands in step 4b
   below if you're reading this later) it is not on — the only things
   currently blocked are force-pushes and deletions; there is no required
   review and no ruleset. See the "do not commit/push" bullet under Security
   notes below for why this specific gap matters here: without it, "the sync
   job only pushes to its own branch" is a property of the workflow's own
   steps, not something GitHub enforces.

   **4a. Enable it:**
   ```bash
   gh api --method PUT repos/st-gr/openshell-driver-kyma/branches/main/protection \
     --input - <<'JSON'
   {
     "required_status_checks": null,
     "enforce_admins": false,
     "required_pull_request_reviews": { "required_approving_review_count": 0 },
     "restrictions": null
   }
   JSON
   ```
   Use `required_approving_review_count: 0`, **not `1`.** This is a
   single-maintainer repo: GitHub will not let a PR author approve their own
   PR, so a count of `1` with no second reviewer to call on locks the
   maintainer out of merging their own work. A count of `0` still forces
   every change onto a pull request — which is the actual control we want,
   since it blocks a direct `git push origin main` using the workflow's
   token — while leaving the maintainer free to merge their own PRs
   unaided. Do not "harden" this to `1` later without first adding a second
   reviewer, or you will lock yourself out.

   `enforce_admins: false` is deliberate too: it leaves the repo admin
   (i.e. the maintainer) an escape hatch to push directly in a genuine
   emergency. Setting it `true` would apply the pull-request requirement to
   the maintainer as well, with no override.

   **4b. Verify it took effect:**
   ```bash
   gh api repos/st-gr/openshell-driver-kyma/branches/main/protection --jq '{
     required_signatures, enforce_admins, required_linear_history,
     allow_force_pushes, allow_deletions
   }'
   gh api repos/st-gr/openshell-driver-kyma/rulesets --jq 'length'
   ```

## Security notes

- `interop-smoke.yml` must never gain a secret. It runs on fork PRs, and its
  safety rests on having nothing to steal.
- `upstream-sync.yml` must never use `pull_request_target` or `issue_comment`.
  Both run in base-repository context with secrets while taking outside input.
  An `@claude`-on-comment trigger would hand subscription access to anyone who
  can comment.
- The residual risk is **prompt injection**, not credential theft: Claude reads
  upstream release notes and diffs while holding branch write access. The
  prompt frames fetched content as data, writes are branch-only, and turns are
  capped — but the mitigation that actually matters is **you reviewing the
  PR before merging.**
- **The "do not commit/push/open a PR" instruction is a soft control.** The
  `sync` job's "Let Claude perform the sync" step grants `contents: write`
  and `pull-requests: write` at the job level and gives that step `Bash`
  among its allowed tools. The prompt tells Claude not to commit, push, or
  open a pull request — a later, separate step does that deterministically —
  but nothing structurally stops the `Bash` tool from running `git commit` or
  `git push` itself: `actions/checkout` leaves credentials for `GITHUB_TOKEN`
  configured in git, and the job's own token has write scope. This is a
  prompt-level constraint, not a permissions-level one.

  That the workflow's own steps only ever commit and push to
  `upstream-sync/<tag>-<run-id>` is a property of the code as written, **not
  a control that's enforced.** Nothing currently stops the `Bash` tool from
  running `git checkout main && git push origin main` with the same
  `GITHUB_TOKEN`. **As of this writing** — recheck with the commands in
  One-time setup step 4b, since this is a fact about live repo
  configuration and not this document: `main` has no required pull-request
  reviews and no ruleset (`gh api repos/st-gr/openshell-driver-kyma/branches/main/protection`
  blocks only force-pushes and deletions; `gh api .../rulesets` returns
  `[]`). A misbehaving or successfully-injected run could push straight to
  `main`.

  The controls that ARE real today, also as of this writing: a human must
  actively merge every sync PR (repo-level `allow_auto_merge` is `false`,
  and nothing in this repo auto-merges) — note that this only proves a
  human has to *trigger* the merge, not that a review happened, since
  branch protection does not yet require one; and `--max-turns 40` bounds
  how much the step can do in one run. Neither of those depends on the
  branch-only behaviour holding. Once One-time setup step 4 is done,
  merging will also require going through a pull request by construction,
  which makes the first of these two controls meaningfully stronger.

  **Remedy:** turn on branch protection for `main`, requiring pull requests
  (see One-time setup, step 4). That is what would turn "the sync job only
  pushes to its own branch" from a convention in the code into an actual
  guarantee GitHub enforces regardless of what the `Bash` tool does. This is
  a known, bounded limitation with a clear fix, not something to be alarmed
  about — but until that step is done, do not casually add more tools or
  more permissions to the sync step without re-checking this reasoning
  still holds.
