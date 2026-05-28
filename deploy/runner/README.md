# Self-hosted GitHub Actions runner on Kyma

A static-IP-friendly GitHub Actions runner that lives inside the same
Kyma cluster as `your-llm-gateway`. Workflows tagged `runs-on: [self-hosted, kyma]`
execute on this runner, which can call the in-cluster Anthropic proxy
without needing GitHub's egress IPs in the proxy's allowlist.

## What you get

One Kubernetes namespace `gh-runner` containing:

- A `Secret` (`gh-runner-creds`) with two values: a GitHub PAT and the
  ANTHROPIC auth token. **Never committed to this repo** — created
  interactively via `make runner-create-secret`.
- A `ConfigMap` (`gh-runner-env`) with `ANTHROPIC_BASE_URL`,
  `ANTHROPIC_MODEL`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`.
- A `ConfigMap` (`gh-runner-entrypoint`) with a 50-line bash script
  that registers/runs/deregisters the runner. Mounted read-only at
  `/runner-entrypoint/entrypoint.sh`.
- A `NetworkPolicy` (`gh-runner-egress`) — default-deny ingress, egress
  scoped to `kube-system:53`, `your-llm-gateway:8080`, and `0.0.0.0/0:443`
  (with RFC1918 explicitly excluded).
- One `Deployment` per registered repo (`replicas: 1`, runs as UID 1001,
  PSA-restricted, drop ALL caps, seccomp RuntimeDefault).

The runner image is `ghcr.io/actions/actions-runner` — the same image
GitHub's official Actions Runner Controller uses. No third-party image
in the trust chain.

## Prerequisites

1. `kubectl` authenticated against the target Kyma cluster.
2. `gh` CLI authenticated as a user who can read the target repos.
3. A **classic** GitHub PAT with `repo` and `workflow` scopes. Mint at
   <https://github.com/settings/tokens/new>. Choose an expiration that
   matches your rotation policy (90 days is reasonable).
4. The `ANTHROPIC_AUTH_TOKEN` recognized by your `your-llm-gateway`
   deployment.

## First-time setup

Run from the repo root.

```bash
# Apply namespace, SA, ConfigMaps, NetworkPolicy.
make runner-deploy

# Create the credentials Secret. The Make target uses `read -rs` so
# tokens never enter shell history or argv.
make runner-create-secret

# Register a runner per repo.
make runner-add-repo OWNER=st-gr REPO=OpenShell
make runner-add-repo OWNER=st-gr REPO=openshell-driver-kyma
```

Verify each runner reports `Idle` in its repo's GitHub UI:
<https://github.com/OWNER/REPO/settings/actions/runners>.

Tail logs:

```bash
make runner-logs OWNER=st-gr REPO=OpenShell
```

Expect a final line like `Listening for Jobs`.

## Adding a new repo later

```bash
make runner-add-repo OWNER=<owner> REPO=<repo>
```

The Node.js script:

1. Validates the repo exists via `gh api repos/<owner>/<repo>`.
2. Renders `deploy/runner/deployment-template.yaml` by literal string
   substitution.
3. Writes the rendered manifest to
   `deploy/runner/deployments/<owner>-<repo>.yaml` (committed for
   reproducibility — contains no secrets, only `secretKeyRef` pointers).
4. Pipes the manifest to `kubectl apply`.

To preview without applying:

```bash
node scripts/add-runner-repo.js --owner <owner> --repo <repo> --dry-run
```

## Removing a repo

```bash
make runner-remove-repo OWNER=<owner> REPO=<repo>
```

The runner pod's SIGTERM trap deregisters itself from GitHub before the
container exits, so the `Settings → Actions → Runners` UI cleans up
automatically. The rendered manifest under `deploy/runner/deployments/`
is also removed; pass `--keep-file` to the script if you want to keep
the historical record.

## Updating credentials

```bash
make runner-create-secret      # interactively re-prompts for both tokens
kubectl -n gh-runner rollout restart deployment    # picks up new env
```

The runner's existing GitHub registration survives the restart because
each pod registers under a stable name (`runner-<owner>-<repo>`) with
`--replace`, which rebinds the same record to the new pod.

## Image upgrade policy

`deploy/runner/deployment-template.yaml` references
`ghcr.io/actions/actions-runner:latest` for ease of initial setup.
**Pin to a digest** before any production rollout.

```bash
docker pull ghcr.io/actions/actions-runner:latest
docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/actions/actions-runner:latest
# -> ghcr.io/actions/actions-runner@sha256:...
```

Edit `deployment-template.yaml`, replace the `image:` line with the
`@sha256:...` form, commit. Any new runner registration picks up the
pinned digest. To upgrade an existing runner, run `make runner-add-repo`
again — the script applies, which causes Kubernetes to roll the
Deployment to the new image.

## Troubleshooting

### Runner pod CrashLoopBackOff with "failed to mint registration token"

The PAT scope is wrong or expired. Re-mint with `repo` + `workflow`
scopes and re-run `make runner-create-secret`.

### Runner pod Running, but GitHub UI shows it Offline

Look at `kubectl -n gh-runner logs deployment/<name>`. Common causes:

- DNS to `api.github.com` blocked: confirm the `gh-runner-egress`
  NetworkPolicy includes a kube-system DNS rule. `kubectl exec`
  into the pod and run `getent hosts api.github.com`.
- HTTPS to GitHub blocked: confirm the egress rule allows
  `0.0.0.0/0:443`. `kubectl exec ... -- curl -sI https://api.github.com/zen`.

### Workflow stuck in "Waiting for a runner..."

The workflow's `runs-on:` doesn't match. The runner advertises
`self-hosted, kyma` — your workflow must use those exact labels:

```yaml
runs-on: [self-hosted, kyma]
```

Check `kubectl -n gh-runner describe deployment/<name>` and confirm the
LABELS env var is `self-hosted,kyma`.

### your-llm-gateway unreachable from within the runner

The runner targets the **gateway Service directly**, not the public nginx
ingress. The public path uses an Istio VirtualService keyed on the public
hostname, so cluster-internal callers using a `*.svc.cluster.local` Host
header fall through and istio-envoy returns 404. Bypass that layer:

```bash
kubectl -n gh-runner exec deployment/<name> -- \
  curl -sS -o /dev/null -w '%{http_code}\n' \
  http://gateway.your-llm-gateway.svc.cluster.local:8080/openrouter/api/v1/models
```

200 means OK (this endpoint requires no auth). Network errors point at
the NetworkPolicy or an Istio sidecar issue (the `gh-runner` namespace
is labeled `istio-injection: disabled` precisely to avoid the latter).
A 404 from `server: istio-envoy` means the runner is reaching nginx but
the VirtualService is not matching — usually because the URL points at
`nginx.your-llm-gateway.svc.cluster.local` instead of
`gateway.your-llm-gateway.svc.cluster.local`.

## Security model

- **Pod hardening**: PSA `restricted` profile, `runAsUser: 1001`,
  `runAsNonRoot: true`, `allowPrivilegeEscalation: false`,
  `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`,
  `automountServiceAccountToken: false`.
- **No K8s API access**: the runner has no RoleBinding. It cannot list,
  create, or modify any cluster resources, including its own Pod.
- **Egress allowlist**: NetworkPolicy restricts egress to DNS,
  `your-llm-gateway:8080` in-cluster, and TCP 443 to public. RFC1918 is
  explicitly excluded from the public-egress rule, so a compromised
  runner cannot pivot to internal services through `0.0.0.0/0:443`.
- **No supply chain dependency on a third-party image**: the runner
  binary comes from `ghcr.io/actions/actions-runner` (GitHub-published).
  The entrypoint script is in this repo (`configmap-entrypoint.yaml`)
  and is ~50 lines of bash you can audit directly.
- **Tokens never on disk in the repo**: `Secret` is created via
  `kubectl create secret --from-literal` from values typed into
  `read -rs`. Manifests reference the Secret via `secretKeyRef`. The
  rendered Deployments under `deploy/runner/deployments/` contain only
  pointers, not values.
- **gitleaks gate**: `.github/workflows/secrets-scan.yml` runs gitleaks
  on every PR and push to main. Any high-confidence credential pattern
  fails the build.

## Going public

If you ever flip this repo's visibility from private to public, run
the following release gate first.

```bash
# 1. Full-history secrets scan. Exit zero is required.
docker run --rm -v "$PWD:/r" zricethezav/gitleaks:latest \
  detect --source /r --redact -v

# 2. Visual review.
ls deploy/runner/deployments/
# Open each rendered Deployment and confirm it contains no inline tokens.
# (It shouldn't — secretKeyRef only — but verify before going public.)

# 3. History grep for known token prefixes.
git log --all -p \
  | grep -E '(sk-ant-[A-Za-z0-9_-]{40,}|ghp_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{80,})' \
  | head
# Empty output is required. If a real-looking match appears, rewrite history
# (BFG Repo-Cleaner or git-filter-repo) before flipping visibility.

# 4. Only then:
gh repo edit st-gr/openshell-driver-kyma --visibility public
```

The third step is critical: gitleaks detects current state, but a
credential committed three months ago and force-pushed away **still
exists in the GitHub remote** until the repo is force-pushed with
amended history. The grep is a final visual check.
