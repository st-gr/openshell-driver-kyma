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
Name prefix of the policies rendered into gatewayIngress.ingressNamespace. It
carries the release namespace, so two releases never collide there.
*/}}
{{- define "openshell-driver-kyma.gatewayIngressPolicyPrefix" -}}
{{- printf "%s-%s" .Release.Namespace (include "openshell-driver-kyma.fullname" .) -}}
{{- end -}}

{{/*
The Secret in gatewayIngress.ingressNamespace that holds the chart CA's public
certificate. The ingress gateway verifies the gateway pod's certificate against it
(gateway-destinationrule.yaml); gateway-ingress-ca.yaml keeps it current.
*/}}
{{- define "openshell-driver-kyma.gatewayIngressCaSecretName" -}}
{{- printf "%s-gateway-ca" (include "openshell-driver-kyma.gatewayIngressPolicyPrefix" .) -}}
{{- end -}}

{{/*
The servers of Istio Gateways on the ingress gateway that are not HTTP: TCP, TLS,
and HTTPS in passthrough mode. Takes a dict with `gateways` (Gateway objects) and
`selector` (gatewayIngress.ingressSelector); a Gateway whose selector names another
value for one of the selector's labels belongs to another gateway deployment and is
skipped. Returns one line per server; scripts/ingress-non-http-servers.sh prints
the same lines from kubectl.
*/}}
{{- define "openshell-driver-kyma.nonHttpIngressServers" -}}
{{- $selector := .selector -}}
{{- $found := list -}}
{{- range $gateway := .gateways -}}
{{- $ours := true -}}
{{- range $key, $value := (default (dict) $gateway.spec.selector) -}}
{{- if and (hasKey $selector $key) (ne (toString (get $selector $key)) (toString $value)) -}}
{{- $ours = false -}}
{{- end -}}
{{- end -}}
{{- if $ours -}}
{{- range $server := (default (list) $gateway.spec.servers) -}}
{{- $port := default (dict) $server.port -}}
{{- $protocol := upper (toString (default "" $port.protocol)) -}}
{{- $mode := upper (toString (default "" (default (dict) $server.tls).mode)) -}}
{{- if or (not (has $protocol (list "HTTP" "HTTPS" "HTTP2" "GRPC" "GRPC-WEB"))) (has $mode (list "PASSTHROUGH" "AUTO_PASSTHROUGH")) -}}
{{- $found = append $found (printf "%s/%s port %v (%s%s)" $gateway.metadata.namespace $gateway.metadata.name $port.number $protocol (ternary (printf ", %s" $mode) "" (ne $mode ""))) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- join "\n" $found -}}
{{- end -}}

{{/*
OIDC role settings upstream would refuse or that contradict each other. Upstream
defaults --oidc-admin-role and --oidc-user-role to openshell-admin and
openshell-user and rejects a gateway with exactly one of them empty
(openshell-server src/auth/authz.rs AuthzPolicy::validate at the pinned tag).
*/}}
{{- define "openshell-driver-kyma.gatewayOidcGuards" -}}
{{- $oidc := .Values.gateway.oidc -}}
{{- /* A string is always true in a template: "false" would switch role checks off. */ -}}
{{- if not (kindIs "bool" $oidc.authOnly) -}}
{{- fail (printf "gateway.oidc.authOnly must be a boolean (true or false), got the %s %q." (kindOf $oidc.authOnly) (toString $oidc.authOnly)) -}}
{{- end -}}
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
{{- /* Removed in 0.10.0. Helm ignores unknown values, so a values file that still
enables it would render cleanly and drop the gateway's public route. */ -}}
{{- with .Values.gatewayApirule -}}
{{- if .enabled -}}
{{- fail "gatewayApirule was removed in 0.10.0, and gatewayApirule.enabled=true would silently drop the gateway's public route. Move to gatewayIngress (the values migration table in CHANGELOG.md) and remove the gatewayApirule block." -}}
{{- end -}}
{{- end -}}
{{- /* A string is always true in a template: "false" would publish the gateway. */ -}}
{{- if not (kindIs "bool" $in.enabled) -}}
{{- fail (printf "gatewayIngress.enabled must be a boolean (true or false), got the %s %q." (kindOf $in.enabled) (toString $in.enabled)) -}}
{{- end -}}
{{- if not (kindIs "bool" $in.serviceHosts.enabled) -}}
{{- fail (printf "gatewayIngress.serviceHosts.enabled must be a boolean (true or false), got the %s %q." (kindOf $in.serviceHosts.enabled) (toString $in.serviceHosts.enabled)) -}}
{{- end -}}
{{- if $in.enabled -}}
{{- if not (has $in.policyAction (list "DENY" "ALLOW")) -}}
{{- fail (printf "gatewayIngress.policyAction %q must be DENY or ALLOW: DENY for an ingress gateway without ALLOW AuthorizationPolicies (the default), ALLOW for one that already allowlists per host." (toString $in.policyAction)) -}}
{{- end -}}
{{- if not (has $in.sourceAddress (list "connection" "forwarded")) -}}
{{- fail (printf "gatewayIngress.sourceAddress %q must be connection or forwarded: connection compares allowedCidrs with the address of the connection the ingress gateway accepted (the default), forwarded with the address Istio takes from X-Forwarded-For, for an ingress gateway behind an HTTP proxy." (toString $in.sourceAddress)) -}}
{{- end -}}
{{- /* The policies render into the ingress gateway's namespace, usually the mesh's
root namespace, where a policy without a selector applies to every workload. */ -}}
{{- if not (and (kindIs "map" $in.ingressSelector) $in.ingressSelector) -}}
{{- fail "gatewayIngress.ingressSelector must be a non-empty map of the ingress gateway's pod labels (for example istio: ingressgateway): a policy without a selector in the mesh's root namespace would apply to every workload." -}}
{{- end -}}
{{- if not $in.ingressNamespace -}}
{{- fail "gatewayIngress.ingressNamespace must name the namespace of the Istio ingress gateway (for example istio-system)." -}}
{{- end -}}
{{- if not $in.istioGateway -}}
{{- fail "gatewayIngress.istioGateway must name the Istio Gateway the routes attach to, as <namespace>/<name> (for example kyma-system/kyma-gateway)." -}}
{{- end -}}
{{- if not (and .Values.gateway.enabled .Values.gatewayService.enabled) -}}
{{- fail "gatewayIngress.enabled=true requires gateway.enabled=true and gatewayService.enabled=true: the VirtualService routes to this release's Service, which exposes the gateway's port only with gatewayService.enabled." -}}
{{- end -}}
{{- if not (and $oidc.issuer $oidc.audience $oidc.clientId) -}}
{{- fail "REFUSING to publish an unauthenticated gateway: gatewayIngress.enabled=true requires gateway.oidc.issuer, gateway.oidc.audience and gateway.oidc.clientId. Without OIDC the gateway accepts every caller, and anyone reaching the public host could create sandboxes." -}}
{{- end -}}
{{- /* Upstream's shape for a gateway behind a TLS-terminating proxy that re-encrypts
(its chart's grpcRoute.backendTLSPolicy): the gateway serves TLS and takes no client
certificate, because the proxy has none to present. */ -}}
{{- if not .Values.gateway.tls.enabled -}}
{{- fail "gatewayIngress.enabled=true requires gateway.tls.enabled=true: the gateway terminates TLS itself and the ingress gateway re-encrypts to it, so the hop into the pod is encrypted and the service URLs the gateway reports are https. An install from before 0.10.0 must regenerate its PKI first (CHANGELOG.md, 0.10.0 upgrade note)." -}}
{{- end -}}
{{- if .Values.gateway.tls.clientCa.enabled -}}
{{- fail "gatewayIngress.enabled=true cannot be combined with gateway.tls.clientCa.enabled=true: the ingress gateway presents no client certificate to the gateway. Callers authenticate with OIDC." -}}
{{- end -}}
{{- if not $in.caHook.image -}}
{{- fail "gatewayIngress.enabled=true requires gatewayIngress.caHook.image: the image (a shell, base64 and kubectl) of the Job that copies the chart CA's public certificate into gatewayIngress.ingressNamespace." -}}
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
{{- /* A DENY rule is matched by host only on HTTP servers. For a TCP or TLS-passthrough
server Istio builds the rule without its hosts (an HTTP-only field) and keeps the source
addresses, so the fence would refuse every connection to that server from outside
allowedCidrs, whatever application it belongs to. ALLOW rules with HTTP-only fields are
skipped there. lookup returns nothing without a cluster (helm template); there the
operator has to check, with scripts/ingress-non-http-servers.sh. */ -}}
{{- if and (eq $in.policyAction "DENY") $in.allowedCidrs -}}
{{- $gateways := (lookup "networking.istio.io/v1" "Gateway" "" "") -}}
{{- $servers := include "openshell-driver-kyma.nonHttpIngressServers" (dict "gateways" (default (list) $gateways.items) "selector" $in.ingressSelector) -}}
{{- if $servers -}}
{{- fail (printf "gatewayIngress.policyAction=DENY with gatewayIngress.allowedCidrs cannot be installed on this ingress gateway. It has servers that are not HTTP, and Istio applies a DENY policy to those without its host condition: every connection to them from outside allowedCidrs would be refused.\n%s\nUse policyAction=ALLOW if the ingress gateway already allowlists per host; otherwise leave allowedCidrs and serviceHosts unset." $servers) -}}
{{- end -}}
{{- end -}}
{{- if $in.serviceHosts.enabled -}}
{{- if not $in.allowedCidrs -}}
{{- fail "gatewayIngress.serviceHosts.enabled=true requires gatewayIngress.allowedCidrs: a browser request to a sandbox service URL carries no token, so the source address is the only fence." -}}
{{- end -}}
{{- if eq (int .Values.gateway.grpcPort) 80 -}}
{{- fail "gatewayIngress.serviceHosts.enabled=true cannot be combined with gateway.grpcPort=80: the Service's http-services port is 80." -}}
{{- end -}}
{{- if not (and (kindIs "slice" $in.serviceHosts.workspaces) $in.serviceHosts.workspaces) -}}
{{- fail "gatewayIngress.serviceHosts.enabled=true requires gatewayIngress.serviceHosts.workspaces: the workspaces whose sandbox service URLs are published (for example [default]). Routes and policies match their hosts as <workspace>--*, never the whole domain." -}}
{{- end -}}
{{- range $in.serviceHosts.workspaces -}}
{{- if or (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" (toString .))) (contains "--" (toString .)) -}}
{{- fail (printf "gatewayIngress.serviceHosts.workspaces entry %q is not a workspace name: lowercase letters, digits and single hyphens." (toString .)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
