# Getting started: from "I have a Kyma cluster" to "I'm running Claude in a sandbox"

This is the canonical walkthrough — four steps from a clean Kyma cluster
to a working `openshell sandbox exec` with Claude in the loop. The shape
follows NVIDIA's CLI-first install: copy the example values file, edit
the bits your operator owns, `helm install -f`.

For the **full hands-on flow** — Kyma bootstrap, install, sandbox
create, file upload, Claude inference that creates a new file, file
download, teardown — see
[`walkthrough-claude-files.md`](walkthrough-claude-files.md).

If you want the underlying mechanics (driver + gateway sidecar
architecture, NetworkPolicy posture, etc.) read
[`production-deployment.md`](production-deployment.md) after you finish
here.

## 1. Prerequisites

- A Kyma cluster you have `cluster-admin` on (Gardener, Trial, or Free
  Tier all work). `kubectl get ns` succeeds against it.
- `helm` v3.12+, `kubectl` v1.27+.
- The `openshell` CLI — see [`install-cli.md`](install-cli.md).
- The `kubernetes-sigs/agent-sandbox` controller installed cluster-wide.
  v0.5.2 is the release the chart's CI runs against:

  ```bash
  kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.2/sandbox.yaml
  kubectl -n agent-sandbox-system rollout status deployment/agent-sandbox-controller --timeout=120s
  ```

## 2. Bootstrap the sandbox namespace

Label the sandbox namespace `privileged` under
[Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
(PSA). That is the level the chart's CI runs at. Upstream's sandbox pods
themselves run unprivileged (non-root, all capabilities dropped), so a
stricter level may admit them, but only `privileged` is verified here; the
provider hook also runs as root, which `restricted` refuses.

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
recommended Claude setup), pre-create the API-key Secret:

```bash
# Operator-managed Secret. The chart never sees the API key.
kubectl -n "$NS" create secret generic my-anthropic-creds \
  --from-literal=api-key=sk-ant-…
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
- A post-install Job that registers a provider profile and creates the
  provider from it on the in-pod gateway (`openshell provider profile
  import` + `openshell provider create`; when `inferenceProvider.enabled`).
- The driver+gateway pod's NetworkPolicy (default-deny ingress except the
  probe and gateway ports, egress to DNS and 443) and, in shared mode with
  the in-pod gateway, `<fullname>-sandbox-ssh`, which admits SSH to sandbox
  pods only from the gateway pod. The sandbox pods
  themselves are fenced by upstream's own per-namespace policies,
  `openshell-sandbox-workloads` and `openshell-sandbox-supervisors`, which
  the driver creates; the chart adds nothing to them.
- RBAC for the driver's ServiceAccount, mirroring upstream's chart: a Role
  in the sandbox namespace and a ClusterRole for cluster-scoped rights.
  It includes `tokenreviews:create`, so the driver can validate the
  supervisor's projected ServiceAccount token (the driver performs the
  TokenReview in its `AuthenticateSandbox` RPC).
- An optional PVC for gateway DB persistence.

## 4. Verify, exec a sandbox

```bash
kubectl -n "$NS" get pods
# NAME                                         READY   STATUS    RESTARTS   AGE
# ods-openshell-driver-kyma-...                2/2     Running   0          30s

kubectl -n "$NS" logs deploy/ods-openshell-driver-kyma -c driver --tail=5
# Look for: "Starting Kyma compute driver"

kubectl -n "$NS" logs deploy/ods-openshell-driver-kyma -c gateway --tail=50
# Look for: "Compute driver connected"
```

The last line proves the gateway is talking to the driver over the shared
Unix socket. If it is missing, check the driver container's logs.

Reach the gateway, create a sandbox, exec into it:

```bash
kubectl -n "$NS" port-forward svc/ods-openshell-driver-kyma 8080:8080 &

openshell --gateway-endpoint http://localhost:8080 sandbox create \
  --name hello \
  --from ghcr.io/nvidia/openshell-community/sandboxes/base:latest \
  --detach \
  -- sleep infinity

openshell --gateway-endpoint http://localhost:8080 sandbox exec \
  --name hello \
  -- echo "hello from inside the sandbox"
```

`sandbox create --detach` returns once the gateway reports the sandbox
`Ready`. Behind that: the CLI calls `CreateSandbox` on the gateway → the
gateway dispatches to the driver over the in-pod Unix socket → upstream's
driver creates the `Sandbox` CR, a hardened supervisor pod
(`os-supervisor-<sandbox id>`) and per-sandbox bootstrap Secrets → the
agent-sandbox controller starts the workload pod → the supervisor bootstraps
against the gateway, exchanging its projected ServiceAccount token for a
sandbox JWT via `IssueSandboxToken` (the driver authenticates the token) →
the gateway reports `Ready`.

### Run Claude with an inference provider

> **Not yet verified end to end on v0.9.0.** This flow follows upstream's
> provider model, but it has not been run against a v0.9.0 cluster yet. Call
> `/usr/bin/claude` directly (as below): the `claude` wrapper in the
> `sandbox-claude` image predates provider profiles and unsets
> `ANTHROPIC_API_KEY`.

If your overlay has `inferenceProvider.enabled`, the chart's post-install
Job has created a provider on the gateway. Its name is
`inferenceProvider.name`, by default `<release>-<type>` (`ods-anthropic` for
the release above). Create sandboxes with `--provider <name>` to give them
that provider:

```bash
openshell --gateway-endpoint http://localhost:8080 provider list

openshell --gateway-endpoint http://localhost:8080 sandbox create \
  --name claude-demo \
  --provider ods-anthropic \
  --from ghcr.io/st-gr/sandbox-claude:latest \
  --detach

openshell --gateway-endpoint http://localhost:8080 sandbox exec \
  --name claude-demo -- env | grep ANTHROPIC
```

The driver gives every sandbox `ANTHROPIC_BASE_URL`
(`inferenceProvider.baseUrl`) and `ANTHROPIC_MODEL`
(`inferenceProvider.modelId`). A sandbox created with `--provider` also has a
placeholder for `ANTHROPIC_API_KEY`. Leave the placeholder in place: do not
export your own key. A sandbox created without `--provider` is not given the
key, nor the network rule that admits the endpoint.

How the routing works (per
[NVIDIA's docs](https://docs.nvidia.com/openshell/how-it-works/inference)):

- The chart renders a **provider profile**: the endpoint is the host and
  port of `inferenceProvider.baseUrl`, and `binaries` lists the executables
  allowed to reach it. The Job imports the profile and creates the provider
  from it with the API key from your Secret. The chart never sees the key.
- `--provider` attaches the provider to the sandbox. The agent sees only a
  placeholder key. Upstream fences the workload pod so that it has no network
  of its own; its traffic goes through its supervisor pod, which substitutes
  the real key in requests to the profile's endpoint and dials the upstream
  itself. The attached provider also contributes the network rule that admits
  that endpoint.
- The key is bound to the endpoint's host and port (the path of `baseUrl` is
  not part of the binding). `binaries` gates which processes may reach the
  endpoint; upstream v0.1.2 does not yet restrict the key by calling
  binary, so treat the endpoint as the scope.
- An in-cluster upstream needs no NetworkPolicy from this chart. Upstream
  gives each supervisor pod its own egress policy (allow-all) and gives
  workload pods none. There is no `gatewayUpstreamEgress` value any more.

`claude-code` runs under `node`, so the default `binaries` list names
`node` and `claude` under `/usr/bin` and `/usr/local/bin`. Add the
interpreter of any other SDK your sandbox image uses to
`inferenceProvider.binaries`.

### Two operational notes

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

**Run `claude` as a plain command, with `HOME` on a writable path.**
`/sandbox` is the sandbox's writable workspace. The provider's placeholder
is already in `ANTHROPIC_API_KEY`; the `claude` wrapper in the
`sandbox-claude` image unsets it, so call the real binary:

```bash
openshell sandbox exec --name claude-demo -- sh -c '
  export HOME=/sandbox
  /usr/bin/claude -p --bare --allow-dangerously-skip-permissions "say hi"'
```

`ANTHROPIC_MODEL` should already name the configured model, so `--model` is
not needed; if you pass one, it must be the model you set in
`inferenceProvider.modelId`.

## Inspect

```bash
openshell --gateway-endpoint http://localhost:8080 sandbox get hello

# The Sandbox CR is named <workspace>--<name>, e.g. default--hello.
kubectl -n "$NS" get sandbox -l openshell.ai/sandbox-name=hello -o yaml

# Each sandbox is a pair of pods that share a sandbox id: the supervisor
# pod os-supervisor-<id> and the workload pod (container `agent`).
ID=$(kubectl -n "$NS" get sandbox -l openshell.ai/sandbox-name=hello \
  -o jsonpath='{.items[0].metadata.labels.openshell\.ai/sandbox-id}' | tr '[:upper:]' '[:lower:]')
kubectl -n "$NS" get pods -l "openshell.ai/boundary-pair=$ID"
kubectl -n "$NS" logs "os-supervisor-$ID" --all-containers --tail=20
```

`openshell sandbox stop hello` deletes both pods and keeps the sandbox;
`openshell sandbox start hello` recreates them.

## Tear down

```bash
openshell --gateway-endpoint http://localhost:8080 sandbox delete hello
kill %1                          # the port-forward
helm uninstall ods -n "$NS"
kubectl delete namespace "$NS"
```

Deleting a sandbox cleans up the sandbox's own objects; the chart removes
everything else. The JWT Secret survives in `$NS`
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
  --set driver.disableClaudeTelemetry=true
```

After install the post-install Job runs once. On success Helm deletes it;
on failure it stays, so its logs show why:

```bash
kubectl -n "$NS" get jobs | grep inference-provider-hook
kubectl -n "$NS" logs job/<release>-openshell-driver-kyma-inference-provider-hook
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

**`agents.x-k8s.io/v1alpha1/Sandbox CRD is not installed` from the chart's
pre-install hook.** Install the agent-sandbox controller per Step 1.

**Sandbox pods are never created, and the namespace events say `violates
PodSecurity`.** The namespace label is wrong or missing — re-run Step 2.

**Sandbox stuck `Pending` with `Failed to pull image …` in the pod
events.** The chart pins upstream's supervisor, sandbox-runtime and gateway
images by digest from `ghcr.io/nvidia/openshell/`, which is public. A private
sandbox image needs an image pull Secret: set
`driver.sandboxImagePullSecrets` for the sandbox pods, and
`imagePullSecrets[0].name` for the driver+gateway pod.

**`openshell sandbox exec` returns `Unavailable: supervisor session not
connected`.** The sandbox's supervisor pod crashed or cannot reach the
gateway. Read its logs (`kubectl -n "$NS" logs os-supervisor-<id>
--all-containers`, see "Inspect") and check that the driver+gateway pod's
NetworkPolicy is not blocking the gateway port.

**`IssueSandboxToken bootstrap exchange failed` repeating in the
supervisor logs.** Either `gateway.sandboxJwt.enabled=false` (the chart
should have failed at install in this case — check for
`allow_unauthenticated_users = true` in
`kubectl -n "$NS" get cm <release>-openshell-driver-kyma-gateway-config -o yaml`
only if you set an OIDC issuer) or the driver's ClusterRole lacks
`tokenreviews:create` (check
`kubectl get clusterrole -l app.kubernetes.io/instance=<release> -o yaml`).

**`inference-provider-hook` Job stuck or failed.**
With `gateway.oidc.issuer` set (the gateway runs in OIDC-authenticated
mode), the Job needs an admin token to call the gateway — not yet
wired. Either register the profile and provider manually from an
authenticated CLI session, or leave OIDC unset for in-cluster-only
deployments (the gateway runs `allow_unauthenticated_users=true` and the
Job needs no extra auth). The manual steps, with the profile the chart
rendered:

```bash
kubectl -n "$NS" get cm <release>-openshell-driver-kyma-inference-profile \
  -o jsonpath='{.data.profile\.yaml}' > profile.yaml
openshell provider profile lint   -f profile.yaml --global
openshell provider profile import -f profile.yaml --global
ANTHROPIC_API_KEY='sk-ant-…' openshell provider create \
  --name <provider-name> --type <profile-id> \
  --credential ANTHROPIC_API_KEY --global-profile
```

If the Job's log says the provider "exists with type …", a provider of that
name was created under another profile (for example by 0.8.0). A provider's
type cannot be changed: delete it (`openshell provider delete <name>`;
sandboxes attached to it lose it) and run `helm upgrade` again, or set
`inferenceProvider.name`.

**`openshell sandbox create --provider <name>` says the provider or its
profile is missing.** With `gateway.dbPersistence.enabled=false`, a gateway
restart wipes the provider and profile. Run `helm upgrade` again to re-run
the hook, or enable persistence.

**Sandboxes from before an upgrade to 0.9.0 do not come up.** A sandbox
created by 0.8.0 cannot bootstrap on the new runtime. Delete it
(`openshell sandbox delete <name>`, or `kubectl -n "$NS" delete sandbox
<name>` if the gateway no longer finds it) and create it again. The CHANGELOG
lists the upgrade steps.
