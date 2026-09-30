# openshell-driver-kyma

[![branch-checks](https://github.com/st-gr/openshell-driver-kyma/actions/workflows/branch-checks.yml/badge.svg)](https://github.com/st-gr/openshell-driver-kyma/actions/workflows/branch-checks.yml)
[![helm-lint](https://github.com/st-gr/openshell-driver-kyma/actions/workflows/helm-lint.yml/badge.svg)](https://github.com/st-gr/openshell-driver-kyma/actions/workflows/helm-lint.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A compute driver that runs [OpenShell](https://github.com/NVIDIA/OpenShell)
agent sandboxes on **SAP BTP Kyma** clusters. The driver runs upstream
OpenShell's Kubernetes driver (`openshell-driver-kubernetes`, release v0.1.2)
unchanged, so every `ComputeDriver` RPC, the sandbox lifecycle and the
isolation are upstream's. It adds only request enrichment (the Istio opt-out
and Kagenti labels, plus configured sandbox environment), optional Kyma
`APIRule` exposure and Pod Security labels on managed-mode workspace
namespaces. Wire-compatible with the upstream OpenShell gateway.

```text
openshell-gateway ── Unix domain socket ── openshell-driver-kyma (Rust, Tonic gRPC)
                                                  │
                                                  ├── upstream openshell-driver-kubernetes
                                                  │     (every RPC: Sandbox CRs, supervisor pods,
                                                  │      isolation, admission, workspace modes)
                                                  └── Kyma layer
                                                        (request labels and env, APIRule exposure,
                                                         namespace PSA labels, /healthz /readyz)
```

**Version 0.9.0.** Upgrading from 0.8.0 needs every sandbox deleted first and
some values removed; see the [CHANGELOG](CHANGELOG.md).

## Quick start

If you have a Kyma cluster, `kubectl`, and an Anthropic-shaped LLM
endpoint + API key, follow
[`docs/tutorial-anthropic-direct.md`](docs/tutorial-anthropic-direct.md) —
a linear ~15 minute end-to-end from an empty cluster to Claude running
inside an isolated sandbox, using the upstream NVIDIA gateway image.

For the more comprehensive walkthrough (install, creating sandboxes,
private-in-cluster-upstream variants and troubleshooting) start at
[`docs/getting-started.md`](docs/getting-started.md). The upload, inference
and download flow, plus the SAP AI Core variant, is in
[`docs/walkthrough-claude-files.md`](docs/walkthrough-claude-files.md).

For production deploys (OIDC user auth, public Kyma APIRule, image
digests pinned), see [`docs/production-deployment.md`](docs/production-deployment.md).

For private VPN routing through SAP Cloud Connector, see
[`docs/cloud-connector-setup.md`](docs/cloud-connector-setup.md).

For installing the `openshell` CLI itself, see
[`docs/install-cli.md`](docs/install-cli.md).

For programmatic gRPC access without the CLI, see
[`docs/openshell-api-programmatic-usage.md`](docs/openshell-api-programmatic-usage.md).

## Configuration reference

The driver container takes no command-line arguments: the Helm chart turns
`values.yaml` keys into environment variables (`driver.*` and `namespace`).
The driver accepts every option of upstream's `openshell-driver-kubernetes`
under upstream's own names (long flag and `OPENSHELL_*` variable, as in
`openshell-driver-kyma --help`), and adds eight Kyma options that always
start with `--kyma-` / `OPENSHELL_KYMA_`:

| Flag | Values key | Default | Purpose |
|------|------------|---------|---------|
| `--kyma-istio-inject-sandboxes` | `driver.istioInjectSandboxes` | `false` | Value of the `sidecar.istio.io/inject` label on sandbox workloads. False means no sidecar. |
| `--kyma-disable-claude-telemetry` | `driver.disableClaudeTelemetry` | `false` | Adds `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` to every sandbox. |
| `--kyma-sandbox-env` | `driver.sandboxEnv` | none | `KEY=VALUE` added to every sandbox. Comma-separated, so a value cannot contain a comma; `OPENSHELL_*` keys other than `OPENSHELL_LOG_LEVEL` are rejected. |
| `--kyma-enable-apirule` | `driver.enableApirule` | `false` | Expose each sandbox's port 8080 through a Kyma `APIRule` (`gateway.kyma-project.io/v2`). An explicit exception to upstream's isolation; see [`docs/production-deployment.md`](docs/production-deployment.md). |
| `--kyma-cluster-domain` | `driver.clusterDomain` | `""` | Domain of the APIRule hosts (`<workspace>--<name>.<domain>`). Required with `--kyma-enable-apirule`. |
| `--kyma-ingress-namespace` | `driver.ingressNamespace` | `istio-system` | Namespace of the Istio ingress gateway that APIRule traffic arrives from. |
| `--kyma-workspace-psa-level` | `driver.workspacePsaLevel` | `""` | Pod Security level for namespaces the driver creates in managed mode (`privileged`, `baseline`, `restricted`; empty leaves them unlabelled). |
| `--kyma-health-port` | `driver.healthPort` | `9090` | Port for `/healthz` and `/readyz`. |

The upstream options most deployments touch:

| Values key | Upstream variable | Purpose |
|------------|-------------------|---------|
| `namespace` | `OPENSHELL_SANDBOX_NAMESPACE` | Namespace where Sandbox CRs are created (shared mode) |
| `driver.workspaceMode` | `OPENSHELL_WORKSPACE_MODE` | `shared`, `managed` or `operator` |
| `driver.socket` | `OPENSHELL_COMPUTE_DRIVER_SOCKET` | Unix socket the gateway connects to |
| `driver.gatewayEndpoint` | `OPENSHELL_GRPC_ENDPOINT` | Gateway endpoint that sandboxes dial |
| `driver.supervisorImage` | `OPENSHELL_SUPERVISOR_IMAGE` | Supervisor image, pinned by digest |
| `driver.sandboxRuntimeImage` | `OPENSHELL_SANDBOX_RUNTIME_IMAGE` | Sandbox runtime image, pinned by digest |
| `driver.allowDriverConfig` | `OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON` | Whether callers may pass `driver_config`; `false` by default, as upstream's (also rendered into the gateway's config) |
| `driver.resourceAdmission.{enabled,requiredLabels}` | `OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON` | Approval labels an attached PVC must carry; upstream's built-in labels by default (also rendered into the gateway's config) |
| `driver.logLevel` | `OPENSHELL_LOG_LEVEL` | Log level |

Every other option is a `driver.*` key in `values.yaml`, named after the
upstream option. The driver's health port serves only `/healthz` and
`/readyz`; upstream traces over OTLP (`driver.otlpEndpoint`).

## Development

All Rust work happens inside a containerized toolchain image; nothing is
installed on the host. Get started in two commands:

```bash
make dev-image    # build openshell-driver-kyma-dev:latest (one-off, ~6 min)
make test         # cargo fmt --check + clippy + tests
```

The first `make test` fetches upstream's crates (git dependencies) into named
Docker volumes; later runs reuse them.

Other useful targets:

```bash
make dev-shell                                          # interactive bash
make image                                              # production image
make helm-lint                                          # helm lint
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

- The driver is built on [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell)
  (Apache-2.0): its `openshell-driver-kubernetes`, `openshell-core` and
  `openshell-otel` crates are git dependencies pinned to one release tag.
  Nothing from upstream is vendored.
- The earlier reference Go implementation for OpenShift is
  [zanetworker/openshell-driver-openshift](https://github.com/zanetworker/openshell-driver-openshift)
  (Apache-2.0); see [`docs/kyma-vs-openshift.md`](docs/kyma-vs-openshift.md)
  for how the platforms differ.

## License

Apache-2.0. See [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES).
