# Kyma vs OpenShift — what differs in this driver

The OpenShift driver
([zanetworker/openshell-driver-openshift](https://github.com/zanetworker/openshell-driver-openshift))
is our structural reference. The Kyma port mirrors its trait layout
(`SandboxProvisioner` / `PlatformEnricher` / `DriverMetrics`) and the
exact 8-RPC gRPC contract, but adapts the platform-specific bits. This
document captures every concrete delta.

## Pod admission policy

| | OpenShift | Kyma |
|---|---|---|
| Mechanism | Security Context Constraints (SCC) | Pod Security Admission (PSA) |
| Default profile | `restricted-v2` | `restricted` (set per namespace via the `pod-security.kubernetes.io/enforce` label) |
| Driver pod | Fits `restricted-v2` cleanly | Fits `restricted` cleanly |
| Sandbox pod | Needs a custom SCC granting `SYS_ADMIN`/`NET_ADMIN`/etc. | Sandbox namespace must be labeled `pod-security.kubernetes.io/enforce: privileged` |

The Kyma driver detects the sandbox namespace's PSA label at startup and
fails fast with an actionable message if it's missing or set to
`baseline`/`restricted`. The OpenShift driver doesn't have an equivalent
because the SCC check fires only at pod admission time.

## Service mesh

| | OpenShift | Kyma |
|---|---|---|
| Default mesh | Optional (Service Mesh Operator) | Istio module enabled by default |
| Sidecar injection on labeled namespaces | Off unless explicitly opted in | On unless explicitly opted out |
| Driver pod | Annotation: not needed | Annotation: `sidecar.istio.io/inject: "false"` (UDS doesn't benefit from mTLS) |
| Sandbox pod | Mesh not assumed | Controlled by `--istio-inject-sandboxes` flag (default `false`) |

See [`istio-considerations.md`](istio-considerations.md) for the
reasoning behind defaulting injection off for sandboxes.

## External access

| | OpenShift | Kyma |
|---|---|---|
| Native CR | `Route` (`route.openshift.io/v1`) | `APIRule` (`gateway.kyma-project.io/v2`) |
| Driver support | Phase 2 in upstream OpenShift driver (not yet) | Optional in this driver behind `--enable-apirule` |
| Cluster domain | Often `*.<cluster-name>.<base>` | `*.<cluster-id>.kyma.ondemand.com`, discovered from the Kyma `Gateway` CR or set via `--cluster-domain` |

When `--enable-apirule` is off, no `apirules.gateway.kyma-project.io`
RBAC is granted to the driver's ServiceAccount. The driver runs cleanly
in clusters that don't have the Kyma API Gateway module installed.

## Compute / GPU

| | OpenShift | Kyma |
|---|---|---|
| Provisioning layer | OpenShift on RHCOS | Gardener (AWS, Azure, GCP, OpenStack) |
| GPU operator | NVIDIA GPU Operator | NVIDIA GPU Operator on Gardener-AWS |
| Resource name | `nvidia.com/gpu` | `nvidia.com/gpu` (identical) |
| Validation | Cluster-scope node read | Cluster-scope node read; opt-out via `--gpu-support=false` |

Both drivers list nodes for `nvidia.com/gpu` allocatable to validate GPU
sandbox requests. The Kyma driver makes this opt-out so it can run with
namespace-scope-only RBAC for non-cluster-admin operators (the trade-off
is that GPU sandbox requests are then rejected with a clear error rather
than silently failing at scheduling time).

## Authentication

| | OpenShift | Kyma |
|---|---|---|
| In-cluster | ServiceAccount token (`/var/run/secrets/...`) | ServiceAccount token (identical) |
| Out-of-cluster | OpenShift OAuth tokens or kubeconfig users | OIDC kubeconfig with `exec` plugin (`kubectl oidc-login`) provided by SAP BTP |

The driver uses `kube::Config::incluster()` first, falling back to
`kube::Config::infer()`. `kube-rs` honors `exec` credential plugins,
so the SAP BTP OIDC kubeconfig works out of the box for local
development; the driver never sees the OIDC tokens directly.

## Build and packaging

| | OpenShift | Kyma |
|---|---|---|
| Language | Go | Rust 1.95.0 |
| Codegen | `protoc` + `protoc-gen-go-grpc` | `tonic-prost-build` |
| K8s client | `k8s.io/client-go` | `kube-rs` 3.x |
| Container | distroless static (Go is fully static) | distroless cc (Rust uses glibc; rustls feature avoids OpenSSL) |
| CI | Go test + golangci-lint | cargo fmt + clippy::pedantic + cargo test |

## Phase parity

The OpenShift driver's "Phase 1" features (init-container supervisor,
Kagenti enrollment labels, GPU validation, `platform_config`
passthrough) are all implemented here. The OpenShift driver's "Phase 2"
roadmap (SCC detection, SELinux, Routes, OAuth proxy, Prometheus, Helm
chart) is mapped to: Kyma's PSA detection (done), Istio injection toggle
(done), `APIRule` rendering (done), Prometheus metrics (done), Helm
chart (done). OAuth proxy sidecar injection is not in scope for the Kyma
driver — Kyma exposes JWT auth directly via the `APIRule` `jwt` handler.

## Sandbox-to-gateway authentication

OpenShift driver: relies on a shared sandbox secret + `Route` for the
gateway. The supervisor reads the secret from a mounted ConfigMap.

Kyma driver: projected ServiceAccount token (audience-bound to
`openshell-gateway`, kubelet-rotated) exchanged for a per-sandbox JWT
via the gateway's `IssueSandboxToken` RPC. The gateway validates the
projected token via the apiserver's `TokenReview` API, reads the
sandbox-pod's `openshell.io/sandbox-id` annotation, mints a fresh
sandbox JWT signed with a key the gateway holds. Mints a fresh JWT
on supervisor startup and on refresh-near-expiry.

Why the difference: Kyma clusters typically issue OIDC kubeconfigs
through SAP IAS, the supervisor pod has no shared cluster-wide secret
to share, and a projected token is rotated automatically by kubelet.
The Kyma chart's pre-install hook runs `openshell-gateway generate-certs`
to write the JWT signing-key Secret on first install.

## Network policy posture

OpenShift driver: relies on the cluster's default `NetworkPolicy` or
the operator's overlay. No NetworkPolicy in the chart.

Kyma driver: NetworkPolicy is **default-on** as of 2026-05-28. The
chart renders two policies:

- driver+gateway pod: ingress on health/grpc/metrics ports, egress to
  DNS and 443.
- sandbox pods (label-selected): no ingress, egress to DNS, the in-pod
  gateway VIP, and 0.0.0.0/0:443 with RFC1918 excluded — so a
  compromised sandbox cannot pivot to internal services but the
  agentic-workflow case (curl GitHub, npm, anthropic.com, pypi)
  still works.

Operators who need internal-cluster sandbox egress add an overlay
policy; the chart's defaults stay tight.

## Public APIRule guard

The chart refuses to render `gatewayApirule.yaml` if
`gatewayApirule.enabled=true` and `gateway.oidc.issuer=""`. Without
this guard, an operator could combine a public host with
`allow_unauthenticated_users=true` (set automatically when no
issuer) and `--disable-tls`, producing a world-writable sandbox
factory.
