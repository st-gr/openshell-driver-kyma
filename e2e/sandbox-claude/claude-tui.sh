#!/bin/sh
# Convenience wrapper installed as /usr/local/bin/claude in
# openshell-driver-kyma sandboxes (with /usr/local/bin/claude-tui kept
# as a symlink for backcompat). On default Ubuntu PATH, /usr/local/bin
# precedes /usr/bin, so typing `claude` resolves to this wrapper; the
# final exec dials /usr/bin/claude (the real npm-installed binary) by
# full path to avoid recursion.
#
# Under upstream OpenShell v0.1.2's provider model the supervisor sets
# ANTHROPIC_API_KEY to a resolver placeholder (openshell:resolve:env:...)
# and ANTHROPIC_BASE_URL to the provider endpoint; the supervisor's proxy
# substitutes the real key ONLY when the client sends that placeholder.
# So this wrapper must leave both variables alone (an earlier version
# unset the key for the retired inference.local router, which now yields
# "Not logged in"). Verified on the v0.9.0 live check: `claude -p` with
# the placeholder kept and the ~/.claude.json skeleton present answers.
#
# Why this exists:
# 1. /home/sandbox is read-only per filesystem_policy. claude wants to
#    write ~/.claude.json on first run for onboarding state. Without
#    HOME=/tmp, claude silently exits.
# 2. The ~/.claude.json skeleton skips the onboarding screen for the TUI.
set -eu

# The supervisor injects HOME=/home/sandbox but filesystem_policy makes
# that read-only, so claude can't write its onboarding state. Force /tmp
# unconditionally — ${HOME:-/tmp} only fires if HOME is unset, which it
# never is under the supervisor.
export HOME=/tmp
mkdir -p "$HOME"

[ -f "$HOME/.claude.json" ] || cp /etc/openshell/skel/claude.json "$HOME/.claude.json"

export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-1}"

exec /usr/bin/claude "$@"
