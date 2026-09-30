#!/usr/bin/env bash
#
# Fail when the chart does not pin the images upstream published for its
# upstream.version.
#
# The chart ships one upstream release: values.yaml's upstream.version (which
# check-chart-render.sh holds equal to the Cargo.toml pin) names it, the
# provider hook runs its CLI, and the gateway, supervisor and sandbox runtime
# images are pinned by digest. The smokes install exactly those pins, so a pin
# that is not that release's would ship, and be tested as, a mixed set. This
# resolves each image's tag for upstream.version (container tags have no
# leading `v`) to a digest on ghcr.io and compares:
#   gateway.image.repository + gateway.image.tag   ghcr.io/nvidia/openshell/gateway
#   driver.supervisorImage                         ghcr.io/nvidia/openshell/supervisor
#   driver.sandboxRuntimeImage                     ghcr.io/nvidia/openshell/sandbox
#
# Exit 0 when all three match, 1 on a mismatch (each printed with the digest
# upstream publishes), 2 when the check could not run (values unreadable, or a
# digest that could not be resolved). check-image-pins.sh is the advisory
# sibling that compares the pins against upstream's latest release instead.
# VALUES_YAML points at another values file (for tests).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

VALUES=${VALUES_YAML:-$(git rev-parse --show-toplevel)/deploy/helm/openshell-driver-kyma/values.yaml}
version=$(chart_upstream_version "$VALUES") \
	|| { echo "error: could not read upstream.version from ${VALUES}" >&2; exit 2; }
image_tag=${version#v}

# name, values key, the reference values.yaml pins, and the repository upstream
# publishes it at, one image per line.
pins=$(python3 - "$VALUES" <<'PY'
import sys, yaml
values = yaml.safe_load(open(sys.argv[1])) or {}
gateway, driver = values.get("gateway", {}).get("image", {}), values.get("driver", {})
tag = str(gateway.get("tag") or "")
gateway_ref = f"{gateway.get('repository')}{'@' if tag.startswith('sha256:') else ':'}{tag}"
for name, key, ref, repo in (
        ("gateway", "gateway.image", gateway_ref, "ghcr.io/nvidia/openshell/gateway"),
        ("supervisor", "driver.supervisorImage", driver.get("supervisorImage"), "ghcr.io/nvidia/openshell/supervisor"),
        ("sandbox runtime", "driver.sandboxRuntimeImage", driver.get("sandboxRuntimeImage"),
         "ghcr.io/nvidia/openshell/sandbox")):
    print(f"{name}\t{key}\t{ref}\t{repo}")
PY
) || { echo "error: could not read the image pins from ${VALUES}" >&2; exit 2; }

mismatch=0
while IFS=$'\t' read -r name key pinned repo; do
	if ! published=$(resolve_image_digest "$repo" "$image_tag"); then
		echo "error: could not resolve ${repo}:${image_tag} to a digest; the ${name} pin was not checked" >&2
		exit 2
	fi
	if [[ $pinned == "$published" ]]; then
		echo "ok        ${name}: ${published}"
	else
		echo "MISMATCH  ${name}: ${key} pins ${pinned}, upstream ${version} publishes ${published}"
		mismatch=1
	fi
done <<<"$pins"

if (( mismatch )); then
	echo "IMAGE_PIN_MISMATCH: re-pin the images above to upstream ${version}'s digests, or move upstream.version with them."
	exit 1
fi
echo "IMAGE_PINS_MATCH: gateway, supervisor and sandbox runtime are upstream ${version}'s"
