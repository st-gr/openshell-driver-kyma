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
