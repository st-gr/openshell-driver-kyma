{{/* Pre-flight guards for driver.workspaceMode.

Mirrors the `{{- fail -}}` style of _inference-provider-guards.tpl: refuse
to render broken manifests instead of producing a Deployment that will
crash-loop once the driver starts.

Every rule below is one of upstream's startup refusals in
KubernetesComputeConfig::validate_workspace_mode (openshell-driver-kubernetes
src/config.rs, v0.1.2), so a value upstream would refuse fails `helm template`
instead of crash-looping the pod:
  managed   config.rs:661   gateway id is a DNS-1123 label
            config.rs:671   "openshell-<id>-" plus a 19-character workspace
                            name fits 63 characters, so the id is at most 33
            config.rs:682   managed SSH ingress needs a gateway namespace
                            and a gateway pod selector (checked on the
                            effective values, openshell-driver-kyma.
                            managedSshIngress: with the in-pod gateway both
                            default to its own pod)
  operator  config.rs:697   exactly one of the namespace label or file...
            config.rs:703   ...not both
Not mirrored because no chart value can reach them: an empty gateway id
(config.rs:658, the id defaults to the release fullname) and an empty operator
label or file (config.rs:709-717, an empty value is simply not passed).

Called via `{{ include "openshell-driver-kyma.workspaceGuards" . }}` from
deployment.yaml. */}}

{{- define "openshell-driver-kyma.workspaceGuards" -}}
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
