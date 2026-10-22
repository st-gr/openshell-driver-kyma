#!/usr/bin/env bash
#
# Prove the chart's cert-manager, Vault and SPIFFE options work on a real
# cluster, one per run:
#
#   DRIVER_IMAGE=openshell-driver-kyma:smoke ./scripts/parity-smoke.sh MODE
#
# MODE is cert-manager, vault or spiffe. The script installs what the mode
# needs, runs scripts/interop-smoke.sh with the mode's values file
# (scripts/testdata/parity-smoke-MODE.yaml, passed as HELM_EXTRA_VALUES), then
# asserts what that option should have changed. It prints
# `PARITY_SMOKE_OK MODE` on success.
#
# Assumes what interop-smoke.sh assumes: a throwaway kind cluster as the
# current kubectl context, the driver image loaded into it, helm and curl.
# Run it from anywhere; it changes to the repository root.
#
# Pinned prerequisites. Each is an exact release at least two weeks old when
# chosen (2026-10-22), downloaded from the project's own release location and
# checked against the sha256 below before use:
#
#   cert-manager v1.21.2 (2026-09-11), static manifest
#     https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml
#   HashiCorp Vault Helm chart 0.34.1 (2026-08-13), from
#     https://helm.releases.hashicorp.com/vault-0.34.1.tgz
#     running hashicorp/vault 2.0.4 pinned by digest (VAULT_IMAGE_DIGEST)
#   SPIRE, spiffe/helm-charts-hardened spire 0.30.2 (2026-09-09, SPIRE 1.15.3,
#     with the SPIFFE CSI driver) and spire-crds 0.6.1 (2026-08-23), from
#     https://github.com/spiffe/helm-charts-hardened/releases
#
# The upstream openshell CLI (vault mode) is the one interop-smoke.sh uses, the
# chart's upstream.version, checked against that release's checksum file.

set -euo pipefail

CERT_MANAGER_VERSION=v1.21.2
CERT_MANAGER_SHA256=e03b668ec8675214af6b0a671699d088f2601fa3878e0dbe1b41d3feafd1879f
VAULT_CHART_VERSION=0.34.1
VAULT_CHART_SHA256=df4c37fac32496892ff1e1d6fd7954d3a402cc7b1b2b4c2226af11b8a57564c4
VAULT_IMAGE_TAG=2.0.4
VAULT_IMAGE_DIGEST=sha256:5be49781ecf78bfe775c5309c6a4d9f4e9e040b6c885c99eb2b12fb69855e1a2
SPIRE_CHART_VERSION=0.30.2
SPIRE_CHART_SHA256=aadaeabe1dfecbcd803d541580ab41c229d99c0075ace3b6e050b0ceef36aa8d
SPIRE_CRDS_CHART_VERSION=0.6.1
SPIRE_CRDS_CHART_SHA256=ce982e63fc375e392b014fc99e621a55442ab886052413e9bb052f72d66580a8

# Fixed by interop-smoke.sh.
NS=openshell-system
RELEASE=ods
FULLNAME=${RELEASE}-openshell-driver-kyma

VAULT_NS=vault
VAULT_CA_CONFIGMAP=parity-smoke-vault-ca   # the values file names it
VAULT_ROLE=openshell-gateway               # the values file names it
# The ServiceAccount the gateway logs in to Vault with: the chart's
# serviceAccount.name default, which the driver and gateway share.
GATEWAY_SA=openshell-driver

log()  { printf '\n=== parity-smoke: %s\n' "$*"; }
fail() { printf '\nFAIL (parity-smoke %s): %s\n' "${MODE:-?}" "$*" >&2; dump_diagnostics; exit 1; }
# What a CI-only failure needs: every pod in the cluster, and the gateway's
# and driver's logs. Best effort; never fails itself.
dump_diagnostics() {
	printf '\n--- pods (all namespaces) ---\n' >&2
	kubectl get pods -A -o wide >&2 2>&1 || true
	local c
	for c in gateway driver; do
		printf '\n--- %s log (last 200 lines) ---\n' "$c" >&2
		kubectl -n "$NS" logs "deploy/${FULLNAME}" -c "$c" --tail=200 2>&1 | strip_ansi >&2 || true
	done
}
strip_ansi() { sed $'s/\033\\[[0-9;]*m//g'; }

usage() { echo "usage: DRIVER_IMAGE=<image> $0 cert-manager|vault|spiffe" >&2; exit 2; }

MODE=${1:-}
case $MODE in
	cert-manager | vault | spiffe) ;;
	*) usage ;;
esac
[[ -n ${DRIVER_IMAGE:-} ]] || { echo "error: DRIVER_IMAGE is required" >&2; exit 1; }

# This installs cert-manager, Vault, SPIRE and CRDs into whatever cluster the
# current context names. Refuse anything but a kind cluster, before the first
# helm, kubectl or openshell action. No override.
ctx=$(kubectl config current-context 2>/dev/null || true)
[[ $ctx == kind-* ]] || { echo "refusing to run: current kube context '${ctx}' is not a kind cluster" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."
WORK="$(mktemp -d)"
PF_PID=""   # the vault assertion's port-forward
trap '[[ -z $PF_PID ]] || kill "$PF_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT

fetch() { # url sha256 dest
	curl -fsSL --retry 3 --retry-delay 2 -o "$3" "$1" || fail "could not download $1"
	echo "$2  $3" | sha256sum -c - >/dev/null || fail "$1 does not match the pinned sha256 $2"
}

gateway_pod() {
	kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/name=openshell-driver-kyma" \
		-o jsonpath='{.items[0].metadata.name}'
}

assert_gateway_pod_ready() {
	local pod
	pod=$(gateway_pod) && [[ -n $pod ]] || fail "no driver+gateway pod found"
	kubectl -n "$NS" wait --for=condition=Ready "pod/${pod}" --timeout=2m >/dev/null \
		|| fail "the driver+gateway pod ${pod} is not Ready"
}

# The sandbox namespace exists before interop-smoke.sh creates it when a mode
# puts something in it first; this is the same idempotent create and label.
ensure_release_namespace() {
	kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
}

# --- prerequisites -----------------------------------------------------------

install_cert_manager() {
	log "installing cert-manager ${CERT_MANAGER_VERSION}"
	fetch "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" \
		"$CERT_MANAGER_SHA256" "${WORK}/cert-manager.yaml"
	kubectl apply -f "${WORK}/cert-manager.yaml" >/dev/null || fail "could not install cert-manager"
	for d in cert-manager cert-manager-cainjector cert-manager-webhook; do
		kubectl -n cert-manager rollout status "deploy/${d}" --timeout=5m || fail "${d} never became available"
	done
	# The webhook Deployment can be available before the cainjector has put its
	# CA into the webhook configuration; until then every Issuer create fails
	# on TLS and the chart install with it. Wait until the API server accepts one.
	local probe="${WORK}/probe-issuer.yaml"
	printf '%s\n' 'apiVersion: cert-manager.io/v1' 'kind: Issuer' \
		'metadata: {name: parity-smoke-probe, namespace: default}' 'spec: {selfSigned: {}}' >"$probe"
	for _ in $(seq 1 60); do
		kubectl apply --dry-run=server -f "$probe" >/dev/null 2>&1 && return 0
		sleep 2
	done
	kubectl apply --dry-run=server -f "$probe" || fail "the cert-manager webhook never accepted an Issuer"
}

vault_exec() { # vault CLI arguments; the dev root token, the dev TLS CA
	kubectl -n "$VAULT_NS" exec -i vault-0 -- env VAULT_TOKEN=root vault "$@"
}

install_vault() {
	log "installing Vault ${VAULT_IMAGE_TAG} (Helm chart ${VAULT_CHART_VERSION}, dev mode with TLS)"
	fetch "https://helm.releases.hashicorp.com/vault-${VAULT_CHART_VERSION}.tgz" \
		"$VAULT_CHART_SHA256" "${WORK}/vault.tgz"
	# The chart refuses plain HTTP to a non-loopback Vault, and a dev server
	# serves plain HTTP. -dev-tls makes it serve HTTPS with a CA of its own,
	# written to the emptyDir; -dev-tls-san puts the Service name on the
	# certificate. That CA becomes the ConfigMap the values file names.
	# global.tlsDisable=false points the pod's VAULT_ADDR and probes at HTTPS.
	cat >"${WORK}/vault-values.yaml" <<-EOF
		global:
		  tlsDisable: false
		injector:
		  enabled: false
		server:
		  image:
		    repository: hashicorp/vault
		    tag: "${VAULT_IMAGE_TAG}@${VAULT_IMAGE_DIGEST}"
		  dev:
		    enabled: true
		    devRootToken: root
		  extraArgs: -dev-tls -dev-tls-cert-dir=/vault/tls -dev-tls-san=vault.${VAULT_NS}.svc
		  extraEnvironmentVars:
		    VAULT_CACERT: /vault/tls/vault-ca.pem
		  volumes:
		    - name: dev-tls
		      emptyDir: {}
		  volumeMounts:
		    - name: dev-tls
		      mountPath: /vault/tls
	EOF
	helm install vault "${WORK}/vault.tgz" --namespace "$VAULT_NS" --create-namespace \
		-f "${WORK}/vault-values.yaml" --wait --timeout 5m || fail "could not install Vault"
	kubectl -n "$VAULT_NS" wait --for=condition=Ready pod/vault-0 --timeout=3m || fail "vault-0 never became Ready"

	log "Vault: Kubernetes auth for the gateway's ServiceAccount"
	# The gateway logs in with its ServiceAccount token; Vault checks it with a
	# TokenReview under its own ServiceAccount (the chart's auth-delegator
	# binding). The policy covers only the driver's path
	# (openshell/provider-credentials/<hash>, openshell-driver-vault lib.rs).
	vault_exec auth enable kubernetes >/dev/null || fail "could not enable Vault Kubernetes auth"
	vault_exec write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc \
		kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt >/dev/null \
		|| fail "could not configure Vault Kubernetes auth"
	printf '%s\n' \
		'path "secret/data/openshell/provider-credentials/*" {' \
		'  capabilities = ["create", "read", "update", "delete"]' \
		'}' \
		'path "secret/metadata/openshell/provider-credentials/*" {' \
		'  capabilities = ["read", "delete", "list"]' \
		'}' | vault_exec policy write openshell-provider-storage - >/dev/null \
		|| fail "could not write the Vault policy"
	vault_exec write "auth/kubernetes/role/${VAULT_ROLE}" \
		"bound_service_account_names=${GATEWAY_SA}" \
		"bound_service_account_namespaces=${NS}" \
		policies=openshell-provider-storage ttl=1h >/dev/null \
		|| fail "could not write the Vault role"

	log "Vault: its dev CA into ConfigMap ${NS}/${VAULT_CA_CONFIGMAP}"
	ensure_release_namespace
	kubectl -n "$VAULT_NS" exec vault-0 -- cat /vault/tls/vault-ca.pem >"${WORK}/vault-ca.crt" \
		|| fail "could not read Vault's dev CA"
	grep -q 'BEGIN CERTIFICATE' "${WORK}/vault-ca.crt" || fail "Vault's dev CA is not a PEM certificate"
	kubectl -n "$NS" create configmap "$VAULT_CA_CONFIGMAP" --from-file=ca.crt="${WORK}/vault-ca.crt" \
		--dry-run=client -o yaml | kubectl apply -f - >/dev/null || fail "could not create the Vault CA ConfigMap"
}

install_spire() {
	log "installing SPIRE (spire ${SPIRE_CHART_VERSION}, spire-crds ${SPIRE_CRDS_CHART_VERSION}) with the SPIFFE CSI driver"
	fetch "https://github.com/spiffe/helm-charts-hardened/releases/download/spire-crds-${SPIRE_CRDS_CHART_VERSION}/spire-crds-${SPIRE_CRDS_CHART_VERSION}.tgz" \
		"$SPIRE_CRDS_CHART_SHA256" "${WORK}/spire-crds.tgz"
	fetch "https://github.com/spiffe/helm-charts-hardened/releases/download/spire-${SPIRE_CHART_VERSION}/spire-${SPIRE_CHART_VERSION}.tgz" \
		"$SPIRE_CHART_SHA256" "${WORK}/spire.tgz"
	helm install spire-crds "${WORK}/spire-crds.tgz" --namespace spire-server --create-namespace \
		--wait --timeout 3m || fail "could not install the SPIRE CRDs"
	# The OIDC discovery provider is not needed for a Workload API socket.
	helm install spire "${WORK}/spire.tgz" --namespace spire-server \
		--set spiffe-oidc-discovery-provider.enabled=false \
		--wait --timeout 8m || fail "could not install SPIRE"
}

# --- assertions ----------------------------------------------------------------

assert_cert_manager() {
	log "ASSERT cert-manager: the gateway's TLS Secrets were issued by cert-manager"
	local s issuer
	for s in "${FULLNAME}-server-tls" "${FULLNAME}-client-tls"; do
		issuer=$(kubectl -n "$NS" get secret "$s" \
			-o jsonpath='{.metadata.annotations.cert-manager\.io/issuer-name}') \
			|| fail "could not read Secret ${s}"
		[[ -n $issuer ]] || fail "Secret ${s} has no cert-manager.io/issuer-name annotation"
		echo "${s}: issuer ${issuer}"
	done
	log "ASSERT cert-manager: the driver+gateway pod is Ready"
	assert_gateway_pod_ready
}

assert_spiffe() {
	log "ASSERT spiffe: the gateway has the Workload API env and the csi.spiffe.io volume"
	local pod env_val csi
	pod=$(gateway_pod) && [[ -n $pod ]] || fail "no driver+gateway pod found"
	env_val=$(kubectl -n "$NS" get pod "$pod" \
		-o jsonpath='{.spec.containers[?(@.name=="gateway")].env[?(@.name=="OPENSHELL_GATEWAY_SPIFFE_WORKLOAD_API_SOCKET")].value}') \
		|| fail "could not read the gateway's env"
	[[ $env_val == /spiffe-workload-api/spire-agent.sock ]] \
		|| fail "OPENSHELL_GATEWAY_SPIFFE_WORKLOAD_API_SOCKET is '${env_val}', expected /spiffe-workload-api/spire-agent.sock"
	csi=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.volumes[*].csi.driver}') \
		|| fail "could not read the pod's volumes"
	grep -qw 'csi.spiffe.io' <<<"$csi" || fail "the pod has no csi.spiffe.io volume (CSI drivers: '${csi}')"
	# A CSI volume that cannot be mounted keeps the pod in ContainerCreating, so
	# Ready proves the driver mounted the Workload API directory.
	log "ASSERT spiffe: the driver+gateway pod is Ready"
	assert_gateway_pod_ready
}

assert_vault() {
	local cli_version cli_dir tarball sums since sb=smoke-vault-sb
	# shellcheck source=scripts/proto-lib.sh
	. scripts/proto-lib.sh
	cli_version=$(chart_upstream_version) || fail "could not read upstream.version from the chart"
	cli_dir="${WORK}/cli"
	mkdir -p "$cli_dir"
	tarball=openshell-x86_64-unknown-linux-musl.tar.gz
	log "installing the openshell CLI ${cli_version}"
	curl -fsSL --retry 3 --retry-delay 2 -o "${cli_dir}/${tarball}" \
		"https://github.com/NVIDIA/OpenShell/releases/download/${cli_version}/${tarball}" \
		|| fail "could not download the openshell CLI"
	sums=$(curl -fsSL --retry 3 --retry-delay 2 \
		"https://github.com/NVIDIA/OpenShell/releases/download/${cli_version}/openshell-checksums-sha256.txt") \
		|| fail "could not download the CLI checksums"
	(cd "$cli_dir" && grep -E "[[:space:]]\*?${tarball}\$" <<<"$sums" | sed 's/\*//' | sha256sum -c - >/dev/null) \
		|| fail "the CLI tarball does not match ${cli_version}'s checksum file"
	tar xzf "${cli_dir}/${tarball}" -C "$cli_dir" || fail "could not unpack the CLI"
	export PATH="${cli_dir}:$PATH"

	kubectl -n "$NS" port-forward "svc/${FULLNAME}" 8080:8080 >"${WORK}/pf.log" 2>&1 &
	PF_PID=$!
	for _ in $(seq 1 20); do
		(: <>/dev/tcp/127.0.0.1/8080) >/dev/null 2>&1 && break
		sleep 0.5
	done
	(: <>/dev/tcp/127.0.0.1/8080) >/dev/null 2>&1 || fail "port-forward never became ready: $(cat "${WORK}/pf.log")"
	osh() { openshell --gateway-endpoint http://127.0.0.1:8080 "$@"; }

	since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	log "ASSERT vault: a provider with a credential is stored in Vault"
	osh profile import -f scripts/testdata/parity-smoke-profile.yaml --global \
		|| fail "could not import the smoke-generic profile"
	SMOKE_TOKEN=dummy osh provider create --name smoke-vault --type smoke-generic \
		--credential SMOKE_TOKEN --global-profile || fail "could not create provider smoke-vault"

	log "ASSERT vault: a sandbox with that provider reaches Ready"
	# --detach returns 0 only once the gateway reports Ready (see interop-smoke.sh
	# ASSERT 2); the supervisor fetches the provider's environment on the way.
	timeout 600 openshell --gateway-endpoint http://127.0.0.1:8080 sandbox create --detach \
		--name "$sb" --provider smoke-vault -- sleep infinity \
		|| fail "sandbox ${sb} with provider smoke-vault did not reach Ready"

	# The gateway logs a successful call as "GetSandboxProviderEnvironment
	# request completed successfully ... provider_count=N", and its request
	# span carries rpc.grpc.status_code only when the call failed (an OK
	# response has none). So: require a successful call that carried the
	# provider, and refuse any non-zero status (FailedPrecondition 9 is how a
	# provider fetch error surfaces; a Vault auth failure would be 7 or 14).
	log "ASSERT vault: GetSandboxProviderEnvironment succeeded for the provider, and never failed"
	local gw rpc_lines hits
	gw=$(kubectl -n "$NS" logs "deploy/${FULLNAME}" -c gateway --since-time="$since" 2>&1) \
		|| fail "could not read the gateway log: ${gw}"
	rpc_lines=$(strip_ansi <<<"$gw" | grep -F 'GetSandboxProviderEnvironment' || true)
	grep -qE 'GetSandboxProviderEnvironment request completed successfully.* provider_count=[1-9]' <<<"$rpc_lines" \
		|| fail "no successful GetSandboxProviderEnvironment with a provider since ${since}:
$(tail -5 <<<"$rpc_lines")"
	hits=$(grep -E 'rpc\.grpc\.status_code=[1-9]' <<<"$rpc_lines" || true)
	[[ -z $hits ]] || fail "the gateway failed GetSandboxProviderEnvironment:
${hits}"

	log "ASSERT vault: the credential is in Vault's KV store"
	local kv
	kv=$(vault_exec kv list secret/ 2>&1) || fail "vault kv list secret/ failed: ${kv}"
	printf '%s\n' "$kv"
	grep -q 'openshell/' <<<"$kv" || fail "Vault's secret/ mount holds nothing under openshell/"
}

# --- run -----------------------------------------------------------------------

case $MODE in
	cert-manager) install_cert_manager ;;
	vault) install_vault ;;
	spiffe) install_spire ;;
esac

log "running interop-smoke.sh with scripts/testdata/parity-smoke-${MODE}.yaml"
HELM_EXTRA_VALUES="scripts/testdata/parity-smoke-${MODE}.yaml" ./scripts/interop-smoke.sh \
	|| fail "interop-smoke.sh failed with the ${MODE} values"

case $MODE in
	cert-manager) assert_cert_manager ;;
	vault) assert_vault ;;
	spiffe) assert_spiffe ;;
esac

echo "PARITY_SMOKE_OK ${MODE}"
