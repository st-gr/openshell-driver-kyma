#!/usr/bin/env bash
#
# Resolve the upstream references the compatibility jobs need, and print them
# as KEY=VALUE lines suitable for `>> "$GITHUB_ENV"`.
#
# Reads GATEWAY_REF from .github/upstream-compat.env. `latest` means the
# newest upstream semver release tag — never the mutable `:latest` container
# tag. Everything is resolved to an immutable digest so a re-run of the same
# commit tests the same bytes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

cd "${SCRIPT_DIR}/.."

KNOB=.github/upstream-compat.env
[[ -f $KNOB ]] || die "$KNOB not found"

# shellcheck disable=SC1090
GATEWAY_REF=$(sed -n 's/^GATEWAY_REF=//p' "$KNOB" | tail -1 | tr -d '[:space:]')
[[ -n $GATEWAY_REF ]] || die "GATEWAY_REF is not set in $KNOB"

if [[ $GATEWAY_REF == latest ]]; then
	tag=$(latest_upstream_tag)
	[[ -n $tag ]] || die "could not reach upstream to resolve 'latest'"
else
	tag=$GATEWAY_REF
fi

[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "resolved gateway tag looks wrong: '$tag'"

# Container tags upstream publishes have no leading `v`.
image_tag=${tag#v}

printf 'GATEWAY_TAG=%s\n' "$tag"
printf 'GATEWAY_IMAGE=%s\n' "$(resolve_image_digest ghcr.io/nvidia/openshell/gateway "$image_tag")"
printf 'SUPERVISOR_IMAGE=%s\n' "$(resolve_image_digest ghcr.io/nvidia/openshell/supervisor "$image_tag")"
printf 'CLI_VERSION=%s\n' "$image_tag"
printf 'PINNED_PROTO_REF=%s\n' "$(lock_get ref)"
