# Getting started: from "I have a Kyma cluster" to "I'm running Claude in a sandbox"

This is the canonical walkthrough. It takes ~15 minutes start to finish
and lands you at a working `openshell sandbox exec` against a Kyma
cluster with the OpenShell gateway sidecar running alongside this driver.

If anything diverges from what you see, the source-of-truth is
`scripts/e2e-cli.sh` — that script runs the exact same flow against a
real cluster on every push.

## 1. Prerequisites

You need:

- A Kyma cluster you have `cluster-admin` on (Gardener, Trial, or
  Free Tier all work). `kubectl get ns` succeeds against it.
- The `kubernetes-sigs/agent-sandbox` controller installed
  cluster-wide. The chart's pre-install hook checks the CRD; the
  recommended install is:

  ```bash
  kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.4.6/manifest.yaml
  kubectl -n agent-sandbox-system rollout status deployment/agent-sandbox-controller --timeout=120s
  ```
- `helm` v3.12+, `kubectl` v1.27+.
- (Optional) The `openshell` CLI — see [`install-cli.md`](install-cli.md).

## 2. Pick a sandbox namespace and label it

The OpenShell supervisor needs `privileged` PSA on the sandbox namespace
because it sets up Landlock + seccomp + a network namespace for each
agent. The driver detects the label at startup and refuses to run
without it.

```bash
NS=openshell-driver-test
kubectl create namespace "$NS"
kubectl label namespace "$NS" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite
```

(The chart's pre-install hook fails fast with an actionable error if
this is missing.)

## 3. Install the chart with the gateway sidecar enabled

```bash
helm install ods deploy/helm/openshell-driver-kyma \
  --namespace "$NS" \
  --set namespace="$NS" \
  --set gateway.enabled=true \
  --set gatewayService.enabled=true \
  --set gateway.sandboxJwt.enabled=true \
  --wait --timeout=180s
```

What this does:

- Deploys the driver and the gateway as two containers in one pod
  sharing a Unix socket via emptyDir.
- Renders a `gateway-jwt-pki-hook` pre-install Job that runs
  `openshell-gateway generate-certs` and writes the JWT signing-key
  Secret + (unused) server-tls and client-tls Secrets to `$NS`.
- Mounts the JWT Secret + a `gateway.toml` ConfigMap into the gateway
  container so it can mint per-sandbox JWTs.
- Grants the chart's `ServiceAccount` cluster-scoped
  `tokenreviews.create` and namespace-scoped `pods.get` so the gateway
  can validate the supervisor's projected SA token via TokenReview
  and read the resulting pod's `openshell.io/sandbox-id` annotation.
- Renders two NetworkPolicies (driver-pod default-deny + sandbox-pod
  egress to DNS, gateway VIP, and 0.0.0.0/0:443 with RFC1918 excluded).

## 4. Verify both containers are Ready

```bash
kubectl -n "$NS" get pods
# NAME                                         READY   STATUS    RESTARTS   AGE
# ods-openshell-driver-kyma-...                2/2     Running   0          30s

kubectl -n "$NS" logs deploy/ods-openshell-driver-kyma -c driver --tail=5
# Look for: "PSA enforce=privileged confirmed"
# Look for: "driver ready"

kubectl -n "$NS" logs deploy/ods-openshell-driver-kyma -c gateway --tail=5
# Look for: "gateway-minted sandbox JWT enabled"
# Look for: "K8s ServiceAccount bootstrap authenticator enabled"
# Look for: "Server listening address=0.0.0.0:8080"
```

## 5. Reach the gateway

You have two options.

**A. Port-forward (fastest, in-cluster only)**

```bash
kubectl -n "$NS" port-forward svc/ods-openshell-driver-kyma 8080:8080 &
openshell --gateway-endpoint http://localhost:8080 status
```

**B. Public via Kyma APIRule (production)**

This requires `gateway.oidc.issuer` to be set; the chart refuses to
render an APIRule for an unauthenticated gateway.
See [`production-deployment.md`](production-deployment.md) for the
full setup.

## 6. Create your first sandbox

```bash
openshell --gateway-endpoint http://localhost:8080 sandbox create \
  --name hello \
  --from ghcr.io/st-gr/e2e-sandbox:latest \
  -- sleep infinity
```

The CLI blocks until the sandbox reaches `phase=Ready`. That involves:

1. The CLI calling `CreateSandbox` on the gateway.
2. The gateway dispatching to the driver over the in-pod UDS.
3. The driver creating a `Sandbox` CR in the agent-sandbox API group.
4. The agent-sandbox controller scheduling a pod with the supervisor
   sideloaded via the binary's `copy-self` subcommand
   (see [`why-init-container.md`](why-init-container.md)).
5. The supervisor exchanging its projected SA token for a sandbox
   JWT via `IssueSandboxToken`.
6. The supervisor fetching its policy and entering steady-state.
7. The pod's container readiness probe flipping `Ready=true`.

## 7. Exec a command

```bash
openshell --gateway-endpoint http://localhost:8080 sandbox exec \
  --name hello \
  -- echo "hello from inside the sandbox"
```

This goes CLI → gateway → driver UDS → supervisor session control
stream → `/run/openshell/ssh.sock` inside the sandbox pod →
your-command.

## 8. Inspect the sandbox

```bash
openshell --gateway-endpoint http://localhost:8080 sandbox get hello
kubectl -n "$NS" get sandbox hello -o yaml         # the raw CR
kubectl -n "$NS" logs hello -c agent --tail=10     # supervisor logs
```

## 9. Tear down

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

## 5b. (Optional) Route model calls through your in-cluster LLM gateway

If you run an in-cluster Anthropic-compatible gateway (typical example:
an SAP-IAS-fronted Claude proxy in a separate namespace) and want every
sandbox's model traffic to flow through it instead of `api.anthropic.com`,
flip on the chart's `inferenceProvider`, `gatewayUpstreamEgress`, and
`gateway.dbPersistence` blocks.

Architecture: the **gateway sidecar** (in the driver+gateway pod) is the
process that rewrites `inference.local` and dials the real upstream. The
sandbox itself never sees the upstream URL or API key — both are owned
by the gateway pod. So this is purely a gateway-side configuration; no
sandbox env var is touched.

```bash
# 1. Operator-managed Secret with the API key. Must exist BEFORE install.
kubectl -n "$NS" create secret generic my-anthropic-creds \
  --from-literal=api-key=sk-ant-…

# 2. Label the upstream LLM gateway's namespace so the NetworkPolicy
#    can match it (Kyma/Gardener doesn't auto-apply this).
kubectl label namespace your-llm-ns kubernetes.io/metadata.name=your-llm-ns

# 3. Helm install with the new options.
helm upgrade --install ods deploy/helm/openshell-driver-kyma \
  --namespace "$NS" \
  --set namespace="$NS" \
  --set gateway.enabled=true --set gateway.sandboxJwt.enabled=true \
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

After install, a `post-install,post-upgrade` Job runs the upstream
`openshell` CLI to do `provider create` + `inference set` against the
in-pod gateway. Verify:

```bash
kubectl -n "$NS" get jobs | grep inference-provider-hook
kubectl -n "$NS" logs job/<release>-inference-provider-hook
```

The Job is idempotent (re-runs cleanly on `helm upgrade`). The chart
never sees the API key — it's mounted into the Job pod from your
Secret via `secretKeyRef`.

## Troubleshooting

**`Sandbox CR is not installed` from the chart's pre-install hook.**
Install the agent-sandbox controller per Step 1.

**`PSA enforce=privileged not confirmed` in driver logs.**
The namespace label is wrong or missing — re-run Step 2.

**Sandbox stuck `Pending` with `Failed to pull image …` in the pod
events.** The chart references `ghcr.io/nvidia/openshell/supervisor:latest`
by default, which is public. Other images (especially private ones)
need an `imagePullSecrets` — set `imagePullSecrets[0].name=<your-secret>`
on the chart.

**`openshell sandbox exec` returns `Unavailable: supervisor session
not connected`.** The driver injects `OPENSHELL_SSH_SOCKET_PATH`; if
you see this error, the supervisor either crashed (check its logs)
or the network policy is too tight (verify the sandbox NetworkPolicy
allows egress to the in-pod gateway).

**`IssueSandboxToken bootstrap exchange failed` repeating in the
supervisor logs.** Either `gateway.sandboxJwt.enabled=false` (the
chart should have failed at install in this case — check for an
`allow_unauthenticated_users = true` in
`kubectl -n "$NS" get cm <release>-gateway-config -o yaml` only if
you set OIDC issuer) or the gateway's TokenReview RBAC is missing
(check `kubectl get clusterrole <release>-tokenreview -o yaml`).
