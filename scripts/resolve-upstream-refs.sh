#!/usr/bin/env bash
#
# Resolve the upstream references the weekly upstream-sync needs, and print
# them as KEY=VALUE lines suitable for `>> "$GITHUB_ENV"`: its detect job
# compares the chart's pins against them, and its sync job moves the pins to
# them. The smokes do not use them; they install the chart's own pins.
#
# Everything is resolved for ONE upstream release, the sync's target tag: the
# crates, the chart's upstream.version and the gateway, supervisor and sandbox
# runtime digests must be one release. The target is the release
# GATEWAY_REF (.github/upstream-compat.env) names -- `latest` is the newest
# upstream semver release tag, never the mutable `:latest` container tag -- but
# never older than the tag Cargo.toml pins (upstream_target_tag in
# proto-lib.sh, the same one check-upstream-pin.sh prints as VENDOR_TARGET_TAG).
# The sync job passes detect's VENDOR_TARGET_TAG as the optional first argument
# so both jobs resolve the very tag detect reported even if upstream has
# published since. Each image is resolved to an immutable digest so a re-run of
# the same commit tests the same bytes.
#
# Usage: resolve-upstream-refs.sh [vX.Y.Z]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

cd "${SCRIPT_DIR}/.."

# Read before the tag is decided: the target is never older than this.
pinned_proto_ref=$(pinned_upstream_tag) || die "failed to read the pinned upstream tag from Cargo.toml"
[[ -n $pinned_proto_ref ]] || die "pinned proto ref resolved empty"

if [[ -n ${1:-} ]]; then
	tag=$1
else
	tag=$(upstream_target_tag "$pinned_proto_ref")
fi

[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "resolved upstream target tag looks wrong: '$tag'"

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

# GATEWAY_TAG is the target tag itself (the name is kept for the workflows that
# read it), and every image below is that release's. PINNED_PROTO_REF is the
# upstream tag the driver links before the sync (Cargo.toml), since protos are
# no longer vendored.
printf 'GATEWAY_TAG=%s\n' "$tag"
printf 'GATEWAY_IMAGE=%s\n' "$gateway_image"
printf 'SUPERVISOR_IMAGE=%s\n' "$supervisor_image"
printf 'SANDBOX_RUNTIME_IMAGE=%s\n' "$sandbox_runtime_image"
printf 'PINNED_PROTO_REF=%s\n' "$pinned_proto_ref"
