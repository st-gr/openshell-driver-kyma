#!/usr/bin/env bash
# Live acceptance check for remote gateway access (the chart's gatewayIngress): upgrades
# a release on a real Kyma cluster and proves that the CLI and a sandbox service URL work
# through the cluster's ingress gateway, with OIDC, and that no other application behind
# that ingress gateway is affected.
#
# CI cannot run this: it needs Istio, the Kyma gateway and a real OIDC issuer. Run it
# from a laptop whose address is in OSH_ALLOWED_CIDRS. Every cluster-specific value
# comes from the environment and is never written to disk:
#
#   OSH_DOMAIN          the cluster's wildcard domain, without "*."
#   OSH_OIDC_ISSUER     the OIDC issuer URL
#   OSH_OIDC_CLIENT_ID  the OIDC client id the CLI logs in with
#   OSH_ALLOWED_CIDRS   comma-separated source CIDR blocks for the ingress policies
#   OSH_VALUES          the release's values file
#   OSH_POLICY_ACTION   DENY when the ingress gateway has no ALLOW AuthorizationPolicy,
#                       ALLOW when it already allowlists per host
#                       (kubectl -n istio-system get authorizationpolicies)
#   OSH_NEIGHBOUR_URLS  comma-separated URLs of OTHER applications behind the same
#                       ingress gateway, one per application
#
# The neighbour probes are the safety net. The ingress gateway is shared: a change that
# applies to it as a whole breaks other applications' logins and API keys while this
# release's own hosts look fine (a RequestAuthentication did exactly that in a live run).
# Before the upgrade the script records, for each neighbour URL, the HTTP status and
# whether the answer is the ingress gateway's own refusal: without a token, with a JWT of
# an issuer nobody here knows, and with a Bearer value that is no JWT. It repeats the
# probes while the upgrade runs and once more after it has ended. If an answer changes
# and stays changed, it stops the upgrade, rolls the release back to the deployed
# revision it found, and stops.
# Choose URLs that answer the same way to all three probes, a login page for example. A
# URL that cannot be reached is refused: probes that see nothing prove nothing.
# OSH_PROBE_ONLY=1 prints the probes and exits; with OSH_PROBE_BASELINE=<file> it exits 1
# when they differ from that file. It needs OSH_NEIGHBOUR_URLS only.
#
# The script changes nothing unless it can undo and watch it: the release's latest
# revision must be a deployed one, every neighbour must answer, and under DENY the
# ingress gateway must have no TCP or TLS-passthrough server (ingress-non-http-servers.sh
# says why).
#
# Optional: OSH_RELEASE (ods), OSH_NAMESPACE (openshell-system), OSH_CLIENT_SECRET
# (openshell-oidc-client: a Secret in OSH_NAMESPACE whose key client-secret holds the
# OIDC client secret; needed when the values enable inferenceProvider),
# OSH_HOOK_CLIENT_ID (the confidential client that secret belongs to, when it is not
# OSH_OIDC_CLIENT_ID), OSH_OIDC_AUDIENCE (the tokens' audience; default the client id),
# OSH_EXTRA_VALUES (a second values file, applied after OSH_VALUES),
# OSH_AUTH_ONLY=1 (accept every authenticated identity instead of upstream's roles),
# OSH_REGENERATE_PKI=1 (delete the release's three PKI Secrets before the upgrade when
# the gateway's certificate does not name the release's Service, as on every install from
# before 0.10.0; existing sandboxes must be recreated afterwards),
# OSH_GATEWAY_NAME (kyma), OSH_SKIP_INSTALL=1 (check an install that is already
# there), OSH_CHECK_IDLE=1 (also hold an idle stream for 400 s), OSH_REVERT=1 (afterwards
# upgrade the release back to OSH_VALUES alone and check nothing of it is left in the
# ingress gateway's namespace),
# OSH_DRY_RUN=1 (render the chart with the values this script would install, print them
# and exit).
#
# e2e/keycloak/deploy.sh sets up a test identity provider and prints these values.
#
# `openshell gateway add` opens a browser for the OIDC login on first use.
# Requires: kubectl (with KUBECONFIG set), helm, curl, openssl, python3, openshell.
set -euo pipefail

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# need VARIABLE MESSAGE: stop unless the variable is set. (Not ${VARIABLE:?}: with an EXIT
# trap, bash 3.2 leaves such a failure with the trap's status, which is success.)
need() {
	if [[ -z ${!1:-} ]]; then
		echo "$1: $2" >&2
		exit 1
	fi
}

http_code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@" || true; }

# A token no issuer of this cluster signed: three base64url parts, like any JWT.
FOREIGN_JWT=$(python3 -c '
import base64, json
part = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b"=").decode()
print(".".join((part({"alg": "RS256", "typ": "JWT", "kid": "neighbour-probe"}),
                part({"iss": "https://neighbour-probe.invalid", "sub": "probe", "aud": "probe", "exp": 4102444800}),
                "c2lnbmF0dXJl")))')

# probe URL [curl args...]: "<HTTP status> <origin>" of one request. The origin tells an
# application's own answer ("-") from the ingress gateway's refusal: "edge-jwt" is Istio's
# JWT filter, "edge-rbac" its authorization filter. An application that answers 401 to a
# bad key keeps its status when the ingress gateway starts answering 401 in its place.
probe() {
	local url=$1 code origin=-
	shift
	rm -f "$WORK/body"
	code=$(curl -s -o "$WORK/body" -m 20 -w '%{http_code}' "$@" "$url" || true)
	if grep -q -E '^(Jwt|Jwks) ' "$WORK/body" 2>/dev/null; then
		origin=edge-jwt
	elif grep -q '^RBAC: access denied' "$WORK/body" 2>/dev/null; then
		origin=edge-rbac
	fi
	printf '%s %s' "${code:-000}" "$origin"
}
# probe_neighbours: one line "<probe> <HTTP status> <origin> <url>" per probe and URL.
probe_neighbours() {
	local url
	for url in ${OSH_NEIGHBOUR_URLS//,/ }; do
		printf 'no-token %s %s\n' "$(probe "$url")" "$url"
		printf 'foreign-jwt %s %s\n' "$(probe "$url" -H "authorization: Bearer $FOREIGN_JWT")" "$url"
		printf 'bearer-key %s %s\n' "$(probe "$url" -H 'authorization: Bearer sk-neighbour-probe')" "$url"
	done
}
# unreachable PROBES: the probe lines without an HTTP answer.
unreachable() { awk '$2 == "000"' <<<"$1"; }
# neighbours_differ BASELINE: true when two probe rounds in a row differ from BASELINE
# (one round alone may be a neighbour's own hiccup). The last round is left in $probes.
probes=""
neighbours_differ() {
	probes=$(probe_neighbours)
	[[ $probes != "$1" ]] || return 1
	sleep "${OSH_PROBE_RECHECK_SECONDS:-5}"
	probes=$(probe_neighbours)
	[[ $probes != "$1" ]]
}
# probe_changes BASELINE CURRENT: the probe lines that differ ("<" before, ">" now).
probe_changes() { diff <(printf '%s\n' "$1") <(printf '%s\n' "$2") | grep '^[<>]' || true; }
# require_neighbours: OSH_NEIGHBOUR_URLS must name at least one URL.
require_neighbours() {
	local urls
	read -r -a urls <<<"${OSH_NEIGHBOUR_URLS//,/ }"
	if ((${#urls[@]} == 0)); then
		echo "OSH_NEIGHBOUR_URLS names no URL: give one URL per other application behind the ingress gateway" >&2
		exit 1
	fi
}

if [[ ${OSH_PROBE_ONLY:-} == 1 ]]; then
	need OSH_NEIGHBOUR_URLS "set OSH_NEIGHBOUR_URLS (comma-separated URLs of other applications behind the ingress gateway)"
	require_neighbours
	probes=$(probe_neighbours)
	printf '%s\n' "$probes"
	if [[ -n $(unreachable "$probes") ]]; then
		printf '\nNEIGHBOUR_UNREACHABLE\n' >&2
		unreachable "$probes" >&2
		exit 1
	fi
	if [[ -n ${OSH_PROBE_BASELINE:-} ]] && [[ $probes != "$(cat "$OSH_PROBE_BASELINE")" ]]; then
		printf '\nNEIGHBOUR_CHANGED\n'
		probe_changes "$(cat "$OSH_PROBE_BASELINE")" "$probes"
		exit 1
	fi
	exit 0
fi

need OSH_DOMAIN "set OSH_DOMAIN to the cluster wildcard domain"
need OSH_OIDC_ISSUER "set OSH_OIDC_ISSUER"
need OSH_OIDC_CLIENT_ID "set OSH_OIDC_CLIENT_ID"
need OSH_ALLOWED_CIDRS "set OSH_ALLOWED_CIDRS (comma-separated)"
need OSH_VALUES "set OSH_VALUES to the release values file"
need OSH_POLICY_ACTION "set OSH_POLICY_ACTION to DENY (the ingress gateway has no ALLOW AuthorizationPolicy) or ALLOW (it already allowlists per host); see kubectl -n istio-system get authorizationpolicies"
if [[ ${OSH_DRY_RUN:-} != 1 && ${OSH_SKIP_INSTALL:-} != 1 ]]; then
	need OSH_NEIGHBOUR_URLS "set OSH_NEIGHBOUR_URLS (comma-separated URLs of other applications behind the ingress gateway): this script does not change a shared ingress gateway without watching its other applications"
	require_neighbours
fi
RELEASE=${OSH_RELEASE:-ods}
NS=${OSH_NAMESPACE:-openshell-system}
SECRET=${OSH_CLIENT_SECRET:-openshell-oidc-client}
GW=${OSH_GATEWAY_NAME:-kyma}
HOST="openshell.${OSH_DOMAIN}"
SANDBOX=rac-web
ROOT=$(git rev-parse --show-toplevel)
CHART="$ROOT/deploy/helm/openshell-driver-kyma"

results=()
failed=0
pass() { results+=("PASS  $1"); }
fail() { results+=("FAIL  $1"); failed=1; }
check() { # description command...
	local what=$1
	shift
	if "$@"; then pass "$what"; else fail "$what"; fi
}
log() { printf '\n=== %s\n' "$*"; }
mask() { sed "s/${OSH_DOMAIN//./\\.}/<domain>/g"; }
osh() { openshell --gateway "$GW" "$@"; }

cidrs_json=$(python3 -c 'import json,sys; print(json.dumps([c.strip() for c in sys.argv[1].split(",") if c.strip()]))' \
	"$OSH_ALLOWED_CIDRS")

AUDIENCE=${OSH_OIDC_AUDIENCE:-$OSH_OIDC_CLIENT_ID}
helm_args=(--set gatewayIngress.enabled=true
	--set "gatewayIngress.domain=$OSH_DOMAIN"
	--set "gatewayIngress.policyAction=$OSH_POLICY_ACTION"
	--set gatewayIngress.serviceHosts.enabled=true
	--set-json "gatewayIngress.allowedCidrs=$cidrs_json"
	--set gateway.tls.enabled=true
	--set "gateway.oidc.issuer=$OSH_OIDC_ISSUER"
	--set "gateway.oidc.audience=$AUDIENCE"
	--set "gateway.oidc.clientId=$OSH_OIDC_CLIENT_ID"
	--set "gateway.oidc.clientCredentialsSecret.name=$SECRET")
if [[ -n ${OSH_HOOK_CLIENT_ID:-} ]]; then
	helm_args+=(--set "gateway.oidc.clientCredentialsSecret.clientId=$OSH_HOOK_CLIENT_ID")
fi
if [[ ${OSH_AUTH_ONLY:-} == 1 ]]; then
	helm_args+=(--set gateway.oidc.authOnly=true)
fi
values_args=(-f "$OSH_VALUES")
extra_values=()
if [[ -n ${OSH_EXTRA_VALUES:-} ]]; then
	extra_values=(-f "$OSH_EXTRA_VALUES")
fi
render() { # [helm template args...]: the chart with the values this script installs
	helm template "$RELEASE" "$CHART" -n "$NS" "${values_args[@]}" ${extra_values[@]+"${extra_values[@]}"} \
		"${helm_args[@]}" "$@"
}
if [[ ${OSH_DRY_RUN:-} == 1 ]]; then
	render >/dev/null
	printf '%s\n' ${extra_values[@]+"${extra_values[@]}"} "${helm_args[@]}"
	exit 0
fi

# finish: print the results and exit with the verdict.
finish() {
	printf '\n'
	printf '%s\n' "${results[@]}" | mask
	if [[ $failed == 1 ]]; then
		printf '\nREMOTE_ACCESS_FAIL\n'
		exit 1
	fi
	printf '\nREMOTE_ACCESS_OK\n'
	exit 0
}

# The provider the chart's hook registers with these values; empty when the values do
# not enable inferenceProvider (the hook template then renders nothing).
provider=$(render --show-only templates/inference-provider-hook.yaml 2>/dev/null \
	| awk '/- name: PROVIDER_NAME/ { getline; gsub(/^[[:space:]]*value:[[:space:]]*"?|"?[[:space:]]*$/, ""); print; exit }' || true)

log "release"
fullname=$(kubectl -n "$NS" get deploy -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=openshell-driver-kyma" \
	-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z $fullname ]]; then
	fail "release $RELEASE has no Deployment in $NS: this script upgrades an existing release"
	finish
fi
service="$fullname.$NS.svc.cluster.local"
ca_secret="$NS-$fullname-gateway-ca"
# The PKI Secrets, by the names the chart's PKI hook gives them with these values.
pki_hook=$(render --show-only templates/gateway-jwt-pki-hook.yaml)
secret_of() { sed -n "s/^ *- --$1-secret-name=//p" <<<"$pki_hook" | head -1; }
server_secret=$(secret_of server)
client_secret=$(secret_of client)
jwt_secret=$(secret_of jwt)
# The gateway's server certificate as text, or nothing when it cannot be read.
server_certificate() {
	kubectl -n "$NS" get secret "$server_secret" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
		| base64 --decode 2>/dev/null | openssl x509 -noout -text 2>/dev/null || true
}

if [[ ${OSH_SKIP_INSTALL:-} != 1 ]]; then
	# Everything that can refuse the run comes before anything that changes the cluster.
	log "the way back"
	latest=$(helm -n "$NS" history "$RELEASE" -o json 2>/dev/null \
		| python3 -c 'import json, sys; last = json.load(sys.stdin)[-1]; print(last["revision"], last["status"])' 2>/dev/null || true)
	revision=${latest%% *}
	if [[ -z $latest ]]; then
		fail "cannot read the history of release $RELEASE (helm -n $NS history $RELEASE): without it there is no revision to roll back to"
		finish
	fi
	if [[ ${latest#* } != deployed ]]; then
		fail "the latest revision of $RELEASE ($revision) is ${latest#* }, not deployed: a rollback would return to it. Bring the release to a deployed revision first (helm -n $NS rollback $RELEASE <revision>)"
		finish
	fi
	pass "revision $revision is deployed: the way back"

	log "neighbours before the upgrade"
	baseline=$(probe_neighbours)
	printf '%s\n' "$baseline" | mask
	if [[ -n $(unreachable "$baseline") ]]; then
		fail "a neighbour cannot be reached, so it cannot be watched: $(unreachable "$baseline" | tr '\n' ' ')"
		finish
	fi
	if awk '$1 != "no-token" && ($2 == 401 || $2 == 403)' <<<"$baseline" | grep -q .; then
		echo "note: a neighbour already refuses a Bearer probe. A change there shows only if the ingress gateway's own refusal replaces the application's; a URL that answers all three probes alike is a better watch."
	fi

	if [[ $OSH_POLICY_ACTION == DENY ]]; then
		log "DENY policies and the ingress gateway's other servers"
		rc=0
		servers=$("$ROOT/scripts/ingress-non-http-servers.sh" 2>&1) || rc=$?
		if [[ $rc != 0 ]]; then
			fail "OSH_POLICY_ACTION=DENY cannot be used on this ingress gateway: Istio applies a DENY policy to servers that are not HTTP without its host condition, so every connection to them from outside OSH_ALLOWED_CIDRS would be refused: $(tr '\n' ';' <<<"$servers")"
			finish
		fi
		pass "the ingress gateway has only HTTP servers, which a DENY policy matches by host"
	fi

	log "PKI"
	if kubectl -n "$NS" get secret "$server_secret" -o name >/dev/null 2>&1; then
		certificate=$(server_certificate)
		if [[ -z $certificate ]]; then
			fail "cannot read the gateway's certificate in $server_secret (kubectl, base64 or openssl failed): not touching the PKI"
			finish
		elif grep -q "DNS:$service" <<<"$certificate"; then
			pass "the gateway's certificate names the release's Service"
		elif [[ ${OSH_REGENERATE_PKI:-} != 1 ]]; then
			fail "the gateway's certificate is from before 0.10.0 and does not name $service, so no client could verify it. Re-run with OSH_REGENERATE_PKI=1: it deletes $server_secret, $client_secret and $jwt_secret, and existing sandboxes must be recreated"
			finish
		elif kubectl -n "$NS" delete secret --ignore-not-found "$server_secret" "$client_secret" "$jwt_secret"; then
			pass "PKI Secrets deleted; the upgrade creates them again, for the release's Service names"
		else
			fail "could not delete the PKI Secrets $server_secret, $client_secret and $jwt_secret: the release is unchanged"
			finish
		fi
	else
		pass "the release has no PKI yet: the upgrade creates it"
	fi

	log "upgrading $RELEASE with gatewayIngress (revision $revision is the way back)"
	helm upgrade "$RELEASE" "$CHART" -n "$NS" "${values_args[@]}" ${extra_values[@]+"${extra_values[@]}"} \
		"${helm_args[@]}" --wait --timeout 10m >/dev/null 2>"$WORK/helm.err" &
	helm_pid=$!
	helm_rc=0
	broken=0
	ended=0
	# A probe round at once, one every interval while the upgrade runs, and one more after
	# it has ended: what the upgrade applied last is watched too.
	while :; do
		kill -0 "$helm_pid" 2>/dev/null || ended=1
		if neighbours_differ "$baseline"; then
			broken=1
			break
		fi
		[[ $ended == 0 ]] || break
		sleep "${OSH_PROBE_INTERVAL_SECONDS:-10}"
	done
	if [[ $broken == 1 ]]; then
		kill "$helm_pid" 2>/dev/null || true
		wait "$helm_pid" 2>/dev/null || true
		fail "another application behind the ingress gateway answers differently since the upgrade began: $(probe_changes "$baseline" "$probes" | tr '\n' ' ')"
		log "rolling $RELEASE back to revision $revision"
		check "helm rollback to revision $revision" helm -n "$NS" rollback "$RELEASE" "$revision" --wait --timeout 10m
		if neighbours_differ "$baseline"; then
			fail "the neighbours still answer differently after the rollback: $(probe_changes "$baseline" "$probes" | tr '\n' ' ')"
		else
			pass "the neighbours answer as before again"
		fi
		finish
	fi
	wait "$helm_pid" || helm_rc=$?
	pass "$(wc -l <<<"$baseline" | tr -d ' ') neighbour probes unchanged by the upgrade"
	if [[ $helm_rc == 0 ]]; then
		pass "helm upgrade with gatewayIngress${provider:+ (the provider hook ran)}"
	else
		# Nothing below can pass against a release that did not install.
		fail "helm upgrade with gatewayIngress (kubectl -n $NS get pods,jobs); the release may be half-applied: $(head -3 "$WORK/helm.err" | tr '\n' ' ')"
		finish
	fi
fi

log "rendered objects"
check "VirtualService $fullname-gateway" kubectl -n "$NS" get virtualservice "$fullname-gateway" -o name
check "VirtualService $fullname-sandbox-services" kubectl -n "$NS" get virtualservice "$fullname-sandbox-services" -o name
check "DestinationRule $fullname-gateway-tls" kubectl -n "$NS" get destinationrule "$fullname-gateway-tls" -o name
for suffix in cli services; do
	check "authorizationpolicy $NS-$fullname-openshell-$suffix in istio-system" \
		kubectl -n istio-system get authorizationpolicy "$NS-$fullname-openshell-$suffix" -o name
done
left=$(kubectl -n istio-system get requestauthentication -o name 2>/dev/null | grep -c -- "$NS-$fullname-" || true)
check "no RequestAuthentication of this release on the ingress gateway (found $left)" test "$left" = 0
args=$(kubectl -n "$NS" get deploy "$fullname" -o jsonpath='{.spec.template.spec.containers[?(@.name=="gateway")].args}')
check "the gateway serves TLS (--tls-cert, no --disable-tls)" \
	test "$(grep -c -- '--tls-cert' <<<"$args")$(grep -c -- '--disable-tls' <<<"$args")" = 10
check "the gateway's certificate names $service" grep -q "DNS:$service" <<<"$(server_certificate)"
chart_ca=$(kubectl -n "$NS" get secret "$server_secret" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)
ingress_ca=$(kubectl -n istio-system get secret "$ca_secret" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)
check "istio-system/$ca_secret holds the chart CA" test -n "$chart_ca" -a "$chart_ca" = "$ingress_ca"

log "the gateway refuses a call without a token"
# The ingress gateway checks no token. The gateway answers in gRPC's own terms: HTTP 200
# with grpc-status 16 (unauthenticated). A 503 here means the ingress gateway cannot reach
# or verify the gateway pod: see the DestinationRule and the CA Secret above.
grpc=$(curl -s -m 20 -o /dev/null -D - -X POST -H 'content-type: application/grpc' \
	"https://$HOST/openshell.v1.OpenShell/ListSandboxes" | tr -d '\r' \
	| awk -F': ' 'tolower($1) == "grpc-status" { print $2 }' || true)
check "a gRPC call without a bearer is refused by the gateway (grpc-status ${grpc:-none}, want 16)" test "$grpc" = 16

log "CLI through the ingress (a browser opens for the OIDC login)"
openshell gateway add "https://$HOST" --name "$GW" --oidc-issuer "$OSH_OIDC_ISSUER" \
	--oidc-client-id "$OSH_OIDC_CLIENT_ID" --oidc-audience "$AUDIENCE" || true
check "openshell status through https://openshell.<domain>" osh status
osh sandbox delete "$SANDBOX" >/dev/null 2>&1 || true
check "sandbox create" osh sandbox create --detach --name "$SANDBOX" --from python:3.12-slim \
	-- python3 -m http.server 8080 --bind 127.0.0.1
ready=""
for _ in $(seq 1 36); do
	ready=$(osh sandbox list 2>/dev/null | awk -v n="$SANDBOX" '$1 == n { print $NF }')
	[[ $ready == Ready ]] && break
	sleep 5
done
check "sandbox reaches Ready (phase: ${ready:-none})" test "$ready" = Ready
# The marker is computed in the sandbox, so an error that echoes the command cannot match.
# shellcheck disable=SC2016 # the sandbox's shell expands it
out=$(osh sandbox exec --name "$SANDBOX" -- sh -c 'echo exec-$((6 * 7))' 2>&1 || true)
check "sandbox exec through the ingress" grep -q exec-42 <<<"$out"

log "sandbox service URL"
url=$(osh service expose "$SANDBOX" 8080 2>&1 | grep -oE 'https?://[^ ]+' | head -1 || true)
# The gateway serves TLS, so it reports an https URL, and upstream's CLI replaces its port
# with the gateway endpoint's: the printed URL is the one that works.
check "service expose prints https://default--$SANDBOX.<domain>/ (printed: $url)" \
	test "$url" = "https://default--$SANDBOX.$OSH_DOMAIN/"
body=$(curl -s -m 20 "https://default--$SANDBOX.$OSH_DOMAIN/" || true)
check "https://default--$SANDBOX.<domain>/ serves the sandbox's directory listing" \
	grep -q "Directory listing for /" <<<"$body"
# The source-address fence is the only protection of a service URL, and it compares the
# client address the ingress gateway believes. If the gateway believed a client's own
# X-Forwarded-For header, this request would be refused as coming from 198.51.100.1, and
# any client could claim an allowed address the same way.
code=$(http_code -H 'x-forwarded-for: 198.51.100.1' "https://default--$SANDBOX.$OSH_DOMAIN/")
check "the ingress gateway does not take the client address from a client's X-Forwarded-For header (HTTP $code, want 200)" \
	test "$code" = 200
code=$(http_code "https://default--no-such-sandbox.$OSH_DOMAIN/")
check "an unknown sandbox host is answered by the gateway, not by a sandbox (HTTP $code, want 404 or 503)" \
	test "$code" = 404 -o "$code" = 503
code=$(http_code "https://unpublished--$SANDBOX.$OSH_DOMAIN/")
check "a workspace that is not published is not served (HTTP $code, want 403 or 404)" \
	test "$code" = 403 -o "$code" = 404

if [[ -n $provider ]]; then
	log "provider registered by the hook (client credentials, over TLS)"
	out=$(osh provider list 2>&1 || true)
	check "provider $provider is registered: the hook's login worked and it trusted the chart CA" \
		grep -qw -- "$provider" <<<"$out"
fi

if [[ ${OSH_CHECK_IDLE:-} == 1 ]]; then
	log "idle stream for 400 s (Envoy's stream idle timeout is 300 s)"
	# shellcheck disable=SC2016 # the sandbox's shell expands it
	out=$(osh sandbox exec --name "$SANDBOX" -- sh -c 'sleep 400; echo idle-$((6 * 7))' 2>&1 || true)
	check "an exec stream idle for 400 s survives" grep -q idle-42 <<<"$out"
fi

log "cleanup"
osh service delete "$SANDBOX" >/dev/null 2>&1 || true
check "sandbox delete" osh sandbox delete "$SANDBOX"

if [[ ${OSH_REVERT:-} == 1 ]]; then
	log "reverting $RELEASE to $OSH_VALUES alone"
	if helm upgrade "$RELEASE" "$CHART" -n "$NS" -f "$OSH_VALUES" --wait --timeout 10m >/dev/null; then
		pass "helm upgrade back to the values file"
	else
		fail "helm upgrade back to the values file (kubectl -n $NS get pods)"
	fi
	left=$(kubectl -n istio-system get authorizationpolicy,requestauthentication,secret,role,rolebinding -o name 2>/dev/null \
		| grep -c -- "/$NS-$fullname-" || true)
	check "nothing of this release is left in istio-system (found $left)" test "$left" = 0
fi

if [[ -n ${OSH_NEIGHBOUR_URLS:-} && -n ${baseline:-} ]]; then
	log "neighbours at the end"
	if neighbours_differ "$baseline"; then
		fail "another application behind the ingress gateway answers differently than before the run: $(probe_changes "$baseline" "$probes" | tr '\n' ' ')"
	else
		pass "the neighbours answer as before the run"
	fi
fi

finish
