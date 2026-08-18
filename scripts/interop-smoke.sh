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
# Strip the conversion webhook BEFORE applying.
#
# Upstream ships the CRD with `conversion.strategy: Webhook` pointing at
# `agent-sandbox-webhook-service` in `agent-sandbox-system` — part of the
# full agent-sandbox controller install, which we deliberately do NOT deploy.
# Without that service the API server rejects every Sandbox create with a
# 500 "conversion webhook ... service not found", before the driver is even
# involved.
#
# Installing the whole controller to satisfy it would add a large moving part
# for no coverage: this smoke stops at "CR created" on purpose and never needs
# the controller to reconcile a pod. Removing the block entirely makes the API
# server default to strategy None and store the submitted version as-is.
#
# Deleting the whole `spec.conversion` key rather than patching
# `strategy: None` onto the applied CRD: that patch leaves `webhook` behind,
# and the API server rejects it with "should not be set when strategy is not
# set to Webhook". Verified `del(.spec.conversion)` leaves both served
# versions (v1beta1, v1alpha1) intact.
curl -fsSL "$CRD_URL" | yq 'del(.spec.conversion)' | kubectl apply -f - \
	|| fail "could not install the agent-sandbox CRD"

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
	--set gateway.sandboxJwt.enabled=true \
	--set driver.supervisorImage="$SUPERVISOR_IMAGE" \
	--wait --timeout 5m \
	|| fail "helm install failed"
# gateway.sandboxJwt.enabled=true is required: templates/gateway-config.yaml
# is gated `if gateway.enabled AND gateway.sandboxJwt.enabled`, and that
# ConfigMap is the only place `allow_unauthenticated_users = true` is set.
# Without it the gateway container gets no --config at all and rejects every
# gRPC call from the CLI with Unauthenticated.

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
# Poll for the forwarded port instead of a fixed sleep. e2e-cli.sh uses the
# same /dev/tcp probe; a fixed sleep is exactly the kind of flake-prone guess
# that made ASSERT 1 unreliable before.
for i in $(seq 1 20); do
	if (echo > /dev/tcp/127.0.0.1/8080) >/dev/null 2>&1; then
		log "port-forward is up"
		break
	fi
	sleep 0.5
	[[ $i == 20 ]] && fail "port-forward never became ready (see /tmp/pf.log)"
done

# The CLI's endpoint env var is OPENSHELL_GATEWAY_ENDPOINT (see
# docs/install-cli.md) -- OPENSHELL_ENDPOINT is a different variable
# entirely, the one the DRIVER injects into sandbox pods. Pass
# --gateway-endpoint explicitly on every call instead of relying on env,
# matching e2e-cli.sh's osh() helper: it also keeps the test stateless (no
# $HOME/.config/openshell registration to leak between CI runs).
osh() { openshell --gateway-endpoint "http://127.0.0.1:8080" "$@"; }

# --- Assertion 1: the gateway is up and serving --------------------------
#
# `openshell status` reports the endpoint and the gateway version. It does
# NOT name the compute driver: its `Gateway:` field is the CLI's endpoint
# (or a locally-registered profile name), which is why asserting on "kyma"
# here failed on the first real CI run while passing on a workstation that
# happened to have a profile called "kyma" saved. Driver acceptance is
# asserted separately, in ASSERT 1b, against the gateway's own log.
log "ASSERT 1: openshell status reports Connected"
status_out=$(osh status 2>&1) || fail "openshell status failed:
${status_out}"
printf '%s\n' "$status_out"
grep -qi "Connected" <<<"$status_out" || fail "gateway did not report Connected"

# --- Assertion 1b: the gateway accepted THIS driver ----------------------
#
# Proves the gateway completed GetCapabilities and accepted the driver's
# advertised identity.
#
# What it does NOT prove, verified by a deliberate-break test rather than by
# reading: the gateway logs this line BEFORE calling
# GetGatewayListenerRequirements (openshell-server/src/compute/mod.rs:608 vs
# :617). Breaking that RPC still produces this line.
#
# That contract break is caught earlier instead — a non-Unimplemented error
# there aborts driver initialisation, the gateway container exits, and
# `helm install --wait` above fails with "failed to create compute runtime".
# So the helm step is the real gate for the listener-requirements contract;
# this assertion covers capabilities and identity.
log "ASSERT 1b: the gateway logged 'Compute driver connected' for kyma"
gw_logs_raw=$(kubectl -n "$NS" logs "deploy/${RELEASE}-openshell-driver-kyma" -c gateway --tail=500 2>&1) \
	|| fail "could not read gateway logs:
${gw_logs_raw}"

# The gateway emits ANSI colour codes even without a TTY, and they land
# BETWEEN the field name, the `=`, and the value — a literal
# `advertised_driver=kyma` never matches. Strip them before asserting, which
# also makes the failure output readable.
gw_logs=$(sed $'s/\033\\[[0-9;]*m//g' <<<"$gw_logs_raw")

grep -q "Compute driver connected" <<<"$gw_logs" || fail "gateway never accepted the compute driver:
${gw_logs}"
grep -qE "advertised_driver=kyma|driver\.name=kyma" <<<"$gw_logs" \
	|| fail "gateway connected a driver, but not one advertising itself as kyma:
${gw_logs}"

# --- Assertion 2: the driver creates a well-formed CR --------------------
#
# `openshell sandbox create` blocks and does not return even once the sandbox
# is Ready, so run it backgrounded and poll kubectl. A naive run-and-wait
# hangs until the job timeout.
log "ASSERT 2: sandbox CR is created with the expected name and labels"
osh sandbox create --name "$SB" --from ghcr.io/nvidia/openshell-community/sandboxes/base:latest \
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
list_out=$(osh sandbox list 2>&1) || fail "openshell sandbox list failed:
${list_out}"
printf '%s\n' "$list_out"
grep -q "$SB" <<<"$list_out" || fail "gateway did not list ${SB} by its bare name"

# --- Assertion 3b: stop and start actually work ------------------------
#
# Unit tests cover the patch payload in isolation. This assertion adds the
# end-to-end path a unit test cannot: the gateway -> driver RPC, the
# label-based CR lookup, and the patch reaching a real API server. This is
# the assertion that would have caught 'stop returns Unimplemented'.
#
# This smoke deliberately runs no agent-sandbox controller (see the CRD
# install step above: "this smoke stops at 'CR created' on purpose and
# never needs the controller to reconcile a pod"), so no Pod is ever
# created here. Asserting on the Sandbox CR's own spec.replicas -- the
# exact field the driver patches (see lifecycle.rs::operating_state_patch)
# -- instead of on a Pod, still covers the gateway -> driver RPC, the
# label-based CR lookup, and the operating-state patch reaching the API
# server. It does NOT exercise provisioner.rs::await_pod_gone's
# termination poll: that only ever runs where a controller has created a
# Pod to wait for. That poll is covered only against a real cluster, not
# by this smoke -- do not read a pass here as proof it works.
#
# Requires CLI >= 0.0.106: `openshell sandbox stop`/`start` do not exist
# before that. CLI_VERSION tracks GATEWAY_REF (see
# scripts/resolve-upstream-refs.sh), so if a maintainer pins GATEWAY_REF to
# <= 0.0.105 in .github/upstream-compat.env during an upstream-breakage
# window, this assertion will fail with "unrecognized subcommand" rather
# than the failure it is meant to catch.
log "ASSERT 3b: stop -> spec.replicas=0 -> start -> spec.replicas=1"

osh sandbox stop "$SB" || fail "openshell sandbox stop failed"

stopped=0
for _ in $(seq 1 40); do
	replicas=$(kubectl -n "$NS" get sandbox "$cr" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
	[[ $replicas == 0 ]] && { stopped=1; break; }
	sleep 3
done
[[ $stopped == 1 ]] || fail "sandbox $cr spec.replicas never reached 0 after stop (last seen: '${replicas:-}')"

osh sandbox start "$SB" || fail "openshell sandbox start failed"

started=0
for _ in $(seq 1 40); do
	replicas=$(kubectl -n "$NS" get sandbox "$cr" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
	[[ $replicas == 1 ]] && { started=1; break; }
	sleep 3
done
[[ $started == 1 ]] || fail "sandbox $cr spec.replicas never reached 1 after start (last seen: '${replicas:-}')"

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
		|| fail "could not read ${c} logs: ${c_logs}"
	grep -E '"level":"ERROR"|[[:space:]]ERROR[[:space:]]' <<<"$c_logs" \
		&& fail "${c} logged an ERROR"
	true
done

log "INTEROP SMOKE PASSED (gateway ${GATEWAY_IMAGE##*@})"
