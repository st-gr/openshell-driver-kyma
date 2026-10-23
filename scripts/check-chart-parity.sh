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
try bad-p3-empty-name 'gateway.name must not be blank' t --set-string 'gateway.name= '

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

# 8. Gateway Service type. A LoadBalancer or NodePort Service carries only the gateway's
# own ports; the driver health port and http-services move to <fullname>-internal.
ING8=(--set gatewayIngress.enabled=true --set gatewayIngress.domain=example.org
	--set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=osh-client
	--set gateway.oidc.clientId=osh-client --set gateway.oidc.authOnly=true --set gateway.tls.enabled=true
	--set gatewayIngress.serviceHosts.enabled=true --set-json 'gatewayIngress.allowedCidrs=["203.0.113.0/24"]')
try good-p8-default '' t
try good-p8-lb '' t --set gatewayService.type=LoadBalancer "${OIDC5[@]}"
try good-p8-lb-ingress '' t --set gatewayService.type=LoadBalancer "${ING8[@]}"
try good-p8-nodeport '' t --set gatewayService.type=NodePort --set gatewayService.nodePort=30443 "${OIDC5[@]}"
try bad-p8-nodeport-clusterip 'gatewayService.nodePort requires gatewayService.type=NodePort' t \
	--set gatewayService.nodePort=30443
try bad-p8-nodeport-lb 'gatewayService.nodePort requires gatewayService.type=NodePort' t \
	--set gatewayService.type=LoadBalancer --set gatewayService.nodePort=30443
try bad-p8-type 'gatewayService.type must be ClusterIP, NodePort or LoadBalancer' t --set gatewayService.type=ExternalName
try bad-p8-lb-no-service 'gatewayService.type=LoadBalancer requires gatewayService.enabled' t \
	--set gatewayService.enabled=false --set driver.gatewayEndpoint=http://gateway.example:8080 \
	--set gatewayService.type=LoadBalancer
# Publishing the gateway (gatewayIngress, or a LoadBalancer/NodePort Service) refuses an
# effective allow_unauthenticated_users = true, and a published Service needs OIDC or a client CA.
UNAUTH8='REFUSING to publish an unauthenticated gateway: allow_unauthenticated_users is true while'
NOAUTH8='publishes the gateway; set gateway.oidc.issuer or enable gateway.tls with gateway.tls.clientCa'
try bad-p8-ingress-unauth "$UNAUTH8 gatewayIngress.enabled publishes it" t "${ING8[@]}" \
	--set gateway.auth.allowUnauthenticatedUsers=true
try bad-p8-ingress-config-unauth "$UNAUTH8 gatewayIngress.enabled publishes it" t "${ING8[@]}" \
	--set-json 'gatewayConfig={"openshell.gateway.auth":{"allow_unauthenticated_users":true}}'
try bad-p8-ingress-nested-unauth "$UNAUTH8 gatewayIngress.enabled publishes it" t "${ING8[@]}" \
	--set-json 'gatewayConfig={"openshell":{"gateway":{"auth":{"allow_unauthenticated_users":true}}}}'
try bad-p8-lb-no-auth "gatewayService.type=LoadBalancer $NOAUTH8" t --set gatewayService.type=LoadBalancer
try bad-p8-nodeport-no-auth "gatewayService.type=NodePort $NOAUTH8" t --set gatewayService.type=NodePort
try bad-p8-lb-oidc-unauth "$UNAUTH8 gatewayService.type=LoadBalancer publishes it" t \
	--set gatewayService.type=LoadBalancer "${OIDC5[@]}" --set gateway.auth.allowUnauthenticatedUsers=true
try good-p8-lb-oidc '' t --set gatewayService.type=LoadBalancer "${OIDC5[@]}"
try good-p8-lb-client-ca '' t --set gatewayService.type=LoadBalancer --set gateway.tls.enabled=true \
	--set gateway.tls.clientCa.enabled=true
try good-p8-clusterip-unauth '' t --set gateway.auth.allowUnauthenticatedUsers=true
# 9. External database Secret: the URL comes from a Secret key, never from args or values.
try good-p9-db '' t --set gateway.dbPersistence.enabled=true --set gateway.dbPersistence.externalDbSecret=osh-db
try good-p9-db-without-enabled '' t --set gateway.dbPersistence.externalDbSecret=osh-db
try good-p9-sqlite '' t --set gateway.dbPersistence.enabled=true
# 10. rbac.create=false drops the chart's own RBAC; the helm hooks' RBAC stays.
try good-p10-default '' t
try good-p10-shared-true '' t --set driver.workspaceMode=shared --set driver.allowDriverConfig=true
try good-p10-no-rbac '' t --set rbac.create=false
try good-p10-managed '' t --set driver.workspaceMode=managed --set gateway.sandboxJwt.gatewayId=gw \
	--set 'driver.sandboxImagePullSecrets={pull}'
try good-p10-no-rbac-sources '' t --set rbac.create=false --set driver.workspaceMode=managed \
	--set gateway.sandboxJwt.gatewayId=gw --set 'driver.sandboxImagePullSecrets={pull}'
try bad-p9-both 'gateway.dbPersistence.externalDbSecret and gateway.dbPersistence.dbUrl are mutually exclusive' t \
	--set gateway.dbPersistence.externalDbSecret=osh-db --set gateway.dbPersistence.dbUrl=postgresql://u@h/d
try bad-p9-name 'gateway.dbPersistence.externalDbSecret must be a valid Kubernetes Secret name' t \
	--set gateway.dbPersistence.externalDbSecret=Bad_Name
try bad-p9-url-without-enabled 'gateway.dbPersistence.dbUrl requires gateway.dbPersistence.enabled=true (or use gateway.dbPersistence.externalDbSecret)' t \
	--set gateway.dbPersistence.dbUrl=postgresql://u@h/d
try bad-p9-long 'gateway.dbPersistence.externalDbSecret must be no more than 253 characters' t \
	--set "gateway.dbPersistence.externalDbSecret=$(printf 'a%.0s' $(seq 254))"
try bad-p9-extra-db-url 'gateway.extraArgs sets --db-url; use gateway.dbPersistence.enabled=true with dbUrl, or externalDbSecret instead' t \
	--set-json 'gateway.extraArgs=["--db-url=sqlite:x"]'

try bad-p5-ttl 'gateway.oidc.jwksTtl must be a positive integer' t "${OIDC5[@]}" --set gateway.oidc.jwksTtl=0
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

# 11. Extra server SANs and a separate client CA Secret.
ING11=(--set gatewayIngress.enabled=true --set gatewayIngress.domain=example.org
	--set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=osh-client
	--set gateway.oidc.clientId=osh-client --set gateway.oidc.authOnly=true
	--set gateway.tls.enabled=true --set gatewayIngress.serviceHosts.enabled=true
	--set-json 'gatewayIngress.allowedCidrs=["203.0.113.0/24"]')
SAN11=(--set 'gateway.sandboxJwt.serverDnsNames={gw.example.org}' --set 'gateway.sandboxJwt.serverIpAddresses={10.0.0.5}')
try good-p11-sans '' t "${SAN11[@]}"
try good-p11-sans-ingress '' t "${SAN11[@]}" "${ING11[@]}"
try good-p11-client-ca '' t --set gateway.tls.enabled=true --set gateway.tls.clientCa.enabled=true \
	--set gateway.tls.clientCa.secretName=user-ca
try good-p11-client-ca-default '' t --set gateway.tls.enabled=true --set gateway.tls.clientCa.enabled=true
try good-p11-client-ca-off '' t --set gateway.tls.enabled=true --set gateway.tls.clientCa.secretName=user-ca
try bad-p11-dns 'gateway.sandboxJwt.serverDnsNames entries must be DNS names' t \
	--set 'gateway.sandboxJwt.serverDnsNames={Bad_Name}'
try bad-p11-ip 'gateway.sandboxJwt.serverIpAddresses entries must be IP addresses' t \
	--set 'gateway.sandboxJwt.serverIpAddresses={300.1.1.1}'
try bad-p11-extra-san 'gateway.extraArgs sets --server-san; use gateway.sandboxJwt.serverDnsNames instead' t \
	--set-json 'gateway.extraArgs=["--server-san=x.example.org"]'

# 12. The Kubernetes Secrets credential driver: provider credentials in Secrets, no KEK.
K8S12=(--set gateway.credentialDrivers.kubernetesSecrets.enabled=true)
try good-p12-k8s '' t "${K8S12[@]}" --set gateway.credentialDrivers.kubernetesSecrets.namespace=osh-creds
# Credentials in the release namespace need sandboxes elsewhere (the sandbox namespace defaults to it).
try good-p12-k8s-default-ns '' t "${K8S12[@]}" --set namespace=osh-sandboxes
try good-p12-create-ns '' t "${K8S12[@]}" --set gateway.credentialDrivers.kubernetesSecrets.namespace=osh-creds \
	--set gateway.credentialDrivers.kubernetesSecrets.createNamespace=true
try good-p12-no-rbac '' t "${K8S12[@]}" --set gateway.credentialDrivers.kubernetesSecrets.namespace=osh-creds \
	--set gateway.credentialDrivers.kubernetesSecrets.rbac.create=false
try good-p12-no-rbac-global '' t "${K8S12[@]}" --set gateway.credentialDrivers.kubernetesSecrets.namespace=osh-creds \
	--set rbac.create=false
try good-p12-via-config '' t --set namespace=osh-sandboxes --set-json 'gatewayConfig={"openshell.gateway":{"credential_drivers":["kubernetes-secrets"]}}'
try good-p12-via-config-nested '' t \
	--set-json 'gatewayConfig={"openshell":{"gateway":{"credential_drivers":["kubernetes-secrets"]},"credential_drivers":{"kubernetes-secrets":{"namespace":"osh-creds"}}}}'
try good-p12-existing-kek '' t "${K8S12[@]}" --set namespace=osh-sandboxes \
	--set gateway.credentialStorage.existingSecret=my-kek
try bad-p12-sandbox-ns 'gateway.credentialDrivers.kubernetesSecrets.namespace must not be the sandbox namespace' t \
	"${K8S12[@]}" --set namespace=openshell-system --set gateway.credentialDrivers.kubernetesSecrets.namespace=openshell-system
try bad-p12-sandbox-release-ns 'gateway.credentialDrivers.kubernetesSecrets.namespace must not be the sandbox namespace' t \
	"${K8S12[@]}" --namespace openshell-system
try bad-p12-sandbox-config-ns 'gateway.credentialDrivers.kubernetesSecrets.namespace must not be the sandbox namespace' t \
	--set namespace=openshell-system \
	--set-json 'gatewayConfig={"openshell.gateway":{"credential_drivers":["kubernetes-secrets"]},"openshell.credential_drivers.kubernetes-secrets":{"namespace":"openshell-system"}}'
try bad-p12-create-release-ns 'gateway.credentialDrivers.kubernetesSecrets.createNamespace requires gateway.credentialDrivers.kubernetesSecrets.namespace to name a namespace other than the release namespace' t \
	"${K8S12[@]}" --set namespace=osh-sandboxes --set gateway.credentialDrivers.kubernetesSecrets.createNamespace=true
try bad-p12-two-drivers 'gatewayConfig.openshell.gateway.credential_drivers may select only one backend' t \
	--set-json 'gatewayConfig={"openshell.gateway":{"credential_drivers":["a","b"]}}'
try bad-p12-no-drivers 'gatewayConfig.openshell.gateway.credential_drivers must select exactly one backend or be omitted/null to use the chart default' t \
	--set-json 'gatewayConfig={"openshell.gateway":{"credential_drivers":[]}}'

# 13. The Vault credential driver.
VAULT13=(--set gateway.credentialDrivers.vault.enabled=true --set gateway.credentialDrivers.vault.address=https://vault.example.org)
try good-p13-vault '' t "${VAULT13[@]}" --set gateway.credentialDrivers.vault.role=osh \
	--set gateway.credentialDrivers.vault.timeoutSecs=30 --set gateway.credentialDrivers.vault.caConfigMapName=vault-ca
try good-p13-vault-port '' t --set gateway.credentialDrivers.vault.enabled=true \
	--set gateway.credentialDrivers.vault.address=https://vault.example.org:8200
try good-p13-vault-loopback-http '' t --set gateway.credentialDrivers.vault.enabled=true \
	--set gateway.credentialDrivers.vault.address=http://localhost
try good-p13-vault-no-np '' t "${VAULT13[@]}" --set networkPolicy.enabled=false
try good-p13-vault-via-config '' t \
	--set-json 'gatewayConfig={"openshell.gateway":{"credential_drivers":["vault"]},"openshell.credential_drivers.vault":{"address":"https://vault.example.org","role":"osh"}}'
try good-p13-vault-via-config-ca '' t --set gateway.credentialDrivers.vault.caConfigMapName=vault-ca \
	--set-json 'gatewayConfig={"openshell.gateway":{"credential_drivers":["vault"]},"openshell.credential_drivers.vault":{"address":"https://vault.example.org:8443","ca_bundle":"/tmp/x"}}'
try bad-p13-two-backends 'only one external gateway.credentialDrivers backend can be enabled at a time' t "${VAULT13[@]}" \
	"${K8S12[@]}"
try bad-p13-two-backends-config 'only one external gateway.credentialDrivers backend can be enabled at a time' t "${VAULT13[@]}" \
	"${K8S12[@]}" --set-json 'gatewayConfig={"openshell.gateway":{"credential_drivers":["vault"]}}'
try good-p13-timeout-string '' t "${VAULT13[@]}" --set-string gateway.credentialDrivers.vault.timeoutSecs=45
try good-p13-timeout-empty '' t "${VAULT13[@]}" --set-string gateway.credentialDrivers.vault.timeoutSecs=
i=0
for v in abc 30s 1.5 0 -5; do
	i=$((i + 1))
	try "bad-p13-timeout-str$i" 'gateway.credentialDrivers.vault.timeoutSecs must be a positive integer' t "${VAULT13[@]}" \
		--set-string "gateway.credentialDrivers.vault.timeoutSecs=$v"
done
for v in 1.5 0 -5; do
	i=$((i + 1))
	try "bad-p13-timeout-num$i" 'gateway.credentialDrivers.vault.timeoutSecs must be a positive integer' t "${VAULT13[@]}" \
		--set "gateway.credentialDrivers.vault.timeoutSecs=$v"
done
try bad-p13-no-address 'gateway.credentialDrivers.vault.address is required' t \
	--set gateway.credentialDrivers.vault.enabled=true
try bad-p13-no-address-config 'gateway.credentialDrivers.vault.address is required' t \
	--set-json 'gatewayConfig={"openshell.gateway":{"credential_drivers":["vault"]}}'
try bad-p13-http 'gateway.credentialDrivers.vault.address must use HTTPS for non-loopback endpoints' t \
	--set gateway.credentialDrivers.vault.enabled=true --set gateway.credentialDrivers.vault.address=http://vault.example.org
try bad-p13-http-config 'gateway.credentialDrivers.vault.address must use HTTPS for non-loopback endpoints' t \
	--set-json 'gatewayConfig={"openshell.gateway":{"credential_drivers":["vault"]},"openshell.credential_drivers.vault":{"address":"http://vault.example.org:8200"}}'

# 14. SPIFFE Workload API for the gateway's provider token grants.
SPIFFE14=(--set gateway.providerTokenGrants.spiffe.enabled=true)
try good-p14-spiffe '' t "${SPIFFE14[@]}"
try good-p14-spiffe-path '' t "${SPIFFE14[@]}" --set gateway.providerTokenGrants.spiffe.workloadApiSocketPath=/run/spire/sock/agent.sock
try good-p14-driver-override '' t --set driver.providerSpiffeWorkloadApiSocket=/x/y.sock
try good-p14-spiffe-driver-override '' t "${SPIFFE14[@]}" --set driver.providerSpiffeWorkloadApiSocket=/x/y.sock
try bad-p14-relative-path 'gateway.providerTokenGrants.spiffe.workloadApiSocketPath must be an absolute path' t "${SPIFFE14[@]}" \
	--set gateway.providerTokenGrants.spiffe.workloadApiSocketPath=spire-agent.sock

# 15. Certificates from cert-manager (gateway.certManager, api cert-manager.io).
CM15=(--set gateway.tls.enabled=true --set gateway.certManager.enabled=true)
ING15=(--set gatewayIngress.enabled=true --set gatewayIngress.domain=example.org
	--set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=osh-client
	--set gateway.oidc.clientId=osh-client --set gateway.oidc.authOnly=true)
try good-p15-cm '' t "${CM15[@]}"
try good-p15-cm-ingress '' t "${CM15[@]}" "${ING15[@]}"
try good-p15-cm-separate-ca '' t "${CM15[@]}" --set gateway.certManager.clientCaFromServerTlsSecret=false \
	--set gateway.tls.clientCa.enabled=true --set gateway.tls.clientCa.secretName=t-openshell-driver-kyma-ca-tls
try good-p15-cm-sans '' t "${CM15[@]}" --set 'gateway.certManager.serverDnsNames={gw.example.org}' \
	--set 'gateway.certManager.serverIpAddresses={10.0.0.5}' --set gateway.certManager.caSecretName=own-ca \
	--set gateway.certManager.caDuration=9481h
try good-p15-cm-mixed-durations '' t "${CM15[@]}" --set gateway.certManager.certificateDuration=1h30m \
	--set gateway.certManager.certificateRenewBefore=45m --set gateway.certManager.caDuration=2h15m1s
try bad-p15-no-tls 'gateway.certManager.enabled requires gateway.tls.enabled' t --set gateway.certManager.enabled=true
try bad-p15-separate-ca-no-secret 'gateway.certManager.clientCaFromServerTlsSecret is false but gateway.tls.clientCa.secretName is empty' t \
	"${CM15[@]}" --set gateway.certManager.clientCaFromServerTlsSecret=false --set gateway.tls.clientCa.enabled=true
try bad-p15-secret-from-server 'gateway.tls.clientCa.secretName is set but gateway.certManager.clientCaFromServerTlsSecret is true' t \
	"${CM15[@]}" --set gateway.tls.clientCa.enabled=true --set gateway.tls.clientCa.secretName=user-ca
try bad-p15-ca-duration 'gateway.certManager.caDuration (8760h) must exceed certificateDuration + certificateRenewBefore (9480h)' t \
	"${CM15[@]}" --set gateway.certManager.caDuration=8760h
try bad-p15-ca-duration-equal 'gateway.certManager.caDuration (9480h) must exceed certificateDuration + certificateRenewBefore (9480h)' t \
	"${CM15[@]}" --set gateway.certManager.caDuration=9480h
try bad-p15-api 'gateway.certManager.api must be cert-manager.io or cert.gardener.cloud' t \
	"${CM15[@]}" --set gateway.certManager.api=example.io
try bad-p15-duration 'gateway.certManager.certificateDuration must be a Go duration in hours (e.g. 8760h)' t \
	"${CM15[@]}" --set gateway.certManager.certificateDuration=bad
for v in 1d 1.5h h 30; do
	try "bad-p15-renew-$v" 'gateway.certManager.certificateRenewBefore must be a Go duration in hours (e.g. 720h)' t \
		"${CM15[@]}" --set-string "gateway.certManager.certificateRenewBefore=$v"
done
try bad-p15-ca-duration-format 'gateway.certManager.caDuration must be a Go duration in hours (e.g. 87600h)' t \
	"${CM15[@]}" --set gateway.certManager.caDuration=10y
try bad-p15-pki-sans 'gateway.sandboxJwt.serverDnsNames and serverIpAddresses name the PKI hook certificate' t \
	"${CM15[@]}" --set 'gateway.sandboxJwt.serverDnsNames={gw.example.org}'
try bad-p15-cm-dns 'gateway.certManager.serverDnsNames entries must be DNS names' t \
	"${CM15[@]}" --set 'gateway.certManager.serverDnsNames={Bad_Name}'
try good-p15-cm-no-fail '' t "${CM15[@]}" "${ING15[@]}" --set gateway.sandboxJwt.timeoutSeconds=60 \
	--set gateway.sandboxJwt.failOnTimeout=false
try bad-p15-timeout 'gateway.sandboxJwt.timeoutSeconds must be a positive integer' t "${CM15[@]}" \
	--set gateway.sandboxJwt.timeoutSeconds=0
try bad-p15-enabled-string 'gateway.certManager.enabled must be a boolean' t --set gateway.tls.enabled=true \
	--set-string gateway.certManager.enabled=false
try bad-p15-cm-ip 'gateway.certManager.serverIpAddresses entries must be IP addresses' t \
	"${CM15[@]}" --set 'gateway.certManager.serverIpAddresses={300.1.1.1}'

# 16. Certificates from Gardener's certificate service (gateway.certManager.api=cert.gardener.cloud).
GD16=("${CM15[@]}" --set gateway.certManager.api=cert.gardener.cloud)
try good-p16-gardener '' t "${GD16[@]}"
try good-p16-gardener-ingress '' t "${GD16[@]}" "${ING15[@]}"
try good-p16-gardener-sans '' t "${GD16[@]}" --set 'gateway.certManager.serverDnsNames={gw.example.org}' \
	--set 'gateway.certManager.serverIpAddresses={10.0.0.5}' --set gateway.certManager.caSecretName=own-ca \
	--set gateway.certManager.caDuration=9481h
try good-p16-gardener-mixed-durations '' t "${GD16[@]}" --set gateway.certManager.certificateDuration=1h30m \
	--set gateway.certManager.certificateRenewBefore=45m --set gateway.certManager.caDuration=2h15m1s
try good-p16-renew-half '' t "${CM15[@]}" --set gateway.certManager.certificateRenewBefore=4380h
RENEW16='gateway.certManager.certificateDuration (8760h) must be at least twice certificateRenewBefore (5000h): the chart requires this for both cert-manager.io and cert.gardener.cloud.'
try bad-p16-gardener-renew "$RENEW16" t "${GD16[@]}" --set gateway.certManager.certificateRenewBefore=5000h
try bad-p16-cm-renew "$RENEW16" t "${CM15[@]}" --set gateway.certManager.certificateRenewBefore=5000h

# 19. 0.11.1 fixes.
# The sandbox namespace defaults to the release namespace; namespace= overrides it.
try good-q1-ns-default '' t --namespace osh-a
try good-q1-ns-explicit '' t --namespace osh-a --set namespace=osh-sb
try bad-q1-k8s-secrets-defaults 'gateway.credentialDrivers.kubernetesSecrets.namespace must not be the sandbox namespace "osh-a"' t \
	--namespace osh-a --set gateway.credentialDrivers.kubernetesSecrets.enabled=true
# Values of the wrong shape fail with a message naming them, not a template error.
TABLE2='must be a table (a map of keys)'
try bad-q2-config-scalar-table "gatewayConfig openshell.gateway.auth $TABLE2" t \
	--set-json 'gatewayConfig={"openshell.gateway.auth":5}'
try bad-q2-config-string-table "gatewayConfig openshell.gateway $TABLE2" t --set-json 'gatewayConfig={"openshell.gateway":"x"}'
try bad-q2-config-nested-scalar "gatewayConfig openshell.gateway $TABLE2" t --set-json 'gatewayConfig={"openshell":{"gateway":5}}'
try good-q2-auth-null '' t --set-json gateway.auth=null
try bad-q2-auth-string 'gateway.auth must be a map' t --set-string gateway.auth=x
try bad-q2-vault-space 'the Vault credential driver address must not contain whitespace' t \
	--set gateway.credentialDrivers.vault.enabled=true --set-string 'gateway.credentialDrivers.vault.address=https://vault.example.org :8200'
# Validation: rbac.create is a boolean; nodePort in the default range; real IPv6 SANs;
# a DNS-1123 credentials namespace; an integer JWKS TTL.
try bad-q3-rbac-string 'rbac.create must be a boolean' t --set-string rbac.create=false
NP3=(--set gatewayService.type=NodePort "${OIDC5[@]}")
NODEPORT3='gatewayService.nodePort must be an integer from 30000 to 32767'
try good-q3-nodeport-low '' t "${NP3[@]}" --set gatewayService.nodePort=30000
try good-q3-nodeport-high '' t "${NP3[@]}" --set gatewayService.nodePort=32767
try bad-q3-nodeport-below "$NODEPORT3" t "${NP3[@]}" --set gatewayService.nodePort=8080
try bad-q3-nodeport-above "$NODEPORT3" t "${NP3[@]}" --set gatewayService.nodePort=32768
try bad-q3-nodeport-string "$NODEPORT3" t "${NP3[@]}" --set-string gatewayService.nodePort=abc
try good-q3-ipv6 '' t --set-json 'gateway.sandboxJwt.serverIpAddresses=["::1","fd00::5","2001:db8:0:0:0:0:0:1","::"]'
IP3='gateway.sandboxJwt.serverIpAddresses entries must be IP addresses'
try bad-q3-ipv6-colons "$IP3" t --set-json 'gateway.sandboxJwt.serverIpAddresses=["::::"]'
try bad-q3-ipv6-two-gaps "$IP3" t --set-json 'gateway.sandboxJwt.serverIpAddresses=["1::2::3"]'
try bad-q3-ipv6-long-group "$IP3" t --set-json 'gateway.sandboxJwt.serverIpAddresses=["12345::1"]'
try bad-q3-ipv6-nine-groups "$IP3" t --set-json 'gateway.sandboxJwt.serverIpAddresses=["1:2:3:4:5:6:7:8:9"]'
try bad-q3-ipv6-seven-groups "$IP3" t --set-json 'gateway.sandboxJwt.serverIpAddresses=["1:2:3:4:5:6:7"]'
try bad-q3-creds-ns 'gateway.credentialDrivers.kubernetesSecrets.namespace must be a valid namespace name' t \
	"${K8S12[@]}" --set namespace=osh-sandboxes --set gateway.credentialDrivers.kubernetesSecrets.namespace=Bad_NS
try bad-q3-jwks-float 'gateway.oidc.jwksTtl must be a positive integer' t "${OIDC5[@]}" --set gateway.oidc.jwksTtl=1.5
try bad-q3-jwks-string 'gateway.oidc.jwksTtl must be a positive integer' t "${OIDC5[@]}" --set-string gateway.oidc.jwksTtl=abc
# With the gateway elsewhere (gateway.enabled=false), gateway.* settings neither fail nor steer the driver.
OFF4=(--set gateway.enabled=false --set driver.gatewayEndpoint=http://gateway.example:8080)
try good-q4-db-url-gateway-off '' t "${OFF4[@]}" --set gateway.dbPersistence.dbUrl=postgres://db.example:5432/osh
try good-q4-spiffe-gateway-off '' t "${OFF4[@]}" --set gateway.providerTokenGrants.spiffe.enabled=true
# Every flag the chart passes to the gateway is refused in extraArgs, naming its value.
for pair in --config:gatewayConfig --bind-address:gateway.grpcPort --port:gateway.grpcPort \
	--health-port:gateway.healthPort --metrics-port:gateway.metricsPort --compute-driver:driver.socket \
	--compute-driver-socket:driver.socket --oidc-issuer:gateway.oidc.issuer --oidc-audience:gateway.oidc.audience \
	--oidc-roles-claim:gateway.oidc.rolesClaim --oidc-admin-role:gateway.oidc.adminRole \
	--oidc-user-role:gateway.oidc.userRole; do
	flag=${pair%%:*}
	try "bad-q5-extra${flag}" "gateway.extraArgs sets ${flag}; use ${pair#*:}" t \
		--set-json "gateway.extraArgs=[\"${flag}=x\"]"
done
# An OTLP endpoint and a gateway name set through gatewayConfig reach the driver and the egress.
try good-q5-otlp-config '' t --set-json 'gatewayConfig={"openshell.gateway.otlp":{"endpoint":"http://otel.example.org:4318"}}'
try good-q5-name-config '' t --set-json 'gatewayConfig={"openshell.gateway":{"name":"from-config"}}'
# Under gateway.certManager the --server-san refusal names certManager's own key.
try bad-q7-extra-san-cm 'gateway.extraArgs sets --server-san; use gateway.certManager.serverDnsNames instead' t \
	"${CM15[@]}" --set-json 'gateway.extraArgs=["--server-san=x.example.org"]'
# The twice-renewBefore boundary on Gardener too; the driver's OTLP default with the gateway elsewhere.
try good-q8-gardener-renew-half '' t "${GD16[@]}" --set gateway.certManager.certificateRenewBefore=4380h
try bad-q8-gardener-renew-over "${RENEW16/5000h/4381h}" t "${GD16[@]}" --set gateway.certManager.certificateRenewBefore=4381h
try good-q8-otlp-gateway-off '' t "${OFF4[@]}" --set gateway.otlp.endpoint=http://otel.example.org:4318

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

def services(case):
    return {d["metadata"]["name"]: d for d in docs(case) if d.get("kind") == "Service"}

def port_names(svc):
    return [p["name"] for p in svc["spec"]["ports"]]

DEFAULT_PORTS = ["health", "grpc", "gw-health", "gw-metrics"]
svcs = services("good-p8-default")
if list(svcs) != ["t-openshell-driver-kyma"]:
    failures.append(f"good-p8-default: Services are {list(svcs)}, want one")
else:
    svc = svcs["t-openshell-driver-kyma"]
    if svc["spec"]["type"] != "ClusterIP" or port_names(svc) != DEFAULT_PORTS:
        failures.append(f"good-p8-default: Service is {svc['spec']['type']} {port_names(svc)}")

for case in ("good-p8-lb", "good-p8-lb-ingress"):
    svcs = services(case)
    typed, internal = svcs.get("t-openshell-driver-kyma"), svcs.get("t-openshell-driver-kyma-internal")
    if typed is None or internal is None:
        failures.append(f"{case}: Services are {list(svcs)}, want the typed one and -internal")
        continue
    if typed["spec"]["type"] != "LoadBalancer":
        failures.append(f"{case}: typed Service is {typed['spec']['type']}")
    if port_names(typed) != ["grpc", "gw-health", "gw-metrics"]:
        failures.append(f"{case}: typed Service ports are {port_names(typed)}")
    if internal["spec"]["type"] != "ClusterIP":
        failures.append(f"{case}: -internal Service is {internal['spec']['type']}")
    want_internal = ["health"] + (["http-services"] if case == "good-p8-lb-ingress" else [])
    if port_names(internal) != want_internal:
        failures.append(f"{case}: -internal ports are {port_names(internal)}, want {want_internal}")
    if internal["spec"]["selector"] != typed["spec"]["selector"]:
        failures.append(f"{case}: -internal selector differs from the typed Service")

def route_hosts(case, kind, name_suffix):
    return [r["destination"]["host"] for d in docs(case) if d.get("kind") == kind
            and d["metadata"]["name"].endswith(name_suffix)
            for h in d["spec"]["http"] for r in h["route"]]

got = route_hosts("good-p8-lb-ingress", "VirtualService", "-sandbox-services")
if got != ["t-openshell-driver-kyma-internal.default.svc.cluster.local"]:
    failures.append(f"good-p8-lb-ingress: services VirtualService routes to {got}, want the -internal Service")
got = route_hosts("good-p8-lb-ingress", "VirtualService", "-kyma") + route_hosts("good-p8-lb-ingress", "VirtualService", "-gateway")
if any("-internal" in h for h in got):
    failures.append(f"good-p8-lb-ingress: the gRPC VirtualService routes to {got}")
hosts = sorted(d["spec"]["host"] for d in docs("good-p8-lb-ingress") if d.get("kind") == "DestinationRule")
if hosts != ["t-openshell-driver-kyma-internal.default.svc.cluster.local",
             "t-openshell-driver-kyma.default.svc.cluster.local"]:
    failures.append(f"good-p8-lb-ingress: DestinationRule hosts are {hosts}")

grpc = next((p for p in services("good-p8-nodeport").get("t-openshell-driver-kyma", {"spec": {"ports": []}})["spec"]["ports"]
             if p["name"] == "grpc"), {})
if grpc.get("nodePort") != 30443:
    failures.append(f"good-p8-nodeport: grpc port is {grpc}, want nodePort 30443")

# 9. External database Secret.
for case in ("good-p9-db", "good-p9-db-without-enabled"):
    gw = gateway_container(case)
    want = {"name": "OPENSHELL_DB_URL", "valueFrom": {"secretKeyRef": {"name": "osh-db", "key": "uri"}}}
    if env_of(gw).get("OPENSHELL_DB_URL") != want:
        failures.append(f"{case}: OPENSHELL_DB_URL is {env_of(gw).get('OPENSHELL_DB_URL')}")
    if any(a.startswith("--db-url") for a in gw_args(case)):
        failures.append(f"{case}: gateway args carry --db-url: {gw_args(case)}")
    if any(d.get("kind") == "PersistentVolumeClaim" for d in docs(case)):
        failures.append(f"{case}: a PersistentVolumeClaim was rendered")
    if any(v["name"] == "gateway-db" for v in pod_spec(case).get("volumes", [])):
        failures.append(f"{case}: the gateway-db volume was rendered")
sq = gateway_container("good-p9-sqlite")
if "OPENSHELL_DB_URL" in env_of(sq) or "--db-url" not in gw_args("good-p9-sqlite"):
    failures.append("good-p9-sqlite: SQLite mode lost its --db-url arg or gained OPENSHELL_DB_URL")
if not any(d.get("kind") == "PersistentVolumeClaim" for d in docs("good-p9-sqlite")):
    failures.append("good-p9-sqlite: no PersistentVolumeClaim was rendered")

# 10. rbac.create.
RBAC_KINDS = ("Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding")

def rbac_objects(case, hooks):
    """(kind, name) of the RBAC objects of a render: the ones with a helm.sh/hook
    annotation when hooks is True, the others when it is False."""
    return sorted((d["kind"], d["metadata"]["name"]) for d in docs(case) if d.get("kind") in RBAC_KINDS
                  and ("helm.sh/hook" in (d["metadata"].get("annotations") or {})) == hooks)

if not rbac_objects("good-p10-default", False):
    failures.append("good-p10-default: no chart RBAC rendered")
if rbac_objects("good-p10-default", False) != rbac_objects("good-p10-shared-true", False):
    failures.append("good-p10-default: RBAC differs from render-shared-true: "
                    f"{rbac_objects('good-p10-default', False)} vs {rbac_objects('good-p10-shared-true', False)}")
if ("Role", "t-openshell-driver-kyma-workspace-secret-source") not in rbac_objects("good-p10-managed", False):
    failures.append("good-p10-managed: no workspace-secret-source Role rendered; the sources case tests nothing")
for case in ("good-p10-no-rbac", "good-p10-no-rbac-sources"):
    left = rbac_objects(case, False)
    if left:
        failures.append(f"{case}: rbac.create=false still renders {left}")
    want = rbac_objects("good-p10-managed" if case.endswith("sources") else "good-p10-default", True)
    if rbac_objects(case, True) != want or not want:
        failures.append(f"{case}: hook RBAC changed: {rbac_objects(case, True)} vs {want}")
hook_kinds = {k for k, _ in rbac_objects("good-p10-no-rbac", True)}
if not {"Role", "RoleBinding"} <= hook_kinds:
    failures.append(f"good-p10-no-rbac: the PKI and provider hook Roles are missing: {hook_kinds}")

# 11. Extra server SANs and a separate client CA Secret.
def hook_sans(case):
    job = next((d for d in docs(case) if d.get("kind") == "Job" and d["metadata"]["name"].endswith("-jwt-pki-hook")), None)
    if job is None:
        failures.append(f"{case}: no PKI hook Job was rendered")
        return []
    return [a for a in job["spec"]["template"]["spec"]["containers"][0]["args"] if a.startswith("--server-san=")]

def gateway_sans(case):
    """Every value of a --server-san flag on the gateway, in either spelling."""
    args = gw_args(case)
    return [args[i + 1] for i, a in enumerate(args[:-1]) if a == "--server-san"] + \
           [a.split("=", 1)[1] for a in args if a.startswith("--server-san=")]

for case in ("good-p11-sans", "good-p11-sans-ingress"):
    got = hook_sans(case)
    if got[-2:] != ["--server-san=gw.example.org", "--server-san=10.0.0.5"] or len(got) != 8:
        failures.append(f"{case}: the PKI hook's --server-san are {got}, want today's six then gw.example.org and 10.0.0.5")
    sans = gateway_sans(case)
    if len(sans) != 1:
        failures.append(f"{case}: the gateway has {len(sans)} --server-san args ({sans}), want exactly one")
    else:
        names = sans[0].split(",")
        want = ["gw.example.org", "10.0.0.5"] + (["*.example.org"] if case.endswith("ingress") else [])
        if sorted(names) != sorted(want):
            failures.append(f"{case}: the gateway's --server-san is {sans[0]!r}, want {want}")
for case in ("good-p1-defaults", "good-p11-client-ca"):
    if gateway_sans(case):
        failures.append(f"{case}: the gateway has --server-san {gateway_sans(case)}, want none")
if len(hook_sans("good-p1-defaults")) != 6:
    failures.append("good-p1-defaults: the PKI hook does not carry exactly today's six --server-san")

def client_ca_case(case, want_path, want_volume):
    gw = gateway_container(case)
    args = gw.get("args", [])
    got = args[args.index("--tls-client-ca") + 1] if "--tls-client-ca" in args else None
    if got != want_path:
        failures.append(f"{case}: --tls-client-ca is {got!r}, want {want_path!r}")
    vols = [v for v in pod_spec(case).get("volumes", []) if v["name"] == "tls-client-ca"]
    mounts = [m for m in gw.get("volumeMounts", []) if m["name"] == "tls-client-ca"]
    if not want_volume:
        if vols or mounts:
            failures.append(f"{case}: a tls-client-ca volume or mount was rendered: {vols} {mounts}")
        return
    if len(vols) != 1 or vols[0].get("secret", {}).get("secretName") != "user-ca" \
            or vols[0]["secret"].get("items") != [{"key": "ca.crt", "path": "ca.crt"}]:
        failures.append(f"{case}: the tls-client-ca volume is {vols}, want Secret user-ca items ca.crt")
    if len(mounts) != 1 or mounts[0].get("mountPath") != "/etc/openshell-tls/client-ca" or not mounts[0].get("readOnly"):
        failures.append(f"{case}: the tls-client-ca mount is {mounts}, want readOnly at /etc/openshell-tls/client-ca")

client_ca_case("good-p11-client-ca", "/etc/openshell-tls/client-ca/ca.crt", True)
client_ca_case("good-p11-client-ca-default", "/etc/openshell-tls/server/ca.crt", False)
client_ca_case("good-p11-client-ca-off", None, False)

# 12. The Kubernetes Secrets credential driver.
KEK_ENV = "OPENSHELL_GATEWAY_CREDENTIAL_KEY_ENCRYPTION_KEY"
KEK_SECRET = "t-openshell-driver-kyma-credential-storage-key-encryption-key"
CREDS = "t-openshell-driver-kyma-credential-secrets"
CREDS_RULES = [{"apiGroups": [""], "resources": ["secrets"], "verbs": ["get", "create", "patch", "delete"]}]

def objects(case, kind):
    return [d for d in docs(case) if d.get("kind") == kind]

def creds_objects(case, kind):
    return [d for d in objects(case, kind) if d["metadata"]["name"] == CREDS]

def kek_state(case):
    """(credential_storage table, KEK env, KEK Secret names) of a render."""
    return (gateway_toml(case).get("openshell", {}).get("gateway", {}).get("credential_storage"),
            env_of(gateway_container(case)).get(KEK_ENV),
            [d["metadata"]["name"] for d in objects(case, "Secret") if d["metadata"]["name"] == KEK_SECRET])

for case, ns, rbac in (("good-p12-k8s", "osh-creds", True), ("good-p12-k8s-default-ns", "default", True),
                       ("good-p12-create-ns", "osh-creds", True), ("good-p12-no-rbac", "osh-creds", False),
                       ("good-p12-no-rbac-global", "osh-creds", False), ("good-p12-via-config", "default", True),
                       ("good-p12-via-config-nested", "osh-creds", True), ("good-p12-existing-kek", "default", True)):
    toml = gateway_toml(case).get("openshell", {})
    if toml.get("gateway", {}).get("credential_drivers") != ["kubernetes-secrets"]:
        failures.append(f"{case}: credential_drivers is {toml.get('gateway', {}).get('credential_drivers')!r}")
    got = toml.get("credential_drivers", {}).get("kubernetes-secrets")
    if got != {"namespace": ns}:
        failures.append(f"{case}: [openshell.credential_drivers.kubernetes-secrets] is {got!r}, want namespace {ns!r}")
    if kek_state(case) != (None, None, []):
        failures.append(f"{case}: KEK storage rendered with an external driver: {kek_state(case)}")
    roles, bindings = creds_objects(case, "Role"), creds_objects(case, "RoleBinding")
    if not rbac:
        if roles or bindings:
            failures.append(f"{case}: the credential-secrets Role/RoleBinding rendered with RBAC off")
        continue
    if len(roles) != 1 or roles[0]["metadata"].get("namespace") != ns or roles[0].get("rules") != CREDS_RULES:
        failures.append(f"{case}: the credential-secrets Role is {roles}, want one in {ns} with {CREDS_RULES}")
    want_binding = {"roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": CREDS},
                    "subjects": [{"kind": "ServiceAccount", "name": "openshell-driver", "namespace": "default"}]}
    if len(bindings) != 1 or bindings[0]["metadata"].get("namespace") != ns or \
            {k: bindings[0].get(k) for k in want_binding} != want_binding:
        failures.append(f"{case}: the credential-secrets RoleBinding is {bindings}, want one in {ns}: {want_binding}")
# Only the nested flag: the chart's other RBAC stays.
if rbac_objects("good-p12-no-rbac", False) != rbac_objects("good-p10-default", False):
    failures.append("good-p12-no-rbac: kubernetesSecrets.rbac.create=false changed the chart's other RBAC: "
                    f"{rbac_objects('good-p12-no-rbac', False)}")
if rbac_objects("good-p12-no-rbac-global", False):
    failures.append(f"good-p12-no-rbac-global: rbac.create=false still renders {rbac_objects('good-p12-no-rbac-global', False)}")
for case in ("good-p12-k8s", "good-p12-k8s-default-ns", "good-p12-via-config", "good-p1-defaults"):
    if objects(case, "Namespace"):
        failures.append(f"{case}: a Namespace was rendered without createNamespace")
nss = objects("good-p12-create-ns", "Namespace")
if [(n["metadata"]["name"], (n["metadata"].get("annotations") or {}).get("helm.sh/resource-policy")) for n in nss] \
        != [("osh-creds", "keep")]:
    failures.append(f"good-p12-create-ns: Namespaces are {nss}, want osh-creds with helm.sh/resource-policy: keep")
# Without the driver: the KEK storage stays, and no credential-secrets RBAC.
want_kek = ({"key_encryption_key_env": KEK_ENV},
            {"name": KEK_ENV, "valueFrom": {"secretKeyRef": {"name": KEK_SECRET, "key": "key-encryption-key"}}},
            [KEK_SECRET])
if kek_state("good-p1-defaults") != want_kek:
    failures.append(f"good-p1-defaults: KEK storage is {kek_state('good-p1-defaults')}, want {want_kek}")
if creds_objects("good-p1-defaults", "Role") or creds_objects("good-p1-defaults", "RoleBinding") or \
        gateway_toml("good-p1-defaults").get("openshell", {}).get("gateway", {}).get("credential_drivers"):
    failures.append("good-p1-defaults: the credential driver rendered without being selected")

# 13. The Vault credential driver.
VAULT_BASE = {"address": "https://vault.example.org", "auth_method": "kubernetes", "role": "osh", "mount": "secret",
              "kv_version": "2", "kubernetes_auth_mount": "kubernetes",
              "service_account_token_path": "/var/run/secrets/kubernetes.io/serviceaccount/token"}
VAULT_CA = "/etc/openshell-tls/vault-ca/ca.crt"
for case, want_table, want_ports in (
        ("good-p13-vault", {**VAULT_BASE, "timeout_secs": 30, "ca_bundle": VAULT_CA}, [443]),
        ("good-p13-timeout-string", {**VAULT_BASE, "role": "", "timeout_secs": 45}, [443]),
        ("good-p13-vault-port", {**VAULT_BASE, "address": "https://vault.example.org:8200", "role": ""}, [443, 8200]),
        ("good-p13-vault-loopback-http", {**VAULT_BASE, "address": "http://localhost", "role": ""}, [443, 8200]),
        ("good-p13-vault-no-np", {**VAULT_BASE, "role": ""}, None),
        # Selected only by gatewayConfig: the values are not applied (enabled is false), the user's table is.
        ("good-p13-vault-via-config", {"address": "https://vault.example.org", "role": "osh"}, [443]),
        # ... and the CA ConfigMap still mounts, with the chart's ca_bundle replacing the user's.
        ("good-p13-vault-via-config-ca", {"address": "https://vault.example.org:8443", "ca_bundle": VAULT_CA},
         [443, 8443])):
    toml = gateway_toml(case).get("openshell", {})
    if toml.get("gateway", {}).get("credential_drivers") != ["vault"]:
        failures.append(f"{case}: credential_drivers is {toml.get('gateway', {}).get('credential_drivers')!r}")
    got = toml.get("credential_drivers", {}).get("vault")
    if got != want_table or (want_table.get("timeout_secs") is not None and type(got.get("timeout_secs")) is not int):
        failures.append(f"{case}: [openshell.credential_drivers.vault] is {got!r}, want {want_table!r}")
    if "kubernetes-secrets" in toml.get("credential_drivers", {}):
        failures.append(f"{case}: a kubernetes-secrets table rendered with Vault selected")
    if kek_state(case) != (None, None, []):
        failures.append(f"{case}: KEK storage rendered with an external driver: {kek_state(case)}")
    if creds_objects(case, "Role") or creds_objects(case, "RoleBinding") or objects(case, "Namespace"):
        failures.append(f"{case}: Kubernetes Secrets driver objects rendered with Vault selected")
    ports = pod_egress_ports(case)
    if want_ports is None:
        if ports is not None:
            failures.append(f"{case}: networkPolicy.enabled=false still rendered the pod NetworkPolicy ({ports})")
    elif ports is None or not set(want_ports) <= set(ports) or (8200 not in want_ports and 8200 in ports):
        failures.append(f"{case}: the pod NetworkPolicy egress ports are {ports!r}, want {want_ports!r} among them")
    vols = [v for v in pod_spec(case).get("volumes", []) if v["name"] == "vault-ca"]
    mounts = [m for m in gateway_container(case).get("volumeMounts", []) if m["name"] == "vault-ca"]
    if VAULT_CA in (want_table.get("ca_bundle"),):
        if len(vols) != 1 or vols[0].get("configMap") != {"name": "vault-ca", "items": [{"key": "ca.crt", "path": "ca.crt"}]}:
            failures.append(f"{case}: the vault-ca volume is {vols}, want ConfigMap vault-ca items ca.crt")
        if len(mounts) != 1 or mounts[0].get("mountPath") != "/etc/openshell-tls/vault-ca" or not mounts[0].get("readOnly"):
            failures.append(f"{case}: the vault-ca mount is {mounts}, want readOnly at /etc/openshell-tls/vault-ca")
    elif vols or mounts:
        failures.append(f"{case}: a vault-ca volume or mount rendered without a CA ConfigMap: {vols} {mounts}")

# 14. SPIFFE Workload API for the gateway's provider token grants.
GW_SPIFFE_ENV = "OPENSHELL_GATEWAY_SPIFFE_WORKLOAD_API_SOCKET"
DRV_SPIFFE_ENV = "OPENSHELL_PROVIDER_SPIFFE_WORKLOAD_API_SOCKET"
SPIFFE_DIR = "/spiffe-workload-api"
SPIFFE_VOLUME = {"name": "spiffe-workload-api", "csi": {"driver": "csi.spiffe.io", "readOnly": True}}
for case, gw_sock, drv_sock, mount in (
        ("good-p14-spiffe", SPIFFE_DIR + "/spire-agent.sock", SPIFFE_DIR + "/spire-agent.sock", SPIFFE_DIR),
        ("good-p14-spiffe-path", "/run/spire/sock/agent.sock", "/run/spire/sock/agent.sock", "/run/spire/sock"),
        ("good-p14-spiffe-driver-override", SPIFFE_DIR + "/spire-agent.sock", "/x/y.sock", SPIFFE_DIR),
        ("good-p14-driver-override", None, "/x/y.sock", None),
        ("good-p1-defaults", None, None, None)):
    gw_env, drv_env = env_of(gateway_container(case)), env_of(driver_container(case))
    got_gw, got_drv = gw_env.get(GW_SPIFFE_ENV, {}).get("value"), drv_env.get(DRV_SPIFFE_ENV, {}).get("value")
    if got_gw != gw_sock:
        failures.append(f"{case}: {GW_SPIFFE_ENV} is {got_gw!r}, want {gw_sock!r}")
    if got_drv != drv_sock:
        failures.append(f"{case}: {DRV_SPIFFE_ENV} is {got_drv!r}, want {drv_sock!r}")
    vols = [v for v in pod_spec(case).get("volumes", []) if v["name"] == "spiffe-workload-api"]
    mounts = [m for m in gateway_container(case).get("volumeMounts", []) if m["name"] == "spiffe-workload-api"]
    driver_mounts = [m for m in driver_container(case).get("volumeMounts", []) if m["name"] == "spiffe-workload-api"]
    if mount is None:
        if vols or mounts:
            failures.append(f"{case}: a SPIFFE volume or mount rendered without SPIFFE enabled: {vols} {mounts}")
        continue
    if vols != [SPIFFE_VOLUME]:
        failures.append(f"{case}: the spiffe-workload-api volume is {vols}, want {SPIFFE_VOLUME}")
    if mounts != [{"name": "spiffe-workload-api", "mountPath": mount, "readOnly": True}]:
        failures.append(f"{case}: the spiffe-workload-api mount is {mounts}, want readOnly at {mount}")
    if driver_mounts:
        failures.append(f"{case}: the driver container mounts the SPIFFE socket: {driver_mounts}")

# 15. Certificates from cert-manager.
FN = "t-openshell-driver-kyma"
CM_API = "cert-manager.io/v1"
CA_ISSUER_REF = {"name": f"{FN}-ca-issuer", "kind": "Issuer", "group": "cert-manager.io"}
ECDSA = {"algorithm": "ECDSA", "size": 256}
HOOK_SANS = [FN, f"{FN}.default", f"{FN}.default.svc", f"{FN}.default.svc.cluster.local", "localhost"]

def cm_objects(case, api=CM_API):
    return {(d["kind"], d["metadata"]["name"]): d for d in docs(case) if d.get("apiVersion") == api}

def want_cm(ca_secret=f"{FN}-ca-tls", ca_duration="87600h", dns=(), ips=(), duration="8760h", renew="720h"):
    leaf = {"duration": duration, "renewBefore": renew, "privateKey": ECDSA, "issuerRef": CA_ISSUER_REF}
    return {
        ("Issuer", f"{FN}-selfsigned"): {"selfSigned": {}},
        ("Certificate", f"{FN}-ca"): {
            "isCA": True, "commonName": "openshell-ca", "secretName": ca_secret, "duration": ca_duration,
            "privateKey": ECDSA, "issuerRef": {"name": f"{FN}-selfsigned", "kind": "Issuer", "group": "cert-manager.io"}},
        ("Issuer", f"{FN}-ca-issuer"): {"ca": {"secretName": ca_secret}},
        ("Certificate", f"{FN}-server"): {
            **leaf, "secretName": f"{FN}-server-tls", "commonName": FN, "dnsNames": HOOK_SANS + list(dns),
            "ipAddresses": ["127.0.0.1"] + list(ips),
            "usages": ["server auth", "digital signature", "key encipherment"]},
        ("Certificate", f"{FN}-client"): {
            **leaf, "secretName": f"{FN}-client-tls", "commonName": "openshell-client",
            "usages": ["client auth", "digital signature", "key encipherment"]},
    }

for case, want in (("good-p15-cm", want_cm()), ("good-p15-cm-ingress", want_cm()),
                   ("good-p15-cm-sans", want_cm(ca_secret="own-ca", ca_duration="9481h", dns=["gw.example.org"],
                                                ips=["10.0.0.5"])),
                   ("good-p15-cm-mixed-durations", want_cm(ca_duration="2h15m1s", duration="1h30m", renew="45m"))):
    got = cm_objects(case)
    if {k: v.get("spec") for k, v in got.items()} != want:
        failures.append(f"{case}: the cert-manager objects are {[(k, v.get('spec')) for k, v in got.items()]}, "
                        f"want exactly {want}")
    for (kind, name), d in got.items():
        if d["metadata"].get("namespace") != "default":
            failures.append(f"{case}: {kind} {name} is not in the release namespace")
for case in ("good-p1-defaults", "good-p7-tls", "good-p8-lb-ingress"):
    if cm_objects(case):
        failures.append(f"{case}: cert-manager objects rendered without gateway.certManager.enabled")

def jobs(case):
    return {d["metadata"]["name"]: d for d in docs(case) if d.get("kind") == "Job"}

def job_args(case, name):
    job = jobs(case).get(name)
    if job is None:
        failures.append(f"{case}: no Job {name} was rendered")
        return None
    return job["spec"]["template"]["spec"]["containers"][0]["args"]

JWT_ONLY = ["generate-certs", "--namespace=$(POD_NAMESPACE)", "--jwt-only", f"--jwt-secret-name={FN}-jwt-keys"]
BACKEND_CA = f"{FN}-backend-ca"
for case in ("good-p15-cm", "good-p15-cm-ingress", "good-p15-cm-separate-ca"):
    got = job_args(case, f"{FN}-jwt-pki-hook")
    if got is not None and got != JWT_ONLY:
        failures.append(f"{case}: the PKI hook args are {got}, want {JWT_ONLY}")
    pki_role = next((d for d in objects(case, "Role") if d["metadata"]["name"] == f"{FN}-jwt-pki-hook"), {})
    if pki_role.get("rules") != [{"apiGroups": [""], "resources": ["secrets"], "verbs": ["get", "create"]}]:
        failures.append(f"{case}: the PKI hook Role rules are {pki_role.get('rules')}, want secrets get/create only")
for case in ("good-p15-cm", "good-p15-cm-separate-ca", "good-p1-defaults", "good-p8-lb-ingress"):
    if BACKEND_CA in jobs(case) or any(d["metadata"]["name"] == BACKEND_CA for d in docs(case)):
        failures.append(f"{case}: backend-CA objects rendered without cert-manager and gatewayIngress")
want_backend_args = JWT_ONLY + [f"--backend-ca-configmap-name={FN}-gateway-ca",
                                f"--backend-ca-source-secret={FN}-server-tls",
                                "--backend-ca-poll-timeout-seconds=120", "--backend-ca-fail-on-timeout"]
got = job_args("good-p15-cm-ingress", BACKEND_CA)
if got is not None and got != want_backend_args:
    failures.append(f"good-p15-cm-ingress: the backend-CA Job args are {got}, want {want_backend_args}")
want = want_backend_args[:-2] + ["--backend-ca-poll-timeout-seconds=60"]
if job_args("good-p15-cm-no-fail", BACKEND_CA) != want or \
        jobs("good-p15-cm-no-fail").get(BACKEND_CA, {}).get("spec", {}).get("activeDeadlineSeconds") != 90:
    failures.append(f"good-p15-cm-no-fail: the backend-CA Job args are {job_args('good-p15-cm-no-fail', BACKEND_CA)}, "
                    f"want {want} and a 90 s deadline")
job = jobs("good-p15-cm-ingress").get(BACKEND_CA, {"metadata": {}, "spec": {"template": {"spec": {}}}})
ann = job["metadata"].get("annotations") or {}
if (ann.get("helm.sh/hook"), ann.get("helm.sh/hook-weight")) != ("post-install,post-upgrade", "0"):
    failures.append(f"good-p15-cm-ingress: the backend-CA Job hook annotations are {ann}")
if job["spec"].get("activeDeadlineSeconds") != 150:
    failures.append(f"good-p15-cm-ingress: the backend-CA Job activeDeadlineSeconds is "
                    f"{job['spec'].get('activeDeadlineSeconds')}, want 150")
if job["spec"]["template"]["spec"].get("serviceAccountName") != BACKEND_CA:
    failures.append(f"good-p15-cm-ingress: the backend-CA Job runs as "
                    f"{job['spec']['template']['spec'].get('serviceAccountName')}, want {BACKEND_CA}")
role = next((d for d in objects("good-p15-cm-ingress", "Role") if d["metadata"]["name"] == BACKEND_CA), {})
want_rules = [{"apiGroups": [""], "resources": ["secrets"], "verbs": ["get"]},
              {"apiGroups": [""], "resources": ["configmaps"], "verbs": ["get", "create", "update"]}]
if role.get("rules") != want_rules:
    failures.append(f"good-p15-cm-ingress: the backend-CA Role rules are {role.get('rules')}, want {want_rules}")
binding = next((d for d in objects("good-p15-cm-ingress", "RoleBinding") if d["metadata"]["name"] == BACKEND_CA), {})
if binding.get("roleRef", {}).get("name") != BACKEND_CA or \
        binding.get("subjects") != [{"kind": "ServiceAccount", "name": BACKEND_CA, "namespace": "default"}]:
    failures.append(f"good-p15-cm-ingress: the backend-CA RoleBinding is {binding}")
if not any(d["metadata"]["name"] == BACKEND_CA for d in objects("good-p15-cm-ingress", "ServiceAccount")):
    failures.append("good-p15-cm-ingress: no backend-CA ServiceAccount was rendered")
# Without cert-manager the PKI hook still writes the CA ConfigMap itself.
got = job_args("good-p8-lb-ingress", f"{FN}-jwt-pki-hook") or []
if f"--backend-ca-configmap-name={FN}-gateway-ca" not in got:
    failures.append(f"good-p8-lb-ingress: the PKI hook lost --backend-ca-configmap-name: {got}")
# The gateway reads the client CA from the separate Secret.
gw = gateway_container("good-p15-cm-separate-ca")
args = gw.get("args", [])
got = args[args.index("--tls-client-ca") + 1] if "--tls-client-ca" in args else None
if got != "/etc/openshell-tls/client-ca/ca.crt":
    failures.append(f"good-p15-cm-separate-ca: --tls-client-ca is {got!r}, want /etc/openshell-tls/client-ca/ca.crt")
vols = [v for v in pod_spec("good-p15-cm-separate-ca").get("volumes", []) if v["name"] == "tls-client-ca"]
if [v.get("secret", {}).get("secretName") for v in vols] != [f"{FN}-ca-tls"]:
    failures.append(f"good-p15-cm-separate-ca: the tls-client-ca volume is {vols}, want Secret {FN}-ca-tls")
# Extra cert-manager names also reach the gateway's runtime --server-san.
if gateway_sans("good-p15-cm-sans") != ["gw.example.org,10.0.0.5"]:
    failures.append(f"good-p15-cm-sans: the gateway's --server-san is {gateway_sans('good-p15-cm-sans')}, "
                    "want ['gw.example.org,10.0.0.5']")

# 16. Certificates from Gardener: the same five objects as cert-manager, in Gardener's schema.
GD_API = "cert.gardener.cloud/v1alpha1"
NS_REF = lambda name: {"name": name, "namespace": "default"}

def want_gardener(ca_secret=f"{FN}-ca-tls", ca_duration="87600h", dns=(), ips=(), duration="8760h", renew="720h"):
    want = want_cm(ca_secret, ca_duration, dns, ips, duration, renew)
    for spec in want.values():
        if "issuerRef" in spec:
            spec["issuerRef"] = NS_REF(spec["issuerRef"]["name"])
    want[("Issuer", f"{FN}-ca-issuer")] = {"ca": {"privateKeySecretRef": NS_REF(ca_secret)}}
    return want

for case, want in (("good-p16-gardener", want_gardener()), ("good-p16-gardener-ingress", want_gardener()),
                   ("good-p16-gardener-sans", want_gardener(ca_secret="own-ca", ca_duration="9481h",
                                                            dns=["gw.example.org"], ips=["10.0.0.5"])),
                   ("good-p16-gardener-mixed-durations",
                    want_gardener(ca_duration="2h15m1s", duration="1h30m", renew="45m"))):
    got = cm_objects(case, GD_API)
    if {k: v.get("spec") for k, v in got.items()} != want:
        failures.append(f"{case}: the Gardener objects are {[(k, v.get('spec')) for k, v in got.items()]}, "
                        f"want exactly {want}")
    for (kind, name), d in got.items():
        if d["metadata"].get("namespace") != "default":
            failures.append(f"{case}: {kind} {name} is not in the release namespace")
    if cm_objects(case):
        failures.append(f"{case}: cert-manager.io objects rendered with api cert.gardener.cloud")
for case in ("good-p15-cm", "good-p1-defaults", "good-p7-tls"):
    if cm_objects(case, GD_API):
        failures.append(f"{case}: Gardener objects rendered without api cert.gardener.cloud")
for case in ("good-p16-gardener", "good-p16-gardener-ingress"):
    got = job_args(case, f"{FN}-jwt-pki-hook")
    if got is not None and got != JWT_ONLY:
        failures.append(f"{case}: the PKI hook args are {got}, want {JWT_ONLY}")
got = job_args("good-p16-gardener-ingress", BACKEND_CA)
if got != want_backend_args:
    failures.append(f"good-p16-gardener-ingress: the backend-CA Job args are {got}, want {want_backend_args}")

# 19. The sandbox namespace: the release namespace unless `namespace` names another.
SANDBOX_NS_OBJECTS = {("ServiceAccount", "openshell-sandbox"), ("Role", FN), ("RoleBinding", FN),
                      ("NetworkPolicy", f"{FN}-sandbox-ssh")}
for case, want in (("good-q1-ns-default", "osh-a"), ("good-q1-ns-explicit", "osh-sb")):
    got = {(d["kind"], d["metadata"]["name"]): d["metadata"].get("namespace") for d in docs(case)
           if (d["kind"], d["metadata"]["name"]) in SANDBOX_NS_OBJECTS}
    if got != {k: want for k in SANDBOX_NS_OBJECTS}:
        failures.append(f"{case}: the sandbox-namespace objects are in {got}, want all in {want!r}")
    env = env_of(driver_container(case)).get("OPENSHELL_SANDBOX_NAMESPACE", {}).get("value")
    if env != want:
        failures.append(f"{case}: the driver's OPENSHELL_SANDBOX_NAMESPACE is {env!r}, want {want!r}")

# 19. The gateway's SPIFFE socket is no default for the driver when the gateway runs elsewhere.
case = "good-q4-spiffe-gateway-off"
if "OPENSHELL_PROVIDER_SPIFFE_WORKLOAD_API_SOCKET" in env_of(driver_container(case)):
    failures.append(f"{case}: the driver got the gateway's SPIFFE socket although the gateway runs elsewhere")
if any(v.get("name") == "spiffe-workload-api" for v in (pod_spec(case) or {}).get("volumes", [])):
    failures.append(f"{case}: the pod mounts the SPIFFE Workload API although the gateway runs elsewhere")

# 19. gatewayConfig's OTLP endpoint and gateway name: the driver and the egress follow them.
case = "good-q5-otlp-config"
got = env_of(driver_container(case)).get("OPENSHELL_OTLP_ENDPOINT", {}).get("value")
if got != "http://otel.example.org:4318":
    failures.append(f"{case}: the driver's OPENSHELL_OTLP_ENDPOINT is {got!r}, want the gatewayConfig endpoint")
if 4318 not in (pod_egress_ports(case) or []):
    failures.append(f"{case}: the pod NetworkPolicy egress ports are {pod_egress_ports(case)!r}, want 4318 among them")
case = "good-q5-name-config"
got = env_of(driver_container(case)).get("OPENSHELL_GATEWAY_NAME", {}).get("value")
toml_name = gateway_toml(case).get("openshell", {}).get("gateway", {}).get("name")
if (got, toml_name) != ("from-config", "from-config"):
    failures.append(f"{case}: driver OPENSHELL_GATEWAY_NAME {got!r} and TOML name {toml_name!r}, want both 'from-config'")

# 19. Hook objects (Jobs and their ServiceAccounts and RBAC) are deleted once their hook
# succeeds: before-hook-creation alone leaves them behind after `helm uninstall`.
for case in ("good-p1-defaults", "good-p15-cm-ingress", "good-p16-gardener-ingress"):
    for d in docs(case):
        annotations = d["metadata"].get("annotations") or {}
        if "helm.sh/hook" in annotations and "hook-succeeded" not in annotations.get("helm.sh/hook-delete-policy", ""):
            failures.append(f"{case}: hook {d['kind']} {d['metadata']['name']} is not deleted when its hook succeeds")

# 19. With the gateway elsewhere the driver still exports to gateway.otlp.endpoint, and the pod may dial it.
case = "good-q8-otlp-gateway-off"
got = env_of(driver_container(case)).get("OPENSHELL_OTLP_ENDPOINT", {}).get("value")
if got != "http://otel.example.org:4318":
    failures.append(f"{case}: the driver's OPENSHELL_OTLP_ENDPOINT is {got!r}, want gateway.otlp.endpoint")
if 4318 not in (pod_egress_ports(case) or []):
    failures.append(f"{case}: the pod NetworkPolicy egress ports are {pod_egress_ports(case)!r}, want 4318 among them")
if any(c["name"] == "gateway" for c in (pod_spec(case) or {}).get("containers", [])):
    failures.append(f"{case}: a gateway container rendered with gateway.enabled=false")

if failures:
    print("CHART_PARITY_FAIL:")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("CHART_PARITY_OK")
PY
