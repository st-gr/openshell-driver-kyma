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
| `upstream-sync` | Sundays 03:00 UTC; manual | `CLAUDE_CODE_OAUTH_TOKEN` |

`upstream-sync` invokes Claude **only** when the protos are behind, the
pinned image digests are stale, or the interop smoke failed. Most Sundays it
is a green no-op costing no tokens.

## Situations

### Sunday PR is green

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

### Sunday PR is a draft

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

The signature of a real incompatibility should be recorded here once the
must-fail guard has actually been exercised against a known-broken gateway.
That has not happened yet — it requires `interop-smoke.yml` to be present on
the default branch first. When you run it, capture the exact failing
assertion and its message and replace this paragraph with it:

```bash
gh workflow run interop-smoke.yml -f gateway_ref=v0.0.91
```

> **TODO:** run the command above once these workflows are merged, then
> paste the `ASSERT n: ...` line and failure message from the run log here.

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

Token created: **TODO — fill in from the `claude setup-token` run that set
the current secret** · Expires: **TODO — same run**

`claude setup-token` prints both dates when it runs; neither is recoverable
from `gh secret list` after the fact (it only reports when the secret value
was last written, not the token's own expiry), so record them here at
rotation time or you will have to rotate blind next time this section is
consulted.

Update those dates here whenever you rotate. The job fails loudly on an
expired token by design: a silently-dead weekly check is worse than none,
because you would believe you were covered.

### Job reports an infrastructure flake

`kind` or CRD setup failed rather than an assertion. Re-run. Escalate only if
it repeats — infra failures are reported distinctly from incompatibilities so
a flake never reads as an upstream break.

### Nothing has happened for weeks

**Expected.** No PR means nothing moved. Confirm liveness rather than assuming:

```bash
gh run list --workflow=upstream-sync.yml --limit 5
```

You should see a green run each Sunday. Silence that means "broken" being read
as silence that means "fine" is the exact failure that let the protos drift
for two months.

## One-time setup

1. `claude setup-token` locally; store as `CLAUDE_CODE_OAUTH_TOKEN` via
   `gh secret set`. Record the expiry above.
2. Keep repository hardening in place:
   ```bash
   gh api repos/st-gr/openshell-driver-kyma/actions/permissions/workflow \
     --jq '{default_workflow_permissions, can_approve_pull_request_reviews}'
   # expect: {"can_approve_pull_request_reviews": false,
   #          "default_workflow_permissions": "read"}
   ```
3. Leave **"Send write tokens to workflows from pull requests" off.** Enabling
   it would give fork PRs a writable `GITHUB_TOKEN`.
4. **Turn on branch protection for `main`, with required pull-request
   reviews.** As of this writing it is not on:
   ```bash
   gh api repos/st-gr/openshell-driver-kyma/branches/main/protection --jq '{
     required_signatures, enforce_admins, required_linear_history,
     allow_force_pushes, allow_deletions
   }'
   gh api repos/st-gr/openshell-driver-kyma/rulesets --jq 'length'
   ```
   The only things currently blocked are force-pushes and deletions — there
   is no required review and no ruleset. See the "do not commit/push" bullet
   under Security notes below for why this specific gap matters here:
   without it, "the sync job only pushes to its own branch" is a property of
   the workflow's own steps, not something GitHub enforces. Adding a required
   review on `main` converts it into an actual guarantee.

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
  `GITHUB_TOKEN` — verified live: `main` has no required pull-request
  reviews and no ruleset (`gh api repos/st-gr/openshell-driver-kyma/branches/main/protection`
  blocks only force-pushes and deletions; `gh api .../rulesets` returns
  `[]`). A misbehaving or successfully-injected run could push straight to
  `main`.

  The controls that ARE real today: every sync PR is reviewed by a human
  before merge (repo-level `allow_auto_merge` is `false` and nothing in this
  repo auto-merges), and `--max-turns 40` bounds how much the step can do in
  one run. Neither of those depends on the branch-only behaviour holding.

  **Remedy:** turn on branch protection for `main` with required
  pull-request reviews (see One-time setup, step 4). That is what would turn
  "the sync job only pushes to its own branch" from a convention in the code
  into an actual guarantee GitHub enforces regardless of what the `Bash`
  tool does. This is a known, bounded limitation with a clear fix, not
  something to be alarmed about — but until that step is done, do not
  casually add more tools or more permissions to the sync step without
  re-checking this reasoning still holds.
