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
  # Must agree with the [openshell.drivers.kyma] tables in gateway-config.yaml;
  # both render from openshell-driver-kyma.admissionPolicy.
  value: {{ include "openshell-driver-kyma.admissionPolicy" . | quote }}
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
{{- $ssh := include "openshell-driver-kyma.managedSshIngress" . | fromJson }}
{{- if $ssh.enabled }}
- name: OPENSHELL_MANAGED_SSH_INGRESS_ENABLED
  value: "true"
{{- end }}
{{- with $ssh.gatewayNamespace }}
- name: OPENSHELL_MANAGED_SSH_GATEWAY_NAMESPACE
  value: {{ . | quote }}
{{- end }}
{{- with $ssh.gatewayPodSelector }}
- name: OPENSHELL_MANAGED_SSH_GATEWAY_POD_SELECTOR
  value: {{ join "," . | quote }}
{{- end }}
{{- with $d.sandboxSshSocketPath }}
- name: OPENSHELL_SANDBOX_SSH_SOCKET_PATH
  value: {{ . | quote }}
{{- end }}
{{- with include "openshell-driver-kyma.driverClientTlsSecretName" . }}
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
{{- with include "openshell-driver-kyma.sandboxIdentity" (dict "key" "driver.sandboxUid" "value" $d.sandboxUid) }}
- name: OPENSHELL_K8S_SANDBOX_UID
  value: {{ . | quote }}
{{- end }}
{{- with include "openshell-driver-kyma.sandboxIdentity" (dict "key" "driver.sandboxGid" "value" $d.sandboxGid) }}
- name: OPENSHELL_K8S_SANDBOX_GID
  value: {{ . | quote }}
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
- name: OPENSHELL_KYMA_EXPOSURE_KIND
  value: {{ $d.exposureKind | quote }}
- name: OPENSHELL_KYMA_ISTIO_GATEWAY
  value: {{ $d.istioGateway | quote }}
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
A sandbox UID or GID as digits, for driver.sandboxUid / driver.sandboxGid. Takes
(dict "key" <values key> "value" <its value>).

Unset (nil or "") gives an empty string, so the variable is omitted and upstream
resolves the identity itself. A set value must be a whole number in
[1, 4294967294], upstream's range (openshell-policy MIN_SANDBOX_UID and
MAX_SANDBOX_UID, checked by validate_sandbox_identity_config in
openshell-driver-kubernetes src/config.rs:569); anything else fails the render
naming the key. So 0 is refused instead of silently dropped, and a fraction
instead of truncated. Digit strings are accepted, other strings are not.

The digits are printed from an int64: a values file yields float64, which Go
prints as 1.00074e+09 from seven digits up, and OpenShift-range UIDs have ten.
*/}}
{{- define "openshell-driver-kyma.sandboxIdentity" -}}
{{- $v := .value -}}
{{- $unset := kindIs "invalid" $v -}}
{{- if kindIs "string" $v -}}
{{- if eq $v "" -}}
{{- $unset = true -}}
{{- end -}}
{{- end -}}
{{- if not $unset -}}
{{- $ok := or (kindIs "float64" $v) (kindIs "int64" $v) (kindIs "int" $v) -}}
{{- if kindIs "string" $v -}}
{{- $ok = regexMatch "^[0-9]+$" $v -}}
{{- end -}}
{{- $shown := printf "%v" $v -}}
{{- if kindIs "float64" $v -}}
{{- $shown = printf "%.15g" $v -}}
{{- end -}}
{{- if not $ok -}}
{{- fail (printf "%s %s must be a whole number from 1 to 4294967294 (upstream's sandbox identity range); leave it unset for upstream's default." .key $shown) -}}
{{- end -}}
{{- $f := float64 $v -}}
{{- if or (lt $f (float64 1)) (gt $f (float64 4294967294)) (ne $f (floor $f)) -}}
{{- fail (printf "%s %s must be a whole number from 1 to 4294967294 (upstream's sandbox identity range); leave it unset for upstream's default." .key $shown) -}}
{{- end -}}
{{- int64 $f -}}
{{- end -}}
{{- end -}}

{{/*
Comma-joined KEY=VALUE list for OPENSHELL_KYMA_SANDBOX_ENV: driver.sandboxEnv, then,
with inferenceProvider.enabled, the endpoint and model sandboxes call
(ANTHROPIC_BASE_URL, ANTHROPIC_MODEL). The driver keeps the first entry for a
key, so an explicit driver.sandboxEnv entry wins. driver.sandboxEnv is checked
separately, by openshell-driver-kyma.sandboxEnvGuards; the two provider values, by
openshell-driver-kyma.inferenceProviderGuards.
*/}}
{{- define "openshell-driver-kyma.sandboxEnv" -}}
{{- $env := .Values.driver.sandboxEnv -}}
{{- if .Values.inferenceProvider.enabled -}}
{{- $env = concat $env (list
      (printf "ANTHROPIC_BASE_URL=%s" .Values.inferenceProvider.baseUrl)
      (printf "ANTHROPIC_MODEL=%s" .Values.inferenceProvider.modelId)) -}}
{{- end -}}
{{- join "," $env -}}
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

{{/*
Pre-flight guard for driver values that are not workspace or sandbox-env
settings, called from deployment.yaml beside the other guards.

driver.exposureKind and driver.istioGateway are checked as the driver's
startup validation checks them (kyma_args.rs), whether or not exposure is
enabled, because the driver validates them either way: the kind is
virtualservice or apirule, and the gateway is <namespace>/<name>, two DNS-1123
labels.

driver.allowDriverConfig and driver.resourceAdmission.enabled render as bare
TOML values in the gateway's config and as JSON values in the driver's
admission policy. Given the string "false", the TOML still reads as the boolean
false but the JSON carries the string "false", which the driver rejects. Each
must be a real boolean. driver.resourceAdmission.requiredLabels is a map of
label to value, or null for upstream's built-in set; an empty map is refused
while admission is enabled, as upstream refuses it at startup
(ResourceAdmissionConfig::validate, src/resource_admission.rs:135-140).
*/}}
{{- define "openshell-driver-kyma.driverValueGuards" -}}
{{- $kind := toString .Values.driver.exposureKind -}}
{{- if not (has $kind (list "virtualservice" "apirule")) -}}
{{- fail (printf "driver.exposureKind must be virtualservice or apirule, got %q." $kind) -}}
{{- end -}}
{{- $istioGateway := toString .Values.driver.istioGateway -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?/[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$" $istioGateway) -}}
{{- fail (printf "driver.istioGateway %q must be <namespace>/<name>, two DNS-1123 labels (e.g. kyma-system/kyma-gateway): the Istio Gateway the exposure VirtualService binds to." $istioGateway) -}}
{{- end -}}
{{- $sock := toString .Values.driver.socket -}}
{{- $parts := splitList "/" (trimPrefix "/" $sock) -}}
{{- if or (not (hasPrefix "/" $sock)) (hasSuffix "/" $sock) (lt (len $parts) 4) (has "" $parts) -}}
{{- fail (printf "driver.socket %q must be an absolute path with at least three directories (e.g. /var/run/openshell/driver.sock; 0.8.0's /var/run/openshell-driver.sock no longer works): upstream's driver refuses to start unless its own uid owns the socket's parent directory, so the chart mounts the shared emptyDir at the grandparent (which must not be a top-level directory) and the driver creates the parent." $sock) -}}
{{- end -}}
{{- $allow := .Values.driver.allowDriverConfig -}}
{{- if not (kindIs "bool" $allow) -}}
{{- fail (printf "driver.allowDriverConfig must be a boolean (true or false), got %s %v. It renders into the gateway's TOML and the driver's admission JSON, and a string breaks the JSON." (kindOf $allow) $allow) -}}
{{- end -}}
{{- $admission := .Values.driver.resourceAdmission.enabled -}}
{{- if not (kindIs "bool" $admission) -}}
{{- fail (printf "driver.resourceAdmission.enabled must be a boolean (true or false), got %s %v. It renders into the gateway's TOML and the driver's admission JSON, and a string breaks the JSON." (kindOf $admission) $admission) -}}
{{- end -}}
{{- $labels := .Values.driver.resourceAdmission.requiredLabels -}}
{{- if not (or (kindIs "invalid" $labels) (kindIs "map" $labels)) -}}
{{- fail (printf "driver.resourceAdmission.requiredLabels must be a map of label to value (or null for upstream's built-in labels), got %s." (kindOf $labels)) -}}
{{- end -}}
{{- if and $admission (kindIs "map" $labels) (eq (len $labels) 0) -}}
{{- fail "driver.resourceAdmission.enabled=true with driver.resourceAdmission.requiredLabels={} (empty) cannot start: upstream refuses an empty required-label set while admission is enabled (\"resource_admission.required_labels must not be empty while enabled\", openshell-core src/resource_admission.rs:136 at v0.1.2). Set requiredLabels to null for upstream's built-in labels or to a non-empty map, or set driver.resourceAdmission.enabled=false to turn the approval check off." -}}
{{- end -}}
{{- end -}}

{{/*
The resource-admission policy, as upstream's DriverAdmissionConfig JSON
(openshell-core src/resource_admission.rs at the pinned tag): allow_driver_config,
and resource_admission with enabled and, only when driver.resourceAdmission.
requiredLabels is set, required_labels (a missing map means upstream's built-in
labels; an empty one is kept). The driver receives it as
OPENSHELL_DRIVER_ADMISSION_CONFIG_JSON, and gateway-config.yaml renders the
gateway's [openshell.drivers.kyma] tables from it, as upstream's chart renders
its own driver's (deploy/helm/openshell/templates/gateway-config.yaml:141-142,
221-228), so the two sides are one value. Label values are strings, as the TOML
quotes them. It runs driverValueGuards first, so a template that renders the
policy before deployment.yaml's guards run fails with the guard's message.
*/}}
{{- define "openshell-driver-kyma.admissionPolicy" -}}
{{- include "openshell-driver-kyma.driverValueGuards" . -}}
{{- $d := .Values.driver -}}
{{- $admission := dict "enabled" $d.resourceAdmission.enabled -}}
{{- if ne $d.resourceAdmission.requiredLabels nil -}}
{{- $labels := dict -}}
{{- range $key, $value := $d.resourceAdmission.requiredLabels -}}
{{- $_ := set $labels $key (toString $value) -}}
{{- end -}}
{{- $_ := set $admission "required_labels" $labels -}}
{{- end -}}
{{- dict "allow_driver_config" $d.allowDriverConfig "resource_admission" $admission | toJson -}}
{{- end -}}
