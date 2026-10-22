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

{{/*
Refuses allow_unauthenticated_users = true next to a client CA: it would admit
callers without a client certificate. Takes a dict with `config` (the gateway TOML
dict, gatewayConfig merged and the chart's value applied), `root`, and `fromConfig`
(true when gatewayConfig set the key), which picks the subject of the message.
*/}}
{{- define "openshell-driver-kyma.mtlsAuthGuard" -}}
{{- if .root.Values.gateway.tls.clientCa.enabled -}}
{{- $auth := get .config "openshell.gateway.auth" | default dict -}}
{{- if eq (toJson (get $auth "allow_unauthenticated_users")) "true" -}}
{{- $subject := ternary "gatewayConfig openshell.gateway.auth.allow_unauthenticated_users=true" "gateway.auth.allowUnauthenticatedUsers=true" .fromConfig -}}
{{- fail (printf "%s would admit callers without a client certificate; remove it to require the certificate" $subject) -}}
{{- end -}}
{{- end -}}
{{- end -}}
