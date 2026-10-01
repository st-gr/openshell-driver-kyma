#!/usr/bin/env bash
# Live acceptance check for remote gateway access (the chart's gatewayIngress):
# installs it on a real Kyma cluster and proves the CLI and a sandbox service URL
# work through the cluster's ingress gateway, with OIDC.
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
# Optional: OSH_RELEASE (ods), OSH_NAMESPACE (openshell-system), OSH_CLIENT_SECRET
# (openshell-oidc-client: a Secret in OSH_NAMESPACE whose key client-secret holds the
# OIDC client secret; needed when the values enable inferenceProvider),
# OSH_HOOK_CLIENT_ID (the confidential client that secret belongs to, when it is not
# OSH_OIDC_CLIENT_ID), OSH_OIDC_AUDIENCE (the tokens' audience; default the client id),
# OSH_OIDC_JWKS_URI (JWKS URL for the ingress gateway, e.g. an in-cluster one),
# OSH_AUTH_ONLY=1 (accept every authenticated identity instead of upstream's roles),
# OSH_GATEWAY_NAME (kyma), OSH_SKIP_INSTALL=1 (check an install that is already
# there), OSH_CHECK_IDLE=1 (also hold an idle stream for 400 s), OSH_DRY_RUN=1 (render
# the chart with the values this script would install, print them and exit).
#
# e2e/keycloak/deploy.sh sets up a test identity provider and prints these values.
#
# `openshell gateway add` opens a browser for the OIDC login on first use.
# Requires: kubectl (with KUBECONFIG set), helm, curl, python3, openshell.
set -euo pipefail

: "${OSH_DOMAIN:?set OSH_DOMAIN to the cluster wildcard domain}"
: "${OSH_OIDC_ISSUER:?set OSH_OIDC_ISSUER}"
: "${OSH_OIDC_CLIENT_ID:?set OSH_OIDC_CLIENT_ID}"
: "${OSH_ALLOWED_CIDRS:?set OSH_ALLOWED_CIDRS (comma-separated)}"
: "${OSH_VALUES:?set OSH_VALUES to the release values file}"
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
osh() { openshell --gateway "$GW" "$@"; }
http_code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@" || true; }

cidrs_json=$(python3 -c 'import json,sys; print(json.dumps([c.strip() for c in sys.argv[1].split(",") if c.strip()]))' \
	"$OSH_ALLOWED_CIDRS")

AUDIENCE=${OSH_OIDC_AUDIENCE:-$OSH_OIDC_CLIENT_ID}
helm_args=(--set gatewayIngress.enabled=true
	--set "gatewayIngress.domain=$OSH_DOMAIN"
	--set gatewayIngress.serviceHosts.enabled=true
	--set-json "gatewayIngress.allowedCidrs=$cidrs_json"
	--set "gateway.oidc.issuer=$OSH_OIDC_ISSUER"
	--set "gateway.oidc.audience=$AUDIENCE"
	--set "gateway.oidc.clientId=$OSH_OIDC_CLIENT_ID"
	--set "gateway.oidc.clientCredentialsSecret.name=$SECRET")
if [[ -n ${OSH_HOOK_CLIENT_ID:-} ]]; then
	helm_args+=(--set "gateway.oidc.clientCredentialsSecret.clientId=$OSH_HOOK_CLIENT_ID")
fi
if [[ -n ${OSH_OIDC_JWKS_URI:-} ]]; then
	helm_args+=(--set "gateway.oidc.jwksUri=$OSH_OIDC_JWKS_URI")
fi
if [[ ${OSH_AUTH_ONLY:-} == 1 ]]; then
	helm_args+=(--set gateway.oidc.authOnly=true)
fi
if [[ ${OSH_DRY_RUN:-} == 1 ]]; then
	helm template "$RELEASE" "$CHART" -n "$NS" -f "$OSH_VALUES" "${helm_args[@]}" >/dev/null
	printf '%s\n' "${helm_args[@]}"
	exit 0
fi

if [[ ${OSH_SKIP_INSTALL:-} != 1 ]]; then
	log "upgrading $RELEASE with gatewayIngress"
	if helm upgrade "$RELEASE" "$CHART" -n "$NS" -f "$OSH_VALUES" "${helm_args[@]}" \
		--wait --timeout 10m >/dev/null; then
		pass "helm upgrade with gatewayIngress (provider hook included)"
	else
		fail "helm upgrade with gatewayIngress (kubectl -n $NS get pods,jobs)"
	fi
fi

log "rendered objects"
fullname=$(kubectl -n "$NS" get deploy -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=openshell-driver-kyma" \
	-o jsonpath='{.items[0].metadata.name}')
check "VirtualService $fullname-gateway" kubectl -n "$NS" get virtualservice "$fullname-gateway" -o name
check "VirtualService $fullname-sandbox-services" kubectl -n "$NS" get virtualservice "$fullname-sandbox-services" -o name
for suffix in jwt cli services; do
	kind=authorizationpolicy
	[[ $suffix == jwt ]] && kind=requestauthentication
	check "$kind $NS-$fullname-openshell-$suffix in istio-system" \
		kubectl -n istio-system get "$kind" "$NS-$fullname-openshell-$suffix" -o name
done
port=$(kubectl -n "$NS" get deploy "$fullname" \
	-o jsonpath='{.spec.template.spec.containers[?(@.name=="gateway")].ports[?(@.name=="grpc")].containerPort}')
check "gateway binds port 80 (got $port)" test "$port" = 80

log "the edge refuses a call without a token"
code=$(http_code -X POST -H 'content-type: application/grpc' "https://$HOST/openshell.v1.OpenShell/ListSandboxes")
check "POST without a bearer is refused at the edge (HTTP $code, want 403)" test "$code" = 403

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
out=$(osh sandbox exec --name "$SANDBOX" -- sh -c 'echo exec-ok' 2>&1 || true)
check "sandbox exec through the ingress" grep -q exec-ok <<<"$out"

log "sandbox service URL"
url=$(osh service expose "$SANDBOX" 8080 2>&1 | grep -oE 'https?://[^ ]+' | head -1 || true)
check "service expose prints http://default--$SANDBOX.<domain>/ (got ${url/$OSH_DOMAIN/<domain>})" \
	test "$url" = "http://default--$SANDBOX.$OSH_DOMAIN/"
code=$(http_code "http://default--$SANDBOX.$OSH_DOMAIN/")
check "the printed http:// URL redirects to https (HTTP $code, want 301)" test "$code" = 301
body=$(curl -s -m 20 "https://default--$SANDBOX.$OSH_DOMAIN/" || true)
check "https://default--$SANDBOX.<domain>/ serves the sandbox's directory listing" \
	grep -q "Directory listing for /" <<<"$body"
code=$(http_code "https://default--no-such-sandbox.$OSH_DOMAIN/")
check "an unknown sandbox host is answered by the gateway, not by a sandbox (HTTP $code, want 404 or 503)" \
	test "$code" = 404 -o "$code" = 503

if kubectl -n "$NS" get job -l "app.kubernetes.io/instance=$RELEASE" -o name 2>/dev/null | grep -q inference-provider-hook \
	|| grep -qE '^inferenceProvider:' "$OSH_VALUES"; then
	log "provider registered by the hook (client credentials)"
	check "openshell provider list succeeds with the user's token" osh provider list
fi

if [[ ${OSH_CHECK_IDLE:-} == 1 ]]; then
	log "idle stream for 400 s (Envoy's stream idle timeout is 300 s)"
	out=$(osh sandbox exec --name "$SANDBOX" -- sh -c 'sleep 400; echo idle-ok' 2>&1 || true)
	check "an exec stream idle for 400 s survives" grep -q idle-ok <<<"$out"
fi

log "cleanup"
osh service delete "$SANDBOX" >/dev/null 2>&1 || true
check "sandbox delete" osh sandbox delete "$SANDBOX"

printf '\n'
printf '%s\n' "${results[@]}" | sed "s/${OSH_DOMAIN//./\\.}/<domain>/g"
if [[ $failed == 1 ]]; then
	printf '\nREMOTE_ACCESS_FAIL\n'
	exit 1
fi
printf '\nREMOTE_ACCESS_OK\n'
