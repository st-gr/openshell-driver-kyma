{{/* Pre-flight guards for driver.workspaceMode.

Mirrors the `{{- fail -}}` style of _inference-provider-guards.tpl: refuse
to render broken manifests instead of producing a Deployment that will
crash-loop once the driver starts.

Every rule below is one of upstream's startup refusals in
KubernetesComputeConfig::validate_workspace_mode (openshell-driver-kubernetes
src/config.rs, v0.1.7), so a value upstream would refuse fails `helm template`
instead of crash-looping the pod:
  managed   config.rs:897   gateway id is a DNS-1123 label
            config.rs:907   "openshell-<id>-" plus a 19-character workspace
                            name fits 63 characters, so the id is at most 33
            config.rs:918   managed SSH ingress needs a gateway namespace
                            and a gateway pod selector (checked on the
                            effective values, openshell-driver-kyma.
                            managedSshIngress: with the in-pod gateway both
                            default to its own pod)
  operator  config.rs:933   exactly one of the namespace label or file...
            config.rs:939   ...not both
Not mirrored because no chart value can reach them: an empty gateway id
(config.rs:894, the id defaults to the release fullname) and an empty operator
label or file (config.rs:945-953, an empty value is simply not passed).

Also mirrored, from upstream v0.1.7:
  OTLP exports openshell-core sandbox_env.rs SupervisorOtlpArgs: each protocol
               is a clap enum (grpc, http/protobuf), and --otlp-cert-file and
               --otlp-key-file `requires` each other. The OCSF schema version is
               deprecated and ignored, no longer refused without the endpoint.
  pod metadata config.rs validate_pod_metadata_allowlist (driver.
               allowedPodAnnotations / allowedPodLabels): each entry is an exact
               key or `<domain>/*`, with a valid prefix and name, outside the
               reserved openshell.ai and agents.x-k8s.io domains

Called via `{{ include "openshell-driver-kyma.workspaceGuards" . }}` from
deployment.yaml. */}}

{{- define "openshell-driver-kyma.podMetadataAllowlistGuard" -}}
{{- if not (kindIs "slice" .entries) -}}
{{- fail (printf "driver.%s must be a list." .key) -}}
{{- end -}}
{{- range .entries -}}
{{- $entry := toString . -}}
{{- $wildcard := hasSuffix "/*" $entry -}}
{{- $key := ternary (trimSuffix "/*" $entry) $entry $wildcard -}}
{{- $prefix := "" -}}
{{- $name := "" -}}
{{- if contains "/" $key -}}
{{- if $wildcard -}}
{{- fail (printf "driver.%s entry %q: wildcard entries must be `<domain>/*`." $.key $entry) -}}
{{- end -}}
{{- $parts := regexSplit "/" $key 2 -}}
{{- $prefix = index $parts 0 -}}
{{- $name = index $parts 1 -}}
{{- else if $wildcard -}}
{{- $prefix = $key -}}
{{- else -}}
{{- $name = $key -}}
{{- end -}}
{{- if and $prefix (or (gt (len $prefix) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$" $prefix))) -}}
{{- fail (printf "driver.%s entry %q: invalid key prefix %q." $.key $entry $prefix) -}}
{{- end -}}
{{- if and (not $wildcard) (not (regexMatch "^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$" $name)) -}}
{{- fail (printf "driver.%s entry %q: invalid key name %q." $.key $entry $name) -}}
{{- end -}}
{{- range $reserved := list "openshell.ai" "agents.x-k8s.io" -}}
{{- if or (eq $prefix $reserved) (hasSuffix (printf ".%s" $reserved) $prefix) -}}
{{- fail (printf "driver.%s entry %q: domain is reserved for OpenShell and Agent Sandbox." $.key $entry) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "openshell-driver-kyma.workspaceGuards" -}}
{{- range $key := list "otlpProtocol" "otlpOcsfProtocol" "otlpAgentProtocol" -}}
{{- $value := get $.Values.driver $key | default "" -}}
{{- if not (has $value (list "" "grpc" "http/protobuf")) -}}
{{- fail (printf "driver.%s must be empty, grpc or http/protobuf, got %q." $key (toString $value)) -}}
{{- end -}}
{{- end -}}
{{- if ne (empty .Values.driver.otlpCertFile) (empty .Values.driver.otlpKeyFile) -}}
{{- fail "driver.otlpCertFile and driver.otlpKeyFile must be set together (upstream's driver requires both for a client certificate)." -}}
{{- end -}}
{{- include "openshell-driver-kyma.podMetadataAllowlistGuard" (dict "key" "allowedPodAnnotations" "entries" (.Values.driver.allowedPodAnnotations | default list)) -}}
{{- include "openshell-driver-kyma.podMetadataAllowlistGuard" (dict "key" "allowedPodLabels" "entries" (.Values.driver.allowedPodLabels | default list)) -}}
{{- $mode := .Values.driver.workspaceMode -}}
{{- if not (has $mode (list "shared" "managed" "operator")) -}}
{{- fail (printf "driver.workspaceMode must be one of shared|managed|operator, got %q." $mode) -}}
{{- end -}}
{{- if eq $mode "managed" -}}
{{- $gid := include "openshell-driver-kyma.gatewayId" . -}}
{{- if or (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $gid)) (gt (len $gid) 63) -}}
{{- fail (printf "gateway.sandboxJwt.gatewayId %q (default: the release's fullname) is not a DNS-1123 label; it becomes part of every managed namespace name." $gid) -}}
{{- end -}}
{{- $prefix := printf "openshell-%s-" $gid -}}
{{- $maxId := sub (sub 63 19) (len "openshell--") -}}
{{- if gt (add (len $prefix) 19) 63 -}}
{{- fail (printf "gateway.sandboxJwt.gatewayId %q (default: the release's fullname) is %d characters, too long for managed mode: the namespace prefix %q plus the longest workspace name (19 characters) must fit the 63-character namespace limit, so the id may be at most %d characters. Set gateway.sandboxJwt.gatewayId to a shorter DNS-1123 label." $gid (len $gid) $prefix $maxId) -}}
{{- end -}}
{{- $ssh := include "openshell-driver-kyma.managedSshIngress" . | fromJson -}}
{{- if $ssh.enabled -}}
{{- if not $ssh.gatewayNamespace -}}
{{- fail "driver.managedSshIngress.enabled in managed mode requires driver.managedSshIngress.gatewayNamespace (it defaults to the release namespace only with the in-pod gateway, gateway.enabled)." -}}
{{- end -}}
{{- if not $ssh.gatewayPodSelector -}}
{{- fail "driver.managedSshIngress.enabled in managed mode requires driver.managedSshIngress.gatewayPodSelector (key=value entries; it defaults to this chart's pod labels only with the in-pod gateway, gateway.enabled)." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if eq $mode "operator" -}}
{{- $label := .Values.driver.operatorNamespaceLabel -}}
{{- $file := .Values.driver.operatorNamespaceConfigMap.name -}}
{{- if and (not $label) (not $file) -}}
{{- fail "driver.workspaceMode=operator requires exactly one of driver.operatorNamespaceLabel or driver.operatorNamespaceConfigMap.name, which select the namespaces upstream's driver may use." -}}
{{- end -}}
{{- if and $label $file -}}
{{- fail "driver.workspaceMode=operator requires exactly one of driver.operatorNamespaceLabel or driver.operatorNamespaceConfigMap.name, not both." -}}
{{- end -}}
{{- end -}}
{{- end -}}
