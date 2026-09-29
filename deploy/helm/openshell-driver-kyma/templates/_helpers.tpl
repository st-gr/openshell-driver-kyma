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
The TCP port the driver's OTLP trace export dials, for its NetworkPolicy egress;
empty without driver.otlpEndpoint. Upstream parses the endpoint as a URI and
hands it to tonic's OTLP/gRPC exporter (openshell-otel src/lib.rs build_provider
at the pinned tag), which dials an explicit port, else its scheme's: 443 for
https, 80 for http. An endpoint without an http(s) scheme (for example a bare
host:4317) gives no port: tonic refuses every request to an endpoint with no
scheme, so upstream exports nothing there and there is no port to open.
*/}}
{{- define "openshell-driver-kyma.otlpPort" -}}
{{- with .Values.driver.otlpEndpoint -}}
{{- $url := urlParse . -}}
{{- if and (has $url.scheme (list "http" "https")) $url.host -}}
{{- default (ternary "443" "80" (eq $url.scheme "https")) (trimPrefix ":" (regexFind ":[0-9]+$" $url.host)) -}}
{{- end -}}
{{- end -}}
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
