#!/usr/bin/env bash
#
# Detect upstream removing the managed inference router and `inference.local`.
#
# Why this exists: NVIDIA/OpenShell#3195 ("refactor(inference): remove managed
# inference routes", merged 2026-09-09) deletes `inference.local` and the
# `openshell-router` crate, replacing them with per-sandbox provider profiles.
# It is NOT in any release yet -- v0.0.116 was tagged 2026-08-28 -- but it will
# be.
#
# This driver injects `ANTHROPIC_BASE_URL=https://inference.local` into every
# sandbox and relies on the supervisor's L7 proxy to swap in the real
# credential. When that release lands, the host stops resolving.
#
# Nothing else would warn. check-proto-drift.sh compares the ComputeDriver
# contract and check-pin-status.sh compares image digests; this is an
# ARCHITECTURAL change behind an UNCHANGED wire contract, so it arrives looking
# like a routine image bump and surfaces as a confusing red smoke. This turns it
# into a named, expected event.
#
# Advisory in the sense that it never errors, but it DOES set the sync verdict
# so a PR gets opened -- an unnoticed architecture change is the failure mode.
#
# Emits `KEY: value` lines, same convention as its sibling checks:
#
#   INFERENCE_LOCAL_PRESENT: true    upstream still ships it; nothing to do
#   INFERENCE_LOCAL_REMOVED: true    the migration has landed upstream
#   INFERENCE_LOCAL_CHECK: unknown   could not determine (network, or the
#                                    sentinel path moved) -- verify by hand

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

cd "${SCRIPT_DIR}/.."

REF="${1:-}"
if [[ -z $REF ]]; then
	REF=$(latest_upstream_tag 2>/dev/null || true)
fi
if [[ -z $REF ]]; then
	printf 'Could not resolve an upstream ref to check.\n'
	printf 'INFERENCE_LOCAL_CHECK: unknown\n'
	exit 0
fi

# Sentinel: the file #3195 deletes. Checked for existence AND content, so a
# file that survives but no longer mentions the host still counts as removed.
# A relocation upstream would read as removed too -- the hints below say to
# confirm rather than assume, which is the right failure direction.
SENTINEL="crates/openshell-core/src/inference.rs"
URL="https://raw.githubusercontent.com/NVIDIA/OpenShell/${REF}/${SENTINEL}"

# `|| rc=$?` rather than a bare assignment: proto-lib.sh sets `set -e`, so a
# failing curl would abort the script before $? is ever read -- the REMOVED
# branch would never run, which is the only branch that matters.
rc=0
body=$(curl -fsSL --max-time 25 "$URL" 2>/dev/null) || rc=$?

printf 'Checking %s for the managed inference router...\n' "$REF"

if [[ $rc -ne 0 ]]; then
	# 404 is the expected signal; any other failure is indistinguishable here,
	# so treat a reachable-but-missing file as removed and an unreachable
	# network as unknown.
	# No `-f` here: with it curl exits non-zero on a 404 while ALSO writing the
	# code, so a `|| echo 000` fallback concatenates into "404000".
	code=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 25 "$URL" 2>/dev/null)
	code=${code:-000}
	if [[ $code == "404" ]]; then
		removed=1
	else
		printf 'Could not fetch %s (HTTP %s).\n' "$SENTINEL" "$code"
		printf 'INFERENCE_LOCAL_CHECK: unknown\n'
		exit 0
	fi
elif ! grep -q "inference\.local" <<<"$body"; then
	removed=1
else
	removed=0
fi

if [[ $removed -eq 0 ]]; then
	printf 'Still present. No action needed.\n'
	printf 'INFERENCE_LOCAL_PRESENT: true\n'
	exit 0
fi

cat <<'HINTS'
UPSTREAM REMOVED `inference.local` AND THE MANAGED INFERENCE ROUTER.

This is an architecture change, not a version bump. The credential-swap
property is PRESERVED upstream -- a provider profile injects a placeholder
and the proxy substitutes the real key at the profile endpoint -- but the
path to it changed.

What breaks here:
  - provisioner.rs injects ANTHROPIC_BASE_URL=https://inference.local into
    every sandbox. That host no longer resolves.
  - AGENT_FACING_INJECTED_ENV carries ANTHROPIC_BASE_URL / OPENAI_BASE_URL
    into exec sessions; both lose their meaning at the same time.
  - chart `inferenceProvider.*` configures a workspace-global route. The
    replacement is a provider profile plus per-sandbox attachment.

Where to look:
  - NVIDIA/OpenShell#3195 (the removal) and #3172 (the rationale)
  - examples/local-inference/README.md upstream, for the new workflow
  - `openshell provider create --type <profile>` then
    `openshell sandbox create --provider <name>`

Confirm before acting: this check keys off one sentinel file, so an upstream
RELOCATION would look identical to a removal.
HINTS
printf 'INFERENCE_LOCAL_REMOVED: true\n'
exit 0
