# Calling the gateway directly — without the `openshell` CLI

The gateway sidecar deployed by this chart speaks **gRPC over HTTP/2**.
The `openshell` CLI is just a typed gRPC client on top of those same
endpoints. If you want to script against the gateway from a language
or environment where the CLI isn't a fit (CI runner without the
binary, embedded controller, browser, raw curl) you can hit the
endpoints directly.

This page shows the protocol, what the server does and doesn't
support, and worked examples invoking real RPCs.

## What the server speaks

Verified live against the upstream NVIDIA gateway image
`ghcr.io/nvidia/openshell/gateway` (the image the chart runs by
default):

| Surface | Status |
|---|---|
| **gRPC** (`application/grpc` over HTTP/2) | ✅ primary protocol; what the CLI uses |
| **gRPC-Web** (`application/grpc-web`) | ✅ accepted; lets you use any HTTP client |
| **Server reflection** | ❌ not enabled — bring your own `.proto` files |
| **HTTP/JSON transcoding** (grpc-gateway) | ❌ not enabled |
| **Connect-RPC** (`Connect-Protocol-Version` header) | ❌ not enabled |
| **TLS** | gated by `gateway.tls.enabled`. With it off (default), use `--plaintext` / `http://`. With it on, also consider `gateway.tls.clientCa.enabled` for mTLS. |
| **Auth** | none with `gateway.oidc.issuer=""` (default). With OIDC set, every call needs a `Bearer` token in the `authorization` metadata. |

The gRPC server lives on `gateway.grpcPort` (default `8080`). Health
probes (`/healthz`, `/readyz`) are plain HTTP/1.1 on
`gateway.healthPort` (default `9092`). Prometheus metrics are on
`gateway.metricsPort` (default `9091`).

## Prerequisite: grab the proto files

The gateway's `.proto` files live in NVIDIA's upstream OpenShell repo,
not this one. Fetch the five files you need:

```bash
mkdir -p /tmp/proto && cd /tmp/proto
for f in datamodel.proto inference.proto sandbox.proto openshell.proto compute_driver.proto; do
  curl -fsSL "https://raw.githubusercontent.com/NVIDIA/OpenShell/main/proto/$f" -o "$f"
done
```

These pin the message types you'll send and the response shapes you'll
get back. The CLI version pin you should match is the one your gateway
image was built against — usually equal to the openshell-cli
`OPENSHELL_CLI_VERSION` constant in the inference-provider-hook
template (currently `v0.0.91`). Replace `main` with `v0.0.91` above
for an exact match.

## Reach the gateway

In-cluster (from a sibling pod):

```bash
GATEWAY=http://ods-openshell-driver-kyma.openshell-system.svc.cluster.local:8080
```

From your host:

```bash
kubectl -n openshell-system port-forward svc/ods-openshell-driver-kyma 8080:8080 &
GATEWAY=http://localhost:8080
```

## Path 1: `grpcurl` — the curl-shaped option

Install once: `brew install grpcurl` (macOS), `apt install grpcurl`
(Debian backports), or grab the
[release tarball](https://github.com/fullstorydev/grpcurl/releases)
for any Linux musl shell.

### List services

```bash
grpcurl -plaintext \
  -import-path /tmp/proto \
  -proto openshell.proto \
  -proto inference.proto \
  ods-openshell-driver-kyma:8080 list
```

Expected:

```
openshell.inference.v1.Inference
openshell.v1.OpenShell
```

### List a service's methods

```bash
grpcurl -plaintext \
  -import-path /tmp/proto -proto openshell.proto \
  ods-openshell-driver-kyma:8080 list openshell.v1.OpenShell
```

Expected (truncated):

```
openshell.v1.OpenShell.AttachSandboxProvider
openshell.v1.OpenShell.CreateProvider
openshell.v1.OpenShell.CreateSandbox
openshell.v1.OpenShell.DeleteSandbox
openshell.v1.OpenShell.ExecSandbox
openshell.v1.OpenShell.GetSandbox
openshell.v1.OpenShell.ListSandboxes
…
```

### Describe a method's request shape

```bash
grpcurl -plaintext \
  -import-path /tmp/proto -proto openshell.proto \
  ods-openshell-driver-kyma:8080 \
  describe openshell.v1.OpenShell.CreateSandbox
```

### Call an RPC

`ListSandboxes` (empty request):

```bash
grpcurl -plaintext \
  -import-path /tmp/proto -proto openshell.proto \
  -d '{}' \
  ods-openshell-driver-kyma:8080 \
  openshell.v1.OpenShell/ListSandboxes
```

`GetClusterInference` (returns the inference route the chart's
post-install Job set up):

```bash
grpcurl -plaintext \
  -import-path /tmp/proto -proto inference.proto \
  -d '{}' \
  ods-openshell-driver-kyma:8080 \
  openshell.inference.v1.Inference/GetClusterInference
```

Expected output:

```json
{
  "providerName": "ods-openshell-driver-kyma-anthropic",
  "modelId": "claude-opus-4-7",
  "version": "1",
  "routeName": "inference.local"
}
```

`CreateProvider` example body (replace placeholders):

```bash
grpcurl -plaintext \
  -import-path /tmp/proto -proto openshell.proto \
  -d '{
    "metadata": { "name": "my-provider" },
    "spec": {
      "type": "anthropic",
      "credential": [{"key": "ANTHROPIC_API_KEY", "value": "sk-ant-..."}],
      "config":     [{"key": "ANTHROPIC_BASE_URL", "value": "http://gateway.your-llm-ns.svc.cluster.local:8080/anthropic"}]
    }
  }' \
  ods-openshell-driver-kyma:8080 \
  openshell.v1.OpenShell/CreateProvider
```

### With OIDC enabled

```bash
TOKEN=$(your-method-of-getting-a-token)
grpcurl -plaintext \
  -H "authorization: Bearer ${TOKEN}" \
  -import-path /tmp/proto -proto openshell.proto \
  -d '{}' \
  ods-openshell-driver-kyma:8080 \
  openshell.v1.OpenShell/ListSandboxes
```

When `gateway.tls.enabled` is on, drop `-plaintext`. When mTLS is on,
also pass `-cert <client.crt> -key <client.key>` (and `-cacert
<ca.crt>` if you didn't trust the chart's self-signed CA OS-wide).

## Path 2: gRPC-Web with raw `curl`

If you can't install `grpcurl` but you can `curl`, the server speaks
gRPC-Web on the same port. The trick is the body framing: a 5-byte
header (`<flag-byte> <big-endian uint32 length>`) followed by a
serialized protobuf message.

The flag byte is `0x00` for a normal data frame. For an RPC with no
request fields (e.g., `ListSandboxes`), the protobuf payload is zero
bytes, so the body is just `00 00 00 00 00`.

```bash
printf '\x00\x00\x00\x00\x00' | \
  curl -sSi -X POST \
    -H "Content-Type: application/grpc-web" \
    --data-binary @- \
    http://ods-openshell-driver-kyma:8080/openshell.v1.OpenShell/ListSandboxes
```

You'll get an `HTTP/1.1 200 OK` with `content-type: application/grpc`
or `application/grpc-web` and a body that's again gRPC-Web-framed:
data frames carrying serialized protobuf, then a trailer frame.
Decoding requires reading the same proto file you'd hand to grpcurl.

For non-empty requests you have to build the protobuf body yourself —
`protoc --encode=…` is the conventional way:

```bash
echo '{"page_size": 50}' | \
  protoc --encode=openshell.v1.ListSandboxesRequest \
    -I /tmp/proto openshell.proto > /tmp/req.bin
LEN=$(printf '%08x' "$(wc -c < /tmp/req.bin)")
{ printf '\x00'; printf "%b" "\x${LEN:0:2}\x${LEN:2:2}\x${LEN:4:2}\x${LEN:6:2}"; cat /tmp/req.bin; } | \
  curl -sSi -X POST \
    -H "Content-Type: application/grpc-web" \
    --data-binary @- \
    http://ods-openshell-driver-kyma:8080/openshell.v1.OpenShell/ListSandboxes
```

This is fiddly. Use grpcurl unless you really can't.

## Path 3: the inference DATA path is separate

The walkthrough's `claude` round-trip goes through a totally different
endpoint:

```
sandbox process  ─https://inference.local/v1/messages──▶  supervisor's L7 inference router
                                                                  │
                                                                  ▼
                                                  operator's in-cluster LLM upstream
```

That `inference.local/v1/messages` is **not a gateway gRPC RPC**. It's
an HTTPS endpoint the supervisor's in-process inference router
intercepts inside the sandbox pod. From inside a sandbox you call it
with plain HTTP/JSON (Anthropic-shape):

```bash
curl -sSi -X POST https://inference.local/v1/messages \
  -H "x-api-key: sk-ant-placeholder000000000000000000000000000000000000000000000000" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-opus-4-7","max_tokens":50,"messages":[{"role":"user","content":"say hi"}]}'
```

The `x-api-key` is stripped and replaced by the supervisor; the value
just has to look like an Anthropic key. The walkthrough at
[`walkthrough-claude-files.md`](walkthrough-claude-files.md) walks
through this end-to-end.

The gateway's gRPC RPCs (`CreateSandbox`, `ListSandboxes`,
`GetInferenceBundle`, etc.) are the **control plane**. The inference
DATA plane lives entirely between the sandbox process and its
supervisor; the gateway sees only a one-time `GetInferenceBundle` per
sandbox at startup, never the actual inference request bytes.

## What's NOT exposed

- No HTTP/JSON transcoding. `POST /openshell.v1.OpenShell/ListSandboxes`
  with `Content-Type: application/json` returns 404. The chart does
  not enable grpc-gateway.
- No Connect-RPC. The `Connect-Protocol-Version: 1` header doesn't
  unlock anything.
- No server reflection. Hence the "bring your own `.proto`" step.
- No anonymous metrics scraping if you don't expose `gatewayService`
  — the chart's NetworkPolicy admits in-cluster pods only.
