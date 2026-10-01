#!/usr/bin/env bash
# Tests for scripts/remote-access-check.sh and scripts/ingress-non-http-servers.sh that
# need no cluster: everything the live check does to keep a shared ingress gateway's other
# applications safe.
#   1. The neighbour probes report each neighbour's status and whether the answer came from
#      the ingress gateway itself, without a token, with a foreign JWT and with a Bearer key;
#      OSH_PROBE_BASELINE detects a change, also one that keeps the status; a neighbour that
#      cannot be reached, or an empty list, is refused.
#   2. An install run refuses to start without OSH_NEIGHBOUR_URLS or OSH_POLICY_ACTION.
#   3. The dry run installs gateway TLS and no value of the removed edge token check.
#   4. During an upgrade: a neighbour that starts refusing Bearer tokens (what a
#      RequestAuthentication on the ingress gateway does) gets the release rolled back to
#      the deployed revision, at once (the upgrade is not waited for), also when it breaks
#      only as the upgrade ends; a single differing probe round does not.
#   5. Nothing is changed when the run cannot be undone or watched: the latest revision is
#      not a deployed one, a neighbour is unreachable, or (under DENY) the ingress gateway
#      has servers that are not HTTP.
#   6. The gateway's certificate: one that does not name the release's Service (every
#      install from before 0.10.0) is replaced only with OSH_REGENERATE_PKI=1, after the
#      way back is known; one that cannot be read is never deleted.
#   7. scripts/ingress-non-http-servers.sh lists TCP and TLS-passthrough servers of the
#      Gateways on the ingress gateway, and fails closed.
#   8. A source-address fence that a client can forge its way through, because the ingress
#      gateway takes the client address from the client's own X-Forwarded-For header, is
#      detected (OSH_FENCE_ONLY=1), however many forwarding hops the mesh trusts; and an
#      install run refuses to publish unauthenticated service hosts behind such a fence.
# The neighbour is a local web server; helm, kubectl and openshell are stand-ins.
# Requires: helm, curl, openssl, python3.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/remote-access-check.sh"
WORK=$(mktemp -d)
server_pid=""
trap '[[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$WORK"' EXIT
die() {
	echo "REMOTE_ACCESS_SELFTEST_FAIL: $*"
	exit 1
}

# The neighbour answers 200. To a request with an Authorization header it answers:
#   while $WORK/app401 exists: 401 from the application itself;
#   while $WORK/broken exists: 401 the way Istio's JWT filter does;
#   while $WORK/hiccup exists: that 401 for the 5th and 6th such request since the file
#     appeared, which is one probe round (the baseline and one round come before it).
# Under /trust<N> it answers like a host fenced by source address behind an ingress
# gateway that trusts N forwarding hops: 403 when the request's X-Forwarded-For header
# has N entries or more (the client address is then taken from the header), else 200.
cat >"$WORK/neighbour.py" <<'PY'
import http.server, os, sys

work, count = sys.argv[1], 0

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global count
        code, body = 200, b"ok\n"
        if self.path.startswith("/trust"):
            hops = int(self.path[len("/trust"):])
            forwarded = [e for e in (self.headers.get("X-Forwarded-For") or "").split(",") if e.strip()]
            if hops and len(forwarded) >= hops:
                code, body = 403, b"RBAC: access denied"
        if self.headers.get("Authorization"):
            if os.path.exists(work + "/app401"):
                code, body = 401, b"invalid api key\n"
            if os.path.exists(work + "/hiccup"):
                count += 1
                if count in (5, 6):
                    code, body = 401, b"Jwt issuer is not configured"
            else:
                count = 0
            if os.path.exists(work + "/broken"):
                code, body = 401, b"Jwt issuer is not configured"
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
python3 "$WORK/neighbour.py" "$WORK" >"$WORK/port" &
server_pid=$!
disown "$server_pid"
for _ in $(seq 1 50); do
	[[ -s $WORK/port ]] && break
	sleep 0.1
done
NEIGHBOUR="http://127.0.0.1:$(cat "$WORK/port")/app"
FENCED="http://127.0.0.1:$(cat "$WORK/port")/trust"
UNREACHABLE="http://127.0.0.1:1/app"

# 1. Probes and baseline comparison.
probe() { env OSH_PROBE_ONLY=1 "$@" "$SCRIPT"; }
probe OSH_NEIGHBOUR_URLS="$NEIGHBOUR" >"$WORK/baseline"
want="no-token 200 - $NEIGHBOUR
foreign-jwt 200 - $NEIGHBOUR
bearer-key 200 - $NEIGHBOUR"
[[ $(cat "$WORK/baseline") == "$want" ]] || die "the probes of a healthy neighbour are: $(cat "$WORK/baseline")"
probe OSH_NEIGHBOUR_URLS="$NEIGHBOUR" OSH_PROBE_BASELINE="$WORK/baseline" >/dev/null \
	|| die "an unchanged neighbour was reported as changed"
touch "$WORK/broken"
if probe OSH_NEIGHBOUR_URLS="$NEIGHBOUR" OSH_PROBE_BASELINE="$WORK/baseline" >"$WORK/changed"; then
	die "a neighbour that refuses Bearer tokens was not reported"
fi
grep -q '^NEIGHBOUR_CHANGED$' "$WORK/changed" || die "no NEIGHBOUR_CHANGED line: $(cat "$WORK/changed")"
[[ $(grep -c '^> .* 401 edge-jwt ' "$WORK/changed") == 2 && $(grep -c '^> no-token' "$WORK/changed") == 0 ]] \
	|| die "expected exactly the two Bearer probes to change, marked edge-jwt: $(cat "$WORK/changed")"
rm "$WORK/broken"
# A neighbour that itself answers 401 to a bad key: the status stays 401 when the ingress
# gateway starts answering instead, and the change must still show.
touch "$WORK/app401"
probe OSH_NEIGHBOUR_URLS="$NEIGHBOUR" >"$WORK/baseline-401"
grep -q "^bearer-key 401 - $NEIGHBOUR\$" "$WORK/baseline-401" || die "an application's own 401 is probed as: $(cat "$WORK/baseline-401")"
touch "$WORK/broken"
if probe OSH_NEIGHBOUR_URLS="$NEIGHBOUR" OSH_PROBE_BASELINE="$WORK/baseline-401" >"$WORK/changed-401"; then
	die "a 401 that moved from the application to the ingress gateway was not reported: $(cat "$WORK/changed-401")"
fi
rm "$WORK/broken" "$WORK/app401"
# Probes that see nothing prove nothing.
if probe OSH_NEIGHBOUR_URLS="$UNREACHABLE" >"$WORK/unreachable" 2>&1; then
	die "an unreachable neighbour was accepted: $(cat "$WORK/unreachable")"
fi
if probe OSH_NEIGHBOUR_URLS="," >"$WORK/empty" 2>&1; then
	die "an empty neighbour list was accepted: $(cat "$WORK/empty")"
fi

# 2 and 3. The values an install run needs, with documentation-only names.
printf 'gateway:\n  enabled: true\n  sandboxJwt:\n    enabled: true\ngatewayService:\n  enabled: true\n' >"$WORK/values.yaml"
base() { # [VAR=value...]: the script with the required variables, except the two below
	env KUBECONFIG=/dev/null OSH_DOMAIN=example.org OSH_OIDC_ISSUER=https://issuer.example \
		OSH_OIDC_CLIENT_ID=osh-client OSH_ALLOWED_CIDRS=203.0.113.0/24 OSH_VALUES="$WORK/values.yaml" \
		OSH_AUTH_ONLY=1 "$@" "$SCRIPT"
}
run() { base OSH_NEIGHBOUR_URLS="$NEIGHBOUR" OSH_POLICY_ACTION=ALLOW OSH_PROBE_INTERVAL_SECONDS=1 OSH_PROBE_RECHECK_SECONDS=1 "$@"; }
if base OSH_POLICY_ACTION=ALLOW >"$WORK/no-neighbours" 2>&1; then
	die "an install run started without OSH_NEIGHBOUR_URLS"
fi
grep -q OSH_NEIGHBOUR_URLS "$WORK/no-neighbours" || die "the refusal does not name OSH_NEIGHBOUR_URLS: $(cat "$WORK/no-neighbours")"
if base OSH_NEIGHBOUR_URLS="$NEIGHBOUR" >"$WORK/no-action" 2>&1; then
	die "an install run started without OSH_POLICY_ACTION"
fi
grep -q OSH_POLICY_ACTION "$WORK/no-action" || die "the refusal does not name OSH_POLICY_ACTION: $(cat "$WORK/no-action")"
base OSH_POLICY_ACTION=ALLOW OSH_DRY_RUN=1 >"$WORK/dry-run"
grep -qx 'gateway.tls.enabled=true' "$WORK/dry-run" || die "the dry run does not install gateway TLS: $(cat "$WORK/dry-run")"
if grep -qi 'jwks' "$WORK/dry-run"; then
	die "the dry run still sets a JWKS value: $(cat "$WORK/dry-run")"
fi

# Stand-ins. Every call of helm and kubectl goes to $WORK/calls.log, in order.
#   STUB_UPGRADE   what `helm upgrade` does: break (default: the neighbour breaks, the
#                  upgrade takes 6 s), long (it breaks, the upgrade would take 60 s and
#                  records a TERM), end (it breaks as the upgrade ends, after 2 s), fail
#                  (the upgrade fails after 3 s; the neighbour is untouched)
#   STUB_HISTORY   failed (the latest revision is a failed one), error (helm history fails)
#   STUB_PKI       old (a certificate that does not name the Service), unreadable
#   STUB_GATEWAYS  tcp (the ingress gateway also has a TCP and a TLS-passthrough server)
# `helm template` is answered by the real helm, which needs no cluster.
REAL_HELM=$(command -v helm)
# A public certificate without the release's Service name, as installs from before 0.10.0 have.
OLD_CERT=LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUNIakNDQWNTZ0F3SUJBZ0lVZTZOYkNCTC9hUWk3TmxhNVhIblBnbE5oVFlRd0NnWUlLb1pJemowRUF3SXcKTHpFWk1CY0dBMVVFQXd3UWIzQmxibk5vWld4c0xYTmxjblpsY2pFU01CQUdBMVVFQ2d3SmIzQmxibk5vWld4cwpNQ0FYRFRJMk1UQXdNVEV3TVRJME0xb1lEekl4TWpZd09UQTNNVEF4TWpReldqQXZNUmt3RndZRFZRUUREQkJ2CmNHVnVjMmhsYkd3dGMyVnlkbVZ5TVJJd0VBWURWUVFLREFsdmNHVnVjMmhsYkd3d1dUQVRCZ2NxaGtqT1BRSUIKQmdncWhrak9QUU1CQndOQ0FBU2VqTTlEWWlUeXF5SjVzMXB3S0hWQjZ3VllLeUFSM2J5VGJERVFiUTBCMUNqRQp1WUIrSE9NZ3p6OE40cE0rVlBhMmRlcW5SRzJ1ZjZ1cldqcjlpNXVpbzRHN01JRzRNQjBHQTFVZERnUVdCQlI4CkR5U29RYzk2WVdkVzFOY1FIZDlKR1d5T3lqQWZCZ05WSFNNRUdEQVdnQlI4RHlTb1FjOTZZV2RXMU5jUUhkOUoKR1d5T3lqQVBCZ05WSFJNQkFmOEVCVEFEQVFIL01HVUdBMVVkRVFSZU1GeUNDVzl3Wlc1emFHVnNiSUlYYjNCbApibk5vWld4c0xtOXdaVzV6YUdWc2JDNXpkbU9DSlc5d1pXNXphR1ZzYkM1dmNHVnVjMmhsYkd3dWMzWmpMbU5zCmRYTjBaWEl1Ykc5allXeUNDV3h2WTJGc2FHOXpkSWNFZndBQUFUQUtCZ2dxaGtqT1BRUURBZ05JQURCRkFpQi8KeU9HcjJMZi92SGhYdWx5dmduQWpnbTFmSDZaOERDcFVBcHowY1B5UytnSWhBT29NcFVHbTBDR1haR1IwK0h6bgozM0xhOGxiUU1TWmRQNWl3clZwYktXb1kKLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=
HTTP_GATEWAYS='{"metadata":{"namespace":"kyma-system","name":"kyma-gateway"},"spec":{"selector":{"istio":"ingressgateway","app":"istio-ingressgateway"},"servers":[{"port":{"number":443,"protocol":"HTTPS"},"tls":{"mode":"SIMPLE"}},{"port":{"number":80,"protocol":"HTTP"}}]}},{"metadata":{"namespace":"mesh","name":"eastwest"},"spec":{"selector":{"istio":"eastwestgateway"},"servers":[{"port":{"number":15443,"protocol":"TLS"},"tls":{"mode":"AUTO_PASSTHROUGH"}}]}}'
TCP_GATEWAYS='{"metadata":{"namespace":"apps","name":"db-gateway"},"spec":{"selector":{"istio":"ingressgateway"},"servers":[{"port":{"number":5432,"protocol":"TCP"}}]}},{"metadata":{"namespace":"apps","name":"passthrough"},"spec":{"selector":{"istio":"ingressgateway"},"servers":[{"port":{"number":443,"protocol":"HTTPS"},"tls":{"mode":"PASSTHROUGH"}}]}}'
mkdir "$WORK/bin"
cat >"$WORK/bin/helm" <<STUB
#!/usr/bin/env bash
echo "helm \$*" >>"$WORK/calls.log"
case " \$* " in
*" template "*) exec "$REAL_HELM" "\$@" ;;
*" history "*)
	case "\${STUB_HISTORY:-}" in
	error) exit 1 ;;
	failed) echo '[{"revision": 41, "status": "deployed"}, {"revision": 42, "status": "failed"}]' ;;
	*) echo '[{"revision": 40, "status": "superseded"}, {"revision": 41, "status": "deployed"}]' ;;
	esac
	;;
*" upgrade "*)
	case "\${STUB_UPGRADE:-break}" in
	break)
		touch "$WORK/broken"
		sleep 6
		;;
	long)
		trap 'echo term >"$WORK/helm.term"; exit 143' TERM
		touch "$WORK/broken"
		sleep 60 &
		wait \$!
		;;
	end)
		sleep 2
		touch "$WORK/broken"
		;;
	fail)
		sleep 3
		exit 1
		;;
	esac
	;;
*" rollback "*) rm -f "$WORK/broken" ;;
esac
STUB
cat >"$WORK/bin/kubectl" <<STUB
#!/usr/bin/env bash
echo "kubectl \$*" >>"$WORK/calls.log"
case " \$* " in
*" get deploy "*) printf 'ods-openshell-driver-kyma' ;;
*" get gateways.networking.istio.io "*)
	if [[ \${STUB_GATEWAYS:-} == tcp ]]; then
		printf '{"items":[%s,%s]}' '$HTTP_GATEWAYS' '$TCP_GATEWAYS'
	else
		printf '{"items":[%s]}' '$HTTP_GATEWAYS'
	fi
	;;
*" get secret "*)
	case "\${STUB_PKI:-}" in
	old) [[ " \$* " != *"tls\\\\.crt"* ]] || printf '%s' '$OLD_CERT' ;;
	unreadable) [[ " \$* " != *"tls\\\\.crt"* ]] || printf 'bm90IGEgY2VydGlmaWNhdGU=' ;;
	*) exit 1 ;;
	esac
	;;
esac
STUB
cat >"$WORK/bin/openshell" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$WORK/openshell.log"
STUB
chmod +x "$WORK/bin/helm" "$WORK/bin/kubectl" "$WORK/bin/openshell"
stubbed() { # name [VAR=value...]: an install run with the stand-ins; prints its exit status
	local name=$1 rc=0
	shift
	rm -f "$WORK/calls.log" "$WORK/openshell.log" "$WORK/helm.term" "$WORK/broken" "$WORK/hiccup"
	: >"$WORK/calls.log"
	PATH="$WORK/bin:$PATH" run "$@" >"$WORK/$name.out" 2>&1 || rc=$?
	echo "$rc"
}
out() { cat "$WORK/$1.out"; }
called() { grep -q -- "$1" "$WORK/calls.log"; }
rolled_back() { called '^helm -n openshell-system rollback ods 41 '; }

# 4. A neighbour breaks during the upgrade.
rc=$(stubbed break)
[[ $rc != 0 ]] || die "the run passed although a neighbour broke during the upgrade: $(out break)"
grep -q '^REMOTE_ACCESS_FAIL$' "$WORK/break.out" || die "no REMOTE_ACCESS_FAIL: $(out break)"
grep -q 'FAIL  another application behind the ingress gateway answers differently' "$WORK/break.out" \
	|| die "the failure does not name the neighbours: $(out break)"
rolled_back || die "helm was not asked to roll back to the deployed revision 41: $(cat "$WORK/calls.log")"
grep -q 'PASS  the neighbours answer as before again' "$WORK/break.out" \
	|| die "the run does not confirm the neighbours recovered: $(out break)"
[[ ! -e $WORK/openshell.log ]] || die "the run went on to the CLI checks after the rollback: $(cat "$WORK/openshell.log")"
[[ ! -e $WORK/broken ]] || die "the neighbour is still broken"
# ...and the script does not wait for an upgrade that keeps running: it stops it.
start=$SECONDS
rc=$(stubbed long STUB_UPGRADE=long)
if [[ $rc == 0 ]] || ! rolled_back; then die "no rollback while the upgrade was still running: $(out long)"; fi
[[ -e $WORK/helm.term ]] || die "the running upgrade was not stopped before the rollback"
((SECONDS - start < 30)) || die "the rollback waited $((SECONDS - start)) s for the upgrade to end"
# ...a neighbour that breaks only as the upgrade ends is seen by the round after it.
rc=$(stubbed end STUB_UPGRADE=end OSH_PROBE_INTERVAL_SECONDS=5)
if [[ $rc == 0 ]] || ! rolled_back; then die "a neighbour that broke as the upgrade ended was missed: $(out end)"; fi
# ...one differing round is a neighbour's own hiccup: no rollback.
rm -f "$WORK/calls.log" "$WORK/broken"
: >"$WORK/calls.log"
touch "$WORK/hiccup"
rc=0
PATH="$WORK/bin:$PATH" run STUB_UPGRADE=fail >"$WORK/hiccup.out" 2>&1 || rc=$?
rm -f "$WORK/hiccup"
if called '^helm .* rollback '; then
	die "one differing probe round rolled the release back: $(out hiccup)"
fi
grep -q 'PASS  3 neighbour probes unchanged by the upgrade' "$WORK/hiccup.out" \
	|| die "after a one-round hiccup the neighbours are not reported unchanged: $(out hiccup)"
grep -q 'FAIL  helm upgrade with gatewayIngress' "$WORK/hiccup.out" || die "a failed upgrade is not reported: $(out hiccup)"

# 5. Nothing is changed when the run cannot be undone or watched.
unchanged() { ! called '^helm upgrade ' && ! called '^kubectl .* delete '; }
rc=$(stubbed failed-revision STUB_HISTORY=failed)
if [[ $rc == 0 ]] || ! unchanged; then die "the release was upgraded on top of a failed revision: $(cat "$WORK/calls.log")"; fi
grep -q 'not deployed' "$WORK/failed-revision.out" || die "the refusal does not say the latest revision is not deployed: $(out failed-revision)"
rc=$(stubbed unreachable OSH_NEIGHBOUR_URLS="$UNREACHABLE")
if [[ $rc == 0 ]] || ! unchanged; then die "the release was upgraded with a neighbour that cannot be watched: $(cat "$WORK/calls.log")"; fi
rc=$(stubbed deny-tcp OSH_POLICY_ACTION=DENY STUB_GATEWAYS=tcp)
if [[ $rc == 0 ]] || ! unchanged; then die "DENY policies were installed on an ingress gateway with TCP servers: $(cat "$WORK/calls.log")"; fi
grep -q 'apps/db-gateway port 5432 (TCP)' "$WORK/deny-tcp.out" || die "the refusal does not name the TCP server: $(out deny-tcp)"
rc=$(stubbed allow-tcp STUB_GATEWAYS=tcp STUB_UPGRADE=fail)
called '^helm upgrade ' || die "ALLOW policies were refused because of TCP servers, which they do not touch: $(out allow-tcp)"

# 6. The gateway's certificate.
rc=$(stubbed old-pki STUB_PKI=old)
if [[ $rc == 0 ]] || ! unchanged; then die "a release with a certificate from before 0.10.0 was changed: $(cat "$WORK/calls.log")"; fi
grep -q 'OSH_REGENERATE_PKI=1' "$WORK/old-pki.out" || die "the refusal does not name OSH_REGENERATE_PKI: $(out old-pki)"
rc=$(stubbed regenerate STUB_PKI=old OSH_REGENERATE_PKI=1 STUB_UPGRADE=fail)
delete='^kubectl -n openshell-system delete secret --ignore-not-found ods-openshell-driver-kyma-server-tls ods-openshell-driver-kyma-client-tls ods-openshell-driver-kyma-jwt-keys$'
called "$delete" || die "the three PKI Secrets were not deleted: $(cat "$WORK/calls.log")"
order=$(grep -n -E '^helm .* history |^kubectl .* delete secret |^helm upgrade ' "$WORK/calls.log" | cut -d: -f2 | awk '{ print $1 "-" ($2 == "-n" ? $4 : $2) }' | tr '\n' ' ')
[[ $order == "helm-history kubectl-delete helm-upgrade " ]] \
	|| die "the PKI must be deleted after the way back is known and before the upgrade, got: $order"
rc=$(stubbed unreadable STUB_PKI=unreadable OSH_REGENERATE_PKI=1)
if [[ $rc == 0 ]] || ! unchanged; then die "a certificate that could not be read was treated as an old one: $(cat "$WORK/calls.log")"; fi
rc=$(stubbed no-history STUB_PKI=old OSH_REGENERATE_PKI=1 STUB_HISTORY=error)
if [[ $rc == 0 ]] || ! unchanged; then die "the PKI was deleted although the release's history could not be read: $(cat "$WORK/calls.log")"; fi

# 7. The servers of the ingress gateway that are not HTTP.
servers() { env PATH="$WORK/bin:$PATH" "$@" "$DIR/ingress-non-http-servers.sh"; }
[[ -z $(servers) ]] || die "HTTP and HTTPS servers, and another gateway's, were reported: $(servers)"
rc=0
found=$(servers STUB_GATEWAYS=tcp) || rc=$?
want="apps/db-gateway port 5432 (TCP)
apps/passthrough port 443 (HTTPS, PASSTHROUGH)"
[[ $rc == 1 && $found == "$want" ]] || die "exit $rc, servers that are not HTTP: $found"
mkdir "$WORK/no-cluster"
printf '#!/bin/sh\nexit 1\n' >"$WORK/no-cluster/kubectl"
chmod +x "$WORK/no-cluster/kubectl"
rc=0
env PATH="$WORK/no-cluster:$PATH" "$DIR/ingress-non-http-servers.sh" >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || die "without a working kubectl the script must fail closed with status 2, got $rc"

# 8. A forgeable source-address fence.
fence() { env OSH_FENCE_ONLY=1 OSH_FENCE_URL="$1" "$SCRIPT"; }
fence "${FENCED}0" >/dev/null || die "a fence that ignores X-Forwarded-For was reported as forgeable"
for hops in 1 2 3; do
	if fence "${FENCED}$hops" >"$WORK/fence" 2>&1; then
		die "an ingress gateway that trusts $hops forwarding hop(s) was not detected: $(cat "$WORK/fence")"
	fi
	grep -q 'X-Forwarded-For' "$WORK/fence" || die "the report does not name X-Forwarded-For: $(cat "$WORK/fence")"
done
rc=$(stubbed forgeable OSH_NEIGHBOUR_URLS="${FENCED}2")
if [[ $rc == 0 ]] || ! unchanged; then die "service hosts were published behind a forgeable fence: $(cat "$WORK/calls.log")"; fi
grep -q 'X-Forwarded-For' "$WORK/forgeable.out" || die "the refusal does not name X-Forwarded-For: $(out forgeable)"

echo "REMOTE_ACCESS_SELFTEST_OK"
