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
# Required env: DRIVER_IMAGE. The upstream gateway, supervisor and sandbox
# runtime images are the chart's own pins, and the openshell CLI is the one of
# the chart's upstream.version, so this tests exactly the image set the chart
# ships (scripts/check-image-digests.sh holds those pins to that release).
#
# Follows one sandbox through its whole life: CR created, supervisor and
# workload pods Ready, bootstrap complete (the gateway reports Ready), the
# Kyma enrichment on the workload pod, and a stop/start round-trip. It installs
# the real agent-sandbox controller for that. An earlier version installed only
# the CRD and stopped at "Sandbox CR created"; no sandbox could start, and a
# release shipped with sandboxes that could not run while this stayed green.

set -euo pipefail

NS=openshell-system
RELEASE=ods
SB=smoke-$$

log()  { printf '\n=== %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; dump_diagnostics; exit 1; }
# The gateway emits ANSI colour codes even without a TTY (see ASSERT 1b). Strip
# them before matching on its log lines: they land between a level and the
# text around it, so a literal ` ERROR ` never matches otherwise.
strip_ansi() { sed $'s/\033\\[[0-9;]*m//g'; }

dump_diagnostics() {
	printf '\n--- pods ---\n' >&2
	kubectl -n "$NS" get pods -o wide 2>&1 | head -20 >&2 || true
	printf '\n--- driver log ---\n' >&2
	kubectl -n "$NS" logs "deploy/${RELEASE}-openshell-driver-kyma" -c driver --tail=50 2>&1 >&2 || true
	printf '\n--- gateway log ---\n' >&2
	kubectl -n "$NS" logs "deploy/${RELEASE}-openshell-driver-kyma" -c gateway --tail=50 2>&1 >&2 || true
	printf '\n--- agent-sandbox controller log ---\n' >&2
	kubectl -n agent-sandbox-system logs deploy/agent-sandbox-controller --tail=50 2>&1 >&2 || true
	printf '\n--- events ---\n' >&2
	kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -30 >&2 || true
}

[[ -n ${DRIVER_IMAGE:-} ]] || { echo "error: DRIVER_IMAGE is required" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"
UPSTREAM_VERSION=$(chart_upstream_version) \
	|| { echo "error: could not read upstream.version from the chart's values.yaml" >&2; exit 1; }
# Upstream's release assets carry the tag's `v`; CLI_VERSION is the bare version.
CLI_VERSION=${UPSTREAM_VERSION#v}

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

log "creating namespace with PSA privileged"
# The driver refuses to start without this label; it is a real precondition,
# not test scaffolding.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=privileged --overwrite

log "installing the chart with its pinned upstream ${UPSTREAM_VERSION} images"
# Install the REAL chart rather than hand-assembling gateway args: no second
# copy of the configuration to drift from deployment.yaml, and it is the path
# a third party would actually take — which is what we are safeguarding.
helm install "$RELEASE" deploy/helm/openshell-driver-kyma \
	--namespace "$NS" \
	--set image.repository="${DRIVER_IMAGE%%:*}" \
	--set image.tag="${DRIVER_IMAGE##*:}" \
	--set image.pullPolicy=Never \
	--set gateway.enabled=true \
	--set gatewayService.enabled=true \
	--set gateway.sandboxJwt.enabled=true \
	--wait --timeout 5m \
	|| fail "helm install failed"
# gateway.sandboxJwt.enabled=true is required so supervisors can complete
# their IssueSandboxToken bootstrap. templates/gateway-config.yaml (and the
# gateway's --config) render whenever gateway.enabled is true; that ConfigMap
# is where `allow_unauthenticated_users = true` is set, without which the
# gateway rejects every gRPC call from the CLI with Unauthenticated.

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
# Poll for the forwarded port instead of a fixed sleep: a fixed sleep is
# exactly the kind of flake-prone guess that made ASSERT 1 unreliable before.
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
# --gateway-endpoint explicitly on every call instead of relying on env: it
# also keeps the test stateless (no $HOME/.config/openshell registration to
# leak between CI runs).
osh() { openshell --gateway-endpoint "http://127.0.0.1:8080" "$@"; }
# The same, bounded: `timeout` cannot run a shell function.
osh_within() { local secs=$1; shift; timeout "$secs" openshell --gateway-endpoint "http://127.0.0.1:8080" "$@"; }

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
# Create with `--detach` and let the CLI run to completion. Do NOT background
# it and kill it once the CR appears: the CR is only the first step of
# CreateSandbox. After it the driver creates the supervisor pod, un-suspends
# the CR, waits for the workload pod, stages secrets and lifts the scheduling
# gates, all inline in the one RPC (openshell-driver-kubernetes driver.rs at
# v0.1.2: CR created at 1941-1950, then create_sandbox_runtime_companions,
# 2277-2620, awaited). Dropping the RPC there can leave pods stuck
# SchedulingGated.
#
# `--detach` (crates/openshell-cli/src/main.rs:1534, "Start the canonical main
# process without attaching to it") makes the CLI return instead of attaching
# a session to `sleep infinity`. It still waits for the sandbox first: run.rs
# watches it (798-1005) until a non-Ready phase has been followed by Ready
# (940-947), and only then takes the `if detach { return Ok(0) }` exit
# (1160-1165). Error, or provisioning idle for OPENSHELL_PROVISION_TIMEOUT
# (826, 300s default), is a non-zero exit. So a zero exit means the gateway
# reported Ready. The `timeout` is a backstop for a wedged CLI: a bound, not
# the wait.
log "ASSERT 2: sandbox CR is created with the expected name and labels"
create_rc=0
osh_within 600 sandbox create --detach --name "$SB" \
	--from ghcr.io/nvidia/openshell-community/sandboxes/base:latest \
	-- sleep infinity >/tmp/create.log 2>&1 || create_rc=$?
cat /tmp/create.log
((create_rc == 0)) || fail "sandbox create ${SB} exited ${create_rc} (124 = still running after 600s); see the output above"
cr=$(kubectl -n "$NS" get sandbox -l "openshell.ai/sandbox-name=${SB}" \
	-o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || cr=""
[[ -n $cr ]] || fail "no Sandbox CR exists for ${SB} although create returned"

[[ $cr == "default--${SB}" ]] || fail "CR name is '${cr}', expected 'default--${SB}'"

labels=$(kubectl -n "$NS" get sandbox "$cr" -o jsonpath='{.metadata.labels}') \
	|| fail "could not read the labels of Sandbox ${cr}"
# The labels upstream's driver sets. kagenti.io/type is not one of them: the
# Kyma enrichment puts it on the sandbox template, so it lands on the workload
# pod and is asserted there (ASSERT 3d).
for key in \
	openshell.ai/sandbox-id \
	openshell.ai/managed-by
do
	grep -q "$key" <<<"$labels" || fail "CR ${cr} is missing label ${key}: ${labels}"
done

# --- Assertion 3: the gateway resolves what the driver created -----------
log "ASSERT 3: openshell sandbox list round-trips the bare name"
list_out=$(osh sandbox list 2>&1) || fail "openshell sandbox list failed:
${list_out}"
printf '%s\n' "$list_out"
grep -q "$SB" <<<"$list_out" || fail "gateway did not list ${SB} by its bare name"

# --- Assertions 3c-3f: the sandbox actually runs --------------------------
#
# What this smoke could not check while it installed only the CRD. The
# controller now turns the CR into pods, so follow the sandbox to Ready, then
# through a stop/start round-trip. `sandbox create --detach` above already
# returned at Ready; these check the Kubernetes side of that and the rest of
# the lifecycle.
#
# `openshell sandbox list` prints NAME, CREATED ("YYYY-MM-DD HH:MM:SS", two
# words) and PHASE, one row per sandbox, PHASE last. The phase is spelled
# Provisioning, Ready, Stopping, Stopped, Starting, Error, Deleting,
# Completed or Unknown (crates/openshell-cli/src/run.rs sandbox_list and
# commands/common.rs phase_name at v0.1.2), so `$NF` is the phase. --color
# never: FORCE_COLOR in the environment would otherwise wrap it in escapes.
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
		[[ -n $(kubectl -n "$NS" get pods "$@" -o name 2>/dev/null) ]] && return 0
		sleep 3
	done
	return 1
}
# Wait until no pod of the sandbox is left. A failed `kubectl get` is not
# evidence that the pods are gone, so it is retried, not counted.
wait_pods_gone() { # timeout-seconds selector
	local deadline=$((SECONDS + $1)) out
	while ((SECONDS < deadline)); do
		if out=$(kubectl -n "$NS" get pods -l "$2" -o name 2>/dev/null) && [[ -z $out ]]; then
			return 0
		fi
		sleep 3
	done
	return 1
}
# Everything needed to see why the pods of a sandbox are not coming up: both
# pods, described, with the logs of every container. `fail` itself only lists
# the pods. (`$pair` and `$wl_sel` are set by ASSERT 3c.)
pair_pod_diagnostics() {
	printf '\n--- supervisor pod os-supervisor-%s ---\n' "$pair" >&2
	kubectl -n "$NS" describe pod "os-supervisor-${pair}" >&2 || true
	kubectl -n "$NS" logs "os-supervisor-${pair}" --all-containers --prefix --tail=200 >&2 || true
	printf '\n--- workload pod (%s) ---\n' "$wl_sel" >&2
	kubectl -n "$NS" describe pod -l "$wl_sel" >&2 || true
	kubectl -n "$NS" logs -l "$wl_sel" --all-containers --prefix --tail=200 >&2 || true
}
fail_pods() { pair_pod_diagnostics; fail "$@"; }
wait_workload_ready() {
	wait_pod_exists 180 -l "$wl_sel" || fail_pods "the workload pod was never created"
	kubectl -n "$NS" wait --for=condition=Ready pod -l "$wl_sel" --timeout=5m \
		|| fail_pods "the workload pod never became Ready"
}

log "ASSERT 3c: the sandbox runtime starts and bootstraps"
sid=$(kubectl -n "$NS" get sandbox "$cr" -o jsonpath='{.metadata.labels.openshell\.ai/sandbox-id}') \
	|| fail "could not read the sandbox id from Sandbox ${cr}"
[[ -n $sid ]] || fail "Sandbox ${cr} has no openshell.ai/sandbox-id label"
pair=${sid,,}
wl_sel="openshell.ai/boundary-pair=${pair},openshell.ai/boundary-role=workload"
wait_pod_exists 180 "os-supervisor-${pair}" \
	|| fail_pods "supervisor pod os-supervisor-${pair} was never created"
kubectl -n "$NS" wait --for=condition=Ready "pod/os-supervisor-${pair}" --timeout=5m \
	|| fail_pods "supervisor pod os-supervisor-${pair} never became Ready"
wait_workload_ready
wait_phase "$SB" Ready 300 || fail_pods "gateway never reported ${SB} Ready: bootstrap did not complete (phase: $(sandbox_phase "$SB"))"

log "ASSERT 3d: Kyma enrichment reached the workload pod"
wl_labels=$(kubectl -n "$NS" get pod -l "$wl_sel" -o jsonpath='{.items[0].metadata.labels}') \
	|| fail "could not read the labels of the workload pod"
grep -q '"sidecar.istio.io/inject":"false"' <<<"$wl_labels" || fail "workload pod lacks sidecar.istio.io/inject=false: ${wl_labels}"
grep -q '"kagenti.io/type":"agent"' <<<"$wl_labels" || fail "workload pod lacks kagenti.io/type=agent: ${wl_labels}"

# `sandbox stop` returns once the gateway reports Stopped and `sandbox start`
# once it reports Ready (each waits up to OPENSHELL_LIFECYCLE_TIMEOUT, 300s by
# default), so the phase waits confirm what the CLI already established. The
# pod checks are the Kubernetes-level proof. The driver's stop deletes the
# supervisor pod, suspends the Sandbox CR so the controller deletes the
# workload pod, and only returns once that pod is gone (driver.rs
# stop_sandbox_inner). Both pods carry the boundary-pair label. The start
# recreates the pods, and the workload one must come back Ready.
log "ASSERT 3e: stop and start round-trip"
osh sandbox stop "$SB" || fail "stop ${SB} failed"
wait_phase_not "$SB" Ready 180 || fail "${SB} never left Ready after stop"
wait_pods_gone 120 "openshell.ai/boundary-pair=${pair}" \
	|| fail_pods "pods of ${SB} (boundary-pair=${pair}) still exist after stop"
osh sandbox start "$SB" || fail "start ${SB} failed"
wait_phase "$SB" Ready 300 || fail_pods "${SB} did not return to Ready after start (phase: $(sandbox_phase "$SB"))"
wait_workload_ready

# The gateway's watch loop (openshell-server compute/mod.rs watch_loop,
# v0.1.2) logs a warning for each way the driver's watch stream can break, and
# retries after 2s. The retry hides the break from every assertion above, so
# look for the warnings themselves. The whole log, not a tail: a break during
# the stop/start is the case this is for.
log "ASSERT 3f: the gateway's compute watch stream stayed healthy"
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

# The driver's watch stream used to be asserted here by scraping
# openshell_driver_watch_events_total from the driver's /metrics. That
# endpoint is gone (the driver's health port serves only /healthz and
# /readyz), so the assertion could not pass. 3c and 3e now depend on the
# stream: the gateway learns a sandbox's phase from the driver's watch stream
# (watch_loop in openshell-server's compute/mod.rs). It also runs a
# reconciliation sweep every minute as a fallback, so a stream that delivered
# nothing would be masked, not caught. No separate assertion covers it.

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
	# The gateway's ERROR level is wrapped in colour codes, so ` ERROR ` below
	# cannot match until they are gone.
	c_logs=$(strip_ansi <<<"$c_logs")
	grep -E '"level":"ERROR"|[[:space:]]ERROR[[:space:]]' <<<"$c_logs" \
		&& fail "${c} logged an ERROR"
	true
done

log "INTEROP SMOKE PASSED (upstream ${UPSTREAM_VERSION}, the chart's pinned images)"
