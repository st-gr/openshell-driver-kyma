#!/usr/bin/env bash
# Render the chart and assert the driver's configuration surface:
#   1. every upstream option (check-upstream-args.sh --print-env) and every Kyma
#      option (the `env = "OPENSHELL_KYMA_..."` attributes in kyma_args.rs) is an
#      environment variable of the driver container in a render that sets every
#      option (scripts/testdata/chart-all-options.yaml), so each is reachable from
#      values;
#   2. the admission policy the gateway derives from [openshell.drivers.kyma]
#      equals the one the driver acknowledges (OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON),
#      and the driver's gateway id equals the gateway's;
#   3. the driver container takes no command-line args, and removed values are
#      gone from values.yaml;
#   3b-3g. values the driver or upstream would refuse at startup fail at render
#      time instead, naming the value, and the values they accept still render:
#      3b driver.sandboxEnv entries, 3c the managed-mode gateway id, 3d the
#      operator-mode namespace selectors, 3e managed SSH ingress, 3f the sandbox
#      UID/GID, 3g driver.allowDriverConfig;
#   6. values.yaml's upstream.version equals the tag Cargo.toml pins.
# Checks 4 and 5 (NetworkPolicies, RBAC) are added with the RBAC work.
# Needs helm, python3 with PyYAML, and network access (for check 1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

ROOT=$(git rev-parse --show-toplevel)
CHART="$ROOT/deploy/helm/openshell-driver-kyma"
KYMA_ARGS="$ROOT/crates/openshell-driver-kyma/src/kyma_args.rs"
ALL_OPTIONS="$SCRIPT_DIR/testdata/chart-all-options.yaml"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

"$SCRIPT_DIR/check-upstream-args.sh" --print-env >"$WORK/upstream-env.txt"
pinned_upstream_tag >"$WORK/pinned-tag.txt"

# render_as RELEASE [helm args...]. Sandbox JWT is on for every render: the gateway
# TOML only carries a gateway_id (check 2) inside [openshell.gateway.gateway_jwt].
render_as() {
	local release=$1
	shift
	helm template "$release" "$CHART" --set gateway.enabled=true --set gateway.sandboxJwt.enabled=true "$@"
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

for mode in shared managed; do
	for allow in true false; do
		extra=()
		[[ $mode == managed ]] && extra=(--set gateway.sandboxJwt.gatewayId=gw)
		render_as t --set "driver.workspaceMode=$mode" --set "driver.allowDriverConfig=$allow" \
			${extra[@]+"${extra[@]}"} >"$WORK/render-$mode-$allow.yaml"
	done
done

# 1. Every option set at once.
try good-all-options '' t -f "$ALL_OPTIONS"

# 3b. Entries the driver's startup validation rejects (a comma, no `=`, an empty
# key, a reserved OPENSHELL_ key) must fail the render, naming the entry. They go
# in with --set-json: `--set driver.sandboxEnv[0]=A=1,2` never reaches the chart,
# helm's own parser stops at the comma with `key "2" has no value`.
n=0
for entry in 'A=1,2' 'NO_EQUALS' '=value' 'OPENSHELL_FOO=bar'; do
	try "bad-3b-$n" "$entry" t --set-json "driver.sandboxEnv=[\"$entry\"]"
	n=$((n + 1))
done
# ...and the two shapes it does accept: a value with `=` in it, and the one
# reserved key upstream keeps.
try good-3b-env '' t --set-json 'driver.sandboxEnv=["OPENSHELL_LOG_LEVEL=debug","OPTS=a=b"]'

# 3c. Managed mode: upstream refuses a gateway id that is not a DNS-1123 label, or
# longer than 33 characters ("openshell-<id>-" plus a 19-character workspace name
# must fit 63). The default id is the release fullname, so a long release name
# alone crash-loops the driver.
id33=$(printf '%033d' 0 | tr 0 a)
id34=$(printf '%034d' 0 | tr 0 a)
try bad-3c-too-long "$id34" t --set driver.workspaceMode=managed --set "gateway.sandboxJwt.gatewayId=$id34"
try bad-3c-long-release 'prod-sandboxes-openshell-driver-kyma' prod-sandboxes --set driver.workspaceMode=managed
try bad-3c-not-a-label 'Bad_ID' t --set driver.workspaceMode=managed --set gateway.sandboxJwt.gatewayId=Bad_ID
try good-3c-33-chars '' t --set driver.workspaceMode=managed --set "gateway.sandboxJwt.gatewayId=$id33"
# A long release name is fine outside managed mode.
try good-3c-shared-long-release '' prod-sandboxes

# 3d. Operator mode takes exactly one of the label and the ConfigMap.
try bad-3d-neither 'requires exactly one of driver.operatorNamespaceLabel' t --set driver.workspaceMode=operator
try bad-3d-both 'not both' t --set driver.workspaceMode=operator \
	--set driver.operatorNamespaceLabel=team=a --set driver.operatorNamespaceConfigMap.name=ns
try good-3d-label '' t --set driver.workspaceMode=operator --set driver.operatorNamespaceLabel=team=a
try good-3d-configmap '' t --set driver.workspaceMode=operator --set driver.operatorNamespaceConfigMap.name=ns

# 3e. Managed SSH ingress needs a gateway namespace and a pod selector, in managed
# mode only.
try bad-3e-no-namespace 'driver.managedSshIngress.gatewayNamespace' t --set driver.workspaceMode=managed \
	--set driver.managedSshIngress.enabled=true --set 'driver.managedSshIngress.gatewayPodSelector[0]=app=gateway'
try bad-3e-no-selector 'driver.managedSshIngress.gatewayPodSelector' t --set driver.workspaceMode=managed \
	--set driver.managedSshIngress.enabled=true --set driver.managedSshIngress.gatewayNamespace=gw
try good-3e-shared-unchecked '' t --set driver.managedSshIngress.enabled=true

# 3f. A set sandbox UID/GID is a whole number from 1 to 4294967294; unset stays unset.
try bad-3f-uid-zero 'driver.sandboxUid' t --set driver.sandboxUid=0
try bad-3f-gid-zero 'driver.sandboxGid' t --set driver.sandboxGid=0
try bad-3f-fraction 'driver.sandboxUid' t --set-json driver.sandboxUid=1.5
try bad-3f-negative 'driver.sandboxUid' t --set driver.sandboxUid=-1
try bad-3f-too-big 'driver.sandboxUid' t --set driver.sandboxUid=4294967295
try bad-3f-not-a-number 'driver.sandboxUid' t --set-string driver.sandboxUid=abc
try good-3f-bounds '' t --set driver.sandboxUid=1 --set driver.sandboxGid=4294967294
try good-3f-unset '' t

# 3g. driver.allowDriverConfig is a real boolean: a string would render the JSON
# policy as "false", which the driver rejects.
try bad-3g-string 'driver.allowDriverConfig' t --set-string driver.allowDriverConfig=false

python3 - "$WORK" "$CHART" "$KYMA_ARGS" <<'PY'
import glob, json, pathlib, re, sys
import yaml

work, chart, kyma_args = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
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

def first_line(text):
    return " ".join(text.split())[:240]

def rendered(name):
    """The driver container's environment of a render that must have succeeded,
    or None after recording why it did not."""
    rc = (work / f"{name}.rc").read_text()
    if rc != "0":
        failures.append(f"{name}: expected the render to succeed, it failed: "
                        + first_line((work / f"{name}.err").read_text()))
        return None
    return {e["name"]: e.get("value") for e in driver_container(docs(work / f"{name}.yaml")).get("env", [])}

# 1. every upstream and Kyma option is an environment variable of the driver
# container when every option is set, so each is reachable from values.
upstream_names = (work / "upstream-env.txt").read_text().split()
kyma_names = list(dict.fromkeys(
    re.findall(r'env\s*=\s*"(OPENSHELL_KYMA_[A-Z0-9_]+)"', kyma_args.read_text())))
if not upstream_names:
    failures.append("check-upstream-args.sh --print-env listed no upstream options")
if not kyma_names:
    failures.append(f'found no env = "OPENSHELL_KYMA_..." attribute in {kyma_args.name}')
all_env = rendered("good-all-options")
if all_env is not None:
    missing = [n for n in upstream_names + kyma_names if n not in all_env]
    if missing:
        failures.append("options not emitted by a render that sets every option: " + ", ".join(missing))
    # A values-file number must reach the driver as digits (Go prints float64 as 1.00074e+09).
    for name, want in (("OPENSHELL_K8S_SANDBOX_UID", "1000740000"), ("OPENSHELL_K8S_SANDBOX_GID", "1000740001")):
        if all_env.get(name) != want:
            failures.append(f"{name}={all_env.get(name)!r} in the all-options render, want {want!r}")

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

# 3b-3g. values upstream or the driver would refuse fail the render, naming the value
bad_cases = sorted(pathlib.Path(p).stem for p in glob.glob(str(work / "bad-*.rc")))
if not bad_cases:
    failures.append("no refused-value cases were rendered")
for name in bad_cases:
    rc = (work / f"{name}.rc").read_text()
    expect = (work / f"{name}.expect").read_text()
    err = (work / f"{name}.err").read_text()
    if rc == "0":
        failures.append(f"{name}: rendered, but the driver or upstream would refuse it at startup")
    elif expect not in err:
        failures.append(f"{name}: failed the render without naming {expect!r}: " + first_line(err))

env = rendered("good-3b-env")
if env is not None and env.get("OPENSHELL_KYMA_SANDBOX_ENV") != "OPENSHELL_LOG_LEVEL=debug,OPTS=a=b":
    failures.append("valid driver.sandboxEnv entries did not reach OPENSHELL_KYMA_SANDBOX_ENV: "
                    f"{env.get('OPENSHELL_KYMA_SANDBOX_ENV')!r}")

env = rendered("good-3c-33-chars")
if env is not None and env.get("OPENSHELL_GATEWAY_ID") != "a" * 33:
    failures.append(f"a 33-character gateway id did not reach the driver: {env.get('OPENSHELL_GATEWAY_ID')!r}")
rendered("good-3c-shared-long-release")

env = rendered("good-3d-label")
if env is not None and (env.get("OPENSHELL_OPERATOR_NAMESPACE_LABEL") != "team=a"
                        or "OPENSHELL_OPERATOR_NAMESPACE_FILE" in env):
    failures.append("operator mode with only a label did not emit only OPENSHELL_OPERATOR_NAMESPACE_LABEL")
env = rendered("good-3d-configmap")
if env is not None and (env.get("OPENSHELL_OPERATOR_NAMESPACE_FILE") != "/etc/openshell-operator-namespaces/namespaces"
                        or "OPENSHELL_OPERATOR_NAMESPACE_LABEL" in env):
    failures.append("operator mode with only a ConfigMap did not emit only OPENSHELL_OPERATOR_NAMESPACE_FILE")

rendered("good-3e-shared-unchecked")

env = rendered("good-3f-bounds")
if env is not None and (env.get("OPENSHELL_K8S_SANDBOX_UID"), env.get("OPENSHELL_K8S_SANDBOX_GID")) != ("1", "4294967294"):
    failures.append("the sandbox UID/GID bounds did not reach the driver as digits: "
                    f"{env.get('OPENSHELL_K8S_SANDBOX_UID')!r}, {env.get('OPENSHELL_K8S_SANDBOX_GID')!r}")
env = rendered("good-3f-unset")
if env is not None and ("OPENSHELL_K8S_SANDBOX_UID" in env or "OPENSHELL_K8S_SANDBOX_GID" in env):
    failures.append("an unset sandbox UID/GID was still passed to the driver")

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
