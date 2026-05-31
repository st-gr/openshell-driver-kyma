# Getting started: from "I have a Kyma cluster" to "I'm running Claude in a sandbox"

This is the canonical walkthrough — four steps from a clean Kyma cluster
to a working `openshell sandbox exec` with Claude in the loop. The shape
follows NVIDIA's CLI-first install: copy the example values file, edit
the bits your operator owns, `helm install -f`.

If you want the underlying mechanics (driver + gateway sidecar
architecture, NetworkPolicy posture, etc.) read
[`production-deployment.md`](production-deployment.md) after you finish
here. If anything diverges from what you see, the source-of-truth is
`scripts/e2e-cli.sh` — that script runs the same flow against a real
cluster on every push.

## 1. Prerequisites

- A Kyma cluster you have `cluster-admin` on (Gardener, Trial, or Free
  Tier all work). `kubectl get ns` succeeds against it.
- `helm` v3.12+, `kubectl` v1.27+.
- The `openshell` CLI — see [`install-cli.md`](install-cli.md).
- The `kubernetes-sigs/agent-sandbox` controller installed cluster-wide:

  ```bash
  kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.4.6/manifest.yaml
  kubectl -n agent-sandbox-system rollout status deployment/agent-sandbox-controller --timeout=120s
  ```

## 2. Bootstrap the sandbox namespace

The OpenShell supervisor needs `privileged` PSA on its namespace because
it sets up Landlock + seccomp + a network namespace for each agent. The
chart's pre-install hook fails fast with an actionable error if the label
is missing.

```bash
NS=openshell-system
kubectl create namespace "$NS"
kubectl label namespace "$NS" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite
```

If you'll route model traffic through an in-cluster LLM gateway (the
recommended Claude setup), pre-create the API-key Secret and label the
upstream namespace:

```bash
# Operator-managed Secret. The chart never sees the API key.
kubectl -n "$NS" create secret generic my-anthropic-creds \
  --from-literal=api-key=sk-ant-…

# Kyma/Gardener doesn't auto-apply this label; the gateway egress
# NetworkPolicy needs it to match the upstream namespace.
kubectl label namespace your-llm-ns kubernetes.io/metadata.name=your-llm-ns
```

## 3. Copy the example values file, edit, install

```bash
cp deploy/helm/openshell-driver-kyma/values.example.yaml my-values.yaml
${EDITOR:-vi} my-values.yaml      # plug in your upstream URL, secret name, OIDC issuer
```

Then install:

```bash
helm install ods deploy/helm/openshell-driver-kyma \
  --namespace "$NS" \
  -f my-values.yaml \
  --wait --timeout=180s
```

Or, clone-free, against the OCI-published chart (every `v*` tag pushes
to `ghcr.io/st-gr/charts/openshell-driver-kyma`):

```bash
helm install ods oci://ghcr.io/st-gr/charts/openshell-driver-kyma \
  --version <chart-version> \
  --namespace "$NS" -f my-values.yaml \
  --wait --timeout=180s
```

What this lands in your cluster:

- A two-container pod (driver + gateway) sharing a Unix socket via emptyDir.
- A pre-install Job that mints the sandbox-JWT signing key (when
  `gateway.sandboxJwt.enabled`).
- A post-install Job that calls `openshell provider create` + `openshell
  inference set` against the in-pod gateway (when
  `inferenceProvider.enabled`).
- Two NetworkPolicies (driver+gateway-pod default-deny + sandbox-pod
  egress to DNS, gateway VIP, and 0.0.0.0/0:443 with RFC1918 excluded).
- A ClusterRole + Role pair for `tokenreviews:create` + `pods:get` so
  the gateway can validate the supervisor's projected SA token.
- An optional PVC for gateway DB persistence.

## 4. Verify, exec a sandbox

```bash
kubectl -n "$NS" get pods
# NAME                                         READY   STATUS    RESTARTS   AGE
# ods-openshell-driver-kyma-...                2/2     Running   0          30s

kubectl -n "$NS" logs deploy/ods-openshell-driver-kyma -c driver --tail=5
# Look for: "PSA enforce=privileged confirmed"  / "driver ready"

kubectl -n "$NS" logs deploy/ods-openshell-driver-kyma -c gateway --tail=5
# Look for: "Server listening address=0.0.0.0:8080"
```

Reach the gateway, create a sandbox, exec into it:

```bash
kubectl -n "$NS" port-forward svc/ods-openshell-driver-kyma 8080:8080 &

openshell --gateway-endpoint http://localhost:8080 sandbox create \
  --name hello \
  --from ghcr.io/st-gr/e2e-sandbox:latest \
  -- sleep infinity

openshell --gateway-endpoint http://localhost:8080 sandbox exec \
  --name hello \
  -- echo "hello from inside the sandbox"
```

`sandbox create` blocks until the sandbox reaches `phase=Ready`. That
involves the CLI calling `CreateSandbox` on the gateway → gateway
dispatching to the driver over the in-pod UDS → driver creating a
`Sandbox` CR → agent-sandbox controller scheduling a pod with the
supervisor sideloaded via the binary's `copy-self` subcommand
(see [`why-init-container.md`](why-init-container.md)) → supervisor
exchanging its projected SA token for a sandbox JWT via
`IssueSandboxToken` → readiness probe flips Ready=true.

If your overlay has `inferenceProvider.enabled`, you can also run Claude
inside a sandbox — the upstream CLI ships a `--claude` flag that
provisions an image with the agent installed:

```bash
openshell --gateway-endpoint http://localhost:8080 sandbox create \
  --name claude-demo \
  --claude

openshell --gateway-endpoint http://localhost:8080 sandbox exec \
  --name claude-demo -- claude "say hi"
```

How the routing works (per
[NVIDIA's docs](https://docs.nvidia.com/openshell/about/how-it-works) —
"No subprocess, no loopback hop"):

- The agent application (your Claude code in the agent container) sees
  only `ANTHROPIC_BASE_URL=https://inference.local` in its env (no
  `/v1` suffix — the Anthropic SDK and `claude-code` append
  `/v1/messages` themselves; with a `/v1` suffix the request would
  land at `/v1/v1/messages` and the supervisor's L7 router rejects it).
  It cannot read the real upstream URL or the API key.
- The supervisor (same pod, separate process namespace, runs privileged)
  fetches a bundle from the gateway via `GetInferenceBundle`. The
  bundle carries the resolved upstream URL + API key the chart's
  post-install Job loaded into the gateway DB from your Secret.
- The supervisor terminates `inference.local` TLS using a per-SNI cert
  from the sandbox CA at `/etc/openshell-tls/`, strips the agent's
  placeholder credentials, injects the real ones, and dials the
  upstream itself from the sandbox pod's eth0.
- The gateway sidecar's role is bundle/config plane only — it never
  forwards inference request bytes.

The `gatewayUpstreamEgress` block in your values file is what unblocks
that final outbound hop on the sandbox-pod NetworkPolicy. Without it,
the supervisor can't reach the in-cluster upstream and `inference.local`
requests time out.

### Two operational notes from the live E2E

**Upload/download needs `rsync` + `openssh-client` on the host.**
`openshell sandbox upload` and `openshell sandbox download` shell out
to `rsync` over `ssh` under the hood. If either is missing on the
machine running the CLI, the command fails with the unhelpful
`Error: No such file or directory (os error 2)`. Install both:

```bash
# Debian/Ubuntu
sudo apt-get install -y rsync openssh-client

# Alpine (in-cluster CLI pod)
apk add --no-cache rsync openssh-client
```

**`claude-code` works end-to-end with a few env knobs.**
Out of the box the chart injects `ANTHROPIC_BASE_URL=https://inference.local`
into every sandbox pod, but `openshell sandbox exec` does NOT propagate
pod-spec env into exec sessions (the supervisor session manager strips
them). To run `claude` via `openshell sandbox exec`, set the env
explicitly inline; with the default chart values that's:

```bash
openshell sandbox exec --name <sandbox> -- sh -c '
  export HOME=/sandbox \
         ANTHROPIC_BASE_URL=https://inference.local \
         ANTHROPIC_API_KEY=sk-ant-placeholder000000000000000000000000000000000000000000000000 \
         CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  claude -p --bare --allow-dangerously-skip-permissions \
         --model <your-configured-model> "say hi"'
```

`HOME=/sandbox` because `/home/sandbox` is Landlock-restricted in the
exec session. `ANTHROPIC_API_KEY` must look like an Anthropic key
(`sk-ant-` prefix); the supervisor's L7 router strips it and injects
the real one from the gateway bundle. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`
silences statsig/sentry calls (also injectable chart-side via
`driver.disableClaudeTelemetry: true` for the agent's main process).
`--model` must match the model configured on the gateway via
`inferenceProvider.modelId` — the supervisor refuses model swaps
because that's a credential boundary.

## Inspect

```bash
openshell --gateway-endpoint http://localhost:8080 sandbox get hello
kubectl -n "$NS" get sandbox hello -o yaml         # the raw CR
kubectl -n "$NS" logs hello -c agent --tail=10     # supervisor logs
```

## Tear down

```bash
openshell --gateway-endpoint http://localhost:8080 sandbox delete hello
kill %1                          # the port-forward
helm uninstall ods -n "$NS"
kubectl delete namespace "$NS"
```

The agent-sandbox controller cleans up the sandbox pod automatically;
the chart removes everything else. The JWT Secret survives in `$NS`
until the namespace deletion (intentional — it survives `helm upgrade`
so the sandbox-Ready promise holds across releases).

---

## Appendix A: install via `--set` flags (no values file)

For one-off and scripted installs you can skip the values file and pass
flags directly. The values-file path above is recommended for anything
you'll keep around.

### Minimal install (gateway sidecar + sandbox-JWT only)

```bash
helm install ods deploy/helm/openshell-driver-kyma \
  --namespace "$NS" \
  --set namespace="$NS" \
  --set gateway.enabled=true \
  --set gatewayService.enabled=true \
  --set gateway.sandboxJwt.enabled=true \
  --wait --timeout=180s
```

### Full install (in-cluster LLM gateway routing)

```bash
helm upgrade --install ods deploy/helm/openshell-driver-kyma \
  --namespace "$NS" \
  --set namespace="$NS" \
  --set gateway.enabled=true \
  --set gateway.sandboxJwt.enabled=true \
  --set gatewayService.enabled=true \
  --set gateway.dbPersistence.enabled=true \
  --set inferenceProvider.enabled=true \
  --set inferenceProvider.type=anthropic \
  --set inferenceProvider.baseUrl=http://gateway.your-llm-ns.svc.cluster.local:8080/anthropic \
  --set inferenceProvider.modelId=claude-opus-4-7 \
  --set inferenceProvider.credentialSecret.name=my-anthropic-creds \
  --set inferenceProvider.credentialSecret.key=api-key \
  --set gatewayUpstreamEgress.enabled=true \
  --set gatewayUpstreamEgress.namespace=your-llm-ns \
  --set gatewayUpstreamEgress.port=8080 \
  --set driver.disableClaudeTelemetry=true
```

After install the post-install Job runs once. Verify:

```bash
kubectl -n "$NS" get jobs | grep inference-provider-hook
kubectl -n "$NS" logs job/<release>-inference-provider-hook
```

The Job is idempotent (re-runs cleanly on `helm upgrade`). The chart
never sees the API key — it's mounted into the Job pod from your Secret
via `secretKeyRef`.

## Appendix B: public exposure via Kyma APIRule

For exposing the gateway outside the cluster (so the `openshell` CLI
runs on a developer laptop, not via port-forward), set
`gatewayApirule.enabled=true` and supply `gateway.oidc.issuer`. The
chart refuses to render an APIRule for an unauthenticated gateway. See
[`production-deployment.md`](production-deployment.md) for the full
setup.

## Troubleshooting

**`Sandbox CR is not installed` from the chart's pre-install hook.**
Install the agent-sandbox controller per Step 1.

**`PSA enforce=privileged not confirmed` in driver logs.**
The namespace label is wrong or missing — re-run Step 2.

**Sandbox stuck `Pending` with `Failed to pull image …` in the pod
events.** The chart references `ghcr.io/nvidia/openshell/supervisor:latest`
by default, which is public. Other images (especially private ones)
need an `imagePullSecrets` — set `imagePullSecrets[0].name=<your-secret>`
in your overlay.

**`openshell sandbox exec` returns `Unavailable: supervisor session
not connected`.** The driver injects `OPENSHELL_SSH_SOCKET_PATH`; if
you see this error, the supervisor either crashed (check its logs) or
the network policy is too tight (verify the sandbox NetworkPolicy
allows egress to the in-pod gateway).

**`IssueSandboxToken bootstrap exchange failed` repeating in the
supervisor logs.** Either `gateway.sandboxJwt.enabled=false` (the chart
should have failed at install in this case — check for
`allow_unauthenticated_users = true` in
`kubectl -n "$NS" get cm <release>-gateway-config -o yaml` only if you
set an OIDC issuer) or the gateway's TokenReview RBAC is missing (check
`kubectl get clusterrole <release>-tokenreview -o yaml`).

**`inference-provider-hook` Job stuck.**
With `gateway.oidc.issuer` set (the gateway runs in OIDC-authenticated
mode), the Job needs an admin token to call the gateway — not yet
wired. Either run the `openshell provider create` + `openshell
inference set` steps manually post-install, or leave OIDC unset for
in-cluster-only deployments (the gateway runs
`allow_unauthenticated_users=true` and the Job needs no extra auth).
