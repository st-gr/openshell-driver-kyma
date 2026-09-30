#!/usr/bin/env bash
# Report where the driver's upstream pin stands, for CI and the weekly sync.
#
# The driver links upstream NVIDIA/OpenShell's Kubernetes driver at the tag
# pinned in the workspace Cargo.toml. Prints:
#   PINNED_UPSTREAM_TAG: <tag>   the tag Cargo.toml pins
#   LATEST_UPSTREAM_TAG: <tag>   the newest upstream release tag
#   VENDOR_TARGET_TAG: <tag>     the ONE release a sync moves the crates, the
#                                chart's upstream.version and its three image
#                                digests to (upstream_target_tag in proto-lib.sh):
#                                GATEWAY_REF's release, the newest release for
#                                `latest`, never older than the pin
#   ADVISORY: ...                only when the pin is behind the LATEST release.
#                                Informational: a knob pinned to an older
#                                release holds the target back on purpose, so
#                                the weekly detect job decides whether a sync
#                                has work by comparing the target with the pin,
#                                not from this line
# then runs check-upstream-args.sh at the PINNED tag. Being behind is advisory
# (exit 0); a mirrored option surface that no longer matches the pinned tag is
# corruption and exits 1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

pinned=$(pinned_upstream_tag) || die "could not read the pinned upstream tag from Cargo.toml"
latest=$(latest_upstream_tag) || true
[[ -n $latest ]] || die "could not reach upstream to resolve its latest release tag"

# The one release a sync moves everything to; never older than the pin.
target=$(upstream_target_tag "$pinned" "$latest")

echo "PINNED_UPSTREAM_TAG: ${pinned}"
echo "LATEST_UPSTREAM_TAG: ${latest}"
echo "VENDOR_TARGET_TAG: ${target}"
if [[ $(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -1) != "$pinned" ]]; then
	echo "ADVISORY: pinned upstream ${pinned} is behind the latest release ${latest}"
fi

"${SCRIPT_DIR}/check-upstream-args.sh"
