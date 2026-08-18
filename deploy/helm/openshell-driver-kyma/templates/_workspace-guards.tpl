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
{{- $gid := default .Values.gateway.sandboxJwt.gatewayId .Values.driver.gatewayId -}}
{{- if not $gid -}}
{{- fail "driver.workspaceMode=managed requires driver.gatewayId (or gateway.sandboxJwt.gatewayId). It becomes part of every managed namespace name." -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $gid) -}}
{{- fail (printf "driver.gatewayId %q is not a DNS-1123 label; it becomes part of every managed namespace name." $gid) -}}
{{- end -}}
{{- if .Values.driver.enableNetworkPolicy -}}
{{- fail "driver.workspaceMode=managed requires driver.enableNetworkPolicy=false. The driver itself already refuses to start on this combination (main.rs, see provisioner.rs::bootstrap_managed_namespace's doc comment for why) because the chart's sandbox NetworkPolicy depends on Helm-only inputs a managed namespace never gets; this guard turns that into an immediate install-time error instead of a pod crash-loop." -}}
{{- end -}}
{{- end -}}
{{- if and (eq $mode "operator") (not .Values.driver.operatorNamespaceAllowlist) -}}
{{- fail "driver.workspaceMode=operator requires a non-empty driver.operatorNamespaceAllowlist. An empty allowlist denies every workspace." -}}
{{- end -}}
{{- end -}}
