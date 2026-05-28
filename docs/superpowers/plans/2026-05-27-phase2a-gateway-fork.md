# Phase 2a — Gateway fork with `--compute-driver-socket`

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** Produce a public container image that is the upstream NVIDIA OpenShell gateway plus a `~30-line` patch enabling it to dispatch sandbox lifecycle to an out-of-process compute driver over a Unix domain socket.

**Architecture:** Fork `NVIDIA/OpenShell` to `st-gr/OpenShell`. Add an `External(PathBuf)` variant to `ComputeDriverKind` in `crates/openshell-core/src/config.rs`. Wire a new `--compute-driver-socket` CLI flag and `OPENSHELL_COMPUTE_DRIVER_SOCKET` env var into `crates/openshell-server/src/cli.rs::RunArgs`. In the driver dispatch path, when the flag is set, build a `tonic` gRPC client over UDS using the existing `compute_driver.proto` contract instead of constructing the in-tree Kubernetes / Docker / Podman / VM driver. Build, tag, and push to `ghcr.io/st-gr/openshell-gateway`.

**Tech stack:** Rust 1.95, tonic 0.14, kube/k8s-openapi (for the in-tree drivers we leave alone), clap 4, miette, GitHub Actions for CI/release. Reference patch behavior already exists in [`zanetworker/OpenShell`](https://github.com/zanetworker/OpenShell) — read it for inspiration but apply against current NVIDIA upstream main.

**Reference materials:**
- This repo's `reference-openshift/docs/specs/2026-04-21-openshift-compute-driver-design.md` — section 7 describes the patch behavior.
- This repo's `reference-openshift/docs/plans/2026-04-21-phase1-core-and-test.md` — Task 7 has the patch outline.
- Upstream proto we already vendor at `proto/compute_driver.proto` (sha256 `80ac042…`) is the contract the gateway will speak to the external driver.

---

## File map (in the fork repo `st-gr/OpenShell`)

| File | Change |
|---|---|
| `crates/openshell-core/src/config.rs` | Add `External(PathBuf)` variant to `ComputeDriverKind`, update `Display` + `FromStr` for `external:<path>` parsing |
| `crates/openshell-core/src/drivers/mod.rs` (or wherever the dispatch lives — research in Task 3) | Branch on `ComputeDriverKind::External(socket)` to build a `tonic` UDS client instead of the in-tree drivers |
| `crates/openshell-core/src/drivers/external.rs` (NEW) | The external-driver impl: a `tonic`-backed `ComputeDriver` trait impl that dials the UDS and forwards each RPC |
| `crates/openshell-server/src/cli.rs` | Add `--compute-driver-socket` flag + env var, plumb it into `RunArgs` and onward into the compute-driver factory |
| `Dockerfile.gateway` (NEW at repo root or in `deploy/`) | Multi-stage cargo-chef build → distroless runtime, just like our driver image |
| `.github/workflows/release-gateway.yml` (NEW) | On push to `main` and on `v*` tags, build + push `ghcr.io/st-gr/openshell-gateway:{<sha>,<tag>,latest}` |
| `README-FORK.md` (NEW) | Two-paragraph note explaining this is a fork of NVIDIA/OpenShell with one patch, with a link to the spec for upstream sync notes |

We do **not** modify the proto, the supervisor, the CLI, or any tests under `crates/openshell-server/tests/`. Smaller surface = easier upstream sync.

---

### Task 1: Fork + bootstrap

**Files:** none in our repo; the fork lives at `github.com/st-gr/OpenShell`.

- [ ] **Step 1**: Visit https://github.com/NVIDIA/OpenShell, click Fork, target `st-gr/OpenShell`. Default branch: `main`.
- [ ] **Step 2**: Clone the fork locally:
  ```
  cd C:/tmp-bwx
  gh repo clone st-gr/OpenShell openshell-fork
  cd openshell-fork
  git remote add upstream https://github.com/NVIDIA/OpenShell.git
  git fetch upstream
  ```
- [ ] **Step 3**: Verify clean upstream build inside the same dev container we use for the driver:
  ```
  MSYS_NO_PATHCONV=1 docker run --rm -v "C:/tmp-bwx/openshell-fork:/workspace" \
    -v "openshell-fork-cargo:/workspace/target" -w /workspace \
    openshell-driver-kyma-dev:latest \
    cargo check -p openshell-server -p openshell-core
  ```
  Expected: `Finished` with zero errors. Note: the dev image was sized for our driver; it has all needed tooling (`cargo-chef`, `protoc`, `libprotobuf-dev`, `kubectl`, `helm`).
- [ ] **Step 4**: Cut a feature branch:
  ```
  git checkout -b feat/external-compute-driver-socket
  ```
- [ ] **Step 5**: Commit a placeholder `README-FORK.md` so the branch exists with one commit. Sign with DCO:
  ```
  git add README-FORK.md
  git commit -s -m "docs: bootstrap fork notes for external-compute-driver-socket patch"
  git push -u origin feat/external-compute-driver-socket
  ```

### Task 2: Add `External(PathBuf)` to `ComputeDriverKind`

**Files:**
- Modify: `crates/openshell-core/src/config.rs`

The current upstream enum (verified against `main` HEAD) is:
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ComputeDriverKind { Kubernetes, Vm, Docker, Podman }
```
plus `as_str`, `Display`, and `FromStr` impls. The new variant is **not** `Copy` because it carries a `PathBuf`, so we need to drop `Copy` from the derive (research how many call sites depend on `Copy`).

- [ ] **Step 1**: Search the workspace for `ComputeDriverKind` to inventory every consumer:
  ```
  rg -l 'ComputeDriverKind' crates/
  ```
  Note every match. Likely callers are in `openshell-server/src/cli.rs` (clap arg) and `openshell-core/src/drivers/` (factory).
- [ ] **Step 2**: Verify which callers depend on `Copy`:
  ```
  rg 'ComputeDriverKind\b' --json | jq -r '.data.lines.text' | sort -u
  ```
  Likely only Vec<ComputeDriverKind>::contains and explicit `.clone()` use it. Remove `Copy` from the derive — `Clone` is sufficient.
- [ ] **Step 3**: Add the variant. Updated enum:
  ```rust
  #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
  #[serde(rename_all = "snake_case")]
  pub enum ComputeDriverKind {
      Kubernetes,
      Vm,
      Docker,
      Podman,
      /// Out-of-process compute driver speaking the gRPC `compute_driver.proto`
      /// contract over a Unix domain socket. The path is supplied by
      /// `--compute-driver-socket` or `OPENSHELL_COMPUTE_DRIVER_SOCKET`.
      External(std::path::PathBuf),
  }
  ```
- [ ] **Step 4**: Update the `as_str` method to return `"external"` for the new variant.
- [ ] **Step 5**: Update `Display` to write `external:<path>` (so configs round-trip).
- [ ] **Step 6**: Update `FromStr` to parse `external:<path>`. Reject `external` without a path with a clear error message.
- [ ] **Step 7**: Run the workspace's existing tests:
  ```
  cargo test -p openshell-core
  ```
  Expect: existing tests pass, no new tests required at this step.
- [ ] **Step 8**: Commit:
  ```
  git add crates/openshell-core/src/config.rs
  git commit -s -m "feat(core): add External(PathBuf) variant to ComputeDriverKind

  Carries the UDS path supplied by --compute-driver-socket. Drops Copy
  from the enum derive (PathBuf is not Copy); existing callers use
  Clone or owned values."
  ```

### Task 3: Trace the driver-factory path

**Files:** none yet — this is a research task. Output is a short note in the commit message of Task 4.

- [ ] **Step 1**: Find where `ComputeDriverKind` becomes a runtime trait object. Search:
  ```
  rg -A 3 'fn .*\(.* ComputeDriverKind' crates/
  rg 'match .*ComputeDriverKind' crates/ -A 5
  ```
- [ ] **Step 2**: Identify the trait the in-tree drivers implement (likely `ComputeDriver` or `Provisioner` in `openshell-core`). Note its method signatures — they are the surface our `External` impl must wrap.
- [ ] **Step 3**: Note the file and line where the factory dispatches each variant. This is the point we add the `External(socket)` arm in Task 4.
- [ ] **Step 4**: Confirm the trait is `dyn`-compatible (no generics on methods, no `Self: Sized` on impl). If it isn't, abandon and ask the user — that means the patch is much larger than ~30 lines.

### Task 4: Implement `ExternalComputeDriver`

**Files:**
- Create: `crates/openshell-core/src/drivers/external.rs`
- Modify: `crates/openshell-core/src/drivers/mod.rs` (or whichever module the in-tree drivers live in — confirmed in Task 3)

- [ ] **Step 1**: In `crates/openshell-core/src/drivers/external.rs`, build a tonic client over UDS to the proto we already know (paths inside the fork: copy `proto/compute_driver.proto` from the upstream tree if not already vendored; the fork already has it under `proto/`). Skeleton:
  ```rust
  use std::path::PathBuf;
  use std::sync::Arc;
  use tonic::transport::{Channel, Endpoint, Uri};
  use tower::service_fn;
  use crate::compute_driver::compute_driver_client::ComputeDriverClient;

  pub struct ExternalComputeDriver {
      client: ComputeDriverClient<Channel>,
  }

  impl ExternalComputeDriver {
      pub async fn connect(socket: PathBuf) -> miette::Result<Arc<Self>> {
          let channel = Endpoint::try_from("http://[::1]:0")
              .map_err(|e| miette::miette!("endpoint: {e}"))?
              .connect_with_connector(service_fn(move |_: Uri| {
                  let s = socket.clone();
                  async move {
                      Ok::<_, std::convert::Infallible>(
                          hyper_util::rt::TokioIo::new(
                              tokio::net::UnixStream::connect(s).await
                                  .expect("connect UDS")
                          )
                      )
                  }
              }))
              .await
              .map_err(|e| miette::miette!("connect UDS: {e}"))?;
          Ok(Arc::new(Self { client: ComputeDriverClient::new(channel) }))
      }
  }
  ```
- [ ] **Step 2**: Implement the in-tree driver trait for `ExternalComputeDriver`. Each method forwards to the gRPC client. The exact trait surface comes from Task 3. For each method, the body is `self.client.clone().<rpc>(req).await`.
- [ ] **Step 3**: Wire `ExternalComputeDriver::connect` into the factory. Pseudocode at the dispatch site (the file you found in Task 3):
  ```rust
  match kind {
      ComputeDriverKind::Kubernetes => /* existing */,
      ComputeDriverKind::Vm => /* existing */,
      ComputeDriverKind::Docker => /* existing */,
      ComputeDriverKind::Podman => /* existing */,
      ComputeDriverKind::External(socket) => {
          ExternalComputeDriver::connect(socket.clone()).await?
      },
  }
  ```
- [ ] **Step 4**: Add `hyper-util = { version = "0.1", features = ["tokio"] }` to `crates/openshell-core/Cargo.toml` if not already present. The connector pattern uses `hyper_util::rt::TokioIo`.
- [ ] **Step 5**: Build the workspace:
  ```
  cargo build -p openshell-server
  ```
  Expected: `Finished` with no warnings (modulo `clippy::pedantic` which the fork doesn't enable). Any pre-existing warnings are out of scope.
- [ ] **Step 6**: Commit:
  ```
  git add crates/openshell-core/src/drivers/external.rs \
          crates/openshell-core/src/drivers/mod.rs \
          crates/openshell-core/Cargo.toml
  git commit -s -m "feat(core): wire ExternalComputeDriver dispatch from External(socket)

  Adds an external-driver impl that dials the configured Unix domain
  socket as a tonic ComputeDriver gRPC client. Each in-tree driver kind
  remains untouched; the new External arm of ComputeDriverKind routes
  through this client.

  Driver dispatch found at: <file:line from Task 3>
  Trait wrapped: <trait name from Task 3>"
  ```

### Task 5: CLI flag in `openshell-server`

**Files:**
- Modify: `crates/openshell-server/src/cli.rs`

Existing `RunArgs` (from earlier upstream research) carries `drivers: Vec<ComputeDriverKind>` parsed by `--drivers`. Add the new flag at the same level.

- [ ] **Step 1**: Add the field:
  ```rust
  /// Path to a Unix domain socket served by an external compute driver
  /// implementing compute_driver.proto. When set, ComputeDriverKind::External
  /// is appended to the resolved driver list.
  #[arg(long, env = "OPENSHELL_COMPUTE_DRIVER_SOCKET")]
  compute_driver_socket: Option<std::path::PathBuf>,
  ```
- [ ] **Step 2**: After `RunArgs::parse()` (find the call site — usually `cli.rs::run_cli`), if `compute_driver_socket.is_some()`, push `ComputeDriverKind::External(path)` onto the resolved drivers list **before** the auto-detection runs. Auto-detection should be skipped when the External driver is set; the user is being explicit.
- [ ] **Step 3**: Smoke test:
  ```
  cargo run -p openshell-server -- run \
    --compute-driver-socket /tmp/nonexistent.sock --disable-tls
  ```
  Expected: gateway prints a startup banner, then fails to connect with a clear "connect UDS" error pointing at `/tmp/nonexistent.sock`. (We're not testing happy-path here; we're verifying the flag is plumbed.)
- [ ] **Step 4**: Commit:
  ```
  git add crates/openshell-server/src/cli.rs
  git commit -s -m "feat(server): --compute-driver-socket CLI flag

  Adds a top-level flag and OPENSHELL_COMPUTE_DRIVER_SOCKET env var.
  When set, the gateway uses the external compute driver instead of
  auto-detecting kubernetes/podman/docker."
  ```

### Task 6: Dockerfile + GHCR publish workflow

**Files:**
- Create: `Dockerfile.gateway` at the fork repo root
- Create: `.github/workflows/release-gateway.yml`

- [ ] **Step 1**: Write `Dockerfile.gateway` mirroring the production Dockerfile we already use for the driver in this repo (cargo-chef → distroless cc nonroot, Rust 1.95.0). Build the `openshell-server` binary:
  ```dockerfile
  ARG RUST_VERSION=1.95.0
  FROM rust:${RUST_VERSION}-slim-bookworm AS chef
  RUN apt-get update && apt-get install -y --no-install-recommends \
      protobuf-compiler libprotobuf-dev pkg-config build-essential \
    && rm -rf /var/lib/apt/lists/*
  RUN cargo install --locked cargo-chef
  WORKDIR /app

  FROM chef AS planner
  COPY . .
  RUN cargo chef prepare --recipe-path recipe.json

  FROM chef AS builder
  COPY --from=planner /app/recipe.json recipe.json
  RUN cargo chef cook --release --recipe-path recipe.json -p openshell-server
  COPY . .
  RUN cargo build --release --bin openshell-server \
   && strip target/release/openshell-server

  FROM gcr.io/distroless/cc-debian12:nonroot
  COPY --from=builder /app/target/release/openshell-server /usr/local/bin/openshell-server
  USER 65532:65532
  ENTRYPOINT ["/usr/local/bin/openshell-server"]
  ```
- [ ] **Step 2**: Write `.github/workflows/release-gateway.yml`:
  ```yaml
  name: release-gateway
  on:
    push:
      branches: [main, feat/external-compute-driver-socket]
      paths-ignore: ['**.md', 'docs/**']
    workflow_dispatch:
  permissions:
    contents: read
    packages: write
  jobs:
    image:
      runs-on: ubuntu-latest
      timeout-minutes: 60
      steps:
        - uses: actions/checkout@v4
        - uses: docker/setup-buildx-action@v3
        - uses: docker/login-action@v3
          with:
            registry: ghcr.io
            username: ${{ github.actor }}
            password: ${{ secrets.GITHUB_TOKEN }}
        - id: repo
          run: echo "lower=$(echo '${{ github.repository_owner }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_OUTPUT"
        - uses: docker/build-push-action@v6
          with:
            context: .
            file: Dockerfile.gateway
            push: true
            tags: |
              ghcr.io/${{ steps.repo.outputs.lower }}/openshell-gateway:${{ github.sha }}
              ghcr.io/${{ steps.repo.outputs.lower }}/openshell-gateway:latest
            cache-from: type=gha
            cache-to: type=gha,mode=max
  ```
- [ ] **Step 3**: Build locally first to catch errors:
  ```
  docker build -f Dockerfile.gateway -t openshell-gateway:dev .
  docker run --rm openshell-gateway:dev run --help
  ```
  Expected: prints clap help; the new `--compute-driver-socket` flag appears under "Options".
- [ ] **Step 4**: Push the branch. CI will build and publish `ghcr.io/st-gr/openshell-gateway:<sha>` and `:latest`. Make the package public via the GHCR UI (Packages → openshell-gateway → Settings → Change visibility → Public).
- [ ] **Step 5**: Commit:
  ```
  git add Dockerfile.gateway .github/workflows/release-gateway.yml
  git commit -s -m "build(gateway): Dockerfile + GHCR release workflow"
  git push
  ```

### Task 7: End-to-end smoke against this repo's driver

**Files:** none (verification-only, run from this repo `C:/tmp-bwx/openshell-driver-kyma`).

- [ ] **Step 1**: Run the driver locally on a temp UDS (it stays Linux-only; do this inside the dev container or on a Linux host):
  ```
  docker network create openshell-test || true
  docker run --rm -d --name openshell-driver-test \
    --network openshell-test -v /tmp/sock:/sock \
    openshell-driver-kyma:dev --socket /sock/driver.sock --namespace openshell-test
  ```
  (Note: the driver will fail PSA pre-flight against an empty cluster — that's expected. Either point KUBECONFIG at a kind cluster or run with the new fork's gateway in a follow-up; for this smoke we only verify the gateway can dial the UDS. You can also use a stub UDS server that just accepts the connection.)
- [ ] **Step 2**: Run the forked gateway pointing at the same UDS:
  ```
  docker run --rm --network openshell-test -v /tmp/sock:/sock \
    ghcr.io/st-gr/openshell-gateway:latest run \
    --compute-driver-socket /sock/driver.sock --disable-tls
  ```
- [ ] **Step 3**: Expected: gateway logs include "connected to external driver socket" or similar, and dialing ANY of the gateway's `OpenShell.*` RPCs from a gRPC client (e.g. `grpcurl`) returns a sensible response or a clear "driver call failed: <reason>" propagated from our driver.
- [ ] **Step 4**: Open a PR to merge `feat/external-compute-driver-socket` into `st-gr/OpenShell`'s `main`. The image build retags `:latest`.

### Task 8: Optional — propose upstream PR

**Files:** the same patch, opened as a PR to `NVIDIA/OpenShell:main` from `st-gr/OpenShell:feat/external-compute-driver-socket`.

- [ ] **Step 1**: Open the PR.  Title: `feat(server): out-of-process compute driver via --compute-driver-socket`. Body: link to this plan, the patch's three commits (Tasks 2, 4, 5), and the proto contract we speak (`proto/compute_driver.proto` already in upstream).
- [ ] **Step 2**: Track the PR; update if NVIDIA reviewers request changes. The fork remains the canonical source until the PR merges.

---

## Verification (end-to-end)

1. `docker pull ghcr.io/st-gr/openshell-gateway:latest && docker run --rm ghcr.io/st-gr/openshell-gateway:latest run --help` exits 0 and lists the `--compute-driver-socket` flag.
2. Pointing the gateway at a UDS where `openshell-driver-kyma` listens succeeds: gateway boots, accepts gRPC requests, and forwards each compute-driver RPC to the driver.
3. The fork's CI is green on the feature branch and on `main` after merge.

## Self-review checklist

- **Spec coverage**: covers the gateway-fork half of the closure plan. The other halves are 2b (driver hardening) and 2c (e2e deployment + docs + test).
- **Placeholders**: Task 3 deliberately calls out research-then-code because the exact driver-factory module path can't be pre-known with confidence — the imperative is concrete (`rg` commands listed) and the engineer doesn't have to invent anything.
- **Type consistency**: `ComputeDriverKind::External(PathBuf)` used consistently. `ExternalComputeDriver::connect` is the only constructor. The trait impl's surface is determined in Task 3 and re-used in Task 4.
- **Risk**: if the in-tree driver trait is not `dyn`-compatible (Task 3 step 4), the patch grows beyond ~30 lines. Plan calls this out as an abandon-and-ask point.
