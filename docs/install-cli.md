# Installing the OpenShell CLI

The `openshell` CLI is the user-facing client for any OpenShell gateway,
including the one shipped by this chart. It's published as a single
musl-static binary (x86_64 and aarch64) and a macOS Apple Silicon archive on
the NVIDIA upstream releases page. The PyPI package no longer contains the
CLI.

## Pick the right version

The CLI's gRPC contract evolves with the gateway. Pin the CLI to the
same upstream release as the gateway image you deployed. The chart deploys
upstream `v0.1.2` (`upstream.version` in `values.yaml`), so install the
`v0.1.2` CLI; if you moved the chart to another upstream release, install
that exact tag.

## Linux x86_64 — direct musl tarball (recommended for CI)

No glibc requirement; no Python. Single binary.

```bash
VERSION=v0.1.2
curl -fsSL "https://github.com/NVIDIA/OpenShell/releases/download/${VERSION}/openshell-x86_64-unknown-linux-musl.tar.gz" \
  | tar -xz -C /usr/local/bin
openshell --version
```

For Linux aarch64, use `openshell-aarch64-unknown-linux-musl.tar.gz`.

## macOS — Apple Silicon tarball

```bash
VERSION=v0.1.2
curl -fsSL "https://github.com/NVIDIA/OpenShell/releases/download/${VERSION}/openshell-aarch64-apple-darwin.tar.gz" \
  | tar -xz -C /usr/local/bin
openshell --version
```

## Windows — WSL2

Native Windows isn't an officially supported target. Use WSL2 + the
Linux musl install above. Git Bash works as a development shell but
not for the CLI's `sandbox connect` (no PTY).

## First-time setup

The CLI talks to a gateway. There are three ways to point it at one:

1. **Per-call (stateless)** — pass `--gateway-endpoint http://<host>:<port>`
   on every command. This keeps `$HOME` clean.
2. **Stored registration** — `openshell gateway add http://<host>:<port> --name my-kyma`,
   then operate against `--gateway my-kyma` (or set `OPENSHELL_GATEWAY=my-kyma`).
3. **Environment variable** — `export OPENSHELL_GATEWAY_ENDPOINT=http://<host>:<port>`.

For OIDC-protected gateways (the recommended production setup —
see [`docs/production-deployment.md`](production-deployment.md))
the CLI opens a browser on first call to mint a token, then caches
the refresh token under `$HOME/.config/openshell/`.

For unauthenticated cluster-internal gateways (the chart's default,
behind a port-forward), pass `--gateway-endpoint http://localhost:8080`
after `kubectl port-forward svc/<release>-openshell-driver-kyma 8080:8080`.

## Verify

```bash
openshell --version          # prints the CLI version
openshell status             # prints "Server Status" if the gateway is reachable
openshell sandbox list       # empty list on a fresh install
```

If `openshell status` returns `missing authorization header`, your
gateway requires auth — set up OIDC per the production runbook or
deploy with `gateway.oidc.issuer=""` (the chart will set
`allow_unauthenticated_users = true` when no issuer is configured,
suitable only for in-cluster / port-forward access).
