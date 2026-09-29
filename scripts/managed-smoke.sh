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
# cluster assumptions, same pinned agent-sandbox controller install, same
# osh() CLI wrapper. Installs `--workspace-mode=managed`, where
# interop-smoke.sh exercises the default `shared` mode instead.
#
# Assumes: a working kubectl context (a throwaway kind cluster), helm, and uv.
# Required env: GATEWAY_IMAGE, SUPERVISOR_IMAGE, SANDBOX_RUNTIME_IMAGE,
#               CLI_VERSION, DRIVER_IMAGE
#
# Like interop-smoke.sh, this runs the real agent-sandbox controller and
# follows the first sandbox to Ready, through bootstrap and a stop/start
# round-trip, in the managed namespace. The ownership assertions (M2, M3) then
# create sandboxes to Ready and delete them.

set -euo pipefail

NS=openshell-system
RELEASE=oms
GATEWAY_ID=smoke
NS_DEFAULT="openshell-${GATEWAY_ID}-default"
NS_DECOY="openshell-${GATEWAY_ID}-decoy"
NS_OWNED="openshell-${GATEWAY_ID}-owned"
# How long to let the gateway's reconciliation sweep catch up before
# cross-checking Kubernetes directly. Was an inline 40x3s=120s poll, which
# this smoke outran often enough to fail roughly half its runs.
STORE_SETTLE_SECS=300

log()  { printf '\n=== %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; dump_diagnostics; exit 1; }
# The gateway emits ANSI colour codes even without a TTY. Strip them before
# matching on its log lines, or a literal level or field never matches.
strip_ansi() { sed $'s/\033\\[[0-9;]*m//g'; }

dump_diagnostics() {
	printf '\n--- pods (%s) ---\n' "$NS" >&2
	kubectl -n "$NS" get pods -o wide 2>&1 | head -20 >&2 || true
	printf '\n--- driver log ---\n' >&2
	kubectl -n "$NS" logs "deploy/${RELEASE}-openshell-driver-kyma" -c driver --tail=50 2>&1 >&2 || true
	printf '\n--- gateway log ---\n' >&2
	kubectl -n "$NS" logs "deploy/${RELEASE}-openshell-driver-kyma" -c gateway --tail=50 2>&1 >&2 || true
	printf '\n--- managed namespaces ---\n' >&2
	kubectl get ns "$NS_DEFAULT" "$NS_DECOY" "$NS_OWNED" -o wide 2>&1 >&2 || true
	local ns
	for ns in "$NS_DEFAULT" "$NS_DECOY" "$NS_OWNED"; do
		printf '\n--- pods (%s) ---\n' "$ns" >&2
		kubectl -n "$ns" get pods -o wide 2>&1 | head -20 >&2 || true
	done
	printf '\n--- agent-sandbox controller log ---\n' >&2
	kubectl -n agent-sandbox-system logs deploy/agent-sandbox-controller --tail=50 2>&1 >&2 || true
	for ns in "$NS_DEFAULT" "$NS_DECOY" "$NS_OWNED"; do
		printf '\n--- events (%s) ---\n' "$ns" >&2
		kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>&1 | tail -30 >&2 || true
	done
}

# Delete a workspace, tolerating a gateway store that lags Kubernetes.
#
# `workspace delete`'s emptiness precondition reads the gateway's own store,
# which is filled by a reconciliation sweep against Kubernetes. That sweep
# can lag badly: observed still listing a deleted sandbox 300s after its CR
# was gone from Kubernetes.
#
# The obvious shape -- poll `sandbox list` until the store agrees, then
# delete once -- does not work, and a longer poll does not fix it. It only
# moves the failure downstream: the poll times out, the delete runs anyway,
# and the precondition refuses it. That was measured, not assumed.
#
# So retry the operation itself rather than polling a proxy for it. The
# delete succeeding IS the condition being waited on, and retrying it is
# safe: a refused delete changes nothing. Only the emptiness precondition is
# retried -- any other error is a real failure and fails immediately rather
# than being masked by ${STORE_SETTLE_SECS}s of pointless retries.
#
# On timeout, Kubernetes is the tiebreaker, so the diagnosis names the
# actual fault: a CR that is genuinely still there is a delete failure,
# while a CR that is gone means the store never converged.
workspace_delete_when_ready() {
	local workspace=$1 sandbox=$2 namespace=$3
	local waited=0 out=""

	while (( waited < STORE_SETTLE_SECS )); do
		if out=$(osh workspace delete "$workspace" 2>&1); then
			(( waited > 0 )) && printf 'note: workspace delete %s succeeded after %ss of store lag\n' "$workspace" "$waited" >&2
			return 0
		fi

		if ! grep -qiE "not in a state required|still contains resources" <<<"$out"; then
			printf '%s\n' "$out" >&2
			fail "workspace delete ${workspace} failed for a reason other than the emptiness precondition"
		fi

		sleep 5
		waited=$(( waited + 5 ))
	done

	printf '%s\n' "$out" >&2
	if kubectl -n "$namespace" get sandbox "$sandbox" >/dev/null 2>&1; then
		fail "workspace delete ${workspace} was refused for ${STORE_SETTLE_SECS}s and sandbox ${sandbox} really is still present in ${namespace} -- a genuine delete failure"
	fi
	fail "workspace delete ${workspace} was refused for ${STORE_SETTLE_SECS}s because the gateway store still lists ${sandbox}, even though its CR is gone from ${namespace} -- the store never converged"
}

for v in GATEWAY_IMAGE SUPERVISOR_IMAGE SANDBOX_RUNTIME_IMAGE CLI_VERSION DRIVER_IMAGE; do
	[[ -n ${!v:-} ]] || { echo "error: $v is required" >&2; exit 1; }
done

# The agent-sandbox controller turns Sandbox CRs into pods. Without it no
# sandbox ever starts, which is how v0.8.0 shipped with sandboxes that could
# not run while this smoke stayed green. Pinned by release and by hash.
AGENT_SANDBOX_VERSION=v0.5.2
AGENT_SANDBOX_SHA256=230ee446d6035f631577e1c6b857f6973a8f09a0a853675d3cc34ebfe47abd6b
log "installing agent-sandbox ${AGENT_SANDBOX_VERSION} (CRD + controller)"
curl -fsSL --retry 3 --retry-delay 2 -o /tmp/agent-sandbox.yaml \
	"https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/sandbox.yaml" \
	|| fail "could not download agent-sandbox ${AGENT_SANDBOX_VERSION}"
echo "${AGENT_SANDBOX_SHA256}  /tmp/agent-sandbox.yaml" | sha256sum -c - >/dev/null \
	|| fail "agent-sandbox manifest does not match the pinned sha256"
kubectl apply -f /tmp/agent-sandbox.yaml || fail "could not install agent-sandbox"
kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=3m \
	|| fail "the agent-sandbox controller never became ready"
# The CRD converts between its two versions through a webhook served by the
# controller, whose CA the controller patches into the CRD at startup (tls.go
# patchCRDs). The Deployment has no readiness probe, so `rollout status`
# returns when the container starts, possibly before that patch has landed;
# until it has, a Sandbox create that needs conversion fails on TLS. Wait for
# the CA rather than trusting the time the helm install takes.
crd_ca() {
	kubectl get crd sandboxes.agents.x-k8s.io \
		-o jsonpath='{.spec.conversion.webhook.clientConfig.caBundle}' 2>/dev/null
}
for _ in $(seq 1 60); do
	[[ -n $(crd_ca) ]] && break
	sleep 2
done
[[ -n $(crd_ca) ]] || fail "the agent-sandbox controller never published its conversion webhook CA"

log "creating the driver/gateway namespace"
# Unlike interop-smoke.sh's shared-mode namespace, this one does NOT need
# the PSA privileged label: main.rs only runs the startup PSA pre-flight
# check under WorkspaceMode::Shared (cfg.namespace is the one static
# namespace shared mode uses). Under Managed there is no single namespace
# to check at startup -- PSA is verified per-workspace instead, as part of
# ASSERT M1 below.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

log "installing the chart in managed mode (gateway ${GATEWAY_IMAGE##*@})"
# The gateway id is gateway.sandboxJwt.gatewayId, shared by the gateway and the
# driver; in managed mode it becomes part of every namespace name, so keep it
# short (the chart refuses more than 33 characters).
#
# workspacePsaLevel=privileged is a level that always admits, so M-psa tests
# the labelling mechanism without depending on the level the chart's users pick.
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
	--set driver.sandboxRuntimeImage="$SANDBOX_RUNTIME_IMAGE" \
	--set driver.workspaceMode=managed \
	--set gateway.sandboxJwt.gatewayId="$GATEWAY_ID" \
	--set driver.workspacePsaLevel=privileged \
	--wait --timeout 5m \
	|| fail "helm install failed"

log "waiting for the driver+gateway pod"
kubectl -n "$NS" rollout status "deploy/${RELEASE}-openshell-driver-kyma" --timeout=3m \
	|| fail "driver/gateway deployment never became available"

# The CLI comes from the release tarball, NOT from PyPI.
#
# `uv tool install openshell==<ver>` worked only incidentally: the wheel used
# to carry the binary as a `.data/scripts/openshell` payload. NVIDIA/OpenShell#2321
# ("fix(python): remove CLI from wheel", merged 2026-08-25) removed it
# deliberately -- "the gateway and CLI now ship as standalone artifacts, so the
# Python distribution should contain only the SDK" -- and added a test asserting
# the wheel *cannot* contain an openshell entry point. From 0.0.113 the wheel is
# a ~0.1 MB SDK (was 8.18 MB), so the old install fails with "No executables are
# provided by package `openshell`".
#
# install.sh is not used either: on Linux it installs a .deb, and on macOS it
# starts a brew-services local gateway. The static musl tarball is the smallest
# thing that yields a CLI -- statically linked, no package manager, no root.
log "installing the openshell CLI ${CLI_VERSION} from the release tarball"
CLI_DIR="$(mktemp -d)"
CLI_TARBALL="openshell-x86_64-unknown-linux-musl.tar.gz"
curl -fsSL --retry 3 --retry-delay 2 \
	"https://github.com/NVIDIA/OpenShell/releases/download/v${CLI_VERSION}/${CLI_TARBALL}" \
	-o "${CLI_DIR}/cli.tar.gz" \
	|| fail "could not download the openshell CLI ${CLI_VERSION} (${CLI_TARBALL})"
tar xzf "${CLI_DIR}/cli.tar.gz" -C "$CLI_DIR" || fail "could not unpack the openshell CLI tarball"
[[ -x "${CLI_DIR}/openshell" ]] || fail "the CLI tarball did not contain an executable 'openshell'"
export PATH="${CLI_DIR}:$PATH"
# Fail here rather than at the first ambiguous assertion if the binary cannot run.
openshell --version >/dev/null 2>&1 || fail "the downloaded openshell CLI is not runnable"

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
# The same, bounded: `timeout` cannot run a shell function.
osh_within() { local secs=$1; shift; timeout "$secs" openshell --gateway-endpoint "http://127.0.0.1:8080" "$@"; }

# Create a sandbox and return only once the gateway reports it Ready.
# `--detach` makes the CLI wait for Ready and then return (see
# interop-smoke.sh's Assertion 2 for the source lines). It must be allowed to
# finish: killing the CLI as soon as the CR appears drops the CreateSandbox RPC
# while the driver is still creating the pods, and can leave them stuck
# SchedulingGated. The `timeout` is a backstop for a wedged CLI, not the wait.
create_sandbox_ready() { # name [sandbox-create-args...]
	local name=$1 rc=0
	shift
	osh_within 600 sandbox create --detach "$@" --name "$name" \
		--from ghcr.io/nvidia/openshell-community/sandboxes/base:latest \
		-- sleep infinity >"/tmp/create-${name}.log" 2>&1 || rc=$?
	cat "/tmp/create-${name}.log"
	((rc == 0)) || fail "sandbox create ${name} exited ${rc} (124 = still running after 600s); see the output above"
}

# --- ASSERT M1: creating a sandbox bootstraps the workspace namespace -----
#
# Created with `--detach` and run to completion (create_sandbox_ready): it
# returns once the sandbox is Ready. See interop-smoke.sh's Assertion 2 for why
# the CLI must not be killed once the CR appears.
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
create_sandbox_ready m1
kubectl -n "$NS_DEFAULT" get sandbox m1 >/dev/null 2>&1 \
	|| fail "sandbox CR 'm1' not found in ${NS_DEFAULT} although create returned"
cr=m1

kubectl get ns "$NS_DEFAULT" >/dev/null 2>&1 || fail "managed namespace $NS_DEFAULT was not created"
[[ "$(kubectl get ns "$NS_DEFAULT" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" == "privileged" ]] \
	|| fail "$NS_DEFAULT is missing the PSA enforce label"
kubectl -n "$NS_DEFAULT" get sa openshell-sandbox >/dev/null 2>&1 \
	|| fail "$NS_DEFAULT is missing the openshell-sandbox ServiceAccount"
# Managed mode uses bare names -- no {workspace}--{name} prefix. Already
# implied by the successful lookup above, asserted explicitly for clarity.
[[ "$(kubectl -n "$NS_DEFAULT" get sandbox m1 -o jsonpath='{.metadata.name}')" == "m1" ]] \
	|| fail "sandbox CR should be named 'm1' in managed mode"

# --- ASSERT M1b-M1e: the managed sandbox actually runs ---------------------
#
# The same lifecycle interop-smoke.sh follows in shared mode (its ASSERT
# 3c-3f), here for sandbox m1 in its managed namespace: pods Ready, bootstrap
# complete, Kyma enrichment on the workload pod, stop/start round-trip with
# the pods checked at the Kubernetes level, and the gateway's watch stream
# healthy. See there for why each step is shaped as it is.
#
# `openshell sandbox list` prints NAME, CREATED ("YYYY-MM-DD HH:MM:SS", two
# words) and PHASE, PHASE last, spelled Provisioning, Ready, Stopping,
# Stopped, Starting, Error, Deleting, Completed or Unknown
# (openshell-cli run.rs sandbox_list, common.rs phase_name at v0.1.2). --color
# never: FORCE_COLOR would otherwise wrap the phase in escapes.
sandbox_phase() {
	osh sandbox list --color never 2>/dev/null | awk -v n="$1" '$1 == n {print $NF}'
}
wait_phase() { # name phase timeout-seconds
	local deadline=$((SECONDS + $3))
	while ((SECONDS < deadline)); do
		[[ $(sandbox_phase "$1") == "$2" ]] && return 0
		sleep 5
	done
	return 1
}
wait_phase_not() { # name phase timeout-seconds
	local deadline=$((SECONDS + $3))
	while ((SECONDS < deadline)); do
		local p
		p=$(sandbox_phase "$1")
		[[ -n $p && $p != "$2" ]] && return 0
		sleep 5
	done
	return 1
}
# `kubectl wait` fails at once when nothing matches yet, so poll for the pod,
# then let `kubectl wait` do the waiting.
wait_pod_exists() { # timeout-seconds kubectl-get-args...
	local deadline=$((SECONDS + $1))
	shift
	while ((SECONDS < deadline)); do
		[[ -n $(kubectl -n "$NS_DEFAULT" get pods "$@" -o name 2>/dev/null) ]] && return 0
		sleep 3
	done
	return 1
}
# Wait until no pod of the sandbox is left. A failed `kubectl get` is not
# evidence that the pods are gone, so it is retried, not counted.
wait_pods_gone() { # timeout-seconds selector
	local deadline=$((SECONDS + $1)) out
	while ((SECONDS < deadline)); do
		if out=$(kubectl -n "$NS_DEFAULT" get pods -l "$2" -o name 2>/dev/null) && [[ -z $out ]]; then
			return 0
		fi
		sleep 3
	done
	return 1
}
# Everything needed to see why the pods of a sandbox are not coming up: both
# pods, described, with the logs of every container. `fail` itself only lists
# the pods. (`$pair` and `$wl_sel` are set by ASSERT M1b.)
pair_pod_diagnostics() {
	printf '\n--- supervisor pod os-supervisor-%s ---\n' "$pair" >&2
	kubectl -n "$NS_DEFAULT" describe pod "os-supervisor-${pair}" >&2 || true
	kubectl -n "$NS_DEFAULT" logs "os-supervisor-${pair}" --all-containers --prefix --tail=200 >&2 || true
	printf '\n--- workload pod (%s) ---\n' "$wl_sel" >&2
	kubectl -n "$NS_DEFAULT" describe pod -l "$wl_sel" >&2 || true
	kubectl -n "$NS_DEFAULT" logs -l "$wl_sel" --all-containers --prefix --tail=200 >&2 || true
}
fail_pods() { pair_pod_diagnostics; fail "$@"; }
wait_workload_ready() {
	wait_pod_exists 180 -l "$wl_sel" || fail_pods "the workload pod was never created in ${NS_DEFAULT}"
	kubectl -n "$NS_DEFAULT" wait --for=condition=Ready pod -l "$wl_sel" --timeout=5m \
		|| fail_pods "the workload pod never became Ready"
}

log "ASSERT M1b: the sandbox runtime starts and bootstraps"
# Managed mode uses bare names, so the CR name is the sandbox name.
sid=$(kubectl -n "$NS_DEFAULT" get sandbox "$cr" -o jsonpath='{.metadata.labels.openshell\.ai/sandbox-id}') \
	|| fail "could not read the sandbox id from Sandbox ${cr}"
[[ -n $sid ]] || fail "Sandbox ${cr} has no openshell.ai/sandbox-id label"
pair=${sid,,}
wl_sel="openshell.ai/boundary-pair=${pair},openshell.ai/boundary-role=workload"
wait_pod_exists 180 "os-supervisor-${pair}" \
	|| fail_pods "supervisor pod os-supervisor-${pair} was never created in ${NS_DEFAULT}"
kubectl -n "$NS_DEFAULT" wait --for=condition=Ready "pod/os-supervisor-${pair}" --timeout=5m \
	|| fail_pods "supervisor pod os-supervisor-${pair} never became Ready"
wait_workload_ready
wait_phase "$cr" Ready 300 || fail_pods "gateway never reported ${cr} Ready: bootstrap did not complete (phase: $(sandbox_phase "$cr"))"

log "ASSERT M1c: Kyma enrichment reached the workload pod"
wl_labels=$(kubectl -n "$NS_DEFAULT" get pod -l "$wl_sel" -o jsonpath='{.items[0].metadata.labels}') \
	|| fail "could not read the labels of the workload pod"
grep -q '"sidecar.istio.io/inject":"false"' <<<"$wl_labels" || fail "workload pod lacks sidecar.istio.io/inject=false: ${wl_labels}"
grep -q '"kagenti.io/type":"agent"' <<<"$wl_labels" || fail "workload pod lacks kagenti.io/type=agent: ${wl_labels}"

# The driver's stop deletes the supervisor pod, suspends the Sandbox CR so the
# controller deletes the workload pod, and only returns once that pod is gone
# (driver.rs stop_sandbox_inner). Both pods carry the boundary-pair label, so
# none may be left. The start recreates them and the workload pod must come
# back Ready.
log "ASSERT M1d: stop and start round-trip"
osh sandbox stop "$cr" || fail "stop ${cr} failed"
wait_phase_not "$cr" Ready 180 || fail "${cr} never left Ready after stop"
wait_pods_gone 120 "openshell.ai/boundary-pair=${pair}" \
	|| fail_pods "pods of ${cr} (boundary-pair=${pair}) still exist after stop"
osh sandbox start "$cr" || fail "start ${cr} failed"
wait_phase "$cr" Ready 300 || fail_pods "${cr} did not return to Ready after start (phase: $(sandbox_phase "$cr"))"
wait_workload_ready

# The gateway's watch loop (openshell-server compute/mod.rs watch_loop,
# v0.1.2) logs a warning for each way the driver's watch stream can break and
# retries after 2s, which hides the break from every assertion above. Look for
# the warnings themselves, in the whole log.
log "ASSERT M1e: the gateway's compute watch stream stayed healthy"
gw_all=$(kubectl -n "$NS" logs "deploy/${RELEASE}-openshell-driver-kyma" -c gateway --tail=-1 2>&1) \
	|| fail "could not read gateway logs: ${gw_all}"
gw_all=$(strip_ansi <<<"$gw_all")
for msg in \
	"Compute driver watch stream failed to start" \
	"Compute driver watch stream errored" \
	"Compute driver watch stream ended unexpectedly" \
	"Failed to apply compute driver event"
do
	# Upstream retries a sandbox-row CAS conflict on the next watch event
	# (compute/mod.rs: "concurrent modification detected"), so that one
	# cause of "Failed to apply compute driver event" is not a failure.
	hits=$(grep -F "$msg" <<<"$gw_all" | grep -vF "concurrent modification detected" || true)
	if [[ -n $hits ]]; then
		fail "the gateway logged '${msg}':
$(tail -3 <<<"$hits")"
	fi
done

log "ASSERT M-psa: the managed namespace carries the configured Pod Security level"
level=$(kubectl get namespace "$NS_DEFAULT" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}') \
	|| fail "could not read the Pod Security label of ${NS_DEFAULT}"
[[ $level == privileged ]] || fail "managed namespace ${NS_DEFAULT} has enforce='${level}', expected 'privileged'"

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
# with FAILED_PRECONDITION if it lands mid-sweep. Polling the gateway's own
# view (`sandbox list --workspace`) until it agrees looks like the fix, and
# is not: the sweep has been observed still listing a deleted sandbox 300s
# on, so the poll times out and the delete is refused anyway. What works is
# retrying the delete itself -- see workspace_delete_when_ready above, which
# both call sites use. Because this is a race and not a deterministic
# ordering bug, a single green run does not prove it is fixed; it only means
# this run did not hit the window.
#
# Instead: `workspace create` registers "decoy" with the gateway (needed so
# `--workspace decoy` below and `workspace delete decoy` further down are
# valid RPCs rather than 404s), then a real sandbox create scoped to that
# workspace -- created like ASSERT M1's, with `--detach`, so it is Ready and
# not half-bootstrapped when it is deleted below -- is what
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

create_sandbox_ready m2 --workspace decoy
kubectl -n "$NS_DECOY" get sandbox m2 >/dev/null 2>&1 \
	|| fail "sandbox CR 'm2' not found in ${NS_DECOY} although create returned"

kubectl get ns "$NS_DECOY" >/dev/null 2>&1 || fail "managed namespace $NS_DECOY was not created"

for key in openshell.ai/managed-by openshell.ai/gateway-id openshell.ai/sandbox-workspace; do
	esc=${key//./\\.}
	val=$(kubectl get ns "$NS_DECOY" -o jsonpath="{.metadata.labels.${esc}}") \
		|| fail "could not read labels of ${NS_DECOY}"
	[[ -n $val ]] || fail "$NS_DECOY is missing ownership label $key"
done

# The sandbox created above to trigger the bootstrap now has to go: a
# non-empty workspace is refused by the gateway before the RPC ever reaches
# the ownership guardrail (see the third trap in the comment above). Delete
# it and poll for the CR to disappear rather than assuming the delete is
# synchronous.
osh sandbox delete --workspace decoy m2 || fail "sandbox delete m2 failed"
# The sandbox is running now, so there are pods to tear down: allow 300s
# (100 x 3s) for the CR to go, not 120s.
gone=0
for _ in $(seq 1 100); do
	if ! kubectl -n "$NS_DECOY" get sandbox m2 >/dev/null 2>&1; then
		gone=1
		break
	fi
	sleep 3
done
[[ $gone == 1 ]] || fail "sandbox m2 was not deleted from ${NS_DECOY}"

# A sandbox delete removes only that sandbox's own objects (CR, pods,
# bootstrap Secrets, PVC) -- it must never touch
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

# The driver declines idempotently and returns Ok -- this must succeed, not
# error. Retried past the gateway's store lag (fifth trap above).
workspace_delete_when_ready decoy m2 "$NS_DECOY"

# Bounded wait rather than an instant check: this is the negative case, so
# there is no "gone" event to wait for -- only silence to confirm. A
# namespace deletion that was going to happen starts immediately (phase
# flips to Terminating), so a short wait is a meaningful signal here, not
# an arbitrary pause.
sleep 15
kubectl get ns "$NS_DECOY" >/dev/null 2>&1 \
	|| fail "GUARDRAIL BREACH: an unlabelled namespace was deleted"
phase=$(kubectl get ns "$NS_DECOY" -o jsonpath='{.status.phase}') \
	|| fail "could not read the phase of ${NS_DECOY}"
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
# in ASSERT M2 (create workspace, create a scoped sandbox to Ready to force
# the bootstrap, delete+poll that sandbox to empty the workspace again)
# but skipping the label strip -- the one difference that makes this the
# positive case: an owned, empty namespace really does get deleted.
#
# ASSERT M1's sandbox 'm1' is left running in $NS_DEFAULT for the rest of
# the script on purpose -- nothing deletes workspace "default" any more,
# so nothing needs it gone.
log "ASSERT M3: an OWNED namespace IS deleted"
osh workspace create --name owned || fail "workspace create owned failed"

create_sandbox_ready m3 --workspace owned
kubectl -n "$NS_OWNED" get sandbox m3 >/dev/null 2>&1 \
	|| fail "sandbox CR 'm3' not found in ${NS_OWNED} although create returned"

kubectl get ns "$NS_OWNED" >/dev/null 2>&1 || fail "managed namespace $NS_OWNED was not created"

for key in openshell.ai/managed-by openshell.ai/gateway-id openshell.ai/sandbox-workspace; do
	esc=${key//./\\.}
	val=$(kubectl get ns "$NS_OWNED" -o jsonpath="{.metadata.labels.${esc}}") \
		|| fail "could not read labels of ${NS_OWNED}"
	[[ -n $val ]] || fail "$NS_OWNED is missing ownership label $key"
done

# Empty the workspace before calling delete -- same emptiness check as
# ASSERT M2 applies here too, and this assertion is meant to prove the
# ownership path succeeds, not get blocked earlier by leftover resources.
osh sandbox delete --workspace owned m3 || fail "sandbox delete m3 failed"
# Running sandbox, pods to tear down: 300s (100 x 3s), as for m2.
gone=0
for _ in $(seq 1 100); do
	if ! kubectl -n "$NS_OWNED" get sandbox m3 >/dev/null 2>&1; then
		gone=1
		break
	fi
	sleep 3
done
[[ $gone == 1 ]] || fail "sandbox m3 was not deleted from ${NS_OWNED}"

kubectl get ns "$NS_OWNED" >/dev/null 2>&1 \
	|| fail "deleting sandbox m3 unexpectedly removed the managed namespace $NS_OWNED"

# Labels were never stripped -- this is an owned namespace. The RPC should
# reach delete_managed_namespace's namespace_owned_by check, find a match,
# and actually delete it.
workspace_delete_when_ready owned m3 "$NS_OWNED"
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
