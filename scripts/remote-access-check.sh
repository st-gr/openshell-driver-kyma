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
#   OSH_NEIGHBOUR_URLS  comma-separated URLs of OTHER applications behind the same
#                       ingress gateway, one per application
#
# The neighbour probes are the safety net. The ingress gateway is shared: a change that
# applies to it as a whole breaks other applications' logins and API keys while this
# release's own hosts look fine (a RequestAuthentication did exactly that in a live run).
# Before the upgrade the script records each neighbour URL's HTTP status without a token,
# with a JWT of an issuer nobody here knows, and with a Bearer value that is no JWT. It
# repeats the probes while the upgrade runs and once more after it. If an answer changes
# and stays changed, it rolls the release back to the revision it found and stops.
# OSH_PROBE_ONLY=1 prints the probes and exits; with OSH_PROBE_BASELINE=<file> it exits 1
# when they differ from that file. It needs OSH_NEIGHBOUR_URLS only.
#
# Optional: OSH_RELEASE (ods), OSH_NAMESPACE (openshell-system), OSH_CLIENT_SECRET
# (openshell-oidc-client: a Secret in OSH_NAMESPACE whose key client-secret holds the
# OIDC client secret; needed when the values enable inferenceProvider),
# OSH_HOOK_CLIENT_ID (the confidential client that secret belongs to, when it is not
# OSH_OIDC_CLIENT_ID), OSH_OIDC_AUDIENCE (the tokens' audience; default the client id),
# OSH_EXTRA_VALUES (a second values file, applied after OSH_VALUES),
# OSH_AUTH_ONLY=1 (accept every authenticated identity instead of upstream's roles),
# OSH_POLICY_ACTION (ALLOW when the ingress gateway already has ALLOW policies; the
# chart's default, DENY, is for a gateway without any),
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

http_code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@" || true; }

# A token no issuer of this cluster signed: three base64url parts, like any JWT.
FOREIGN_JWT=$(python3 -c '
import base64, json
part = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b"=").decode()
print(".".join((part({"alg": "RS256", "typ": "JWT", "kid": "neighbour-probe"}),
                part({"iss": "https://neighbour-probe.invalid", "sub": "probe", "aud": "probe", "exp": 4102444800}),
                "c2lnbmF0dXJl")))')

# probe_neighbours: one line "<probe> <HTTP status> <url>" per probe and neighbour URL.
probe_neighbours() {
	local url
	for url in ${OSH_NEIGHBOUR_URLS//,/ }; do
		printf 'no-token %s %s\n' "$(http_code "$url")" "$url"
		printf 'foreign-jwt %s %s\n' "$(http_code -H "authorization: Bearer $FOREIGN_JWT" "$url")" "$url"
		printf 'bearer-key %s %s\n' "$(http_code -H 'authorization: Bearer sk-neighbour-probe' "$url")" "$url"
	done
}
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

if [[ ${OSH_PROBE_ONLY:-} == 1 ]]; then
	: "${OSH_NEIGHBOUR_URLS:?set OSH_NEIGHBOUR_URLS (comma-separated URLs of other applications behind the ingress gateway)}"
	probes=$(probe_neighbours)
	printf '%s\n' "$probes"
	if [[ -n ${OSH_PROBE_BASELINE:-} ]] && [[ $probes != "$(cat "$OSH_PROBE_BASELINE")" ]]; then
		printf '\nNEIGHBOUR_CHANGED\n'
		probe_changes "$(cat "$OSH_PROBE_BASELINE")" "$probes"
		exit 1
	fi
	exit 0
fi

: "${OSH_DOMAIN:?set OSH_DOMAIN to the cluster wildcard domain}"
: "${OSH_OIDC_ISSUER:?set OSH_OIDC_ISSUER}"
: "${OSH_OIDC_CLIENT_ID:?set OSH_OIDC_CLIENT_ID}"
: "${OSH_ALLOWED_CIDRS:?set OSH_ALLOWED_CIDRS (comma-separated)}"
: "${OSH_VALUES:?set OSH_VALUES to the release values file}"
if [[ ${OSH_DRY_RUN:-} != 1 && ${OSH_SKIP_INSTALL:-} != 1 ]]; then
	: "${OSH_NEIGHBOUR_URLS:?set OSH_NEIGHBOUR_URLS (comma-separated URLs of other applications behind the ingress gateway): this script does not change a shared ingress gateway without watching its other applications}"
fi
RELEASE=${OSH_RELEASE:-ods}
NS=${OSH_NAMESPACE:-openshell-system}
SECRET=${OSH_CLIENT_SECRET:-openshell-oidc-client}
GW=${OSH_GATEWAY_NAME:-kyma}
HOST="openshell.${OSH_DOMAIN}"
SANDBOX=rac-web
ROOT=$(git rev-parse --show-toplevel)
CHART="$ROOT/deploy/helm/openshell-driver-kyma"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

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
if [[ -n ${OSH_POLICY_ACTION:-} ]]; then
	helm_args+=(--set "gatewayIngress.policyAction=$OSH_POLICY_ACTION")
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
# The subject alternative names of the gateway's server certificate, or nothing.
server_sans() {
	kubectl -n "$NS" get secret "$server_secret" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
		| base64 --decode 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null || true
}

if [[ ${OSH_SKIP_INSTALL:-} != 1 ]]; then
	log "PKI"
	if kubectl -n "$NS" get secret "$server_secret" -o name >/dev/null 2>&1 \
		&& ! grep -q "DNS:$service" <<<"$(server_sans)"; then
		if [[ ${OSH_REGENERATE_PKI:-} == 1 ]]; then
			check "PKI Secrets deleted; the upgrade creates them again, for the release's Service names" \
				kubectl -n "$NS" delete secret --ignore-not-found "$server_secret" "$client_secret" "$jwt_secret"
		else
			fail "the gateway's certificate is from before 0.10.0 and does not name $service, so no client could verify it. Re-run with OSH_REGENERATE_PKI=1: it deletes $server_secret, $client_secret and $jwt_secret, and existing sandboxes must be recreated"
			finish
		fi
	else
		pass "the gateway's certificate names the release's Service, or the upgrade creates it"
	fi

	revision=$(helm -n "$NS" history "$RELEASE" --max 1 -o json \
		| python3 -c 'import json, sys; print(json.load(sys.stdin)[-1]["revision"])')
	log "neighbours before the upgrade"
	baseline=$(probe_neighbours)
	printf '%s\n' "$baseline" | mask

	log "upgrading $RELEASE with gatewayIngress (revision $revision is the way back)"
	helm upgrade "$RELEASE" "$CHART" -n "$NS" "${values_args[@]}" ${extra_values[@]+"${extra_values[@]}"} \
		"${helm_args[@]}" --wait --timeout 10m >/dev/null 2>"$WORK/helm.err" &
	helm_pid=$!
	helm_rc=0
	broken=0
	while kill -0 "$helm_pid" 2>/dev/null; do
		sleep "${OSH_PROBE_INTERVAL_SECONDS:-10}"
		if neighbours_differ "$baseline"; then
			broken=1
			break
		fi
	done
	if [[ $broken == 0 ]]; then
		wait "$helm_pid" || helm_rc=$?
		if neighbours_differ "$baseline"; then broken=1; fi
	fi
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
check "the gateway's certificate names $service" grep -q "DNS:$service" <<<"$(server_sans)"
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
