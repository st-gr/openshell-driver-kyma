# Kyma vs OpenShift — what differs in this driver

The OpenShift driver
([zanetworker/openshell-driver-openshift](https://github.com/zanetworker/openshell-driver-openshift))
was the structural reference for this project. This document captures the
concrete differences between it and the Kyma driver.

The Kyma driver runs upstream OpenShell's Kubernetes driver
(`openshell-driver-kubernetes`, release v0.1.2) unchanged, so provisioning,
sandbox authentication and isolation are upstream's, and it adds two things
of its own: request enrichment (the Istio opt-out and Kagenti labels, plus
configured sandbox environment) and Pod Security labels on the namespaces the
driver creates in managed mode. Everything below
that reads "Kyma" describes those additions and the chart around them.

## Pod admission policy

| | OpenShift | Kyma |
|---|---|---|
| Mechanism | Security Context Constraints (SCC) | Pod Security Admission (PSA) |
| Default profile | `restricted-v2` | `restricted` (set per namespace via the `pod-security.kubernetes.io/enforce` label) |
| Driver pod | Fits `restricted-v2` cleanly | Fits `restricted` cleanly |
| Sandbox pod | Needs a custom SCC granting `SYS_ADMIN`/`NET_ADMIN`/etc. | Sandbox namespace labeled `pod-security.kubernetes.io/enforce: privileged`, the level the chart's CI runs at. Upstream's pods themselves run unprivileged (non-root, all capabilities dropped), so a stricter level may admit them; that is not verified here |

The Kyma driver does not check the namespace label at startup. A pod that
Pod Security Admission rejects shows up as a `violates PodSecurity` event on
the namespace. In managed mode (`driver.workspaceMode=managed`) the driver
creates the workspace namespaces itself and, when
`driver.workspacePsaLevel` is set, labels each one with that level before its
first sandbox is created.

## Service mesh

| | OpenShift | Kyma |
|---|---|---|
| Default mesh | Optional (Service Mesh Operator) | Istio module enabled by default |
| Sidecar injection on labeled namespaces | Off unless explicitly opted in | On unless explicitly opted out |
| Driver pod | Annotation: not needed | Annotation: `sidecar.istio.io/inject: "false"` (UDS doesn't benefit from mTLS) |
| Sandbox pod | Mesh not assumed | Controlled by `--kyma-istio-inject-sandboxes` (`driver.istioInjectSandboxes`, default `false`) |

See [`istio-considerations.md`](istio-considerations.md) for the
reasoning behind defaulting injection off for sandboxes.

## External access

| | OpenShift | Kyma |
|---|---|---|
| Native CR | `Route` (`route.openshift.io/v1`) | `APIRule` (`gateway.kyma-project.io/v2`) |
| Gateway | Phase 2 in upstream OpenShift driver (not yet) | `gatewayIngress` publishes the gateway, which authenticates with OIDC (VirtualService, TLS from the ingress gateway to the gateway pod, source-address policies) |
| Sandbox pods | — | Never, by upstream design (below) |
| Cluster domain | Often `*.<cluster-name>.<base>` | `*.<cluster-id>.kyma.ondemand.com`, set as `gatewayIngress.domain` |

Nothing routes to a sandbox pod: upstream's sandbox runtime brokers the
workload's `bind`/`listen`/`accept` syscalls and resets every inbound
connection that does not arrive through the gateway's relay, so an `APIRule`
or `VirtualService` to the pod answers `503`. A service inside a sandbox is
reached with `openshell service expose` through the gateway; see
[`production-deployment.md`](production-deployment.md). The driver needs no
`apirules.gateway.kyma-project.io` RBAC and runs cleanly in clusters that
don't have the Kyma API Gateway module installed.

## Compute / GPU

| | OpenShift | Kyma |
|---|---|---|
| Provisioning layer | OpenShift on RHCOS | Gardener (AWS, Azure, GCP, OpenStack) |
| GPU operator | NVIDIA GPU Operator | NVIDIA GPU Operator on Gardener-AWS |
| Resource name | `nvidia.com/gpu` | `nvidia.com/gpu` (identical) |
| Validation | Cluster-scope node read | Cluster-scope node read, by upstream's driver; no opt-out |

Both drivers list nodes for `nvidia.com/gpu` allocatable to validate GPU
sandbox requests. Upstream's driver does this unconditionally, so the Kyma
driver's ClusterRole always grants read access to nodes; the
GPU opt-out of earlier versions is gone.

## Authentication

| | OpenShift | Kyma |
|---|---|---|
| In-cluster | ServiceAccount token (`/var/run/secrets/...`) | ServiceAccount token (identical) |
| Out-of-cluster | OpenShift OAuth tokens or kubeconfig users | OIDC kubeconfig with `exec` plugin (`kubectl oidc-login`) provided by SAP BTP |

Upstream's driver uses `kube::Config::incluster()` first, falling back to
`kube::Config::infer()`. The Kyma layer's own client uses
`kube::Client::try_default()`, which tries a kubeconfig first (`KUBECONFIG` or
`~/.kube/config`) and then the in-cluster configuration; inside a pod, where
there is no kubeconfig, the effect is the same. `kube-rs` honors `exec`
credential plugins, so the SAP BTP OIDC kubeconfig
works out of the box for local development; the driver never sees the OIDC
tokens directly.

## Build and packaging

| | OpenShift | Kyma |
|---|---|---|
| Language | Go | Rust 1.95.0 |
| Codegen | `protoc` + `protoc-gen-go-grpc` | none: the protocol types come from upstream's `openshell-core` crate |
| K8s client | `k8s.io/client-go` | `kube-rs` 0.99, the version upstream's driver uses |
| Container | distroless static (Go is fully static) | distroless cc (Rust uses glibc; rustls feature avoids OpenSSL) |
| CI | Go test + golangci-lint | cargo fmt + clippy::pedantic + cargo test |

## Feature parity

The OpenShift driver's "Phase 1" features (supervisor delivery, Kagenti
enrollment labels, GPU validation, `platform_config` passthrough) are all
upstream's Kubernetes driver's own behaviour here, apart from the Kagenti
label, which the Kyma layer adds. The OpenShift driver's "Phase 2" roadmap
(SCC detection, SELinux, Routes, OAuth proxy, Prometheus, Helm chart) is
mapped to: Istio injection toggle (done), gateway `APIRule` rendering (done), Helm
chart (done); the driver's Prometheus metrics endpoint is gone (upstream
traces over OTLP: `driver.otlpEndpoint`), and SCC detection has no Kyma
equivalent. OAuth proxy sidecar injection is not in scope for the Kyma
driver — Kyma exposes JWT auth directly via the `APIRule` `jwt` handler.

## Sandbox-to-gateway authentication

OpenShift driver: relies on a shared sandbox secret + `Route` for the
gateway. The supervisor reads the secret from a mounted ConfigMap.

Kyma driver: provisioning and authentication are upstream's, unchanged. The
driver runs upstream's Kubernetes driver and adds request enrichment and
managed-namespace PSA labels; see the top of this page. No shared
cluster-wide secret exists: a projected, kubelet-rotated ServiceAccount token
is exchanged for a per-sandbox JWT, which suits Kyma clusters that issue OIDC
kubeconfigs through SAP IAS.

## Network policy posture

OpenShift driver: relies on the cluster's default `NetworkPolicy` or
the operator's overlay. No NetworkPolicy in the chart.

Kyma driver: **upstream fences sandboxes, and the chart adds nothing to that
fence.** Upstream's driver creates two NetworkPolicies per sandbox namespace,
`openshell-sandbox-workloads` (workload pods: no egress, ingress only from
their supervisor pod) and `openshell-sandbox-supervisors` (supervisor pods).
NetworkPolicies are additive, so the chart renders none that select sandbox
pods, with one exception that grants nothing beyond upstream's: in shared
mode with the in-pod gateway, `<fullname>-sandbox-ssh`, which limits SSH
ingress (TCP 2222) on sandbox pods to the gateway pod. What the chart does
render is the driver+gateway pod's own policy (ingress on the health, gRPC and
metrics ports; egress to DNS and 443). Set `networkPolicy.enabled=false` to
render neither. The cluster's CNI must enforce NetworkPolicy in every sandbox
namespace.

## Public ingress guard

The chart refuses to render with `gatewayIngress.enabled=true` unless
`gateway.oidc.issuer`, `audience` and `clientId` are set. Without this guard,
an operator could combine a public host with
`allow_unauthenticated_users=true` (set automatically when no issuer) and
`--disable-tls`, producing a world-writable sandbox factory.

## Provider-profile inference routing

OpenShift driver: relies on direct sandbox-side env (`ANTHROPIC_BASE_URL`,
`ANTHROPIC_API_KEY`) for routing. Operators who want to route through
an in-cluster proxy patch each sandbox's CR.

Kyma driver: follows upstream OpenShell's provider-profile model (see NVIDIA's
[Inference](https://docs.nvidia.com/openshell/how-it-works/inference) and
[Provider profiles](https://docs.nvidia.com/openshell/how-it-works/providers/profiles)
pages). Upstream v0.1.2 has no `inference.local` endpoint, no router bundle
and no command that sets a cluster-wide inference route:

- The chart renders a provider profile (the host and port of
  `inferenceProvider.baseUrl`, and the `binaries` allowed to reach it); a
  post-install Job imports it and creates the provider from it with the API
  key from an operator-managed Secret. The chart never sees the key.
- Sandboxes are created with `openshell sandbox create --provider <name>`.
  The driver gives every sandbox `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL`
  (`--kyma-sandbox-env`); a sandbox with the provider attached also has a
  placeholder for the key.
- The workload pod has no network of its own. Its traffic goes through its
  supervisor pod, which substitutes the real key in requests to the profile's
  host and port and dials the upstream.
- The key is bound to that host and port. `binaries` gates which processes may
  reach the endpoint; upstream v0.1.2 does not yet restrict the key by calling
  binary.

Chart blocks behind this:

| Block | What it adds |
|---|---|
| `gateway.dbPersistence` | PVC-backed SQLite (or external Postgres `dbUrl`) for the gateway's DB, so the provider and its profile survive pod restarts. |
| `inferenceProvider` | The provider profile, and a post-install, post-upgrade Helm Hook Job that imports it and creates (or updates) the provider against the in-pod gateway, using the `openshell` CLI of `upstream.version`. The API key is mounted from a Secret the operator manages. |

There is no `gatewayUpstreamEgress` block any more: upstream gives each
supervisor pod its own egress policy (allow-all), so an in-cluster upstream
needs no NetworkPolicy from the chart.

See [`getting-started.md`](getting-started.md) Appendix A for the
end-to-end install command, and [`production-deployment.md`](production-deployment.md)
for the values overlay equivalent.
