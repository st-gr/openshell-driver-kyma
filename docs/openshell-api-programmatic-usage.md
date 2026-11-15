# Programmatic OpenShell API usage

> **Written for upstream OpenShell v0.1.8 / chart 0.14.0.** The Python sample
> below is verified: its requests are built from stubs generated from the
> v0.1.8 protos, and it ran live on 2026-11-15 against a 0.14.0 release through
> `gatewayIngress` with an OIDC bearer token, and on 2026-11-14 against a scratch
> 0.13.0 release with a client certificate over a port-forward.

This guide is for engineers who drive OpenShell sandboxes from their own
services or scripts instead of the `openshell` CLI. It covers how to reach
and authenticate to the gateway, how to generate a client from upstream's
protos, and a worked Python flow: list sandboxes, create one, wait until it is
ready, run a command in it, and delete it.

For one-off calls from a shell (`grpcurl`, server reflection) see
[`grpc-without-cli.md`](grpc-without-cli.md).

## Table of contents

1. [API surface](#api-surface)
2. [Workspaces](#workspaces)
3. [Reaching the gateway](#reaching-the-gateway)
4. [Authentication](#authentication)
5. [Generating a client](#generating-a-client)
6. [Worked example: Python](#worked-example-python)
7. [Beyond the sample](#beyond-the-sample)
8. [Worked example: TypeScript](#worked-example-typescript)
9. [Operational notes](#operational-notes)
10. [References](#references)

## API surface

The gateway serves native gRPC over HTTP/2 only. There is no REST surface, no
gRPC-Web and no Connect protocol: a browser client needs its own gRPC-Web
proxy, which this chart does not provide.

- Package: `openshell.v1`
- Service: `OpenShell` (86 RPCs in v0.1.8), plus `SandboxUpdates`, both in
  [`proto/openshell.proto`](https://github.com/NVIDIA/OpenShell/blob/v0.1.8/proto/openshell.proto)
- Server reflection is on, so `grpcurl` can list and describe methods without
  the proto files (see [`grpc-without-cli.md`](grpc-without-cli.md)).

The RPCs a programmatic caller usually needs:

| Concern | RPC | Streaming |
|---|---|---|
| Health probe (no credentials needed) | `Health` | unary |
| Who am I (as the gateway sees the caller) | `GetCurrentUser` | unary |
| Sandbox lifecycle | `CreateSandbox`, `GetSandbox`, `ListSandboxes`, `DeleteSandbox` | unary |
| Follow a sandbox's status | `WatchSandbox` | server stream |
| Run a command | `ExecSandbox` | server stream (stdout, stderr, exit) |
| Run a command with streamed stdin or a TTY | `ExecSandboxInteractive` | bidirectional |
| Credentials for sandboxes | `CreateProvider`, `ListProviderProfiles`, `AttachSandboxProvider` | unary |
| Reach a TCP port inside a sandbox | `ForwardTcp` | bidirectional |
| Expose an HTTP service of a sandbox | `ExposeService`, `GetService`, `ListServices`, `DeleteService` | unary |
| Workspaces and members | `CreateWorkspace`, `ListWorkspaces`, `AddWorkspaceMember`, ... | unary |

The rest (policy, draft-policy review, supervisor relay, logs, tokens, peer
calls) is mostly for the CLI, sandboxes and other gateways.

## Workspaces

Every sandbox and provider belongs to a workspace, and every call about them
carries a `workspace_scope` (`openshell.datamodel.v1.WorkspaceSelector`). Name
one workspace; the gateway's default workspace is `default`:

```python
dm.WorkspaceSelector(workspace="default")
```

Without it the gateway answers `workspace_scope is required`. Only a few calls,
such as `ListSandboxes`, also accept `all_workspaces`, and only for a platform
admin.

A caller with the platform admin role may use every workspace. A caller with
only the user role must be a member of the workspace, or the gateway answers
`not a member of workspace 'default'`. An admin adds members with
`openshell workspace member add --workspace default --subject <subject> --role user`
(see [`sap-ias-setup.md`](sap-ias-setup.md#8-log-in-and-grant-workspaces)).

## Reaching the gateway

The gateway runs next to the driver in the chart's pod. It is reachable over
the network only with `gateway.enabled=true` and `gatewayService.enabled=true`.
Both default to `false`; [`values.example.yaml`](../deploy/helm/openshell-driver-kyma/values.example.yaml)
sets them. The Service is named after the release:
`<release>-openshell-driver-kyma`, gRPC on port `8080` (`gateway.grpcPort`).

| From | Endpoint |
|---|---|
| Inside the cluster, same namespace | `<release>-openshell-driver-kyma:8080` |
| Inside the cluster, other namespace | `<release>-openshell-driver-kyma.<namespace>.svc.cluster.local:8080` |
| Laptop port-forward | `kubectl -n <namespace> port-forward svc/<release>-openshell-driver-kyma 8080:8080`, then `localhost:8080` |
| Public, with `gatewayIngress.enabled` | `openshell.<cluster-domain>:443` (`gatewayIngress.host`) |

TLS depends on the chart values:

- `gateway.tls.enabled=false` (default): the gateway serves plaintext. Use an
  insecure channel, and only inside the cluster or through a port-forward.
- `gateway.tls.enabled=true`: the gateway serves TLS with a certificate from
  the chart CA. Clients verify it with that CA (`ca.crt` in the
  `<release>-openshell-driver-kyma-client-tls` Secret). The PKI hook's certificate
  names the Service, its in-cluster DNS names, `localhost` and `127.0.0.1`, so a
  port-forward verifies too.
- `gatewayIngress`: the Kyma ingress gateway terminates the client's TLS with
  the cluster's public certificate (the system trust store verifies it) and
  re-encrypts to the gateway. It needs `gateway.tls.enabled` and an OIDC issuer,
  and the gateway still checks the token of every call. See
  [`production-deployment.md`](production-deployment.md).

For private routing through SAP Cloud Connector see
[`cloud-connector-setup.md`](cloud-connector-setup.md); the client then dials a
local port as with a port-forward.

## Authentication

The chart values decide what the gateway expects from a caller:

| Chart values | The caller sends |
|---|---|
| No `gateway.oidc.issuer`, no `gateway.tls.clientCa.enabled` (default) | nothing |
| `gateway.tls.clientCa.enabled`, no issuer | a client certificate signed by the CA |
| `gateway.oidc.issuer` set | `authorization: Bearer <access token>` metadata on every call |

**OIDC bearer token.** The token must be issued for the gateway's audience
(`gateway.oidc.audience`) and carry a role. By default upstream reads the
roles from `realm_access.roles` and expects `openshell-admin` or
`openshell-user`; `gateway.oidc.rolesClaim`, `adminRole` and `userRole` change
that, and `gateway.oidc.authOnly: true` makes every authenticated identity a
platform admin. A user-role caller also needs workspace membership
([Workspaces](#workspaces)). Only when `gateway.oidc.scopesClaim` is set does
the gateway also check scopes: the sandbox calls need `sandbox:read` or
`sandbox:write` (or `openshell:all`). How to get such a token depends on your
identity provider: a person logs in through it, and a service usually uses the
client-credentials grant of a confidential client, as the chart's inference
provider hook does. For SAP Cloud Identity Services see
[`sap-ias-setup.md`](sap-ias-setup.md); for other providers see
[`production-deployment.md`](production-deployment.md).

**Client certificate (mTLS).** With `gateway.tls.clientCa.enabled` and no
issuer, the gateway accepts a client certificate signed by the chart CA:
`tls.crt` and `tls.key` from the `<release>-openshell-driver-kyma-client-tls`
Secret. Without OIDC, every authenticated caller is a platform admin. Sandboxes
hold the same certificate, so anyone who can read it inside a sandbox can act
as a user. This does not work through `gatewayIngress`, because the ingress
gateway presents no client certificate. See
[`production-deployment.md`](production-deployment.md).

Kubernetes ServiceAccount tokens are not a user credential: upstream accepts
them only for calls between gateway replicas.

## Generating a client

`openshell.proto` imports three more files from the same directory and three
Google well-known types (which `grpcio-tools` and `protoc` ship). Fetch the
four files at the tag your gateway runs:

```bash
mkdir -p proto gen
for f in openshell datamodel sandbox options; do
  curl -fsSL "https://raw.githubusercontent.com/NVIDIA/OpenShell/v0.1.8/proto/$f.proto" \
    -o "proto/$f.proto"
done
```

Python (the protos import each other by bare file name, so generate into one
flat directory and put it on `sys.path`):

```bash
python3 -m venv .venv
.venv/bin/pip install grpcio grpcio-tools protobuf
.venv/bin/python -m grpc_tools.protoc -I proto --python_out=gen --grpc_python_out=gen \
  proto/openshell.proto proto/datamodel.proto proto/sandbox.proto proto/options.proto
```

This yields `openshell_pb2.py` (package `openshell.v1`), `datamodel_pb2.py`
(`openshell.datamodel.v1`: `WorkspaceSelector`, `ObjectMeta`, `Provider`),
`sandbox_pb2.py`, `options_pb2.py` and the `*_pb2_grpc.py` client stubs. The
generated stubs require a `grpcio` at least as new as the `grpcio-tools` that
made them.

Other languages use their own protoc plugin on the same four files. Upstream's
Rust crate `openshell-core` compiles them with `tonic-prost-build`.

## Worked example: Python

The script below lists the sandboxes in a workspace, creates a small sandbox
that runs `sleep infinity`, follows `WatchSandbox` until the sandbox is
`SANDBOX_PHASE_READY`, runs `echo hello` with `ExecSandbox`, and deletes the
sandbox. It reads its settings from the environment:

| Variable | Meaning |
|---|---|
| `OPENSHELL_ENDPOINT` | `host:port`, default `localhost:8080` |
| `OPENSHELL_PLAINTEXT=1` | insecure channel (gateway without TLS) |
| `OPENSHELL_TOKEN` | OIDC access token, sent as `authorization: Bearer` |
| `OPENSHELL_CA_CERT` | CA file to verify the gateway (unset: system trust store) |
| `OPENSHELL_CLIENT_CERT`, `OPENSHELL_CLIENT_KEY` | client certificate and key (mTLS) |
| `OPENSHELL_WORKSPACE` | workspace, default `default` |
| `OPENSHELL_IMAGE` | sandbox image; unset uses the gateway's default (`driver.sandboxImage`) |

Save it as `sample.py` next to the `gen/` directory:

```python
#!/usr/bin/env python3
"""List sandboxes, create one, wait for Ready, exec `echo hello`, delete it.

Stubs generated from upstream OpenShell v0.1.8 protos into ./gen.
"""
import os
import sys
import uuid

import grpc

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen"))
import datamodel_pb2 as dm  # noqa: E402
import openshell_pb2 as pb  # noqa: E402
import openshell_pb2_grpc as rpc  # noqa: E402

ENDPOINT = os.environ.get("OPENSHELL_ENDPOINT", "localhost:8080")
WORKSPACE = os.environ.get("OPENSHELL_WORKSPACE", "default")
IMAGE = os.environ.get("OPENSHELL_IMAGE", "")  # "" = the gateway's default image


def read(path):
    with open(path, "rb") as f:
        return f.read()


def connect():
    """Return (channel, metadata) from the OPENSHELL_* environment variables."""
    token = os.environ.get("OPENSHELL_TOKEN", "")
    metadata = (("authorization", f"Bearer {token}"),) if token else ()
    if os.environ.get("OPENSHELL_PLAINTEXT") == "1":
        return grpc.insecure_channel(ENDPOINT), metadata
    ca = os.environ.get("OPENSHELL_CA_CERT")
    cert = os.environ.get("OPENSHELL_CLIENT_CERT")
    key = os.environ.get("OPENSHELL_CLIENT_KEY")
    creds = grpc.ssl_channel_credentials(
        root_certificates=read(ca) if ca else None,  # None = system trust store
        private_key=read(key) if key else None,
        certificate_chain=read(cert) if cert else None,
    )
    return grpc.secure_channel(ENDPOINT, creds), metadata


def ws():
    return dm.WorkspaceSelector(workspace=WORKSPACE)


def list_sandboxes(stub, md):
    names, token = [], ""
    while True:
        resp = stub.ListSandboxes(
            pb.ListSandboxesRequest(workspace_scope=ws(), page_size=100, page_token=token),
            metadata=md, timeout=30,
        )
        names += [s.metadata.name for s in resp.sandboxes]
        token = resp.next_page_token
        if not token:
            return names


def create_sandbox(stub, md, name):
    spec = pb.SandboxSpec(command=["sleep", "infinity"])
    if IMAGE:
        spec.template.image = IMAGE
    resp = stub.CreateSandbox(
        pb.CreateSandboxRequest(
            workspace_scope=ws(), name=name, spec=spec,
            labels={"created-by": "api-sample"},
        ),
        metadata=md, timeout=60,
    )
    return resp.sandbox


def wait_ready(stub, md, name, timeout=300):
    req = pb.WatchSandboxRequest(
        workspace_scope=ws(), sandbox=name, follow_status=True, stop_on_terminal=True,
    )
    for ev in stub.WatchSandbox(req, metadata=md, timeout=timeout):
        if not ev.HasField("sandbox"):
            continue
        phase = ev.sandbox.status.phase
        print(f"  phase: {pb.SandboxPhase.Name(phase)}")
        if phase == pb.SANDBOX_PHASE_READY:
            return
        if phase in (pb.SANDBOX_PHASE_ERROR, pb.SANDBOX_PHASE_STOPPED,
                     pb.SANDBOX_PHASE_COMPLETED):
            raise RuntimeError(f"sandbox {name} ended in {pb.SandboxPhase.Name(phase)}")
    raise RuntimeError(f"watch ended before sandbox {name} was ready")


def exec_command(stub, md, name, command):
    req = pb.ExecSandboxRequest(workspace_scope=ws(), sandbox=name, command=command)
    out, code = b"", None
    for ev in stub.ExecSandbox(req, metadata=md, timeout=60):
        if ev.HasField("stdout"):
            out += ev.stdout.data
        elif ev.HasField("stderr"):
            sys.stderr.buffer.write(ev.stderr.data)
        elif ev.HasField("exit"):
            code = ev.exit.exit_code
    return code, out


def delete_sandbox(stub, md, name):
    resp = stub.DeleteSandbox(
        pb.DeleteSandboxRequest(workspace_scope=ws(), name=name, allow_missing=True),
        metadata=md, timeout=60,
    )
    return pb.DeletionOutcome.Name(resp.outcome)


def run(stub, md):
    print("health:", stub.Health(pb.HealthRequest(), timeout=10).version)
    print(f"sandboxes in {WORKSPACE!r}:", list_sandboxes(stub, md))
    name = f"api-sample-{uuid.uuid4().hex[:6]}"
    sandbox = create_sandbox(stub, md, name)
    print("created:", sandbox.metadata.name)
    try:
        wait_ready(stub, md, name)
        code, out = exec_command(stub, md, name, ["echo", "hello"])
        print(f"exec exit={code} stdout={out.decode().strip()!r}")
    finally:
        print("delete:", delete_sandbox(stub, md, name))


def main():
    channel, md = connect()
    with channel:
        run(rpc.OpenShellStub(channel), md)


if __name__ == "__main__":
    main()
```

Run it:

```bash
# Through gatewayIngress, with an OIDC token
OPENSHELL_ENDPOINT=openshell.<cluster-domain>:443 OPENSHELL_TOKEN=<access token> \
  .venv/bin/python sample.py

# Through a port-forward to a gateway without TLS
OPENSHELL_ENDPOINT=localhost:8080 OPENSHELL_PLAINTEXT=1 .venv/bin/python sample.py

# Through a port-forward to a gateway with TLS and a client CA
OPENSHELL_ENDPOINT=localhost:8080 OPENSHELL_CA_CERT=ca.crt \
  OPENSHELL_CLIENT_CERT=tls.crt OPENSHELL_CLIENT_KEY=tls.key .venv/bin/python sample.py
```

Points worth knowing about the request shapes:

- **`CreateSandbox`** takes the sandbox definition in `spec` (`SandboxSpec`):
  `command`, `environment`, `providers`, and `template.image` for the image.
  The response is a `SandboxResponse` whose `sandbox` has `metadata`
  (`ObjectMeta`: `name`, `id`, `workspace`, `labels`), `spec` and `status`. An
  existing name fails with `ALREADY_EXISTS`; an empty name lets the gateway pick
  one.
- **`WatchSandbox`** names the sandbox in `sandbox`. With `follow_status` it
  streams `SandboxStreamEvent`s whose `sandbox` field holds a status snapshot
  (other events carry logs, platform events or warnings). The lifecycle is
  `sandbox.status.phase` (`SandboxPhase`: `PROVISIONING`, `READY`, `ERROR`,
  `DELETING`, `STOPPED`, `COMPLETED`, ...). `stop_on_terminal` ends the stream
  at `READY` or a terminal phase.
- **`ExecSandbox`** names the sandbox in `sandbox` and streams
  `ExecSandboxEvent`s: `stdout.data` and `stderr.data` (bytes), then
  `exit.exit_code`. By default the command runs through a login shell
  (`no_login_shell` turns that off). Other fields: `workdir`, `environment`,
  `execution_timeout`, `stdin`, `tty`.
- **`DeleteSandbox`** returns an `outcome` (`DeletionOutcome`). With
  `allow_missing=True` a missing sandbox is `ALREADY_ABSENT` rather than an
  error. `ACCEPTED` means the gateway record still exists while the deletion
  finishes.

## Beyond the sample

These snippets use the sample's `pb`, `dm`, `ws()`, stub and metadata, and the
file snippets also `import io, tarfile`. They are checked against the v0.1.8
stubs like the sample.

### Credentials: providers

A provider holds a credential for sandboxes. Its `type` is the ID of a provider
profile already on the gateway (`ListProviderProfiles`); the chart's inference
provider hook imports one named `kyma-<type>`, for example `kyma-anthropic`.
The credential keys are the profile's environment variable names.

```python
def provider_snippet(stub, md, name):
    stub.CreateProvider(pb.CreateProviderRequest(
        workspace_scope=ws(),
        provider=dm.Provider(
            metadata=dm.ObjectMeta(name="my-anthropic"),
            type="kyma-anthropic",  # a profile ID from ListProviderProfiles
            credentials={"ANTHROPIC_API_KEY": os.environ["ANTHROPIC_API_KEY"]},
        ),
    ), metadata=md, timeout=30)
    # At creation: pb.SandboxSpec(..., providers=["my-anthropic"]). Later:
    stub.AttachSandboxProvider(pb.AttachSandboxProviderRequest(
        workspace_scope=ws(), sandbox=name, provider="my-anthropic",
    ), metadata=md, timeout=30)
```

### Files in and out

There is no file-transfer RPC. Pipe a tar archive through a command instead,
or use `openshell sandbox upload` / `download` from the CLI.

Small files fit in one `ExecSandbox` request (`stdin` bytes). The gateway
refuses any inbound message over 1 MiB, the request included:

```python
def upload_small(stub, md, name, local_path, remote_dir):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        tar.add(local_path, arcname=os.path.basename(local_path))
    req = pb.ExecSandboxRequest(
        workspace_scope=ws(), sandbox=name,
        command=["tar", "-xf", "-", "-C", remote_dir],
        stdin=buf.getvalue(),  # the whole request must stay under 1 MiB
    )
    for ev in stub.ExecSandbox(req, metadata=md, timeout=120):
        if ev.HasField("exit") and ev.exit.exit_code != 0:
            raise RuntimeError(f"tar -x exited {ev.exit.exit_code}")
```

Downloads arrive as a stream of `stdout` chunks, so they have no such limit:

```python
def download(stub, md, name, remote_dir, remote_name, local_dir):
    req = pb.ExecSandboxRequest(
        workspace_scope=ws(), sandbox=name,
        command=["tar", "-cf", "-", "-C", remote_dir, remote_name],
    )
    buf = io.BytesIO()
    for ev in stub.ExecSandbox(req, metadata=md, timeout=120):
        if ev.HasField("stdout"):
            buf.write(ev.stdout.data)
        elif ev.HasField("exit") and ev.exit.exit_code != 0:
            raise RuntimeError(f"tar -c exited {ev.exit.exit_code}")
    buf.seek(0)
    with tarfile.open(fileobj=buf) as tar:
        tar.extractall(local_dir, filter="data")
```

Larger uploads go through `ExecSandboxInteractive`. The first
`ExecSandboxInput` carries the `start` request; later ones carry raw `stdin`
bytes (keep each well under 1 MiB) or a `resize` for a TTY. Ending the
request stream closes the command's stdin:

```python
def upload_stream(stub, md, name, payload, remote_path):
    def frames():
        yield pb.ExecSandboxInput(start=pb.ExecSandboxRequest(
            workspace_scope=ws(), sandbox=name,
            command=["sh", "-c", 'cat > "$1"', "sh", remote_path],
        ))
        for i in range(0, len(payload), 256 * 1024):
            yield pb.ExecSandboxInput(stdin=payload[i:i + 256 * 1024])
        # Returning ends the request stream, which closes the command's stdin.

    for ev in stub.ExecSandboxInteractive(frames(), metadata=md):
        if ev.HasField("exit") and ev.exit.exit_code != 0:
            raise RuntimeError(f"upload exited {ev.exit.exit_code}")
```

### TCP forwarding

`ForwardTcp` is a bidirectional stream of `TcpForwardFrame`s. The first frame
is `init` with the sandbox, its workspace and the target; after that both
sides send `data` bytes. In v0.1.8 the TCP target must be a loopback address
inside the sandbox (`127.0.0.1`, `::1` or `localhost`):

```python
def forward_first_frame(name):
    return pb.TcpForwardFrame(init=pb.TcpForwardInit(
        sandbox=name, workspace="default",
        tcp=pb.TcpRelayTarget(host="127.0.0.1", port=8000),
    ))
```

For reaching a sandbox's HTTP service from outside, `openshell service expose`
is the supported route; see
[`production-deployment.md`](production-deployment.md#reaching-a-service-inside-a-sandbox).

## Worked example: TypeScript

A shorter Node version of the same flow with plain
[`@grpc/grpc-js`](https://www.npmjs.com/package/@grpc/grpc-js), loading the
same four proto files at runtime with `@grpc/proto-loader`. `keepCase: true`
keeps the proto field names (`workspace_scope`, `follow_status`, ...), so they
match the Python sample. This sample has not been run; the field names are
those of the v0.1.8 protos.

```typescript
import * as grpc from "@grpc/grpc-js";
import * as protoLoader from "@grpc/proto-loader";

const def = protoLoader.loadSync("proto/openshell.proto", {
  includeDirs: ["proto"], keepCase: true, enums: String, longs: String,
  defaults: true, oneofs: true,
});
const pkg = grpc.loadPackageDefinition(def) as any;
const creds = process.env.OPENSHELL_PLAINTEXT === "1"
  ? grpc.credentials.createInsecure()
  : grpc.credentials.createSsl(); // createSsl(ca, key, cert) for mTLS
const client = new pkg.openshell.v1.OpenShell(
  process.env.OPENSHELL_ENDPOINT ?? "localhost:8080", creds);
const md = new grpc.Metadata();
if (process.env.OPENSHELL_TOKEN) md.set("authorization", `Bearer ${process.env.OPENSHELL_TOKEN}`);
const ws = { workspace: process.env.OPENSHELL_WORKSPACE ?? "default" };

const unary = (method: string, req: object): Promise<any> =>
  new Promise((resolve, reject) =>
    client[method](req, md, (err: grpc.ServiceError | null, res: any) =>
      err ? reject(err) : resolve(res)));

async function main() {
  const name = `api-sample-${Date.now().toString(36)}`;
  await unary("CreateSandbox", { workspace_scope: ws, name, spec: { command: ["sleep", "infinity"] } });
  try {
    const watch = client.WatchSandbox(
      { workspace_scope: ws, sandbox: name, follow_status: true, stop_on_terminal: true }, md);
    for await (const ev of watch) {
      if (ev.payload !== "sandbox") continue;
      const phase = ev.sandbox.status?.phase;
      if (phase === "SANDBOX_PHASE_READY") break;
      if (phase === "SANDBOX_PHASE_ERROR") throw new Error(`sandbox ${name} failed`);
    }
    const exec = client.ExecSandbox({ workspace_scope: ws, sandbox: name, command: ["echo", "hello"] }, md);
    for await (const ev of exec) {
      if (ev.payload === "stdout") process.stdout.write(ev.stdout.data);
      if (ev.payload === "exit") console.log("exit", ev.exit.exit_code);
    }
  } finally {
    await unary("DeleteSandbox", { workspace_scope: ws, name, allow_missing: true });
  }
}

main();
```

## Operational notes

- **Message size.** The gateway accepts inbound gRPC messages up to 1 MiB
  (upstream's `MAX_GRPC_DECODE_SIZE`, in place of tonic's 4 MiB default). This
  covers a whole `ExecSandboxRequest` including `stdin` and each
  `ExecSandboxInput` frame. It applies to what the gateway receives, not to
  what it streams back.
- **Retries.** `CreateSandbox`, `DeleteSandbox`, `CreateProvider`,
  `AttachSandboxProvider` and `ExecSandbox` take an optional `request_id` (a
  nonzero UUID). A retry with the same `request_id` does not create or run
  anything twice; see the field comments in `openshell.proto`.
- **Cleanup.** Label your sandboxes at creation and clean up leftovers with
  `ListSandboxes(label_selector="created-by=api-sample")`, following
  `next_page_token` until it is empty, then `DeleteSandbox` with
  `allow_missing=True`.
- **Rate limit.** With `gateway.grpcRateLimit` set, the gateway limits gRPC
  requests per window; reflection calls have their own counter with the same
  limit.
- **Gateway TLS changes.** Sandboxes created before `gateway.tls.enabled` was
  turned on keep the plaintext endpoint and must be recreated
  ([`production-deployment.md`](production-deployment.md#upgrading-to-gateway-tls)).

## References

- Upstream protos at v0.1.8: <https://github.com/NVIDIA/OpenShell/tree/v0.1.8/proto>
- Upstream project: <https://github.com/NVIDIA/OpenShell>
- [`grpc-without-cli.md`](grpc-without-cli.md): `grpcurl` and reflection
- [`production-deployment.md`](production-deployment.md): OIDC, TLS, mTLS and `gatewayIngress`
- [`sap-ias-setup.md`](sap-ias-setup.md): SAP Cloud Identity Services as the identity provider
- [`cloud-connector-setup.md`](cloud-connector-setup.md): private routing through SAP Cloud Connector
