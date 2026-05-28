#!/usr/bin/env bash
# e2e-cli.sh — exercise the deployed gateway sidecar through the upstream
# openshell CLI. Runs inside the dev container; assumes:
#   - INTEGRATION_TEST_NAMESPACE is set and the chart is deployed there
#     with gateway.enabled=true and gatewayService.enabled=true.
#   - /root/.kube/config is the static kubeconfig produced by
#     scripts/render-static-kubeconfig.js (already mounted by the
#     `make e2e-cli` recipe).
#
# This is the first end-to-end test that exercises the full chain:
#     openshell CLI -> port-forward -> gateway pod -> driver pod (UDS) ->
#     Sandbox CR -> agent-sandbox controller -> running pod.
#
# Self-contained: no Anthropic API key, no provider creds. The sandbox
# runs `sleep infinity`; we assert it reaches Ready and exec a trivial
# echo command. That's enough to prove the chain is wired up correctly.

set -euo pipefail

NS="${INTEGRATION_TEST_NAMESPACE:?must be set}"
SVC="${E2E_SVC_NAME:-ods-openshell-driver-kyma}"
PORT="${E2E_PORT:-8080}"
TIMEOUT_READY="${E2E_READY_TIMEOUT:-180}"
LOG_PREFIX='[e2e-cli]'

log() { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# 1. Sanity: refuse to operate on a system namespace, mirroring live_cluster.rs.
case "$NS" in
  default|kube-system|kube-public|kube-node-lease|istio-system|kyma-system|agent-sandbox-system)
    die "refusing to run e2e in '$NS' (deny-listed)"
    ;;
esac

# 2. Ensure the deployment has both containers (driver + gateway) Ready.
log "waiting for Deployment/$SVC to roll out..."
kubectl -n "$NS" rollout status "deployment/$SVC" --timeout=120s

POD=$(kubectl -n "$NS" get pod -l "app.kubernetes.io/name=openshell-driver-kyma" \
        -o jsonpath='{.items[0].metadata.name}')
[ -n "$POD" ] || die "no driver pod found in $NS"
log "pod: $POD"

# Both containers must report Ready=true.
kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[*].ready}' \
  | grep -qw 'true true' \
  || die "driver and gateway containers are not both Ready"

# 3. Install the openshell CLI as a flat musl-static binary. PyPI wheels
#    are tagged manylinux_2_39 and require glibc >= 2.39, which Bookworm
#    (the dev image base) does not have. The musl tarball is glibc-free.
OS_VER="${OPENSHELL_CLI_VERSION:-v0.0.50}"
OS_BIN="/workspace/.tmp/openshell-${OS_VER}"
if [ ! -x "$OS_BIN" ]; then
  log "downloading openshell CLI ${OS_VER} (musl-static)..."
  mkdir -p /workspace/.tmp
  url="https://github.com/NVIDIA/OpenShell/releases/download/${OS_VER}/openshell-x86_64-unknown-linux-musl.tar.gz"
  curl -fsSL "$url" | tar -xz -C /tmp \
    || die "failed to download openshell CLI from $url"
  mv /tmp/openshell "$OS_BIN" \
    || die "tarball layout did not contain openshell binary at expected path"
  chmod +x "$OS_BIN"
fi
osh() { "$OS_BIN" --gateway-endpoint "http://127.0.0.1:$PORT" "$@"; }
"$OS_BIN" --version | grep -q '^openshell ' || die "openshell CLI did not run"

# 4. Port-forward the gateway gRPC port. Backgrounded; killed in cleanup.
log "starting kubectl port-forward $PORT:$PORT..."
kubectl -n "$NS" port-forward "svc/$SVC" "$PORT:$PORT" >/tmp/pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
# Wait until the local port answers.
for i in $(seq 1 20); do
  if (echo > /dev/tcp/127.0.0.1/"$PORT") >/dev/null 2>&1; then
    log "port-forward is up"
    break
  fi
  sleep 0.5
  [ "$i" = 20 ] && die "port-forward never became ready (see /tmp/pf.log)"
done

# 5. Smoke: gateway answers the basic status RPC. We use --gateway-endpoint
#    on every call instead of registering ('gateway add'); this avoids
#    persisting state in $HOME/.config/openshell between runs and keeps
#    the test stateless.
log "calling 'openshell status' via direct gateway-endpoint..."
osh status >/tmp/status.txt 2>&1 || {
  log "openshell status output:"
  cat /tmp/status.txt >&2
  die "gateway is reachable but 'openshell status' failed"
}
log "gateway responded: $(head -1 /tmp/status.txt)"

# 6. Create a sandbox running 'sleep infinity'. The supervisor image is
#    a small one from upstream; no provider creds needed for a bare
#    command (the agent-sandbox controller materializes a generic pod).
SB_NAME="e2e-$(date +%s)"
log "creating sandbox '$SB_NAME'..."
osh sandbox create --name "$SB_NAME" \
  --from docker.io/library/ubuntu:24.04 \
  -- sleep infinity \
  >/tmp/create.log 2>&1 \
  || { cat /tmp/create.log >&2; die "openshell sandbox create failed"; }

# 7. Wait until the sandbox reaches Ready. The CLI doesn't expose a
#    structured wait; we poll `sandbox get` and look at the human-readable
#    output, accepting either 'Ready' or 'phase: Ready'.
log "waiting up to ${TIMEOUT_READY}s for Ready..."
deadline=$(( $(date +%s) + TIMEOUT_READY ))
ready=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  out=$(osh sandbox get "$SB_NAME" 2>/dev/null || true)
  if printf '%s' "$out" | grep -qiE 'phase:.*ready|status:.*ready|^Ready$'; then
    ready=1; break
  fi
  sleep 5
done
[ "$ready" = 1 ] || {
  log "last 'sandbox get' output:"
  osh sandbox get "$SB_NAME" 2>&1 | head -30 >&2 || true
  log "Sandbox CR status:"
  kubectl -n "$NS" get sandbox "$SB_NAME" -o yaml 2>&1 | tail -30 >&2 || true
  die "sandbox did not reach Ready in ${TIMEOUT_READY}s"
}

# 8. Exec a trivial command end-to-end (CLI -> gateway -> sandbox).
log "exec ok-check..."
out=$(osh sandbox exec --name "$SB_NAME" --no-tty -- echo OK 2>&1 | tr -d '\r\n ')
[ "$out" = "OK" ] || die "exec returned unexpected output: '$out'"
log "exec returned OK"

# 9. Cleanup. Trap will kill the port-forward.
log "cleaning up sandbox '$SB_NAME'..."
osh sandbox delete "$SB_NAME" >/dev/null 2>&1 || true
log "DONE: full chain (CLI -> gateway -> driver -> CR -> pod) is operational"
