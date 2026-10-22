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

if failures:
    print("CHART_PARITY_FAIL:")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("CHART_PARITY_OK")
PY
