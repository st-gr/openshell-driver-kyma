#!/usr/bin/env bash
#
# Advisory report on the image and version pins this repo carries.
#
# Why this exists: every pin here is deliberate -- a moving tag once handed
# every new sandbox an unreviewed privileged supervisor binary, which is why
# the supervisor is a digest. But a pin that nothing ever re-examines stops
# being a decision and becomes an accident: the version it froze recedes,
# and nobody can say whether that is still intentional. check-pin-status.sh
# does exactly this job for the GATEWAY_REF knob in upstream-compat.env;
# this is its sibling for the pins that live in the chart and the sandbox
# image, which that script does not look at.
#
# Run it before cutting a release -- release-tag.yml does, and prints the
# result into the run summary -- so "are we still current?" is answered at
# the moment the answer matters, not months later.
#
# Advisory only. It must NEVER fail a release: exit status is always 0,
# even when the network is unreachable or a pin is stale. A stale pin is a
# nag for a human, not a broken build.
#
# Emits `KEY: value` lines a workflow step can pick out, the same
# convention check-pin-status.sh and check-proto-drift.sh use:
#
#   SANDBOX_BASE_STATUS    current | stale | unknown
#   CLAUDE_CODE_STATUS     current | stale | unknown
#   SUPERVISOR_STATUS      current | stale | unknown
#   GATEWAY_TAG_STATUS     current | stale | unknown
#   PINS_STALE: true       at least one pin is behind
#   PINS_UNCHECKED: true   at least one pin could not be checked

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

cd "${SCRIPT_DIR}/.."

DOCKERFILE=e2e/sandbox-claude/Dockerfile
VALUES=deploy/helm/openshell-driver-kyma/values.yaml

stale=0
unchecked=0

report() {
	local label=$1 key=$2 state=$3 detail=$4
	printf '%-16s %-8s %s\n' "$label" "$state" "$detail"
	printf '%s: %s\n' "$key" "$state"
	case $state in
	stale) stale=1 ;;
	unknown) unchecked=1 ;;
	esac
}

printf 'Pin status (advisory -- never fails the build)\n\n'

# --- sandbox-claude base image -------------------------------------------
pinned_base=$(sed -n 's|^FROM ghcr.io/st-gr/e2e-sandbox@||p' "$DOCKERFILE" | tail -1)
if [[ -z $pinned_base ]]; then
	report "sandbox base" SANDBOX_BASE_STATUS unknown "no digest pin found in ${DOCKERFILE}"
elif live=$( (resolve_image_digest ghcr.io/st-gr/e2e-sandbox latest) 2>/dev/null ); then
	live_digest=${live#*@}
	if [[ $live_digest == "$pinned_base" ]]; then
		report "sandbox base" SANDBOX_BASE_STATUS current "${pinned_base:0:19}..."
	else
		report "sandbox base" SANDBOX_BASE_STATUS stale "pinned ${pinned_base:0:19}... but :latest is ${live_digest:0:19}..."
	fi
else
	report "sandbox base" SANDBOX_BASE_STATUS unknown "could not resolve ghcr.io/st-gr/e2e-sandbox:latest (private or offline)"
fi

# --- claude-code version --------------------------------------------------
pinned_cc=$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' "$DOCKERFILE" | tail -1 | tr -d '[:space:]')
if [[ -z $pinned_cc ]]; then
	report "claude-code" CLAUDE_CODE_STATUS unknown "no ARG CLAUDE_CODE_VERSION in ${DOCKERFILE}"
elif live_cc=$(curl -fsSL --max-time 20 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null |
	sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1) && [[ -n $live_cc ]]; then
	if [[ $pinned_cc == "$live_cc" ]]; then
		report "claude-code" CLAUDE_CODE_STATUS current "$pinned_cc"
	else
		report "claude-code" CLAUDE_CODE_STATUS stale "pinned ${pinned_cc}, npm latest is ${live_cc}"
	fi
else
	report "claude-code" CLAUDE_CODE_STATUS unknown "could not reach the npm registry"
fi

# --- gateway + supervisor digests ----------------------------------------
#
# Both are pinned by digest, not by tag: gateway.image.tag holds a
# `sha256:...` value that the chart helper expands to `<repo>@sha256:...`,
# and supervisorImage carries the digest inline. So "is this pin current?"
# cannot be answered by comparing version strings -- it means: does the
# pinned digest still equal the digest upstream publishes for its newest
# release? They are deliberately version-matched to each other, so both are
# checked against the same tag and reported separately.
latest_tag=$(latest_upstream_tag 2>/dev/null || true)
latest_image_tag=${latest_tag#v}

check_digest_pin() {
	local label=$1 key=$2 repo=$3 pinned=$4 live live_digest

	if [[ -z $pinned ]]; then
		report "$label" "$key" unknown "no digest pin found in ${VALUES}"
		return
	fi
	if [[ -z $latest_image_tag ]]; then
		report "$label" "$key" unknown "could not reach upstream for the newest tag"
		return
	fi
	if ! live=$( (resolve_image_digest "$repo" "$latest_image_tag") 2>/dev/null ); then
		report "$label" "$key" unknown "upstream ${latest_tag} exists but ${repo##*/}:${latest_image_tag} does not resolve (not published yet)"
		return
	fi

	live_digest=${live#*@}
	if [[ $live_digest == "$pinned" ]]; then
		report "$label" "$key" current "on upstream ${latest_tag}"
	else
		report "$label" "$key" stale "upstream ${latest_tag} publishes ${live_digest:0:19}..., pinned is ${pinned:0:19}..."
	fi
}

gateway_pinned=$(sed -n 's/^[[:space:]]*tag:[[:space:]]*"\{0,1\}sha256:\([0-9a-f]\{64\}\)"\{0,1\}[[:space:]]*$/sha256:\1/p' "$VALUES" | tail -1)
check_digest_pin "gateway" GATEWAY_TAG_STATUS ghcr.io/nvidia/openshell/gateway "$gateway_pinned"

supervisor_pinned=$(sed -n 's|^[[:space:]]*supervisorImage:[[:space:]]*ghcr.io/nvidia/openshell/supervisor@||p' "$VALUES" | tail -1 | tr -d '[:space:]')
check_digest_pin "supervisor" SUPERVISOR_STATUS ghcr.io/nvidia/openshell/supervisor "$supervisor_pinned"

echo
if (( stale )); then
	printf 'At least one pin is behind. Bumping is a deliberate, reviewable commit --\n'
	printf 'see the re-resolve instructions beside each pin.\n'
	printf 'PINS_STALE: true\n'
else
	printf 'All checked pins are current.\n'
fi
(( unchecked )) && printf 'PINS_UNCHECKED: true\n'

exit 0
