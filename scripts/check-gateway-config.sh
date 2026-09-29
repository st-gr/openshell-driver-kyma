#!/usr/bin/env bash
# Render the chart's gateway TOML and prove the gateway image the chart
# deploys accepts it. Config parsing happens before anything else in the
# binary, so a schema error is distinguishable from the unrelated runtime
# failures that follow when the image runs outside Kubernetes (characteristically
# "failed to create /.local/state/openshell/gateway: Permission denied", which
# means the config WAS accepted).
#
# The image under test is read from the rendered Deployment, so it is always
# the (digest-pinned) image the chart really ships. Override for ad-hoc runs
# with GATEWAY_IMAGE=...
#
# Docker Desktop on macOS does not share /tmp or $TMPDIR: a bind mount from
# there silently arrives as an empty DIRECTORY and the gateway reports "is not
# a regular file (directory)", which looks like a config error but is not. The
# work dir is therefore staged under $HOME, which works locally and in CI.
set -euo pipefail

CHART="deploy/helm/openshell-driver-kyma"
mkdir -p "$HOME/.cache"
WORK="$(mktemp -d "$HOME/.cache/check-gateway-config.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

render() {
  helm template check "$CHART" \
    --set gateway.enabled=true \
    --set gateway.sandboxJwt.enabled=true \
    --show-only "$1"
}

render templates/gateway-config.yaml > "$WORK/rendered.yaml"
render templates/deployment.yaml > "$WORK/deployment.yaml"

python3 - "$WORK/rendered.yaml" "$WORK/gateway.toml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
open(sys.argv[2], "w").write(doc["data"]["gateway.toml"])
PY

IMAGE="${GATEWAY_IMAGE:-$(python3 - "$WORK/deployment.yaml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for c in doc["spec"]["template"]["spec"]["containers"]:
    if c["name"] == "gateway":
        print(c["image"])
        break
else:
    sys.exit("no gateway container in rendered Deployment")
PY
)}"
echo "--- gateway image: $IMAGE ---"

echo "--- rendered gateway.toml ---"
cat "$WORK/gateway.toml"

out="$(docker run --rm -v "$WORK/gateway.toml:/etc/openshell/gateway.toml:ro" \
  --entrypoint openshell-gateway "$IMAGE" \
  --config /etc/openshell/gateway.toml --compute-driver kyma \
  --compute-driver-socket /run/openshell/driver.sock 2>&1 || true)"

if grep -qiE "failed to parse gateway config|unsupported gateway config version|unknown field" <<<"$out"; then
  echo "GATEWAY_CONFIG_REJECTED"
  head -20 <<<"$out"
  exit 1
fi

echo "--- gateway output (config accepted; any failure below is runtime) ---"
head -20 <<<"$out"
echo "GATEWAY_CONFIG_ACCEPTED"
