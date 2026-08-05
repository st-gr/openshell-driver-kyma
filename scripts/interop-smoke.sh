#!/usr/bin/env bash
#
# Prove a real upstream gateway accepts this driver.
#
# A proto diff cannot establish that. Syncing the pin proves the driver
# COMPILES against latest protos; it does not prove a latest gateway ACCEPTS
# it. This script closes that gap by installing the real Helm chart against a
# real gateway image and exercising the handshake.
#
# Assumes: a working kubectl context (a throwaway kind cluster), helm, and uv.
# Required env: GATEWAY_IMAGE, SUPERVISOR_IMAGE, CLI_VERSION, DRIVER_IMAGE
#
# Deliberately stops at "Sandbox CR created", NOT "pod Ready". Reaching Ready
# needs the supervisor running privileged with SYS_ADMIN and netns setup
# inside kind-in-Docker; that is the fragile part, and a weekly job that cries
# wolf gets ignored.

set -euo pipefail

NS=openshell-system
RELEASE=ods
SB=smoke-$$
CRD_URL="https://raw.githubusercontent.com/kubernetes-sigs/agent-sandbox/main/k8s/crds/agents.x-k8s.io_sandboxes.yaml"

log()  { printf '\n=== %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; dump_diagnostics; exit 1; }

dump_diagnostics() {
	printf '\n--- pods ---\n' >&2
	kubectl -n "$NS" get pods -o wide 2>&1 | head -20 >&2 || true
	printf '\n--- driver log ---\n' >&2
	kubectl -n "$NS" logs "deploy/${RELEASE}-openshell-driver-kyma" -c driver --tail=50 2>&1 >&2 || true
	printf '\n--- gateway log ---\n' >&2
	kubectl -n "$NS" logs "deploy/${RELEASE}-openshell-driver-kyma" -c gateway --tail=50 2>&1 >&2 || true
}

for v in GATEWAY_IMAGE SUPERVISOR_IMAGE CLI_VERSION DRIVER_IMAGE; do
	[[ -n ${!v:-} ]] || { echo "error: $v is required" >&2; exit 1; }
done

log "installing the agent-sandbox CRD"
# The chart's pre-install-crd-check Job aborts the install without this.
kubectl apply -f "$CRD_URL"

log "creating namespace with PSA privileged"
# The driver refuses to start without this label; it is a real precondition,
# not test scaffolding.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=privileged --overwrite

log "installing the chart (gateway ${GATEWAY_IMAGE##*@})"
# Install the REAL chart rather than hand-assembling gateway args: no second
# copy of the configuration to drift from deployment.yaml, and it is the path
# a third party would actually take — which is what we are safeguarding.
helm install "$RELEASE" deploy/helm/openshell-driver-kyma \
	--namespace "$NS" \
	--set image.repository="${DRIVER_IMAGE%%:*}" \
	--set image.tag="${DRIVER_IMAGE##*:}" \
	--set image.pullPolicy=Never \
	--set gateway.enabled=true \
	--set gateway.image.repository="${GATEWAY_IMAGE%%@*}" \
	--set gateway.image.tag="${GATEWAY_IMAGE##*@}" \
	--set gatewayService.enabled=true \
	--set driver.supervisorImage="$SUPERVISOR_IMAGE" \
	--wait --timeout 5m

log "waiting for the driver+gateway pod"
kubectl -n "$NS" rollout status "deploy/${RELEASE}-openshell-driver-kyma" --timeout=3m \
	|| fail "driver/gateway deployment never became available"

log "installing the openshell CLI ${CLI_VERSION}"
uv tool install "openshell==${CLI_VERSION}" --force
export PATH="$HOME/.local/bin:$PATH"

log "port-forwarding the gateway"
kubectl -n "$NS" port-forward "svc/${RELEASE}-openshell-driver-kyma" 8080:8080 >/tmp/pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 8
export OPENSHELL_ENDPOINT=http://127.0.0.1:8080

# --- Assertion 1: the gateway accepted the driver ------------------------
#
# Load-bearing. Reaching Connected proves the gateway completed
# GetCapabilities AND got a tolerable answer to
# GetGatewayListenerRequirements — a non-Unimplemented error there aborts
# driver initialisation outright. A broken contract cannot produce Connected.
log "ASSERT 1: openshell status reports Connected"
status_out=$(openshell status 2>&1) || fail "openshell status failed:\n${status_out}"
printf '%s\n' "$status_out"
grep -qi "Connected" <<<"$status_out" || fail "gateway did not report Connected"
grep -qi "kyma"      <<<"$status_out" || fail "gateway did not report the kyma driver"

# --- Assertion 2: the driver creates a well-formed CR --------------------
#
# `openshell sandbox create` blocks and does not return even once the sandbox
# is Ready, so run it backgrounded and poll kubectl. A naive run-and-wait
# hangs until the job timeout.
log "ASSERT 2: sandbox CR is created with the expected name and labels"
openshell sandbox create --name "$SB" --from ghcr.io/nvidia/openshell-community/sandboxes/base:latest \
	-- sleep infinity >/tmp/create.log 2>&1 &
CREATE_PID=$!
cr=""
for _ in $(seq 1 40); do
	cr=$(kubectl -n "$NS" get sandbox -l "openshell.ai/sandbox-name=${SB}" \
		-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
	[[ -n $cr ]] && break
	sleep 3
done
kill "$CREATE_PID" 2>/dev/null || true
[[ -n $cr ]] || { cat /tmp/create.log >&2; fail "no Sandbox CR appeared for ${SB}"; }

[[ $cr == "default--${SB}" ]] || fail "CR name is '${cr}', expected 'default--${SB}'"

labels=$(kubectl -n "$NS" get sandbox "$cr" -o jsonpath='{.metadata.labels}')
for key in \
	openshell.ai/sandbox-id \
	openshell.ai/sandbox-name \
	openshell.ai/sandbox-namespace \
	openshell.ai/sandbox-workspace \
	openshell.ai/managed-by \
	kagenti.io/type
do
	grep -q "$key" <<<"$labels" || fail "CR ${cr} is missing label ${key}: ${labels}"
done

# --- Assertion 3: the gateway resolves what the driver created -----------
log "ASSERT 3: openshell sandbox list round-trips the bare name"
list_out=$(openshell sandbox list 2>&1) || fail "openshell sandbox list failed:\n${list_out}"
printf '%s\n' "$list_out"
grep -q "$SB" <<<"$list_out" || fail "gateway did not list ${SB} by its bare name"

# --- Assertion 4: nothing errored ----------------------------------------
#
# Capture the logs into a variable and check kubectl's own exit status
# before grepping. Piping `kubectl logs` straight into `grep` inside an
# `if` masks a kubectl failure (container name mismatch, evicted pod,
# crash-restart with no previous logs): grep would just see empty input,
# return 1, and the branch would be skipped — reporting "no ERRORs" without
# ever having read a log line. "Could not check" must fail, not pass.
log "ASSERT 4: no ERROR in driver or gateway logs"
for c in driver gateway; do
	c_logs=$(kubectl -n "$NS" logs "deploy/${RELEASE}-openshell-driver-kyma" -c "$c" --tail=500 2>&1) \
		|| fail "could not read ${c} logs:\n${c_logs}"
	grep -E '"level":"ERROR"|[[:space:]]ERROR[[:space:]]' <<<"$c_logs" \
		&& fail "${c} logged an ERROR"
	true
done

log "INTEROP SMOKE PASSED (gateway ${GATEWAY_IMAGE##*@})"
