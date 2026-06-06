# End-to-end walkthrough: Kyma → sandboxed Claude → upload → infer → download → teardown

This is the canonical hands-on guide. It takes a clean Kyma cluster
through:

1. Cluster prerequisites + namespace bootstrap.
2. Installing the chart (`v0.1.1`) from OCI.
3. Installing the `openshell` CLI on your host.
4. Creating a Claude-equipped sandbox.
5. Uploading a file to the sandbox.
6. Asking Claude to read the input and create a new file.
7. Downloading the new file to your host.
8. Tearing the sandbox + release down.

All steps verified end-to-end against a real Kyma cluster on
2026-05-31. Total time: ~10 minutes once the prerequisites are in
place.

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

## 2. Bootstrap the cluster (one-time)

```bash
# CRD prereq — kubernetes-sigs/agent-sandbox controller, cluster-wide.
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.4.6/manifest.yaml
kubectl -n agent-sandbox-system rollout status deployment/agent-sandbox-controller --timeout=120s

# Sandbox namespace + PSA labels (required: the supervisor needs
# privileged for Landlock + netns + capabilities).
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

# If your upstream LLM gateway is in another namespace, label that
# namespace so the chart's NetworkPolicy can match it. Kyma/Gardener
# does NOT auto-apply this label.
kubectl label namespace your-llm-ns \
  kubernetes.io/metadata.name=your-llm-ns
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
#   gatewayUpstreamEgress.{namespace,podSelector,port}:  match your upstream
```

## 4. Install the chart from OCI

```bash
helm install ods oci://ghcr.io/st-gr/charts/openshell-driver-kyma \
  --version 0.1.1 \
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
openshell gateway add http://localhost:8080 --local
```

`gateway add --local` registers this gateway as the active one so
subsequent `openshell` commands don't need `--gateway-endpoint`.

## 6. Create the Claude-equipped sandbox

The policy below is a minimal template that lets the agent reach
`inference.local:443` (where the supervisor's L7 router intercepts) and
nothing else. For the field-by-field schema and how to iterate on it,
see the upstream docs:

- [Customize Sandbox Policies](https://docs.nvidia.com/openshell/sandboxes/policies)
  — what each section does, hot-reload semantics, debugging denied
  requests.
- [Policy Schema Reference](https://docs.nvidia.com/openshell/reference/policy-schema)
  — every field, every accepted value.

```bash
# A format-valid placeholder is enough. The supervisor's L7 router
# strips this and injects the real key from the gateway bundle.
export ANTHROPIC_API_KEY=sk-ant-placeholder000000000000000000000000000000000000000000000000

cat > claude-policy.yaml <<'YAML'
version: 1
filesystem_policy:
  include_workdir: true
  read_only:  ["/usr","/lib","/lib64","/proc","/etc","/opt","/home","/etc/openshell-tls"]
  read_write: ["/sandbox","/tmp"]
landlock:
  compatibility: best_effort
process:
  run_as_user: sandbox
  run_as_group: sandbox
network_policies:
  claude:
    name: claude
    endpoints:
      - { host: inference.local, port: 443 }
    binaries:
      - { path: /usr/bin/claude }
      - { path: /usr/bin/node }
YAML

openshell sandbox create \
  --name claude-files \
  --from ghcr.io/st-gr/sandbox-claude:latest \
  --provider claude-code \
  --auto-providers \
  --policy ./claude-policy.yaml

# Wait for the sandbox to become Ready (typically ~10–15 s on Kyma).
# `openshell sandbox create` returns as soon as the CR is accepted, well
# before the pod reaches Running, so a bare follow-up `list` would just
# show Pending.
until openshell sandbox list 2>/dev/null | grep -q "claude-files.*Ready"; do
  sleep 1
done
openshell sandbox list
```

What's happening:

- `--from ghcr.io/st-gr/sandbox-claude:latest` — public image with
  Node 22 + the `claude` CLI baked in (sibling of `e2e-sandbox`).
- `--provider claude-code` + `--auto-providers` — registers a
  `claude-code` provider on the gateway from your local
  `ANTHROPIC_API_KEY` env. Required so the supervisor's L7 router
  treats claude-code's request shape correctly.
- `--policy ./claude-policy.yaml` — locks the sandbox's network egress
  to `inference.local:443` only. The agent process cannot dial
  api.anthropic.com or anywhere else.
- **No trailing `-- <COMMAND>` clause needed.** The pod's PID 1 is the
  OpenShell supervisor binary (`/opt/openshell/bin/openshell-sandbox`),
  set by the base image — it runs unconditionally and is what keeps
  the pod alive. The `--` clause sets the *initial command*, which only
  matters in combination with `--no-keep` (which auto-deletes the
  sandbox when that command exits). Earlier docs in this repo and
  upstream told you to add `-- sleep infinity`; that's a no-op without
  `--no-keep` and has been removed here.

You'll see the harmless CLI message
`Error: × No such file or directory (os error 2)` after the sandbox is
created — that's the CLI returning before the sandbox reaches Ready.
The `until` loop above is what blocks until the supervisor is up.

## 7. Upload a file

Pick any local file. Example: a draft you want Claude to summarize.

```bash
cat > /tmp/draft.md <<'EOF'
# Project status (draft)

Three things shipped this week:
- Helm chart published as OCI artifact.
- Driver v0.1.1 with inference.local URL fix.
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
  export HOME=/sandbox \
         ANTHROPIC_BASE_URL=https://inference.local \
         ANTHROPIC_API_KEY=sk-ant-placeholder000000000000000000000000000000000000000000000000 \
         CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  claude -p \
    --allow-dangerously-skip-permissions \
    --allowed-tools Write,Read \
    --add-dir /sandbox \
    --model claude-opus-4-7 \
    "Read /sandbox/draft.md. Write /sandbox/summary.md containing exactly two single-line bullet points: one for shipped, one for outstanding. After writing, print only the word DONE."
'
```

The flags that matter:

- `HOME=/sandbox` — `/home/sandbox` is Landlock-restricted in exec
  sessions. Setting `HOME` to a writable dir lets claude write its
  state cache.
- `ANTHROPIC_BASE_URL=https://inference.local` — **no `/v1` suffix**.
  Anthropic SDKs append `/v1/messages` themselves. Earlier chart
  versions injected `…/v1` and produced `/v1/v1/messages`, which the
  supervisor's L7 router rejected. Fixed in v0.1.1; the chart's
  pod-spec env var is now correct, but exec sessions don't inherit
  pod-spec env, so set it inline.
- `ANTHROPIC_API_KEY=sk-ant-…` — placeholder. The supervisor's L7
  router strips it and injects the real one from the gateway bundle.
  Must look like an Anthropic key (`sk-ant-` prefix and length) or
  claude-code rejects it client-side.
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` — silences statsig +
  sentry + other auxiliary endpoints. The chart can also inject this
  for the agent's main process via `driver.disableClaudeTelemetry: true`.
- `--allowed-tools Write,Read` — claude-code's `-p` print mode disables
  tools by default. You have to opt in to Write to let it create files.
- `--add-dir /sandbox` — claude-code only writes inside directories
  passed via `--add-dir` (or the cwd at startup).
- `--model claude-opus-4-7` — must match the model configured on the
  gateway via `inferenceProvider.modelId`. The supervisor refuses
  swaps; that's a credential boundary.

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
agent (claude-code, sandbox UID 1000660000)
  │  POST https://inference.local/v1/messages
  ▼
supervisor's L7 inference router (same pod, separate process namespace, root)
  │  strips agent's placeholder x-api-key
  │  injects real key from GetInferenceBundle
  │  rewrites Host: header to your upstream
  ▼
gateway sidecar (driver+gateway pod) ──── bundle/config plane only
                                          NEVER forwards request bytes

(supervisor dials directly from sandbox-pod's eth0)
  ▼
your in-cluster LLM upstream
  ▼
(real Anthropic / Bedrock / etc.)
```

What the agent sees in its env: `ANTHROPIC_BASE_URL=https://inference.local`,
nothing else. No real upstream URL. No real key. The supervisor process
in the same pod holds the bundle, but as a separate process namespace
the agent cannot inspect it.

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
is identical to the Anthropic-mode flow above — same `inference.local`
endpoint, same `claude` invocation, no Bedrock env, no AWS creds, no
per-pod policy carve-out. The only operator-facing changes are the
Secret pre-flight, the values overlay, and pointing
`inferenceProvider.baseUrl` at the bridge.

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
registers `claude-opus-4.7` (or whichever `inferenceProvider.modelId`
is) as a normal Anthropic provider whose upstream is the bridge.

### Sandbox env

Section 8's `claude` invocation works **unchanged**. `ANTHROPIC_MODEL`
selects which key from `bedrockBridge.modelMap` to use, and
`ANTHROPIC_SMALL_FAST_MODEL` selects the model for sub-agents (Task
tool, etc.):

```bash
openshell sandbox exec --name claude-files -- sh -c '
  cd /sandbox
  export HOME=/sandbox \
         ANTHROPIC_MODEL=claude-opus-4.7 \
         ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4.5 \
         ANTHROPIC_SMALL_FAST_MODEL=claude-haiku-4.5
  claude -p \
    --allow-dangerously-skip-permissions \
    --allowed-tools Write,Read \
    --add-dir /sandbox \
    "Read /sandbox/draft.md. Write /sandbox/summary.md..."
'
```

Notes:
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
  curl -fsSL https://github.com/NVIDIA/OpenShell/releases/download/v0.0.50/openshell-x86_64-unknown-linux-musl.tar.gz \
    | tar -xz -C /usr/local/bin &&
  /usr/local/bin/openshell gateway add http://ods-openshell-driver-kyma:8080 --local
'

# Then everywhere the walkthrough says `openshell ...`, prefix with
# `kubectl -n "$NS" exec cli -- /usr/local/bin/openshell ...`
```

Caveat: `kubectl exec` shell quoting through Windows PowerShell is
brittle. Multi-line shell scripts get rejected with "command argument
contains newline or carriage return" — keep everything on one line, or
use `--%` (PowerShell 5.1) to stop arg parsing.
