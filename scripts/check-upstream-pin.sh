#!/usr/bin/env bash
# Report where the driver's upstream pin stands, for CI and the weekly sync.
#
# The driver links upstream NVIDIA/OpenShell's Kubernetes driver at the tag
# pinned in the workspace Cargo.toml. Prints:
#   PINNED_UPSTREAM_TAG: <tag>   the tag Cargo.toml pins
#   LATEST_UPSTREAM_TAG: <tag>   the newest upstream release tag
#   VENDOR_TARGET_TAG: <tag>     the tag a sync should move to (never older than the pin)
#   ADVISORY: ...                only when the pin is behind the latest release
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

# The newer of the two by version sort: a sync must never move the pin backwards.
newest=$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -1)

echo "PINNED_UPSTREAM_TAG: ${pinned}"
echo "LATEST_UPSTREAM_TAG: ${latest}"
echo "VENDOR_TARGET_TAG: ${newest}"
if [[ $newest != "$pinned" ]]; then
	echo "ADVISORY: pinned upstream ${pinned} is behind the latest release ${latest}"
fi

"${SCRIPT_DIR}/check-upstream-args.sh"
