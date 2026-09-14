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
# Claude Code version, PINNED — but the pin lives in package.json, not here.
#
# It used to be an ARG in this file, which nothing could manage: dependabot's
# docker ecosystem only tracks `FROM` tags, so every bump was a manual commit
# prompted by scripts/check-image-pins.sh. That pin went stale within six days
# twice running, which is exactly how an always-red check stops being read.
#
# package.json exists solely to give dependabot's npm ecosystem something it
# understands (see .github/dependabot.yml). It is never installed as a package
# and never published — the Dockerfile just reads the version out of it, so
# there is one source of truth rather than two that can drift.
COPY package.json /tmp/agent-package.json
RUN apt-get update \
    && apt-get install -y --no-install-recommends gnupg \
    && curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && CLAUDE_CODE_VERSION="$(node -p "require('/tmp/agent-package.json').dependencies['@anthropic-ai/claude-code']")" \
    && echo "installing claude-code ${CLAUDE_CODE_VERSION} (from package.json)" \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && rm -f /tmp/agent-package.json \
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

# Remove the inherited login-shell dotfiles from /home/sandbox.
#
# The supervisor injects HOME=/home/sandbox (from the passwd entry) but
# filesystem_policy makes that directory unreadable, so every `sandbox exec`
# starts with:
#
#   /bin/bash: /home/sandbox/.profile: Permission denied
#
# bash is silent about a MISSING startup file and warns only about one it
# cannot read, so deleting them removes the noise. .bashrc and .bash_logout
# go too -- they are equally unreadable and would warn in interactive and
# logout paths respectively. They are stock Debian skel files; nothing in
# this image or the driver reads them.
#
# This silences the symptom. The cause is HOME pointing into a Landlock-
# blocked directory, which is also why callers still need `export
# HOME=/sandbox` and why claude-tui.sh sets HOME=/tmp. Repointing the
# passwd home at /sandbox would address the cause, but whether the
# supervisor derives HOME from passwd or injects it independently is not
# verified here, so that is deliberately left alone.
RUN rm -f /home/sandbox/.profile /home/sandbox/.bashrc /home/sandbox/.bash_logout

# Drop back to the unprivileged sandbox user; the supervisor runs the
# agent as this UID via policy.process.run_as_user.
USER sandbox
WORKDIR /sandbox
