#!/usr/bin/env bash
# Render the chart and assert the driver's configuration surface:
#   1. every upstream option (check-upstream-args.sh --print-env) and every Kyma
#      option (the `env = "OPENSHELL_KYMA_..."` attributes in kyma_args.rs) is an
#      environment variable of the driver container in a render that sets every
#      option (scripts/testdata/chart-all-options.yaml), so each is reachable from
#      values;
#   2. the whole admission policy the gateway derives from [openshell.drivers.kyma]
#      (allow_driver_config and resource_admission) equals the one the driver
#      acknowledges (OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON) and the one values set,
#      and the driver's gateway id equals the gateway's;
#   3. the driver container takes no command-line args, and removed values are
#      gone from values.yaml;
#   3b-3j. values the driver or upstream would refuse at startup fail at render
#      time instead, naming the value, and the values they accept still render:
#      3b driver.sandboxEnv entries, 3c the managed-mode gateway id, 3d the
#      operator-mode namespace selectors, 3e managed SSH ingress, 3f the sandbox
#      UID/GID, 3g driver.allowDriverConfig and driver.resourceAdmission (types, and
#      no empty label set while admission is enabled); 3h
#      gateway settings that cannot work: the in-pod gateway without the Service
#      sandboxes dial or without sandbox-JWT keys, and the provider hook without
#      the gateway's Service or against an OIDC or TLS gateway it cannot reach;
#      and 3j the exposure kind and the Istio Gateway its VirtualService binds to;
#   4. the chart's NetworkPolicies: exactly one selects OpenShell sandbox pods, the
#      mirror of upstream's SSH-ingress restriction, present in shared mode with the
#      in-pod gateway only; in managed mode the driver applies it instead, so the
#      driver's managed SSH ingress settings are asserted there (on by default with
#      the in-pod gateway, naming its own pod);
#      the rest select only the chart's own pods. Upstream fences sandboxes per
#      namespace and NetworkPolicies are additive, so any other policy could only
#      widen that fence. The driver pod's egress is DNS and 443, plus the port of
#      driver.otlpEndpoint when one is set;
#   5. the RBAC the driver's ServiceAccount is granted, by bindings, is exactly
#      upstream's rules plus the Kyma layer's for that render: nothing missing and
#      nothing extra, per scope, in every workspace mode and option combination the
#      table names, including the Secrets the driver may read;
#   6. values.yaml's upstream.version equals the tag Cargo.toml pins, and 6b the
#      gateway endpoint sandboxes dial takes its scheme from gateway.tls.enabled, with
#      the PKI hook's client TLS Secret as the driver's default under TLS;
#   7. providers follow upstream's profile model: no template calls the removed
#      `openshell inference`; the chart renders a provider profile with exactly the
#      configured endpoint and binaries; the hook installs the pinned CLI, checks it
#      against the release checksums, keeps the API key out of its script, and mounts
#      that profile; sandboxes receive the endpoint and model; and 7b an endpoint,
#      model or binaries list the driver or upstream would refuse (a comma, a URL
#      that is not plain http(s) to a host name, credentials in the URL, nothing
#      listed) fails the render, naming the value and never echoing credentials.
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

# render_as RELEASE [helm args...]. The in-pod gateway runs in every render, with
# what it needs to work (3h): its Service, which sandboxes dial, and sandbox JWT,
# which is also where the gateway TOML carries a gateway_id (check 2).
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

for mode in shared managed; do
	for allow in true false; do
		extra=()
		[[ $mode == managed ]] && extra=(--set gateway.sandboxJwt.gatewayId=gw)
		render_as t --set "driver.workspaceMode=$mode" --set "driver.allowDriverConfig=$allow" \
			${extra[@]+"${extra[@]}"} >"$WORK/render-$mode-$allow.yaml"
	done
done
# 2. Resource admission: off; custom labels, one of them the workspace placeholder;
# and off with an explicitly empty map, which must reach both sides as empty, not as
# upstream's built-in labels.
render_as t --set driver.resourceAdmission.enabled=false >"$WORK/render-admission-off.yaml"
# shellcheck disable=SC2016 # ${workspace} is upstream's literal placeholder, not a shell variable
render_as t --set-json 'driver.resourceAdmission.requiredLabels={"example.com/approved":"yes","example.com/team":"${workspace}"}' \
	>"$WORK/render-admission-labels.yaml"
render_as t --set driver.resourceAdmission.enabled=false --set-json 'driver.resourceAdmission.requiredLabels={}' \
	>"$WORK/render-admission-empty.yaml"

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
# mode only. The guard reads the effective values: with the in-pod gateway both
# default to its own pod, so the refusals need an external gateway.
try bad-3e-no-namespace 'driver.managedSshIngress.gatewayNamespace' t --set driver.workspaceMode=managed \
	--set gateway.enabled=false \
	--set driver.managedSshIngress.enabled=true --set 'driver.managedSshIngress.gatewayPodSelector[0]=app=gateway'
try bad-3e-no-selector 'driver.managedSshIngress.gatewayPodSelector' t --set driver.workspaceMode=managed \
	--set gateway.enabled=false \
	--set driver.managedSshIngress.enabled=true --set driver.managedSshIngress.gatewayNamespace=gw
try good-3e-shared-unchecked '' t --set driver.managedSshIngress.enabled=true
try good-3e-in-pod-defaults '' t --set driver.workspaceMode=managed --set driver.managedSshIngress.enabled=true

# 3f. A set sandbox UID/GID is a whole number from 1 to 4294967294; unset stays unset.
try bad-3f-uid-zero 'driver.sandboxUid' t --set driver.sandboxUid=0
try bad-3f-gid-zero 'driver.sandboxGid' t --set driver.sandboxGid=0
try bad-3f-fraction 'driver.sandboxUid' t --set-json driver.sandboxUid=1.5
try bad-3f-negative 'driver.sandboxUid' t --set driver.sandboxUid=-1
try bad-3f-too-big 'driver.sandboxUid' t --set driver.sandboxUid=4294967295
try bad-3f-not-a-number 'driver.sandboxUid' t --set-string driver.sandboxUid=abc
try good-3f-bounds '' t --set driver.sandboxUid=1 --set driver.sandboxGid=4294967294
try good-3f-unset '' t

# 3i. driver.socket must be two directories deep: upstream's bind_private requires
# the driver's uid to own the socket's parent, which the driver creates inside
# the emptyDir mounted at the grandparent.
try bad-3i-socket-one-level 'driver.socket' t --set driver.socket=/var/run/openshell-driver.sock
try bad-3i-socket-relative 'driver.socket' t --set driver.socket=run/openshell/driver.sock
try bad-3i-socket-top-level 'driver.socket' t --set driver.socket=/run/openshell/driver.sock
try good-3i-socket-deep '' t --set driver.socket=/run/openshell/sockets/driver.sock

# 3g. driver.allowDriverConfig is a real boolean: a string would render the JSON
# policy as "false", which the driver rejects.
try bad-3g-string 'driver.allowDriverConfig' t --set-string driver.allowDriverConfig=false
try bad-3g-admission-string 'driver.resourceAdmission.enabled' t --set-string driver.resourceAdmission.enabled=false
try bad-3g-labels-list 'driver.resourceAdmission.requiredLabels' t --set-json 'driver.resourceAdmission.requiredLabels=["a=b"]'
# ...and upstream refuses an empty label set while admission is enabled
# (resource_admission.rs:136), in three series: enabled with {} fails; enabled with
# null (upstream's built-in labels) or a non-empty map renders; disabled with {}
# renders, and reaches both sides as empty (check 2).
try bad-3g-admission-empty-labels 'driver.resourceAdmission.requiredLabels' t \
	--set driver.resourceAdmission.enabled=true --set-json 'driver.resourceAdmission.requiredLabels={}'
try good-3g-admission-null-labels '' t --set driver.resourceAdmission.enabled=true --set-json 'driver.resourceAdmission.requiredLabels=null'
try good-3g-admission-some-labels '' t --set driver.resourceAdmission.enabled=true \
	--set-json 'driver.resourceAdmission.requiredLabels={"example.com/approved":"yes"}'
try good-3g-admission-off-empty-labels '' t --set driver.resourceAdmission.enabled=false \
	--set-json 'driver.resourceAdmission.requiredLabels={}'

# 3h. Gateway settings that cannot work. Sandboxes dial the release's Service unless
# driver.gatewayEndpoint names another address, and their supervisors cannot
# bootstrap without the gateway's sandbox-JWT keys.
try bad-3h-gateway-no-service 'gatewayService.enabled' t --set gatewayService.enabled=false
try bad-3h-gateway-no-jwt 'gateway.sandboxJwt.enabled' t --set gateway.sandboxJwt.enabled=false
try good-3h-gateway-endpoint '' t --set gatewayService.enabled=false \
	--set driver.gatewayEndpoint=http://gateway.example:8080

# 3j. The driver validates the exposure kind (virtualservice or apirule) and the Istio
# Gateway (<namespace>/<name>, two DNS-1123 labels) at startup, exposure on or off.
try bad-3j-kind 'driver.exposureKind must be virtualservice or apirule, got "ingress"' t \
	--set driver.exposureKind=ingress
try bad-3j-gateway-no-namespace 'driver.istioGateway "kyma-gateway"' t --set driver.istioGateway=kyma-gateway
try bad-3j-gateway-three-parts 'driver.istioGateway "a/b/c"' t --set driver.istioGateway=a/b/c
try bad-3j-gateway-not-a-label 'driver.istioGateway "Kyma-System/kyma-gateway"' t \
	--set driver.istioGateway=Kyma-System/kyma-gateway
try good-3j-exposure '' t --set driver.enableApirule=true --set driver.clusterDomain=example.org \
	--set driver.exposureKind=apirule --set driver.istioGateway=istio-system/other-gateway

# 7 and 7b. An inference provider. Every value goes in explicitly and as the last
# word on its key: helm applies --set after --set-json, so an override of a --set
# value with --set-json would be ignored. baseUrl and modelId reach the sandboxes'
# environment, which the driver splits on commas, so the chart holds them to the same
# rules as driver.sandboxEnv: no comma, and not empty.
inference_url=http://gateway.llm.svc.cluster.local:8080/anthropic
inference_model=claude-opus-4-7
inference_common=(--set inferenceProvider.enabled=true --set inferenceProvider.type=anthropic
	--set inferenceProvider.credentialSecret.name=creds --set inferenceProvider.credentialSecret.key=api-key)
try bad-7b-url-comma 'http://gateway.llm.svc.cluster.local:8080/a,b' t "${inference_common[@]}" \
	--set-json 'inferenceProvider.baseUrl="http://gateway.llm.svc.cluster.local:8080/a,b"' \
	--set "inferenceProvider.modelId=$inference_model"
try bad-7b-model-comma 'claude-opus,4-7' t "${inference_common[@]}" \
	--set "inferenceProvider.baseUrl=$inference_url" --set-json 'inferenceProvider.modelId="claude-opus,4-7"'
try bad-7b-url-empty 'inferenceProvider.baseUrl' t "${inference_common[@]}" \
	--set inferenceProvider.baseUrl= --set "inferenceProvider.modelId=$inference_model"
try bad-7b-model-empty 'inferenceProvider.modelId' t "${inference_common[@]}" \
	--set "inferenceProvider.baseUrl=$inference_url" --set inferenceProvider.modelId=
try bad-7b-type 'inferenceProvider.type "openai"' t "${inference_common[@]}" \
	--set inferenceProvider.type=openai --set "inferenceProvider.baseUrl=$inference_url" \
	--set "inferenceProvider.modelId=$inference_model"
# bad-7b-url-* : the endpoint becomes the profile's host and port, so it must be a
# plain http(s) URL to a host name, and must not carry credentials (the message must
# not echo them either; check 7 tests that).
inference_try() {
	local name=$1 expect=$2
	shift 2
	try "$name" "$expect" t "${inference_common[@]}" --set "inferenceProvider.modelId=$inference_model" "$@"
}
inference_try bad-7b-url-no-scheme 'http:// or https://' --set inferenceProvider.baseUrl=gateway.llm.svc.cluster.local:8080/anthropic
inference_try bad-7b-url-ftp 'http:// or https://' --set inferenceProvider.baseUrl=ftp://gateway.llm.svc.cluster.local/anthropic
inference_try bad-7b-url-userinfo 'must not carry credentials' \
	--set inferenceProvider.baseUrl=http://user:secretpw@gateway.llm.svc.cluster.local:8080/anthropic
inference_try bad-7b-url-no-host 'has no host' --set inferenceProvider.baseUrl=http:///anthropic
inference_try bad-7b-url-ipv6 'IPv6' --set 'inferenceProvider.baseUrl=http://[::1]:8080/anthropic'
inference_try bad-7b-binaries-empty 'inferenceProvider.binaries' --set "inferenceProvider.baseUrl=$inference_url" \
	--set-json 'inferenceProvider.binaries=[]'
# 3h. The provider hook reaches the in-pod gateway through the release's Service, and
# cannot authenticate to a gateway with OIDC.
inference_try bad-3h-inference-no-service 'gatewayService.enabled' --set "inferenceProvider.baseUrl=$inference_url" \
	--set gatewayService.enabled=false --set driver.gatewayEndpoint=http://gateway.example:8080
inference_try bad-3h-inference-no-gateway 'gateway.enabled' --set "inferenceProvider.baseUrl=$inference_url" \
	--set gateway.enabled=false
inference_try bad-3h-inference-oidc 'gateway.oidc.issuer' --set "inferenceProvider.baseUrl=$inference_url" \
	--set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=openshell
# ...and the hook dials http:// with no client certificate, so it cannot reach a gateway
# with TLS: in three series, both together fail; TLS alone and the provider alone render.
inference_try bad-3h-inference-tls 'gateway.tls.enabled' --set "inferenceProvider.baseUrl=$inference_url" \
	--set gateway.tls.enabled=true
try good-3h-tls-no-inference '' t --set gateway.tls.enabled=true
try good-3h-inference-no-tls '' t "${inference_common[@]}" --set "inferenceProvider.baseUrl=$inference_url" \
	--set "inferenceProvider.modelId=$inference_model" --set gateway.tls.enabled=false
# The endpoint and model join what driver.sandboxEnv already sets, in that order.
try good-7-env '' t "${inference_common[@]}" --set "inferenceProvider.baseUrl=$inference_url" \
	--set "inferenceProvider.modelId=$inference_model" --set-json 'driver.sandboxEnv=["OPTS=a=b"]'
# An endpoint without a port gets its scheme's default port in the profile.
try good-7-https '' t "${inference_common[@]}" --set inferenceProvider.baseUrl=https://llm.example.org/anthropic \
	--set "inferenceProvider.modelId=$inference_model"
try good-7-http '' t "${inference_common[@]}" --set inferenceProvider.baseUrl=http://llm.example.org/anthropic \
	--set "inferenceProvider.modelId=$inference_model"
# The binaries in values are the binaries in the profile, and only those.
try good-7-binaries '' t "${inference_common[@]}" --set "inferenceProvider.baseUrl=$inference_url" \
	--set "inferenceProvider.modelId=$inference_model" \
	--set-json 'inferenceProvider.binaries=["/opt/agent/bin/python3","/usr/bin/node"]'

# 4 and 5. Renders for the NetworkPolicy and RBAC checks. Named rbac-*, so check 2's
# render-*.yaml glob skips them, and check 4's r*.yaml glob takes them.
# Exposure on (the renders are named after driver.enableApirule), in shared, managed
# (which also labels namespaces) and operator mode, through the default VirtualService;
# and in shared mode through an APIRule (the all-options render covers managed mode).
render_as t --set driver.enableApirule=true --set driver.clusterDomain=example.org \
	>"$WORK/rbac-apirule.yaml"
render_as t --set driver.enableApirule=true --set driver.clusterDomain=example.org \
	--set driver.exposureKind=apirule >"$WORK/rbac-apirule-kind.yaml"
render_as t --set driver.workspaceMode=managed --set gateway.sandboxJwt.gatewayId=gw \
	--set driver.enableApirule=true --set driver.clusterDomain=example.org \
	--set driver.workspacePsaLevel=baseline >"$WORK/rbac-managed-apirule.yaml"
render_as t --set driver.workspaceMode=managed --set gateway.sandboxJwt.gatewayId=gw \
	--set driver.workspacePsaLevel="" >"$WORK/rbac-managed-no-psa.yaml"
render_as t --set driver.workspaceMode=operator --set driver.operatorNamespaceLabel=team=a \
	--set driver.enableApirule=true --set driver.clusterDomain=example.org \
	>"$WORK/rbac-operator-apirule.yaml"
# Managed SSH ingress, which makes the driver write a NetworkPolicy in every workspace:
# on by default with the in-pod gateway and networkPolicy.enabled (every managed render
# above), here with an explicit namespace and selector, and off when networkPolicy is,
# with an external gateway, or when disabled explicitly.
render_as t --set driver.workspaceMode=managed --set gateway.sandboxJwt.gatewayId=gw \
	--set driver.managedSshIngress.enabled=true --set driver.managedSshIngress.gatewayNamespace=gw-ns \
	--set 'driver.managedSshIngress.gatewayPodSelector[0]=app=gateway' >"$WORK/rbac-managed-ssh.yaml"
render_as t --set driver.workspaceMode=managed --set gateway.sandboxJwt.gatewayId=gw \
	--set networkPolicy.enabled=false >"$WORK/rbac-managed-no-netpol.yaml"
render_as t --set driver.workspaceMode=managed --set gateway.sandboxJwt.gatewayId=gw \
	--set gateway.enabled=false >"$WORK/rbac-managed-no-gateway.yaml"
render_as t --set driver.workspaceMode=managed --set gateway.sandboxJwt.gatewayId=gw \
	--set driver.managedSshIngress.enabled=false >"$WORK/rbac-managed-ssh-off.yaml"
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
# Gateway TLS: the endpoint turns https and the driver defaults to the PKI hook's client
# TLS Secret, which managed and operator mode stage into workspaces; an explicit
# driver.clientTlsSecretName still wins.
render_as t --set gateway.tls.enabled=true >"$WORK/rbac-shared-tls.yaml"
render_as t --set gateway.tls.enabled=true --set driver.workspaceMode=managed \
	--set gateway.sandboxJwt.gatewayId=gw >"$WORK/rbac-managed-tls.yaml"
render_as t --set gateway.tls.enabled=true --set driver.workspaceMode=operator \
	--set driver.operatorNamespaceLabel=team=a --set driver.clientTlsSecretName=own-tls >"$WORK/rbac-operator-tls.yaml"
# NetworkPolicies off; an external gateway (the chart's default gateway.enabled=false,
# which render_as overrides); and the bedrock bridge, which has a NetworkPolicy of its own.
render_as t --set networkPolicy.enabled=false >"$WORK/rbac-shared-no-netpol.yaml"
# OTLP trace export: the driver pod may reach the collector's port; 80 and 443 are the
# schemes' defaults, and an endpoint without a scheme, which upstream cannot export to,
# opens nothing. (The all-options render names port 4317.)
render_as t --set driver.otlpEndpoint=https://collector.example >"$WORK/rbac-otlp-https.yaml"
render_as t --set driver.otlpEndpoint=http://collector.example >"$WORK/rbac-otlp-http.yaml"
render_as t --set driver.otlpEndpoint=collector.example:4317 >"$WORK/rbac-otlp-no-scheme.yaml"
render_as t --set driver.otlpEndpoint=http://collector.example:4317 --set networkPolicy.enabled=false \
	>"$WORK/rbac-otlp-no-netpol.yaml"
render_as t --set gateway.enabled=false >"$WORK/rbac-shared-no-gateway.yaml"
render_as t --set bedrockBridge.enabled=true --set bedrockBridge.sap.serviceKeySecret.name=sap-key \
	--set bedrockBridge.singleDeploymentId=deployment >"$WORK/rbac-bedrock-bridge.yaml"
# An inference provider, whose hook has a Role of its own that must not reach the driver.
render_as t "${inference_common[@]}" --set "inferenceProvider.baseUrl=$inference_url" \
	--set "inferenceProvider.modelId=$inference_model" >"$WORK/rbac-inference.yaml"

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

# 2. gateway and driver agree on the whole admission policy, and it is the one values
# set. Both sides are reduced to upstream's effective DriverAdmissionConfig
# (openshell-core src/resource_admission.rs): allow_driver_config defaults to false,
# resource_admission.enabled to true, and required_labels, when absent, to the
# built-in pair; unknown fields are refused, as upstream's deny_unknown_fields does.
BUILTIN_LABELS = {"openshell.ai/sandbox-attachable": "true",
                  "openshell.ai/sandbox-attachable-workspace": "${workspace}"}
CUSTOM_LABELS = {"example.com/approved": "yes", "example.com/team": "${workspace}"}
# render -> (allow_driver_config, resource_admission.enabled, required_labels)
EXPECTED_POLICY = {
    "render-shared-true": (True, True, BUILTIN_LABELS),
    "render-shared-false": (False, True, BUILTIN_LABELS),
    "render-managed-true": (True, True, BUILTIN_LABELS),
    "render-managed-false": (False, True, BUILTIN_LABELS),
    "render-admission-off": (False, False, BUILTIN_LABELS),
    "render-admission-labels": (False, True, CUSTOM_LABELS),
    "render-admission-empty": (False, False, {}),
}
TOML_KEY = r'(?:[A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*")'
TOML_VALUE = r'(?:true|false|-?[0-9]+|"(?:[^"\\]|\\.)*")'

def toml_tables(text, where):
    """{table: {key: value}} of the simple TOML the chart renders: [table] headers,
    and `key = value` lines with a bare or quoted key and a boolean, integer or
    quoted string value. Any other line is a failure, so nothing can hide from check 2."""
    tables, current = {}, None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        header = re.fullmatch(r"\[([A-Za-z0-9_.-]+)\]", line)
        if header:
            current = tables.setdefault(header.group(1), {})
            continue
        pair = re.fullmatch(rf"({TOML_KEY})\s*=\s*({TOML_VALUE})", line)
        if not pair or current is None:
            failures.append(f"{where}: gateway TOML line check 2 cannot read: {line!r}")
            continue
        key, value = pair.groups()
        current[json.loads(key) if key.startswith('"') else key] = (
            value == "true" if value in ("true", "false") else json.loads(value))
    return tables

def effective_policy(allow, admission, labels, where, side):
    if not isinstance(allow, bool) or not isinstance(admission.get("enabled", True), bool):
        failures.append(f"{where}: the {side} admission policy has a non-boolean flag: {allow!r}, {admission!r}")
    return (allow, admission.get("enabled", True), BUILTIN_LABELS if labels is None else labels)

for render in sorted(work.glob("render-*.yaml")):
    expected = EXPECTED_POLICY.get(render.stem)
    if expected is None:
        failures.append(f"{render.name}: no expected admission policy in check 2's table")
        continue
    documents = docs(render)
    toml = next(d["data"]["gateway.toml"] for d in documents
                if d.get("kind") == "ConfigMap" and "gateway.toml" in d.get("data", {}))
    tables = toml_tables(toml, render.name)
    kyma = tables.get("openshell.drivers.kyma", {})
    toml_admission = tables.get("openshell.drivers.kyma.resource_admission", {})
    extra = (set(kyma) - {"socket_path", "allow_driver_config"}) | (set(toml_admission) - {"enabled"})
    if extra:
        failures.append(f"{render.name}: unexpected keys in the gateway's kyma driver tables: {sorted(extra)}")
    gateway_side = effective_policy(kyma.get("allow_driver_config", False), toml_admission,
                                    tables.get("openshell.drivers.kyma.resource_admission.required_labels"),
                                    render.name, "gateway")
    env = {e["name"]: e.get("value") for e in driver_container(documents).get("env", [])}
    policy = json.loads(env.get("OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON") or "null")
    if not isinstance(policy, dict):
        failures.append(f"{render.name}: OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON is not a JSON object: {policy!r}")
        continue
    json_admission = policy.get("resource_admission", {})
    extra = (set(policy) - {"allow_driver_config", "resource_admission"}) | (
        set(json_admission) - {"enabled", "required_labels"})
    if extra:
        failures.append(f"{render.name}: unknown fields in the driver's admission JSON, which upstream refuses: {sorted(extra)}")
    driver_side = effective_policy(policy.get("allow_driver_config", False), json_admission,
                                   json_admission.get("required_labels"), render.name, "driver")
    if not (gateway_side == driver_side == expected):
        failures.append(f"{render.name}: admission policy (allow_driver_config, enabled, required_labels) "
                        f"gateway={gateway_side}, driver={driver_side}, values={expected}")
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

# 3i. the socket's grandparent is the shared emptyDir in BOTH containers: upstream's
# bind_private makes the driver create and own the parent (chmod 0700), and the
# gateway (same uid) dials the socket through it.
for d in docs(work / "render-shared-true.yaml"):
    if d.get("kind") != "Deployment":
        continue
    pod = d["spec"]["template"]["spec"]
    env = {e["name"]: e.get("value") for e in driver_container([d]).get("env", [])}
    sock = env.get("OPENSHELL_COMPUTE_DRIVER_SOCKET") or ""
    grand = str(pathlib.PurePosixPath(sock).parent.parent)
    if sock.count("/") < 4:
        failures.append(f"OPENSHELL_COMPUTE_DRIVER_SOCKET={sock!r} is not three directories deep")
    for c in pod["containers"]:
        if c["name"] not in ("driver", "gateway"):
            continue
        mounts = {m["name"]: m["mountPath"] for m in c.get("volumeMounts", [])}
        if mounts.get("socket-dir") != grand:
            failures.append(f"{c['name']} mounts socket-dir at {mounts.get('socket-dir')!r}, "
                            f"expected the socket's grandparent {grand!r}")
    if not any(v.get("name") == "socket-dir" and "emptyDir" in v for v in pod.get("volumes", [])):
        failures.append("socket-dir is not an emptyDir")

# 3b-3j and 7b. values upstream or the driver would refuse fail the render, naming the value
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
for name in ("good-3g-admission-null-labels", "good-3g-admission-some-labels", "good-3g-admission-off-empty-labels",
             "good-3h-tls-no-inference", "good-3h-inference-no-tls"):
    rendered(name)
env = rendered("good-3h-gateway-endpoint")
if env is not None and env.get("OPENSHELL_GRPC_ENDPOINT") != "http://gateway.example:8080":
    failures.append(f"driver.gatewayEndpoint did not reach the driver: {env.get('OPENSHELL_GRPC_ENDPOINT')!r}")
env = rendered("good-3e-in-pod-defaults")
if env is not None and (env.get("OPENSHELL_MANAGED_SSH_INGRESS_ENABLED") != "true"
                        or not env.get("OPENSHELL_MANAGED_SSH_GATEWAY_NAMESPACE")
                        or not env.get("OPENSHELL_MANAGED_SSH_GATEWAY_POD_SELECTOR")):
    failures.append("managed SSH ingress enabled with the in-pod gateway did not default its gateway "
                    f"namespace and pod selector: {env}")

env = rendered("good-3f-bounds")
if env is not None and (env.get("OPENSHELL_K8S_SANDBOX_UID"), env.get("OPENSHELL_K8S_SANDBOX_GID")) != ("1", "4294967294"):
    failures.append("the sandbox UID/GID bounds did not reach the driver as digits: "
                    f"{env.get('OPENSHELL_K8S_SANDBOX_UID')!r}, {env.get('OPENSHELL_K8S_SANDBOX_GID')!r}")
env = rendered("good-3f-unset")
if env is not None and ("OPENSHELL_K8S_SANDBOX_UID" in env or "OPENSHELL_K8S_SANDBOX_GID" in env):
    failures.append("an unset sandbox UID/GID was still passed to the driver")

# 3j. the chart's exposure defaults are the driver's (kyma_args.rs), and set values reach it
EXPOSURE_ENV = ("OPENSHELL_KYMA_EXPOSURE_KIND", "OPENSHELL_KYMA_ISTIO_GATEWAY")
env = {e["name"]: e.get("value") for e in driver_container(docs(work / "render-shared-true.yaml")).get("env", [])}
if tuple(env.get(n) for n in EXPOSURE_ENV) != ("virtualservice", "kyma-system/kyma-gateway"):
    failures.append(f"the default render passes {[env.get(n) for n in EXPOSURE_ENV]} as {list(EXPOSURE_ENV)}, "
                    "not the driver's defaults virtualservice and kyma-system/kyma-gateway")
env = rendered("good-3j-exposure")
if env is not None and tuple(env.get(n) for n in EXPOSURE_ENV) != ("apirule", "istio-system/other-gateway"):
    failures.append(f"driver.exposureKind and driver.istioGateway did not reach the driver: "
                    f"{[env.get(n) for n in EXPOSURE_ENV]}")

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
                      "rbac-otlp-no-netpol.yaml": "networkPolicy.enabled=false",
                      "rbac-shared-no-gateway.yaml": "gateway.enabled=false"}

# Managed-mode renders -> the driver's managed SSH ingress (gateway namespace, pod
# selector), or None when it must be off. None for a namespace is the release's.
# Upstream derives it from networkPolicy.enabled with its own gateway pod
# (deploy/helm/openshell/templates/gateway-config.yaml:230-233); here that pod is
# the in-pod gateway's, the chart's own.
MANAGED_SSH = {
    "render-managed-true": (None, own_pods[0]),
    "render-managed-false": (None, own_pods[0]),
    "rbac-managed-apirule": (None, own_pods[0]),
    "rbac-managed-secrets": (None, own_pods[0]),
    "rbac-managed-no-psa": (None, own_pods[0]),                 # in-pod gateway, PSA label cleared
    "rbac-managed-ssh": ("gw-ns", {"app": "gateway"}),            # explicit values override the defaults
    "rbac-managed-no-netpol": None,                              # networkPolicy.enabled=false, as upstream
    "rbac-managed-no-gateway": None,                             # an external gateway: nothing derived
    "rbac-managed-ssh-off": None,                                # driver.managedSshIngress.enabled=false
    "rbac-managed-tls": (None, own_pods[0]),
    "good-all-options.yaml": ("example-gateway", {"app": "gateway"}),
}

# The driver pod's egress: DNS and the apiserver's 443, and the OTLP collector's port
# (render -> port) when driver.otlpEndpoint is set.
DRIVER_EGRESS = [{"ports": [{"port": 53, "protocol": "UDP"}, {"port": 53, "protocol": "TCP"}]},
                 {"ports": [{"port": 443, "protocol": "TCP"}]}]
OTLP_PORT = {"good-all-options.yaml": 4317, "rbac-otlp-https.yaml": 443, "rbac-otlp-http.yaml": 80}

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
    env = {e["name"]: e.get("value") for e in driver_container(documents).get("env", [])}
    ssh_env = (env.get("OPENSHELL_MANAGED_SSH_INGRESS_ENABLED"), env.get("OPENSHELL_MANAGED_SSH_GATEWAY_NAMESPACE"),
               dict(e.split("=", 1) for e in env["OPENSHELL_MANAGED_SSH_GATEWAY_POD_SELECTOR"].split(","))
               if env.get("OPENSHELL_MANAGED_SSH_GATEWAY_POD_SELECTOR") else None)
    key = render.stem if render.stem in MANAGED_SSH else render.name
    if mode == "managed":
        if key not in MANAGED_SSH:
            failures.append(f"{render.name}: a managed-mode render with no entry in check 4's MANAGED_SSH table")
        else:
            want_ssh = MANAGED_SSH[key]
            want_env = (None, None, None) if want_ssh is None else (
                "true", want_ssh[0] or pod["metadata"].get("namespace"), want_ssh[1])
            if ssh_env != want_env:
                failures.append(f"{render.name}: managed SSH ingress (enabled, gateway namespace, pod selector) "
                                f"is {ssh_env}, want {want_env}")
    elif ssh_env[0] is not None:
        failures.append(f"{render.name}: managed SSH ingress is enabled in {mode} mode, where nothing sets it")
    policies = [d for d in documents if d.get("kind") == "NetworkPolicy"]
    ssh = [d for d in policies if d["metadata"]["name"].endswith("-sandbox-ssh")]
    want = 1 if mode == "shared" and render.name not in NO_SSH_RESTRICTION else 0
    if len(ssh) != want:
        failures.append(f"{render.name}: {len(ssh)} SSH-ingress restrictions in {mode} mode"
                        + (f" with {NO_SSH_RESTRICTION[render.name]}" if render.name in NO_SSH_RESTRICTION else "")
                        + f", want {want}")
    driver_policy = [d for d in policies if d["metadata"]["name"] == pod["metadata"]["name"] + "-driver"]
    if driver_policy:
        otlp = OTLP_PORT.get(render.name)
        want_egress = DRIVER_EGRESS + ([{"ports": [{"port": otlp, "protocol": "TCP"}]}] if otlp else [])
        if (driver_policy[0].get("spec") or {}).get("egress") != want_egress:
            failures.append(f"{render.name}: the driver pod's egress is {driver_policy[0]['spec'].get('egress')}, "
                            f"want {want_egress}")
    elif render.name == "rbac-otlp-no-netpol.yaml" and policies:
        failures.append(f"{render.name}: NetworkPolicies rendered with networkPolicy.enabled=false")
    elif render.name not in ("rbac-shared-no-netpol.yaml", "rbac-managed-no-netpol.yaml", "rbac-otlp-no-netpol.yaml"):
        failures.append(f"{render.name}: no NetworkPolicy for the driver pod")
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
# networkPolicy.enabled, which sets managed_ssh_ingress.enabled there; here it follows the effective
# managed SSH ingress, which derives from networkPolicy.enabled with the in-pod gateway (see check 4).
SSH_INGRESS_POLICY = [("networking.k8s.io", "networkpolicies", ["get", "create", "patch", "update"])]
# The Kyma layer (src/exposure.rs, src/namespaces.rs): server-side apply of a Service, a
# NetworkPolicy and a route, a VirtualService by default or an APIRule with
# driver.exposureKind=apirule, never both (patch, and create for a new object; nothing
# reads a route), a failure Event, and a merge patch that labels a managed namespace.
KYMA_EXPOSURE = [("", "services", ["patch"]), ("networking.k8s.io", "networkpolicies", ["patch"]),
                 ("networking.istio.io", "virtualservices", ["create", "patch"]), ("", "events", ["create"])]
KYMA_EXPOSURE_APIRULE = [("", "services", ["patch"]), ("networking.k8s.io", "networkpolicies", ["patch"]),
                         ("gateway.kyma-project.io", "apirules", ["create", "patch"]), ("", "events", ["create"])]
KYMA_PSA_LABEL = [("", "namespaces", ["patch"])]

def secret_sources(*names):
    """upstream's workspace-secret-source-role.yaml: get on exactly these Secrets."""
    return [("", "secrets", ["get"], names)]

# driver.allowDriverConfig defaults to false, as upstream's does, so PVC_GET is added
# only to the renders that set it true.
SHARED = [WORKLOAD, BOOTSTRAP_SECRETS]     # in the sandbox namespace, by the Role
SHARED_CLUSTER = [NODE_READER, NAMESPACE_GET]
MANAGED = [NODE_READER, NAMESPACE_GET, NAMESPACE_DISCOVERY, NAMESPACE_LIFECYCLE, WORKLOAD,
           BOOTSTRAP_SECRETS, WORKSPACE_SERVICEACCOUNTS,
           KYMA_PSA_LABEL]  # driver.workspacePsaLevel defaults to restricted (v0.9.0 live check)
OPERATOR = [NODE_READER, NAMESPACE_GET, NAMESPACE_DISCOVERY, WORKLOAD]   # no secrets, no lifecycle
opts = (yaml.safe_load(all_options.read_text()) or {})["driver"]
all_options_secrets = secret_sources(opts["clientTlsSecretName"], *opts["sandboxImagePullSecrets"])

# render -> (blocks the driver holds in the sandbox namespace, blocks it holds cluster-wide)
EXPECTED = {
    "render-shared-true": (SHARED + [PVC_GET], SHARED_CLUSTER),                            # allowDriverConfig adds PVC get
    "render-shared-false": (SHARED, SHARED_CLUSTER),
    "rbac-shared-no-netpol": (SHARED, SHARED_CLUSTER),
    "rbac-shared-no-gateway": (SHARED, SHARED_CLUSTER),                                    # an external gateway changes no RBAC
    "rbac-apirule": (SHARED + [KYMA_EXPOSURE], SHARED_CLUSTER),
    "rbac-apirule-kind": (SHARED + [KYMA_EXPOSURE_APIRULE], SHARED_CLUSTER),               # driver.exposureKind=apirule
    "rbac-shared-secrets": (SHARED, SHARED_CLUSTER),                                       # shared mode stages no Secret
    "rbac-inference": (SHARED, SHARED_CLUSTER),                                            # the hook's own Role is bound to the hook
    # Managed SSH ingress is on by default with the in-pod gateway and networkPolicy.enabled.
    "render-managed-true": ([], MANAGED + [PVC_GET, SSH_INGRESS_POLICY]),
    "render-managed-false": ([], MANAGED + [SSH_INGRESS_POLICY]),
    "rbac-managed-apirule": ([], MANAGED + [SSH_INGRESS_POLICY, KYMA_EXPOSURE, KYMA_PSA_LABEL]),
    "rbac-managed-no-psa": ([], [b for b in MANAGED if b is not KYMA_PSA_LABEL] + [SSH_INGRESS_POLICY]),
    "rbac-managed-ssh": ([], MANAGED + [SSH_INGRESS_POLICY]),
    "rbac-managed-no-netpol": ([], MANAGED),                                               # as upstream, off with networkPolicy
    "rbac-managed-no-gateway": ([], MANAGED),                                              # an external gateway: off unless set
    "rbac-managed-ssh-off": ([], MANAGED),
    "rbac-managed-secrets": ([secret_sources("client-tls", "pull-a", "pull-b")], MANAGED + [SSH_INGRESS_POLICY]),
    "rbac-operator-apirule": ([], OPERATOR + [KYMA_EXPOSURE]),
    "rbac-operator-secrets": ([secret_sources("client-tls")], OPERATOR),                   # TLS Secret only, no pull Secrets
    # Gateway TLS: the PKI hook's client TLS Secret is the driver's by default.
    "rbac-shared-tls": (SHARED, SHARED_CLUSTER),                                           # shared mode stages no Secret
    "rbac-managed-tls": ([secret_sources("t-openshell-driver-kyma-client-tls")], MANAGED + [SSH_INGRESS_POLICY]),
    "rbac-operator-tls": ([secret_sources("own-tls")], OPERATOR),                          # an explicit name wins
    "good-all-options": ([all_options_secrets],                                            # driver.exposureKind=apirule
                         MANAGED + [PVC_GET, SSH_INGRESS_POLICY, KYMA_EXPOSURE_APIRULE, KYMA_PSA_LABEL]),
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

# 6b. The endpoint sandboxes dial is https:// exactly when the in-pod gateway serves TLS
# (upstream's openshell.grpcEndpoint takes the scheme from disableTls), and the driver
# then mounts the PKI hook's client TLS Secret unless driver.clientTlsSecretName names one.
TLS_ENDPOINT = {  # render -> (scheme, OPENSHELL_CLIENT_TLS_SECRET_NAME)
    "render-shared-true": ("http", None),
    "rbac-shared-tls": ("https", "t-openshell-driver-kyma-client-tls"),
    "rbac-managed-tls": ("https", "t-openshell-driver-kyma-client-tls"),
    "rbac-operator-tls": ("https", "own-tls"),
    "rbac-managed-secrets": ("http", "client-tls"),
}
for name, (scheme, secret) in TLS_ENDPOINT.items():
    env = {e["name"]: e.get("value") for e in driver_container(docs(work / f"{name}.yaml")).get("env", [])}
    endpoint = env.get("OPENSHELL_GRPC_ENDPOINT") or ""
    want = f"{scheme}://t-openshell-driver-kyma."
    if not endpoint.startswith(want) or env.get("OPENSHELL_CLIENT_TLS_SECRET_NAME") != secret:
        failures.append(f"{name}: OPENSHELL_GRPC_ENDPOINT={endpoint!r} and OPENSHELL_CLIENT_TLS_SECRET_NAME="
                        f"{env.get('OPENSHELL_CLIENT_TLS_SECRET_NAME')!r}, want {want}... and {secret!r}")

# 7. providers use upstream's profile model, the pinned CLI, and reach sandboxes
templates = "\n".join(p.read_text() for p in sorted((chart / "templates").iterdir()) if p.is_file())
# The removed command in any spelling: `openshell inference set`, or with the global
# flags between, as in `openshell --gateway-endpoint "$URL" inference set`.
REMOVED_INFERENCE = re.compile(r"\bopenshell\b[^\n]*\binference\s+[a-z]")
if REMOVED_INFERENCE.search(templates) or "inference set" in templates:
    failures.append("templates still call the removed `openshell inference` command")

def profile_of(documents):
    """The provider profile ConfigMap of a render and the profile it holds, or (None, None)."""
    cm = next((d for d in documents if d.get("kind") == "ConfigMap"
               and "profile.yaml" in d.get("data", {})), None)
    return cm, yaml.safe_load(cm["data"]["profile.yaml"]) if cm else None

def check_endpoint(profile, host, port, where):
    # The credential is bound to every endpoint of the profile: more than the one
    # inference endpoint would hand the API key to more hosts.
    endpoints = profile.get("endpoints") or []
    if len(endpoints) != 1:
        failures.append(f"{where}: the profile has {len(endpoints)} endpoints, want exactly the one "
                        f"inference endpoint: {[e.get('host') for e in endpoints]}")
    elif (endpoints[0].get("host"), endpoints[0].get("port")) != (host, port):
        failures.append(f"{where}: profile endpoint {endpoints[0]} is not {host}:{port} from inferenceProvider.baseUrl")

inference = docs(work / "rbac-inference.yaml")
profile_cm, profile = profile_of(inference)
default_binaries = ((yaml.safe_load(values) or {}).get("inferenceProvider") or {}).get("binaries")
if profile_cm is None:
    failures.append("no provider profile ConfigMap rendered")
else:
    check_endpoint(profile, "gateway.llm.svc.cluster.local", 8080, "rbac-inference")
    if profile.get("binaries") != default_binaries:
        failures.append(f"profile binaries {profile.get('binaries')} are not inferenceProvider.binaries "
                        f"of values.yaml {default_binaries}")
    if "/usr/bin/node" not in (profile.get("binaries") or []):
        failures.append("profile binaries must include node, which runs claude-code")
    wild = [b for b in profile.get("binaries") or [] if "*" in str(b)]
    if wild:
        failures.append(f"profile binaries contain a wildcard, which would let any process use the credential: {wild}")
# The chart has other hook Jobs (the gateway's PKI): the provider's is the one named for it.
job = next((d for d in inference if d.get("kind") == "Job"
            and d["metadata"]["name"].endswith("-inference-provider-hook")), None)
if job is None:
    failures.append("no inference provider hook Job rendered")
else:
    pod_spec = job["spec"]["template"]["spec"]
    hook = pod_spec["containers"][0]
    job_env = {e["name"]: e.get("value") for e in hook.get("env", [])}
    if job_env.get("CLI_VERSION") != pinned:
        failures.append(f"hook CLI_VERSION={job_env.get('CLI_VERSION')!r}, expected the pinned {pinned!r}")
    # The API key reaches the hook only from its Secret, and never leaves the CLI's own
    # environment lookup (`--credential ANTHROPIC_API_KEY`): not in the pod spec, not
    # expanded in the script (an argument shows in the process list), not traced.
    key_env = [e for e in hook.get("env", []) if e["name"] == "ANTHROPIC_API_KEY"]
    ref = (key_env[0].get("valueFrom") or {}).get("secretKeyRef") if len(key_env) == 1 else None
    if len(key_env) != 1 or "value" in key_env[0] or not ref:
        failures.append(f"the hook's ANTHROPIC_API_KEY env must be exactly one secretKeyRef entry with no literal value: {key_env}")
    elif (ref.get("name"), ref.get("key")) != ("creds", "api-key"):
        failures.append(f"the hook's ANTHROPIC_API_KEY comes from {ref}, not inferenceProvider.credentialSecret")
    command = hook.get("command") or []
    script = command[-1] if command else ""
    if re.search(r"\$\{?ANTHROPIC_API_KEY\b", script):
        failures.append("the hook script expands ANTHROPIC_API_KEY; the CLI must read it from its own environment")
    if re.search(r"(?:^|[\s;&|(])set\s+(?:-[A-Za-z]*x|-o\s+xtrace)", script, re.M) or any(
            arg.startswith("-") and "x" in arg[1:] for arg in command[1:-1]):
        failures.append("the hook script traces its commands (set -x / sh -x), which would print the key")
    if REMOVED_INFERENCE.search(script) or "inference set" in script:
        failures.append("the hook script still calls the removed `openshell inference` command")
    # The CLI is the pinned release's, checked against its checksum file before it runs.
    tags = re.findall(r'releases/download/([^/\s"]+)', script)
    if not tags or set(tags) != {"${CLI_VERSION}"}:
        failures.append(f"the hook downloads from release tag(s) {sorted(set(tags))}, want only ${{CLI_VERSION}}")
    extract = re.search(r"^\s*tar\s+-x", script, re.M)
    if ("uname -m" not in script or "openshell-checksums-sha256.txt" not in script
            or "sha256sum -c" not in script or not extract
            or script.index("sha256sum -c") > extract.start()):
        failures.append("the hook must pick the CLI asset by `uname -m` and verify it against "
                        "openshell-checksums-sha256.txt (sha256sum -c) before extracting it")
    # ...and it registers the profile this render holds, mounted from that ConfigMap.
    volume = next((v for v in pod_spec.get("volumes") or [] if v.get("name") == "profile"), None)
    mount = next((m for m in hook.get("volumeMounts") or [] if m.get("name") == "profile"), None)
    if profile_cm is not None and (
            (volume or {}).get("configMap", {}).get("name") != profile_cm["metadata"]["name"]
            or not profile_cm["metadata"]["name"].endswith("-inference-profile")):
        failures.append(f"the hook's profile volume {volume} is not the rendered ConfigMap "
                        f"{profile_cm['metadata']['name']}")
    if (mount or {}).get("mountPath") != "/profile" or "/profile/profile.yaml" not in script:
        failures.append(f"the hook does not read the profile from its mount: {mount}")
driver_env = {e["name"]: e.get("value") for e in driver_container(inference).get("env", [])}
sandbox_env = driver_env.get("OPENSHELL_KYMA_SANDBOX_ENV", "")
for wanted in ("ANTHROPIC_BASE_URL=http://gateway.llm.svc.cluster.local:8080/anthropic",
               "ANTHROPIC_MODEL=claude-opus-4-7"):
    if wanted not in sandbox_env.split(","):
        failures.append(f"sandboxes do not receive {wanted}")

env = rendered("good-7-env")
if env is not None and env.get("OPENSHELL_KYMA_SANDBOX_ENV") != (
        "OPTS=a=b,ANTHROPIC_BASE_URL=http://gateway.llm.svc.cluster.local:8080/anthropic,"
        "ANTHROPIC_MODEL=claude-opus-4-7"):
    failures.append("the provider's endpoint and model did not follow driver.sandboxEnv in "
                    f"OPENSHELL_KYMA_SANDBOX_ENV: {env.get('OPENSHELL_KYMA_SANDBOX_ENV')!r}")
# An endpoint without a port gets its scheme's default port; binaries pass through as set.
for name, host, port in (("good-7-https", "llm.example.org", 443), ("good-7-http", "llm.example.org", 80)):
    if rendered(name) is not None:
        _, rendered_profile = profile_of(docs(work / f"{name}.yaml"))
        if rendered_profile is None:
            failures.append(f"{name}: no provider profile ConfigMap rendered")
        else:
            check_endpoint(rendered_profile, host, port, name)
if rendered("good-7-binaries") is not None:
    _, rendered_profile = profile_of(docs(work / "good-7-binaries.yaml"))
    if (rendered_profile or {}).get("binaries") != ["/opt/agent/bin/python3", "/usr/bin/node"]:
        failures.append("inferenceProvider.binaries did not reach the profile exactly as set: "
                        f"{(rendered_profile or {}).get('binaries')}")
# A URL's credentials must never be echoed by the error that refuses them.
userinfo_err = work / "bad-7b-url-userinfo.err"
if userinfo_err.exists() and "secretpw" in userinfo_err.read_text():
    failures.append("bad-7b-url-userinfo: the render error echoes the credentials in inferenceProvider.baseUrl")

if failures:
    print("CHART_RENDER_FAIL:")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("CHART_RENDER_OK")
PY
