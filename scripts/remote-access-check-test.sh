#!/usr/bin/env bash
# Tests for scripts/remote-access-check.sh that need no cluster: the neighbour probes,
# which watch the other applications behind a shared ingress gateway, and the rollback
# they trigger.
#   1. the probes report each neighbour's status without a token, with a foreign JWT and
#      with a Bearer key, and OSH_PROBE_BASELINE detects a change;
#   2. an install run refuses to start without OSH_NEIGHBOUR_URLS;
#   3. the dry run installs gateway TLS and no value of the removed edge token check;
#   4. when a neighbour starts refusing Bearer tokens during the upgrade (what a
#      RequestAuthentication on the ingress gateway does), the script rolls the release
#      back to the revision it found, reports the failure, and goes no further;
#   5. a release whose gateway certificate does not name its Service (every install from
#      before 0.10.0) is not upgraded unless OSH_REGENERATE_PKI=1 says to replace the PKI.
# The neighbour is a local web server; helm, kubectl and openshell are stand-ins for 4 and 5.
# Requires: helm, curl, python3.
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

# The neighbour: answers 200, and 401 to any request with an Authorization header while
# $WORK/broken exists.
cat >"$WORK/neighbour.py" <<'PY'
import http.server, os, sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        broken = os.path.exists(sys.argv[1]) and self.headers.get("Authorization")
        self.send_response(401 if broken else 200)
        self.end_headers()
    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
python3 "$WORK/neighbour.py" "$WORK/broken" >"$WORK/port" &
server_pid=$!
disown "$server_pid"
for _ in $(seq 1 50); do
	[[ -s $WORK/port ]] && break
	sleep 0.1
done
NEIGHBOUR="http://127.0.0.1:$(cat "$WORK/port")/app"

# 1. Probes and baseline comparison.
OSH_PROBE_ONLY=1 OSH_NEIGHBOUR_URLS="$NEIGHBOUR" "$SCRIPT" >"$WORK/baseline"
want="no-token 200 $NEIGHBOUR
foreign-jwt 200 $NEIGHBOUR
bearer-key 200 $NEIGHBOUR"
[[ $(cat "$WORK/baseline") == "$want" ]] || die "the probes of a healthy neighbour are: $(cat "$WORK/baseline")"
OSH_PROBE_ONLY=1 OSH_NEIGHBOUR_URLS="$NEIGHBOUR" OSH_PROBE_BASELINE="$WORK/baseline" "$SCRIPT" >/dev/null \
	|| die "an unchanged neighbour was reported as changed"
touch "$WORK/broken"
if OSH_PROBE_ONLY=1 OSH_NEIGHBOUR_URLS="$NEIGHBOUR" OSH_PROBE_BASELINE="$WORK/baseline" "$SCRIPT" >"$WORK/changed"; then
	die "a neighbour that refuses Bearer tokens was not reported"
fi
grep -q '^NEIGHBOUR_CHANGED$' "$WORK/changed" || die "no NEIGHBOUR_CHANGED line: $(cat "$WORK/changed")"
[[ $(grep -c '^> .* 401 ' "$WORK/changed") == 2 && $(grep -c '^> no-token' "$WORK/changed") == 0 ]] \
	|| die "expected exactly the two Bearer probes to change: $(cat "$WORK/changed")"
rm "$WORK/broken"

# 2 and 3. The values an install run needs, with documentation-only names.
printf 'gateway:\n  enabled: true\n  sandboxJwt:\n    enabled: true\ngatewayService:\n  enabled: true\n' >"$WORK/values.yaml"
run() { # [VAR=value...]: the script with the required variables of an install run
	env KUBECONFIG=/dev/null OSH_DOMAIN=example.org OSH_OIDC_ISSUER=https://issuer.example \
		OSH_OIDC_CLIENT_ID=osh-client OSH_ALLOWED_CIDRS=203.0.113.0/24 OSH_VALUES="$WORK/values.yaml" \
		OSH_AUTH_ONLY=1 "$@" "$SCRIPT"
}
if run >"$WORK/no-neighbours" 2>&1; then
	die "an install run started without OSH_NEIGHBOUR_URLS"
fi
grep -q OSH_NEIGHBOUR_URLS "$WORK/no-neighbours" || die "the refusal does not name OSH_NEIGHBOUR_URLS: $(cat "$WORK/no-neighbours")"
run OSH_DRY_RUN=1 >"$WORK/dry-run"
grep -qx 'gateway.tls.enabled=true' "$WORK/dry-run" || die "the dry run does not install gateway TLS: $(cat "$WORK/dry-run")"
if grep -qi 'jwks' "$WORK/dry-run"; then
	die "the dry run still sets a JWKS value: $(cat "$WORK/dry-run")"
fi

# 4. A neighbour breaks during the upgrade. The helm stand-in breaks it on `upgrade` and
# mends it on `rollback`; it answers `template` with the real helm, which needs no cluster.
REAL_HELM=$(command -v helm)
mkdir "$WORK/bin"
cat >"$WORK/bin/helm" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$WORK/helm.log"
case " \$* " in
*" template "*) exec "$REAL_HELM" "\$@" ;;
*" history "*) echo '[{"revision": 41}]' ;;
*" upgrade "*)
	touch "$WORK/broken"
	sleep 6
	;;
*" rollback "*) rm -f "$WORK/broken" ;;
esac
STUB
cat >"$WORK/bin/kubectl" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$WORK/kubectl.log"
case " \$* " in
*" get deploy "*) printf 'ods-openshell-driver-kyma' ;;
# STUB_OLD_PKI=1: the server TLS Secret exists, with a certificate that names nothing.
*" get secret "*) [[ \${STUB_OLD_PKI:-} == 1 ]] || exit 1 ;;
esac
STUB
cat >"$WORK/bin/openshell" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$WORK/openshell.log"
STUB
chmod +x "$WORK/bin/helm" "$WORK/bin/kubectl" "$WORK/bin/openshell"
if PATH="$WORK/bin:$PATH" run OSH_NEIGHBOUR_URLS="$NEIGHBOUR" OSH_PROBE_INTERVAL_SECONDS=1 \
	OSH_PROBE_RECHECK_SECONDS=1 >"$WORK/run" 2>&1; then
	die "the run passed although a neighbour broke during the upgrade: $(cat "$WORK/run")"
fi
grep -q '^REMOTE_ACCESS_FAIL$' "$WORK/run" || die "no REMOTE_ACCESS_FAIL: $(cat "$WORK/run")"
grep -q 'FAIL  another application behind the ingress gateway answers differently' "$WORK/run" \
	|| die "the failure does not name the neighbours: $(cat "$WORK/run")"
grep -q -- '-n openshell-system rollback ods 41 ' "$WORK/helm.log" \
	|| die "helm was not asked to roll back to revision 41: $(cat "$WORK/helm.log")"
grep -q 'PASS  the neighbours answer as before again' "$WORK/run" \
	|| die "the run does not confirm the neighbours recovered: $(cat "$WORK/run")"
[[ ! -e $WORK/openshell.log ]] || die "the run went on to the CLI checks after the rollback: $(cat "$WORK/openshell.log")"
[[ ! -e $WORK/broken ]] || die "the neighbour is still broken"

# 5. A certificate from before 0.10.0: no upgrade without OSH_REGENERATE_PKI=1, and with
# it the three PKI Secrets are deleted first.
rm -f "$WORK/helm.log" "$WORK/kubectl.log"
if PATH="$WORK/bin:$PATH" STUB_OLD_PKI=1 run OSH_NEIGHBOUR_URLS="$NEIGHBOUR" >"$WORK/old-pki" 2>&1; then
	die "a release with a certificate from before 0.10.0 was upgraded: $(cat "$WORK/old-pki")"
fi
grep -q 'OSH_REGENERATE_PKI=1' "$WORK/old-pki" || die "the refusal does not name OSH_REGENERATE_PKI: $(cat "$WORK/old-pki")"
if grep -q '^upgrade ' "$WORK/helm.log"; then
	die "helm upgrade ran against a certificate no client can verify: $(cat "$WORK/helm.log")"
fi
rm -f "$WORK/helm.log" "$WORK/kubectl.log"
PATH="$WORK/bin:$PATH" STUB_OLD_PKI=1 run OSH_NEIGHBOUR_URLS="$NEIGHBOUR" OSH_REGENERATE_PKI=1 \
	OSH_PROBE_INTERVAL_SECONDS=1 OSH_PROBE_RECHECK_SECONDS=1 >"$WORK/regenerate" 2>&1 || true
grep -q -- 'delete secret --ignore-not-found ods-openshell-driver-kyma-server-tls ods-openshell-driver-kyma-client-tls ods-openshell-driver-kyma-jwt-keys' \
	"$WORK/kubectl.log" || die "the three PKI Secrets were not deleted: $(cat "$WORK/kubectl.log")"
grep -q '^upgrade ' "$WORK/helm.log" || die "no upgrade after the PKI Secrets were deleted: $(cat "$WORK/helm.log")"
rm -f "$WORK/broken"

echo "REMOTE_ACCESS_SELFTEST_OK"
