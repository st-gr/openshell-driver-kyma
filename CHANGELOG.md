# Changelog

All notable changes to openshell-driver-kyma are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial Phase 1 implementation: KymaProvisioner, KymaEnricher,
  PrometheusMetrics, Driver gRPC service implementing all 8 RPCs from
  the OpenShell `ComputeDriver` contract.
- Tier-1 unit tests (65 cases), Tier-2 gRPC contract tests over real
  Unix domain socket (8 cases), Tier-3 live-cluster harness with
  hardcoded deny-list of system namespaces (5 live cases gated by
  `INTEGRATION_TEST_NAMESPACE`).
- Pod Security Admission fail-fast at startup; clear error pointing to
  the kubectl command that fixes the namespace label.
- Optional Kyma `APIRule` rendering behind `--enable-apirule`.
- Helm chart with gated RBAC (cluster-scope node access only when
  `--gpu-support`, APIRule permissions only when `--enable-apirule`),
  restricted Pod Security context for the driver pod, optional sandbox
  NetworkPolicy, pre-install Job that aborts the release if the
  agent-sandbox CRD is missing.
- GitHub Actions workflows: `branch-checks`, `dco`, `helm-lint`,
  `docker-build`, `release-tag`. Dependabot watching cargo, github-actions,
  and docker on a weekly cadence.
- Development container (`deploy/Dockerfile.dev`) bundling Rust 1.95.0
  toolchain plus protoc, kubectl, helm, and markdownlint-cli2 so the
  host needs only Docker to build/test the project.
