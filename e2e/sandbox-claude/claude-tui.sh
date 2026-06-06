#!/bin/sh
# Convenience wrapper installed as /usr/local/bin/claude in
# openshell-driver-kyma sandboxes (with /usr/local/bin/claude-tui kept
# as a symlink for backcompat). On default Ubuntu PATH, /usr/local/bin
# precedes /usr/bin, so typing `claude` resolves to this wrapper; the
# final exec dials /usr/bin/claude (the real npm-installed binary) by
# full path to avoid recursion.
#
# The OpenShell sandbox supervisor's L7 router strips inbound client auth
# at the inference.local boundary and substitutes the operator's bundle
# key. So the placeholder primaryApiKey baked into ~/.claude.json only
# needs to be format-valid — claude reads it to skip the onboarding
# screen, never sends it upstream.
#
# Why this exists:
# 1. /home/sandbox is read-only per filesystem_policy. claude wants to
#    write ~/.claude.json on first run for onboarding state. Without
#    HOME=/tmp, claude silently exits.
# 2. The supervisor injects ANTHROPIC_API_KEY=openshell:resolve:env:...
#    (a runtime resolver placeholder). claude treats this as a
#    "console-key" which conflicts with the file's primaryApiKey.
#    Unsetting ANTHROPIC_API_KEY here lets the file's primaryApiKey win
#    so the TUI starts clean. The L7 router still substitutes the real
#    upstream key — the auth path doesn't depend on what claude sends.
# 3. ANTHROPIC_BASE_URL is supervisor-injected to https://inference.local
#    in the sandbox CR's spec.env, but defensive default here keeps the
#    wrapper functional under unusual configurations.
set -eu

# The supervisor injects HOME=/home/sandbox but filesystem_policy makes
# that read-only, so claude can't write its onboarding state. Force /tmp
# unconditionally — ${HOME:-/tmp} only fires if HOME is unset, which it
# never is under the supervisor.
export HOME=/tmp
mkdir -p "$HOME"

unset ANTHROPIC_API_KEY

[ -f "$HOME/.claude.json" ] || cp /etc/openshell/skel/claude.json "$HOME/.claude.json"

export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://inference.local}"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-1}"

exec /usr/bin/claude "$@"
