**What a real incompatibility looks like** (exercised 2026-08-05 with a
deliberately broken driver, not guessed):

The gateway container fails to start, crashloops, and `helm install --wait`
times out. The smoke reports:

```
=== installing the chart (gateway sha256:...)
Error: INSTALLATION FAILED: context deadline exceeded
FAIL: helm install failed
--- pods ---
ods-openshell-driver-kyma-...  1/2  CrashLoopBackOff
--- gateway log ---
... Compute driver connected  configured_driver=kyma advertised_driver=kyma
Error: × execution error: failed to create compute runtime: <the driver's error>
```

So a contract break surfaces at the **helm install** step, before any ASSERT
runs. Look at the `--- gateway log ---` block in the failure output: the line
after "Compute driver connected" names the actual cause.

Two traps this exercise exposed, worth knowing before you debug:

- **"Compute driver connected" is not proof the contract is satisfied.** The
  gateway logs it *before* calling `GetGatewayListenerRequirements`
  (`openshell-server/src/compute/mod.rs:608` vs `:617`). A driver that breaks
  that RPC still produces the line, then kills the gateway a moment later.
- **`gateway_ref=v0.0.91` is NOT a negative test.** It passes, because the
  driver is genuinely backward compatible: v0.0.97 only *added* an RPC, and an
  older gateway never calls it. Verified — the smoke is green against v0.0.91
  and v0.0.99 alike. To exercise the failure path, break the driver on a
  scratch branch and dispatch the smoke against that branch instead.

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

1. **Install the Claude Code GitHub App on this repository:**
   <https://github.com/apps/claude>

   This is separate from the token and BOTH are required. The action fetches
   a GitHub OIDC token, then exchanges it for an app token; without the App
   installed the exchange returns:

   ```
   App token exchange failed: 401 Unauthorized - Claude Code is not installed
   on this repository.
   ```

   It fails at auth, before Claude runs, so a missing App costs no
   subscription tokens — it just means the Sunday job never does anything.
   Verify by dispatching `upstream-sync` manually; you cannot check the
   installation with a normal `gh` token (the API needs an app-authorised
   one).

2. `claude setup-token` locally; store as `CLAUDE_CODE_OAUTH_TOKEN` via
   `gh secret set`. Record the expiry above.
3. Keep repository hardening in place:
   ```bash
   gh api repos/st-gr/openshell-driver-kyma/actions/permissions/workflow \
     --jq '{default_workflow_permissions, can_approve_pull_request_reviews}'
   # expect: {"can_approve_pull_request_reviews": false,
   #          "default_workflow_permissions": "read"}
   ```
4. Leave **"Send write tokens to workflows from pull requests" off.** Enabling
   it would give fork PRs a writable `GITHUB_TOKEN`.
5. **Turn on branch protection for `main`, requiring changes to go through a
   pull request.** As of this writing (recheck with the commands in step 5b
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
  One-time setup step 5b, since this is a fact about live repo
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
  (see One-time setup, step 5). That is what would turn "the sync job only
  pushes to its own branch" from a convention in the code into an actual
  guarantee GitHub enforces regardless of what the `Bash` tool does. This is
  a known, bounded limitation with a clear fix, not something to be alarmed
  about — but until that step is done, do not casually add more tools or
  more permissions to the sync step without re-checking this reasoning
  still holds.
