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

FROM ghcr.io/st-gr/e2e-sandbox:latest

USER root
ENV DEBIAN_FRONTEND=noninteractive

# Node 22 LTS — Claude Code's package needs Node 20+ (string-width's /v
# regex flag is one of several gates; 22 LTS is the conservative pick).
ARG NODE_MAJOR=22
RUN apt-get update \
    && apt-get install -y --no-install-recommends gnupg \
    && curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pre-onboarded ~/.claude.json template + claude-tui wrapper.
#
# Without this, the interactive TUI shows an onboarding/login screen
# claude can't write through (filesystem_policy makes /home/sandbox
# read-only). The wrapper sets HOME=/tmp, copies the template into
# place if missing, unsets the supervisor's resolver-placeholder
# ANTHROPIC_API_KEY (which conflicts with the file's primaryApiKey),
# and execs claude with ANTHROPIC_BASE_URL pre-set. See claude-tui.sh
# for the rationale per env var.
#
# The placeholder primaryApiKey is intentional — the L7 router strips
# whatever claude sends and substitutes the upstream's bundle key, so
# the file's value just needs to be format-valid.
RUN mkdir -p /etc/openshell/skel
COPY claude.json.skel /etc/openshell/skel/claude.json
COPY claude-tui.sh /usr/local/bin/claude-tui
RUN chmod 755 /usr/local/bin/claude-tui /etc/openshell/skel/claude.json

# Drop back to the unprivileged sandbox user; the supervisor runs the
# agent as this UID via policy.process.run_as_user.
USER sandbox
WORKDIR /sandbox
