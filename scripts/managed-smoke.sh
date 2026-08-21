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
NS_OWNED="openshell-${GATEWAY_ID}-owned"
CRD_URL="https://raw.githubusercontent.com/kubernetes-sigs/agent-sandbox/main/k8s/crds/agents.x-k8s.io_sandboxes.yaml"
# How long to let the gateway's reconciliation sweep catch up before
# cross-checking Kubernetes directly. Was an inline 40x3s=120s poll, which
# this smoke outran often enough to fail roughly half its runs.
STORE_SETTLE_SECS=300

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
	kubectl get ns "$NS_DEFAULT" "$NS_DECOY" "$NS_OWNED" -o wide 2>&1 >&2 || true
}

# Wait for the gateway's own store to stop listing $name in $workspace.
#
# `workspace delete`'s emptiness precondition reads the gateway's store, not
# Kubernetes, so polling that store -- rather than kubectl -- is what makes
# the gate consult the same source the precondition does. But the store is
# filled by a reconciliation sweep that can lag arbitrarily, and a slow
# sweep is not the same failure as a sandbox that genuinely did not delete.
# Treating them as one failure is what made this assertion flaky.
#
# So: poll the store for up to STORE_SETTLE_SECS. If it still lists the
# sandbox, cross-check Kubernetes -- the source of truth the sweep reads
# from. Fail only when BOTH still report it, which is a real delete failure.
# When Kubernetes says the CR is gone and only the store disagrees, the
# sweep is merely behind: warn loudly and continue, letting the workspace
# delete downstream be the real assertion rather than inventing a failure
# here. The warning is deliberately noisy -- a sweep that never catches up
# is worth seeing even on a green run.
wait_for_gateway_to_forget() {
	local workspace=$1 name=$2 namespace=$3
	local waited=0

	while (( waited < STORE_SETTLE_SECS )); do
		if ! osh sandbox list --workspace "$workspace" --names 2>/dev/null | grep -qx "$name"; then
			return 0
		fi
		sleep 3
		waited=$(( waited + 3 ))
	done

	if kubectl -n "$namespace" get sandbox "$name" >/dev/null 2>&1; then
		fail "sandbox ${name} is still listed by BOTH the gateway store and Kubernetes (${namespace}) after ${STORE_SETTLE_SECS}s -- this is a real delete failure, not the reconciliation lag"
	fi

	printf '\nWARNING: gateway store still lists %s in workspace %s after %ss,\n' \
		"$name" "$workspace" "$STORE_SETTLE_SECS" >&2
	printf 'WARNING: but its CR is already gone from %s -- the reconciliation sweep\n' "$namespace" >&2
	printf 'WARNING: is lagging. Continuing; the workspace delete below is the real gate.\n' >&2
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
# The gateway does not call EnsureWorkspace before sandbox create -- at
# upstream v0.0.109 ensure_workspace appears nowhere in
# crates/openshell-server/src/grpc/sandbox.rs, only in two provider
# handlers and the provider-refresh loop, all gated on storing provider
# credentials. The namespace exists by the time the CR appears because
# this driver bootstraps it lazily inside KymaProvisioner::create under
# Managed, matching upstream's own create_sandbox -> ensure_namespace
# (openshell-driver-kubernetes/src/driver.rs:1358). That lazy bootstrap on
# the sandbox-create path is exactly what this assertion proves, not a
# gateway guarantee it relies on. Managed mode uses bare object names --
# no sandbox create call ever names a workspace here, so an unscoped
# create lands in the gateway's default workspace ("default"), giving
# openshell-smoke-default.
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
# A third trap, found the hard way: the same sandbox create that bootstraps
# $NS_DECOY also leaves the workspace non-empty, and the gateway refuses to
# delete a non-empty workspace outright -- workspace.rs's
# "still contains resources" check, status FAILED_PRECONDITION -- before
# the RPC ever reaches delete_managed_namespace's ownership guardrail. So
# the sandbox created to trigger the bootstrap must be deleted again before
# `workspace delete` is called, or this assertion fails for a reason that
# has nothing to do with ownership.
#
# A fourth trap, which does not affect ASSERT M2 itself but sank the first
# version of ASSERT M3 below: the gateway refuses to delete the workspace
# literally named "default" unconditionally -- workspace.rs's
# DEFAULT_WORKSPACE_NAME guard returns FAILED_PRECONDITION before either
# the emptiness check above or delete_managed_namespace ever runs. No
# amount of emptying or labelling $NS_DEFAULT makes `workspace delete
# default` succeed. Proving the happy path (an owned, empty namespace
# really is deleted) therefore needs a workspace that is not "default" --
# see ASSERT M3, which uses "owned" instead and otherwise follows this
# exact recipe minus the label strip.
#
# A fifth trap, this one a race rather than a deterministic bug: the
# gateway's "is this workspace empty?" precondition on workspace delete
# reads its own store, not Kubernetes -- workspace.rs's store.list check,
# upstream v0.0.109 -- and that store is filled by a reconciliation sweep
# against Kubernetes that can lag. Waiting for the sandbox CR to disappear
# from Kubernetes (the third trap above) proves the driver's half is done,
# but not that the gateway's store has caught up -- a `workspace delete`
# issued right after the CR vanishes from Kubernetes can still be refused
# with FAILED_PRECONDITION if it lands mid-sweep. The fix is to also poll
# the gateway's own view (`sandbox list --workspace`) until it agrees the
# workspace is empty, and gate the delete on that -- the same source the
# precondition consults -- not on the kubectl poll alone. Because this is a
# race and not a deterministic ordering bug, a single green run does not
# prove it is fixed; it only means this run did not hit the window.
#
# Instead: `workspace create` registers "decoy" with the gateway (needed so
# `--workspace decoy` below and `workspace delete decoy` further down are
# valid RPCs rather than 404s), then a real sandbox create scoped to that
# workspace -- mirroring ASSERT M1's idiom of polling for the CR rather
# than waiting on the CLI to return, since it never will -- is what
# actually makes the driver bootstrap and label $NS_DECOY. Once the
# ownership labels are confirmed, the sandbox is deleted again (polling for
# the CR to disappear, then confirming $NS_DECOY itself is untouched -- a
# sandbox delete only ever removes the CR and its PVC, never the namespace)
# so the workspace is empty. Only then do we strip exactly the three
# ownership labels the guardrail checks and call `workspace delete` for
# real. The RPC reaches delete_managed_namespace's namespace_owned_by
# check, which must see the mismatch and decline -- returning Ok, not
# erroring.
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

# The sandbox created above to trigger the bootstrap now has to go: a
# non-empty workspace is refused by the gateway before the RPC ever reaches
# the ownership guardrail (see the third trap in the comment above). Delete
# it and poll for the CR to disappear rather than assuming the delete is
# synchronous.
osh sandbox delete --workspace decoy m2 || fail "sandbox delete m2 failed"
gone=0
for _ in $(seq 1 40); do
	if ! kubectl -n "$NS_DECOY" get sandbox m2 >/dev/null 2>&1; then
		gone=1
		break
	fi
	sleep 3
done
[[ $gone == 1 ]] || fail "sandbox m2 was not deleted from ${NS_DECOY}"

# The kubectl poll above only proves the driver's half: the CR is gone from
# Kubernetes. The gateway's own emptiness precondition on workspace delete
# reads its own store, not Kubernetes, and that store can still lag behind
# a moment after the CR disappears (see the fifth trap above). The helper
# polls the gateway's own view -- the same source the precondition consults
# -- and cross-checks Kubernetes before calling it a failure.
wait_for_gateway_to_forget decoy m2 "$NS_DECOY"

# A sandbox delete removes only the CR and its PVC -- it must never touch
# the namespace. Confirm that before trusting the "workspace delete should
# succeed" assertion below to mean what it claims.
kubectl get ns "$NS_DECOY" >/dev/null 2>&1 \
	|| fail "deleting sandbox m2 unexpectedly removed the managed namespace $NS_DECOY"

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
#
# Cannot reuse workspace "default" here -- that's the fourth trap recorded
# above: the gateway refuses to delete "default" unconditionally, before
# any emptiness or ownership check runs. And it cannot reuse ASSERT M2's
# "decoy" either, since that workspace's ownership labels were deliberately
# stripped -- exercising this assertion against it would prove nothing.
# So this gets its own workspace, "owned", built exactly like "decoy" was
# in ASSERT M2 (create workspace, create+poll a scoped sandbox to force
# the bootstrap, delete+poll that sandbox to empty the workspace again)
# but skipping the label strip -- the one difference that makes this the
# positive case: an owned, empty namespace really does get deleted.
#
# ASSERT M1's sandbox 'm1' is left running in $NS_DEFAULT for the rest of
# the script on purpose -- nothing deletes workspace "default" any more,
# so nothing needs it gone.
log "ASSERT M3: an OWNED namespace IS deleted"
osh workspace create --name owned || fail "workspace create owned failed"

osh sandbox create --workspace owned --name m3 --from ghcr.io/nvidia/openshell-community/sandboxes/base:latest \
	-- sleep infinity >/tmp/create-m3.log 2>&1 &
CREATE_PID=$!
cr=""
for _ in $(seq 1 40); do
	if kubectl -n "$NS_OWNED" get sandbox m3 >/dev/null 2>&1; then
		cr=m3
		break
	fi
	sleep 3
done
kill "$CREATE_PID" 2>/dev/null || true
[[ -n $cr ]] || { cat /tmp/create-m3.log >&2; fail "sandbox CR 'm3' never appeared in ${NS_OWNED}"; }

kubectl get ns "$NS_OWNED" >/dev/null 2>&1 || fail "managed namespace $NS_OWNED was not created"

for key in openshell.ai/managed-by openshell.ai/gateway-id openshell.ai/sandbox-workspace; do
	esc=${key//./\\.}
	val=$(kubectl get ns "$NS_OWNED" -o jsonpath="{.metadata.labels.${esc}}")
	[[ -n $val ]] || fail "$NS_OWNED is missing ownership label $key"
done

# Empty the workspace before calling delete -- same emptiness check as
# ASSERT M2 applies here too, and this assertion is meant to prove the
# ownership path succeeds, not get blocked earlier by leftover resources.
osh sandbox delete --workspace owned m3 || fail "sandbox delete m3 failed"
gone=0
for _ in $(seq 1 40); do
	if ! kubectl -n "$NS_OWNED" get sandbox m3 >/dev/null 2>&1; then
		gone=1
		break
	fi
	sleep 3
done
[[ $gone == 1 ]] || fail "sandbox m3 was not deleted from ${NS_OWNED}"

# Same fifth trap as ASSERT M2: the kubectl poll above proves the CR is
# gone from Kubernetes, but the gateway's own emptiness precondition reads
# its own store, which can still lag.
wait_for_gateway_to_forget owned m3 "$NS_OWNED"
kubectl get ns "$NS_OWNED" >/dev/null 2>&1 \
	|| fail "deleting sandbox m3 unexpectedly removed the managed namespace $NS_OWNED"

# Labels were never stripped -- this is an owned namespace. The RPC should
# reach delete_managed_namespace's namespace_owned_by check, find a match,
# and actually delete it.
osh workspace delete owned || fail "workspace delete owned failed"
gone=0
for _ in $(seq 1 40); do
	if ! kubectl get ns "$NS_OWNED" >/dev/null 2>&1; then
		gone=1
		break
	fi
	# A namespace stuck Terminating still counts as accepted-for-deletion --
	# deletion is asynchronous and background-propagated.
	if [[ "$(kubectl get ns "$NS_OWNED" -o jsonpath='{.status.phase}')" == "Terminating" ]]; then
		gone=1
		break
	fi
	sleep 3
done
[[ $gone == 1 ]] || fail "owned namespace $NS_OWNED was not deleted"

log "MANAGED SMOKE PASSED (gateway ${GATEWAY_IMAGE##*@})"
