# Tutorial: OpenShell on Kyma with a direct Anthropic endpoint

End-to-end walkthrough for the simplest useful shape: one Kyma cluster,
one Anthropic-shaped API endpoint, one API key. No SAP AI Core, no
in-cluster LLM gateway, no OIDC. About 15 minutes from "empty cluster"
to Claude producing output inside an isolated sandbox on your cluster.

```mermaid
flowchart TB
    P["Prerequisites:<br/>Kyma cluster + kubectl + helm<br/>Anthropic endpoint + API key<br/>host for the openshell CLI"]

    subgraph S1["1 — Cluster bootstrap"]
        direction LR
        C1["agent-sandbox<br/>controller v0.4.6"]
        C2["namespace openshell-system<br/>PSA privileged"]
        C3["Secret<br/>my-anthropic-creds"]
    end

    subgraph S2["2 — Values overlay"]
        V{"Where is the<br/>upstream endpoint?"}
        VPUB["public :443<br/>default NetworkPolicy suffices"]
        VPRIV["in-cluster / RFC1918 / non-443:<br/>MUST enable gatewayUpstreamEgress<br/>or all inference returns 503"]
    end

    subgraph S3["3 — helm install chart 0.1.2"]
        POD["driver + gateway pod 2/2<br/>gateway 0.0.73, Unix socket,<br/>--drivers kyma"]
        HOOK["hook Job: provider create +<br/>inference set (auto-deletes)"]
    end

    S45["4-5 — install openshell CLI,<br/>port-forward :8080,<br/>gateway add --local"]

    subgraph S6["6 — run Claude in a sandbox"]
        CREATE["sandbox create --policy<br/>(egress locked to inference.local)"]
        PROBE{"6a probe: node POST<br/>inference.local/v1/messages"}
        OK["HTTP 200 — pipeline works"]
        E503["HTTP 503 — upstream unreachable,<br/>fix gatewayUpstreamEgress"]
        RUN["6b claude -p or TUI via wrapper<br/>(do NOT export ANTHROPIC_API_KEY)"]
        PATH["agent → inference.local →<br/>supervisor injects real key →<br/>upstream"]
    end

    S7["7 — teardown: sandbox delete,<br/>helm uninstall, delete namespace"]

    P --> S1
    S1 --> S2
    V -->|public| VPUB
    V -->|private| VPRIV
    S2 --> S3
    HOOK -.reads key.-> C3
    S3 --> S45
    S45 --> CREATE
    CREATE --> PROBE
    PROBE -->|200| OK
    OK --> RUN
    RUN === PATH
    PROBE -->|503| E503
    E503 -.fix values, retest.-> PROBE
    RUN --> S7

    style VPRIV fill:#f8d7da,stroke:#b02a37,stroke-width:2px
    style E503 fill:#f8d7da,stroke:#b02a37,stroke-width:2px
    style OK fill:#d1e7dd,stroke:#146c43
    style PATH fill:#cfe2ff,stroke:#0a58ca
```

The upstream gateway image comes from NVIDIA — nothing here needs a
fork build.

If you have an SAP AI Core service key instead of a plain Anthropic
key, use [`walkthrough-claude-files.md`](walkthrough-claude-files.md)
and its "SAP AI Core via the in-cluster translation bridge" variant.
If your upstream is a private LLM gateway inside another namespace in
your cluster, use [`getting-started.md`](getting-started.md) instead.

## Prerequisites

- **A Kyma cluster** you have `cluster-admin` on. Gardener, SAP BTP
  Trial, or Free Tier all work. `kubectl get ns` must succeed.
- **`kubectl` v1.27+** and **`helm` v3.12+**.
- **An Anthropic-shaped endpoint** — either `https://api.anthropic.com`
  or your own Anthropic-compatible URL (any proxy that exposes
  `POST /v1/messages` and speaks the Anthropic Messages API). The
  endpoint must be reachable from the internet or from your Kyma
  cluster's node egress.
- **An API key** that the endpoint accepts (`sk-ant-…` for real
  Anthropic; any key format your proxy expects otherwise).
- **A host to run the `openshell` CLI**. Linux, macOS, or Windows via
  WSL2. Native Windows is not supported by the CLI.

## 1. Cluster bootstrap

One-time cluster setup. Skip anything you've already done.

### 1a. Install the agent-sandbox controller

The chart's pre-install hook fails fast if this CRD is missing.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.4.6/manifest.yaml
kubectl -n agent-sandbox-system rollout status \
  deployment/agent-sandbox-controller --timeout=120s
```

### 1b. Create the sandbox namespace with `privileged` PSA

The OpenShell supervisor needs `privileged` Pod Security Admission
because it configures Landlock + seccomp + a network namespace for each
agent. Kyma enforces PSA by default; without this label the pods won't
start.

```bash
NS=openshell-system
kubectl create namespace "$NS"
kubectl label namespace "$NS" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite
```

### 1c. Store your Anthropic API key as a Secret

The chart never sees the key — it flows Secret → post-install
Job → gateway DB → sandbox supervisor at request time.

```bash
kubectl -n "$NS" create secret generic my-anthropic-creds \
  --from-literal=api-key='sk-ant-…'          # or whatever your endpoint expects
```

## 2. Values overlay

Create a `my-values.yaml` file. This is everything you need for the
direct-endpoint case:

```yaml
# my-values.yaml
namespace: openshell-system

driver:
  # Silences non-essential telemetry inside claude-code. Optional but
  # recommended so the agent's egress is only inference traffic.
  disableClaudeTelemetry: true

gateway:
  # Enable the in-pod gateway sidecar. The kyma driver won't work
  # without it (they talk over an in-pod Unix domain socket).
  enabled: true
  # Persist the gateway DB (provider records + inference route)
  # across pod restarts. Backed by a 1Gi PVC by default.
  dbPersistence:
    enabled: true
  sandboxJwt:
    enabled: true

gatewayService:
  # Expose the gateway on ClusterIP so the openshell CLI can reach it
  # via kubectl port-forward.
  enabled: true

inferenceProvider:
  enabled: true
  type: anthropic
  # Real Anthropic API. Change if you have your own Anthropic-shaped
  # endpoint. No trailing slash. Do NOT append /v1 — the SDK adds
  # /v1/messages itself.
  baseUrl: https://api.anthropic.com
  # Must match one of the models your endpoint serves. The supervisor
  # refuses model swaps mid-request — this is a credential boundary.
  modelId: claude-opus-4-7
  credentialSecret:
    name: my-anthropic-creds
    key: api-key
```

Notes on why this is short:

- **`gatewayUpstreamEgress` is not enabled — this is only safe for a
  public `:443` endpoint.** The chart's default sandbox NetworkPolicy
  allows egress to DNS, the in-pod gateway, and `0.0.0.0/0:443` **with
  RFC1918 ranges excluded** (`10/8`, `172.16/12`, `192.168/16`). A
  public `https://api.anthropic.com` is reached over `:443` on a public
  IP, so it is covered. **But if your endpoint is inside the cluster**
  (an RFC1918 ClusterIP, and/or a non-443 port like `:8080`), the
  supervisor cannot reach it and every inference call fails with
  `503 inference service unavailable` — while the sandbox itself looks
  perfectly healthy. In that case enable the egress carve-out:

  ```yaml
  gatewayUpstreamEgress:
    enabled: true
    namespace: your-llm-ns   # namespace hosting the upstream
    port: 8080               # the upstream's port
  ```

  This is the single most common reason a correctly-installed setup
  produces no inference. See the verification `curl`/`node` probe in
  step 6 to distinguish it from other failures.
- **No `gatewayApirule` / OIDC block.** Those are for exposing the
  gateway outside the cluster with browser-based auth. This tutorial
  uses `kubectl port-forward` to reach the gateway; auth stays
  unauthenticated-in-cluster.
- **No `bedrockBridge` block.** That's the SAP AI Core translation
  bridge — not needed if you have a plain Anthropic key.

## 3. Install the chart

```bash
helm install ods oci://ghcr.io/st-gr/charts/openshell-driver-kyma \
  --version 0.1.2 \
  --namespace "$NS" \
  -f my-values.yaml \
  --wait --timeout=300s
```

Expected result: `STATUS: deployed`, and a two-container pod
(`driver` + `gateway`) reaches `Running 2/2` in about 30–60 s.
Verify:

```bash
kubectl -n "$NS" get pods
kubectl -n "$NS" logs deploy/ods-openshell-driver-kyma -c driver --tail=5
# Look for: "PSA enforce=privileged confirmed" / "driver ready"
kubectl -n "$NS" logs deploy/ods-openshell-driver-kyma -c gateway --tail=5
# Look for: "Server listening address=0.0.0.0:8080"
# And:      "Compute driver connected configured_driver=kyma advertised_driver=kyma in_tree=false"
```

The last line proves the gateway is talking to the kyma driver over
the shared UDS. If it's missing, the driver container failed —
check its logs.

Do not install chart `0.1.1` — its default `gateway.image` points at a
stale pre-release fork build (`ghcr.io/st-gr/openshell-gateway:latest`)
that silently breaks sandbox phase reporting (`openshell sandbox
create` never sees the sandbox reach `Ready` and times out after
300 s). Chart `0.1.2`+ pins the upstream NVIDIA gateway by digest.

A post-install Job also runs once and registers the Anthropic
provider + inference route on the gateway. On success helm deletes
the Job (hook delete-policy), so its absence is the normal outcome —
confirm via events, or via the CLI in step 5:

```bash
kubectl -n "$NS" get events --sort-by=lastTimestamp | grep inference-provider-hook
# Look for: "Completed   job/ods-openshell-driver-kyma-inference-provider-hook"
```

If the install instead timed out waiting on the hook, the most common
cause is a wrong `inferenceProvider.baseUrl` that the gateway can't
validate against — see the [troubleshooting appendix in
`getting-started.md`](getting-started.md#troubleshooting). The failed
Job sticks around in that case, so `kubectl -n "$NS" logs
job/ods-openshell-driver-kyma-inference-provider-hook` shows why.

## 4. Install the openshell CLI

See [`install-cli.md`](install-cli.md) for the full matrix. For a
quick smoke test on Linux (or WSL2):

```bash
VERSION=v0.0.75
curl -fsSL "https://github.com/NVIDIA/OpenShell/releases/download/${VERSION}/openshell-x86_64-unknown-linux-musl.tar.gz" \
  | tar -xz -C /usr/local/bin
openshell --version
```

On macOS: `brew install astral-sh/uv/uv && uv tool install -U openshell`.

**Pin the CLI version to the gateway image**. This tutorial pins the
gateway to the digest of `0.0.73` via the chart default (see
`values.yaml`), so `v0.0.75` CLI is fine — the gRPC contract is
compatible across recent patch releases, but the CLI's error messages
match the gateway's shape when they align.

## 5. Reach the gateway + verify

Port-forward the in-cluster gateway to `localhost:8080`, then register
it with the CLI as the local default:

```bash
kubectl -n "$NS" port-forward svc/ods-openshell-driver-kyma 8080:8080 &
openshell gateway add --local http://localhost:8080
openshell status
# Server Status: OK
```

If `openshell status` says `missing authorization header`, the gateway
requires OIDC — you almost certainly set `gateway.oidc.issuer` in your
values file. Unset it for this tutorial (in-cluster only), or follow
[`production-deployment.md`](production-deployment.md) to wire OIDC end
to end.

## 6. Run Claude in a sandbox

The sandbox image `ghcr.io/st-gr/sandbox-claude:latest` bundles Node 22
and the `claude` CLI. Its default policy locks agent egress to
`inference.local:443` only, so the agent's outbound goes exclusively
through the supervisor's L7 router — the router strips the agent's
placeholder credentials and injects the real ones from the gateway
bundle.

Create the sandbox:

```bash
# A format-valid placeholder is enough. The supervisor's L7 router
# strips it and injects the real API key from the gateway bundle.
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
  --name hello \
  --from ghcr.io/st-gr/sandbox-claude:latest \
  --provider claude-code \
  --auto-providers \
  --policy ./claude-policy.yaml

# sandbox create returns before the pod is Ready. Wait explicitly.
until openshell sandbox list 2>/dev/null | grep -q "hello.*Ready"; do
  sleep 1
done
openshell sandbox list
```

### 6a. Confirm the inference path first

Before involving Claude Code, prove the gateway actually serves
inference — this one probe separates "the pipeline works" from "some
claude-code quirk." The sandbox image ships `node` (no `curl`), so use
it to POST directly to `inference.local`. Keep it on one line — the
exec endpoint rejects multi-line command arguments:

```bash
openshell sandbox exec --name hello -- node -e 'const https=require("https");const b=JSON.stringify({model:"claude-opus-4-7",max_tokens:16,messages:[{role:"user",content:"Reply OK"}]});const r=https.request("https://inference.local/v1/messages",{method:"POST",rejectUnauthorized:false,headers:{"content-type":"application/json","anthropic-version":"2023-06-01","x-api-key":"sk-ant-placeholder000000000000000000000000000000000000000000000000"}},s=>{let d="";s.on("data",c=>d+=c);s.on("end",()=>{console.log("HTTP",s.statusCode);console.log(d.slice(0,300))})});r.on("error",e=>console.log("ERR",e.message));r.write(b);r.end();'
```

- **`HTTP 200` with `{"content":[{"text":"OK",…}]}`** — the whole path
  works (supervisor strips the placeholder `x-api-key`, injects the
  real one, forwards to your upstream). Proceed to 6b.
- **`HTTP 503 {"error":"inference service unavailable"}`** — the
  supervisor cannot reach your configured upstream. This is almost
  always the `gatewayUpstreamEgress` gap from step 2: an in-cluster or
  non-`:443` endpoint blocked by the sandbox NetworkPolicy. Enable the
  egress carve-out and re-test.
- **`ERR` / TLS errors** — `inference.local` isn't resolving or the
  sandbox policy denies it; check the sandbox `--policy` allows
  `inference.local:443`.

The `x-api-key` here is a format-valid placeholder; the L7 router
replaces it. `rejectUnauthorized:false` skips verifying the supervisor's
per-SNI cert, which is fine for this probe.

### 6b. Run Claude Code

Once 6a returns `200`, Claude Code works both interactively and in
print mode. **Call the wrapper `claude`** (installed at
`/usr/local/bin/claude`) — it sets `HOME`, seeds onboarding state,
points `ANTHROPIC_BASE_URL` at `inference.local`, and unsets the
supervisor's placeholder `ANTHROPIC_API_KEY` so Claude uses the managed
key and never reaches for `api.anthropic.com`. **Do not re-export
`ANTHROPIC_API_KEY` yourself** — that forces claude-code into an auth
pre-flight against `api.anthropic.com`, which the sandbox policy blocks.

Non-interactive (print mode):

```bash
openshell sandbox exec --name hello -- claude -p --model claude-opus-4-7 "Reply with exactly OK"
```

Expected output: `OK`.

Interactive TUI (allocates a PTY automatically when your terminal is
interactive):

```bash
openshell sandbox exec --name hello -- claude --model claude-opus-4-7
```

Type a prompt, watch it stream back through `inference.local`, exit
with `/quit`.

If Claude answers with `authentication_error`, your Secret's `api-key`
value is wrong — recreate it with the correct key and roll the gateway
pod so it re-reads the DB. If you see `model_not_found`, `--model`
doesn't match `inferenceProvider.modelId` in your values overlay.

> **Why `claude -p` might appear to hang.** In print mode claude-code
> buffers all output until completion, so if the underlying inference
> call fails (e.g. the 503 above), you see silence rather than an
> error. If `claude -p` hangs, run the 6a probe — a `503` there is the
> real cause, not claude-code. `--output-format stream-json --verbose`
> also surfaces the buffered error.

For the fuller flow (uploading a file, having Claude produce a new
file, downloading it) follow
[`walkthrough-claude-files.md`](walkthrough-claude-files.md) sections 7
onward.

## 7. Teardown

```bash
openshell sandbox delete hello
kill %1                                     # the port-forward
helm uninstall ods -n "$NS"
kubectl delete namespace "$NS"              # optional; wipes the JWT + TLS Secrets too
```

The kubernetes-sigs agent-sandbox controller stays installed
cluster-wide — remove it separately with a matching
`kubectl delete -f https://…/manifest.yaml` if you no longer need it.

## What to change if your setup is different

- **Your endpoint is an Anthropic-shaped proxy inside your Kyma cluster
  (private).** Set `inferenceProvider.baseUrl` to the in-cluster URL
  (`http://gateway.your-llm-ns.svc.cluster.local:8080/anthropic` or
  similar) and enable `gatewayUpstreamEgress`. See
  [`getting-started.md`](getting-started.md) Appendix A "Full install".
- **You want to hit real Anthropic via SAP AI Core** (SAP service key,
  Bedrock-shaped deployments). Use
  [`walkthrough-claude-files.md`](walkthrough-claude-files.md) with its
  bedrockBridge variant.
- **You want the CLI to run on a developer laptop over the public
  internet** (no port-forward). Set `gatewayApirule.enabled=true` and
  `gateway.oidc.issuer`. See
  [`production-deployment.md`](production-deployment.md).
- **You want to route inference through SAP Cloud Connector.** See
  [`cloud-connector-setup.md`](cloud-connector-setup.md).

## Verified against

Run end-to-end on 2026-07-02:

- Kyma / Gardener (SAP BTP), 4x `cpu-worker` amd64 nodes, Kubernetes
  v1.34.
- Chart `openshell-driver-kyma` `0.1.2` (do **not** use `0.1.1` — see
  the note in step 3).
- Gateway image `ghcr.io/nvidia/openshell/gateway@sha256:523609f8…`
  (upstream NVIDIA `0.0.73`, containing NVIDIA/OpenShell#1703 and #1704),
  pulled via the chart's default digest pin.
- `openshell` CLI `v0.0.75`.

Verified end-to-end: install, gateway↔driver named-endpoint handshake
(`configured_driver=kyma advertised_driver=kyma in_tree=false`),
provider + inference route registration, sandbox create reaching
`Ready`, a direct `node` POST to `inference.local` returning
`HTTP 200` with a Claude reply, and `claude -p` returning `OK` through
the wrapper.

Verified against an **in-cluster** upstream (an Anthropic-shaped
gateway on an RFC1918 ClusterIP, port 8080), which required
`gatewayUpstreamEgress` — without it, inference returned
`503 inference service unavailable` while the sandbox looked healthy.
For a genuinely public `https://api.anthropic.com:443` endpoint the
default policy suffices and no egress block is needed.

If your outcome diverges from what's above, the source of truth is
`scripts/e2e-cli.sh` — every push through CI runs the same shape
end-to-end against a real cluster.
