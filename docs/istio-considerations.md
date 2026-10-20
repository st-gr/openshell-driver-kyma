# Istio considerations

Kyma's Istio module is enabled by default. Sandbox workload pods never get an
Istio sidecar: the driver puts the label `sidecar.istio.io/inject: "false"` on
the sandbox template, and upstream's driver copies it onto each sandbox's
workload pod. Istio honours the label even in a namespace labelled
`istio-injection=enabled`.

## Why sandbox workloads never get a sidecar

1. **Upstream refuses it.** Upstream OpenShell (v0.1.3 and later) checks every admitted
   workload pod for capability-free isolation and refuses one that receives a
   projected ServiceAccount token. An Istio sidecar brings one, so the sandbox
   is never created: `openshell sandbox create` fails with "admitted workload
   Pod does not preserve capability-free isolation: workload Pod must not
   receive a projected ServiceAccount token" (seen live on Kyma, 2026-10-12).

2. **The isolation fence.** Upstream's workload pods have no egress and
   accept ingress only from their supervisor pod. A sidecar would sit
   outside that boundary.

3. **mTLS is redundant for OpenShell egress.** OpenShell's policy engine
   intercepts outbound traffic at the supervisor level. Istio mTLS on top
   adds no meaningful guarantee for the agent workload.

Releases up to 0.10.1 had an option to let Istio inject sidecars into
sandbox workloads (`driver.istioInjectSandboxes`,
`--kyma-istio-inject-sandboxes`). With upstream v0.1.3 it made every sandbox
creation fail, so 0.10.2 removed it; a values file that still sets it to
`true` fails the render with an explanation.

The driver does **not** change the namespace's `istio-injection` label. That
stays a cluster-admin concern. The label goes on the workload pod only: the
supervisor pod is built by upstream's driver from its own labels and does not
carry it, so do not label the sandbox namespace `istio-injection=enabled`
unless you want sidecars on supervisor pods.

## Driver pod itself

The driver pod always carries `sidecar.istio.io/inject: "false"`. Its only
inbound surface is the local Unix domain socket the gateway sidecar talks to
within the same pod, plus the HTTP probes on `/healthz` and `/readyz`. None
benefit from a sidecar.
