{{/*
The gateway TOML as a dict, rendered by openshell-driver-kyma.gatewayToml
(_toml.tpl), as upstream's chart renders its gatewayConfig. Keys are dotted TOML
table names, values the tables' keys. Returns JSON; gateway-config.yaml checks the
values first.
*/}}
{{- define "openshell-driver-kyma.gatewayConfigDict" -}}
{{- $config := dict -}}
{{- $_ := set $config "openshell" (dict "version" 2) -}}
{{- $gateway := dict "log_level" .Values.driver.logLevel -}}
{{- $rateRequests := int (.Values.gateway.grpcRateLimit.requests | default 0) -}}
{{- $rateWindow := int (.Values.gateway.grpcRateLimit.windowSeconds | default 0) -}}
{{- if gt $rateRequests 0 -}}
{{- $_ := set $gateway "grpc_rate_limit_requests" $rateRequests -}}
{{- $_ := set $gateway "grpc_rate_limit_window_seconds" $rateWindow -}}
{{- end -}}
{{- $_ := set $config "openshell.gateway" $gateway -}}
{{- /* When OIDC is not configured, every gRPC request would otherwise be
rejected with Unauthenticated/missing-authorization-header — including
`openshell sandbox create` from the CLI. Allow unauthenticated user
calls in that case so the chart is usable in-cluster behind a port-
forward or a Service-mesh-controlled APIRule. This setting covers user
calls only; supervisor->gateway calls authenticate separately, via the
driver's AuthenticateSandbox and (when enabled) the sandbox-JWT issuer. */ -}}
{{- $_ := set $config "openshell.gateway.auth" (dict "allow_unauthenticated_users" (not .Values.gateway.oidc.issuer)) -}}
{{- /* The provider credentials' key-encryption key, from the Secret the gateway
container takes this variable from (gateway.credentialStorage). */ -}}
{{- $_ := set $config "openshell.gateway.credential_storage" (dict "key_encryption_key_env" "OPENSHELL_GATEWAY_CREDENTIAL_KEY_ENCRYPTION_KEY") -}}
{{- /* Only when sandboxJwt is enabled: paths to the signing material (mounted
from the JWT Secret) so the gateway can mint per-sandbox JWTs in IssueSandboxToken. */ -}}
{{- if .Values.gateway.sandboxJwt.enabled -}}
{{- $_ := set $config "openshell.gateway.gateway_jwt" (dict
    "signing_key_path" "/etc/openshell-jwt/signing.pem"
    "public_key_path" "/etc/openshell-jwt/public.pem"
    "kid_path" "/etc/openshell-jwt/kid"
    "gateway_id" (include "openshell-driver-kyma.gatewayId" .)
    "ttl_secs" .Values.gateway.sandboxJwt.ttlSecs) -}}
{{- end -}}
{{- /* gateway.ocsfLog: the gateway's OCSF audit events as JSONL. */ -}}
{{- $ocsf := .Values.gateway.ocsfLog -}}
{{- if $ocsf.enabled -}}
{{- $ocsfLog := dict "path" $ocsf.path "rotation" $ocsf.rotation
    "queue_capacity" (int $ocsf.queueCapacity) "queue_max_bytes" (int $ocsf.queueMaxBytes) -}}
{{- if eq $ocsf.rotation "daily" -}}
{{- $_ := set $ocsfLog "max_files" (int $ocsf.maxFiles) -}}
{{- end -}}
{{- with toString $ocsf.schemaVersion -}}
{{- $_ := set $ocsfLog "schema_version" . -}}
{{- end -}}
{{- $_ := set $config "openshell.gateway.ocsf_log" $ocsfLog -}}
{{- end -}}
{{- /* Schema-v2 access path for an external compute driver reached over
--compute-driver-socket. The gateway also derives its resource-admission
policy from this table and requires the driver to acknowledge the same
policy, so both sides render from one value; the driver receives its
side as OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON.
The admission policy and the driver's admission JSON render from one helper
(openshell-driver-kyma.admissionPolicy), so the two sides cannot disagree.
allow_driver_config comes from driver.allowDriverConfig, false by default as in
upstream's chart; resource_admission from driver.resourceAdmission, as upstream
renders it for its own driver. required_labels is a table of its own, so that
check-chart-render.sh's line reader can read it. */ -}}
{{- $policy := include "openshell-driver-kyma.admissionPolicy" . | fromJson -}}
{{- $_ := set $config "openshell.drivers.kyma" (dict "socket_path" .Values.driver.socket "allow_driver_config" $policy.allow_driver_config) -}}
{{- $_ := set $config "openshell.drivers.kyma.resource_admission" (dict "enabled" $policy.resource_admission.enabled) -}}
{{- if hasKey $policy.resource_admission "required_labels" -}}
{{- $_ := set $config "openshell.drivers.kyma.resource_admission.required_labels" $policy.resource_admission.required_labels -}}
{{- end -}}
{{- $config | toJson -}}
{{- end -}}
