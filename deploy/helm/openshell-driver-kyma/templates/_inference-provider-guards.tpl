{{/* Pre-flight guards for inferenceProvider.

Uses the chart's `{{- fail -}}` style: when an opt-in
block is enabled but missing a required field, refuse to render with an
actionable message instead of silently producing broken manifests.

Called via `{{ include "openshell-driver-kyma.inferenceProviderGuards" . }}`
from any template that needs the validation. We invoke it from the
inference-provider-hook.yaml template. The guards exist standalone so
anyone running `helm lint --strict` with inferenceProvider.enabled=true
gets immediate feedback. */}}

{{- define "openshell-driver-kyma.inferenceProviderGuards" -}}
{{- if .Values.inferenceProvider.enabled -}}
{{- if not .Values.inferenceProvider.type -}}
{{- fail "inferenceProvider.enabled=true requires inferenceProvider.type (e.g. \"anthropic\")." -}}
{{- end -}}
{{- if ne .Values.inferenceProvider.type "anthropic" -}}
{{- fail (printf "inferenceProvider.type %q is not supported: the chart ships a provider profile for \"anthropic\" only." .Values.inferenceProvider.type) -}}
{{- end -}}
{{- if not .Values.inferenceProvider.baseUrl -}}
{{- fail "inferenceProvider.enabled=true requires inferenceProvider.baseUrl (e.g. http://gateway.your-llm-ns.svc.cluster.local:8080/anthropic)." -}}
{{- end -}}
{{- $url := urlParse .Values.inferenceProvider.baseUrl -}}
{{- /* Checked before any message that would echo the value: a URL can carry credentials. */ -}}
{{- if $url.userinfo -}}
{{- fail "inferenceProvider.baseUrl must not carry credentials (user:password@host): the profile is stored in a ConfigMap and the sandboxes' environment. The API key comes from inferenceProvider.credentialSecret." -}}
{{- end -}}
{{- if not (has $url.scheme (list "http" "https")) -}}
{{- fail "inferenceProvider.baseUrl must be an http:// or https:// URL (e.g. http://gateway.your-llm-ns.svc.cluster.local:8080/anthropic)." -}}
{{- end -}}
{{- if not $url.hostname -}}
{{- fail "inferenceProvider.baseUrl has no host (e.g. http://gateway.your-llm-ns.svc.cluster.local:8080/anthropic)." -}}
{{- end -}}
{{- if contains ":" $url.hostname -}}
{{- fail "inferenceProvider.baseUrl uses an IPv6 literal, which the chart does not support: the provider profile takes a host name. Use a DNS name." -}}
{{- end -}}
{{- if contains "," .Values.inferenceProvider.baseUrl -}}
{{- fail (printf "inferenceProvider.baseUrl %q contains a comma; it reaches sandboxes as ANTHROPIC_BASE_URL through OPENSHELL_KYMA_SANDBOX_ENV, which the driver splits on commas, so a value cannot contain one." .Values.inferenceProvider.baseUrl) -}}
{{- end -}}
{{- if not .Values.inferenceProvider.modelId -}}
{{- fail "inferenceProvider.enabled=true requires inferenceProvider.modelId (e.g. claude-opus-4-7)." -}}
{{- end -}}
{{- if contains "," .Values.inferenceProvider.modelId -}}
{{- fail (printf "inferenceProvider.modelId %q contains a comma; it reaches sandboxes as ANTHROPIC_MODEL through OPENSHELL_KYMA_SANDBOX_ENV, which the driver splits on commas, so a value cannot contain one." .Values.inferenceProvider.modelId) -}}
{{- end -}}
{{- if not .Values.inferenceProvider.binaries -}}
{{- fail "inferenceProvider.enabled=true requires inferenceProvider.binaries: the executable paths allowed to reach the endpoint (e.g. /usr/bin/node, which runs claude-code). An empty list leaves the provider's policy with no process able to use it." -}}
{{- end -}}
{{- if not .Values.inferenceProvider.credentialSecret.name -}}
{{- fail "inferenceProvider.enabled=true requires inferenceProvider.credentialSecret.name pointing at a Secret you manage in .Release.Namespace." -}}
{{- end -}}
{{- if not .Values.inferenceProvider.credentialSecret.key -}}
{{- fail "inferenceProvider.enabled=true requires inferenceProvider.credentialSecret.key (the key inside the Secret holding the API token)." -}}
{{- end -}}
{{- /* The hook registers the provider with this release's in-pod gateway through
the release's Service (GATEWAY_URL and GATEWAY_HEALTH_URL in
inference-provider-hook.yaml), whose gateway ports exist only with
gatewayService.enabled (service.yaml). Without either, it waits for a gateway that
never answers and fails the install. */ -}}
{{- if not (and .Values.gateway.enabled .Values.gatewayService.enabled) -}}
{{- fail "inferenceProvider.enabled=true requires gateway.enabled=true and gatewayService.enabled=true: the provider hook registers the provider with this release's in-pod gateway through the release's Service, which exposes the gateway's ports only with gatewayService.enabled." -}}
{{- end -}}
{{- /* With an OIDC issuer the gateway runs allow_unauthenticated_users = false
(gateway-config.yaml), and upstream then answers a call without a bearer token
with Unauthenticated (openshell-server src/multiplex.rs AuthGrpcRouter at the
pinned tag). The hook therefore authenticates with the client-credentials grant
(inference-provider-hook.yaml), which needs the client and its secret. */ -}}
{{- if .Values.gateway.oidc.issuer -}}
{{- if not (or .Values.gateway.oidc.clientCredentialsSecret.clientId .Values.gateway.oidc.clientId) -}}
{{- fail "inferenceProvider.enabled=true with gateway.oidc.issuer requires gateway.oidc.clientId, or gateway.oidc.clientCredentialsSecret.clientId when the provider uses a separate confidential client: the provider hook authenticates to the gateway with that client's client-credentials grant." -}}
{{- end -}}
{{- if not (and .Values.gateway.oidc.clientCredentialsSecret.name .Values.gateway.oidc.clientCredentialsSecret.key) -}}
{{- fail "inferenceProvider.enabled=true with gateway.oidc.issuer requires gateway.oidc.clientCredentialsSecret.name (and .key): a Secret you manage in .Release.Namespace holding the OIDC client secret, which the provider hook exchanges for a token. Without one, leave inferenceProvider disabled and register the profile and provider from an authenticated CLI session (docs/production-deployment.md)." -}}
{{- end -}}
{{- end -}}
{{- /* The hook dials the gateway at http:// (GATEWAY_URL and GATEWAY_HEALTH_URL in
inference-provider-hook.yaml, whatever gateway.tls.enabled says) and mounts no
client certificate, so against a gateway that terminates TLS every call fails
and so does the install. */ -}}
{{- if .Values.gateway.tls.enabled -}}
{{- fail "inferenceProvider.enabled=true cannot be combined with gateway.tls.enabled=true: the provider hook always dials the gateway over http:// and presents no client certificate, so it cannot reach a gateway that terminates TLS. Set inferenceProvider.enabled=false and register the profile and provider from a CLI session that trusts the gateway's CA (docs/production-deployment.md), or set gateway.tls.enabled=false." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "openshell-driver-kyma.gatewayTlsGuards" -}}
{{- if .Values.gateway.tls.enabled -}}
{{- if not .Values.gateway.enabled -}}
{{- fail "gateway.tls.enabled=true requires gateway.enabled=true (no in-pod gateway sidecar to terminate TLS on)." -}}
{{- end -}}
{{- if not .Values.gateway.sandboxJwt.enabled -}}
{{- fail "gateway.tls.enabled=true requires gateway.sandboxJwt.enabled=true — the chart's gateway-jwt-pki-hook is what creates the server-tls Secret. Either flip sandboxJwt on, or pre-create a kubernetes.io/tls Secret named per gateway.sandboxJwt.serverTlsSecretName and disable the hook." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Pre-flight guards for the in-pod gateway, called from deployment.yaml.

- Sandboxes dial OPENSHELL_GRPC_ENDPOINT (upstream hands it to each supervisor as
  OPENSHELL_ENDPOINT, openshell-driver-kubernetes src/sandbox_runtime.rs:245 at
  the pinned tag). Unless driver.gatewayEndpoint names another address it is this
  release's Service (openshell-driver-kyma.grpcEndpoint), whose gateway port
  exists only with gatewayService.enabled (service.yaml).
- A supervisor bootstraps by calling IssueSandboxToken, which upstream answers
  with Unavailable unless the gateway has [openshell.gateway.gateway_jwt]
  (openshell-server src/grpc/auth_rpc.rs handle_issue_sandbox_token; without it
  the gateway also never enables the compute-driver authenticator,
  src/lib.rs:747-756). The chart renders that table only with
  gateway.sandboxJwt.enabled; upstream's chart always renders it. */}}
{{- define "openshell-driver-kyma.gatewayGuards" -}}
{{- if .Values.gateway.enabled -}}
{{- if and (not .Values.gatewayService.enabled) (not .Values.driver.gatewayEndpoint) -}}
{{- fail "gateway.enabled=true requires gatewayService.enabled=true, or driver.gatewayEndpoint naming the address sandboxes reach the gateway at: by default sandboxes dial this release's Service, which exposes the gateway's port only with gatewayService.enabled." -}}
{{- end -}}
{{- if not .Values.gateway.sandboxJwt.enabled -}}
{{- fail "gateway.enabled=true requires gateway.sandboxJwt.enabled=true: without the gateway's sandbox-JWT keys a sandbox's supervisor cannot complete its IssueSandboxToken bootstrap, so no sandbox ever becomes ready." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "openshell-driver-kyma.bedrockBridgeGuards" -}}
{{- if .Values.bedrockBridge.enabled -}}
{{- if not .Values.bedrockBridge.sap.serviceKeySecret.name -}}
{{- fail "bedrockBridge.enabled=true requires bedrockBridge.sap.serviceKeySecret.name pointing at a Secret you created with the SAP BTP service-key JSON (e.g. `kubectl create secret generic my-sap-aicore-key --from-file=service-key.json=./sk-openshell.json`)." -}}
{{- end -}}
{{- if and (not .Values.bedrockBridge.modelMap) (not .Values.bedrockBridge.singleDeploymentId) -}}
{{- fail "bedrockBridge.enabled=true requires either bedrockBridge.modelMap (object of bedrock-id -> SAP-deployment-id) OR bedrockBridge.singleDeploymentId. At least one path must be set so the bridge knows where to forward inference traffic." -}}
{{- end -}}
{{- if and (kindIs "map" .Values.bedrockBridge.modelMap) (eq (len .Values.bedrockBridge.modelMap) 0) (not .Values.bedrockBridge.singleDeploymentId) -}}
{{- fail "bedrockBridge.enabled=true with an empty modelMap requires bedrockBridge.singleDeploymentId so every inbound model id resolves to that deployment." -}}
{{- end -}}
{{- if not .Values.gateway.enabled -}}
{{- fail "bedrockBridge.enabled=true requires gateway.enabled=true. The bridge is wired into the chart by pointing inferenceProvider.baseUrl at it, and the provider hook registers that endpoint with the in-pod gateway." -}}
{{- end -}}
{{- end -}}
{{- end -}}
