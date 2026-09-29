#!/usr/bin/env bash
#
# Resolve the upstream references the weekly upstream-sync needs, and print
# them as KEY=VALUE lines suitable for `>> "$GITHUB_ENV"`: its detect job
# compares the chart's pins against them, and its sync job moves the pins to
# them. The smokes do not use them; they install the chart's own pins.
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
	tag=$(latest_upstream_tag) || die "could not reach upstream to resolve 'latest'"
	[[ -n $tag ]] || die "could not reach upstream to resolve 'latest'"
else
	tag=$GATEWAY_REF
fi

[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "resolved gateway tag looks wrong: '$tag'"

# Container tags upstream publishes have no leading `v`.
image_tag=${tag#v}

gateway_image=$(resolve_image_digest ghcr.io/nvidia/openshell/gateway "$image_tag") \
	|| die "failed to resolve the gateway image digest for ${image_tag}"
[[ -n $gateway_image ]] || die "gateway image digest resolved empty for ${image_tag}"

supervisor_image=$(resolve_image_digest ghcr.io/nvidia/openshell/supervisor "$image_tag") \
	|| die "failed to resolve the supervisor image digest for ${image_tag}"
[[ -n $supervisor_image ]] || die "supervisor image digest resolved empty for ${image_tag}"

sandbox_runtime_image=$(resolve_image_digest ghcr.io/nvidia/openshell/sandbox "$image_tag") \
	|| die "failed to resolve the sandbox runtime image digest for ${image_tag}"
[[ -n $sandbox_runtime_image ]] || die "sandbox runtime image digest resolved empty for ${image_tag}"

# Kept as PINNED_PROTO_REF for the workflows that read it; it is now the
# upstream tag the driver links (Cargo.toml), since protos are no longer vendored.
pinned_proto_ref=$(pinned_upstream_tag) || die "failed to read the pinned upstream tag from Cargo.toml"
[[ -n $pinned_proto_ref ]] || die "pinned proto ref resolved empty"

printf 'GATEWAY_TAG=%s\n' "$tag"
printf 'GATEWAY_IMAGE=%s\n' "$gateway_image"
printf 'SUPERVISOR_IMAGE=%s\n' "$supervisor_image"
printf 'SANDBOX_RUNTIME_IMAGE=%s\n' "$sandbox_runtime_image"
printf 'PINNED_PROTO_REF=%s\n' "$pinned_proto_ref"
