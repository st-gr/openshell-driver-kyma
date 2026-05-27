# Istio considerations

Kyma's Istio module is enabled by default. Sandbox pods either get a
sidecar injected (when the namespace carries
`istio-injection=enabled`) or don't. The `--istio-inject-sandboxes`
flag controls how the driver handles this.

## Why the default is `false`

When `--istio-inject-sandboxes=false` (the default) the driver stamps
the label `sidecar.istio.io/inject: "false"` on every Sandbox CR's pod
template. Istio sees the label and does not inject. Three reasons:

1. **Capability conflicts.** The agent container needs
   `SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE`, and `SYSLOG`. Istio's
   `istio-init` init container manipulates iptables and runs before
   the agent, also requiring `NET_ADMIN`. Stacking them works in
   theory but adds a moving piece to debug when sandbox traffic
   misroutes — and the sandbox supervisor sets up its own network
   namespace anyway.

2. **mTLS is redundant for OpenShell egress.** OpenShell's policy
   engine intercepts outbound traffic at the supervisor level. Layering
   Istio mTLS on top doesn't add a meaningful guarantee for the agent
   workload — it's terminated and re-originated inside the supervisor
   regardless.

3. **Latency budget.** Each sidecar adds two L7 hops on the egress
   path. For agents that talk to inference backends, that compounds
   noticeably across long sessions.

## When to flip it on

`--istio-inject-sandboxes=true` is appropriate when you want
namespace-uniform behavior — for example, if your sandbox namespace
also runs a Kyma-managed Service Mesh AuthorizationPolicy that you
want every pod (including sandboxes) to obey. In that case:

1. Set `--istio-inject-sandboxes=true` on the driver.
2. Make sure the namespace's `PeerAuthentication` is `PERMISSIVE` or
   the sandbox supervisor's outbound traffic carries valid mTLS
   credentials.
3. Allow the additional latency budget.

The driver does **not** mutate the namespace's `istio-injection`
label. That stays a cluster-admin concern. The
`sidecar.istio.io/inject: "false"` label only affects the individual
pod template and is the canonical way Istio supports per-pod
opt-out.

## Driver pod itself

The driver pod always carries `sidecar.istio.io/inject: "false"`
regardless of the flag. Its only inbound surface is the local Unix
domain socket the gateway sidecar talks to within the same pod, plus
the HTTP probes on `/healthz`, `/readyz`, `/metrics`. None benefit
from a sidecar.
