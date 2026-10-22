{{/*
Expand the name of the chart.
*/}}
{{- define "openshell-driver-kyma.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "openshell-driver-kyma.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "openshell-driver-kyma.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "openshell-driver-kyma.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: driver
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "openshell-driver-kyma.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openshell-driver-kyma.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name.
*/}}
{{- define "openshell-driver-kyma.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "openshell-driver-kyma.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference.

If `image.tag` begins with `sha256:`, emit `<repo>@<digest>` (the OCI
canonical digest-pin form). Otherwise emit `<repo>:<tag>`. This lets
operators pin by digest in production with a one-line value:

  image:
    tag: sha256:abc123…
*/}}
{{- define "openshell-driver-kyma.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if hasPrefix "sha256:" $tag -}}
{{- printf "%s@%s" .Values.image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end }}

{{/*
Gateway image reference. Same digest-pin convention as the driver image.
*/}}
{{- define "openshell-driver-kyma.gatewayImage" -}}
{{- $tag := .Values.gateway.image.tag -}}
{{- if hasPrefix "sha256:" $tag -}}
{{- printf "%s@%s" .Values.gateway.image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.gateway.image.repository $tag -}}
{{- end -}}
{{- end }}

{{/*
Bedrock-bridge image reference. Same digest-pin convention as the driver image.
*/}}
{{- define "openshell-driver-kyma.bedrockBridgeImage" -}}
{{- $tag := default .Chart.AppVersion .Values.bedrockBridge.image.tag -}}
{{- if hasPrefix "sha256:" $tag -}}
{{- printf "%s@%s" .Values.bedrockBridge.image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.bedrockBridge.image.repository $tag -}}
{{- end -}}
{{- end }}

{{/*
Bedrock-bridge fullname (Deployment + Service share this).
*/}}
{{- define "openshell-driver-kyma.bedrockBridgeFullname" -}}
{{- printf "%s-bedrock-bridge" (include "openshell-driver-kyma.fullname" .) -}}
{{- end }}

{{/*
JWT signing-key Secret name. Defaults to <fullname>-jwt-keys.
Used by both the certgen pre-install hook (to create the Secret) and the
gateway container (to mount it at /etc/openshell-jwt).
*/}}
{{- define "openshell-driver-kyma.jwtSecretName" -}}
{{- default (printf "%s-jwt-keys" (include "openshell-driver-kyma.fullname" .)) .Values.gateway.sandboxJwt.jwtSecretName }}
{{- end }}

{{/*
Secret holding the gateway's credential storage key-encryption key (upstream's
server.credentialStorage): gateway.credentialStorage.existingSecret when set, else the
chart-generated Secret. Its key, and the gateway environment variable the TOML names,
are upstream's.
*/}}
{{- define "openshell-driver-kyma.kekSecretName" -}}
{{- $existing := .Values.gateway.credentialStorage.existingSecret -}}
{{- if and (ne $existing nil) (ne $existing "") -}}
{{- if not (kindIs "string" $existing) -}}
{{- fail (printf "gateway.credentialStorage.existingSecret must be a Kubernetes Secret name, got %s" (kindOf $existing)) -}}
{{- end -}}
{{- if gt (len $existing) 253 -}}
{{- fail "gateway.credentialStorage.existingSecret must be no more than 253 characters" -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$" $existing) -}}
{{- fail "gateway.credentialStorage.existingSecret must be a valid Kubernetes Secret name" -}}
{{- end -}}
{{- $existing -}}
{{- else -}}
{{- printf "%s-credential-storage-key-encryption-key" (include "openshell-driver-kyma.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
One table of gatewayConfig, as JSON, its nested maps normalised to dotted tables as
the gateway TOML renders them: (list $root "openshell.gateway").
*/}}
{{- define "openshell-driver-kyma.userGatewayTable" -}}
{{- $root := index . 0 -}}
{{- $user := $root.Values.gatewayConfig | default dict | deepCopy -}}
{{- $flat := dict -}}
{{- range $name, $table := $user -}}
{{- if kindIs "map" $table -}}
{{- include "openshell-driver-kyma.tomlFlatten" (dict "out" $flat "user" $user "name" $name "table" $table) -}}
{{- end -}}
{{- end -}}
{{- get $flat (index . 1) | default dict | toJson -}}
{{- end }}

{{/*
The external credential driver the gateway uses: "" (the default store, encrypted in
the gateway DB with the credentialStorage KEK), "kubernetes-secrets" or "vault".
gatewayConfig's openshell.gateway.credential_drivers wins over the values, as in
upstream's chart, and may name one backend only.
*/}}
{{- define "openshell-driver-kyma.credentialDriver" -}}
{{- $gateway := include "openshell-driver-kyma.userGatewayTable" (list . "openshell.gateway") | fromJson -}}
{{- $drivers := get $gateway "credential_drivers" -}}
{{- if and .Values.gateway.credentialDrivers.kubernetesSecrets.enabled .Values.gateway.credentialDrivers.vault.enabled -}}
{{- fail "only one external gateway.credentialDrivers backend can be enabled at a time" -}}
{{- end -}}
{{- if and (hasKey $gateway "credential_drivers") (ne $drivers nil) -}}
{{- if not (kindIs "slice" $drivers) -}}
{{- fail (printf "gatewayConfig.openshell.gateway.credential_drivers must be a list, got %s" (kindOf $drivers)) -}}
{{- end -}}
{{- if eq (len $drivers) 0 -}}
{{- fail "gatewayConfig.openshell.gateway.credential_drivers must select exactly one backend or be omitted/null to use the chart default" -}}
{{- end -}}
{{- if gt (len $drivers) 1 -}}
{{- fail "gatewayConfig.openshell.gateway.credential_drivers may select only one backend" -}}
{{- end -}}
{{- index $drivers 0 | toString -}}
{{- else if .Values.gateway.credentialDrivers.kubernetesSecrets.enabled -}}
kubernetes-secrets
{{- else if .Values.gateway.credentialDrivers.vault.enabled -}}
vault
{{- end -}}
{{- end }}

{{/*
The Vault driver's address: gatewayConfig's openshell.credential_drivers.vault
address, else gateway.credentialDrivers.vault.address; empty when Vault is not the
selected credential driver.
*/}}
{{- define "openshell-driver-kyma.vaultAddress" -}}
{{- if eq (include "openshell-driver-kyma.credentialDriver" .) "vault" -}}
{{- $config := include "openshell-driver-kyma.userGatewayTable" (list . "openshell.credential_drivers.vault") | fromJson -}}
{{- get $config "address" | default .Values.gateway.credentialDrivers.vault.address -}}
{{- end -}}
{{- end }}

{{/*
The SPIFFE Workload API socket path of the gateway, when
gateway.providerTokenGrants.spiffe is enabled; empty otherwise.
*/}}
{{- define "openshell-driver-kyma.gatewaySpiffeSocket" -}}
{{- if .Values.gateway.providerTokenGrants.spiffe.enabled -}}
{{- .Values.gateway.providerTokenGrants.spiffe.workloadApiSocketPath -}}
{{- end -}}
{{- end }}

{{/*
The ConfigMap holding the private Vault CA, when Vault is the selected credential
driver.
*/}}
{{- define "openshell-driver-kyma.vaultCaConfigMapName" -}}
{{- if eq (include "openshell-driver-kyma.credentialDriver" .) "vault" -}}
{{- .Values.gateway.credentialDrivers.vault.caConfigMapName -}}
{{- end -}}
{{- end }}

{{/*
Whether a URL host is loopback, as upstream's Vault driver decides it
(vault_host_is_loopback): localhost, or an IPv4 address in 127.0.0.0/8, or ::1. The
host is the URL's, with any port and IPv6 brackets: (include ... $host) prints
"true" or nothing.
*/}}
{{- define "openshell-driver-kyma.hostIsLoopback" -}}
{{- $host := lower (regexReplaceAll ":[0-9]+$" . "") -}}
{{- if or (eq $host "localhost") (eq $host "[::1]") (regexMatch "^127(\\.[0-9]{1,3}){3}$" $host) -}}
true
{{- end -}}
{{- end }}

{{/*
Namespace of the Kubernetes Secrets credential driver: gatewayConfig's
openshell.credential_drivers.kubernetes-secrets namespace, else
gateway.credentialDrivers.kubernetesSecrets.namespace, else the release namespace.
*/}}
{{- define "openshell-driver-kyma.credentialSecretsNamespace" -}}
{{- $config := include "openshell-driver-kyma.userGatewayTable" (list . "openshell.credential_drivers.kubernetes-secrets") | fromJson -}}
{{- get $config "namespace" | default .Values.gateway.credentialDrivers.kubernetesSecrets.namespace | default .Release.Namespace -}}
{{- end }}

{{/*
Server TLS Secret name (auto-created by `generate-certs`, unused when --disable-tls).
*/}}
{{- define "openshell-driver-kyma.serverTlsSecretName" -}}
{{- default (printf "%s-server-tls" (include "openshell-driver-kyma.fullname" .)) .Values.gateway.sandboxJwt.serverTlsSecretName }}
{{- end }}

{{/*
Client TLS Secret name (auto-created by `generate-certs`, unused when --disable-tls).
*/}}
{{- define "openshell-driver-kyma.clientTlsSecretName" -}}
{{- default (printf "%s-client-tls" (include "openshell-driver-kyma.fullname" .)) .Values.gateway.sandboxJwt.clientTlsSecretName }}
{{- end }}

{{/*
Stable identifier baked into every gateway-minted sandbox JWT (claim "iss").
*/}}
{{- define "openshell-driver-kyma.gatewayId" -}}
{{- default (include "openshell-driver-kyma.fullname" .) .Values.gateway.sandboxJwt.gatewayId }}
{{- end }}

{{/*
The gateway endpoint sandboxes dial (upstream --grpc-endpoint). An explicit
driver.gatewayEndpoint wins; with the gateway sidecar enabled it defaults to
this release's Service, https:// when the gateway serves TLS
(gateway.tls.enabled) and http:// otherwise, as upstream's openshell.grpcEndpoint
takes the scheme from its disableTls (deploy/helm/openshell/templates/
_helpers.tpl:256-262 at the pinned tag). Empty lets upstream decide.
*/}}
{{- define "openshell-driver-kyma.grpcEndpoint" -}}
{{- if .Values.driver.gatewayEndpoint -}}
{{- .Values.driver.gatewayEndpoint -}}
{{- else if .Values.gateway.enabled -}}
{{- include "openshell-driver-kyma.gatewayTlsGuards" . -}}
{{- $scheme := ternary "https" "http" (default false .Values.gateway.tls.enabled) -}}
{{- printf "%s://%s.%s.svc.cluster.local:%v" $scheme (include "openshell-driver-kyma.fullname" .) .Release.Namespace .Values.gateway.grpcPort -}}
{{- end -}}
{{- end -}}

{{/*
The client TLS Secret the driver mounts into sandboxes (upstream
--client-tls-secret-name). An explicit driver.clientTlsSecretName wins; when the
in-pod gateway serves TLS (gateway.tls.enabled) it defaults to the Secret the
chart's PKI hook creates (openshell-driver-kyma.clientTlsSecretName), as
upstream's chart passes server.tls.clientTlsSecretName whenever TLS is on
(deploy/helm/openshell/templates/gateway-config.yaml:152-154). Empty otherwise,
so the variable is not passed.
*/}}
{{- define "openshell-driver-kyma.driverClientTlsSecretName" -}}
{{- if .Values.driver.clientTlsSecretName -}}
{{- .Values.driver.clientTlsSecretName -}}
{{- else if and .Values.gateway.enabled .Values.gateway.tls.enabled -}}
{{- include "openshell-driver-kyma.clientTlsSecretName" . -}}
{{- end -}}
{{- end -}}

{{/*
The gateway's name: gateway.name, else the chart fullname. The gateway uses it
for its OCSF identity, its OTel resource and the in-process driver build context;
the external driver only for its OTel resource, and nothing persists it, so the
default can follow the fullname. driver.gatewayName defaults to it.
*/}}
{{- define "openshell-driver-kyma.gatewayName" -}}
{{- $name := .Values.gateway.name -}}
{{- if and $name (not (trim (toString $name))) -}}
{{- fail "gateway.name must not be empty; leave it unset for the chart fullname." -}}
{{- end -}}
{{- default (include "openshell-driver-kyma.fullname" .) $name -}}
{{- end -}}

{{/*
The effective managed SSH ingress, as JSON {enabled, gatewayNamespace,
gatewayPodSelector}. Upstream's chart sets managed_ssh_ingress from its own
networkPolicy.enabled, with its release namespace and its gateway pod's labels
(deploy/helm/openshell/templates/gateway-config.yaml:230-233 at the pinned tag).
Here the gateway is the in-pod sidecar (gateway.enabled), so in managed mode
with gateway.enabled and networkPolicy.enabled it is on by default, naming
.Release.Namespace and this chart's selectorLabels. driver.managedSshIngress
overrides each part: enabled (true or false; null for the default),
gatewayNamespace and gatewayPodSelector. The namespace and selector are derived
only when it is enabled and the gateway is in-pod; with an external gateway
(gateway.enabled=false) nothing is derived, so it is off unless enabled and then
takes both from values. The env, the ClusterRole and the workspace guards all
read this, so they follow one effective value.
*/}}
{{- define "openshell-driver-kyma.managedSshIngress" -}}
{{- $ssh := .Values.driver.managedSshIngress -}}
{{- $enabled := $ssh.enabled -}}
{{- if kindIs "invalid" $enabled -}}
{{- $enabled = and (eq .Values.driver.workspaceMode "managed") .Values.gateway.enabled .Values.networkPolicy.enabled -}}
{{- end -}}
{{- $namespace := $ssh.gatewayNamespace -}}
{{- $selector := $ssh.gatewayPodSelector -}}
{{- if and $enabled .Values.gateway.enabled -}}
{{- $namespace = default .Release.Namespace $namespace -}}
{{- if not $selector -}}
{{- $selector = list -}}
{{- range $key, $value := include "openshell-driver-kyma.selectorLabels" . | fromYaml -}}
{{- $selector = append $selector (printf "%s=%s" $key $value) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- dict "enabled" $enabled "gatewayNamespace" $namespace "gatewayPodSelector" $selector | toJson -}}
{{- end -}}

{{/*
The TCP port an OTLP trace export to the given endpoint dials, for the
NetworkPolicy egress; empty without an endpoint. Upstream parses the endpoint as a URI and
hands it to tonic's OTLP/gRPC exporter (openshell-otel src/lib.rs build_provider
at the pinned tag), which dials an explicit port, else its scheme's: 443 for
https, 80 for http. An endpoint without an http(s) scheme (for example a bare
host:4317) gives no port: tonic refuses every request to an endpoint with no
scheme, so upstream exports nothing there and there is no port to open.
*/}}
{{- define "openshell-driver-kyma.otlpPort" -}}
{{- with . -}}
{{- $url := urlParse . -}}
{{- if and (has $url.scheme (list "http" "https")) $url.host -}}
{{- default (ternary "443" "80" (eq $url.scheme "https")) (trimPrefix ":" (regexFind ":[0-9]+$" $url.host)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* The driver's OTLP endpoint: driver.otlpEndpoint, else gateway.otlp.endpoint. */}}
{{- define "openshell-driver-kyma.driverOtlpEndpoint" -}}
{{- default .Values.gateway.otlp.endpoint .Values.driver.otlpEndpoint -}}
{{- end -}}

{{/*
The de-duplicated TCP ports the pod's OTLP trace exports and Vault driver dial, as a
JSON array of numbers: the driver's OTLP endpoint, and, when the in-pod gateway
runs, the gateway's and the Vault address'.
Each OTLP endpoint's port comes from openshell-driver-kyma.otlpPort.
*/}}
{{- define "openshell-driver-kyma.egressPorts" -}}
{{- $endpoints := list (include "openshell-driver-kyma.driverOtlpEndpoint" .) -}}
{{- if .Values.gateway.enabled -}}
{{- $endpoints = prepend $endpoints .Values.gateway.otlp.endpoint -}}
{{- end -}}
{{- $ports := list -}}
{{- range $endpoints -}}
{{- with include "openshell-driver-kyma.otlpPort" . -}}
{{- $ports = append $ports (int .) -}}
{{- end -}}
{{- end -}}
{{- /* The Vault driver is dialled by the gateway: explicit port, else 443 for https, 8200 for http. */ -}}
{{- with and .Values.gateway.enabled (include "openshell-driver-kyma.vaultAddress" .) -}}
{{- $url := urlParse . -}}
{{- $ports = append $ports (int (default (ternary "443" "8200" (eq $url.scheme "https")) (trimPrefix ":" (regexFind ":[0-9]+$" $url.host)))) -}}
{{- end -}}
{{- $ports | uniq | toJson -}}
{{- end -}}

{{/*
Secrets in the sandbox namespace whose contents the driver stages into
workspace namespaces, as a JSON array; empty in shared mode. Mirrors upstream's
openshell.workspaceSecretSourceNames (deploy/helm/openshell/templates/_helpers.tpl
at the pinned tag). The client TLS Secret is staged in managed and operator
mode, when the driver is given one (openshell-driver-kyma.driverClientTlsSecretName:
upstream's chart always has a name and skips it when TLS is off; here an empty
name is that case). The image-pull Secrets are staged in managed mode only.
driver.sandboxImagePullSecrets is a list of Secret names, as the driver's
environment takes it.
*/}}
{{- define "openshell-driver-kyma.workspaceSecretSourceNames" -}}
{{- $mode := .Values.driver.workspaceMode -}}
{{- $names := list -}}
{{- $clientTls := include "openshell-driver-kyma.driverClientTlsSecretName" . -}}
{{- if and (ne $mode "shared") $clientTls -}}
{{- $names = append $names $clientTls -}}
{{- end -}}
{{- if eq $mode "managed" -}}
{{- range .Values.driver.sandboxImagePullSecrets -}}
{{- if . -}}
{{- $names = append $names . -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- uniq $names | toJson -}}
{{- end }}

{{/*
Id of the provider profile the chart registers with the gateway, and the name of
the provider the hook creates from it (inferenceProvider.profileId and .name).
*/}}
{{- define "openshell-driver-kyma.inferenceProfileId" -}}
{{- default (printf "kyma-%s" .Values.inferenceProvider.type) .Values.inferenceProvider.profileId -}}
{{- end -}}

{{- define "openshell-driver-kyma.inferenceProviderName" -}}
{{- default (printf "%s-%s" .Release.Name .Values.inferenceProvider.type) .Values.inferenceProvider.name -}}
{{- end -}}

{{/*
The driver's ClusterRole: rbac.clusterScoped.clusterRoleName, else
<fullname>-driver-<release namespace>. The ClusterRoleBinding refers to it.
*/}}
{{- define "openshell-driver-kyma.clusterRoleName" -}}
{{- default (printf "%s-driver-%s" (include "openshell-driver-kyma.fullname" .) .Release.Namespace) .Values.rbac.clusterScoped.clusterRoleName -}}
{{- end -}}

{{/*
File mode of the gateway's mounted Secrets (sandbox JWT keys, server TLS), as a
decimal integer. gateway.sandboxJwt.secretDefaultMode is a string such as "0440"
(sprig's int reads the leading 0 as octal) matching ^0[0-7]{3}$, or an integer
from 1 to 511 (288); empty = 0400. Anything else is refused.
*/}}
{{- define "openshell-driver-kyma.secretDefaultMode" -}}
{{- $m := .Values.gateway.sandboxJwt.secretDefaultMode -}}
{{- $msg := "gateway.sandboxJwt.secretDefaultMode must be an octal string like \"0440\" or an integer from 1 to 511" -}}
{{- if or (kindIs "invalid" $m) (and (kindIs "string" $m) (eq $m "")) -}}
256
{{- else if kindIs "string" $m -}}
{{- if not (regexMatch "^0[0-7]{3}$" $m) -}}{{- fail (printf "%s, got %q." $msg $m) -}}{{- end -}}
{{ $m | int }}
{{- else if or (kindIs "float64" $m) (kindIs "int" $m) (kindIs "int64" $m) -}}
{{- if or (ne (float64 $m) (floor (float64 $m))) (lt (float64 $m) 1.0) (gt (float64 $m) 511.0) -}}{{- fail (printf "%s, got %v." $msg $m) -}}{{- end -}}
{{ $m | int }}
{{- else -}}
{{- fail (printf "%s, got the %s %v." $msg (kindOf $m) $m) -}}
{{- end -}}
{{- end }}

{{/*
The Service that carries the driver health port and http-services. It is the
release's Service itself while gatewayService.type is ClusterIP; for a LoadBalancer
or NodePort those ports move to <fullname>-internal, which stays ClusterIP.
*/}}
{{- define "openshell-driver-kyma.internalServiceName" -}}
{{- if eq (default "ClusterIP" .Values.gatewayService.type) "ClusterIP" -}}
{{- include "openshell-driver-kyma.fullname" . -}}
{{- else -}}
{{- printf "%s-internal" (include "openshell-driver-kyma.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
The gateway's runtime --server-san value, comma-joined: the wildcard of the sandbox
service domain when gatewayIngress.serviceHosts is on, then the extra names and
addresses (openshell-driver-kyma.extraServerSans). Empty when there is none.
*/}}
{{- define "openshell-driver-kyma.runtimeServerSans" -}}
{{- $sans := list -}}
{{- if include "openshell-driver-kyma.serviceHostsEnabled" . -}}
{{- $sans = append $sans (printf "*.%s" .Values.gatewayIngress.domain) -}}
{{- end -}}
{{- $extra := include "openshell-driver-kyma.extraServerSans" . | fromJson -}}
{{- $sans = concat $sans $extra.dnsNames $extra.ipAddresses -}}
{{- join "," $sans -}}
{{- end }}

{{/*
The operator's extra server names, as JSON {"dnsNames": [...], "ipAddresses": [...]}:
gateway.certManager's while it issues the certificates, else gateway.sandboxJwt's
(the PKI hook's).
*/}}
{{- define "openshell-driver-kyma.extraServerSans" -}}
{{- $src := ternary .Values.gateway.certManager .Values.gateway.sandboxJwt (eq (toString .Values.gateway.certManager.enabled) "true") -}}
{{- dict "dnsNames" ($src.serverDnsNames | default list) "ipAddresses" ($src.serverIpAddresses | default list) | toJson -}}
{{- end }}

{{/*
The names on a server certificate the chart issues (the PKI hook, cert-manager or
Gardener), as JSON: "base" (this release's Service, short to fully qualified, and
localhost), "loopbackIp" (127.0.0.1), then the operator's extra "dnsNames" and
"ipAddresses" (openshell-driver-kyma.extraServerSans). The one place the list is built.
*/}}
{{- define "openshell-driver-kyma.pkiServerNames" -}}
{{- $service := include "openshell-driver-kyma.fullname" . -}}
{{- $ns := .Release.Namespace -}}
{{- $extra := include "openshell-driver-kyma.extraServerSans" . | fromJson -}}
{{- dict "base" (list $service (printf "%s.%s" $service $ns) (printf "%s.%s.svc" $service $ns) (printf "%s.%s.svc.cluster.local" $service $ns) "localhost") "loopbackIp" "127.0.0.1" "dnsNames" $extra.dnsNames "ipAddresses" $extra.ipAddresses | toJson -}}
{{- end }}

{{/*
The DNS names (pkiServerSans: base, then the extra names) and the IP addresses
(pkiServerIps: 127.0.0.1, then the extra addresses) of that certificate, as YAML lists.
*/}}
{{- define "openshell-driver-kyma.pkiServerSans" -}}
{{- $n := include "openshell-driver-kyma.pkiServerNames" . | fromJson -}}
{{- concat $n.base $n.dnsNames | toYaml -}}
{{- end }}

{{- define "openshell-driver-kyma.pkiServerIps" -}}
{{- $n := include "openshell-driver-kyma.pkiServerNames" . | fromJson -}}
{{- concat (list $n.loopbackIp) $n.ipAddresses | toYaml -}}
{{- end }}

{{/*
The Secret holding the chart CA that cert-manager or Gardener issues:
gateway.certManager.caSecretName, else <fullname>-ca-tls.
*/}}
{{- define "openshell-driver-kyma.caSecretName" -}}
{{- default (printf "%s-ca-tls" (include "openshell-driver-kyma.fullname" .)) .Values.gateway.certManager.caSecretName -}}
{{- end }}

{{/*
The spec fields cert-manager.io and cert.gardener.cloud Certificates have in common,
for cert-manager-pki.yaml and gardener-pki.yaml (each adds its own issuerRef). Takes a
dict with `ctx` (the root context) and `role`: "ca" (the chart CA), "server" (the
gateway's names, as openshell-driver-kyma.pkiServerSans) or "client". The CA gets an
explicit duration, longer than a leaf's lifetime plus its renewal window
(certManagerGuards): it must outlive every certificate it signs.
*/}}
{{- define "openshell-driver-kyma.pkiCertSpec" -}}
{{- $ctx := .ctx -}}
{{- $cm := $ctx.Values.gateway.certManager -}}
{{- if eq .role "ca" -}}
isCA: true
commonName: openshell-ca
secretName: {{ include "openshell-driver-kyma.caSecretName" $ctx | quote }}
duration: {{ $cm.caDuration | quote }}
{{- else -}}
secretName: {{ include (printf "openshell-driver-kyma.%sTlsSecretName" .role) $ctx | quote }}
duration: {{ $cm.certificateDuration | quote }}
renewBefore: {{ $cm.certificateRenewBefore | quote }}
{{- if eq .role "server" }}
commonName: {{ include "openshell-driver-kyma.fullname" $ctx }}
dnsNames:
  {{- range include "openshell-driver-kyma.pkiServerSans" $ctx | fromYamlArray }}
  - {{ . | quote }}
  {{- end }}
ipAddresses:
  {{- range include "openshell-driver-kyma.pkiServerIps" $ctx | fromYamlArray }}
  - {{ . | quote }}
  {{- end }}
{{- else }}
commonName: openshell-client
{{- end }}
{{- end }}
privateKey:
  algorithm: ECDSA
  size: 256
{{- if ne .role "ca" }}
usages:
  - {{ ternary "server auth" "client auth" (eq .role "server") }}
  - digital signature
  - key encipherment
{{- end }}
{{- end }}

{{/*
A Go duration limited to hours, minutes and seconds with integer parts ("8760h",
"1h30m", "45m", "90s"), in seconds. Takes a dict with `key` (the value's name, for
the message), `value` and `example`; anything else fails the render.
*/}}
{{- define "openshell-driver-kyma.durationSeconds" -}}
{{- $v := toString .value -}}
{{- if or (eq $v "") (not (regexMatch "^([0-9]+h)?([0-9]+m)?([0-9]+s)?$" $v)) -}}
{{- fail (printf "%s must be a Go duration in hours (e.g. %s), got %q." .key .example $v) -}}
{{- end -}}
{{- $total := 0 -}}
{{- range $part := regexFindAll "[0-9]+[hms]" $v -1 -}}
{{- $n := trimSuffix "h" (trimSuffix "m" (trimSuffix "s" $part)) | atoi -}}
{{- $unit := get (dict "h" 3600 "m" 60 "s" 1) (regexFind "[hms]$" $part) -}}
{{- $total = add $total (mul $n $unit) -}}
{{- end -}}
{{- $total -}}
{{- end }}

{{/* Seconds as a Go duration in hours, minutes and seconds, zero parts left out ("9480h", "2h15m"). */}}
{{- define "openshell-driver-kyma.formatDuration" -}}
{{- $s := int . -}}
{{- $out := "" -}}
{{- if ge $s 3600 -}}{{- $out = printf "%dh" (div $s 3600) -}}{{- end -}}
{{- if mod (div $s 60) 60 -}}{{- $out = printf "%s%dm" $out (mod (div $s 60) 60) -}}{{- end -}}
{{- if or (mod $s 60) (eq $s 0) -}}{{- $out = printf "%s%ds" $out (mod $s 60) -}}{{- end -}}
{{- $out -}}
{{- end }}

{{/*
Where the gateway reads the client CA: the server TLS Secret's ca.crt, or
gateway.tls.clientCa.secretName's ca.crt (mounted at /etc/openshell-tls/client-ca).
*/}}
{{- define "openshell-driver-kyma.clientCaPath" -}}
{{- if .Values.gateway.tls.clientCa.secretName -}}
/etc/openshell-tls/client-ca/ca.crt
{{- else -}}
/etc/openshell-tls/server/ca.crt
{{- end -}}
{{- end }}
