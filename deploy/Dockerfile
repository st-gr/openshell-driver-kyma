# syntax=docker/dockerfile:1.7
# Production Dockerfile for openshell-driver-kyma.
#
# Multi-stage build using cargo-chef to keep the dep-resolution layer
# cached separately from the source. Final stage is distroless/static
# (rustls only, no openssl) running as nonroot user 65532:65532. The
# resulting image fits Kyma's `restricted` Pod Security profile cleanly.

ARG RUST_VERSION=1.95.0

# --- recipe stage ----------------------------------------------------------
FROM rust:${RUST_VERSION}-slim-bookworm AS chef
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        protobuf-compiler libprotobuf-dev pkg-config build-essential \
    && rm -rf /var/lib/apt/lists/*
RUN cargo install --locked cargo-chef
WORKDIR /app

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# --- builder stage ---------------------------------------------------------
FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json
COPY . .
RUN cargo build --release --bin openshell-driver-kyma \
    && strip target/release/openshell-driver-kyma

# --- runtime stage ---------------------------------------------------------
# distroless/cc keeps glibc + libgcc (~22 MB) for the dynamically-linked
# rust binary. distroless/static would shave a few MB but requires a musl
# build target which we don't currently configure.
FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=builder /app/target/release/openshell-driver-kyma /usr/local/bin/openshell-driver-kyma
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/openshell-driver-kyma"]
