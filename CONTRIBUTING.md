# Contributing

Thanks for your interest! This project keeps a small, predictable
developer experience: all Rust work runs inside a container, every commit
must be DCO-signed, and PRs go green before they merge.

## Developer Certificate of Origin (DCO)

Every commit must carry a `Signed-off-by:` line matching the commit
author. Add one with `git commit -s`. The
[`dco.yml`](.github/workflows/dco.yml) workflow blocks merges if any
commit on the branch is missing the trailer.

If you forgot to sign:

```bash
git commit --amend -s          # for the most recent commit
git rebase -i --signoff <base> # for older commits in the branch
```

## Local workflow

Rust 1.95.0 lives inside the dev container, not on your host. Bootstrap
the image once, then iterate from any host that has Docker.

```bash
make dev-image
make test                      # cargo fmt --check + clippy + tests
make build                     # cargo build --release
make image                     # production container
make helm-lint
```

For interactive work:

```bash
make dev-shell                 # cargo, kubectl, helm, markdownlint
make dev-shell-with-kube       # also mounts $HOME/.kube read-only
```

The `target/` directory is mounted as a named Docker volume
(`openshell-cargo-cache`) so incremental builds survive between runs.

## Branch + PR conventions

- Branches: `feat/<short-name>`, `fix/<short-name>`, `chore/<short-name>`,
  `docs/<short-name>`, `ci/<short-name>`, `test/<short-name>`.
- Commits: [Conventional
  Commits](https://www.conventionalcommits.org/) subject lines (e.g.
  `feat(provisioner): ...`). The body should explain *why*, not just *what*.
- PR checklist:
  1. `make test` passes locally (or in CI).
  2. `cargo clippy ... -W clippy::pedantic` is clean.
  3. Any plan deviation is documented in the commit body.
  4. Live-cluster behavior, if changed, was verified with
     `make test-integration INTEGRATION_TEST_NAMESPACE=...`.

## Tier-3 live cluster tests

The Tier-3 suite (`tests/live_cluster.rs`) runs against a real
Kubernetes cluster with the agent-sandbox CRD installed. It is gated
behind the `integration` Cargo feature and the
`INTEGRATION_TEST_NAMESPACE` env var. The harness refuses to run in any
of the well-known system namespaces (`default`, `kube-system`,
`kube-public`, `kube-node-lease`, `istio-system`, `kyma-system`,
`agent-sandbox-system`) and you can extend that deny-list at runtime via
`INTEGRATION_TEST_NAMESPACE_DENYLIST`.

## Reporting security issues

See [SECURITY.md](SECURITY.md). Do not open public issues for security
problems.
