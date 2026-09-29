# Istio considerations

Kyma's Istio module is enabled by default. Sandbox pods either get a
sidecar injected (when the namespace carries
`istio-injection=enabled`) or don't. The `--kyma-istio-inject-sandboxes`
option (`driver.istioInjectSandboxes`) controls how the driver handles this
for the sandbox's workload pod.

## Why the default is `false`

When `--kyma-istio-inject-sandboxes=false` (the default) the driver adds
the label `sidecar.istio.io/inject: "false"` to the sandbox template's
labels, which upstream's driver copies onto the sandbox's workload pod. Istio
sees the label and does not inject. Three reasons:

1. **The isolation fence.** Upstream's workload pods have no egress and
   accept ingress only from their supervisor pod. A sidecar would sit
   outside that boundary, and `istio-init`'s iptables changes and extra
   listeners are one more moving piece to debug when sandbox traffic
   misroutes.

2. **mTLS is redundant for OpenShell egress.** OpenShell's policy
   engine intercepts outbound traffic at the supervisor level. Layering
   Istio mTLS on top doesn't add a meaningful guarantee for the agent
   workload — it's terminated and re-originated inside the supervisor
   regardless.

3. **Latency budget.** Each sidecar adds two L7 hops on the egress
   path. For agents that talk to inference backends, that compounds
   noticeably across long sessions.

## When to flip it on

`--kyma-istio-inject-sandboxes=true` is appropriate when you want
namespace-uniform behavior — for example, if your sandbox namespace
also runs a Kyma-managed Service Mesh AuthorizationPolicy that you
want every pod (including sandboxes) to obey. In that case:

1. Set `driver.istioInjectSandboxes=true` (`--kyma-istio-inject-sandboxes`) on the driver.
2. Make sure the namespace's `PeerAuthentication` is `PERMISSIVE` or
   the sandbox supervisor's outbound traffic carries valid mTLS
   credentials.
3. Allow the additional latency budget.

The driver does **not** mutate the namespace's `istio-injection`
label. That stays a cluster-admin concern. The
`sidecar.istio.io/inject: "false"` label only affects the individual
pod and is the canonical way Istio supports per-pod opt-out. The label goes
on the workload pod only: the supervisor pod is built by upstream's driver
from its own labels and does not carry it, so do not label the sandbox
namespace `istio-injection=enabled` unless you want sidecars on supervisor
pods.

## Driver pod itself

The driver pod always carries `sidecar.istio.io/inject: "false"`
regardless of the flag. Its only inbound surface is the local Unix
domain socket the gateway sidecar talks to within the same pod, plus
the HTTP probes on `/healthz` and `/readyz`. None benefit from a sidecar.
