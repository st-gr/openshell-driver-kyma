# Sandbox image with Claude Code pre-installed.
#
# Extends the e2e-sandbox base (ubuntu:24.04 + iproute2 + nftables + curl
# + the `sandbox` user the OpenShell supervisor expects) with Node 22 LTS
# (via NodeSource) and the `claude` CLI from npm.
#
# Use as: openshell sandbox create --from ghcr.io/st-gr/sandbox-claude:latest
#
# The agent inside the sandbox sees `ANTHROPIC_BASE_URL=https://inference.local/v1`
# (injected by the openshell-driver-kyma provisioner). The supervisor's
# in-process inference router intercepts that, fetches the bundle from
# the gateway sidecar, and dials the operator's real upstream — neither
# this image nor the agent process ever sees the real URL or API key.

# Base image, PINNED BY DIGEST. `:latest` here meant a rebuild of this
# image could silently pick up a different base than the one last
# reviewed -- the same failure mode that made the supervisor image a
# digest pin in deploy/helm/.../values.yaml. Pinning also makes a build
# of this Dockerfile reproducible: the same commit yields the same base.
#
# To re-resolve after a deliberate base bump:
#   docker buildx imagetools inspect ghcr.io/st-gr/e2e-sandbox:latest \
#     --format '{{json .Manifest.Digest}}'
#
# Note the trade-off this creates: build-sandbox-claude.yml still triggers
# on changes under e2e/sandbox/**, but a rebuilt base no longer reaches
# this image on its own -- the digest below has to be bumped in a commit.
# That is the intended cost of not tracking a moving tag.
# scripts/check-image-pins.sh reports when this digest has fallen behind.
FROM ghcr.io/st-gr/e2e-sandbox@sha256:abbcc9a966fde6395916eaef25064c9d010a7cbdb912f7c97a04d726ca832b97

USER root
ENV DEBIAN_FRONTEND=noninteractive

# Node 22 LTS — Claude Code's package needs Node 20+ (string-width's /v
# regex flag is one of several gates; 22 LTS is the conservative pick).
ARG NODE_MAJOR=22
# Claude Code version, PINNED. An unpinned `npm install -g` meant two
# builds of the same commit could bake different agent versions, so a
# sandbox's behaviour was not reproducible from its source. Bump this
# deliberately; scripts/check-image-pins.sh reports when it is behind.
ARG CLAUDE_CODE_VERSION=2.1.239
RUN apt-get update \
    && apt-get install -y --no-install-recommends gnupg \
    && curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pre-onboarded ~/.claude.json template + wrapper installed as `claude`.
#
# Without the wrapper, the interactive TUI shows an onboarding/login
# screen claude can't write through (filesystem_policy makes
# /home/sandbox read-only). The wrapper sets HOME=/tmp, copies the
# template into place if missing, unsets the supervisor's
# resolver-placeholder ANTHROPIC_API_KEY (which conflicts with the
# file's primaryApiKey), and execs the real claude with
# ANTHROPIC_BASE_URL pre-set. See claude-tui.sh for the rationale per
# env var.
#
# Install destination is /usr/local/bin/claude — the default Ubuntu
# PATH puts /usr/local/bin before /usr/bin, so typing `claude` finds
# the wrapper first; the wrapper exec's /usr/bin/claude (the real npm
# binary) by full path, avoiding recursion. claude-tui is kept as a
# symlink so one-release-old docs / muscle memory keep working.
#
# The placeholder primaryApiKey is intentional — the L7 router strips
# whatever claude sends and substitutes the upstream's bundle key, so
# the file's value just needs to be format-valid.
RUN mkdir -p /etc/openshell/skel
COPY claude.json.skel /etc/openshell/skel/claude.json
COPY claude-tui.sh /usr/local/bin/claude
RUN chmod 755 /usr/local/bin/claude /etc/openshell/skel/claude.json \
 && ln -s claude /usr/local/bin/claude-tui

# Drop back to the unprivileged sandbox user; the supervisor runs the
# agent as this UID via policy.process.run_as_user.
USER sandbox
WORKDIR /sandbox
