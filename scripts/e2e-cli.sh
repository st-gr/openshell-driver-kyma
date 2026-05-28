#!/usr/bin/env bash
# e2e-cli.sh — exercise the deployed gateway sidecar through the upstream
# openshell CLI. Runs inside the dev container; assumes:
#   - INTEGRATION_TEST_NAMESPACE is set and the chart is deployed there
#     with gateway.enabled=true and gatewayService.enabled=true.
#   - /root/.kube/config is the static kubeconfig produced by
#     scripts/render-static-kubeconfig.js (already mounted by the
#     `make e2e-cli` recipe).
#
# Scope: this is a *structural* e2e — it asserts what the driver is
# responsible for and stops there.
#
#   PASS criteria:
#     + chart deploys, both containers Ready
#     + 'openshell status' via direct gateway-endpoint returns success
#     + Sandbox CR is created via the CLI
#     + Sandbox pod reaches phase=Running (controller observed +
#       supervisor-init copy-self ran + agent container started)
#     + supervisor calls IssueSandboxToken on the gateway
#       (proves CLI -> gateway -> driver -> CR -> pod -> supervisor ->
#        gateway is fully wired)
#
#   NOT tested:
#     - Sandbox reaches phase=Ready (requires gateway-internal sandbox-JWT
#       auth: signing-key Secret + TokenReview RBAC + ConfigMap, all
#       outside the driver's responsibility)
#     - 'openshell sandbox exec' (depends on sandbox-Ready)
#
# No Anthropic API key, no provider creds, no AI model calls — the test
# uses docker.io/library/ubuntu:24.04 + `sleep infinity` so it runs
# anywhere with network access.

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

# 6. Create a sandbox via the CLI. The CLI itself blocks waiting for
#    Ready and will time out (~300s) in this configuration because the
#    gateway's sandbox-JWT auth isn't wired (deliberate scope cut). We
#    spawn it in the background and assert on the K8s surface directly,
#    since that's what the driver is actually responsible for.
SB_NAME="e2e-$(date +%s)"
log "creating sandbox '$SB_NAME' via CLI (background; CLI will time out, ignored)..."
osh sandbox create --name "$SB_NAME" \
  --from docker.io/library/ubuntu:24.04 \
  -- sleep infinity \
  >/tmp/create.log 2>&1 &
CREATE_PID=$!
trap 'kill "$PF_PID" "$CREATE_PID" 2>/dev/null || true' EXIT

# 7. Wait for the Sandbox CR's pod to reach Running. Everything up to
#    this point is the driver + chart's responsibility:
#      driver builds CR -> agent-sandbox controller observes -> pod
#      scheduled -> supervisor-init runs copy-self -> agent container
#      starts -> phase: Running.
log "waiting up to ${TIMEOUT_READY}s for sandbox pod to reach Running..."
deadline=$(( $(date +%s) + TIMEOUT_READY ))
running=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  phase=$(kubectl -n "$NS" get pod "$SB_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$phase" = "Running" ]; then running=1; break; fi
  sleep 3
done
[ "$running" = 1 ] || {
  log "Sandbox CR + Pod state:"
  kubectl -n "$NS" get sandbox "$SB_NAME" -o yaml 2>&1 | tail -30 >&2 || true
  kubectl -n "$NS" describe pod "$SB_NAME" 2>&1 | tail -20 >&2 || true
  die "sandbox pod did not reach Running"
}
log "pod is Running"

# 8. Verify the supervisor reaches the gateway. The supervisor calls
#    IssueSandboxToken on the gateway as its first action; that call
#    appears in the gateway logs even though it returns Status::unavailable
#    until JWT signing is configured. Seeing the request proves the
#    supervisor sideload ran, the binary started, OPENSHELL_ENDPOINT was
#    correctly injected, and the in-cluster Service VIP resolves end to end.
DRIVER_POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=openshell-driver-kyma \
              -o jsonpath='{.items[0].metadata.name}')
log "checking gateway logs for IssueSandboxToken call..."
seen=0
deadline=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if kubectl -n "$NS" logs "$DRIVER_POD" -c gateway --since=2m 2>/dev/null \
       | grep -q 'IssueSandboxToken'; then
    seen=1; break
  fi
  sleep 2
done
[ "$seen" = 1 ] || die "gateway never saw an IssueSandboxToken call from the supervisor"
log "gateway received IssueSandboxToken (chain proven through to supervisor)"

# 9. Cleanup. Trap kills port-forward + the background CLI.
log "cleaning up sandbox '$SB_NAME'..."
kubectl -n "$NS" delete sandbox "$SB_NAME" --wait=false >/dev/null 2>&1 || true
log "DONE: structural chain (CLI -> gateway -> driver -> CR -> pod -> supervisor -> gateway) is operational"
log "Note: sandbox-Ready and CLI-exec require gateway sandbox-JWT setup; not tested here."
