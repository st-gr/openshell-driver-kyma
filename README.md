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

If you have a Kyma cluster, `kubectl`, and an Anthropic-shaped LLM
endpoint + API key, follow
[`docs/tutorial-anthropic-direct.md`](docs/tutorial-anthropic-direct.md) —
a linear ~15 minute end-to-end from an empty cluster to Claude running
inside an isolated sandbox, using the upstream NVIDIA gateway image.

For the more comprehensive walkthrough (including uploading files,
running inference, downloading results, plus SAP AI Core and
private-in-cluster-upstream variants) start at
[`docs/getting-started.md`](docs/getting-started.md). It mirrors what
`make e2e-cli` does in CI, so it's guaranteed to track the
implementation.

For production deploys (OIDC user auth, public Kyma APIRule, image
digests pinned), see [`docs/production-deployment.md`](docs/production-deployment.md).

For private VPN routing through SAP Cloud Connector, see
[`docs/cloud-connector-setup.md`](docs/cloud-connector-setup.md).

For installing the `openshell` CLI itself, see
[`docs/install-cli.md`](docs/install-cli.md).

For programmatic gRPC access without the CLI, see
[`docs/openshell-api-programmatic-usage.md`](docs/openshell-api-programmatic-usage.md).

## Configuration reference

All flags also work as `values.yaml` keys in the Helm chart.

| Flag | Default | Purpose |
|------|---------|---------|
| `--socket` | `/var/run/openshell-driver.sock` | UDS path for the gRPC server |
| `--namespace` | `openshell-system` | Namespace where Sandbox CRs are created |
| `--supervisor-image` | `ghcr.io/nvidia/openshell/supervisor:latest` | Init-container image carrying the supervisor binary (distroless; binary self-copies via `copy-self`) |
| `--supervisor-binary-path` | `/openshell-sandbox` | Path to the supervisor inside the image (matches the distroless image's layout) |
| `--supervisor-mount-path` | `/opt/openshell/bin` | Mount point in the agent container |
| `--gateway-endpoint` | `""` | Optional `OPENSHELL_ENDPOINT` env var injected into sandboxes |
| `--istio-inject-sandboxes` | `false` | When false, stamps `sidecar.istio.io/inject: "false"` on sandbox pods |
| `--enable-apirule` | `false` | Create one `gateway.kyma-project.io/v2/APIRule` per sandbox |
| `--cluster-domain` | `""` (auto-discover) | Kyma cluster domain suffix; only used with `--enable-apirule` |
| `--gpu-support` | `true` | Validate `nvidia.com/gpu` capacity at create time (cluster-scope node read) |
| `--enable-network-policy` | `true` | Render the driver+gateway and sandbox `NetworkPolicy` (default-on as of 2026-05-28) |
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

## Related

- [`st-gr/gha-runner-kyma`](https://github.com/st-gr/gha-runner-kyma) —
  a self-hosted GitHub Actions runner that lives in the same Kyma
  cluster, useful when CI workflows need to call the in-cluster
  gateway (originally bundled here under `deploy/runner/`; extracted
  on 2026-05-28).

## Reference and credits

- The reference Go implementation for OpenShift is
  [zanetworker/openshell-driver-openshift](https://github.com/zanetworker/openshell-driver-openshift)
  (Apache-2.0). Architectural parallels are documented inline in the source.
- The proto contract `proto/compute_driver.proto` is vendored from
  [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) (Apache-2.0); the
  SPDX header is preserved.

## License

Apache-2.0. See [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES).
