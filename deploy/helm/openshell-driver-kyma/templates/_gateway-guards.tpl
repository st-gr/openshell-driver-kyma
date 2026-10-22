{{/*
Refuses a gateway.extraArgs entry that sets a flag the chart owns through a
value: the flag would reach the gateway twice, and which one wins is the
gateway's affair. Takes a dict with `flags` (flag -> the value name to use
instead) and `args` (gateway.extraArgs). An entry matches when it equals the
flag or starts with `<flag>=`. Later tasks register their flags in the dict
of openshell-driver-kyma.gatewayArgGuards.
*/}}
{{- define "openshell-driver-kyma.extraArgsGuard" -}}
{{- range $flag, $value := .flags -}}
{{- range $arg := $.args -}}
{{- $a := toString $arg -}}
{{- if or (eq $a $flag) (hasPrefix (printf "%s=" $flag) $a) -}}
{{- fail (printf "gateway.extraArgs sets %s; use %s instead" $flag $value) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* The flags the chart sets from values, and the value that sets each. */}}
{{- define "openshell-driver-kyma.gatewayArgGuards" -}}
{{- if .Values.gateway.enabled -}}
{{- include "openshell-driver-kyma.extraArgsGuard" (dict "args" .Values.gateway.extraArgs "flags" (dict
  "--oidc-jwks-ttl" "gateway.oidc.jwksTtl"
  "--oidc-scopes-claim" "gateway.oidc.scopesClaim"
  "--oidc-jwks-allowed-origins" "gateway.oidc.jwksAllowedOrigins"
  "--oidc-dangerously-allow-insecure-http" "gateway.oidc.dangerouslyAllowInsecureHttp")) -}}
{{- end -}}
{{- end -}}
