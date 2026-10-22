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
    --show-only "$@"
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
# The PKI hook runs the same image's generate-certs: its rendered arguments must be known
# too, with remote access on (it then also writes the CA ConfigMap for the ingress gateway).
helm template check "$CHART" --set gateway.enabled=true --set gateway.sandboxJwt.enabled=true \
  --set gatewayService.enabled=true --set gatewayIngress.enabled=true --set gatewayIngress.domain=example.org \
  --set gateway.tls.enabled=true --set gateway.oidc.issuer=https://issuer.example \
  --set gateway.oidc.audience=osh-client --set gateway.oidc.clientId=osh-client \
  --show-only templates/gateway-jwt-pki-hook.yaml > "$WORK/pki-hook.yaml"
python3 - "$WORK/pki-hook.yaml" > "$WORK/pki-args.txt" <<'PY'
import sys, yaml
job = next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "Job")
print("\n".join(a.replace("$(POD_NAMESPACE)", "check") for a in job["spec"]["template"]["spec"]["containers"][0]["args"]))
PY
grep -q -- '--backend-ca-configmap-name=' "$WORK/pki-args.txt" \
  || { echo "ERROR: the PKI hook render has no --backend-ca-configmap-name; nothing to test" >&2; exit 1; }
pki_args=()
while IFS= read -r line; do pki_args+=("$line"); done < "$WORK/pki-args.txt"
rc=0
out="$(docker run --rm --entrypoint openshell-gateway "$IMAGE" "${pki_args[@]}" --help 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "GATEWAY_ARGS_REJECTED (pki-hook, exit $rc)"
  head -5 <<<"$out"
  exit 1
fi
echo "GATEWAY_ARGS_ACCEPTED (pki-hook, ${#pki_args[@]} args)"
check_args remote-access \
  --set gatewayIngress.enabled=true \
  --set gatewayIngress.domain=example.org \
  --set gatewayIngress.serviceHosts.enabled=true \
  --set-json 'gatewayIngress.allowedCidrs=["203.0.113.0/24"]' \
  --set gateway.oidc.issuer=https://issuer.example \
  --set gateway.oidc.audience=osh-client \
  --set gateway.oidc.clientId=osh-client \
  --set gateway.oidc.authOnly=true \
  --set gateway.tls.enabled=true
# Upstream v0.1.4's mTLS operators (`--enable-operator-auth`, OU=operator certificates)
# have no chart value, as in upstream's chart: they are reached through gateway.extraArgs,
# and need TLS and the client CA, so the pinned image must accept that command line.
check_args operator-auth \
  --set gateway.tls.enabled=true \
  --set gateway.tls.clientCa.enabled=true \
  --set-json 'gateway.extraArgs=["--enable-operator-auth=true"]'
check_args rbac-roles \
  --set gateway.oidc.issuer=https://issuer.example \
  --set gateway.oidc.audience=osh-client \
  --set gateway.oidc.rolesClaim=groups \
  --set gateway.oidc.adminRole=osh-admin \
  --set gateway.oidc.userRole=osh-user
check_args oidc-extras \
  --set gateway.oidc.issuer=https://issuer.example.org \
  --set gateway.oidc.audience=a \
  --set gateway.oidc.jwksTtl=600 \
  --set gateway.oidc.scopesClaim=scp \
  --set 'gateway.oidc.jwksAllowedOrigins={https://keys.example.org,https://k2.example.org}' \
  --set gateway.oidc.dangerouslyAllowInsecureHttp=true

# check_config LABEL TOML: run the gateway with that config. Config parsing happens before
# anything else, so a schema error is told apart from the runtime failure that follows
# outside Kubernetes. Prints GATEWAY_CONFIG_ACCEPTED (LABEL) or exits non-zero.
check_config() {
  local label=$1 toml=$2 rc=0 out
  out="$(docker run --rm -v "$toml:/etc/openshell/gateway.toml:ro" \
    --entrypoint openshell-gateway "$IMAGE" \
    --config /etc/openshell/gateway.toml --compute-driver kyma \
    --compute-driver-socket /run/openshell/driver.sock 2>&1)" || rc=$?

  # 125/126/127 are docker's own failures (daemon, exec, command not found),
  # not the gateway's exit status.
  if [ "$rc" -ge 125 ] && [ "$rc" -le 127 ]; then
    echo "ERROR: docker run failed at docker level (status $rc); the config ($label) was not tested" >&2
    head -20 <<<"$out" >&2
    exit 1
  fi

  if grep -qiE "failed to parse gateway config|unsupported gateway config version|unknown field|ocsf_log" <<<"$out"; then
    echo "GATEWAY_CONFIG_REJECTED ($label)"
    head -20 <<<"$out"
    exit 1
  fi

  # Positive evidence: the gateway got past config parsing and failed on
  # something unrelated to config (running outside Kubernetes).
  if grep -q "failed to create /.local/state/openshell/gateway" <<<"$out"; then
    echo "--- gateway output ($label: config accepted; failure below is runtime) ---"
    head -5 <<<"$out"
    echo "GATEWAY_CONFIG_ACCEPTED ($label)"
    return 0
  fi

  echo "ERROR: could not determine whether the config ($label) was accepted (exit $rc); output:" >&2
  head -40 <<<"$out" >&2
  exit 1
}
check_config defaults "$WORK/gateway.toml"

# The gRPC rate limit (gateway.grpcRateLimit).
render templates/gateway-config.yaml --set gateway.grpcRateLimit.requests=120 \
  --set gateway.grpcRateLimit.windowSeconds=60 > "$WORK/rendered-rate-limit.yaml"
python3 - "$WORK/rendered-rate-limit.yaml" "$WORK/gateway-rate-limit.toml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
open(sys.argv[2], "w").write(doc["data"]["gateway.toml"])
PY
grep -q '^ *grpc_rate_limit_requests = 120$' "$WORK/gateway-rate-limit.toml" \
  || { echo "ERROR: the rate-limit render has no grpc_rate_limit_requests; nothing to test" >&2; exit 1; }
check_config rate-limit "$WORK/gateway-rate-limit.toml"
# The gateway's OCSF audit log (gateway.ocsfLog), both rotation modes.
for variant in daily never; do
  render templates/gateway-config.yaml --set gateway.ocsfLog.enabled=true \
    --set "gateway.ocsfLog.rotation=$variant" --set gateway.ocsfLog.schemaVersion=1.3 > "$WORK/rendered-ocsf.yaml"
  python3 - "$WORK/rendered-ocsf.yaml" "$WORK/gateway-ocsf-$variant.toml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
open(sys.argv[2], "w").write(doc["data"]["gateway.toml"])
PY
  grep -q '^\[openshell.gateway.ocsf_log\]' "$WORK/gateway-ocsf-$variant.toml" \
    || { echo "ERROR: the OCSF render has no [openshell.gateway.ocsf_log] table; nothing to test" >&2; exit 1; }
  check_config "ocsf-$variant" "$WORK/gateway-ocsf-$variant.toml"
done
# gatewayConfig, upstream's TOML passthrough, merged into the chart's tables.
render templates/gateway-config.yaml -f scripts/testdata/parity-gateway-config.yaml \
  > "$WORK/rendered-gateway-config.yaml"
python3 - "$WORK/rendered-gateway-config.yaml" "$WORK/gateway-passthrough.toml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
open(sys.argv[2], "w").write(doc["data"]["gateway.toml"])
PY
grep -q '^ *image_preparation_timeout_seconds = 300$' "$WORK/gateway-passthrough.toml" \
  || { echo "ERROR: the gatewayConfig render has no image_preparation_timeout_seconds; nothing to test" >&2; exit 1; }
check_config gateway-config-passthrough "$WORK/gateway-passthrough.toml"
# The gateway's OTLP trace export (gateway.otlp).
render templates/gateway-config.yaml --set gateway.otlp.endpoint=http://otel.example.org:4318 \
  --set gateway.otlp.serviceName=osh-gw > "$WORK/rendered-otlp.yaml"
python3 - "$WORK/rendered-otlp.yaml" "$WORK/gateway-otlp.toml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
open(sys.argv[2], "w").write(doc["data"]["gateway.toml"])
PY
grep -q '^\[openshell.gateway.otlp\]' "$WORK/gateway-otlp.toml" \
  || { echo "ERROR: the OTLP render has no [openshell.gateway.otlp] table; nothing to test" >&2; exit 1; }
check_config otlp "$WORK/gateway-otlp.toml"
echo "GATEWAY_CONFIG_ACCEPTED"
