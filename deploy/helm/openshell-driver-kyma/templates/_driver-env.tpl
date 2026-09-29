{{/*
Environment for the driver container: upstream openshell-driver-kubernetes's
options, by upstream's own variable names, then the Kyma layer's.
scripts/check-chart-render.sh fails CI when an upstream option is missing here.
*/}}
{{- define "openshell-driver-kyma.driverEnv" -}}
{{- $d := .Values.driver -}}
- name: OPENSHELL_COMPUTE_DRIVER_SOCKET
  value: {{ $d.socket | quote }}
- name: OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON
  # Must agree with [openshell.drivers.kyma] allow_driver_config in
  # gateway-config.yaml; both render from driver.allowDriverConfig.
  value: {{ dict "allow_driver_config" $d.allowDriverConfig | toJson | quote }}
- name: OPENSHELL_LOG_LEVEL
  value: {{ $d.logLevel | quote }}
- name: OPENSHELL_SANDBOX_NAMESPACE
  value: {{ .Values.namespace | quote }}
- name: OPENSHELL_WORKSPACE_MODE
  value: {{ $d.workspaceMode | quote }}
- name: OPENSHELL_GATEWAY_ID
  # The same value the gateway's gateway_jwt uses, as in upstream's chart.
  value: {{ include "openshell-driver-kyma.gatewayId" . | quote }}
- name: OPENSHELL_K8S_SANDBOX_SERVICE_ACCOUNT
  value: {{ .Values.sandboxServiceAccount.name | quote }}
- name: OPENSHELL_SUPERVISOR_IMAGE
  value: {{ $d.supervisorImage | quote }}
- name: OPENSHELL_SANDBOX_RUNTIME_IMAGE
  value: {{ $d.sandboxRuntimeImage | quote }}
- name: OPENSHELL_K8S_SANDBOX_RUNTIME_BOUNDARY_PORT
  value: {{ $d.sandboxRuntimeBoundaryPort | quote }}
- name: OPENSHELL_K8S_SA_TOKEN_TTL_SECS
  value: {{ $d.saTokenTtlSecs | quote }}
{{- with include "openshell-driver-kyma.grpcEndpoint" . }}
- name: OPENSHELL_GRPC_ENDPOINT
  value: {{ . | quote }}
{{- end }}
{{- with $d.bindAddress }}
- name: OPENSHELL_COMPUTE_DRIVER_BIND
  value: {{ . | quote }}
{{- end }}
{{- with $d.otlpEndpoint }}
- name: OPENSHELL_OTLP_ENDPOINT
  value: {{ . | quote }}
{{- end }}
{{- with $d.gatewayName }}
- name: OPENSHELL_GATEWAY_NAME
  value: {{ . | quote }}
{{- end }}
{{- with $d.operatorNamespaceLabel }}
- name: OPENSHELL_OPERATOR_NAMESPACE_LABEL
  value: {{ . | quote }}
{{- end }}
{{- if $d.operatorNamespaceConfigMap.name }}
- name: OPENSHELL_OPERATOR_NAMESPACE_FILE
  value: {{ printf "/etc/openshell-operator-namespaces/%s" $d.operatorNamespaceConfigMap.key | quote }}
{{- end }}
{{- with $d.sandboxImage }}
- name: OPENSHELL_SANDBOX_IMAGE
  value: {{ . | quote }}
{{- end }}
{{- with $d.sandboxImagePullPolicy }}
- name: OPENSHELL_SANDBOX_IMAGE_PULL_POLICY
  value: {{ . | quote }}
{{- end }}
{{- with $d.sandboxImagePullSecrets }}
- name: OPENSHELL_SANDBOX_IMAGE_PULL_SECRETS
  value: {{ join "," . | quote }}
{{- end }}
{{- if $d.managedSshIngress.enabled }}
- name: OPENSHELL_MANAGED_SSH_INGRESS_ENABLED
  value: "true"
{{- end }}
{{- with $d.managedSshIngress.gatewayNamespace }}
- name: OPENSHELL_MANAGED_SSH_GATEWAY_NAMESPACE
  value: {{ . | quote }}
{{- end }}
{{- with $d.managedSshIngress.gatewayPodSelector }}
- name: OPENSHELL_MANAGED_SSH_GATEWAY_POD_SELECTOR
  value: {{ join "," . | quote }}
{{- end }}
{{- with $d.sandboxSshSocketPath }}
- name: OPENSHELL_SANDBOX_SSH_SOCKET_PATH
  value: {{ . | quote }}
{{- end }}
{{- with $d.clientTlsSecretName }}
- name: OPENSHELL_CLIENT_TLS_SECRET_NAME
  value: {{ . | quote }}
{{- end }}
{{- with $d.hostGatewayIp }}
- name: OPENSHELL_HOST_GATEWAY_IP
  value: {{ . | quote }}
{{- end }}
{{- with $d.sandboxRuntimeImagePullPolicy }}
- name: OPENSHELL_SANDBOX_RUNTIME_IMAGE_PULL_POLICY
  value: {{ . | quote }}
{{- end }}
{{- with $d.supervisorImagePullPolicy }}
- name: OPENSHELL_SUPERVISOR_IMAGE_PULL_POLICY
  value: {{ . | quote }}
{{- end }}
{{- with $d.upstreamProxy.url }}
- name: OPENSHELL_UPSTREAM_PROXY
  value: {{ . | quote }}
{{- end }}
{{- with $d.upstreamProxy.noProxy }}
- name: OPENSHELL_UPSTREAM_NO_PROXY
  value: {{ . | quote }}
{{- end }}
{{- with $d.upstreamProxy.authSecretName }}
- name: OPENSHELL_UPSTREAM_PROXY_AUTH_SECRET_NAME
  value: {{ . | quote }}
{{- end }}
{{- with $d.upstreamProxy.authSecretKey }}
- name: OPENSHELL_UPSTREAM_PROXY_AUTH_SECRET_KEY
  value: {{ . | quote }}
{{- end }}
{{- if $d.upstreamProxy.allowInsecure }}
- name: OPENSHELL_UPSTREAM_PROXY_AUTH_ALLOW_INSECURE
  value: "true"
{{- end }}
{{- if $d.upstreamProxy.connectByHostname }}
- name: OPENSHELL_UPSTREAM_PROXY_CONNECT_BY_HOSTNAME
  value: "true"
{{- end }}
{{- if $d.upstreamProxy.caBundleConfigMap.name }}
- name: OPENSHELL_UPSTREAM_PROXY_CA_BUNDLE
  value: {{ printf "/etc/openshell-upstream-proxy/%s" $d.upstreamProxy.caBundleConfigMap.key | quote }}
{{- end }}
{{- if $d.enableUserNamespaces }}
- name: OPENSHELL_ENABLE_USER_NAMESPACES
  value: "true"
{{- end }}
{{- with $d.providerSpiffeWorkloadApiSocket }}
- name: OPENSHELL_PROVIDER_SPIFFE_WORKLOAD_API_SOCKET
  value: {{ . | quote }}
{{- end }}
{{- with $d.sandboxUid }}
- name: OPENSHELL_K8S_SANDBOX_UID
  value: {{ include "openshell-driver-kyma.wholeNumber" . | quote }}
{{- end }}
{{- with $d.sandboxGid }}
- name: OPENSHELL_K8S_SANDBOX_GID
  value: {{ include "openshell-driver-kyma.wholeNumber" . | quote }}
{{- end }}
{{- with $d.sandboxStorageSize }}
- name: OPENSHELL_K8S_WORKSPACE_DEFAULT_STORAGE_SIZE
  value: {{ . | quote }}
{{- end }}
{{- with $d.sandboxStorageClass }}
- name: OPENSHELL_K8S_WORKSPACE_STORAGE_CLASS
  value: {{ . | quote }}
{{- end }}
{{- with $d.runtimeClassName }}
- name: OPENSHELL_K8S_DEFAULT_RUNTIME_CLASS_NAME
  value: {{ . | quote }}
{{- end }}
{{- if $d.istioInjectSandboxes }}
- name: OPENSHELL_KYMA_ISTIO_INJECT_SANDBOXES
  value: "true"
{{- end }}
{{- if $d.disableClaudeTelemetry }}
- name: OPENSHELL_KYMA_DISABLE_CLAUDE_TELEMETRY
  value: "true"
{{- end }}
{{- if $d.enableApirule }}
- name: OPENSHELL_KYMA_ENABLE_APIRULE
  value: "true"
- name: OPENSHELL_KYMA_CLUSTER_DOMAIN
  value: {{ required "driver.clusterDomain is required when driver.enableApirule is true" $d.clusterDomain | quote }}
{{- end }}
- name: OPENSHELL_KYMA_INGRESS_NAMESPACE
  value: {{ $d.ingressNamespace | quote }}
{{- with $d.workspacePsaLevel }}
- name: OPENSHELL_KYMA_WORKSPACE_PSA_LEVEL
  value: {{ . | quote }}
{{- end }}
- name: OPENSHELL_KYMA_HEALTH_PORT
  value: {{ $d.healthPort | quote }}
{{- with (include "openshell-driver-kyma.sandboxEnv" .) }}
- name: OPENSHELL_KYMA_SANDBOX_ENV
  value: {{ . | quote }}
{{- end }}
{{- end -}}

{{/*
A whole number as digits. A values file yields float64, which Go prints as
1.00074e+09 from seven digits up, and OpenShift-range UIDs have ten. Strings
pass through unchanged, so the driver's own parser reports a bad one.
*/}}
{{- define "openshell-driver-kyma.wholeNumber" -}}
{{- if kindIs "float64" . -}}{{ int64 . }}{{- else -}}{{ . }}{{- end -}}
{{- end -}}

{{/*
Comma-joined KEY=VALUE list for OPENSHELL_KYMA_SANDBOX_ENV. driver.sandboxEnv is
checked separately, by openshell-driver-kyma.sandboxEnvGuards.
*/}}
{{- define "openshell-driver-kyma.sandboxEnv" -}}
{{- join "," .Values.driver.sandboxEnv -}}
{{- end -}}

{{/*
Pre-flight guard for driver.sandboxEnv, called from deployment.yaml beside the
other guards. It mirrors what the driver's startup validation accepts
(kyma_args.rs), so a bad entry fails `helm template` naming the entry instead of
crash-looping the pod: no comma (the driver splits the list on commas), a `=`, a
non-empty key, and no OPENSHELL_ key other than OPENSHELL_LOG_LEVEL (upstream
strips those from the sandbox environment).
*/}}
{{- define "openshell-driver-kyma.sandboxEnvGuards" -}}
{{- range $entry := .Values.driver.sandboxEnv -}}
{{- $e := toString $entry -}}
{{- if contains "," $e -}}
{{- fail (printf "driver.sandboxEnv entry %q contains a comma; the driver splits OPENSHELL_KYMA_SANDBOX_ENV on commas, so a value cannot contain one. Set such a variable per sandbox through the caller's template environment." $e) -}}
{{- end -}}
{{- if not (contains "=" $e) -}}
{{- fail (printf "driver.sandboxEnv entry %q must be KEY=VALUE." $e) -}}
{{- end -}}
{{- $key := first (splitList "=" $e) -}}
{{- if not $key -}}
{{- fail (printf "driver.sandboxEnv entry %q has an empty KEY; it must be KEY=VALUE." $e) -}}
{{- end -}}
{{- if and (hasPrefix "OPENSHELL_" $key) (ne $key "OPENSHELL_LOG_LEVEL") -}}
{{- fail (printf "driver.sandboxEnv entry %q uses a reserved OPENSHELL_* key: upstream strips it from the sandbox environment (only OPENSHELL_LOG_LEVEL is kept)." $e) -}}
{{- end -}}
{{- end -}}
{{- end -}}
