# openshell-driver-kyma Makefile
#
# All Rust work happens inside the `openshell-driver-kyma-dev:latest`
# container, mounted read-write at /workspace with a named Docker volume
# at /workspace/target so cargo's incremental cache survives between runs.
# Linux/macOS hosts work directly; Windows hosts must use Git Bash or WSL2.

.SHELLFLAGS := -eu -o pipefail -c

IMAGE_NAME ?= openshell-driver-kyma
IMAGE_TAG ?= dev
DEV_IMAGE ?= openshell-driver-kyma-dev:latest
HELM_CHART ?= deploy/helm/openshell-driver-kyma
INTEGRATION_TEST_NAMESPACE ?=

DOCKER_RUN := MSYS_NO_PATHCONV=1 docker run --rm \
    -v "$(CURDIR):/workspace" \
    -v "openshell-cargo-cache:/workspace/target" \
    -w /workspace

DOCKER_RUN_INTERACTIVE := MSYS_NO_PATHCONV=1 docker run --rm -it \
    -v "$(CURDIR):/workspace" \
    -v "openshell-cargo-cache:/workspace/target" \
    -w /workspace

.PHONY: help
help:
	@echo "Common targets:"
	@echo "  dev-image            build the dev toolchain image"
	@echo "  dev-shell            interactive shell in the dev image"
	@echo "  dev-shell-with-kube  shell with \$$HOME/.kube mounted read-only"
	@echo ""
	@echo "  proto                regenerate tonic/prost bindings (rare)"
	@echo "  fmt                  cargo fmt --all"
	@echo "  fmt-check            cargo fmt --all --check"
	@echo "  clippy               cargo clippy with pedantic warnings as errors"
	@echo "  build                cargo build --release --workspace"
	@echo "  test                 fmt-check + clippy + cargo test --workspace"
	@echo "  test-integration     Tier-3 live cluster (requires INTEGRATION_TEST_NAMESPACE)"
	@echo "  test-all             test + test-integration"
	@echo "  coverage             cargo llvm-cov over the workspace"
	@echo ""
	@echo "  image                build the production container ($(IMAGE_NAME):$(IMAGE_TAG))"
	@echo "  helm-lint            helm lint $(HELM_CHART)"
	@echo "  helm-template        helm template ..."
	@echo "  clean                cargo clean + remove dist/"

# ---------------------------------------------------------------------------
# Dev container
# ---------------------------------------------------------------------------

.PHONY: dev-image
dev-image:
	docker build -f deploy/Dockerfile.dev -t $(DEV_IMAGE) .

.PHONY: dev-shell
dev-shell:
	$(DOCKER_RUN_INTERACTIVE) $(DEV_IMAGE) bash

.PHONY: dev-shell-with-kube
dev-shell-with-kube:
	$(DOCKER_RUN_INTERACTIVE) -v "$(HOME)/.kube:/root/.kube:ro" $(DEV_IMAGE) bash

# ---------------------------------------------------------------------------
# Build / test (run inside the dev container)
# ---------------------------------------------------------------------------

.PHONY: proto
proto:
	$(DOCKER_RUN) $(DEV_IMAGE) cargo build -p computev1

.PHONY: fmt
fmt:
	$(DOCKER_RUN) $(DEV_IMAGE) cargo fmt --all

.PHONY: fmt-check
fmt-check:
	$(DOCKER_RUN) $(DEV_IMAGE) cargo fmt --all -- --check

.PHONY: clippy
clippy:
	$(DOCKER_RUN) $(DEV_IMAGE) cargo clippy --workspace --all-targets -- -D warnings

.PHONY: build
build:
	$(DOCKER_RUN) $(DEV_IMAGE) cargo build --release --workspace

.PHONY: test
test: fmt-check clippy
	$(DOCKER_RUN) $(DEV_IMAGE) cargo test --workspace --lib --tests

.PHONY: test-integration
test-integration:
ifeq ($(strip $(INTEGRATION_TEST_NAMESPACE)),)
	$(error INTEGRATION_TEST_NAMESPACE must be set, e.g. INTEGRATION_TEST_NAMESPACE=openshell-driver-test)
endif
	$(DOCKER_RUN) -v "$(HOME)/.kube:/root/.kube:ro" \
		-e INTEGRATION_TEST_NAMESPACE=$(INTEGRATION_TEST_NAMESPACE) \
		-e INTEGRATION_TEST_NAMESPACE_DENYLIST=$${INTEGRATION_TEST_NAMESPACE_DENYLIST:-} \
		$(DEV_IMAGE) \
		cargo test -p openshell-driver-kyma --test live_cluster --features integration -- --test-threads=1

.PHONY: test-all
test-all: test test-integration

.PHONY: coverage
coverage:
	$(DOCKER_RUN) $(DEV_IMAGE) cargo llvm-cov --workspace --html --output-dir coverage

.PHONY: dev-test
dev-test: test

.PHONY: dev-build
dev-build: build

# ---------------------------------------------------------------------------
# Container image (production)
# ---------------------------------------------------------------------------

.PHONY: image
image:
	docker build -f deploy/Dockerfile -t $(IMAGE_NAME):$(IMAGE_TAG) .

.PHONY: image-help
image-help: image
	docker run --rm $(IMAGE_NAME):$(IMAGE_TAG) --help

# ---------------------------------------------------------------------------
# Helm chart
# ---------------------------------------------------------------------------

.PHONY: helm-lint
helm-lint:
	$(DOCKER_RUN) $(DEV_IMAGE) helm lint $(HELM_CHART)

.PHONY: helm-template
helm-template:
	$(DOCKER_RUN) $(DEV_IMAGE) helm template $(HELM_CHART)

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

.PHONY: clean
clean:
	$(DOCKER_RUN) $(DEV_IMAGE) cargo clean
	rm -rf dist coverage

# ---------------------------------------------------------------------------
# Self-hosted runner (Kyma-hosted GitHub Actions runner)
# ---------------------------------------------------------------------------
# All targets here assume kubectl on PATH and authenticated against the
# target cluster. Tokens never reach Make variables; the secret is created
# interactively via `make runner-create-secret`.

RUNNER_NS ?= gh-runner
OWNER ?=
REPO ?=

.PHONY: runner-deploy
runner-deploy:
	kubectl apply -f deploy/runner/namespace.yaml
	kubectl apply -f deploy/runner/serviceaccount.yaml
	kubectl apply -f deploy/runner/configmap.yaml
	kubectl apply -f deploy/runner/configmap-entrypoint.yaml
	kubectl apply -f deploy/runner/networkpolicy.yaml
	@echo ""
	@echo "Namespace, SA, ConfigMaps, and NetworkPolicy applied."
	@echo "Next: create the credentials Secret with"
	@echo "    make runner-create-secret"
	@echo "Then add a runner per repo with"
	@echo "    make runner-add-repo OWNER=<owner> REPO=<repo>"

.PHONY: runner-create-secret
runner-create-secret:
	@node scripts/create-runner-secret.js $(RUNNER_NS)

.PHONY: runner-add-repo
runner-add-repo:
ifeq ($(strip $(OWNER)),)
	$(error OWNER is required, e.g. OWNER=st-gr REPO=OpenShell)
endif
ifeq ($(strip $(REPO)),)
	$(error REPO is required, e.g. OWNER=st-gr REPO=OpenShell)
endif
	node scripts/add-runner-repo.js --owner $(OWNER) --repo $(REPO) --namespace $(RUNNER_NS) --apply

.PHONY: runner-remove-repo
runner-remove-repo:
ifeq ($(strip $(OWNER)),)
	$(error OWNER is required)
endif
ifeq ($(strip $(REPO)),)
	$(error REPO is required)
endif
	node scripts/remove-runner-repo.js --owner $(OWNER) --repo $(REPO) --namespace $(RUNNER_NS)

.PHONY: runner-status
runner-status:
	@kubectl -n $(RUNNER_NS) get pods -L runner-repo

.PHONY: runner-logs
runner-logs:
ifeq ($(strip $(OWNER)),)
	$(error OWNER is required)
endif
ifeq ($(strip $(REPO)),)
	$(error REPO is required)
endif
	kubectl -n $(RUNNER_NS) logs -f deployment/runner-$(shell echo $(OWNER) | tr '[:upper:]' '[:lower:]')-$(shell echo $(REPO) | tr '[:upper:]' '[:lower:]')
