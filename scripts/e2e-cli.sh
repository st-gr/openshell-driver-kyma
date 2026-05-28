#!/usr/bin/env bash
# e2e-cli.sh - exercise the deployed gateway sidecar through the upstream
# openshell CLI. Runs inside the dev container; assumes:
#   - INTEGRATION_TEST_NAMESPACE is set and the chart is deployed there
#     with gateway.enabled=true, gatewayService.enabled=true, and
#     gateway.sandboxJwt.enabled=true.
#   - /root/.kube/config is the static kubeconfig produced by
#     scripts/render-static-kubeconfig.js (already mounted by the
#     `make e2e-cli` recipe).
#
# Scope: full end-to-end - chart, gateway, driver, supervisor, exec.
#
#   PASS criteria:
#     + chart deploys, both containers Ready
#     + 'openshell status' via --gateway-endpoint returns success
#     + Sandbox CR is created via the CLI
#     + Sandbox pod reaches Running AND containerStatuses[0].ready=true
#       (proves: controller observed -> supervisor copy-self -> agent
#        started -> supervisor IssueSandboxToken bootstrap succeeded ->
#        gateway minted sandbox JWT -> supervisor fetched policy ->
#        sandbox is healthy)
#     + 'openshell sandbox exec -- echo OK' returns "OK"
#       (proves the CLI control plane works through the same gateway,
#        across the full chain end to end)
#
# No Anthropic API key, no provider creds, no AI model calls. The test
# uses our own minimal sandbox image (built from e2e/sandbox/Dockerfile,
# has the `sandbox` user the supervisor requires) and runs `sleep
# infinity`.

set -euo pipefail

NS="${INTEGRATION_TEST_NAMESPACE:?must be set}"
SVC="${E2E_SVC_NAME:-ods-openshell-driver-kyma}"
PORT="${E2E_PORT:-8080}"
TIMEOUT_READY="${E2E_READY_TIMEOUT:-180}"
SB_IMAGE="${E2E_SANDBOX_IMAGE:-ghcr.io/st-gr/openshell-driver-kyma/e2e-sandbox:latest}"
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
  # The musl tarball is flat: just `openshell` at the root.
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
#    on every call instead of registering ('gateway add') to keep the
#    test stateless (no $HOME/.config/openshell residue between runs).
log "calling 'openshell status' via direct gateway-endpoint..."
osh status >/tmp/status.txt 2>&1 || {
  log "openshell status output:"
  cat /tmp/status.txt >&2
  die "gateway is reachable but 'openshell status' failed"
}
log "gateway responded: $(head -1 /tmp/status.txt)"

# 6. Create a sandbox via the CLI. The CLI blocks waiting for Ready;
#    spawn it in the background and poll the K8s + CLI surfaces in
#    parallel. The image must contain a `sandbox` user/group + iproute2
#    + nftables; vanilla ubuntu won't work. Default points at our own
#    minimal e2e image (e2e/sandbox/Dockerfile).
SB_NAME="e2e-$(date +%s)"
log "creating sandbox '$SB_NAME' from $SB_IMAGE..."
osh sandbox create --name "$SB_NAME" \
  --from "$SB_IMAGE" \
  -- sleep infinity \
  >/tmp/create.log 2>&1 &
CREATE_PID=$!
trap 'kill "$PF_PID" "$CREATE_PID" 2>/dev/null || true' EXIT

# 7. Wait until the sandbox pod is Running AND its container reports
#    Ready=true. Container readiness only flips true after the supervisor
#    successfully completes IssueSandboxToken, fetches its policy, and
#    enters the steady-state run loop.
log "waiting up to ${TIMEOUT_READY}s for sandbox pod Ready..."
deadline=$(( $(date +%s) + TIMEOUT_READY ))
ready=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  phase=$(kubectl -n "$NS" get pod "$SB_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  cready=$(kubectl -n "$NS" get pod "$SB_NAME" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
  if [ "$phase" = "Running" ] && [ "$cready" = "true" ]; then ready=1; break; fi
  sleep 3
done
[ "$ready" = 1 ] || {
  log "Sandbox CR + Pod state on failure:"
  kubectl -n "$NS" get sandbox "$SB_NAME" -o yaml 2>&1 | tail -30 >&2 || true
  kubectl -n "$NS" describe pod "$SB_NAME" 2>&1 | tail -25 >&2 || true
  log "Supervisor (agent) logs:"
  kubectl -n "$NS" logs "$SB_NAME" -c agent --tail=20 2>&1 >&2 || true
  die "sandbox pod did not reach Ready in ${TIMEOUT_READY}s"
}
log "pod is Ready (supervisor IssueSandboxToken bootstrap succeeded)"

# 8. CLI exec end-to-end. The CLI talks to the gateway over the same
#    port-forward, the gateway forwards to the driver UDS, the driver
#    proxies the exec stream into the supervisor inside the sandbox.
log "openshell sandbox exec -- echo OK..."
out=$(osh sandbox exec --name "$SB_NAME" --no-tty -- echo OK 2>/tmp/exec-err.log \
        | tr -d '\r\n[:space:]')
if [ "$out" != "OK" ]; then
  log "exec stderr:"
  cat /tmp/exec-err.log >&2 || true
  die "exec returned unexpected output: '$out'"
fi
log "exec returned: OK"

# 9. Cleanup. Trap kills port-forward + the background CLI.
log "cleaning up sandbox '$SB_NAME'..."
kubectl -n "$NS" delete sandbox "$SB_NAME" --wait=false >/dev/null 2>&1 || true
log "DONE: full end-to-end chain (CLI -> gateway -> driver -> CR -> pod -> supervisor -> CLI exec) is operational"
