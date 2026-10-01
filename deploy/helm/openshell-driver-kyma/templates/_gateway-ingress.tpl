{{/*
Remote access through the cluster's Istio ingress gateway (gatewayIngress).
The gateway is published, never a sandbox pod: upstream's sandbox runtime resets
every inbound connection that does not arrive through the gateway's relay.
*/}}

{{/* The host the CLI dials: gatewayIngress.host, else openshell.<domain>. */}}
{{- define "openshell-driver-kyma.gatewayIngressHost" -}}
{{- default (printf "openshell.%s" .Values.gatewayIngress.domain) .Values.gatewayIngress.host -}}
{{- end -}}

{{/* "true" when sandbox service URLs are published (browser traffic), else empty. */}}
{{- define "openshell-driver-kyma.serviceHostsEnabled" -}}
{{- if and .Values.gatewayIngress.enabled .Values.gatewayIngress.serviceHosts.enabled -}}true{{- end -}}
{{- end -}}

{{/*
The port the gateway binds in the pod. Upstream prints a service URL as
<scheme>://<host>:<bind port>/ and leaves the port out only for http on 80
(openshell-server src/service_routing.rs endpoint_url at the pinned tag), so with
published service hosts the gateway binds 80: the URL is then http://<host>/,
which the Kyma gateway's http server redirects to https. Otherwise it binds
gateway.grpcPort, as before. The Service keeps gateway.grpcPort either way.
*/}}
{{- define "openshell-driver-kyma.gatewayBindPort" -}}
{{- if include "openshell-driver-kyma.serviceHostsEnabled" . -}}80{{- else -}}{{ .Values.gateway.grpcPort }}{{- end -}}
{{- end -}}

{{/*
Name prefix of the policies rendered into gatewayIngress.ingressNamespace. It
carries the release namespace, so two releases never collide there.
*/}}
{{- define "openshell-driver-kyma.gatewayIngressPolicyPrefix" -}}
{{- printf "%s-%s" .Release.Namespace (include "openshell-driver-kyma.fullname" .) -}}
{{- end -}}

{{/*
OIDC role settings upstream would refuse or that contradict each other. Upstream
defaults --oidc-admin-role and --oidc-user-role to openshell-admin and
openshell-user and rejects a gateway with exactly one of them empty
(openshell-server src/auth/authz.rs AuthzPolicy::validate at the pinned tag).
*/}}
{{- define "openshell-driver-kyma.gatewayOidcGuards" -}}
{{- $oidc := .Values.gateway.oidc -}}
{{- if and $oidc.authOnly (or $oidc.adminRole $oidc.userRole) -}}
{{- fail "gateway.oidc.authOnly=true cannot be combined with gateway.oidc.adminRole or gateway.oidc.userRole: authOnly accepts every authenticated identity, roles restrict them. Set one or the other." -}}
{{- end -}}
{{- if ne (empty $oidc.adminRole) (empty $oidc.userRole) -}}
{{- fail "gateway.oidc.adminRole and gateway.oidc.userRole must be set together: upstream refuses a gateway with only one of them (both for RBAC, or neither)." -}}
{{- end -}}
{{- end -}}

{{- define "openshell-driver-kyma.gatewayIngressGuards" -}}
{{- $oidc := .Values.gateway.oidc -}}
{{- $in := .Values.gatewayIngress -}}
{{- if $in.enabled -}}
{{- if not (and .Values.gateway.enabled .Values.gatewayService.enabled) -}}
{{- fail "gatewayIngress.enabled=true requires gateway.enabled=true and gatewayService.enabled=true: the VirtualService routes to this release's Service, which exposes the gateway's port only with gatewayService.enabled." -}}
{{- end -}}
{{- if not (and $oidc.issuer $oidc.audience $oidc.clientId) -}}
{{- fail "REFUSING to publish an unauthenticated gateway: gatewayIngress.enabled=true requires gateway.oidc.issuer, gateway.oidc.audience and gateway.oidc.clientId. Without OIDC the gateway accepts every caller, and anyone reaching the public host could create sandboxes." -}}
{{- end -}}
{{- if .Values.gateway.tls.enabled -}}
{{- fail "gatewayIngress.enabled=true cannot be combined with gateway.tls.enabled=true: the ingress gateway forwards plaintext HTTP/2 to the gateway pod. Set gateway.tls.enabled=false." -}}
{{- end -}}
{{- if not $in.domain -}}
{{- fail "gatewayIngress.enabled=true requires gatewayIngress.domain: the cluster's wildcard domain (the Kyma gateway's *.<domain>), without the leading \"*.\"." -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)+$" $in.domain) -}}
{{- fail (printf "gatewayIngress.domain %q is not a lowercase DNS name: give the domain alone, for example c-0000000.kyma.ondemand.com, without \"*.\", a scheme or a trailing dot." $in.domain) -}}
{{- end -}}
{{- $host := include "openshell-driver-kyma.gatewayIngressHost" . -}}
{{- $label := trimSuffix (printf ".%s" $in.domain) $host -}}
{{- if or (eq $label $host) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $label)) (contains "--" $label) -}}
{{- fail (printf "gatewayIngress.host %q must be one label under gatewayIngress.domain (<label>.%s) without \"--\": the Kyma gateway serves *.%s, and names with \"--\" are sandbox service hosts." $host $in.domain $in.domain) -}}
{{- end -}}
{{- range $in.allowedCidrs -}}
{{- if not (regexMatch "^(([0-9]{1,3}\\.){3}[0-9]{1,3}(/[0-9]{1,2})?|[0-9a-fA-F:]*:[0-9a-fA-F:]*(/[0-9]{1,3})?)$" (toString .)) -}}
{{- fail (printf "gatewayIngress.allowedCidrs entry %q is not an IP address or CIDR block (for example 203.0.113.0/24)." (toString .)) -}}
{{- end -}}
{{- end -}}
{{- if $in.serviceHosts.enabled -}}
{{- if not $in.allowedCidrs -}}
{{- fail "gatewayIngress.serviceHosts.enabled=true requires gatewayIngress.allowedCidrs: a browser request to a sandbox service URL carries no token, so the source address is the only fence." -}}
{{- end -}}
{{- if eq (int .Values.gateway.grpcPort) 80 -}}
{{- fail "gatewayIngress.serviceHosts.enabled=true cannot be combined with gateway.grpcPort=80: the Service's http-services port is 80." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
