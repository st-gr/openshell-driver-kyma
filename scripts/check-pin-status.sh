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
#   CLI_ENTRYPOINT_MISSING: true the newer tag's PyPI wheel ships no CLI
#                               binary, so the smokes cannot install one --
#                               the pin stays regardless of images
#   PIN_STILL_JUSTIFIED: true  a newer tag exists but its images do not yet
#   LATEST_UPSTREAM_TAG        the newest upstream tag, emitted whether or not
#                               a pin is in place -- so "what would we move to?"
#                               is answerable from the summary without a pin

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
	# Still report what upstream's newest tag is. Without it the summary can
	# say a pin is absent but not what version is actually being tracked,
	# which is the other half of the question a reader is asking.
	unpinned_latest=$(latest_upstream_tag 2>/dev/null || true)
	if [[ -n $unpinned_latest ]]; then
		printf 'Newest upstream tag: %s\n' "$unpinned_latest"
		printf 'LATEST_UPSTREAM_TAG: %s\n' "$unpinned_latest"
	fi
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

printf 'LATEST_UPSTREAM_TAG: %s\n' "$latest"

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

# Images are necessary but NOT sufficient. Both smokes also `uv tool install
# openshell==<tag>`, and from 0.0.113 upstream's PyPI wheel stopped shipping
# the CLI binary: it became a ~0.1 MB pure-Python library with no
# `.data/scripts/openshell` entry, so the install fails with "No executables
# are provided by package `openshell`". An images-only check reported the pin
# as no longer needed and would have unpinned CI straight into that failure.
#
# The wheel is ~8 MB when it does contain the binary, so this only runs at the
# one moment it decides something: after the images check has already passed
# and the script is about to declare the pin's reason evaporated.
cli_ships_entrypoint() {
	local version=$1 url tmp
	# Checks the RELEASE ASSET, not the PyPI wheel. The wheel will never carry
	# the binary again: NVIDIA/OpenShell#2321 removed it deliberately and added
	# a test asserting it cannot come back. Asking the wheel would hold a pin
	# forever on a question whose answer is permanently "no".
	local url="https://github.com/NVIDIA/OpenShell/releases/download/v${version}/openshell-x86_64-unknown-linux-musl.tar.gz"
	local code
	code=$(curl -fsSL -o /dev/null -w '%{http_code}' --max-time 30 -I "$url" 2>/dev/null) || return 2
	case $code in
	200) return 0 ;;
	404) return 1 ;;
	*) return 2 ;;
	esac
}

if [[ $gateway_state == published && $supervisor_state == published ]]; then
	# `|| cli_rc=$?` rather than a bare call: proto-lib.sh sets `set -e`, so a
	# bare invocation returning non-zero would abort this script -- which must
	# never happen, since it is advisory and the weekly job relies on it always
	# exiting 0.
	cli_rc=0
	cli_ships_entrypoint "$image_tag" || cli_rc=$?
	case $cli_rc in
	1)
		printf 'Images exist for %s, but it publishes no Linux CLI tarball\n' "$latest"
		printf '(openshell-x86_64-unknown-linux-musl.tar.gz missing), so the smokes could not\n'
		printf 'install a CLI at all and both\n'
		printf 'smokes would die at CLI install. The pin stays.\n'
		printf 'CLI_ENTRYPOINT_MISSING: true\n'
		printf 'PIN_STILL_JUSTIFIED: true\n'
		exit 0
		;;
	2)
		printf 'Could not check whether %s ships a CLI binary; not declaring the\n' "$latest"
		printf 'pin evaporated on images alone.\n'
		printf 'PIN_CHECK: network-unreachable\n'
		exit 0
		;;
	*) ;;
	esac
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
