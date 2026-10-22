{{/*
The gateway TOML as a dict, rendered by openshell-driver-kyma.gatewayToml
(_toml.tpl), as upstream's chart renders its gatewayConfig. Keys are dotted TOML
table names, values the tables' keys. Returns JSON; gateway-config.yaml checks the
values first.

The dict starts from gatewayConfig (upstream's passthrough), its nested maps
normalised to dotted tables, so that a user table and the chart's table of the
same name render once. Chart values then fill only the keys the user left out
(tomlDefault), or set keys the chart owns (tomlOwned). The tables and keys the
chart owns through flags or the driver's environment are refused outright: the
gateway would silently override them, or the driver would never see them.
*/}}

{{/* tomlDefault (dict "config" $c "table" "openshell.gateway" "key" "name" "value" $v):
set table.key to value only when gatewayConfig left it out. */}}
{{- define "openshell-driver-kyma.tomlDefault" -}}
{{- $table := get .config .table | default dict -}}
{{- if not (hasKey $table .key) -}}
{{- $_ := set $table .key .value -}}
{{- end -}}
{{- $_ := set .config .table $table -}}
{{- end -}}

{{/* tomlOwned (dict "config" $c "table" "openshell.gateway" "key" "name" "value" $v
"valuePath" "gateway.x"): set table.key to value; gatewayConfig may repeat the
same value but not set another. valuePath names the chart value to use instead. */}}
{{- define "openshell-driver-kyma.tomlOwned" -}}
{{- $table := get .config .table | default dict -}}
{{- if and (hasKey $table .key) (ne (toJson (get $table .key)) (toJson .value)) -}}
{{- fail (printf "gatewayConfig must not set %s.%s; it is chart-owned (use %s instead)" .table .key .valuePath) -}}
{{- end -}}
{{- $_ := set $table .key .value -}}
{{- $_ := set .config .table $table -}}
{{- end -}}

{{/* tomlFlatten (dict "out" $out "user" $gatewayConfig "name" $tableName "table" $map):
write the table and every nested map in it to $out as dotted tables. A nested map
whose dotted name gatewayConfig also defines fails with upstream's message (its
_toml.tpl renders such a map inline, so it checks the same conflict before
serializing). A key containing a dot stays an inline table: as a table name it
would split into the wrong path. */}}
{{- define "openshell-driver-kyma.tomlFlatten" -}}
{{- $fields := dict -}}
{{- $hasNested := false -}}
{{- range $key, $value := .table -}}
{{- if and (kindIs "map" $value) (not (contains "." $key)) -}}
{{- $nested := printf "%s.%s" $.name $key -}}
{{- if hasKey $.user $nested -}}
{{- fail (printf "gatewayConfig defines %q both as a nested map and a dotted top-level table; use only the dotted top-level key" $nested) -}}
{{- end -}}
{{- $hasNested = true -}}
{{- include "openshell-driver-kyma.tomlFlatten" (dict "out" $.out "user" $.user "name" $nested "table" $value) -}}
{{- else -}}
{{- $_ := set $fields $key $value -}}
{{- end -}}
{{- end -}}
{{- if or $fields (not $hasNested) -}}
{{- $_ := set .out .name $fields -}}
{{- end -}}
{{- end -}}

{{- define "openshell-driver-kyma.gatewayConfigDict" -}}
{{- $user := .Values.gatewayConfig | default dict | deepCopy -}}
{{- $config := dict -}}
{{- range $name, $table := $user -}}
{{- if kindIs "map" $table -}}
{{- include "openshell-driver-kyma.tomlFlatten" (dict "out" $config "user" $user "name" $name "table" $table) -}}
{{- else -}}
{{- /* Arrays of tables, and anything else _toml.tpl refuses with its own message. */ -}}
{{- $_ := set $config $name $table -}}
{{- end -}}
{{- end -}}
{{- /* Chart-owned tables: the driver's socket and admission policy (the driver must
acknowledge the same policy), upstream's own driver (this chart's driver reads its
environment, so a table would do nothing), and the TLS paths the gateway takes as flags. */ -}}
{{- $ownedTables := dict
    "openshell.drivers.kyma" "it is chart-owned (use driver.socket, driver.allowDriverConfig and driver.resourceAdmission instead)"
    "openshell.drivers.kubernetes" "this chart's driver is configured by environment (driver.* values)"
    "openshell.gateway.tls" "it is chart-owned (use gateway.tls.* instead)" -}}
{{- range $name := keys $config | sortAlpha -}}
{{- range $owned := keys $ownedTables | sortAlpha -}}
{{- if or (eq $name $owned) (hasPrefix (printf "%s." $owned) $name) -}}
{{- fail (printf "gatewayConfig must not set %s; %s" $owned (get $ownedTables $owned)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- /* Chart-owned keys the gateway takes as flags (a flag wins over the TOML, so the
key would silently do nothing). database_url is refused by _toml.tpl in every table. */ -}}
{{- $ownedKeys := dict
    "openshell.gateway" (dict
      "bind_address" "gateway.grpcPort"
      "health_bind_address" "gateway.healthPort"
      "metrics_bind_address" "gateway.metricsPort"
      "compute_driver" "driver.* values"
      "server_sans" "gateway.sandboxJwt.serverDnsNames")
    "openshell.gateway.oidc" (dict
      "issuer" "gateway.oidc.issuer"
      "audience" "gateway.oidc.audience"
      "roles_claim" "gateway.oidc.rolesClaim"
      "admin_role" "gateway.oidc.adminRole"
      "user_role" "gateway.oidc.userRole"
      "jwks_ttl_secs" "gateway.oidc.jwksTtl"
      "scopes_claim" "gateway.oidc.scopesClaim"
      "jwks_allowed_origins" "gateway.oidc.jwksAllowedOrigins"
      "dangerously_allow_insecure_http" "gateway.oidc.dangerouslyAllowInsecureHttp") -}}
{{- range $tableName := keys $ownedKeys | sortAlpha -}}
{{- $table := get $config $tableName -}}
{{- if kindIs "map" $table -}}
{{- $owned := get $ownedKeys $tableName -}}
{{- range $key := keys $owned | sortAlpha -}}
{{- if hasKey $table $key -}}
{{- fail (printf "gatewayConfig must not set %s.%s; it is chart-owned (use %s instead)" $tableName $key (get $owned $key)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell" "key" "version" "value" 2) -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway" "key" "log_level" "value" .Values.driver.logLevel) -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway" "key" "name" "value" (include "openshell-driver-kyma.gatewayName" .)) -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway" "key" "policy_validation_failure_mode" "value" .Values.gateway.policyValidationFailureMode) -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway" "key" "enable_loopback_service_http" "value" .Values.gateway.enableLoopbackServiceHttp) -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway" "key" "enable_websocket_tunnel" "value" .Values.gateway.enableWebsocketTunnel) -}}
{{- $rateRequests := int (.Values.gateway.grpcRateLimit.requests | default 0) -}}
{{- $rateWindow := int (.Values.gateway.grpcRateLimit.windowSeconds | default 0) -}}
{{- if gt $rateRequests 0 -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway" "key" "grpc_rate_limit_requests" "value" $rateRequests) -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway" "key" "grpc_rate_limit_window_seconds" "value" $rateWindow) -}}
{{- end -}}
{{- /* Who may call as a user. Computed (gateway.auth.allowUnauthenticatedUsers
null): true only when nothing authenticates callers, that is with neither an OIDC
issuer nor an effective client CA (TLS on and gateway.tls.clientCa.enabled, which
is when the chart passes --tls-client-ca). Without it every gRPC request would be rejected with
Unauthenticated/missing-authorization-header, `openshell sandbox create` from the
CLI included. With a client CA and no issuer the gateway enables mTLS user
authentication itself (upstream v0.1.4), so false makes it require the certificate.
This setting covers user calls only; supervisor->gateway calls authenticate
separately, via the driver's AuthenticateSandbox and (when enabled) the
sandbox-JWT issuer. */ -}}
{{- $fromConfig := hasKey (get $config "openshell.gateway.auth" | default dict) "allow_unauthenticated_users" -}}
{{- $allowUnauth := .Values.gateway.auth.allowUnauthenticatedUsers -}}
{{- if kindIs "invalid" $allowUnauth -}}
{{- $allowUnauth = and (not .Values.gateway.oidc.issuer) (not (and .Values.gateway.tls.enabled .Values.gateway.tls.clientCa.enabled)) -}}
{{- else if not (kindIs "bool" $allowUnauth) -}}
{{- fail (printf "gateway.auth.allowUnauthenticatedUsers must be a boolean (true or false) or null, got the %s %q." (kindOf $allowUnauth) (toString $allowUnauth)) -}}
{{- end -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway.auth" "key" "allow_unauthenticated_users" "value" $allowUnauth) -}}
{{- include "openshell-driver-kyma.mtlsAuthGuard" (dict "config" $config "root" . "fromConfig" $fromConfig) -}}
{{- /* The provider credentials' key-encryption key, from the Secret the gateway
container takes this variable from (gateway.credentialStorage). */ -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway.credential_storage" "key" "key_encryption_key_env" "value" "OPENSHELL_GATEWAY_CREDENTIAL_KEY_ENCRYPTION_KEY") -}}
{{- /* Only when sandboxJwt is enabled: paths to the signing material (mounted
from the JWT Secret) so the gateway can mint per-sandbox JWTs in IssueSandboxToken. */ -}}
{{- if .Values.gateway.sandboxJwt.enabled -}}
{{- range $key, $value := dict
    "signing_key_path" "/etc/openshell-jwt/signing.pem"
    "public_key_path" "/etc/openshell-jwt/public.pem"
    "kid_path" "/etc/openshell-jwt/kid"
    "gateway_id" (include "openshell-driver-kyma.gatewayId" .)
    "ttl_secs" .Values.gateway.sandboxJwt.ttlSecs -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway.gateway_jwt" "key" $key "value" $value) -}}
{{- end -}}
{{- end -}}
{{- /* gateway.otlp: the gateway's OTLP trace export; no table without an endpoint. */ -}}
{{- with .Values.gateway.otlp.endpoint -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway.otlp" "key" "endpoint" "value" .) -}}
{{- with $.Values.gateway.otlp.serviceName -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway.otlp" "key" "service_name" "value" .) -}}
{{- end -}}
{{- end -}}
{{- /* gateway.ocsfLog: the gateway's OCSF audit events as JSONL. */ -}}
{{- $ocsf := .Values.gateway.ocsfLog -}}
{{- if $ocsf.enabled -}}
{{- range $key, $value := dict "path" $ocsf.path "rotation" $ocsf.rotation
    "queue_capacity" (int $ocsf.queueCapacity) "queue_max_bytes" (int $ocsf.queueMaxBytes) -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway.ocsf_log" "key" $key "value" $value) -}}
{{- end -}}
{{- if eq (get (get $config "openshell.gateway.ocsf_log") "rotation") "daily" -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway.ocsf_log" "key" "max_files" "value" (int $ocsf.maxFiles)) -}}
{{- end -}}
{{- with toString $ocsf.schemaVersion -}}
{{- include "openshell-driver-kyma.tomlDefault" (dict "config" $config "table" "openshell.gateway.ocsf_log" "key" "schema_version" "value" .) -}}
{{- end -}}
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
