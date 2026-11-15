# Calling the gateway directly — without the `openshell` CLI

The in-pod gateway deployed by this chart (`gateway.enabled=true` and
`gatewayService.enabled=true`) speaks **gRPC over HTTP/2**.
The `openshell` CLI is just a typed gRPC client on top of those same
endpoints. If you want to script against the gateway from a language
or environment where the CLI isn't a fit (CI runner without the
binary, embedded controller) you can hit the endpoints directly with any
gRPC client. Browser clients need their own gRPC-Web proxy, which this chart
does not provide.

This page shows the protocol, what the server does and doesn't
support, and worked examples invoking real RPCs.

## What the server speaks

The upstream NVIDIA gateway image `ghcr.io/nvidia/openshell/gateway` (the
image the chart runs by default) serves:

| Surface | Status |
|---|---|
| **gRPC** (`application/grpc` over HTTP/2) | ✅ primary protocol; what the CLI uses |
| **gRPC-Web** (`application/grpc-web`) | ❌ not served; browsers need a gRPC-Web proxy of their own |
| **Server reflection** | ✅ v1, upstream v0.1.4 and later; advertises only `openshell.v1.OpenShell`, needs no bearer token |
| **HTTP/JSON transcoding** (grpc-gateway) | ❌ not enabled |
| **Connect-RPC** (`Connect-Protocol-Version` header) | ❌ not enabled |
| **TLS** | gated by `gateway.tls.enabled`. With it off (default), use `-plaintext`. With it on, also consider `gateway.tls.clientCa.enabled` for mTLS. Through `gatewayIngress` the gateway terminates TLS with a public certificate and needs only the token (no client certificate). |
| **Auth** | none with no `gateway.oidc.issuer` and no `gateway.tls.clientCa` (default). With only `clientCa`, a client certificate. With an issuer, every call needs a `Bearer` token in the `authorization` metadata. |

The gRPC server lives on `gateway.grpcPort` (default `8080`). Health
probes (`/healthz`, `/readyz`) are plain HTTP/1.1 on
`gateway.healthPort` (default `9092`). Prometheus metrics are on
`gateway.metricsPort` (default `9091`).

## Prerequisite: the message types

The gateway (upstream v0.1.4 and later) serves gRPC server reflection, so
`grpcurl` can learn the message types from it: drop `-import-path` and
`-proto` from the examples below. Reflection needs no bearer token, but TLS
and client-certificate requirements still apply. It advertises only the public
`openshell.v1.OpenShell` service, and with `gateway.grpcRateLimit` set it has a
separate counter with the same limit; over the limit the stream closes with
`RESOURCE_EXHAUSTED`.

`$GATEWAY` is set under [Reach the gateway](#reach-the-gateway) below.

```bash
grpcurl -plaintext $GATEWAY list
grpcurl -plaintext $GATEWAY describe openshell.v1.OpenShell
```

For tools without reflection, or to pin the schema, use the `.proto` files.
They live in NVIDIA's upstream OpenShell repo, not this one. Fetch the four
files you need:

```bash
mkdir -p /tmp/proto && cd /tmp/proto
for f in datamodel.proto options.proto sandbox.proto openshell.proto; do
  curl -fsSL "https://raw.githubusercontent.com/NVIDIA/OpenShell/v0.1.7/proto/$f" -o "$f"
done
```

These pin the message types you'll send and the response shapes you'll
get back. Use the tag of the upstream release your gateway image was built
from: the chart's `upstream.version` (`v0.1.7`).

## Reach the gateway

In-cluster (from a sibling pod):

```bash
GATEWAY=ods-openshell-driver-kyma.openshell-system.svc.cluster.local:8080
```

From your host (the Service is named after the release, `<release>-openshell-driver-kyma`):

```bash
kubectl -n openshell-system port-forward svc/ods-openshell-driver-kyma 8080:8080 &
GATEWAY=localhost:8080
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
  $GATEWAY list
```

Expected:

```
openshell.v1.OpenShell
```

### List a service's methods

```bash
grpcurl -plaintext \
  -import-path /tmp/proto -proto openshell.proto \
  $GATEWAY list openshell.v1.OpenShell
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
  $GATEWAY \
  describe openshell.v1.OpenShell.CreateSandbox
```

### Call an RPC

Workspace-scoped RPCs need a `workspace_scope`; an empty request is rejected
with `workspace_scope is required`. `default` is the gateway's default
workspace.

`ListSandboxes`:

```bash
grpcurl -plaintext \
  -import-path /tmp/proto -proto openshell.proto \
  -d '{"workspace_scope": {"workspace": "default"}}' \
  $GATEWAY \
  openshell.v1.OpenShell/ListSandboxes
```

`ListProviders` (returns the providers on the gateway, among them the one
the chart's post-install Job created, named `<release>-<type>`):

```bash
grpcurl -plaintext \
  -import-path /tmp/proto -proto openshell.proto \
  -d '{"workspace_scope": {"workspace": "default"}}' \
  $GATEWAY \
  openshell.v1.OpenShell/ListProviders
```

`CreateProvider` example body (replace placeholders). `type` is the id of a
provider profile already imported on the gateway; the chart's profile is
`kyma-<type>` (see `inferenceProvider.profileId`):

```bash
grpcurl -plaintext \
  -import-path /tmp/proto -proto openshell.proto \
  -d '{
    "workspace_scope": { "workspace": "default" },
    "provider": {
      "metadata": { "name": "my-provider" },
      "type": "kyma-anthropic",
      "credentials": { "ANTHROPIC_API_KEY": "sk-ant-..." }
    }
  }' \
  $GATEWAY \
  openshell.v1.OpenShell/CreateProvider
```

### With OIDC enabled

```bash
TOKEN=$(your-method-of-getting-a-token)
grpcurl -plaintext \
  -H "authorization: Bearer ${TOKEN}" \
  -import-path /tmp/proto -proto openshell.proto \
  -d '{"workspace_scope": {"workspace": "default"}}' \
  $GATEWAY \
  openshell.v1.OpenShell/ListSandboxes
```

A valid token is not enough: it needs the roles configured in
`gateway.oidc.rolesClaim`, `adminRole` and `userRole` (unless `authOnly: true`),
and its subject must be a member of the workspace
(`openshell workspace member add --workspace default --subject <sub> --role user`).
See [`sap-ias-setup.md`](sap-ias-setup.md) for a verified IAS setup.

When `gateway.tls.enabled` is on, drop `-plaintext`. When mTLS is on,
also pass `-cert <client.crt> -key <client.key>` (and `-cacert
<ca.crt>` if you didn't trust the chart's self-signed CA OS-wide).

Remotely, through `gatewayIngress`, the gateway presents a public certificate
and needs only the token. Drop `-plaintext`, `-cert` and `-key` (mTLS does not
work through `gatewayIngress`):

```bash
grpcurl -H "authorization: Bearer ${TOKEN}" \
  -import-path /tmp/proto -proto openshell.proto \
  -d '{"workspace_scope": {"workspace": "default"}}' \
  openshell.<domain>:443 openshell.v1.OpenShell/ListSandboxes
```

## Path 2: the inference DATA path is separate

The walkthrough's `claude` round-trip does not go through the gateway's gRPC
API at all:

```
sandbox process  ─ANTHROPIC_BASE_URL, placeholder key──▶  its supervisor pod
                                                                  │
                                                                  ▼
                                                  operator's in-cluster LLM upstream
```

Inference is an ordinary HTTP(S) request from the sandbox to the endpoint
named in `inferenceProvider.baseUrl`. The workload pod has no network of its
own: the request goes through its supervisor pod, which substitutes the real
key for the placeholder the attached provider put in the sandbox's
environment. From inside a sandbox created with `--provider`, call the
endpoint with plain HTTP/JSON (Anthropic shape), sending the key from the
environment:

```bash
curl -sSi -X POST "$ANTHROPIC_BASE_URL/v1/messages" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "{\"model\":\"$ANTHROPIC_MODEL\",\"max_tokens\":50,\"messages\":[{\"role\":\"user\",\"content\":\"say hi\"}]}"
```

(`curl` must be in the sandbox image, and its path in
`inferenceProvider.binaries`; the `sandbox-claude` image ships `node`, not
`curl`.) The gateway's gRPC RPCs (`CreateSandbox`, `ListSandboxes`,
`CreateProvider`, etc.) are the **control plane**: the gateway stores the
provider and profile and hands the supervisor its credentials, and never sees
the inference request bytes.

## What's NOT exposed

- No HTTP/JSON transcoding. `POST /openshell.v1.OpenShell/ListSandboxes`
  with `Content-Type: application/json` returns 404. The chart does
  not enable grpc-gateway.
- No Connect-RPC or gRPC-Web. The `Connect-Protocol-Version: 1` header doesn't
  unlock anything.
- No anonymous metrics scraping if you don't expose `gatewayService`
  — the chart's NetworkPolicy admits in-cluster pods only.
