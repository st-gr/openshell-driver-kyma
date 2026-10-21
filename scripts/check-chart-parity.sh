#!/usr/bin/env bash
# Render the chart and assert its parity with upstream OpenShell's Helm chart
# (the 0.11.0 parity release; spec docs/superpowers/specs/2026-10-21-chart-parity-0110-design.md):
#   1. the gateway TOML, rendered from one dict by the serializer ported from
#      upstream's _toml.tpl, parses with tomllib to exactly the tables and keys the
#      hand-written template rendered before it (golden: defaults, and every
#      setting that adds or changes a table).
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
    "openshell.gateway": {"log_level": "info"},
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
    "openshell.gateway": {"log_level": "info", "grpc_rate_limit_requests": 120,
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

if failures:
    print("CHART_PARITY_FAIL:")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("CHART_PARITY_OK")
PY
