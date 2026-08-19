#!/usr/bin/env bash
#
# Prove the managed-mode namespace-per-workspace lifecycle against a real API
# server, not just the unit-tested stub.
#
# Unit tests cover `bootstrap_managed_namespace` and `delete_managed_namespace`
# in isolation with a fake API server. What they cannot cover is the thing
# that matters most: does the real gRPC path -- gateway -> driver ->
# kube-apiserver -- actually create the namespace it claims to, and does the
# ownership guardrail actually decline a real DeleteWorkspace call for a
# namespace it does not own? A wrong answer to either question means either a
# tenant never gets a working namespace, or DeleteWorkspace destroys someone
# else's. This script closes that gap.
#
# Modeled on scripts/interop-smoke.sh: same log/fail helpers, same kind
# cluster assumptions, same CRD conversion-webhook strip, same osh() CLI
# wrapper. Installs `--workspace-mode=managed`, where interop-smoke.sh
# exercises the default `shared` mode instead.
#
# Assumes: a working kubectl context (a throwaway kind cluster), helm, and uv.
# Required env: GATEWAY_IMAGE, SUPERVISOR_IMAGE, CLI_VERSION, DRIVER_IMAGE
#
# Like interop-smoke.sh, this installs only the agent-sandbox CRD, never the
# controller -- it stops at "CR created" on purpose. No Pod is ever created,
# so no assertion here waits for one.

set -euo pipefail

NS=openshell-system
RELEASE=oms
GATEWAY_ID=smoke
NS_DEFAULT="openshell-${GATEWAY_ID}-default"
NS_DECOY="openshell-${GATEWAY_ID}-decoy"
CRD_URL="https://raw.githubusercontent.com/kubernetes-sigs/agent-sandbox/main/k8s/crds/agents.x-k8s.io_sandboxes.yaml"

log()  { printf '\n=== %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; dump_diagnostics; exit 1; }

dump_diagnostics() {
	printf '\n--- pods (%s) ---\n' "$NS" >&2
	kubectl -n "$NS" get pods -o wide 2>&1 | head -20 >&2 || true
	printf '\n--- driver log ---\n' >&2
	kubectl -n "$NS" logs "deploy/${RELEASE}-openshell-driver-kyma" -c driver --tail=50 2>&1 >&2 || true
	printf '\n--- gateway log ---\n' >&2
	kubectl -n "$NS" logs "deploy/${RELEASE}-openshell-driver-kyma" -c gateway --tail=50 2>&1 >&2 || true
	printf '\n--- managed namespaces ---\n' >&2
	kubectl get ns "$NS_DEFAULT" "$NS_DECOY" -o wide 2>&1 >&2 || true
}

for v in GATEWAY_IMAGE SUPERVISOR_IMAGE CLI_VERSION DRIVER_IMAGE; do
	[[ -n ${!v:-} ]] || { echo "error: $v is required" >&2; exit 1; }
done

log "installing the agent-sandbox CRD"
# Same rationale as interop-smoke.sh: upstream ships the CRD with
# conversion.strategy: Webhook pointing at a service that only exists as
# part of the full agent-sandbox controller install, which this smoke
# deliberately does not deploy. Strip spec.conversion entirely so the API
# server defaults to strategy None instead of rejecting every Sandbox
# create with "conversion webhook ... service not found".
curl -fsSL "$CRD_URL" | yq 'del(.spec.conversion)' | kubectl apply -f - \
	|| fail "could not install the agent-sandbox CRD"

log "creating the driver/gateway namespace"
# Unlike interop-smoke.sh's shared-mode namespace, this one does NOT need
# the PSA privileged label: main.rs only runs the startup PSA pre-flight
# check under WorkspaceMode::Shared (cfg.namespace is the one static
# namespace shared mode uses). Under Managed there is no single namespace
# to check at startup -- PSA is verified per-workspace instead, as part of
# ASSERT M1 below.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

log "installing the chart in managed mode (gateway ${GATEWAY_IMAGE##*@})"
# The chart refuses workspaceMode=managed together with the default
# enableNetworkPolicy=true (main.rs's managed_network_policy_gap guard) --
# managed-namespace NetworkPolicy support does not exist yet. This is a
# deliberate gap, not something to work around.
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
	--set driver.workspaceMode=managed \
	--set driver.gatewayId="$GATEWAY_ID" \
	--set driver.enableNetworkPolicy=false \
	--wait --timeout 5m \
	|| fail "helm install failed"

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
for i in $(seq 1 20); do
	if (echo > /dev/tcp/127.0.0.1/8080) >/dev/null 2>&1; then
		log "port-forward is up"
		break
	fi
	sleep 0.5
	[[ $i == 20 ]] && fail "port-forward never became ready (see /tmp/pf.log)"
done

osh() { openshell --gateway-endpoint "http://127.0.0.1:8080" "$@"; }

# --- ASSERT M1: creating a sandbox bootstraps the workspace namespace -----
#
# `openshell sandbox create` blocks and does not return even once the
# sandbox is Ready (see interop-smoke.sh's Assertion 2), and this smoke runs
# no agent-sandbox controller, so it never will be. Run backgrounded and
# poll kubectl instead of waiting on the CLI to return.
#
# The gateway calls EnsureWorkspace before every sandbox create (see
# driver.rs's ensure_workspace doc comment), so both the namespace and the
# Sandbox CR are expected to exist by the time the CR appears. Managed mode
# uses bare object names -- no sandbox create call ever names a workspace
# here, so the gateway's default workspace ("default") is what gets
# bootstrapped, giving openshell-smoke-default.
log "ASSERT M1: creating a sandbox bootstraps the managed workspace namespace"
osh sandbox create --name m1 --from ghcr.io/nvidia/openshell-community/sandboxes/base:latest \
	-- sleep infinity >/tmp/create-m1.log 2>&1 &
CREATE_PID=$!
cr=""
for _ in $(seq 1 40); do
	if kubectl -n "$NS_DEFAULT" get sandbox m1 >/dev/null 2>&1; then
		cr=m1
		break
	fi
	sleep 3
done
kill "$CREATE_PID" 2>/dev/null || true
[[ -n $cr ]] || { cat /tmp/create-m1.log >&2; fail "sandbox CR 'm1' never appeared in ${NS_DEFAULT}"; }

kubectl get ns "$NS_DEFAULT" >/dev/null 2>&1 || fail "managed namespace $NS_DEFAULT was not created"
[[ "$(kubectl get ns "$NS_DEFAULT" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" == "privileged" ]] \
	|| fail "$NS_DEFAULT is missing the PSA enforce label"
kubectl -n "$NS_DEFAULT" get sa openshell-sandbox >/dev/null 2>&1 \
	|| fail "$NS_DEFAULT is missing the openshell-sandbox ServiceAccount"
# Managed mode uses bare names -- no {workspace}--{name} prefix. Already
# implied by the successful lookup above, asserted explicitly for clarity.
[[ "$(kubectl -n "$NS_DEFAULT" get sandbox m1 -o jsonpath='{.metadata.name}')" == "m1" ]] \
	|| fail "sandbox CR should be named 'm1' in managed mode"

# --- ASSERT M2: an UNOWNED namespace of the same shape is NOT deleted -----
#
# This is the guardrail that protects a pre-existing namespace which merely
# matches the naming convention. The naive version of this test creates a
# bare `kubectl create ns` decoy and calls `workspace delete` on a workspace
# the gateway never heard of -- but the gateway would 404 that before the
# RPC ever reaches the driver, so the namespace would survive because
# nothing ran, not because the guardrail declined. That passes vacuously.
#
# A second, subtler trap: `openshell workspace create` alone does not
# bootstrap the namespace either. It only registers the workspace name with
# the gateway -- ensure_workspace is never called from that path (see the
# bootstrap comment on KymaProvisioner::create in provisioner.rs), so a
# decoy built from `workspace create` alone would never see $NS_DECOY come
# into existence, and this assertion would fail before it ever reached the
# guardrail -- the same misconception ASSERT M1 had before its fix, one
# layer along.
#
# Instead: `workspace create` registers "decoy" with the gateway (needed so
# `--workspace decoy` below and `workspace delete decoy` further down are
# valid RPCs rather than 404s), then a real sandbox create scoped to that
# workspace -- mirroring ASSERT M1's idiom of polling for the CR rather
# than waiting on the CLI to return, since it never will -- is what
# actually makes the driver bootstrap and label $NS_DECOY. Only then do we
# strip exactly the three ownership labels the guardrail checks and call
# `workspace delete` for real. The RPC reaches delete_managed_namespace's
# namespace_owned_by check, which must see the mismatch and decline --
# returning Ok, not erroring.
log "ASSERT M2: an UNOWNED namespace is NOT deleted (ownership guardrail)"
osh workspace create --name decoy || fail "workspace create decoy failed"

osh sandbox create --workspace decoy --name m2 --from ghcr.io/nvidia/openshell-community/sandboxes/base:latest \
	-- sleep infinity >/tmp/create-m2.log 2>&1 &
CREATE_PID=$!
cr=""
for _ in $(seq 1 40); do
	if kubectl -n "$NS_DECOY" get sandbox m2 >/dev/null 2>&1; then
		cr=m2
		break
	fi
	sleep 3
done
kill "$CREATE_PID" 2>/dev/null || true
[[ -n $cr ]] || { cat /tmp/create-m2.log >&2; fail "sandbox CR 'm2' never appeared in ${NS_DECOY}"; }

kubectl get ns "$NS_DECOY" >/dev/null 2>&1 || fail "managed namespace $NS_DECOY was not created"

for key in openshell.ai/managed-by openshell.ai/gateway-id openshell.ai/sandbox-workspace; do
	esc=${key//./\\.}
	val=$(kubectl get ns "$NS_DECOY" -o jsonpath="{.metadata.labels.${esc}}")
	[[ -n $val ]] || fail "$NS_DECOY is missing ownership label $key"
done

# Strip the ownership labels. A trailing '-' on a label key removes it.
kubectl label namespace "$NS_DECOY" \
	openshell.ai/managed-by- \
	openshell.ai/gateway-id- \
	openshell.ai/sandbox-workspace- \
	|| fail "could not strip ownership labels from $NS_DECOY"

# The driver declines idempotently and returns Ok -- this must succeed, not error.
osh workspace delete decoy || fail "workspace delete decoy should succeed even though the driver declines to delete the namespace"

# Bounded wait rather than an instant check: this is the negative case, so
# there is no "gone" event to wait for -- only silence to confirm. A
# namespace deletion that was going to happen starts immediately (phase
# flips to Terminating), so a short wait is a meaningful signal here, not
# an arbitrary pause.
sleep 15
kubectl get ns "$NS_DECOY" >/dev/null 2>&1 \
	|| fail "GUARDRAIL BREACH: an unlabelled namespace was deleted"
phase=$(kubectl get ns "$NS_DECOY" -o jsonpath='{.status.phase}')
[[ "$phase" == "Active" ]] \
	|| fail "GUARDRAIL BREACH: $NS_DECOY phase is '$phase', expected 'Active'"

# --- ASSERT M3: an OWNED namespace IS deleted ------------------------------
log "ASSERT M3: an OWNED namespace IS deleted"
osh workspace delete default || fail "workspace delete default failed"
gone=0
for _ in $(seq 1 40); do
	if ! kubectl get ns "$NS_DEFAULT" >/dev/null 2>&1; then
		gone=1
		break
	fi
	# A namespace stuck Terminating still counts as accepted-for-deletion --
	# deletion is asynchronous and background-propagated.
	if [[ "$(kubectl get ns "$NS_DEFAULT" -o jsonpath='{.status.phase}')" == "Terminating" ]]; then
		gone=1
		break
	fi
	sleep 3
done
[[ $gone == 1 ]] || fail "owned namespace $NS_DEFAULT was not deleted"

log "MANAGED SMOKE PASSED (gateway ${GATEWAY_IMAGE##*@})"
