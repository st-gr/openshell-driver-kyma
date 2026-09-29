#!/usr/bin/env bash
# Render the chart and assert the driver's configuration surface:
#   1. every upstream option (check-upstream-args.sh --print-env) is referenced
#      by the chart templates, so it can be set from values;
#   2. the admission policy the gateway derives from [openshell.drivers.kyma]
#      equals the one the driver acknowledges (OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON),
#      and the driver's gateway id equals the gateway's;
#   3. the driver container takes no command-line args, and removed values are
#      gone from values.yaml;
#   3b. driver.sandboxEnv entries the driver would reject at startup fail at
#      render time instead, and entries it accepts still render;
#   6. values.yaml's upstream.version equals the tag Cargo.toml pins.
# Checks 4 and 5 (NetworkPolicies, RBAC) are added with the RBAC work.
# Needs helm, python3 with PyYAML, and network access (for check 1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

ROOT=$(git rev-parse --show-toplevel)
CHART="$ROOT/deploy/helm/openshell-driver-kyma"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

"$SCRIPT_DIR/check-upstream-args.sh" --print-env >"$WORK/upstream-env.txt"
pinned_upstream_tag >"$WORK/pinned-tag.txt"

# Sandbox JWT is on for every render: the gateway TOML only carries a
# gateway_id (check 2) inside [openshell.gateway.gateway_jwt].
render() {
	helm template t "$CHART" --set gateway.enabled=true --set gateway.sandboxJwt.enabled=true "$@"
}

for mode in shared managed; do
	for allow in true false; do
		extra=()
		[[ $mode == managed ]] && extra=(--set gateway.sandboxJwt.gatewayId=gw)
		render --set "driver.workspaceMode=$mode" --set "driver.allowDriverConfig=$allow" \
			${extra[@]+"${extra[@]}"} >"$WORK/render-$mode-$allow.yaml"
	done
done

# 3b. Entries the driver's startup validation rejects (a comma, no `=`, an
# empty key, a reserved OPENSHELL_ key) must fail the render. They go in with
# --set-json: `--set driver.sandboxEnv[0]=A=1,2` never reaches the chart, helm's
# own parser stops at the comma with `key "2" has no value`.
n=0
for entry in 'A=1,2' 'NO_EQUALS' '=value' 'OPENSHELL_FOO=bar'; do
	rc=0
	render --set-json "driver.sandboxEnv=[\"$entry\"]" >"$WORK/bad-$n.out" 2>&1 || rc=$?
	printf '%s' "$entry" >"$WORK/bad-$n.entry"
	printf '%s' "$rc" >"$WORK/bad-$n.rc"
	n=$((n + 1))
done
# ...and the two shapes it does accept: a value with `=` in it, and the one
# reserved key upstream keeps.
render --set-json 'driver.sandboxEnv=["OPENSHELL_LOG_LEVEL=debug","OPTS=a=b"]' >"$WORK/good-env.yaml"

python3 - "$WORK" "$CHART" <<'PY'
import glob, json, pathlib, re, sys
import yaml

work, chart = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
failures = []

def docs(path):
    return [d for d in yaml.safe_load_all(path.read_text()) if d]

def driver_container(documents):
    for d in documents:
        if d.get("kind") == "Deployment":
            for c in d["spec"]["template"]["spec"]["containers"]:
                if c["name"] == "driver":
                    return c
    raise SystemExit("no driver container rendered")

# 1. every upstream option is reachable from values. Whole-name match: a name
# that is a prefix of another (OPENSHELL_SANDBOX_IMAGE and
# OPENSHELL_SANDBOX_IMAGE_PULL_POLICY) must not be satisfied by the longer one.
templates = "\n".join(p.read_text() for p in (chart / "templates").glob("*"))
missing = [n for n in (work / "upstream-env.txt").read_text().split()
           if not re.search(r"(?<![A-Z0-9_])" + re.escape(n) + r"(?![A-Z0-9_])", templates)]
if missing:
    failures.append("upstream options not reachable from the chart: " + ", ".join(missing))

# 2. gateway and driver agree on the admission policy
for render in sorted(work.glob("render-*.yaml")):
    expected = render.stem.endswith("-true")
    documents = docs(render)
    toml = next(d["data"]["gateway.toml"] for d in documents
                if d.get("kind") == "ConfigMap" and "gateway.toml" in d.get("data", {}))
    kyma_table = toml.split("[openshell.drivers.kyma]", 1)[1].split("\n[", 1)[0]
    m = re.search(r"^\s*allow_driver_config\s*=\s*(true|false)\s*$", kyma_table, re.M)
    gateway_side = m and m.group(1) == "true"
    env = {e["name"]: e.get("value") for e in driver_container(documents).get("env", [])}
    admission = env.get("OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON")
    driver_side = json.loads(admission).get("allow_driver_config") if admission else None
    if not (gateway_side == driver_side == expected):
        failures.append(f"{render.name}: gateway allow_driver_config={gateway_side}, "
                        f"driver={driver_side}, values={expected}")
    # upstream's chart derives the gateway's and the driver's gateway_id from one value
    jwt_id = re.search(r'^\s*gateway_id\s*=\s*"([^"]*)"', toml, re.M)
    if not jwt_id or env.get("OPENSHELL_GATEWAY_ID") != jwt_id.group(1):
        failures.append(f"{render.name}: driver OPENSHELL_GATEWAY_ID={env.get('OPENSHELL_GATEWAY_ID')!r} "
                        f"differs from the gateway's gateway_id={jwt_id and jwt_id.group(1)!r}")

# 3. no args on the driver, removed values gone
if "args" in driver_container(docs(work / "render-shared-true.yaml")):
    failures.append("the driver container still passes command-line args")
removed = ["supervisorBinaryPath", "supervisorMountPath", "gpuSupport", "enableNetworkPolicy",
           "telemetryEnabled", "stopTimeoutSecs", "driverConfigAllowVolumes",
           "operatorNamespaceAllowlist", "gatewayId"]
values = (chart / "values.yaml").read_text()
driver_values = (yaml.safe_load(values) or {}).get("driver", {})
still = [k for k in removed if k in driver_values]
if still:
    failures.append("removed values still in values.yaml: " + ", ".join(still))

# 3b. the chart refuses sandbox env entries the driver would refuse at startup
for rc_file in sorted(glob.glob(str(work / "bad-*.rc"))):
    stem = rc_file[: -len(".rc")]
    entry = pathlib.Path(stem + ".entry").read_text()
    rc = pathlib.Path(rc_file).read_text()
    output = pathlib.Path(stem + ".out").read_text()
    if rc == "0":
        failures.append(f"driver.sandboxEnv entry {entry!r} rendered; the driver would reject it at startup")
    elif entry not in output:
        failures.append(f"driver.sandboxEnv entry {entry!r} failed the render without naming it: "
                        + " ".join(output.split())[:200])
good_env = {e["name"]: e.get("value")
            for e in driver_container(docs(work / "good-env.yaml")).get("env", [])}
if good_env.get("OPENSHELL_KYMA_SANDBOX_ENV") != "OPENSHELL_LOG_LEVEL=debug,OPTS=a=b":
    failures.append("valid driver.sandboxEnv entries did not reach OPENSHELL_KYMA_SANDBOX_ENV: "
                    f"{good_env.get('OPENSHELL_KYMA_SANDBOX_ENV')!r}")

# 6. the chart's upstream version is the pinned tag
pinned = (work / "pinned-tag.txt").read_text().strip()
chart_version = (yaml.safe_load(values) or {}).get("upstream", {}).get("version")
if chart_version != pinned:
    failures.append(f"values upstream.version={chart_version!r}, Cargo.toml pins {pinned!r}")

if failures:
    print("CHART_RENDER_FAIL:")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("CHART_RENDER_OK")
PY
