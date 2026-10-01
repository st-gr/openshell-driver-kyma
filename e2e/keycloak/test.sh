#!/usr/bin/env bash
# Tests for the Keycloak test identity provider (this directory):
#   1. deploy.sh renders the manifests it would apply, with no credential in them;
#   2. realm.json carries no credential either, and has the clients the chart needs;
#   3. the realm imports into a throwaway Keycloak (Docker) and issues tokens the
#      OpenShell gateway accepts: issuer, audience, roles, for
#      the client-credentials grant (the provider hook) and for the browser login with
#      PKCE on a loopback redirect (the openshell CLI).
# Requires: docker, curl, python3 with PyYAML.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d)
NAME="osh-keycloak-test-$$"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

# 1 and 2: static checks.
render() { # output-file [VAR=value...]
	local out=$1
	shift
	env OSH_RENDER_ONLY=1 OSH_DOMAIN=example.org OSH_ALLOWED_CIDRS=203.0.113.0/24,2001:db8::/32 \
		OSH_CLUSTER_CIDRS=10.96.0.0/13,10.250.0.0/16 "$@" "$DIR/deploy.sh" >"$out"
}
render "$WORK/manifests.yaml"
render "$WORK/manifests-allow.yaml" OSH_POLICY_ACTION=ALLOW
render "$WORK/manifests-forwarded.yaml" OSH_SOURCE_ADDRESS=forwarded
render "$WORK/manifests-allow-forwarded.yaml" OSH_POLICY_ACTION=ALLOW OSH_SOURCE_ADDRESS=forwarded
for bad in OSH_POLICY_ACTION=allow OSH_DOMAIN='*.example.org' OSH_ALLOWED_CIDRS=office OSH_SOURCE_ADDRESS=xff; do
	if render /dev/null "$bad" 2>/dev/null; then
		echo "KEYCLOAK_FIXTURE_FAIL: deploy.sh accepted $bad"
		exit 1
	fi
done

# deploy.sh against a kubectl stand-in: it must not adopt or delete what it did not create.
# The stand-in logs every call; STUB_NS_LABEL is the fixture label of the namespace (empty:
# not ours), STUB_NS_MISSING=1 means the namespace does not exist.
mkdir "$WORK/bin"
cat >"$WORK/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
case "$*" in
"get namespace keycloak -o jsonpath="*)
	[[ ${STUB_NS_MISSING:-} == 1 ]] && exit 1
	printf '%s' "${STUB_NS_LABEL:-}"
	;;
"get gateways.networking.istio.io -A -o json")
	if [[ -n ${STUB_GATEWAYS:-} ]]; then printf '%s' "$STUB_GATEWAYS"; else printf '{"items":[]}'; fi
	;;
esac
exit 0
STUB
chmod +x "$WORK/bin/kubectl"
stub() { # log-name [VAR=value...]: run deploy.sh with the stand-in; prints its exit status
	local log="$WORK/$1.log" rc=0
	shift
	: >"$log"
	env PATH="$WORK/bin:$PATH" STUB_LOG="$log" "$@" "$DIR/deploy.sh" >/dev/null 2>&1 || rc=$?
	echo "$rc"
}
mutating='(^| )(apply|create|delete|label|rollout)( |$)'
rc=$(stub foreign-deploy OSH_DOMAIN=example.org OSH_ALLOWED_CIDRS=203.0.113.0/24 OSH_CLUSTER_CIDRS=10.0.0.0/8)
if [[ $rc == 0 ]] || grep -qE "$mutating" "$WORK/foreign-deploy.log"; then
	echo "KEYCLOAK_FIXTURE_FAIL: deploy.sh deployed into a namespace 'keycloak' it did not create (exit $rc):"
	grep -E "$mutating" "$WORK/foreign-deploy.log" | head -3
	exit 1
fi
rc=$(stub foreign-delete OSH_DELETE=1)
if [[ $rc == 0 ]] || grep -qE "$mutating" "$WORK/foreign-delete.log"; then
	echo "KEYCLOAK_FIXTURE_FAIL: OSH_DELETE=1 touched a namespace 'keycloak' it did not create (exit $rc)"
	exit 1
fi
rc=$(stub own-delete OSH_DELETE=1 STUB_NS_LABEL=keycloak)
if [[ $rc != 0 ]] || ! grep -q "^delete namespace keycloak" "$WORK/own-delete.log"; then
	echo "KEYCLOAK_FIXTURE_FAIL: OSH_DELETE=1 (without OSH_DOMAIN) did not remove the fixture's own namespace (exit $rc)"
	exit 1
fi

# Under DENY the fence on Keycloak's host would close TCP and TLS-passthrough servers of the
# same ingress gateway to every other source address (Istio builds a DENY rule for them
# without its host): deploy.sh refuses such a gateway before it creates anything. ALLOW
# rules do not reach those servers.
tcp_gateway='{"items":[{"metadata":{"namespace":"apps","name":"db-gateway"},"spec":{"selector":{"istio":"ingressgateway"},"servers":[{"port":{"number":5432,"protocol":"TCP"}}]}}]}'
tcp_deploy() { # log-name [VAR=value...]: deploy.sh onto a gateway with a TCP server; prints its output
	local log="$WORK/$1.log"
	shift
	: >"$log"
	env PATH="$WORK/bin:$PATH" STUB_LOG="$log" STUB_NS_LABEL=keycloak STUB_GATEWAYS="$tcp_gateway" \
		OSH_DOMAIN=example.org OSH_ALLOWED_CIDRS=203.0.113.0/24 OSH_CLUSTER_CIDRS=10.0.0.0/8 "$@" "$DIR/deploy.sh" 2>&1 || true
}
out=$(tcp_deploy tcp-deny)
if ! grep -q 'apps/db-gateway port 5432 (TCP)' <<<"$out" || grep -qE "$mutating" "$WORK/tcp-deny.log"; then
	echo "KEYCLOAK_FIXTURE_FAIL: under DENY, deploy.sh did not refuse an ingress gateway with a TCP server before changing anything:"
	head -3 <<<"$out"
	grep -E "$mutating" "$WORK/tcp-deny.log" | head -3
	exit 1
fi
out=$(tcp_deploy tcp-allow OSH_POLICY_ACTION=ALLOW)
if grep -q 'port 5432' <<<"$out"; then
	echo "KEYCLOAK_FIXTURE_FAIL: under ALLOW, deploy.sh refused because of a TCP server, which ALLOW rules do not touch"
	exit 1
fi

# values.yaml of this directory: the chart's driver+gateway pod may reach an issuer that sits
# behind the cluster's own ingress gateway (its container port, after DNAT).
KUBECONFIG=/dev/null helm template t "$DIR/../../deploy/helm/openshell-driver-kyma" --set gateway.enabled=true \
	--set gateway.sandboxJwt.enabled=true --set gatewayService.enabled=true -f "$DIR/values.yaml" \
	--show-only templates/networkpolicy.yaml >"$WORK/networkpolicy.yaml"
if ! grep -q "port: 8443" "$WORK/networkpolicy.yaml" || ! grep -q "istio: ingressgateway" "$WORK/networkpolicy.yaml"; then
	echo "KEYCLOAK_FIXTURE_FAIL: values.yaml does not open the driver pod's egress to the ingress gateway's port 8443"
	exit 1
fi

python3 - "$WORK/manifests.yaml" "$DIR/realm.json" "$WORK/manifests-allow.yaml" "$WORK/manifests-forwarded.yaml" \
	"$WORK/manifests-allow-forwarded.yaml" <<'PY'
import json, re, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
realm = json.load(open(sys.argv[2]))
failures = []
def one(kind):
    found = [d for d in docs if d["kind"] == kind]
    if len(found) != 1:
        failures.append(f"deploy.sh renders {len(found)} {kind} objects, want 1")
        return None
    return found[0]

deployment = one("Deployment")
if deployment:
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    if not re.fullmatch(r"quay\.io/keycloak/keycloak@sha256:[0-9a-f]{64}", container["image"]):
        failures.append(f"the Keycloak image is not pinned by digest: {container['image']}")
    if container.get("args") != ["start-dev", "--import-realm"]:
        failures.append(f"Keycloak args are {container.get('args')}")
    env = {e["name"]: e for e in container.get("env", [])}
    if env.get("KC_HOSTNAME", {}).get("value") != "https://keycloak.example.org":
        failures.append(f"KC_HOSTNAME is {env.get('KC_HOSTNAME')}, want the public https URL (it becomes the token issuer)")
    for name, e in env.items():
        if re.search(r"PASSWORD|SECRET", name) and ("value" in e or "secretKeyRef" not in (e.get("valueFrom") or {})):
            failures.append(f"{name} must come from a Secret, never a literal")
    security = container.get("securityContext") or {}
    if security.get("allowPrivilegeEscalation") is not False or security.get("capabilities") != {"drop": ["ALL"]}:
        failures.append(f"the Keycloak container is not locked down: {security}")
service = one("Service")
route = one("VirtualService")
if route and service:
    want = {"hosts": ["keycloak.example.org"], "gateways": ["kyma-system/kyma-gateway"],
            "http": [{"route": [{"destination": {"host": "keycloak.keycloak.svc.cluster.local", "port": {"number": 8080}}}]}]}
    if route["spec"] != want or route["metadata"]["namespace"] != "keycloak":
        failures.append(f"the VirtualService is {route['spec']}, want {want}")
    if [(p["name"], p["port"]) for p in service["spec"]["ports"]] != [("http", 8080)]:
        failures.append(f"the Service ports are {service['spec']['ports']}")
# The policy follows the ingress gateway, like the chart's: DENY (default) on a gateway that
# lets everything through, where an ALLOW policy would shut out every other host; ALLOW on
# one that already allowlists.
def policy_of(documents):
    found = [d for d in documents if d["kind"] == "AuthorizationPolicy"]
    return found[0] if len(found) == 1 else None
BLOCKS = ["203.0.113.0/24", "2001:db8::/32", "10.96.0.0/13", "10.250.0.0/16"]
# The fence compares the address of the connection the ingress gateway accepted (ipBlocks),
# as the chart does by default; OSH_SOURCE_ADDRESS=forwarded compares the forwarded one.
renders = [[d for d in yaml.safe_load_all(open(path)) if d] for path in sys.argv[3:6]]
for action, key, documents in (("DENY", "notIpBlocks", docs), ("ALLOW", "ipBlocks", renders[0]),
                               ("DENY", "notRemoteIpBlocks", renders[1]), ("ALLOW", "remoteIpBlocks", renders[2])):
    policy = policy_of(documents)
    want = {"selector": {"matchLabels": {"istio": "ingressgateway"}}, "action": action,
            "rules": [{"from": [{"source": {key: BLOCKS}}],
                       "to": [{"operation": {"hosts": ["keycloak.example.org", "keycloak.example.org:*"]}}]}]}
    if not policy or policy["spec"] != want or policy["metadata"]["namespace"] != "istio-system":
        failures.append(f"with OSH_POLICY_ACTION={action} ({key}) the AuthorizationPolicy is {policy and policy['spec']}, want {want} in istio-system")
fence = one("NetworkPolicy")
if fence:
    want = {"podSelector": {"matchLabels": {"app": "keycloak"}}, "policyTypes": ["Ingress"],
            "ingress": [{"from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "istio-system"}}}],
                         "ports": [{"protocol": "TCP", "port": 8080}]}]}
    if fence["spec"] != want:
        failures.append(f"the NetworkPolicy is {fence['spec']}, want {want}")
if any(d["kind"] == "Secret" for d in docs):
    failures.append("deploy.sh renders a Secret; credentials are created in the cluster, never rendered")

# The realm: no credential in the file, and the clients the chart's values name.
PLACEHOLDER = re.compile(r"^\$\{[A-Z_]+\}$")
clients = {c["clientId"]: c for c in realm["clients"]}
for c in clients.values():
    if "secret" in c and not PLACEHOLDER.match(c["secret"]):
        failures.append(f"client {c['clientId']} has a literal secret")
for u in realm.get("users", []):
    for credential in u.get("credentials", []):
        if not PLACEHOLDER.match(credential.get("value", "")):
            failures.append(f"user {u['username']} has a literal password")
def audience(client):
    return [m["config"].get("included.client.audience") for m in client.get("protocolMappers", [])
            if m["protocolMapper"] == "oidc-audience-mapper" and m["config"].get("access.token.claim") == "true"]
cli, ci = clients.get("openshell-cli"), clients.get("openshell-ci")
if not cli or not ci:
    failures.append(f"the realm's clients are {sorted(clients)}, want openshell-cli and openshell-ci")
else:
    if (cli.get("publicClient"), cli.get("standardFlowEnabled"), cli.get("directAccessGrantsEnabled"),
            cli.get("attributes", {}).get("pkce.code.challenge.method"), cli.get("redirectUris")) != (
            True, True, False, "S256", ["http://127.0.0.1:*"]):
        failures.append("openshell-cli must be a public PKCE (S256) client with only the loopback redirect and no password grant")
    if (ci.get("publicClient"), ci.get("serviceAccountsEnabled"), ci.get("standardFlowEnabled")) != (False, True, False):
        failures.append("openshell-ci must be a confidential service-account client without the browser flow")
    for c in (cli, ci):
        if audience(c) != ["openshell-cli"]:
            failures.append(f"client {c['clientId']} does not put the audience openshell-cli into access tokens")
if sorted(r["name"] for r in realm["roles"]["realm"]) != ["openshell-admin", "openshell-user"]:
    failures.append("the realm roles are not upstream's openshell-admin and openshell-user")
if (realm.get("sslRequired"), realm.get("registrationAllowed"), realm.get("bruteForceProtected")) != ("external", False, True):
    failures.append("the realm must require TLS for external requests, forbid self-registration and throttle brute force")
if failures:
    print("KEYCLOAK_FIXTURE_FAIL (static):")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("static checks ok")
PY

# 3: a real Keycloak with the realm imported.
# shellcheck disable=SC2016 # the pattern matches deploy.sh's literal ${KEYCLOAK_IMAGE:-...}
IMAGE=$(sed -n 's/^KEYCLOAK_IMAGE=\${KEYCLOAK_IMAGE:-\(.*\)}$/\1/p' "$DIR/deploy.sh")
[[ -n $IMAGE ]] || { echo "KEYCLOAK_FIXTURE_FAIL: no KEYCLOAK_IMAGE default in deploy.sh"; exit 1; }
PORT=${KEYCLOAK_TEST_PORT:-18080}
export OSH_USER_PASSWORD OSH_CI_CLIENT_SECRET
OSH_USER_PASSWORD=$(openssl rand -hex 12)
OSH_CI_CLIENT_SECRET=$(openssl rand -hex 24)
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:8080" \
	-e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD="$(openssl rand -hex 12)" \
	-e OSH_USER_PASSWORD -e OSH_CI_CLIENT_SECRET \
	-v "$DIR/realm.json:/opt/keycloak/data/import/realm.json:ro" \
	"$IMAGE" start-dev --import-realm >/dev/null
for i in $(seq 1 90); do
	curl -fsS -o /dev/null "http://127.0.0.1:$PORT/realms/openshell/.well-known/openid-configuration" 2>/dev/null && break
	if [[ $i == 90 ]]; then
		echo "KEYCLOAK_FIXTURE_FAIL: the realm never came up; last log lines:"
		docker logs "$NAME" 2>&1 | tail -15
		exit 1
	fi
	sleep 2
done
python3 - "http://127.0.0.1:$PORT" <<'PY'
import base64, hashlib, html, http.cookiejar, json, os, re, secrets, sys
import urllib.error, urllib.parse, urllib.request

base = sys.argv[1]
realm = base + "/realms/openshell"
failures = []

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

class LoopbackPolicy(http.cookiejar.DefaultCookiePolicy):
    """Keycloak marks its session cookies Secure. A browser treats a loopback address as a
    secure context and sends them back over http; so does this client."""
    def return_ok_secure(self, cookie, request):
        return True

def call(opener, url, data=None):
    """(status, body, headers) of a request, whatever the status."""
    request = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode() if data else None)
    try:
        with opener.open(request, timeout=30) as response:
            return response.status, response.read().decode(), response.headers
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode(), error.headers

def claims(token, part=1):
    segment = token.split(".")[part]
    return json.loads(base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4)))

def check_token(where, body, roles, **expect):
    token = json.loads(body)["access_token"]
    header, payload = claims(token, 0), claims(token)
    audience = payload.get("aud")
    audience = audience if isinstance(audience, list) else [audience]
    got_roles = (payload.get("realm_access") or {}).get("roles") or []
    if payload.get("iss") != realm:
        failures.append(f"{where}: iss is {payload.get('iss')!r}, want {realm!r}")
    if "openshell-cli" not in audience:
        failures.append(f"{where}: aud is {audience}, want it to contain openshell-cli (gateway.oidc.audience)")
    if not set(roles) <= set(got_roles):
        failures.append(f"{where}: realm_access.roles is {got_roles}, want {roles}")
    if not payload.get("sub") or not header.get("kid") or not payload.get("exp"):
        failures.append(f"{where}: the token lacks sub, exp or a key id, which the gateway validates")
    for key, want in expect.items():
        if payload.get(key) != want:
            failures.append(f"{where}: {key} is {payload.get(key)!r}, want {want!r}")

plain = urllib.request.build_opener()
status, body, _ = call(plain, realm + "/.well-known/openid-configuration")
discovery = json.loads(body)
if discovery.get("issuer") != realm:
    failures.append(f"discovery issuer is {discovery.get('issuer')!r}, want {realm!r}")
token_url, auth_url = discovery["token_endpoint"], discovery["authorization_endpoint"]

# The provider hook: client credentials, as upstream's CLI sends them (secret in the body,
# an `audience` parameter).
grant = {"grant_type": "client_credentials", "client_id": "openshell-ci", "audience": "openshell-cli"}
status, body, _ = call(plain, token_url, dict(grant, client_secret=os.environ["OSH_CI_CLIENT_SECRET"]))
if status != 200:
    failures.append(f"client credentials for openshell-ci: HTTP {status}: {body[:200]}")
else:
    check_token("client credentials", body, ["openshell-admin", "openshell-user"], azp="openshell-ci")
status, body, _ = call(plain, token_url, dict(grant, client_secret="wrong"))
if status not in (400, 401):
    failures.append(f"client credentials with a wrong secret: HTTP {status}, want 401")
status, body, _ = call(plain, token_url, {"grant_type": "password", "client_id": "openshell-cli",
                                          "username": "dev", "password": os.environ["OSH_USER_PASSWORD"]})
if status == 200:
    failures.append("openshell-cli accepts the password grant; only the browser flow may log users in")

# The CLI: authorization code with PKCE (S256) on a loopback redirect with an ephemeral port.
verifier = secrets.token_urlsafe(48)
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
redirect = "http://127.0.0.1:54321/callback"
query = {"response_type": "code", "client_id": "openshell-cli", "redirect_uri": redirect, "scope": "openid",
         "state": "state", "code_challenge": challenge, "code_challenge_method": "S256"}
browser = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar(LoopbackPolicy())), NoRedirect)
status, page, _ = call(browser, auth_url + "?" + urllib.parse.urlencode(query))
form = re.search(r'<form[^>]*\baction="([^"]+)"', page)
if status != 200 or not form:
    failures.append(f"the login page for a loopback redirect: HTTP {status}, form found: {bool(form)}")
else:
    status, body, headers = call(browser, html.unescape(form.group(1)),
                                 {"username": "dev", "password": os.environ["OSH_USER_PASSWORD"]})
    location = headers.get("Location") or ""
    code = urllib.parse.parse_qs(urllib.parse.urlparse(location).query).get("code", [None])[0]
    if status != 302 or not location.startswith(redirect) or not code:
        failures.append(f"login as dev: HTTP {status}, redirect {location[:80]!r}; want a 302 to the loopback "
                        "callback with a code (a required action such as a profile update would block the CLI). "
                        "Page text: " + " ".join(re.sub(r"<[^>]+>", " ", body).split())[:300])
    else:
        status, body, _ = call(plain, token_url, {"grant_type": "authorization_code", "client_id": "openshell-cli",
                                                   "code": code, "redirect_uri": redirect, "code_verifier": verifier})
        if status != 200:
            failures.append(f"code exchange with the PKCE verifier: HTTP {status}: {body[:200]}")
        else:
            check_token("browser login", body, ["openshell-admin", "openshell-user"],
                        azp="openshell-cli", preferred_username="dev")
        status, body, _ = call(plain, token_url, {"grant_type": "authorization_code", "client_id": "openshell-cli",
                                                   "code": code, "redirect_uri": redirect, "code_verifier": "wrong"})
        if status == 200:
            failures.append("the code was exchanged a second time, with a wrong PKCE verifier")
status, page, _ = call(browser, auth_url + "?" + urllib.parse.urlencode(dict(query, redirect_uri="https://evil.example/callback")))
if status == 200 and "kc-form-login" in page:
    failures.append("the login page is served for a redirect URI outside the loopback")

if failures:
    print("KEYCLOAK_FIXTURE_FAIL (tokens):")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("token checks ok")
PY
echo KEYCLOAK_FIXTURE_OK
