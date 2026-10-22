#!/usr/bin/env bash
# Render the chart and assert its parity with upstream OpenShell's Helm chart
# (the 0.11.0 parity release; spec docs/superpowers/specs/2026-10-21-chart-parity-0110-design.md):
#   1. the gateway TOML, rendered from one dict by the serializer ported from
#      upstream's _toml.tpl, parses with tomllib to exactly the tables and keys the
#      hand-written template rendered before it (golden: defaults, and every
#      setting that adds or changes a table).
#   2. gatewayConfig, upstream's TOML passthrough: merged with the chart's tables
#      (chart values fill only absent keys), with upstream's secret-boundary guards
#      and the chart-owned tables and keys refused.
# Every render goes through `try`: a case whose EXPECT is empty must render, any
# other must fail the render with EXPECT in its error text.
# check-chart-render.sh keeps the driver's configuration surface; new chart
# assertions go here.
# Needs helm and uv (Python 3.12 with PyYAML).
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
CHART="$ROOT/deploy/helm/openshell-driver-kyma"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# render_as RELEASE [helm args...]. The in-pod gateway runs in every render, with
# what it needs to work: its Service, which sandboxes dial, and sandbox JWT.
render_as() {
	local release=$1
	shift
	helm template "$release" "$CHART" --set gateway.enabled=true --set gateway.sandboxJwt.enabled=true \
		--set gatewayService.enabled=true "$@"
}

# try NAME EXPECT RELEASE [helm args...]: render, and keep the output, the error
# text, the exit status and the text a failing render must contain (EXPECT) for
# the checks below. A render that fails is data here, not an error.
try() {
	local name=$1 expect=$2 release=$3 rc=0
	shift 3
	render_as "$release" "$@" >"$WORK/$name.yaml" 2>"$WORK/$name.err" || rc=$?
	printf '%s' "$rc" >"$WORK/$name.rc"
	printf '%s' "$expect" >"$WORK/$name.expect"
}

# 1. The gateway TOML: defaults, and every setting that adds or changes a table.
try good-p1-defaults '' t
try good-p1-full '' t --set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=osh-client \
	--set gateway.ocsfLog.enabled=true --set gateway.grpcRateLimit.requests=120 \
	--set gateway.grpcRateLimit.windowSeconds=60 \
	--set-json 'driver.resourceAdmission.requiredLabels={"example.com/team":"a"}'

# 3. Gateway name, policy validation mode, loopback service HTTP and WebSocket tunnel.
try good-p3-values '' t --set gateway.name=gw1 --set gateway.policyValidationFailureMode=retain_last_valid \
	--set gateway.enableLoopbackServiceHttp=false --set gateway.enableWebsocketTunnel=true
try good-p3-driver-name '' t --set driver.gatewayName=other
try bad-p3-mode 'gateway.policyValidationFailureMode must be fail_closed or retain_last_valid' t \
	--set gateway.policyValidationFailureMode=open
try bad-p3-websocket-string 'gateway.enableWebsocketTunnel must be a boolean' t \
	--set-string gateway.enableWebsocketTunnel=true
try bad-p3-loopback-string 'gateway.enableLoopbackServiceHttp must be a boolean' t \
	--set-string gateway.enableLoopbackServiceHttp=false
try bad-p3-empty-name 'gateway.name must not be empty' t --set-string 'gateway.name= '

# 4. Telemetry (off by default, gateway only) and the gateway's OTLP export.
try good-p4-telemetry-on '' t --set gateway.telemetryEnabled=true
try good-p4-otlp '' t --set gateway.otlp.endpoint=http://otel.example.org:4318 --set gateway.otlp.serviceName=osh-gw
try good-p4-otlp-no-name '' t --set gateway.otlp.endpoint=http://otel.example.org:4318
try good-p4-otlp-driver-override '' t --set gateway.otlp.endpoint=http://otel.example.org:4318 \
	--set driver.otlpEndpoint=http://other.example.org:4317
try bad-p4-telemetry-string 'gateway.telemetryEnabled must be a boolean' t \
	--set-string gateway.telemetryEnabled=false

# 5. OIDC JWKS TTL, scopes claim, allowed origins, insecure HTTP and issuer CA.
OIDC5=(--set gateway.oidc.issuer=https://issuer.example.org --set gateway.oidc.audience=a)
try good-p5-default "" t "${OIDC5[@]}"
try good-p5-oidc '' t "${OIDC5[@]}" --set gateway.oidc.jwksTtl=600 --set gateway.oidc.scopesClaim=scp \
	--set 'gateway.oidc.jwksAllowedOrigins={https://keys.example.org,https://k2.example.org}' \
	--set gateway.oidc.dangerouslyAllowInsecureHttp=true
try good-p5-oidc-ca '' t "${OIDC5[@]}" --set gateway.oidc.caConfigMapName=issuer-ca
try good-p5-ca-no-issuer '' t --set gateway.oidc.caConfigMapName=issuer-ca

# 7. Pod plumbing: SA annotations, grace period, probe timings, host aliases, JWT Secret mode.
try good-p7 '' t --set serviceAccount.annotations.a=b --set sandboxServiceAccount.annotations.c=d \
	--set gateway.terminationGracePeriodSeconds=60 --set gateway.probes.liveness.periodSeconds=20 \
	--set-string gateway.sandboxJwt.secretDefaultMode=0440 --set driver.hostGatewayIp=10.0.0.1
try good-p7-tls '' t --set gateway.tls.enabled=true
try good-p7-int-mode '' t --set gateway.sandboxJwt.secretDefaultMode=288
try good-p7-probes '' t --set gateway.probes.startup.failureThreshold=5 --set gateway.probes.readiness.periodSeconds=7
MODE_ERR='gateway.sandboxJwt.secretDefaultMode must be an octal string like "0440" or an integer from 1 to 511'
try bad-p7-mode-abc "$MODE_ERR" t --set-string gateway.sandboxJwt.secretDefaultMode=abc
try bad-p7-mode-440 "$MODE_ERR" t --set-string gateway.sandboxJwt.secretDefaultMode=440
try bad-p7-mode-0999 "$MODE_ERR" t --set-string gateway.sandboxJwt.secretDefaultMode=0999
try bad-p7-mode-zero "$MODE_ERR" t --set gateway.sandboxJwt.secretDefaultMode=0
try bad-p7-mode-too-big "$MODE_ERR" t --set gateway.sandboxJwt.secretDefaultMode=512
try bad-p7-mode-float "$MODE_ERR" t --set gateway.sandboxJwt.secretDefaultMode=1.5
try bad-p7-mode-float-string "$MODE_ERR" t --set-string gateway.sandboxJwt.secretDefaultMode=1.5
try bad-p5-ttl 'gateway.oidc.jwksTtl must be greater than zero' t "${OIDC5[@]}" --set gateway.oidc.jwksTtl=0
try bad-p5-origin-path 'gateway.oidc.jwksAllowedOrigins entries must not include a path or query' t "${OIDC5[@]}" \
	--set 'gateway.oidc.jwksAllowedOrigins={https://k.example.org/path}'
try bad-p5-insecure-string 'gateway.oidc.dangerouslyAllowInsecureHttp must be a boolean' t "${OIDC5[@]}" \
	--set-string gateway.oidc.dangerouslyAllowInsecureHttp=false
try bad-p5-extra-ttl 'gateway.extraArgs sets --oidc-jwks-ttl; use gateway.oidc.jwksTtl instead' t "${OIDC5[@]}" \
	--set-json 'gateway.extraArgs=["--oidc-jwks-ttl=5"]'
try bad-p5-extra-scopes 'gateway.extraArgs sets --oidc-scopes-claim; use gateway.oidc.scopesClaim instead' t "${OIDC5[@]}" \
	--set-json 'gateway.extraArgs=["--oidc-scopes-claim","scp"]'

# 6. mTLS-only authentication: a client CA without OIDC requires the certificate.
TLS6=(--set gateway.tls.enabled=true --set gateway.tls.clientCa.enabled=true)
try good-p6-mtls '' t "${TLS6[@]}"
try good-p6-explicit-false '' t --set gateway.auth.allowUnauthenticatedUsers=false
try bad-p6-ca-true 'gateway.auth.allowUnauthenticatedUsers=true would admit callers without a client certificate; remove it to require the certificate' t \
	"${TLS6[@]}" --set gateway.auth.allowUnauthenticatedUsers=true
try bad-p6-ca-config-true 'gatewayConfig openshell.gateway.auth.allow_unauthenticated_users=true would admit callers without a client certificate; remove it to require the certificate' t \
	"${TLS6[@]}" --set-json 'gatewayConfig={"openshell.gateway.auth":{"allow_unauthenticated_users":true}}'

try bad-p6-extra-ca 'gateway.extraArgs sets --tls-client-ca; use gateway.tls.clientCa instead' t \
	--set gateway.tls.enabled=true --set-json 'gateway.extraArgs=["--tls-client-ca=/x"]'
try bad-p6-extra-cert 'gateway.extraArgs sets --tls-cert; use gateway.tls.enabled instead' t \
	--set-json 'gateway.extraArgs=["--tls-cert","/x"]'
try bad-p6-extra-disable 'gateway.extraArgs sets --disable-tls; use gateway.tls.enabled instead' t \
	--set-json 'gateway.extraArgs=["--disable-tls"]'
try good-p6-ca-no-tls '' t --set gateway.tls.clientCa.enabled=true
try good-p6-ca-no-tls-true '' t --set gateway.tls.clientCa.enabled=true --set gateway.auth.allowUnauthenticatedUsers=true
try good-p6-oidc-mtls '' t "${TLS6[@]}" "${OIDC5[@]}"
try bad-p6-ca-nested-true 'gatewayConfig openshell.gateway.auth.allow_unauthenticated_users=true would admit callers without a client certificate' t \
	"${TLS6[@]}" --set-json 'gatewayConfig={"openshell":{"gateway":{"auth":{"allow_unauthenticated_users":true}}}}'

# 2. gatewayConfig: merged, nested, arrays of tables; then each refusal.
try good-p2-merge '' t --set-json 'gatewayConfig={"openshell.gateway":{"policy_validation_failure_mode":"retain_last_valid"},"openshell.gateway.auth":{"allow_unauthenticated_users":false}}'
try good-p2-nested '' t --set-json 'gatewayConfig={"openshell":{"gateway":{"ssh_session_ttl_secs":600}}}'
try good-p2-array-tables '' t --set-json 'gatewayConfig={"openshell.supervisor.middleware":[{"name":"m1","url":"http://m1.example.org"}]}'
# Header split so secret scanners don't flag the fixture; it holds no key material.
pem_header='-----BEGIN '"PRIVATE KEY-----"
try bad-p2-private-key 'gatewayConfig must not contain an inline private key' t \
	--set-json "gatewayConfig={\"openshell.gateway\":{\"x\":\"${pem_header}\"}}"
try bad-p2-url-credentials 'gatewayConfig must not contain inline URL credentials' t \
	--set-json 'gatewayConfig={"openshell.gateway":{"x":"http://u:p@h"}}'
try bad-p2-database-url 'gatewayConfig must not contain database_url' t \
	--set-json 'gatewayConfig={"openshell.gateway":{"database_url":"sqlite:///x.db"}}'
try bad-p2-nested-and-dotted 'both as a nested map and a dotted top-level table' t \
	--set-json 'gatewayConfig={"openshell":{"gateway":{"a":1}},"openshell.gateway":{"b":2}}'
try bad-p2-kyma 'gatewayConfig must not set openshell.drivers.kyma' t \
	--set-json 'gatewayConfig={"openshell.drivers.kyma":{"socket_path":"/x"}}'
try bad-p2-kubernetes "gatewayConfig must not set openshell.drivers.kubernetes; this chart's driver is configured by environment (driver.* values)" t \
	--set-json 'gatewayConfig={"openshell.drivers.kubernetes":{"namespace":"x"}}'
try bad-p2-tls 'gatewayConfig must not set openshell.gateway.tls' t \
	--set-json 'gatewayConfig={"openshell.gateway.tls":{"cert_path":"/x"}}'
try bad-p2-bind-address 'gatewayConfig must not set openshell.gateway.bind_address' t \
	--set-json 'gatewayConfig={"openshell.gateway":{"bind_address":"0.0.0.0"}}'
try bad-p2-server-sans 'gatewayConfig must not set openshell.gateway.server_sans; it is chart-owned (use gateway.sandboxJwt.serverDnsNames instead)' t \
	--set-json 'gatewayConfig={"openshell.gateway":{"server_sans":["a"]}}'

uv run --quiet --no-project --python 3.12 --with pyyaml==6.0.2 python - "$WORK" "$CHART" <<'PY'
import pathlib, sys, tomllib
import yaml

work, chart = (pathlib.Path(a) for a in sys.argv[1:3])
failures = []

def first_line(text):
    return " ".join(text.split())[:240]

# Every case: an empty EXPECT must render; any other must fail, naming EXPECT.
cases = sorted(p.stem for p in work.glob("*.rc"))
if not cases:
    failures.append("no cases were rendered")
for name in cases:
    rc = (work / f"{name}.rc").read_text()
    expect = (work / f"{name}.expect").read_text()
    err = (work / f"{name}.err").read_text()
    if not expect and rc != "0":
        failures.append(f"{name}: expected the render to succeed, it failed: " + first_line(err))
    elif expect and rc == "0":
        failures.append(f"{name}: rendered, but it must fail naming {expect!r}")
    elif expect and expect not in err:
        failures.append(f"{name}: failed the render without naming {expect!r}: " + first_line(err))

def docs(name):
    """The documents of a render; none when it failed (the loop above recorded why)."""
    if (work / f"{name}.rc").read_text() != "0":
        return []
    return [d for d in yaml.safe_load_all((work / f"{name}.yaml").read_text()) if d]

def pod_spec(name):
    """The pod spec of the Deployment that runs the driver."""
    for d in docs(name):
        if d.get("kind") == "Deployment" and any(
                c["name"] == "driver" for c in d["spec"]["template"]["spec"]["containers"]):
            return d["spec"]["template"]["spec"]
    failures.append(f"{name}: no Deployment with a driver container was rendered")
    return {"containers": []}

def container(name, container_name):
    found = next((c for c in pod_spec(name)["containers"] if c["name"] == container_name), None)
    if found is None:
        failures.append(f"{name}: no {container_name} container was rendered")
        return {}
    return found

def gateway_container(name):
    return container(name, "gateway")

def driver_container(name):
    return container(name, "driver")

def env_of(c):
    """name -> env entry of a container."""
    return {e["name"]: e for e in c.get("env", [])}

def gateway_toml(name):
    """The gateway TOML of a render, parsed with tomllib."""
    cm = next((d for d in docs(name) if d.get("kind") == "ConfigMap"
               and d["metadata"]["name"].endswith("-gateway-config")), None)
    if cm is None:
        failures.append(f"{name}: no gateway ConfigMap was rendered")
        return {}
    try:
        return tomllib.loads(cm["data"]["gateway.toml"])
    except tomllib.TOMLDecodeError as e:
        failures.append(f"{name}: the gateway TOML does not parse: {e}")
        return {}

def flatten(table, prefix=""):
    """{dotted table: {scalar keys}}; nested tables become their own dotted entries."""
    out = {}
    scalars = {k: v for k, v in table.items() if not isinstance(v, dict)}
    if prefix and (scalars or not any(isinstance(v, dict) for v in table.values())):
        out[prefix] = scalars
    for k, v in table.items():
        if isinstance(v, dict):
            out.update(flatten(v, f"{prefix}.{k}" if prefix else k))
    return out

def diff(got, want):
    lines = []
    for table in sorted(set(got) | set(want)):
        if got.get(table) != want.get(table):
            lines.append(f"[{table}] is {got.get(table)}, want {want.get(table)}")
    return "; ".join(lines)

# 1. The gateway TOML, as the hand-written template rendered it before the serializer.
GOLDEN_DEFAULT = {
    "openshell": {"version": 2},
    "openshell.gateway": {
        "log_level": "info", "name": "t-openshell-driver-kyma",
        "policy_validation_failure_mode": "fail_closed",
        "enable_loopback_service_http": True, "enable_websocket_tunnel": False},
    "openshell.gateway.auth": {"allow_unauthenticated_users": True},
    "openshell.gateway.credential_storage": {
        "key_encryption_key_env": "OPENSHELL_GATEWAY_CREDENTIAL_KEY_ENCRYPTION_KEY"},
    "openshell.gateway.gateway_jwt": {
        "signing_key_path": "/etc/openshell-jwt/signing.pem",
        "public_key_path": "/etc/openshell-jwt/public.pem", "kid_path": "/etc/openshell-jwt/kid",
        "gateway_id": "t-openshell-driver-kyma", "ttl_secs": 3600},
    "openshell.drivers.kyma": {"socket_path": "/var/run/openshell/driver.sock", "allow_driver_config": False},
    # requiredLabels: null renders no required_labels table (upstream's built-in labels apply).
    "openshell.drivers.kyma.resource_admission": {"enabled": True},
}
GOLDEN_FULL = {
    **GOLDEN_DEFAULT,
    "openshell.gateway": {**GOLDEN_DEFAULT["openshell.gateway"], "grpc_rate_limit_requests": 120,
                          "grpc_rate_limit_window_seconds": 60},
    "openshell.gateway.auth": {"allow_unauthenticated_users": False},
    "openshell.gateway.ocsf_log": {"path": "/tmp/gateway-ocsf.jsonl", "rotation": "daily", "max_files": 7,
                                   "queue_capacity": 10000, "queue_max_bytes": 16777216},
    "openshell.drivers.kyma.resource_admission.required_labels": {"example.com/team": "a"},
}
for name, want in (("good-p1-defaults", GOLDEN_DEFAULT), ("good-p1-full", GOLDEN_FULL)):
    got = flatten(gateway_toml(name))
    if got != want:
        failures.append(f"{name}: the gateway TOML differs from the golden: {diff(got, want)}")

# 3. The gateway name, and the four settings: values reach the TOML; the driver's env follows.
p3 = gateway_toml("good-p3-values").get("openshell", {}).get("gateway", {})
want_p3 = {"name": "gw1", "policy_validation_failure_mode": "retain_last_valid",
           "enable_loopback_service_http": False, "enable_websocket_tunnel": True}
if {k: p3.get(k) for k in want_p3} != want_p3:
    failures.append(f"good-p3-values: the gateway table has {p3}, want {want_p3}")
for case, want in (("good-p3-values", "gw1"), ("good-p1-defaults", "t-openshell-driver-kyma"),
                   ("good-p3-driver-name", "other")):
    got = env_of(driver_container(case)).get("OPENSHELL_GATEWAY_NAME", {}).get("value")
    if got != want:
        failures.append(f"{case}: the driver's OPENSHELL_GATEWAY_NAME is {got!r}, want {want!r}")
got = gateway_toml("good-p3-driver-name").get("openshell", {}).get("gateway", {}).get("name")
if got != "t-openshell-driver-kyma":
    failures.append(f"good-p3-driver-name: the TOML name is {got!r}, want 't-openshell-driver-kyma'")

# 4. Telemetry: always rendered on the gateway, never on the driver; the OTLP table and egress.
def telemetry_env(case):
    return env_of(gateway_container(case)).get("OPENSHELL_TELEMETRY_ENABLED")

for case, want in (("good-p1-defaults", "false"), ("good-p4-telemetry-on", "true")):
    got = telemetry_env(case)
    if got != {"name": "OPENSHELL_TELEMETRY_ENABLED", "value": want}:
        failures.append(f"{case}: the gateway's OPENSHELL_TELEMETRY_ENABLED is {got!r}, want {want!r}")
    if "OPENSHELL_TELEMETRY_ENABLED" in env_of(driver_container(case)):
        failures.append(f"{case}: the driver container must not get OPENSHELL_TELEMETRY_ENABLED")

def otlp_table(case):
    return gateway_toml(case).get("openshell", {}).get("gateway", {}).get("otlp")

def pod_egress_ports(case):
    for d in docs(case):
        if d.get("kind") == "NetworkPolicy" and d["metadata"]["name"].endswith("-driver"):
            return sorted(p["port"] for r in d["spec"]["egress"] for p in r.get("ports", [])
                          if p.get("protocol") == "TCP")
    return None

if otlp_table("good-p1-defaults") is not None:
    failures.append(f"good-p1-defaults: unexpected [openshell.gateway.otlp]: {otlp_table('good-p1-defaults')}")
if otlp_table("good-p4-telemetry-on") is not None:
    failures.append("good-p4-telemetry-on: telemetry alone must not write an otlp table")
endpoint = "http://otel.example.org:4318"
for case, want_table in (("good-p4-otlp", {"endpoint": endpoint, "service_name": "osh-gw"}),
                         ("good-p4-otlp-no-name", {"endpoint": endpoint}),
                         ("good-p4-otlp-driver-override", {"endpoint": endpoint})):
    if otlp_table(case) != want_table:
        failures.append(f"{case}: the otlp table is {otlp_table(case)!r}, want {want_table!r}")
for case, want in (("good-p1-defaults", None), ("good-p4-otlp", endpoint),
                   ("good-p4-otlp-driver-override", "http://other.example.org:4317")):
    got = env_of(driver_container(case)).get("OPENSHELL_OTLP_ENDPOINT", {}).get("value")
    if got != want:
        failures.append(f"{case}: the driver's OPENSHELL_OTLP_ENDPOINT is {got!r}, want {want!r}")
for case, ports in (("good-p4-otlp", [443, 4318]), ("good-p4-otlp-driver-override", [443, 4317, 4318])):
    got = pod_egress_ports(case)
    if got is None or not set(ports) <= set(got):
        failures.append(f"{case}: the pod NetworkPolicy egress ports are {got!r}, want {ports!r} among them")

# 6. mTLS-only authentication.
p6 = gateway_toml("good-p6-mtls").get("openshell", {}).get("gateway", {}).get("auth")
if p6 != {"allow_unauthenticated_users": False}:
    failures.append(f"good-p6-mtls: the auth table is {p6!r}, want allow_unauthenticated_users = False")
if any(a.startswith("--enable-mtls-auth") for a in gateway_container("good-p6-mtls").get("args", [])):
    failures.append("good-p6-mtls: the chart must not pass --enable-mtls-auth (the gateway enables it itself)")
p6 = gateway_toml("good-p6-explicit-false").get("openshell", {}).get("gateway", {}).get("auth")
if p6 != {"allow_unauthenticated_users": False}:
    failures.append(f"good-p6-explicit-false: the auth table is {p6!r}, want allow_unauthenticated_users = False")

def p6_allow(case):
    return gateway_toml(case).get("openshell", {}).get("gateway", {}).get("auth", {}).get("allow_unauthenticated_users")

for case, want in (("good-p6-ca-no-tls", True), ("good-p6-ca-no-tls-true", True), ("good-p6-oidc-mtls", False)):
    if p6_allow(case) is not want:
        failures.append(f"{case}: allow_unauthenticated_users is {p6_allow(case)!r}, want {want!r}")

# 2. gatewayConfig merged into the chart's tables, each table rendered once.
def gateway_toml_text(name):
    cm = next((d for d in docs(name) if d.get("kind") == "ConfigMap"
               and d["metadata"]["name"].endswith("-gateway-config")), None)
    return cm["data"]["gateway.toml"] if cm else ""

merged = gateway_toml("good-p2-merge")
gw = merged.get("openshell", {}).get("gateway", {})
if gw.get("policy_validation_failure_mode") != "retain_last_valid":
    failures.append("good-p2-merge: openshell.gateway.policy_validation_failure_mode is "
                    f"{gw.get('policy_validation_failure_mode')!r}, want 'retain_last_valid'")
if gw.get("log_level") != "info":
    failures.append(f"good-p2-merge: the chart's log_level was lost from the merged table: {gw}")
if gw.get("auth", {}).get("allow_unauthenticated_users") is not False:
    failures.append("good-p2-merge: openshell.gateway.auth.allow_unauthenticated_users is "
                    f"{gw.get('auth', {}).get('allow_unauthenticated_users')!r}, want False")
text = gateway_toml_text("good-p2-merge")
for header in ("[openshell.gateway]", "[openshell.gateway.auth]"):
    count = sum(1 for line in text.splitlines() if line == header)
    if count != 1:
        failures.append(f"good-p2-merge: {header} appears {count} times, want 1")

nested = gateway_toml("good-p2-nested")
if nested.get("openshell", {}).get("gateway", {}).get("ssh_session_ttl_secs") != 600:
    failures.append("good-p2-nested: openshell.gateway.ssh_session_ttl_secs is not 600: "
                    f"{nested.get('openshell', {}).get('gateway')}")
if nested.get("openshell", {}).get("version") != 2:
    failures.append(f"good-p2-nested: openshell.version is not 2: {nested.get('openshell')}")

arrays = gateway_toml("good-p2-array-tables")
middleware = arrays.get("openshell", {}).get("supervisor", {}).get("middleware")
if middleware != [{"name": "m1", "url": "http://m1.example.org"}]:
    failures.append(f"good-p2-array-tables: openshell.supervisor.middleware is {middleware!r}")

# 5. OIDC extras and the issuer CA.
def gw_args(case):
    return gateway_container(case).get("args", [])

args = gw_args("good-p5-oidc")
for want in ("--oidc-jwks-ttl=600", "--oidc-scopes-claim=scp",
             "--oidc-jwks-allowed-origins=https://keys.example.org,https://k2.example.org",
             "--oidc-dangerously-allow-insecure-http=true"):
    if want not in args:
        failures.append(f"good-p5-oidc: gateway args lack {want}: {args}")
args = gw_args("good-p5-default")
if "--oidc-jwks-ttl=3600" not in args:
    failures.append(f"good-p5-default: gateway args lack --oidc-jwks-ttl=3600: {args}")
for flag in ("--oidc-scopes-claim", "--oidc-jwks-allowed-origins", "--oidc-dangerously-allow-insecure-http"):
    if any(a.startswith(flag) for a in args):
        failures.append(f"good-p5-default: gateway args carry {flag}: {args}")

CA_DIR = "/etc/openshell-tls/oidc-ca"
def ca_state(case):
    spec = pod_spec(case)
    gw = gateway_container(case)
    return (env_of(gw).get("SSL_CERT_FILE", {}).get("value"),
            [m for m in gw.get("volumeMounts", []) if m["name"] == "oidc-ca"],
            [v for v in spec.get("volumes", []) if v["name"] == "oidc-ca"])

env_v, mounts, vols = ca_state("good-p5-oidc-ca")
if env_v != CA_DIR + "/ca.crt":
    failures.append(f"good-p5-oidc-ca: SSL_CERT_FILE is {env_v!r}")
if mounts != [{"name": "oidc-ca", "mountPath": CA_DIR, "readOnly": True}]:
    failures.append(f"good-p5-oidc-ca: oidc-ca mounts are {mounts}")
if vols != [{"name": "oidc-ca", "configMap": {"name": "issuer-ca"}}]:
    failures.append(f"good-p5-oidc-ca: oidc-ca volumes are {vols}")
if ca_state("good-p5-ca-no-issuer") != (None, [], []):
    failures.append(f"good-p5-ca-no-issuer: CA wiring rendered without an issuer: {ca_state('good-p5-ca-no-issuer')}")
if ca_state("good-p5-default") != (None, [], []):
    failures.append("good-p5-default: CA wiring rendered without caConfigMapName")

# 7. Pod plumbing.
GW_PROBES = {
    "startupProbe": {"httpGet": {"path": "/healthz", "port": "gw-health"},
                     "periodSeconds": 2, "timeoutSeconds": 1, "failureThreshold": 30},
    "livenessProbe": {"httpGet": {"path": "/healthz", "port": "gw-health"},
                      "initialDelaySeconds": 2, "periodSeconds": 5, "timeoutSeconds": 1, "failureThreshold": 3},
    "readinessProbe": {"httpGet": {"path": "/readyz", "port": "gw-health"},
                       "initialDelaySeconds": 1, "periodSeconds": 2, "timeoutSeconds": 1, "failureThreshold": 3},
}
DRIVER_PROBES = {
    "livenessProbe": {"httpGet": {"path": "/healthz", "port": "health"},
                      "initialDelaySeconds": 5, "periodSeconds": 10, "timeoutSeconds": 3, "failureThreshold": 3},
}

def mode_of(case, volume):
    return next((v["secret"].get("defaultMode") for v in pod_spec(case).get("volumes", [])
                 if v["name"] == volume), "no such volume")

def service_accounts(case):
    return {d["metadata"]["name"]: d["metadata"].get("annotations")
            for d in docs(case) if d.get("kind") == "ServiceAccount"}

for case in ("good-p7", "good-p7-tls", "good-p7-int-mode"):
    spec = pod_spec(case)
    gw = gateway_container(case)
    want = {k: dict(v) for k, v in GW_PROBES.items()}
    if case == "good-p7":
        want["livenessProbe"]["periodSeconds"] = 20
    for key, probe in want.items():
        if gw.get(key) != probe:
            failures.append(f"{case}: gateway {key} is {gw.get(key)}, want {probe}")
    drv = driver_container(case)
    if drv.get("livenessProbe") != DRIVER_PROBES["livenessProbe"]:
        failures.append(f"{case}: driver livenessProbe changed: {drv.get('livenessProbe')}")
    if "startupProbe" in drv:
        failures.append(f"{case}: driver gained a startupProbe")
    grace = spec.get("terminationGracePeriodSeconds")
    if grace != (60 if case == "good-p7" else 30):
        failures.append(f"{case}: terminationGracePeriodSeconds is {grace}")
    want_mode = 288 if case in ("good-p7", "good-p7-int-mode") else 256
    if mode_of(case, "sandbox-jwt") != want_mode:
        failures.append(f"{case}: sandbox-jwt defaultMode is {mode_of(case, 'sandbox-jwt')}, want {want_mode}")
    if case == "good-p7-tls" and mode_of(case, "gateway-tls") != 256:
        failures.append(f"{case}: gateway-tls defaultMode is {mode_of(case, 'gateway-tls')}, want 256")
    aliases = spec.get("hostAliases")
    want_aliases = ([{"ip": "10.0.0.1", "hostnames": ["host.docker.internal", "host.openshell.internal"]}]
                    if case == "good-p7" else None)
    if aliases != want_aliases:
        failures.append(f"{case}: hostAliases is {aliases}, want {want_aliases}")
probes = gateway_container("good-p7-probes")
for key, field, value in (("startupProbe", "failureThreshold", 5), ("readinessProbe", "periodSeconds", 7)):
    want = {**GW_PROBES[key], field: value}
    if probes.get(key) != want:
        failures.append(f"good-p7-probes: gateway {key} is {probes.get(key)}, want {want}")

for case, want in (("good-p7", ({"a": "b"}, {"c": "d"})), ("good-p7-tls", (None, None))):
    sas = service_accounts(case)
    got = (sas.get("openshell-driver"), sas.get("openshell-sandbox"))
    if got != want:
        failures.append(f"{case}: driver and sandbox service account annotations are {got}, want {want}")

if failures:
    print("CHART_PARITY_FAIL:")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("CHART_PARITY_OK")
PY
