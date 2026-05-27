# Programmatic OpenShell API usage

This guide is for engineers who need to drive OpenShell sandboxes from
their own services or scripts — without going through the `openshell`
CLI. It covers the gateway's gRPC API, how to reach it from outside the
cluster, the lifecycle of a Claude Code (or any other agent) sandbox,
and three practical patterns for uploading and downloading files.

> **Scope.** Everything below targets the OpenShell gateway's public
> surface (`openshell.v1.OpenShell`), which the upstream NVIDIA project
> publishes under Apache-2.0. The gateway's *internal* contract with
> compute drivers — `compute_driver.proto`, what
> `openshell-driver-kyma` itself implements — is documented separately
> in [`docs/superpowers/specs/2026-05-26-openshell-driver-kyma-design.md`](superpowers/specs/2026-05-26-openshell-driver-kyma-design.md).

## Table of contents

1. [API surface](#api-surface)
2. [Reaching the gateway](#reaching-the-gateway)
3. [Generating a client](#generating-a-client)
4. [Authentication](#authentication)
5. [Sandbox lifecycle](#sandbox-lifecycle)
6. [Running commands inside the sandbox](#running-commands-inside-the-sandbox)
7. [File upload patterns](#file-upload-patterns)
8. [File download patterns](#file-download-patterns)
9. [Streaming Claude Code interactively](#streaming-claude-code-interactively)
10. [Tear-down and resource cleanup](#tear-down-and-resource-cleanup)
11. [Complete worked example: Python](#complete-worked-example-python)
12. [Complete worked example: TypeScript](#complete-worked-example-typescript)
13. [Operational notes](#operational-notes)
14. [References](#references)

## API surface

The gateway speaks **pure gRPC** (HTTP/2). One service, one package:

- Package: `openshell.v1`
- Service: `OpenShell` (defined in
  [`proto/openshell.proto`](https://raw.githubusercontent.com/NVIDIA/OpenShell/main/proto/openshell.proto))

There are no `google.api.http` annotations, so **there is no
auto-generated REST surface**. Browser-side and Connect-protocol clients
are supported by the underlying tonic stack; native gRPC works
everywhere else.

The RPCs you actually need for "spin up Claude Code, talk to it, copy
files in and out, tear down" are a small subset:

| Concern | RPC | Streaming |
|---|---|---|
| Provider config (one-time per credential) | `CreateProvider`, `GetProvider`, `ListProviders`, `UpdateProvider`, `DeleteProvider` | unary |
| Attach provider to a sandbox | `AttachSandboxProvider` | unary |
| Sandbox lifecycle | `CreateSandbox`, `GetSandbox`, `ListSandboxes`, `DeleteSandbox`, `WatchSandbox` | `WatchSandbox` is server-stream |
| Run a command (one-shot) | `ExecSandbox` | server-stream (stdout/stderr until exit) |
| Run a command (PTY / pipes / interactive) | `ExecSandboxInteractive` | bidi-stream |
| Open an SSH session | `CreateSshSession`, `RevokeSshSession` | unary |
| Forward a TCP port to/from the sandbox | `ForwardTcp` | bidi-stream |
| Expose a sandbox-local HTTP service | `ExposeService`, `GetService`, `ListServices`, `DeleteService` | unary |
| Health probe | `Health` | unary |

The full RPC list (and the associated message schemas) lives in
upstream `openshell.proto`. It includes ~60 RPCs covering policy,
draft-policy review, supervisor relay, logs, and tokens — most of which
you won't touch from a programmatic caller.

## Reaching the gateway

Pick one of the two patterns based on whether you want public ingress
or VPN-only routing:

### A. Public hostname via Kyma `APIRule`

When the `openshell-driver-kyma` Helm chart is installed with
`--set driver.enableApirule=true` and a hostname, Kyma's API Gateway
exposes the gateway at `https://<release>.<cluster-id>.kyma.ondemand.com`.
Lock it down to your VPN egress IPs with an
`AuthorizationPolicy` on the Istio ingress. Native gRPC clients dial
the `:443` HTTPS endpoint.

### B. Private routing via SAP Cloud Connector

Documented in [`docs/cloud-connector-setup.md`](cloud-connector-setup.md).
Service Channel for Kubernetes + `kubectl port-forward
svc/openshell-gateway 8080:8080 -n openshell-system`. Your client dials
`http://localhost:8080` (gRPC over plaintext HTTP/2 since it's loopback).

## Generating a client

You only need the proto file from upstream. Pin it to a known commit so
your generated stubs don't drift unexpectedly:

```bash
mkdir -p proto/openshell-v1
curl -fsSL \
  https://raw.githubusercontent.com/NVIDIA/OpenShell/<sha>/proto/openshell.proto \
  -o proto/openshell-v1/openshell.proto
curl -fsSL \
  https://raw.githubusercontent.com/NVIDIA/OpenShell/<sha>/proto/datamodel.proto \
  -o proto/openshell-v1/datamodel.proto
curl -fsSL \
  https://raw.githubusercontent.com/NVIDIA/OpenShell/<sha>/proto/sandbox.proto \
  -o proto/openshell-v1/sandbox.proto
```

Then run your language's protoc plugin:

| Language | Tool |
|---|---|
| Python | `python -m grpc_tools.protoc -I proto --python_out=gen --grpc_python_out=gen proto/openshell-v1/*.proto` |
| TypeScript | `buf generate --template buf.gen.yaml proto/openshell-v1` (with `@bufbuild/protoc-gen-es` + `@connectrpc/protoc-gen-connect-es`) |
| Go | `protoc -I proto --go_out=gen --go-grpc_out=gen proto/openshell-v1/*.proto` |
| Rust | add `tonic-prost-build = "0.14"` to `build.rs` and call `compile_protos` (mirrors what `crates/computev1` does in this repo) |

## Authentication

The gateway authenticates clients with a bearer token issued by your
identity provider (the OpenShell Helm chart configures this — typically
SAP IAS / OIDC for BTP-Kyma deployments). Pass it as a gRPC metadata
header:

```python
metadata = (("authorization", f"Bearer {token}"),)
stub.CreateSandbox(req, metadata=metadata)
```

For mTLS deployments (gateway behind a Service mesh that requires
client certs), supply the cert and key when you build the gRPC channel
— `grpc.ssl_channel_credentials(root_certs, private_key, cert_chain)`
in Python, or `Channel::from_static(...).tls_config(...)` in Tonic.

When running entirely inside the cluster, ServiceAccount token
projection (`automountServiceAccountToken: true` plus a TokenRequest
volume) is enough — the gateway accepts the SA token.

## Sandbox lifecycle

### 1. Create the provider once

Each external credential (an Anthropic API key, an OpenAI key, etc.)
maps to one `Provider` record. The driver injects the credential as
environment variables into every sandbox the provider is attached to.

```python
stub.CreateProvider(pb.CreateProviderRequest(
    name="anthropic-prod",
    type="anthropic",
    credentials={"ANTHROPIC_API_KEY": os.environ["ANTHROPIC_API_KEY"]},
))
```

The provider type names (`anthropic`, `openai`, `google`, `xai`,
`bedrock`, `ollama`, etc.) come from the upstream provider catalog —
`ListProviderProfiles` returns the catalog at runtime if you need the
canonical list.

### 2. Create the sandbox

```python
sandbox = stub.CreateSandbox(pb.CreateSandboxRequest(
    image="ghcr.io/nvidia/openshell-community/sandboxes/base:latest",
    command=["sleep", "infinity"],
    provider="anthropic-prod",       # attaches the provider above
    labels={"owner": "my-service"},
)).sandbox
```

The `image` is the agent container the supervisor wraps. For Claude
Code specifically, NVIDIA publishes
`quay.io/azaalouk/demo-sandbox-claude:latest` (Apache-2.0); your
deployment's chart values can default it.

### 3. Wait for `Ready`

```python
for ev in stub.WatchSandbox(pb.WatchSandboxRequest(name=sandbox.name)):
    if ev.state == pb.SANDBOX_STATE_READY:
        break
    if ev.state in (pb.SANDBOX_STATE_FAILED, pb.SANDBOX_STATE_DELETED):
        raise RuntimeError(f"sandbox failed: {ev.message}")
```

Typical Ready time is 5-30 s on a warm Kyma cluster (image already
cached on the node). Cold start can take a minute when the image
needs to pull.

## Running commands inside the sandbox

Two RPCs, two use cases.

### `ExecSandbox` — one-shot, server-streamed

You send a request with the command and arguments; the gateway
streams stdout/stderr back until the process exits.

```python
req = pb.ExecSandboxRequest(
    name=sandbox.name,
    command=["claude", "--version"],
)
for ev in stub.ExecSandbox(req):
    if ev.HasField("stdout"):
        sys.stdout.buffer.write(ev.stdout)
    if ev.HasField("stderr"):
        sys.stderr.buffer.write(ev.stderr)
    if ev.HasField("exit"):
        return ev.exit.code
```

Use this for short, scripted invocations: `claude --version`,
`pip install ...`, `git clone ...`.

### `ExecSandboxInteractive` — PTY, bidi-streamed

You send `ExecSandboxInput` frames (start, stdin, resize, signal,
close); the gateway returns `ExecSandboxEvent` frames
(stdout/stderr/exit). This is the right tool for an interactive
Claude Code session, a debug shell, or anything that needs a real
TTY.

See the [interactive Claude example](#streaming-claude-code-interactively)
below.

## File upload patterns

There is **no dedicated file-transfer RPC** in the OpenShell gateway.
Three established patterns layer on top of the existing byte streams.
Pick by file size and by whether the sandbox already has the right
tools.

### Pattern 1 — `tar` over `ExecSandbox` stdin (most portable)

Streams a tar archive into the sandbox via the bidi exec stream and
extracts it server-side. Works for any agent image that ships `tar`
(virtually all of them). Best for batches up to a few hundred MB; the
data goes through gRPC framing so very large transfers add latency.

```python
import tarfile, io

def tar_bytes(local_paths: list[str]) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for p in local_paths:
            tar.add(p, arcname=os.path.basename(p))
    return buf.getvalue()

def upload(stub, sandbox_name: str, local_paths: list[str], remote_dir: str):
    payload = tar_bytes(local_paths)

    def gen():
        # 1. Start the command: tar -x in the target directory.
        yield pb.ExecSandboxInput(start=pb.ExecStart(
            name=sandbox_name,
            command=["tar", "-xC", remote_dir],
            tty=False,
        ))
        # 2. Stream the archive bytes as stdin frames.
        for chunk in chunks(payload, 256 * 1024):
            yield pb.ExecSandboxInput(stdin=pb.ExecStdin(data=chunk))
        # 3. Close stdin so tar finishes.
        yield pb.ExecSandboxInput(close_stdin=pb.ExecCloseStdin())

    for ev in stub.ExecSandboxInteractive(gen()):
        if ev.HasField("exit") and ev.exit.code != 0:
            raise RuntimeError(f"tar failed: {ev.exit.code}")

def chunks(b: bytes, n: int):
    for i in range(0, len(b), n):
        yield b[i:i+n]
```

### Pattern 2 — SSH/SCP via `CreateSshSession` (best for arbitrary tooling)

The gateway issues a one-shot SSH session bound to the sandbox.
Returns a host, port, username, and private key. From there you use
**any** SSH-aware tool (`scp`, `rsync`, `sftp`, `ssh`, `mosh`).

```python
session = stub.CreateSshSession(pb.CreateSshSessionRequest(
    sandbox=sandbox.name,
    ttl_seconds=900,
)).session

# session.host, session.port, session.username, session.private_key
# Write key to a tmpfile and call scp:
with tempfile.NamedTemporaryFile("w", delete=False) as f:
    f.write(session.private_key)
    keyfile = f.name
os.chmod(keyfile, 0o600)

subprocess.check_call([
    "scp", "-i", keyfile, "-P", str(session.port),
    "-o", "StrictHostKeyChecking=no",
    "local-file.tar.gz",
    f"{session.username}@{session.host}:/workspace/",
])
```

This is the most flexible pattern: you get the full SSH wire
protocol, including parallel transfers, partial resume, and `rsync`'s
delta sync. It also gives you an interactive `ssh` if the
`ExecSandboxInteractive` PTY isn't enough.

When done, `RevokeSshSession` invalidates the credentials early.
Otherwise they expire on `ttl_seconds`.

### Pattern 3 — TCP-forwarded HTTP/S3 server (best for very large files)

Run a tiny HTTP server inside the sandbox, then ask the gateway to
forward a local TCP port to it. Stream files at line rate without
gRPC framing overhead.

```bash
# Inside the sandbox (one-time, started by your orchestration script):
python3 -m http.server 8080 --directory /workspace
```

```python
# Local side: open a ForwardTcp bidi stream that maps localhost:9000 -> sandbox:8080
def forward(stub, sandbox_name):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 9000)); listener.listen(1)
    sock, _ = listener.accept()

    def gen():
        yield pb.TcpForwardFrame(start=pb.TcpForwardStart(
            sandbox=sandbox_name, port=8080))
        while True:
            data = sock.recv(64*1024)
            if not data: break
            yield pb.TcpForwardFrame(data=data)

    stream = stub.ForwardTcp(gen())
    for frame in stream:
        sock.sendall(frame.data)
```

Now `curl http://localhost:9000/file.bin` (or any HTTP client) talks
to the in-sandbox HTTP server through the gateway tunnel. For S3-style
uploads, run `minio` or `garage` in the sandbox; for FTP-like access,
forward port 21.

This pattern bypasses gRPC frame size limits entirely. Trade-off: you
have to provision a server inside the sandbox, which means the agent
image must include one or you must `pip install`/`apk add` it via
`ExecSandbox` first.

## File download patterns

Symmetric to upload. Pick the same pattern by file size and tooling.

### Pattern 1 — `tar` out of `ExecSandbox` stdout

```python
def download(stub, sandbox_name, remote_path, dest_dir):
    req = pb.ExecSandboxRequest(
        name=sandbox_name,
        command=["tar", "-cf", "-", "-C",
                 os.path.dirname(remote_path) or "/",
                 os.path.basename(remote_path)],
    )
    buf = io.BytesIO()
    for ev in stub.ExecSandbox(req):
        if ev.HasField("stdout"):
            buf.write(ev.stdout)
        if ev.HasField("exit") and ev.exit.code != 0:
            raise RuntimeError("tar -c failed")
    buf.seek(0)
    with tarfile.open(fileobj=buf) as tar:
        tar.extractall(dest_dir)
```

### Pattern 2 — `scp` from the SSH session

```python
session = stub.CreateSshSession(pb.CreateSshSessionRequest(
    sandbox=sandbox.name, ttl_seconds=900)).session
# write key to tempfile, then:
subprocess.check_call([
    "scp", "-i", keyfile, "-P", str(session.port),
    "-o", "StrictHostKeyChecking=no",
    f"{session.username}@{session.host}:/workspace/results/",
    "./local-results/",
])
```

### Pattern 3 — HTTP GET via TCP forward

Same forwarding setup as upload pattern 3; the local side runs `curl
http://localhost:9000/result.tar.gz -o result.tar.gz` instead.

## Streaming Claude Code interactively

The end-to-end shape for a programmatic Claude Code session:

```python
def interactive_claude(stub, sandbox_name):
    # Bidi: we send keystrokes / commands; gateway sends stdout.
    in_q: queue.Queue = queue.Queue()
    in_q.put(pb.ExecSandboxInput(start=pb.ExecStart(
        name=sandbox_name,
        command=["claude"],
        tty=True,
        env={"ANTHROPIC_LOG_LEVEL": "info"},
    )))

    def out_iter():
        while True:
            yield in_q.get()

    stream = stub.ExecSandboxInteractive(out_iter())

    # Background thread: read keyboard, push to in_q.
    def stdin_pump():
        for line in sys.stdin:
            in_q.put(pb.ExecSandboxInput(stdin=pb.ExecStdin(
                data=line.encode())))
    threading.Thread(target=stdin_pump, daemon=True).start()

    # Main: print events as they arrive.
    for ev in stream:
        if ev.HasField("stdout"):
            sys.stdout.buffer.write(ev.stdout); sys.stdout.flush()
        if ev.HasField("stderr"):
            sys.stderr.buffer.write(ev.stderr); sys.stderr.flush()
        if ev.HasField("exit"):
            return ev.exit.code
```

For batch (non-interactive) Claude work — "ask one question, get one
answer" — use `ExecSandbox` instead and let stdin be empty. Claude
Code's `--print` flag bypasses the TTY entirely.

## Tear-down and resource cleanup

Always `DeleteSandbox` when done. The driver's compute-driver layer
will clean up the underlying CR (and the agent-sandbox controller will
GC the pod), but stale sandbox records consume gateway memory.

```python
stub.DeleteSandbox(pb.DeleteSandboxRequest(name=sandbox.name))
```

Idempotent — second delete returns `Deleted=false`, no error.

For long-running services, register an `atexit` handler or a finalizer
that walks `ListSandboxes(label_selector="owner=my-service")` and
deletes any leftover entries — defensive against process crashes.

## Complete worked example: Python

A self-contained script that creates a Claude Code sandbox, uploads a
prompt file, runs a one-shot prompt against it, downloads the result,
and tears down. Save as `examples/claude_oneshot.py`:

```python
#!/usr/bin/env python3
"""End-to-end Claude Code one-shot through the OpenShell gRPC API."""
import grpc, io, os, sys, tarfile
from openshell.v1 import openshell_pb2 as pb, openshell_pb2_grpc as svc

GATEWAY = os.environ.get("OPENSHELL_GATEWAY", "localhost:8080")
TOKEN   = os.environ.get("OPENSHELL_TOKEN")

def channel():
    if GATEWAY.startswith("localhost") or GATEWAY.startswith("127."):
        return grpc.insecure_channel(GATEWAY)
    creds = grpc.ssl_channel_credentials()
    if TOKEN:
        call_creds = grpc.access_token_call_credentials(TOKEN)
        creds = grpc.composite_channel_credentials(creds, call_creds)
    return grpc.secure_channel(GATEWAY, creds)

def chunks(b, n=256*1024):
    for i in range(0, len(b), n):
        yield b[i:i+n]

def main(prompt_path: str):
    with channel() as ch:
        stub = svc.OpenShellStub(ch)

        # Provider (idempotent — ignore AlreadyExists)
        try:
            stub.CreateProvider(pb.CreateProviderRequest(
                name="anthropic", type="anthropic",
                credentials={"ANTHROPIC_API_KEY": os.environ["ANTHROPIC_API_KEY"]},
            ))
        except grpc.RpcError as e:
            if e.code() != grpc.StatusCode.ALREADY_EXISTS: raise

        sb = stub.CreateSandbox(pb.CreateSandboxRequest(
            image="quay.io/azaalouk/demo-sandbox-claude:latest",
            command=["sleep", "infinity"],
            provider="anthropic",
            labels={"owner": "claude_oneshot.py"},
        )).sandbox
        print(f"sandbox: {sb.name}", file=sys.stderr)

        # Wait Ready
        for ev in stub.WatchSandbox(pb.WatchSandboxRequest(name=sb.name)):
            if ev.state == pb.SANDBOX_STATE_READY: break

        # Upload the prompt as /workspace/prompt.txt via tar
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tar:
            tar.add(prompt_path, arcname="prompt.txt")
        payload = buf.getvalue()

        def upload_gen():
            yield pb.ExecSandboxInput(start=pb.ExecStart(
                name=sb.name, command=["tar", "-xC", "/workspace"], tty=False))
            for c in chunks(payload):
                yield pb.ExecSandboxInput(stdin=pb.ExecStdin(data=c))
            yield pb.ExecSandboxInput(close_stdin=pb.ExecCloseStdin())
        for ev in stub.ExecSandboxInteractive(upload_gen()):
            if ev.HasField("exit") and ev.exit.code != 0:
                raise RuntimeError(f"upload failed: {ev.exit.code}")

        # Run claude --print < /workspace/prompt.txt > /workspace/answer.txt
        for ev in stub.ExecSandbox(pb.ExecSandboxRequest(
            name=sb.name,
            command=["sh", "-c",
                     "claude --print < /workspace/prompt.txt > /workspace/answer.txt"],
        )):
            if ev.HasField("stderr"): sys.stderr.buffer.write(ev.stderr)
            if ev.HasField("exit") and ev.exit.code != 0:
                raise RuntimeError(f"claude failed: {ev.exit.code}")

        # Download /workspace/answer.txt via tar
        out = io.BytesIO()
        for ev in stub.ExecSandbox(pb.ExecSandboxRequest(
            name=sb.name,
            command=["tar", "-cf", "-", "-C", "/workspace", "answer.txt"],
        )):
            if ev.HasField("stdout"): out.write(ev.stdout)
            if ev.HasField("exit") and ev.exit.code != 0:
                raise RuntimeError("download failed")
        out.seek(0)
        with tarfile.open(fileobj=out) as tar:
            tar.extract("answer.txt", path=".")

        # Cleanup
        stub.DeleteSandbox(pb.DeleteSandboxRequest(name=sb.name))
        print("answer written to ./answer.txt", file=sys.stderr)

if __name__ == "__main__":
    main(sys.argv[1])
```

Invoke with:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export OPENSHELL_GATEWAY=localhost:8080  # via kubectl port-forward
python examples/claude_oneshot.py prompt.txt
```

## Complete worked example: TypeScript

Equivalent flow using `@connectrpc/connect` for browser/Node:

```typescript
import { createPromiseClient } from "@connectrpc/connect";
import { createGrpcWebTransport } from "@connectrpc/connect-web";
import { OpenShell } from "./gen/openshell/v1/openshell_connect.js";
import { CreateSandboxRequest, ExecSandboxRequest, ExecSandboxInput, ExecStart, ExecStdin, ExecCloseStdin } from "./gen/openshell/v1/openshell_pb.js";

const transport = createGrpcWebTransport({
  baseUrl: process.env.OPENSHELL_GATEWAY ?? "http://localhost:8080",
  interceptors: [(next) => async (req) => {
    if (process.env.OPENSHELL_TOKEN)
      req.header.set("authorization", `Bearer ${process.env.OPENSHELL_TOKEN}`);
    return next(req);
  }],
});
const client = createPromiseClient(OpenShell, transport);

const { sandbox } = await client.createSandbox(new CreateSandboxRequest({
  image: "quay.io/azaalouk/demo-sandbox-claude:latest",
  command: ["sleep", "infinity"],
  provider: "anthropic",
}));

// Wait Ready
for await (const ev of client.watchSandbox({ name: sandbox!.name })) {
  if (ev.state === SandboxState.READY) break;
}

// Upload via tar pipe
const tarBytes = await tarPack(["./prompt.txt"]);
const upStream = client.execSandboxInteractive((async function* () {
  yield new ExecSandboxInput({ start: new ExecStart({
    name: sandbox!.name, command: ["tar", "-xC", "/workspace"], tty: false }) });
  for (const chunk of chunkify(tarBytes, 256 * 1024))
    yield new ExecSandboxInput({ stdin: new ExecStdin({ data: chunk }) });
  yield new ExecSandboxInput({ closeStdin: new ExecCloseStdin() });
})());
for await (const ev of upStream) {
  if (ev.exit && ev.exit.code !== 0) throw new Error(`tar failed: ${ev.exit.code}`);
}

// Run + download elided — same shape as Python.

await client.deleteSandbox({ name: sandbox!.name });
```

## Operational notes

- **Sandbox cold-start cost** is dominated by container image pull.
  Pre-pulling the agent image to every node (or staging a smaller
  derivative) cuts time-to-Ready from ~60 s to ~5 s.
- **Concurrency**: each sandbox has its own pod. The Helm chart's
  `Deployment` for the driver is single-replica. Many sandboxes per
  driver are fine; they all serialize through the gateway's gRPC
  server, but the actual sandbox lifecycle is parallelized inside
  Kyma.
- **Quotas**: respect the namespace ResourceQuota when sizing
  sandboxes. The driver's `--enable-network-policy` flag adds a
  default-deny egress that allows only DNS + the gateway service —
  enable it for any multi-tenant workload.
- **gRPC max message size**: the gateway sets a default 64 MB cap. For
  files larger than that, use SSH/SCP or TCP-forwarded HTTP — not the
  exec stdin pipe.
- **Idempotency**: `CreateProvider` and `CreateSandbox` are not
  retried automatically. Catch `ALREADY_EXISTS` and treat it as
  success. `DeleteSandbox` is idempotent on the wire (returns
  `deleted: false` if already gone).
- **Streaming back-pressure**: when piping large stdin, watch for
  flow-control. Tonic and grpc-python both honor HTTP/2 windows;
  Connect-Web caps at 16 MB per stream by default — chunk smaller.

## References

- Upstream proto: [`NVIDIA/OpenShell/proto/openshell.proto`](https://raw.githubusercontent.com/NVIDIA/OpenShell/main/proto/openshell.proto)
- Upstream README: <https://github.com/NVIDIA/OpenShell>
- Connect protocol (grpc-web alternative): <https://connectrpc.com>
- gRPC max-message-size and back-pressure tuning: <https://grpc.io/docs/guides/performance/>
- This repo's design spec for the compute-driver contract:
  [`docs/superpowers/specs/2026-05-26-openshell-driver-kyma-design.md`](superpowers/specs/2026-05-26-openshell-driver-kyma-design.md)
- This repo's Cloud Connector setup:
  [`docs/cloud-connector-setup.md`](cloud-connector-setup.md)
