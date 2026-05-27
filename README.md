# openshell-driver-kyma

[![branch-checks](https://github.com/st-gr/openshell-driver-kyma/actions/workflows/branch-checks.yml/badge.svg)](https://github.com/st-gr/openshell-driver-kyma/actions/workflows/branch-checks.yml)
[![helm-lint](https://github.com/st-gr/openshell-driver-kyma/actions/workflows/helm-lint.yml/badge.svg)](https://github.com/st-gr/openshell-driver-kyma/actions/workflows/helm-lint.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A Rust implementation of the [OpenShell](https://github.com/NVIDIA/OpenShell)
`ComputeDriver` gRPC contract, targeting **SAP BTP Kyma** clusters.
Wire-compatible with the upstream OpenShell gateway; provisions agent
sandboxes as `agents.x-k8s.io/v1alpha1/Sandbox` CRDs with Kyma-specific
adaptations (Pod Security Admission instead of OpenShift SCC, configurable
Istio sidecar injection, optional Kyma `APIRule` for external access).

```text
openshell-gateway ── Unix domain socket ── openshell-driver-kyma (Rust, Tonic gRPC)
                                                  │
                                                  ├── KymaProvisioner   (Sandbox CR lifecycle)
                                                  ├── KymaEnricher      (Istio toggle, PSA, APIRule)
                                                  └── PrometheusMetrics (axum /healthz /readyz /metrics)
```

**Status:** Phase 1 — see
[docs/superpowers/specs/2026-05-26-openshell-driver-kyma-design.md](docs/superpowers/specs/2026-05-26-openshell-driver-kyma-design.md)
for the full design and
[docs/superpowers/plans/2026-05-27-openshell-driver-kyma.md](docs/superpowers/plans/2026-05-27-openshell-driver-kyma.md)
for the implementation plan.

## Quick start

### Prerequisites on the cluster

- Kyma cluster with the **Istio** module enabled (default in Kyma).
- The
  [`kubernetes-sigs/agent-sandbox`](https://github.com/kubernetes-sigs/agent-sandbox)
  CRD installed:

  ```bash
  kubectl apply -f \
    https://raw.githubusercontent.com/kubernetes-sigs/agent-sandbox/main/k8s/crds/agents.x-k8s.io_sandboxes.yaml
  ```

- A namespace for sandbox CRs, labeled
  `pod-security.kubernetes.io/enforce: privileged` (cluster-admin operation
  — required because the supervisor inside each sandbox needs `SYS_ADMIN`,
  `NET_ADMIN`, `SYS_PTRACE`, and `SYSLOG` capabilities to install
  Landlock/seccomp). The driver fails fast if this label is missing.

  ```bash
  kubectl create namespace openshell-system
  kubectl label namespace openshell-system \
    pod-security.kubernetes.io/enforce=privileged --overwrite
  ```

### Install via Helm

```bash
helm install openshell-driver-kyma deploy/helm/openshell-driver-kyma \
  --namespace openshell-system --create-namespace \
  --set image.repository=ghcr.io/st-gr/openshell-driver-kyma \
  --set image.tag=latest
```

### Verify the driver is running

```bash
kubectl -n openshell-system get pods
kubectl -n openshell-system logs deploy/openshell-driver-kyma
# Expected: "driver ready" line in JSON tracing output
```

### Connect the OpenShell gateway

The driver listens on a Unix domain socket inside the pod. Run the
gateway as a sidecar in the same pod (sharing an `emptyDir` for the
socket) and start it with `--compute-driver-socket=/shared/driver.sock`.
A reference deployment lives at
[`deploy/gateway-with-driver.yaml`](deploy/gateway-with-driver.yaml) (TBD
— upstream gateway dependency tracked in the design spec section 6).

## Configuration reference

All flags also work as `values.yaml` keys in the Helm chart.

| Flag | Default | Purpose |
|------|---------|---------|
| `--socket` | `/var/run/openshell-driver.sock` | UDS path for the gRPC server |
| `--namespace` | `openshell-system` | Namespace where Sandbox CRs are created |
| `--supervisor-image` | `ghcr.io/nvidia/openshell-community/supervisor:latest` | Init-container image carrying the supervisor binary |
| `--supervisor-binary-path` | `/usr/local/bin/openshell-sandbox` | Path to the supervisor inside the image |
| `--supervisor-mount-path` | `/opt/openshell/bin` | Mount point in the agent container |
| `--gateway-endpoint` | `""` | Optional `OPENSHELL_ENDPOINT` env var injected into sandboxes |
| `--istio-inject-sandboxes` | `false` | When false, stamps `sidecar.istio.io/inject: "false"` on sandbox pods |
| `--enable-apirule` | `false` | Create one `gateway.kyma-project.io/v2/APIRule` per sandbox |
| `--cluster-domain` | `""` (auto-discover) | Kyma cluster domain suffix; only used with `--enable-apirule` |
| `--gpu-support` | `true` | Validate `nvidia.com/gpu` capacity at create time (cluster-scope node read) |
| `--enable-network-policy` | `false` | Render the optional sandbox `NetworkPolicy` (Helm only) |
| `--health-port` | `9090` | TCP port for `/healthz`, `/readyz`, `/metrics` |
| `--log-level` | `info` | Tracing level (`RUST_LOG` overrides) |

## Development

All Rust work happens inside a containerized toolchain image; nothing is
installed on the host. Get started in two commands:

```bash
make dev-image    # build openshell-driver-kyma-dev:latest (one-off, ~6 min)
make test         # cargo fmt --check + clippy + tests (~30 s warm cache)
```

Other useful targets:

```bash
make dev-shell                                          # interactive bash
make image                                              # production image
make helm-lint                                          # helm lint
make test-integration INTEGRATION_TEST_NAMESPACE=openshell-driver-test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, including DCO
sign-off requirements (`git commit -s` on every commit).

## Reference and credits

- The reference Go implementation for OpenShift is
  [zanetworker/openshell-driver-openshift](https://github.com/zanetworker/openshell-driver-openshift)
  (Apache-2.0). Architectural parallels are documented inline in the source.
- The proto contract `proto/compute_driver.proto` is vendored from
  [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) (Apache-2.0); the
  SPDX header is preserved.

## License

Apache-2.0. See [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES).
