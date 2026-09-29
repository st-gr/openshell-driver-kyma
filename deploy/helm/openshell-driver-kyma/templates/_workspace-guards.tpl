{{/* Pre-flight guards for driver.workspaceMode.

Mirrors the `{{- fail -}}` style of _inference-provider-guards.tpl: refuse
to render broken manifests instead of producing a Deployment that will
crash-loop once the driver starts.

Called via `{{ include "openshell-driver-kyma.workspaceGuards" . }}` from
deployment.yaml. */}}

{{- define "openshell-driver-kyma.workspaceGuards" -}}
{{- $mode := .Values.driver.workspaceMode -}}
{{- if not (has $mode (list "shared" "managed" "operator")) -}}
{{- fail (printf "driver.workspaceMode must be one of shared|managed|operator, got %q." $mode) -}}
{{- end -}}
{{- if eq $mode "managed" -}}
{{- $gid := include "openshell-driver-kyma.gatewayId" . -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $gid) -}}
{{- fail (printf "gateway.sandboxJwt.gatewayId %q (default: the release's fullname) is not a DNS-1123 label; it becomes part of every managed namespace name." $gid) -}}
{{- end -}}
{{- end -}}
{{- if and (eq $mode "operator") (not .Values.driver.operatorNamespaceLabel) (not .Values.driver.operatorNamespaceConfigMap.name) -}}
{{- fail "driver.workspaceMode=operator requires driver.operatorNamespaceLabel or driver.operatorNamespaceConfigMap.name, which select the namespaces upstream's driver may use." -}}
{{- end -}}
{{- end -}}
