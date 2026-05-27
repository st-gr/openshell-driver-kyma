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
