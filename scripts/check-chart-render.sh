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
#   4. the chart's NetworkPolicies: exactly one selects OpenShell sandbox pods, the
#      mirror of upstream's SSH-ingress restriction, present in shared mode with the
#      in-pod gateway only;
#      the rest select only the chart's own pods. Upstream fences sandboxes per
#      namespace and NetworkPolicies are additive, so any other policy could only
#      widen that fence;
#   5. the RBAC the driver's ServiceAccount is granted, by bindings, is exactly
#      upstream's rules plus the Kyma layer's for that render: nothing missing and
#      nothing extra, per scope, in every workspace mode and option combination the
#      table names, including the Secrets the driver may read;
#   6. values.yaml's upstream.version equals the tag Cargo.toml pins.
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

# 4 and 5. Renders for the NetworkPolicy and RBAC checks. Named rbac-*, so check 2's
# render-*.yaml glob skips them, and check 4's r*.yaml glob takes them.
# Exposure on, in shared, managed (which also labels namespaces) and operator mode.
render_as t --set driver.enableApirule=true --set driver.clusterDomain=example.org \
	>"$WORK/rbac-apirule.yaml"
render_as t --set driver.workspaceMode=managed --set gateway.sandboxJwt.gatewayId=gw \
	--set driver.enableApirule=true --set driver.clusterDomain=example.org \
	--set driver.workspacePsaLevel=baseline >"$WORK/rbac-managed-apirule.yaml"
render_as t --set driver.workspaceMode=operator --set driver.operatorNamespaceLabel=team=a \
	--set driver.enableApirule=true --set driver.clusterDomain=example.org \
	>"$WORK/rbac-operator-apirule.yaml"
# Managed SSH ingress, which makes the driver write a NetworkPolicy in every workspace.
render_as t --set driver.workspaceMode=managed --set gateway.sandboxJwt.gatewayId=gw \
	--set driver.managedSshIngress.enabled=true --set driver.managedSshIngress.gatewayNamespace=gw-ns \
	--set 'driver.managedSshIngress.gatewayPodSelector[0]=app=gateway' >"$WORK/rbac-managed-ssh.yaml"
# The Secrets the driver stages into workspace namespaces: a client TLS Secret and
# image-pull Secrets. The pull list repeats a name, repeats the TLS name and holds
# an empty entry, so each render also proves the deduplication and the skip.
secret_values=(--set driver.clientTlsSecretName=client-tls
	--set-json 'driver.sandboxImagePullSecrets=["pull-a","pull-b","client-tls","pull-a",""]')
render_as t "${secret_values[@]}" >"$WORK/rbac-shared-secrets.yaml"
render_as t --set driver.workspaceMode=managed --set gateway.sandboxJwt.gatewayId=gw \
	"${secret_values[@]}" >"$WORK/rbac-managed-secrets.yaml"
render_as t --set driver.workspaceMode=operator --set driver.operatorNamespaceLabel=team=a \
	"${secret_values[@]}" >"$WORK/rbac-operator-secrets.yaml"
# NetworkPolicies off; an external gateway (the chart's default gateway.enabled=false,
# which render_as overrides); and the bedrock bridge, which has a NetworkPolicy of its own.
render_as t --set networkPolicy.enabled=false >"$WORK/rbac-shared-no-netpol.yaml"
render_as t --set gateway.enabled=false >"$WORK/rbac-shared-no-gateway.yaml"
render_as t --set bedrockBridge.enabled=true --set bedrockBridge.sap.serviceKeySecret.name=sap-key \
	--set bedrockBridge.singleDeploymentId=deployment >"$WORK/rbac-bedrock-bridge.yaml"

python3 - "$WORK" "$CHART" "$KYMA_ARGS" "$ALL_OPTIONS" <<'PY'
import glob, json, pathlib, re, sys
import yaml

work, chart, kyma_args, all_options = (pathlib.Path(a) for a in sys.argv[1:5])
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

# Checks 4 and 5 need the sandbox namespace and the Deployment that runs the driver.
sandbox_namespace = (yaml.safe_load(values) or {}).get("namespace")

def driver_deployment(documents, where):
    """The Deployment whose pod runs the driver, or None after recording why not."""
    for d in documents:
        if d.get("kind") == "Deployment" and any(
                c["name"] == "driver" for c in d["spec"]["template"]["spec"]["containers"]):
            return d
    failures.append(f"{where}: no Deployment with a driver container was rendered")
    return None

# 4. NetworkPolicies. Upstream's driver fences sandbox pods per namespace, and
# NetworkPolicies are additive, so a chart policy selecting them can only widen the
# fence. The exception is upstream's own SSH-ingress restriction, which the chart
# mirrors in shared mode (deploy/helm/openshell/templates/networkpolicy.yaml at the
# pinned tag, lines 4-35; managed mode gets it from the driver). Its one peer is the
# release's own gateway pod, so an external gateway (gateway.enabled=false) is left to
# its own deployment. Every other policy must select the chart's own pods: never an
# empty selector, never openshell.ai/*.
chart_name = (yaml.safe_load((chart / "Chart.yaml").read_text()) or {})["name"]
own_pods = [{"app.kubernetes.io/name": chart_name, "app.kubernetes.io/instance": "t"},
            {"app.kubernetes.io/name": chart_name + "-bedrock-bridge", "app.kubernetes.io/instance": "t"}]
# Shared-mode renders in which the SSH-ingress restriction must be absent, and why.
NO_SSH_RESTRICTION = {"rbac-shared-no-netpol.yaml": "networkPolicy.enabled=false",
                      "rbac-shared-no-gateway.yaml": "gateway.enabled=false"}

def ssh_restriction(release_namespace):
    return {"podSelector": {"matchLabels": {"openshell.ai/managed-by": "openshell"}},
            "policyTypes": ["Ingress"],
            "ingress": [{"from": [{"namespaceSelector": {"matchLabels": {
                                       "kubernetes.io/metadata.name": release_namespace}},
                                   "podSelector": {"matchLabels": own_pods[0]}}],
                         "ports": [{"protocol": "TCP", "port": 2222}]}]}

for render in sorted(work.glob("r*.yaml")) + [work / "good-all-options.yaml"]:
    documents = docs(render)
    pod = driver_deployment(documents, render.name)
    if pod is None:
        continue
    mode = {e["name"]: e.get("value") for e in driver_container(documents).get("env", [])}.get(
        "OPENSHELL_WORKSPACE_MODE")
    policies = [d for d in documents if d.get("kind") == "NetworkPolicy"]
    ssh = [d for d in policies if d["metadata"]["name"].endswith("-sandbox-ssh")]
    want = 1 if mode == "shared" and render.name not in NO_SSH_RESTRICTION else 0
    if len(ssh) != want:
        failures.append(f"{render.name}: {len(ssh)} SSH-ingress restrictions in {mode} mode"
                        + (f" with {NO_SSH_RESTRICTION[render.name]}" if render.name in NO_SSH_RESTRICTION else "")
                        + f", want {want}")
    for d in policies:
        name, spec = d["metadata"]["name"], d.get("spec") or {}
        if d in ssh:
            if d["metadata"].get("namespace") != sandbox_namespace or spec != ssh_restriction(
                    pod["metadata"].get("namespace")):
                failures.append(f"{render.name}: NetworkPolicy {name} is not upstream's SSH-ingress "
                                f"restriction in the sandbox namespace {sandbox_namespace}: {spec}")
            continue
        selector = spec.get("podSelector") or {}
        labels = selector.get("matchLabels") or {}
        expressions = selector.get("matchExpressions") or []
        keys = list(labels) + [e.get("key", "") for e in expressions]
        if any(k.startswith("openshell.ai/") for k in keys):
            failures.append(f"{render.name}: NetworkPolicy {name} selects sandbox pods and would add to "
                            "upstream's workload fence")
        elif expressions or labels not in own_pods:
            failures.append(f"{render.name}: NetworkPolicy {name} selects {selector or 'every pod'} "
                            "instead of only the chart's own pods")

# 5. The driver's RBAC is exactly upstream's rules plus the Kyma layer's, per render.
# effective_rules() resolves what the driver pod's ServiceAccount is granted through
# bindings, as (scope, apiGroup, resource, verb, resourceNames) rows: scope is
# "cluster" for a ClusterRoleBinding and the binding's namespace otherwise. So an
# unbound Role grants nothing, a ClusterRole bound by a RoleBinding grants only in
# that namespace, and a hook's Role (bound to the hook's own ServiceAccount) does
# not count. Rows are compared as sets: anything missing or extra fails. A wildcard
# is a row of its own, so it is an over-grant, as no row of the table has one; the
# same holds for a cluster-wide Secret grant, which is how a ClusterRole could hide
# one from the secret-source Role's names.
def expand(scope, rule):
    names = tuple(sorted(rule.get("resourceNames") or [])) or None
    verbs = rule.get("verbs") or ["<no verbs>"]
    if rule.get("nonResourceURLs"):
        return {(scope, "<nonResourceURL>", url, verb, None) for url in rule["nonResourceURLs"] for verb in verbs}
    return {(scope, group, resource, verb, names)
            for group in rule.get("apiGroups") or ["<no apiGroups>"]
            for resource in rule.get("resources") or ["<no resources>"] for verb in verbs}

def effective_rules(documents, where):
    pod = driver_deployment(documents, where)
    if pod is None:
        return None
    account_name = pod["spec"]["template"]["spec"].get("serviceAccountName")
    if not account_name:
        failures.append(f"{where}: the driver Deployment names no serviceAccountName")
        return None
    account = (pod["metadata"].get("namespace"), account_name)
    roles = {(d["metadata"].get("namespace"), d["metadata"]["name"]): d for d in documents if d.get("kind") == "Role"}
    cluster_roles = {d["metadata"]["name"]: d for d in documents if d.get("kind") == "ClusterRole"}
    rows = set()
    for binding in documents:
        if binding.get("kind") not in ("RoleBinding", "ClusterRoleBinding") or not any(
                s.get("kind") == "ServiceAccount" and (s.get("namespace"), s.get("name")) == account
                for s in binding.get("subjects") or []):
            continue
        namespace, ref = binding["metadata"].get("namespace"), binding["roleRef"]
        role = roles.get((namespace, ref["name"])) if ref["kind"] == "Role" else cluster_roles.get(ref["name"])
        if role is None:
            failures.append(f"{where}: {binding['kind']} {binding['metadata']['name']} binds the driver to "
                            f"{ref['kind']} {ref['name']}, which this render does not contain")
            continue
        for rule in role.get("rules") or []:
            rows |= expand(namespace or "cluster", rule)
    return rows

SANDBOX_VERBS = ["create", "delete", "get", "list", "patch", "update", "watch"]
# Blocks of (apiGroup, resource, verbs[, resourceNames]) rows. Upstream's come from
# the v0.1.2 templates of deploy/helm/openshell (role.yaml for shared mode, whose
# Role holds the namespaced rights; clusterrole.yaml for the cluster-wide rights of
# every mode and the namespaced rights of the other modes); the line numbers refer to those.
PVC_GET = [("", "persistentvolumeclaims", ["get"])]           # role.yaml:13-18, clusterrole.yaml:18-22; with allowDriverConfig
WORKLOAD = [("agents.x-k8s.io", "sandboxes", SANDBOX_VERBS),                        # role.yaml:19-31, clusterrole.yaml:59-70
            ("agents.x-k8s.io", "sandboxes/status", SANDBOX_VERBS),
            ("", "events", ["get", "list", "watch"]),                                # role.yaml:32-44, clusterrole.yaml:72-79
            ("", "pods", ["create", "delete", "get", "list", "patch", "watch"]),     # role.yaml:46-56, clusterrole.yaml:80-90
            ("", "services", ["create", "get"]),                                     # role.yaml:57-59, clusterrole.yaml:93-95
            ("networking.k8s.io", "networkpolicies", ["create", "get"])]             # role.yaml:65-67, clusterrole.yaml:96-98
BOOTSTRAP_SECRETS = [("", "secrets", ["create", "delete"])]   # role.yaml:60-64; clusterrole.yaml:100-108, managed only
NODE_READER = [("node.k8s.io", "runtimeclasses", ["get"]),                          # clusterrole.yaml:12-14
               ("scheduling.k8s.io", "priorityclasses", ["get"]),                   # clusterrole.yaml:15-17
               ("authentication.k8s.io", "tokenreviews", ["create"]),               # clusterrole.yaml:25-31
               ("", "nodes", ["get", "list", "watch"])]                             # clusterrole.yaml:32-35
NAMESPACE_GET = [("", "namespaces", ["get"])]                                       # clusterrole.yaml:43-48, every mode
NAMESPACE_DISCOVERY = [("", "namespaces", ["list", "watch"])]                       # clusterrole.yaml:49-52, managed and operator
NAMESPACE_LIFECYCLE = [("", "namespaces", ["create", "delete"])]                    # clusterrole.yaml:53-56, managed
WORKSPACE_SERVICEACCOUNTS = [("", "serviceaccounts", ["create", "get"])]            # clusterrole.yaml:109-116, managed
# clusterrole.yaml:118-129 applies the SSH-ingress policy in each workspace. Upstream gates it on its
# networkPolicy.enabled, which sets managed_ssh_ingress.enabled there; here that is driver.managedSshIngress.enabled.
SSH_INGRESS_POLICY = [("networking.k8s.io", "networkpolicies", ["get", "create", "patch", "update"])]
# The Kyma layer (src/exposure.rs, src/namespaces.rs): server-side apply of a Service, a
# NetworkPolicy and an APIRule (patch, and create for a new object; nothing reads an
# APIRule), a failure Event, and a merge patch that labels a managed namespace.
KYMA_EXPOSURE = [("", "services", ["patch"]), ("networking.k8s.io", "networkpolicies", ["patch"]),
                 ("gateway.kyma-project.io", "apirules", ["create", "patch"]), ("", "events", ["create"])]
KYMA_PSA_LABEL = [("", "namespaces", ["patch"])]

def secret_sources(*names):
    """upstream's workspace-secret-source-role.yaml: get on exactly these Secrets."""
    return [("", "secrets", ["get"], names)]

SHARED = [PVC_GET, WORKLOAD, BOOTSTRAP_SECRETS]     # in the sandbox namespace, by the Role
SHARED_CLUSTER = [NODE_READER, NAMESPACE_GET]
MANAGED = [NODE_READER, NAMESPACE_GET, NAMESPACE_DISCOVERY, NAMESPACE_LIFECYCLE, PVC_GET, WORKLOAD,
           BOOTSTRAP_SECRETS, WORKSPACE_SERVICEACCOUNTS]
MANAGED_NO_PVC = [b for b in MANAGED if b is not PVC_GET]
OPERATOR = [NODE_READER, NAMESPACE_GET, NAMESPACE_DISCOVERY, PVC_GET, WORKLOAD]   # no secrets, no lifecycle
opts = (yaml.safe_load(all_options.read_text()) or {})["driver"]
all_options_secrets = secret_sources(opts["clientTlsSecretName"], *opts["sandboxImagePullSecrets"])

# render -> (blocks the driver holds in the sandbox namespace, blocks it holds cluster-wide)
EXPECTED = {
    "render-shared-true": (SHARED, SHARED_CLUSTER),
    "render-shared-false": ([b for b in SHARED if b is not PVC_GET], SHARED_CLUSTER),      # no allowDriverConfig, no PVC get
    "rbac-shared-no-netpol": (SHARED, SHARED_CLUSTER),
    "rbac-shared-no-gateway": (SHARED, SHARED_CLUSTER),                                    # an external gateway changes no RBAC
    "rbac-apirule": (SHARED + [KYMA_EXPOSURE], SHARED_CLUSTER),
    "rbac-shared-secrets": (SHARED, SHARED_CLUSTER),                                       # shared mode stages no Secret
    "render-managed-true": ([], MANAGED),
    "render-managed-false": ([], MANAGED_NO_PVC),
    "rbac-managed-apirule": ([], MANAGED + [KYMA_EXPOSURE, KYMA_PSA_LABEL]),
    "rbac-managed-ssh": ([], MANAGED + [SSH_INGRESS_POLICY]),
    "rbac-managed-secrets": ([secret_sources("client-tls", "pull-a", "pull-b")], MANAGED),
    "rbac-operator-apirule": ([], OPERATOR + [KYMA_EXPOSURE]),
    "rbac-operator-secrets": ([secret_sources("client-tls")], OPERATOR),                   # TLS Secret only, no pull Secrets
    "good-all-options": ([all_options_secrets], MANAGED + [SSH_INGRESS_POLICY, KYMA_EXPOSURE, KYMA_PSA_LABEL]),
}

def table(scope, blocks):
    return {(scope, group, resource, verb, row[3] if len(row) > 3 else None)
            for block in blocks for row in block for group, resource in [row[:2]] for verb in row[2]}

def show(row):
    scope, group, resource, verb, names = row
    return f"{verb} on {group or 'core'}/{resource}" + (f" {list(names)}" if names else "") + f" in {scope}"

for name, (namespaced, cluster_wide) in EXPECTED.items():
    actual = effective_rules(docs(work / f"{name}.yaml"), name)
    if actual is None:
        continue
    expected = table(sandbox_namespace, namespaced) | table("cluster", cluster_wide)
    failures.extend(f"{name}: missing {show(r)}" for r in sorted(expected - actual, key=str))
    failures.extend(f"{name}: extra {show(r)}" for r in sorted(actual - expected, key=str))

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
