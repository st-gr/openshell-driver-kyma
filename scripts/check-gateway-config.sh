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
#
# Requires: helm, docker, python3 with PyYAML (preinstalled on ubuntu-latest).
#
# Outcome rule: acceptance needs POSITIVE evidence. Anything unrecognised
# (docker failure, pull failure, unexpected output) fails; it is never read as
# success.
set -euo pipefail

CHART="deploy/helm/openshell-driver-kyma"
mkdir -p "$HOME/.cache"
WORK="$(mktemp -d "$HOME/.cache/check-gateway-config.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

render() {
  helm template check "$CHART" \
    --set gateway.enabled=true \
    --set gateway.sandboxJwt.enabled=true \
    --set gatewayService.enabled=true \
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

if [ ! -s "$WORK/gateway.toml" ] || ! grep -q '^version' "$WORK/gateway.toml"; then
  echo "ERROR: rendered gateway.toml is empty or has no top-level version; nothing to test" >&2
  exit 1
fi

echo "--- rendered gateway.toml ---"
cat "$WORK/gateway.toml"

if ! docker pull "$IMAGE" >/dev/null; then
  echo "ERROR: could not pull $IMAGE; the config was not tested" >&2
  exit 1
fi

# The gateway's command line, as the chart renders it. Flags are parsed before the
# config is read and `--help` stops the gateway right after parsing, so appending it
# proves the pinned image knows every flag the chart passes: with the defaults, and
# with remote access on, the render that passes the most.
check_args() { # label [helm args...]
  local label=$1 rc=0 out line args=()
  shift
  helm template check "$CHART" \
    --set gateway.enabled=true \
    --set gateway.sandboxJwt.enabled=true \
    --set gatewayService.enabled=true \
    "$@" --show-only templates/deployment.yaml > "$WORK/args-deployment.yaml"
  python3 - "$WORK/args-deployment.yaml" > "$WORK/args.txt" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for c in doc["spec"]["template"]["spec"]["containers"]:
    if c["name"] == "gateway":
        print("\n".join(c["args"]))
        break
else:
    sys.exit("no gateway container in rendered Deployment")
PY
  while IFS= read -r line; do args+=("$line"); done < "$WORK/args.txt"
  out="$(docker run --rm --entrypoint openshell-gateway "$IMAGE" "${args[@]}" --help 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "GATEWAY_ARGS_REJECTED ($label, exit $rc)"
    head -5 <<<"$out"
    exit 1
  fi
  echo "GATEWAY_ARGS_ACCEPTED ($label, ${#args[@]} args)"
}
check_args defaults
check_args remote-access \
  --set gatewayIngress.enabled=true \
  --set gatewayIngress.domain=example.org \
  --set gatewayIngress.serviceHosts.enabled=true \
  --set-json 'gatewayIngress.allowedCidrs=["203.0.113.0/24"]' \
  --set gateway.oidc.issuer=https://issuer.example \
  --set gateway.oidc.audience=osh-client \
  --set gateway.oidc.clientId=osh-client \
  --set gateway.oidc.authOnly=true
check_args rbac-roles \
  --set gateway.oidc.issuer=https://issuer.example \
  --set gateway.oidc.audience=osh-client \
  --set gateway.oidc.rolesClaim=groups \
  --set gateway.oidc.adminRole=osh-admin \
  --set gateway.oidc.userRole=osh-user

rc=0
out="$(docker run --rm -v "$WORK/gateway.toml:/etc/openshell/gateway.toml:ro" \
  --entrypoint openshell-gateway "$IMAGE" \
  --config /etc/openshell/gateway.toml --compute-driver kyma \
  --compute-driver-socket /run/openshell/driver.sock 2>&1)" || rc=$?

# 125/126/127 are docker's own failures (daemon, exec, command not found),
# not the gateway's exit status.
if [ "$rc" -ge 125 ] && [ "$rc" -le 127 ]; then
  echo "ERROR: docker run failed at docker level (status $rc); the config was not tested" >&2
  head -20 <<<"$out" >&2
  exit 1
fi

if grep -qiE "failed to parse gateway config|unsupported gateway config version|unknown field" <<<"$out"; then
  echo "GATEWAY_CONFIG_REJECTED"
  head -20 <<<"$out"
  exit 1
fi

# Positive evidence: the gateway got past config parsing and failed on
# something unrelated to config (running outside Kubernetes).
if grep -q "failed to create /.local/state/openshell/gateway" <<<"$out"; then
  echo "--- gateway output (config accepted; failure below is runtime) ---"
  head -20 <<<"$out"
  echo "GATEWAY_CONFIG_ACCEPTED"
  exit 0
fi

echo "ERROR: could not determine whether the config was accepted (exit $rc); output:" >&2
head -40 <<<"$out" >&2
exit 1
