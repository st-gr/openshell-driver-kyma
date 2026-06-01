{{/* Pre-flight guards for inferenceProvider + gatewayUpstreamEgress.

Mirrors the gateway-apirule.yaml `{{- fail -}}` style: when an opt-in
block is enabled but missing a required field, refuse to render with an
actionable message instead of silently producing broken manifests.

Called via `{{ include "openshell-driver-kyma.inferenceProviderGuards" . }}`
from any template that needs the validation. We invoke it from the
inference-provider-hook.yaml template (Task 5) and gateway-upstream-
egress-related sections of networkpolicy.yaml (Task 6). For now the
guards exist standalone so anyone running `helm lint --strict` with
inferenceProvider.enabled=true gets immediate feedback even before
Tasks 5/6 land. */}}

{{- define "openshell-driver-kyma.inferenceProviderGuards" -}}
{{- if .Values.inferenceProvider.enabled -}}
{{- if not .Values.inferenceProvider.type -}}
{{- fail "inferenceProvider.enabled=true requires inferenceProvider.type (e.g. \"anthropic\")." -}}
{{- end -}}
{{- if not .Values.inferenceProvider.baseUrl -}}
{{- fail "inferenceProvider.enabled=true requires inferenceProvider.baseUrl (e.g. http://gateway.your-llm-ns.svc.cluster.local:8080/anthropic)." -}}
{{- end -}}
{{- if not .Values.inferenceProvider.modelId -}}
{{- fail "inferenceProvider.enabled=true requires inferenceProvider.modelId (e.g. claude-opus-4-7)." -}}
{{- end -}}
{{- if not .Values.inferenceProvider.credentialSecret.name -}}
{{- fail "inferenceProvider.enabled=true requires inferenceProvider.credentialSecret.name pointing at a Secret you manage in .Release.Namespace." -}}
{{- end -}}
{{- if not .Values.inferenceProvider.credentialSecret.key -}}
{{- fail "inferenceProvider.enabled=true requires inferenceProvider.credentialSecret.key (the key inside the Secret holding the API token)." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "openshell-driver-kyma.gatewayUpstreamEgressGuards" -}}
{{- if .Values.gatewayUpstreamEgress.enabled -}}
{{- if not .Values.gatewayUpstreamEgress.namespace -}}
{{- fail "gatewayUpstreamEgress.enabled=true requires gatewayUpstreamEgress.namespace (the namespace where the upstream LLM gateway lives)." -}}
{{- end -}}
{{- if not .Values.gatewayUpstreamEgress.port -}}
{{- fail "gatewayUpstreamEgress.enabled=true requires gatewayUpstreamEgress.port (TCP port the upstream listens on; default 8080)." -}}
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
{{- fail "bedrockBridge.enabled=true requires gateway.enabled=true (the bridge is registered as an aws-bedrock provider on the in-pod gateway)." -}}
{{- end -}}
{{- end -}}
{{- end -}}
