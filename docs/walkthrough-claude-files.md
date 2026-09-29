# End-to-end walkthrough: Kyma → sandboxed Claude → upload → infer → download → teardown

This is the canonical hands-on guide. It takes a clean Kyma cluster
through:

1. Cluster prerequisites + namespace bootstrap.
2. Installing the chart (`0.9.0`) from OCI.
3. Installing the `openshell` CLI on your host.
4. Creating a Claude-equipped sandbox.
5. Uploading a file to the sandbox.
6. Asking Claude to read the input and create a new file.
7. Downloading the new file to your host.
8. Tearing the sandbox + release down.

```mermaid
sequenceDiagram
    autonumber
    actor Op as Operator host
    participant GW as gateway :8080
    participant DRV as kyma driver
    participant CTRL as agent-sandbox controller
    participant SBX as sandbox pods<br/>(supervisor pod + workload pod running claude)
    participant UP as upstream<br/>(Anthropic API or bedrock-bridge to SAP AI Core)

    Note over Op,CTRL: one-time setup: controller + PSA namespace + Secret + helm install (OCI chart)
    Op->>GW: gateway add --local (via kubectl port-forward)
    Op->>GW: sandbox create --provider ods-anthropic
    GW->>DRV: CreateSandbox over Unix socket
    DRV->>CTRL: create Sandbox CR and supervisor pod
    CTRL-->>SBX: start workload pod; supervisor bootstraps; phase Ready
    Op->>SBX: sandbox upload draft.md (rsync over ssh)
    Op->>SBX: sandbox exec claude -p "read draft.md, write summary.md"
    SBX->>UP: supervisor substitutes the real key, POST /v1/messages
    UP-->>SBX: completion - claude writes /sandbox/summary.md
    Op->>SBX: sandbox download summary.md
    Op->>GW: sandbox delete + helm uninstall
```

## A note on running the CLI in a container

The walkthrough below shows the CLI running on your host. NVIDIA
publishes the `openshell` CLI for Linux (musl + RPM), macOS (Apple
Silicon tarball), and Linux/macOS Python wheels — but **not for
Windows**. If your host is Windows, three options:

- **WSL2** (recommended for repeated use). One-time install:
  `wsl --install -d Ubuntu`, then run all of the walkthrough's `bash`
  steps inside WSL. Port-forwards to `localhost:8080` work natively
  from Windows-side terminals AND from WSL.
- **Run the CLI inside the cluster as a one-shot pod** (zero host
  install). This is what the appendix at the bottom shows. You drive
  everything via `kubectl exec cli -- openshell ...`. Useful for a
  first taste; clunky for daily use because shell quoting through
  `kubectl exec` is fiddly.
- **Docker Desktop / Podman**. Run the Linux musl tarball in an Alpine
  container with `~/.kube` mounted read-only. Same shape as the
  in-cluster pod option, just locally.

The walkthrough body uses the host-CLI shape (works in WSL, Linux,
macOS). The in-cluster-pod variants are in the appendix.

If you want to skip the CLI entirely and hit the gateway's gRPC
endpoints from any HTTP/2 client (`grpcurl`, raw `curl` over
gRPC-Web, a Go/Python/JS gRPC library), see
[`grpc-without-cli.md`](grpc-without-cli.md).

## 1. Prerequisites

- A Kyma cluster you have `cluster-admin` on. `kubectl get ns` works.
- `helm` v3.12+, `kubectl` v1.27+ on your host.
- An Anthropic-compatible upstream reachable from inside the cluster
  (e.g., an in-cluster gateway on `gateway.<your-llm-ns>.svc.cluster.local:8080`).
- An Anthropic API key (or whatever credential your upstream LLM
  gateway accepts).
- An `openshell` CLI on your host or in WSL (see the note above).
- New to OpenShell? The gateway / driver / supervisor / agent roles
  and the credential-containment model are summarized in the
  ["What you're building"](tutorial-anthropic-direct.md#what-youre-building)
  primer of the companion tutorial.

## 2. Bootstrap the cluster (one-time)

```bash
# CRD prereq — kubernetes-sigs/agent-sandbox controller, cluster-wide
# (v0.5.2 is the release the chart's CI runs against).
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.2/sandbox.yaml
kubectl -n agent-sandbox-system rollout status deployment/agent-sandbox-controller --timeout=120s

# Sandbox namespace + Pod Security Admission (PSA) labels. PSA is
# Kubernetes' namespace-level pod security enforcement. `privileged` is the
# level the chart's CI runs at; upstream's sandbox pods run unprivileged, so a
# stricter level may admit them, but only `privileged` is verified here.
NS=openshell-system
kubectl create namespace "$NS"
kubectl label namespace "$NS" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite

# Anthropic key Secret. The chart never sees this Secret's value.
kubectl -n "$NS" create secret generic my-anthropic-creds \
  --from-literal=api-key='sk-ant-…'
```

## 3. Build a values overlay

Copy `values.example.yaml` and edit four lines:

```bash
curl -fsSL https://raw.githubusercontent.com/st-gr/openshell-driver-kyma/main/deploy/helm/openshell-driver-kyma/values.example.yaml \
  > my-values.yaml

# Edit my-values.yaml — at minimum:
#   inferenceProvider.baseUrl:  http://gateway.your-llm-ns.svc.cluster.local:8080/anthropic
#   inferenceProvider.modelId:  claude-opus-4-7   (or whatever the upstream serves)
#   inferenceProvider.credentialSecret.{name,key}:  my-anthropic-creds / api-key
```

## 4. Install the chart from OCI

```bash
helm install ods oci://ghcr.io/st-gr/charts/openshell-driver-kyma \
  --version 0.9.0 \
  --namespace "$NS" \
  -f my-values.yaml \
  --wait --timeout=300s
```

Expect: `STATUS: deployed`, pod `2/2 Running`. If post-install times
out on `inference-provider-hook`, see
[`getting-started.md`](getting-started.md) Troubleshooting.

## 5. Reach the gateway from your host

```bash
kubectl -n "$NS" port-forward svc/ods-openshell-driver-kyma 8080:8080 &
openshell gateway add --local http://localhost:8080
```

`gateway add --local` registers this gateway as the active one so
subsequent `openshell` commands don't need `--gateway-endpoint`.

## 6. Create the Claude-equipped sandbox

The chart's post-install Job created a provider on the gateway (named
`<release>-<type>`, so `ods-anthropic` here) from a provider profile that
names your upstream's host and port. Attach it with `--provider`: that gives
the sandbox a placeholder key and the network rule that admits the endpoint.
For what a sandbox policy is and how to iterate on one, see NVIDIA's
[Policies](https://docs.nvidia.com/openshell/how-it-works/policies/overview)
and [Policy schema](https://docs.nvidia.com/openshell/how-it-works/policies/schema).

```bash
openshell provider list          # ods-anthropic

openshell sandbox create \
  --name claude-files \
  --provider ods-anthropic \
  --from ghcr.io/st-gr/sandbox-claude:latest \
  --detach \
  -- sleep infinity

openshell sandbox list           # claude-files ... Ready
```

What's happening:

- `--from ghcr.io/st-gr/sandbox-claude:latest` — public image with
  Node 22 + the `claude` CLI baked in (sibling of `e2e-sandbox`).
- `--provider ods-anthropic` — attaches the chart-created provider. The
  sandbox gets a placeholder for `ANTHROPIC_API_KEY`; the supervisor
  substitutes the real key only in requests to the profile's host and port.
  The driver gives every sandbox `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL`
  from `inferenceProvider.baseUrl` and `.modelId`.
- `--detach -- sleep infinity` — `--detach` returns once the gateway reports
  the sandbox `Ready`; the trailing command is the sandbox's main process,
  kept alive with `sleep`.

## 7. Upload a file

Pick any local file. Example: a draft you want Claude to summarize.

```bash
cat > /tmp/draft.md <<'EOF'
# Project status (draft)

Three things shipped this week:
- Helm chart published as OCI artifact.
- Driver release on upstream OpenShell v0.1.2.
- E2E live-cluster smoke succeeded.

Two things outstanding:
- CI-driven e2e via the self-hosted Kyma runner.
- Upstream PR for the external-driver-socket gateway patch.
EOF

openshell sandbox upload claude-files /tmp/draft.md /sandbox/draft.md
```

`openshell sandbox upload` shells out to `rsync` over `ssh`. If you
get `Error: No such file or directory (os error 2)`, install both:

```bash
sudo apt-get install -y rsync openssh-client    # WSL/Debian/Ubuntu
brew install rsync openssh                      # macOS
apk add --no-cache rsync openssh-client          # Alpine
```

## 8. Run inference: ask Claude to read + write a new file

```bash
openshell sandbox exec --name claude-files -- sh -c '
  cd /sandbox
  export HOME=/sandbox
  /usr/bin/claude -p \
    --bare \
    --allow-dangerously-skip-permissions \
    --allowed-tools Write,Read \
    --add-dir /sandbox \
    "Read /sandbox/draft.md. Write /sandbox/summary.md containing exactly two single-line bullet points: one for shipped, one for outstanding. After writing, print only the word DONE."
'
```

The flags that matter:

- `/usr/bin/claude` — the real binary. The `claude` wrapper in the
  `sandbox-claude` image predates provider profiles and unsets
  `ANTHROPIC_API_KEY`, which would stop the supervisor from substituting the
  real key.
- `HOME=/sandbox` — a writable directory for claude's state cache.
- **No `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY` or `--model`.** The driver
  already gave the sandbox `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL`, and
  `--provider` gave it the placeholder key. Do not export a key of your own:
  the supervisor substitutes the real key only for the placeholder, in requests
  to the profile's host and port. Confirm with
  `openshell sandbox exec --name claude-files -- env | grep ANTHROPIC`.
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` — silences statsig +
  sentry + other auxiliary endpoints. `driver.disableClaudeTelemetry: true`
  adds it to every sandbox.
- `--allowed-tools Write,Read` — claude-code's `-p` print mode disables
  tools by default. You have to opt in to Write to let it create files.
- `--add-dir /sandbox` — claude-code only writes inside directories
  passed via `--add-dir` (or the cwd at startup).

You should see Claude print `DONE` and exit 0. Confirm the file:

```bash
openshell sandbox exec --name claude-files -- cat /sandbox/summary.md
```

Expected: a two-line bullet summary derived from `draft.md`.

## 9. Download the file

```bash
openshell sandbox download claude-files /sandbox/summary.md /tmp/summary.md
cat /tmp/summary.md
```

## 10. Teardown

Two-line cleanup:

```bash
openshell sandbox delete claude-files
helm uninstall ods -n "$NS"
```

The chart leaves three Secrets in the namespace by design (the JWT
signing-key Secret + two TLS Secrets), so they survive `helm upgrade`
and the sandbox-Ready promise holds across releases. They go away with
`kubectl delete namespace "$NS"`. The operator-managed
`my-anthropic-creds` Secret also stays (the chart never owned it).

For a complete scrub:

```bash
kubectl delete namespace "$NS"
```

## What's running, what's isolated

When `claude` ran, the path was:

```
agent (claude-code, in the workload pod)
  │  POST <ANTHROPIC_BASE_URL>/v1/messages  with the placeholder key
  ▼
its supervisor pod (os-supervisor-<sandbox id>)
  │  checks the request against the profile-derived network policy
  │  substitutes the real key, only at the profile's host:port
  ▼
your in-cluster LLM upstream
  ▼
(real Anthropic / Bedrock / etc.)
```

The gateway sidecar (driver+gateway pod) holds the provider record and hands
it to the supervisor, but never forwards request bytes.

What the agent sees in its env: `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL` and a
placeholder for the key. No real key. The workload pod has no network of its
own: upstream's NetworkPolicy gives it no egress and admits ingress only from
its supervisor pod, so it cannot dial the upstream directly.

This is **stronger isolation than NVIDIA's tutorial pattern**, which
allows the agent to call `api.anthropic.com:443` directly with the
user's OAuth-fronted Anthropic creds. Their pattern is process
containment, not credential containment.

## Variant: SAP AI Core via the in-cluster translation bridge

If your Anthropic models live behind SAP AI Core's deployed-Bedrock
schema (XSUAA service key, no SigV4), the chart ships an in-cluster
translation bridge. **The bridge speaks the Anthropic Messages API on
the inside** (`POST /v1/messages`) and converts outbound to SAP's
Bedrock InvokeModel format. From the agent's perspective the wiring
is identical to the Anthropic-mode flow above — same `--provider`
attachment, same `claude` invocation, no Bedrock env, no AWS creds. The only
operator-facing changes are the Secret pre-flight, the values overlay, and
pointing `inferenceProvider.baseUrl` at the bridge. Only sandboxes in the
release namespace (shared workspace mode) can reach the bridge: its
NetworkPolicy admits only OpenShell pods of that namespace, so sandboxes in
managed-mode namespaces cannot.

### Pre-flight (one-time)

```bash
# SAP service-key Secret. Contents stay on disk + in this Secret —
# the chart never reads the JSON.
kubectl -n "$NS" create secret generic my-sap-aicore-key \
  --from-file=service-key.json=./sk-openshell.json
```

### Values overlay additions

```yaml
bedrockBridge:
  enabled: true
  sap:
    serviceKeySecret:
      name: my-sap-aicore-key
      key: service-key.json
  modelMap:
    claude-opus-4.7:   <sap-deployment-uuid-for-opus-4-7>
    claude-sonnet-4.6: <sap-deployment-uuid-for-sonnet-4-6>
    claude-haiku-4.5:  <sap-deployment-uuid-for-haiku-4-5>

# Point the gateway's Anthropic provider at the bridge instead of an
# external Anthropic-API upstream. The credentialSecret value is
# accepted by the gateway but ignored by the bridge (SAP auth is
# XSUAA-bearer, minted bridge-side from the service-key Secret).
inferenceProvider:
  enabled: true
  type: anthropic
  baseUrl: http://ods-openshell-driver-kyma-bedrock-bridge.openshell-system.svc.cluster.local:8787
  modelId: claude-opus-4.7   # must match a key in bedrockBridge.modelMap
  credentialSecret:
    name: my-anthropic-creds
    key: api-key
```

`helm upgrade -f my-values.yaml` deploys the bridge alongside the
driver+gateway pod. The chart's existing inference-provider Job then
registers a provider profile whose endpoint is the bridge (host and port 8787)
and updates the provider. Create a new sandbox with `--provider` as in
step 6; `ANTHROPIC_MODEL` is `inferenceProvider.modelId`
(`claude-opus-4.7`).

### Sandbox env

Section 8's `claude` invocation works **unchanged**. `ANTHROPIC_MODEL`
(already set from `inferenceProvider.modelId`) selects which key from
`bedrockBridge.modelMap` to use, and `ANTHROPIC_SMALL_FAST_MODEL` selects the
model for sub-agents (Task tool, etc.):

```bash
openshell sandbox exec --name claude-files -- sh -c '
  cd /sandbox
  export HOME=/sandbox \
         ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4.5 \
         ANTHROPIC_SMALL_FAST_MODEL=claude-haiku-4.5
  /usr/bin/claude -p \
    --bare \
    --allow-dangerously-skip-permissions \
    --allowed-tools Write,Read \
    --add-dir /sandbox \
    "Read /sandbox/draft.md. Write /sandbox/summary.md..."
'
```

Notes:
- To set the sub-agent models for every sandbox instead, add
  `driver.sandboxEnv: ["ANTHROPIC_SMALL_FAST_MODEL=claude-haiku-4.5"]`.
- Both `ANTHROPIC_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL` strings must
  appear as keys in `bedrockBridge.modelMap`. Operator picks the
  naming; Claude Code passes them through verbatim.
- The bridge holds the SAP service key, exchanges it for an XSUAA
  bearer (cached, refreshed ~60s before expiry), and forwards each
  request body to the SAP deployment with `model` and `stream`
  stripped and `anthropic_version: bedrock-2023-05-31` injected.
- Streaming is byte-pass-through SSE: SAP defaults to
  `text/event-stream` and Anthropic SSE has the same wire format, so
  no per-event re-framing is needed.

### Sandbox-leakage verification (one-time, after first install)

Confirm the SAP service-key never reaches the sandbox:

```bash
# 1. Bridge file is mounted on the bridge pod, not anywhere else.
kubectl -n "$NS" exec deploy/ods-openshell-driver-kyma-bedrock-bridge \
  -- ls -la /etc/sap-aicore/
# Expected: -r-------- ... service-key.json

# 2. Sandbox SA cannot get the Secret.
kubectl -n "$NS" auth can-i get secret/my-sap-aicore-key \
  --as=system:serviceaccount:"$NS":openshell-sandbox
# Expected: no

# 3. Sandbox env carries no SAP material.
openshell sandbox exec --name claude-files -- sh -c '
  cat /etc/sap-aicore/service-key.json 2>&1 || true
  env | grep -iE "CLIENTSECRET|XSUAA|hana.ondemand" || echo "(empty)"
'
# Expected: "No such file or directory" + "(empty)"
```

## Appendix: in-cluster pod variant (no host CLI install)

If you can't install `openshell` on your host (or want to test
without): spin up an Alpine pod, install rsync + ssh + the CLI inside,
and drive everything from there.

```bash
NS=openshell-system
kubectl -n "$NS" run cli --restart=Never --image=alpine:3.20 --command -- sleep 7200

# Inside the pod (one-time setup):
kubectl -n "$NS" exec cli -- sh -c '
  apk add --no-cache curl rsync openssh-client &&
  curl -fsSL https://github.com/NVIDIA/OpenShell/releases/download/v0.1.2/openshell-x86_64-unknown-linux-musl.tar.gz \
    | tar -xz -C /usr/local/bin &&
  /usr/local/bin/openshell gateway add --local http://ods-openshell-driver-kyma:8080
'

# Then everywhere the walkthrough says `openshell ...`, prefix with
# `kubectl -n "$NS" exec cli -- /usr/local/bin/openshell ...`
```

Caveat: `kubectl exec` shell quoting through Windows PowerShell is
brittle. Multi-line shell scripts get rejected with "command argument
contains newline or carriage return" — keep everything on one line, or
use `--%` (PowerShell 5.1) to stop arg parsing.
