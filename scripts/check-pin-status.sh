#!/usr/bin/env bash
#
# Advisory report on the GATEWAY_REF pin in .github/upstream-compat.env.
#
# Why this exists: GATEWAY_REF may legitimately be pinned to an older
# upstream tag when upstream itself is broken (see that file's own
# comment). But while pinned, resolve-upstream-refs.sh resolves ONLY the
# pinned ref -- it never compares against what upstream has since done.
# That means the weekly detect job's IMAGES_STALE check ends up comparing
# the pinned digests against themselves and stays green forever, so a pin
# whose reason has evaporated can sit unnoticed for months. This script is
# the missing signal: it says whether the pin still holds, without being
# the thing that enforces it.
#
# Advisory only. It must NEVER fail CI -- exit status is always 0, even
# when the network is unreachable or the pin looks stale. A stale pin is
# a nag for a human, not a build failure; check-proto-drift.sh is the
# actual gate, this is only its sibling in output shape.
#
# Emits `KEY: value` lines a workflow step can pick out with e.g.
# `sed -n 's/^PIN_REASON_EVAPORATED: //p'`, the same convention
# check-proto-drift.sh uses for its VENDOR_TARGET_TAG line. Keys used:
#
#   PIN_STATUS               unpinned | pinned | unknown
#   PINNED_REF                the pinned tag, when pinned
#   PIN_REASON                 the recorded PIN_REASON text, when non-empty
#   PIN_REASON_MISSING: true   pinned but PIN_REASON is empty
#   PIN_REVIEW_AFTER            the recorded review date, when set
#   PIN_REVIEW_OVERDUE: true    today is past PIN_REVIEW_AFTER
#   PIN_CHECK                  network-unreachable | up-to-date (terminal;
#                               nothing further was checked)
#   PIN_REASON_EVAPORATED: true both images now exist for a newer tag --
#                               the pin should be reverted to latest
#   VENDOR_TARGET_TAG          the newer tag, alongside PIN_REASON_EVAPORATED
#   PIN_STILL_JUSTIFIED: true  a newer tag exists but its images do not yet

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

cd "${SCRIPT_DIR}/.."

KNOB=.github/upstream-compat.env

if [[ ! -f $KNOB ]]; then
	printf 'error: %s not found\n' "$KNOB" >&2
	printf 'PIN_STATUS: unknown\n'
	exit 0
fi

GATEWAY_REF=$(sed -n 's/^GATEWAY_REF=//p' "$KNOB" | tail -1 | tr -d '[:space:]')
PIN_REASON=$(sed -n 's/^PIN_REASON=//p' "$KNOB" | tail -1)
PIN_REVIEW_AFTER=$(sed -n 's/^PIN_REVIEW_AFTER=//p' "$KNOB" | tail -1 | tr -d '[:space:]')

if [[ -z $GATEWAY_REF || $GATEWAY_REF == latest ]]; then
	printf 'Not pinned: GATEWAY_REF=latest. Nothing to review.\n'
	printf 'PIN_STATUS: unpinned\n'
	exit 0
fi

printf 'Pinned: GATEWAY_REF=%s\n' "$GATEWAY_REF"
printf 'PIN_STATUS: pinned\n'
printf 'PINNED_REF: %s\n' "$GATEWAY_REF"

if [[ -n $PIN_REASON ]]; then
	printf 'Reason: %s\n' "$PIN_REASON"
	printf 'PIN_REASON: %s\n' "$PIN_REASON"
else
	printf 'No PIN_REASON recorded. A pin with no recorded reason is how it becomes\n'
	printf 'permanent by accident -- fill this in in the same commit that sets the pin.\n'
	printf 'PIN_REASON_MISSING: true\n'
fi

if [[ -n $PIN_REVIEW_AFTER ]]; then
	printf 'Review after: %s\n' "$PIN_REVIEW_AFTER"
	printf 'PIN_REVIEW_AFTER: %s\n' "$PIN_REVIEW_AFTER"
	today=$(date +%Y-%m-%d)
	if [[ $today > $PIN_REVIEW_AFTER ]]; then
		printf 'Review date has passed (today is %s) -- worth a look, not an emergency.\n' "$today"
		printf 'PIN_REVIEW_OVERDUE: true\n'
	fi
else
	printf 'No PIN_REVIEW_AFTER recorded.\n'
fi

echo

latest=$(latest_upstream_tag || true)
if [[ -z $latest ]]; then
	printf 'Could not reach upstream to check whether the pin is still justified.\n'
	printf 'PIN_CHECK: network-unreachable\n'
	exit 0
fi

if [[ $latest == "$GATEWAY_REF" ]]; then
	printf 'Pin already matches the latest known upstream tag; nothing further to check.\n'
	printf 'PIN_CHECK: up-to-date\n'
	exit 0
fi

newest=$(printf '%s\n%s\n' "$GATEWAY_REF" "$latest" | sort -V | tail -1)
if [[ $newest != "$latest" ]]; then
	printf 'Pin (%s) is at or ahead of the latest upstream tag (%s); nothing further to check.\n' \
		"$GATEWAY_REF" "$latest"
	printf 'PIN_CHECK: up-to-date\n'
	exit 0
fi

printf 'Upstream has moved to %s. Checking whether its images are published yet...\n' "$latest"
image_tag=${latest#v}

# Each resolve_image_digest call runs inside an explicit subshell so its
# die() on a missing image (expected -- that is the "not published yet"
# case, not an error) only ends the subshell, never this script.
gateway_state=missing
if ( resolve_image_digest ghcr.io/nvidia/openshell/gateway "$image_tag" >/dev/null 2>&1 ); then
	gateway_state=published
fi

supervisor_state=missing
if ( resolve_image_digest ghcr.io/nvidia/openshell/supervisor "$image_tag" >/dev/null 2>&1 ); then
	supervisor_state=published
fi

if [[ $gateway_state == published && $supervisor_state == published ]]; then
	printf 'Both gateway and supervisor images now exist for %s.\n' "$latest"
	printf 'The pin was waiting on this -- revert GATEWAY_REF to latest.\n'
	printf 'PIN_REASON_EVAPORATED: true\n'
	printf 'VENDOR_TARGET_TAG: %s\n' "$latest"
else
	printf 'Upstream tagged %s, but its images are not published yet (gateway: %s, supervisor: %s).\n' \
		"$latest" "$gateway_state" "$supervisor_state"
	printf 'The pin is still justified.\n'
	printf 'PIN_STILL_JUSTIFIED: true\n'
fi

exit 0
