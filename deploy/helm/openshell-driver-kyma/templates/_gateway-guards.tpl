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
{{- $sans := ternary "gateway.certManager.serverDnsNames" "gateway.sandboxJwt.serverDnsNames" (eq (toJson .Values.gateway.certManager.enabled) "true") -}}
{{- include "openshell-driver-kyma.extraArgsGuard" (dict "args" .Values.gateway.extraArgs "flags" (dict
  "--config" "gatewayConfig"
  "--bind-address" "gateway.grpcPort (the chart binds all addresses)"
  "--port" "gateway.grpcPort"
  "--health-port" "gateway.healthPort"
  "--metrics-port" "gateway.metricsPort"
  "--compute-driver" "driver.socket (the chart runs the kyma driver)"
  "--compute-driver-socket" "driver.socket"
  "--oidc-issuer" "gateway.oidc.issuer"
  "--oidc-audience" "gateway.oidc.audience"
  "--oidc-roles-claim" "gateway.oidc.rolesClaim"
  "--oidc-admin-role" "gateway.oidc.adminRole"
  "--oidc-user-role" "gateway.oidc.userRole"
  "--db-url" "gateway.dbPersistence.enabled=true with dbUrl, or externalDbSecret"
  "--tls-cert" "gateway.tls.enabled"
  "--tls-key" "gateway.tls.enabled"
  "--disable-tls" "gateway.tls.enabled"
  "--tls-client-ca" "gateway.tls.clientCa"
  "--server-san" $sans
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
{{- if and .root.Values.gateway.tls.enabled .root.Values.gateway.tls.clientCa.enabled -}}
{{- $auth := get .config "openshell.gateway.auth" | default dict -}}
{{- if eq (toJson (get $auth "allow_unauthenticated_users")) "true" -}}
{{- $subject := ternary "gatewayConfig openshell.gateway.auth.allow_unauthenticated_users=true" "gateway.auth.allowUnauthenticatedUsers=true" .fromConfig -}}
{{- fail (printf "%s would admit callers without a client certificate; remove it to require the certificate" $subject) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Refuses publishing a gateway that admits unauthenticated callers. Published means
gatewayIngress.enabled or a gatewayService.type other than ClusterIP. A published
Service also needs an OIDC issuer or an effective client CA: no ingress fences it.
Takes a dict with `config` (the gateway TOML dict, gatewayConfig merged and the
chart's value applied) and `root`. A ClusterIP-only gateway (local development)
may stay unauthenticated.
*/}}
{{- define "openshell-driver-kyma.publishAuthGuard" -}}
{{- $v := .root.Values -}}
{{- $type := toString $v.gatewayService.type -}}
{{- $published := "" -}}
{{- if $v.gatewayIngress.enabled -}}
{{- $published = "gatewayIngress.enabled" -}}
{{- else if and $type (ne $type "ClusterIP") -}}
{{- $published = printf "gatewayService.type=%s" $type -}}
{{- end -}}
{{- if $published -}}
{{- if and $type (ne $type "ClusterIP") (not $v.gateway.oidc.issuer) (not (and $v.gateway.tls.enabled $v.gateway.tls.clientCa.enabled)) -}}
{{- fail (printf "gatewayService.type=%s publishes the gateway; set gateway.oidc.issuer or enable gateway.tls with gateway.tls.clientCa.enabled" $type) -}}
{{- end -}}
{{- $auth := get .config "openshell.gateway.auth" | default dict -}}
{{- if eq (toJson (get $auth "allow_unauthenticated_users")) "true" -}}
{{- fail (printf "REFUSING to publish an unauthenticated gateway: allow_unauthenticated_users is true while %s publishes it" $published) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Where the gateway's database lives: "secret" (URL from gateway.dbPersistence.externalDbSecret,
which implies persistence), "url" (dbUrl in the args), "sqlite" (PVC-backed) or "" (ephemeral).
Refuses a Secret next to dbUrl and an invalid Secret name; the name check mirrors upstream's
validateSecretReference (a DNS-1123 subdomain of at most 253 characters).
*/}}
{{- define "openshell-driver-kyma.gatewayDbMode" -}}
{{- $db := .Values.gateway.dbPersistence -}}
{{- if $db.externalDbSecret -}}
{{- $name := toString $db.externalDbSecret -}}
{{- if $db.dbUrl -}}
{{- fail "gateway.dbPersistence.externalDbSecret and gateway.dbPersistence.dbUrl are mutually exclusive" -}}
{{- end -}}
{{- if gt (len $name) 253 -}}
{{- fail "gateway.dbPersistence.externalDbSecret must be no more than 253 characters" -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$" $name) -}}
{{- fail "gateway.dbPersistence.externalDbSecret must be a valid Kubernetes Secret name" -}}
{{- end -}}
secret
{{- else if and $db.dbUrl (not $db.enabled) -}}
{{- fail "gateway.dbPersistence.dbUrl requires gateway.dbPersistence.enabled=true (or use gateway.dbPersistence.externalDbSecret)" -}}
{{- else if and $db.enabled $db.dbUrl -}}
url
{{- else if $db.enabled -}}
sqlite
{{- end -}}
{{- end -}}

{{/*
Refuses a Vault timeoutSecs that is not a positive integer, and an address that is missing, or plain HTTP to a non-loopback host.
Refuses a Kubernetes Secrets credential driver namespace that is the sandbox
namespace (the driver keeps sandbox bootstrap Secrets there, and the Role would hand
the gateway all of them), and createNamespace for the release namespace (upstream's
message, our keys).
*/}}
{{- define "openshell-driver-kyma.credentialDriverGuards" -}}
{{- if and .Values.gateway.enabled (eq (include "openshell-driver-kyma.credentialDriver" .) "kubernetes-secrets") -}}
{{- $namespace := include "openshell-driver-kyma.credentialSecretsNamespace" . -}}
{{- if not (and (le (len $namespace) 63) (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $namespace)) -}}
{{- fail (printf "gateway.credentialDrivers.kubernetesSecrets.namespace must be a valid namespace name (a DNS-1123 label of at most 63 characters), got %q" $namespace) -}}
{{- end -}}
{{- if eq $namespace (include "openshell-driver-kyma.sandboxNamespace" .) -}}
{{- fail (printf "gateway.credentialDrivers.kubernetesSecrets.namespace must not be the sandbox namespace %q, where the driver keeps sandbox bootstrap Secrets; name a dedicated namespace (empty means the release namespace)" $namespace) -}}
{{- end -}}
{{- if and .Values.gateway.credentialDrivers.kubernetesSecrets.createNamespace (eq $namespace .Release.Namespace) -}}
{{- fail "gateway.credentialDrivers.kubernetesSecrets.createNamespace requires gateway.credentialDrivers.kubernetesSecrets.namespace to name a namespace other than the release namespace" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.gateway.enabled .Values.gateway.providerTokenGrants.spiffe.enabled (not (hasPrefix "/" (toString .Values.gateway.providerTokenGrants.spiffe.workloadApiSocketPath))) -}}
{{- fail "gateway.providerTokenGrants.spiffe.workloadApiSocketPath must be an absolute path" -}}
{{- end -}}
{{- /* Empty (the driver's default) or a positive integer, as a number or a numeric string; upstream's driver refuses anything else when the gateway starts. */ -}}
{{- $timeout := .Values.gateway.credentialDrivers.vault.timeoutSecs -}}
{{- if and .Values.gateway.enabled (not (kindIs "invalid" $timeout)) (ne (toString $timeout) "") (not (regexMatch "^[1-9][0-9]*$" (toString $timeout))) -}}
{{- fail "gateway.credentialDrivers.vault.timeoutSecs must be a positive integer" -}}
{{- end -}}
{{- if and .Values.gateway.enabled (eq (include "openshell-driver-kyma.credentialDriver" .) "vault") -}}
{{- /* Upstream's Vault driver checks the same at start-up; here the release fails instead. */ -}}
{{- $address := include "openshell-driver-kyma.vaultAddress" . | trim -}}
{{- if not $address -}}
{{- fail "gateway.credentialDrivers.vault.address is required when the Vault credential driver is selected" -}}
{{- end -}}
{{- $url := urlParse $address -}}
{{- if and (eq $url.scheme "http") (not (include "openshell-driver-kyma.hostIsLoopback" $url.host)) -}}
{{- fail "gateway.credentialDrivers.vault.address must use HTTPS for non-loopback endpoints" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
gateway.certManager: cert-manager (or Gardener) issues the gateway's certificates.
Refuses it without gateway.tls.enabled, an unknown api, durations that are not Go
durations in h/m/s, a CA that would not outlive a leaf (Gardener refuses such a leaf,
cert-manager cuts it short), the PKI hook's extra names (gateway.certManager has its
own), and a client CA source that is not unambiguous: clientCaFromServerTlsSecret=true
takes the server Secret's ca.crt, false takes gateway.tls.clientCa.secretName.
*/}}
{{- define "openshell-driver-kyma.certManagerGuards" -}}
{{- $cm := .Values.gateway.certManager -}}
{{- range $key, $v := dict "gateway.certManager.enabled" $cm.enabled "gateway.certManager.clientCaFromServerTlsSecret" $cm.clientCaFromServerTlsSecret "gateway.sandboxJwt.failOnTimeout" .Values.gateway.sandboxJwt.failOnTimeout -}}
{{- if not (kindIs "bool" $v) -}}
{{- fail (printf "%s must be a boolean (true or false), got the %s %q." $key (kindOf $v) (toString $v)) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.gateway.enabled $cm.enabled -}}
{{- if not .Values.gateway.tls.enabled -}}
{{- fail "gateway.certManager.enabled requires gateway.tls.enabled: the certificates it issues are the gateway's TLS certificates." -}}
{{- end -}}
{{- if not (has (toString $cm.api) (list "cert-manager.io" "cert.gardener.cloud")) -}}
{{- fail (printf "gateway.certManager.api must be cert-manager.io or cert.gardener.cloud, got %q." (toString $cm.api)) -}}
{{- end -}}
{{- $ca := include "openshell-driver-kyma.durationSeconds" (dict "key" "gateway.certManager.caDuration" "value" $cm.caDuration "example" "87600h") | int64 -}}
{{- $leaf := include "openshell-driver-kyma.durationSeconds" (dict "key" "gateway.certManager.certificateDuration" "value" $cm.certificateDuration "example" "8760h") | int64 -}}
{{- $renew := include "openshell-driver-kyma.durationSeconds" (dict "key" "gateway.certManager.certificateRenewBefore" "value" $cm.certificateRenewBefore "example" "720h") | int64 -}}
{{- if lt $leaf (mul 2 $renew) -}}
{{- fail (printf "gateway.certManager.certificateDuration (%s) must be at least twice certificateRenewBefore (%s): the chart requires this for both cert-manager.io and cert.gardener.cloud." (toString $cm.certificateDuration) (toString $cm.certificateRenewBefore)) -}}
{{- end -}}
{{- if le $ca (add $leaf $renew) -}}
{{- fail (printf "gateway.certManager.caDuration (%s) must exceed certificateDuration + certificateRenewBefore (%s): Gardener refuses a certificate that outlives its CA, and cert-manager cuts it short." (toString $cm.caDuration) (include "openshell-driver-kyma.formatDuration" (add $leaf $renew))) -}}
{{- end -}}
{{- if not (regexMatch "^[1-9][0-9]*$" (toString .Values.gateway.sandboxJwt.timeoutSeconds)) -}}
{{- fail "gateway.sandboxJwt.timeoutSeconds must be a positive integer" -}}
{{- end -}}
{{- if or .Values.gateway.sandboxJwt.serverDnsNames .Values.gateway.sandboxJwt.serverIpAddresses -}}
{{- fail "gateway.sandboxJwt.serverDnsNames and serverIpAddresses name the PKI hook certificate, which gateway.certManager replaces: move them to gateway.certManager.serverDnsNames and serverIpAddresses." -}}
{{- end -}}
{{- if and .Values.gateway.tls.enabled .Values.gateway.tls.clientCa.enabled -}}
{{- if and $cm.clientCaFromServerTlsSecret .Values.gateway.tls.clientCa.secretName -}}
{{- fail "gateway.tls.clientCa.secretName is set but gateway.certManager.clientCaFromServerTlsSecret is true, which takes the client CA from the server TLS Secret. Set gateway.certManager.clientCaFromServerTlsSecret=false to verify client certificates against the Secret, or leave gateway.tls.clientCa.secretName empty." -}}
{{- end -}}
{{- if and (not $cm.clientCaFromServerTlsSecret) (not .Values.gateway.tls.clientCa.secretName) -}}
{{- fail (printf "gateway.certManager.clientCaFromServerTlsSecret is false but gateway.tls.clientCa.secretName is empty, and nothing else provides a client CA when cert-manager owns TLS. Set gateway.tls.clientCa.secretName to the secret containing the client CA (e.g. the value of gateway.certManager.caSecretName, here %s), or set gateway.tls.clientCa.enabled=false to disable mTLS client verification." (include "openshell-driver-kyma.caSecretName" .)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
