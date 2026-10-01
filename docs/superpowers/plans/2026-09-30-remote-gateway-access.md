# Remote Gateway Access Implementation Plan

> **Superseded.** This plan implemented revision 1 of the design, which was withdrawn (it put a `RequestAuthentication` on a shared ingress gateway). See `2026-10-01-remote-gateway-access-rev2.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the OpenShell gateway of a Kyma cluster through the cluster's Istio ingress gateway with OIDC, so the CLI and `openshell service expose` URLs work without a `kubectl port-forward` (chart/driver 0.10.0).

**Architecture:** A new `gatewayIngress` chart block renders two `VirtualService`s in the release namespace and a `RequestAuthentication` plus ALLOW `AuthorizationPolicy`s on the ingress gateway in `istio-system`; it replaces the unverified `gatewayApirule`. The gateway stays plaintext in the pod and validates the same OIDC token the edge validated. With published service hosts the gateway binds port 80 (safe sysctl) and learns the service domain from `--server-san`, so the URLs it prints are correct. The provider hook Job authenticates with the OIDC client-credentials grant.

**Tech Stack:** Helm 3 templates (Sprig), Istio `networking.istio.io/v1` and `security.istio.io/v1`, bash + Python 3 (PyYAML) render checks, Docker (pinned upstream gateway image), upstream `openshell` CLI v0.1.2. No Rust changes besides the version number.

**Spec:** `docs/superpowers/specs/2026-09-30-remote-gateway-access-design.md`

## Global Constraints

- Work on branch `feat/remote-gateway-access`, created from `docs/remote-gateway-access` (which holds the spec and this plan on top of `main` at v0.9.1).
- Never write a real cluster domain, IAS tenant, client id, CIDR or secret into any file, commit, log or subagent prompt. Fixtures use exactly: domain `example.org`, issuer `https://issuer.example`, client id and audience `osh-client`, CIDRs `203.0.113.0/24` and `2001:db8::/32`, Secret name `oidc-client`.
- Local helm runs with `KUBECONFIG=/dev/null`. Subagents never run `helm install`/`upgrade` or `kubectl` against a cluster.
- Rust is built and tested only in the dev container: `make fmt && make test` (the host has no toolchain). The only Rust-side change is the version in `Cargo.toml`; `make test` updates `Cargo.lock`.
- Exact names, used verbatim everywhere: values block `gatewayIngress` with keys `enabled`, `domain`, `host`, `istioGateway`, `ingressNamespace`, `ingressSelector`, `allowedCidrs`, `serviceHosts.enabled`; `gateway.oidc` keys `issuer`, `audience`, `clientId`, `jwksUri`, `authOnly`, `rolesClaim`, `adminRole`, `userRole`, `clientCredentialsSecret.name`, `clientCredentialsSecret.key` (default `client-secret`); helpers `openshell-driver-kyma.gatewayIngressHost`, `.serviceHostsEnabled`, `.gatewayBindPort`, `.gatewayIngressPolicyPrefix`, `.gatewayIngressGuards`, `.gatewayOidcGuards`; Service port `http-services` = 80 → `targetPort: grpc`; sysctl `net.ipv4.ip_unprivileged_port_start` = `"0"`; API versions `networking.istio.io/v1` and `security.istio.io/v1`.
- Resource names: VirtualServices `<fullname>-gateway` and `<fullname>-sandbox-services` (release namespace); in `gatewayIngress.ingressNamespace`: `<release-namespace>-<fullname>-openshell-jwt`, `-openshell-cli`, `-openshell-services`.
- `scripts/check-chart-render.sh` must end with `CHART_RENDER_OK`, `scripts/check-gateway-config.sh` with `GATEWAY_CONFIG_ACCEPTED`, `helm lint deploy/helm/openshell-driver-kyma` with `0 chart(s) failed`.
- Commit as the repository's configured identity (pass no `-c user.email`); inspect `git diff --cached` before every commit; end commit messages with `Co-Authored-By: <the committing model's name> <noreply@anthropic.com>`.
- Version: `0.10.0` (Cargo workspace, chart `version` and `appVersion`, doc pins).
- `scripts/check-chart-render.sh` is already 944 lines; this plan adds a check 8 to it in the file's existing style and does not restructure it.

## Review Focus

1. The operator already sets `podSecurityContext.sysctls` → the chart's sysctl is appended, the operator's entries survive (Task 2, `good-8-long-names`).
2. `gatewayIngress.domain` typed as `*.example.org`, `Example.org`, with a scheme or a trailing dot → the render fails naming the value (Task 1, `bad-8-wildcard-domain`, `bad-8-upper-domain`).
3. An `allowedCidrs` entry that is not an address or CIDR (`office`) → the render fails instead of Istio rejecting the policy during install (Task 1, `bad-8-cidr`).
4. Two releases in different namespaces with remote access on → their `istio-system` policies have different names (Task 3, `good-8-long-names` renders in another namespace).
5. `gatewayIngress.host` outside the domain, two labels deep, or shaped like a sandbox service host (`a--b`) → the render fails: Kyma's wildcard certificate and gateway only cover `<label>.<domain>` (Task 1, `bad-8-host-*`).

---

### Task 1: `gatewayIngress` values, helpers and render guards; remove `gatewayApirule`

**Files:**
- Create: `deploy/helm/openshell-driver-kyma/templates/_gateway-ingress.tpl`
- Delete: `deploy/helm/openshell-driver-kyma/templates/gateway-apirule.yaml`
- Modify: `deploy/helm/openshell-driver-kyma/values.yaml` (the `gateway.oidc` block, the `gateway.tls` comment, the `gatewayApirule` block)
- Modify: `deploy/helm/openshell-driver-kyma/values.example.yaml` (the `gatewayApirule` block)
- Modify: `deploy/helm/openshell-driver-kyma/templates/deployment.yaml:1-7` (guard includes)
- Modify: `deploy/helm/openshell-driver-kyma/templates/_inference-provider-guards.tpl:3` (comment)
- Modify: `.github/workflows/helm-lint.yml` (one render step)
- Test: `scripts/check-chart-render.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: the values keys and the six helpers named in Global Constraints. `gatewayIngressHost` returns the CLI host string; `serviceHostsEnabled` returns `true` or empty; `gatewayBindPort` returns `80` or `gateway.grpcPort` as a string; `gatewayIngressPolicyPrefix` returns `<release-namespace>-<fullname>`. Render fixtures `ingress_common` and `ingress_services` (bash arrays) and the render names `good-8-ingress`, `good-8-services`, `good-8-host`, `good-8-issuer-slash`, `good-8-long-names`, `good-8-rbac-roles`, `good-8-oidc-default-roles` in `scripts/check-chart-render.sh`, which Tasks 2-4 assert on.

- [ ] **Step 1: Add the failing render cases**

In `scripts/check-chart-render.sh`, insert this block immediately before the line `# 4 and 5. Renders for the NetworkPolicy and RBAC checks. Named rbac-*, so check 2's` (continuation lines start with a TAB, like the rest of the file):

```bash
# 8. Remote access (gatewayIngress): the gateway published through the cluster's Istio
# ingress gateway. The names start with good-8/bad-8, so checks 4 and 5 (r*.yaml) skip them.
ingress_common=(--set gatewayIngress.enabled=true --set gatewayIngress.domain=example.org
	--set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=osh-client
	--set gateway.oidc.clientId=osh-client --set gateway.oidc.authOnly=true)
ingress_services=(--set gatewayIngress.serviceHosts.enabled=true
	--set-json 'gatewayIngress.allowedCidrs=["203.0.113.0/24","2001:db8::/32"]')
try good-8-ingress '' t "${ingress_common[@]}"
try good-8-services '' t "${ingress_common[@]}" "${ingress_services[@]}"
try good-8-host '' t "${ingress_common[@]}" --set gatewayIngress.host=osh.example.org \
	--set gateway.oidc.jwksUri=https://issuer.example/oauth2/certs
# The issuer reaches the policies verbatim, a trailing slash included.
try good-8-issuer-slash '' t "${ingress_common[@]}" --set gateway.oidc.issuer=https://issuer.example/
# Another release name and namespace, and pod sysctls the operator already sets.
try good-8-long-names '' prod-sandboxes "${ingress_common[@]}" "${ingress_services[@]}" \
	--namespace a-rather-long-release-namespace-name \
	--set-json 'podSecurityContext.sysctls=[{"name":"net.ipv4.ping_group_range","value":"0 0"}]'
# RBAC roles instead of authentication-only, and an issuer with neither (upstream's defaults).
try good-8-rbac-roles '' t "${ingress_common[@]}" --set gateway.oidc.authOnly=false \
	--set gateway.oidc.rolesClaim=groups --set gateway.oidc.adminRole=osh-admin --set gateway.oidc.userRole=osh-user
try good-8-oidc-default-roles '' t --set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=osh-client
try bad-8-no-oidc 'REFUSING to publish an unauthenticated gateway' t --set gatewayIngress.enabled=true \
	--set gatewayIngress.domain=example.org
try bad-8-no-client-id 'gateway.oidc.clientId' t "${ingress_common[@]}" --set gateway.oidc.clientId=
try bad-8-no-service 'gatewayService.enabled' t "${ingress_common[@]}" --set gatewayService.enabled=false \
	--set driver.gatewayEndpoint=http://gateway.example:8080
try bad-8-no-domain 'gatewayIngress.domain' t "${ingress_common[@]}" --set gatewayIngress.domain=
try bad-8-wildcard-domain '*.example.org' t "${ingress_common[@]}" --set 'gatewayIngress.domain=*.example.org'
try bad-8-upper-domain 'Example.org' t "${ingress_common[@]}" --set gatewayIngress.domain=Example.org
try bad-8-dot-domain 'example.org.' t "${ingress_common[@]}" --set gatewayIngress.domain=example.org.
try bad-8-host-elsewhere 'openshell.other.org' t "${ingress_common[@]}" --set gatewayIngress.host=openshell.other.org
try bad-8-host-two-labels 'a.b.example.org' t "${ingress_common[@]}" --set gatewayIngress.host=a.b.example.org
try bad-8-host-service-shape 'a--b.example.org' t "${ingress_common[@]}" --set gatewayIngress.host=a--b.example.org
try bad-8-tls 'gateway.tls.enabled' t "${ingress_common[@]}" --set gateway.tls.enabled=true
try bad-8-services-no-cidrs 'gatewayIngress.allowedCidrs' t "${ingress_common[@]}" \
	--set gatewayIngress.serviceHosts.enabled=true
try bad-8-cidr 'office' t "${ingress_common[@]}" --set-json 'gatewayIngress.allowedCidrs=["office"]'
try bad-8-services-port-80 'gateway.grpcPort=80' t "${ingress_common[@]}" "${ingress_services[@]}" \
	--set gateway.grpcPort=80
try bad-8-one-role 'must be set together' t --set gateway.oidc.issuer=https://issuer.example \
	--set gateway.oidc.audience=osh-client --set gateway.oidc.adminRole=osh-admin
try bad-8-auth-only-with-roles 'gateway.oidc.authOnly' t --set gateway.oidc.issuer=https://issuer.example \
	--set gateway.oidc.audience=osh-client --set gateway.oidc.authOnly=true \
	--set gateway.oidc.adminRole=osh-admin --set gateway.oidc.userRole=osh-user

```

In the Python part of the same file, insert this block immediately before the line `if failures:` near the end:

```python
# 8. Remote access. The refused values are the bad-8-* cases (checked with the other
# bad-* cases above); these renders must succeed, and the removed APIRule is gone.
INGRESS_RENDERS = ("good-8-ingress", "good-8-services", "good-8-host", "good-8-issuer-slash",
                   "good-8-long-names", "good-8-rbac-roles", "good-8-oidc-default-roles")
for name in INGRESS_RENDERS:
    rendered(name)

def succeeded(name):
    return (work / f"{name}.rc").read_text() == "0"

if "gatewayApirule" in (yaml.safe_load(values) or {}):
    failures.append("values.yaml still has the removed gatewayApirule block")
if (chart / "templates" / "gateway-apirule.yaml").exists():
    failures.append("templates/gateway-apirule.yaml still exists; gatewayIngress replaces it")
if "gatewayIngress" not in (yaml.safe_load(values) or {}):
    failures.append("values.yaml has no gatewayIngress block")

```

Also extend the header comment of the script: after the paragraph of item `7.` (the line ending `never echoing credentials.`), add:

```bash
#   8. remote access (gatewayIngress): values that cannot work (no OIDC, no domain, a
#      host outside it, gateway TLS, service hosts without an allowlist, a malformed
#      CIDR, one OIDC role without the other) fail the render; the gateway's listener,
#      Service and NetworkPolicy follow the bind port; the Istio routes and policies
#      are exactly the documented ones, in the ingress gateway's namespace; and the
#      provider hook authenticates with the client-credentials grant under OIDC.
```

- [ ] **Step 2: Run the check and see it fail**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -30`
Expected: `CHART_RENDER_FAIL:` listing, among others, `bad-8-no-oidc: rendered, but the driver or upstream would refuse it at startup` (unknown values are ignored today, so every `bad-8-*` case renders), `values.yaml still has the removed gatewayApirule block`, `templates/gateway-apirule.yaml still exists; gatewayIngress replaces it` and `values.yaml has no gatewayIngress block`.

- [ ] **Step 3: Write the helpers and guards**

Create `deploy/helm/openshell-driver-kyma/templates/_gateway-ingress.tpl`:

```yaml
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
```

In `deploy/helm/openshell-driver-kyma/templates/deployment.yaml`, add two lines after `{{- include "openshell-driver-kyma.gatewayGuards" . -}}`:

```yaml
{{- include "openshell-driver-kyma.gatewayOidcGuards" . -}}
{{- include "openshell-driver-kyma.gatewayIngressGuards" . -}}
```

Delete the old template: `git rm deploy/helm/openshell-driver-kyma/templates/gateway-apirule.yaml`

In `deploy/helm/openshell-driver-kyma/templates/_inference-provider-guards.tpl`, line 3, replace `Mirrors the gateway-apirule.yaml `{{- fail -}}` style: when an opt-in` with `Uses the chart's `{{- fail -}}` style: when an opt-in`.

- [ ] **Step 4: Write the values**

In `deploy/helm/openshell-driver-kyma/values.yaml`, replace the `oidc:` block of `gateway` (the comment above it and the four keys) with:

```yaml
  # OIDC for client auth (the openshell CLI authenticates via OIDC).
  # Independent of TLS: configure both, neither, or either alone. With an
  # issuer every caller needs a bearer token, the chart's provider hook
  # included: inferenceProvider.enabled then requires clientId and
  # clientCredentialsSecret (docs/production-deployment.md).
  oidc:
    issuer: ""
    audience: ""              # the token's `aud`; for SAP IAS the client id
    # The OIDC client the CLI logs in with (`openshell gateway add --oidc-client-id`),
    # also used by the provider hook's client-credentials grant.
    clientId: ""
    # JWKS URL for the ingress gateway's RequestAuthentication (gatewayIngress).
    # Empty lets Istio discover it from the issuer; the gateway always does.
    jwksUri: ""
    # Authorization. Upstream defaults the roles to `openshell-admin` and
    # `openshell-user`, read from the `realm_access.roles` claim, so with the
    # three values below empty a token needs those roles. Either
    #   - set authOnly: true to accept every identity the issuer authenticates
    #     (upstream's authentication-only mode; both roles are passed empty), or
    #   - set rolesClaim (for example `groups`), adminRole and userRole.
    # adminRole and userRole must be set together.
    authOnly: false
    rolesClaim: ""
    adminRole: ""
    userRole: ""
    # A Secret you manage in .Release.Namespace holding the OIDC client secret,
    # for the provider hook's client-credentials grant. The chart never reads it.
    clientCredentialsSecret:
      name: ""
      key: client-secret
```

In the `gateway.tls` comment of the same file, replace `# (e.g. Kyma APIRule + kyma-gateway), or for fully-trusted local dev.` with `# (gatewayIngress and the Kyma gateway), or for fully-trusted local dev.`.

Replace the whole `gatewayApirule` block (from the comment line `# Kyma APIRule for external access. Requires .Values.gatewayService.enabled.` through the line `        authentications: []`) with:

```yaml
# Remote access: publish the gateway through the cluster's Istio ingress gateway
# (the Kyma gateway), so the openshell CLI and sandbox service URLs work without a
# port-forward. Requires gateway.enabled, gatewayService.enabled and
# gateway.oidc.{issuer,audience,clientId}: the chart refuses to publish an
# unauthenticated gateway. Sandbox pods are never published; upstream's sandbox
# runtime accepts inbound connections only through the gateway's relay.
#
# Renders, in the release namespace, a VirtualService for `host`, and in
# `ingressNamespace` a RequestAuthentication (the issuer's tokens) and an ALLOW
# AuthorizationPolicy for `host` that requires such a token. Installing with this
# block enabled therefore needs rights in `ingressNamespace`.
gatewayIngress:
  enabled: false
  # The cluster's wildcard domain, without "*." (the Kyma gateway serves
  # *.<domain>), e.g. c-0000000.kyma.ondemand.com. Never commit a real one.
  domain: ""
  # Host of the gateway API. Empty = openshell.<domain>. One label under `domain`.
  host: ""
  istioGateway: kyma-system/kyma-gateway
  # Namespace and labels of the Istio ingress gateway the policies select.
  ingressNamespace: istio-system
  ingressSelector:
    istio: ingressgateway
  # Source addresses or CIDR blocks (Istio remoteIpBlocks). Optional extra fence
  # for `host`; required for serviceHosts.
  allowedCidrs: []
  # Publish the URLs `openshell service expose` prints, as
  # http://<workspace>--<sandbox>[--<service>].<domain>/ (redirected to https).
  # A browser sends no token, so these hosts are fenced by allowedCidrs only, and
  # Istio's host matching takes only a prefix wildcard: the policy admits
  # allowedCidrs to EVERY host under `domain`, not only to sandbox service hosts.
  # With this on, the gateway binds port 80 in the pod (the pod gets the safe
  # sysctl net.ipv4.ip_unprivileged_port_start=0) so the URLs carry no port.
  serviceHosts:
    enabled: false

```

In `deploy/helm/openshell-driver-kyma/values.example.yaml`, replace the block from the line `# ─── Gateway APIRule (Kyma) ───────────────────────────────────────────────` through the line `        #     jwksUri: https://my-tenant.accounts.ondemand.com/oauth2/certs` with:

```yaml
# ─── Remote access (Kyma ingress) ─────────────────────────────────────────
# Publishes the gateway through the cluster's Istio ingress gateway. Refused
# unless gateway.oidc.{issuer,audience,clientId} are set (the chart never
# publishes an unauthenticated gateway). See docs/production-deployment.md.
gatewayIngress:
  enabled: false
  domain: ""               # e.g. your-cluster-id.kyma.ondemand.com
  allowedCidrs: []         # e.g. ["203.0.113.0/24"]; required for serviceHosts
  serviceHosts:
    enabled: false
```

- [ ] **Step 5: Run the checks and see them pass**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -5`
Expected: `CHART_RENDER_OK`

Run: `KUBECONFIG=/dev/null helm lint deploy/helm/openshell-driver-kyma | tail -1`
Expected: `1 chart(s) linted, 0 chart(s) failed`

Run: `grep -rn "gatewayApirule" deploy/ scripts/ .github/ | grep -v "check-chart-render.sh"`
Expected: no output.

- [ ] **Step 6: Render the block in the lint workflow**

In `.github/workflows/helm-lint.yml`, add this step after the step named `helm template (all flags on)`:

```yaml
      - name: helm template (remote access on)
        run: |
          helm template openshell-driver-kyma deploy/helm/openshell-driver-kyma \
            --set gateway.enabled=true \
            --set gateway.sandboxJwt.enabled=true \
            --set gatewayService.enabled=true \
            --set gatewayIngress.enabled=true \
            --set gatewayIngress.domain=example.org \
            --set gatewayIngress.serviceHosts.enabled=true \
            --set-json 'gatewayIngress.allowedCidrs=["203.0.113.0/24"]' \
            --set gateway.oidc.issuer=https://issuer.example \
            --set gateway.oidc.audience=osh-client \
            --set gateway.oidc.clientId=osh-client \
            --set gateway.oidc.authOnly=true \
            > /dev/null
```

Run the same command locally with `KUBECONFIG=/dev/null`; expected: exit status 0.

- [ ] **Step 7: Commit**

```bash
git add scripts/check-chart-render.sh .github/workflows/helm-lint.yml deploy/helm/openshell-driver-kyma
git diff --cached --stat
git commit -m "feat(chart)!: gatewayIngress values and guards replace gatewayApirule"
```

---

### Task 2: Gateway listener wiring (bind port, sysctl, service domain, OIDC role flags)

**Files:**
- Modify: `deploy/helm/openshell-driver-kyma/templates/deployment.yaml` (pod `securityContext`, gateway `args`, gateway `ports`)
- Modify: `deploy/helm/openshell-driver-kyma/templates/service.yaml`
- Modify: `deploy/helm/openshell-driver-kyma/templates/networkpolicy.yaml` (driver pod ingress ports)
- Modify: `scripts/check-gateway-config.sh`
- Test: `scripts/check-chart-render.sh`, `scripts/check-gateway-config.sh`

**Interfaces:**
- Consumes: helpers `openshell-driver-kyma.gatewayBindPort` (string `80` or `gateway.grpcPort`) and `openshell-driver-kyma.serviceHostsEnabled` (`true` or empty); values `gateway.oidc.authOnly`, `rolesClaim`, `adminRole`, `userRole`; renders `good-8-*` and Python helper `succeeded(name)` from Task 1.
- Produces: the gateway container's `--port`, `--server-san`, `--oidc-*` flags, the Service port `http-services` (80 → `grpc`), Python helpers `gateway_parts(name)` and `flag(args, name)` that Task 3 and Task 4 reuse.

- [ ] **Step 1: Add the failing assertions**

In the Python part of `scripts/check-chart-render.sh`, insert after the block Task 1 added (still before `if failures:`):

```python
def gateway_parts(name):
    """(gateway container, pod spec, the release's Service, the driver pod's NetworkPolicy)."""
    documents = docs(work / f"{name}.yaml")
    pod = driver_deployment(documents, name)["spec"]["template"]["spec"]
    gateway = next(c for c in pod["containers"] if c["name"] == "gateway")
    service = next(d for d in documents if d.get("kind") == "Service"
                   and any(p["name"] == "grpc" for p in d["spec"]["ports"]))
    policy = next((d for d in documents if d.get("kind") == "NetworkPolicy"
                   and d["metadata"]["name"].endswith("-driver")), None)
    return gateway, pod, service, policy

def flag(args, name):
    """The values of every occurrence of a gateway flag."""
    return [args[i + 1] for i, a in enumerate(args) if a == name and i + 1 < len(args)]

# The gateway's listener. Upstream prints a service URL with the bind port unless it is
# http on 80, so with published service hosts the gateway binds 80 (which a non-root
# container may only do with the unprivileged-port sysctl) and takes the service domain
# from a wildcard --server-san; the Service adds an http-* port on the same listener.
UNPRIVILEGED_PORTS = {"name": "net.ipv4.ip_unprivileged_port_start", "value": "0"}
OPERATOR_SYSCTL = {"name": "net.ipv4.ping_group_range", "value": "0 0"}
LISTENER = {  # render -> (bind port, pod sysctls, --server-san, Service ports on the listener)
    "render-shared-true": (8080, None, [], {"grpc": 8080}),
    "good-8-ingress": (8080, None, [], {"grpc": 8080}),
    "good-8-services": (80, [UNPRIVILEGED_PORTS], ["*.example.org"], {"grpc": 8080, "http-services": 80}),
    "good-8-long-names": (80, [OPERATOR_SYSCTL, UNPRIVILEGED_PORTS], ["*.example.org"],
                          {"grpc": 8080, "http-services": 80}),
}
for name, (port, sysctls, sans, service_ports) in LISTENER.items():
    if name != "render-shared-true" and not succeeded(name):
        continue
    gateway, pod, service, policy = gateway_parts(name)
    args = gateway["args"]
    got = (flag(args, "--port"), (pod.get("securityContext") or {}).get("sysctls"), flag(args, "--server-san"),
           [p["containerPort"] for p in gateway["ports"] if p["name"] == "grpc"])
    if got != ([str(port)], sysctls, sans, [port]):
        failures.append(f"{name}: gateway (--port, pod sysctls, --server-san, grpc containerPort) is {got}, "
                        f"want {([str(port)], sysctls, sans, [port])}")
    ports = {p["name"]: (p["port"], p["targetPort"]) for p in service["spec"]["ports"]
             if p["name"] in ("grpc", "http-services")}
    if ports != {n: (p, "grpc") for n, p in service_ports.items()}:
        failures.append(f"{name}: the Service's listener ports are {ports}, want {service_ports} -> grpc")
    allowed = [p["port"] for p in policy["spec"]["ingress"][0]["ports"]] if policy else []
    if port not in allowed or (port != 8080 and 8080 in allowed):
        failures.append(f"{name}: the driver pod's NetworkPolicy admits ports {allowed}, "
                        f"which must include the gateway's bind port {port} and no stale 8080")

# OIDC authorization flags. Upstream defaults the roles to openshell-admin/openshell-user,
# so authentication-only mode needs both passed empty; without authOnly or roles the
# chart passes neither and upstream's defaults apply.
OIDC_FLAGS = {  # render -> (--oidc-roles-claim, --oidc-admin-role, --oidc-user-role)
    "good-8-ingress": ([], [""], [""]),
    "good-8-rbac-roles": (["groups"], ["osh-admin"], ["osh-user"]),
    "good-8-oidc-default-roles": ([], [], []),
}
for name, want in OIDC_FLAGS.items():
    if not succeeded(name):
        continue
    args = gateway_parts(name)[0]["args"]
    got = (flag(args, "--oidc-roles-claim"), flag(args, "--oidc-admin-role"), flag(args, "--oidc-user-role"))
    if got != want or flag(args, "--oidc-issuer") != ["https://issuer.example"] \
            or flag(args, "--oidc-audience") != ["osh-client"]:
        failures.append(f"{name}: gateway OIDC flags (roles claim, admin role, user role) are {got}, want {want}, "
                        f"with issuer {flag(args, '--oidc-issuer')} and audience {flag(args, '--oidc-audience')}")

```

- [ ] **Step 2: Run the check and see it fail**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -12`
Expected: `CHART_RENDER_FAIL:` with `good-8-services: gateway (--port, pod sysctls, --server-san, grpc containerPort) is (['8080'], None, [], [8080]), want (['80'], …)`, `good-8-services: the Service's listener ports are {'grpc': (8080, 'grpc')}, want …`, and `good-8-ingress: gateway OIDC flags (roles claim, admin role, user role) are ([], [], []), want ([], [''], [''])`.

- [ ] **Step 3: Wire the deployment**

In `deploy/helm/openshell-driver-kyma/templates/deployment.yaml`:

Replace

```yaml
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      containers:
```

with

```yaml
      {{- $podSecurity := deepCopy .Values.podSecurityContext }}
      {{- if and .Values.gateway.enabled (lt (int (include "openshell-driver-kyma.gatewayBindPort" .)) 1024) }}
      {{- /* The gateway runs as a non-root user and binds a port below 1024. */}}
      {{- $_ := set $podSecurity "sysctls" (append (default (list) $podSecurity.sysctls) (dict "name" "net.ipv4.ip_unprivileged_port_start" "value" "0")) }}
      {{- end }}
      securityContext:
        {{- toYaml $podSecurity | nindent 8 }}
      containers:
```

Replace

```yaml
            - --port
            - {{ .Values.gateway.grpcPort | quote }}
```

with

```yaml
            - --port
            - {{ include "openshell-driver-kyma.gatewayBindPort" . | quote }}
```

Replace

```yaml
            {{- with $.Values.gateway.oidc.adminRole }}
            - --oidc-admin-role
            - {{ . | quote }}
            {{- end }}
            {{- with $.Values.gateway.oidc.userRole }}
            - --oidc-user-role
            - {{ . | quote }}
            {{- end }}
            {{- end }}
```

with

```yaml
            {{- with $.Values.gateway.oidc.rolesClaim }}
            - --oidc-roles-claim
            - {{ . | quote }}
            {{- end }}
            {{- if $.Values.gateway.oidc.authOnly }}
            # Authentication-only: upstream defaults the roles to openshell-admin and
            # openshell-user, so both are passed empty to switch role checks off.
            - --oidc-admin-role
            - ""
            - --oidc-user-role
            - ""
            {{- else }}
            {{- with $.Values.gateway.oidc.adminRole }}
            - --oidc-admin-role
            - {{ . | quote }}
            {{- end }}
            {{- with $.Values.gateway.oidc.userRole }}
            - --oidc-user-role
            - {{ . | quote }}
            {{- end }}
            {{- end }}
            {{- end }}
            {{- if include "openshell-driver-kyma.serviceHostsEnabled" . }}
            # A wildcard SAN is how upstream learns the domain of sandbox service
            # URLs (its default, openshell.localhost, stays available).
            - --server-san
            - {{ printf "*.%s" .Values.gatewayIngress.domain | quote }}
            {{- end }}
```

Replace

```yaml
            - name: grpc
              containerPort: {{ .Values.gateway.grpcPort }}
```

with

```yaml
            - name: grpc
              containerPort: {{ include "openshell-driver-kyma.gatewayBindPort" . }}
```

- [ ] **Step 4: Wire the Service and the NetworkPolicy**

In `deploy/helm/openshell-driver-kyma/templates/service.yaml`, replace

```yaml
      targetPort: grpc
      protocol: TCP
    - name: gw-health
```

with

```yaml
      targetPort: grpc
      protocol: TCP
    {{- if include "openshell-driver-kyma.serviceHostsEnabled" . }}
    # The same gateway listener under an http-* name: Istio then speaks HTTP/1.1 to
    # it for sandbox service URLs, which lets WebSocket upgrades through.
    - name: http-services
      port: 80
      targetPort: grpc
      protocol: TCP
    {{- end }}
    - name: gw-health
```

In `deploy/helm/openshell-driver-kyma/templates/networkpolicy.yaml`, replace

```yaml
        - port: {{ .Values.gateway.grpcPort }}
          protocol: TCP
        - port: {{ .Values.gateway.healthPort }}
```

with

```yaml
        - port: {{ include "openshell-driver-kyma.gatewayBindPort" . }}
          protocol: TCP
        - port: {{ .Values.gateway.healthPort }}
```

and in the comment at the top of that file replace `(so port-forward, sidecar mesh, or APIRule reverse proxy can` with `(so port-forward and the ingress gateway of gatewayIngress can`.

- [ ] **Step 5: Run the render check and see it pass**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -5`
Expected: `CHART_RENDER_OK`

- [ ] **Step 6: Prove the pinned gateway image knows every rendered flag**

`scripts/check-gateway-config.sh` today passes a fixed command line. Add a flag check: the gateway parses its flags before reading the config, and `--help` stops it right after parsing, so appending `--help` to the rendered args fails (exit status 2, `error: unexpected argument`) exactly when the image does not know a flag.

In `scripts/check-gateway-config.sh`, insert this block immediately before the line `rc=0` that precedes `out="$(docker run --rm -v "$WORK/gateway.toml:/etc/openshell/gateway.toml:ro" \`:

```bash
# The gateway's command line, as the chart renders it. Flags are parsed before the
# config is read and `--help` stops the gateway right after parsing, so appending it
# proves the pinned image knows every flag the chart passes: with the defaults, and
# with remote access on, the render that passes the most.
check_args() { # label [helm args...]
  local label=$1 rc=0 out line args=()
  shift
  helm template check "$CHART" \
    --set gateway.enabled=true \
    --set gateway.sandboxJwt.enabled=true \
    --set gatewayService.enabled=true \
    "$@" --show-only templates/deployment.yaml > "$WORK/args-deployment.yaml"
  python3 - "$WORK/args-deployment.yaml" > "$WORK/args.txt" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for c in doc["spec"]["template"]["spec"]["containers"]:
    if c["name"] == "gateway":
        print("\n".join(c["args"]))
        break
else:
    sys.exit("no gateway container in rendered Deployment")
PY
  while IFS= read -r line; do args+=("$line"); done < "$WORK/args.txt"
  out="$(docker run --rm --entrypoint openshell-gateway "$IMAGE" "${args[@]}" --help 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "GATEWAY_ARGS_REJECTED ($label, exit $rc)"
    head -5 <<<"$out"
    exit 1
  fi
  echo "GATEWAY_ARGS_ACCEPTED ($label, ${#args[@]} args)"
}
check_args defaults
check_args remote-access \
  --set gatewayIngress.enabled=true \
  --set gatewayIngress.domain=example.org \
  --set gatewayIngress.serviceHosts.enabled=true \
  --set-json 'gatewayIngress.allowedCidrs=["203.0.113.0/24"]' \
  --set gateway.oidc.issuer=https://issuer.example \
  --set gateway.oidc.audience=osh-client \
  --set gateway.oidc.clientId=osh-client \
  --set gateway.oidc.authOnly=true
check_args rbac-roles \
  --set gateway.oidc.issuer=https://issuer.example \
  --set gateway.oidc.audience=osh-client \
  --set gateway.oidc.rolesClaim=groups \
  --set gateway.oidc.adminRole=osh-admin \
  --set gateway.oidc.userRole=osh-user

```

Run: `KUBECONFIG=/dev/null ./scripts/check-gateway-config.sh 2>&1 | grep -E "GATEWAY_(ARGS|CONFIG)_"`
Expected:

```
GATEWAY_ARGS_ACCEPTED (defaults, 15 args)
GATEWAY_ARGS_ACCEPTED (remote-access, 25 args)
GATEWAY_ARGS_ACCEPTED (rbac-roles, 25 args)
GATEWAY_CONFIG_ACCEPTED
```

(The counts may differ by a few; three `GATEWAY_ARGS_ACCEPTED` lines and `GATEWAY_CONFIG_ACCEPTED` are what matters.) To see the check bite, temporarily change `--server-san` to `--server-sans` in `deployment.yaml`, re-run, expect `GATEWAY_ARGS_REJECTED (remote-access, exit 2)` and `error: unexpected argument '--server-sans' found`, then restore the file.

- [ ] **Step 7: Commit**

```bash
git add scripts/check-chart-render.sh scripts/check-gateway-config.sh deploy/helm/openshell-driver-kyma/templates
git diff --cached --stat
git commit -m "feat(chart): gateway binds 80 with published service hosts; explicit OIDC role flags"
```

---

### Task 3: Istio routes and ingress-gateway policies

**Files:**
- Create: `deploy/helm/openshell-driver-kyma/templates/gateway-virtualservice.yaml`
- Create: `deploy/helm/openshell-driver-kyma/templates/gateway-services-virtualservice.yaml`
- Create: `deploy/helm/openshell-driver-kyma/templates/gateway-ingress-auth.yaml`
- Test: `scripts/check-chart-render.sh`

**Interfaces:**
- Consumes: helpers `gatewayIngressHost`, `serviceHostsEnabled`, `gatewayIngressPolicyPrefix`, `gatewayIngressGuards`, `fullname`, `labels`; the Service port `http-services` (80) from Task 2; Python helpers `succeeded(name)` (Task 1) and `docs(path)`.
- Produces: the five objects named in Global Constraints. Nothing later depends on their internals.

- [ ] **Step 1: Add the failing assertions**

In the Python part of `scripts/check-chart-render.sh`, insert after Task 2's block (before `if failures:`):

```python
# The Istio objects. Routes live in the release namespace, policies on the ingress
# gateway in its own namespace, named for the release namespace so releases never collide.
INGRESS_KINDS = ("VirtualService", "RequestAuthentication", "AuthorizationPolicy")
SELECTOR = {"matchLabels": {"istio": "ingressgateway"}}
CIDRS = ["203.0.113.0/24", "2001:db8::/32"]
SERVICE_HOST = (r"^[a-z0-9]+(-[a-z0-9]+)*--[a-z0-9]+(-[a-z0-9]+)*(--[a-z0-9]+(-[a-z0-9]+)*)?"
                r"\.example\.org(:[0-9]+)?$")

def ingress_objects(name):
    return {(d["kind"], d["metadata"]["namespace"], d["metadata"]["name"]): d["spec"]
            for d in docs(work / f"{name}.yaml") if d.get("kind") in INGRESS_KINDS}

def route(service, port, match=None):
    rule = {"route": [{"destination": {"host": service, "port": {"number": port}}}], "timeout": "0s"}
    return [dict(match=[{"authority": {"regex": match}}], **rule) if match else rule]

def expected_ingress(release_ns, fullname, host, issuer, cidrs, services, jwks=None):
    service = f"{fullname}.{release_ns}.svc.cluster.local"
    prefix = f"{release_ns}-{fullname}"
    rule = {"issuer": issuer, "audiences": ["osh-client"], "forwardOriginalToken": True}
    if jwks:
        rule["jwksUri"] = jwks
    source = {"requestPrincipals": [issuer + "/*"]}
    if cidrs:
        source["remoteIpBlocks"] = cidrs
    want = {
        ("VirtualService", release_ns, f"{fullname}-gateway"): {
            "hosts": [host], "gateways": ["kyma-system/kyma-gateway"], "http": route(service, 8080)},
        ("RequestAuthentication", "istio-system", f"{prefix}-openshell-jwt"): {
            "selector": SELECTOR, "jwtRules": [rule]},
        ("AuthorizationPolicy", "istio-system", f"{prefix}-openshell-cli"): {
            "selector": SELECTOR, "action": "ALLOW",
            "rules": [{"from": [{"source": source}], "to": [{"operation": {"hosts": [host]}}]}]},
    }
    if services:
        want[("VirtualService", release_ns, f"{fullname}-sandbox-services")] = {
            "hosts": ["*.example.org"], "gateways": ["kyma-system/kyma-gateway"],
            "http": route(service, 80, SERVICE_HOST)}
        want[("AuthorizationPolicy", "istio-system", f"{prefix}-openshell-services")] = {
            "selector": SELECTOR, "action": "ALLOW",
            "rules": [{"from": [{"source": {"remoteIpBlocks": cidrs}}],
                       "to": [{"operation": {"hosts": ["*.example.org"]}}]}]}
    return want

T = ("default", "t-openshell-driver-kyma")   # helm template's namespace and the fullname of release t
INGRESS_OBJECTS = {
    "good-8-ingress": expected_ingress(*T, "openshell.example.org", "https://issuer.example", None, False),
    "good-8-services": expected_ingress(*T, "openshell.example.org", "https://issuer.example", CIDRS, True),
    "good-8-host": expected_ingress(*T, "osh.example.org", "https://issuer.example", None, False,
                                    jwks="https://issuer.example/oauth2/certs"),
    # The principal is the issuer verbatim plus "/*": Istio builds it as <iss>/<sub>.
    "good-8-issuer-slash": expected_ingress(*T, "openshell.example.org", "https://issuer.example/", None, False),
    "good-8-long-names": expected_ingress("a-rather-long-release-namespace-name", "prod-sandboxes-openshell-driver-kyma",
                                          "openshell.example.org", "https://issuer.example", CIDRS, True),
}
for name, want in INGRESS_OBJECTS.items():
    if not succeeded(name):
        continue
    got = ingress_objects(name)
    for key in sorted(set(got) | set(want)):
        if got.get(key) != want.get(key):
            failures.append(f"{name}: {'/'.join(key)} is {got.get(key)}, want {want.get(key)}")
# Nothing of it without gatewayIngress: not by default, and not with OIDC alone.
for name in ("render-shared-true", "good-8-oidc-default-roles"):
    stray = sorted("/".join(k) for k in ingress_objects(name))
    if stray:
        failures.append(f"{name}: gatewayIngress is off, but the chart rendered {stray}")
# The service-host pattern admits exactly <workspace>--<sandbox>[--<service>].<domain>.
service_host = re.compile(SERVICE_HOST)
for host, want in (("default--web.example.org", True), ("team-a--my-app--admin.example.org:443", True),
                   ("openshell.example.org", False), ("default--web.example.org.evil.test", False),
                   ("default--web-example.org", False), ("a--b--c--d.example.org", False),
                   ("-a--b.example.org", False), ("a--.example.org", False)):
    if bool(service_host.fullmatch(host)) != want:
        failures.append(f"the sandbox service host pattern {'rejects' if want else 'accepts'} {host!r}")

```

- [ ] **Step 2: Run the check and see it fail**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -12`
Expected: `CHART_RENDER_FAIL:` with lines such as `good-8-ingress: VirtualService/default/t-openshell-driver-kyma-gateway is None, want {'hosts': ['openshell.example.org'], …}` and `good-8-services: AuthorizationPolicy/istio-system/default-t-openshell-driver-kyma-openshell-services is None, want …`.

- [ ] **Step 3: Write the CLI route**

Create `deploy/helm/openshell-driver-kyma/templates/gateway-virtualservice.yaml`:

```yaml
{{- if .Values.gatewayIngress.enabled -}}
{{- include "openshell-driver-kyma.gatewayIngressGuards" . -}}
# The CLI's route: gRPC with an OIDC bearer, through the cluster's Istio ingress
# gateway to this release's gateway. gateway-ingress-auth.yaml holds the policies
# that admit it.
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: {{ include "openshell-driver-kyma.fullname" . }}-gateway
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
spec:
  hosts:
    - {{ include "openshell-driver-kyma.gatewayIngressHost" . | quote }}
  gateways:
    - {{ .Values.gatewayIngress.istioGateway | quote }}
  http:
    - route:
        - destination:
            host: {{ include "openshell-driver-kyma.fullname" . }}.{{ .Release.Namespace }}.svc.cluster.local
            port:
              number: {{ .Values.gateway.grpcPort }}
      # Streaming RPCs (WatchSandboxes, Exec, RelayStream) have no deadline.
      timeout: 0s
{{- end }}
```

- [ ] **Step 4: Write the sandbox-service route**

Create `deploy/helm/openshell-driver-kyma/templates/gateway-services-virtualservice.yaml`:

```yaml
{{- if include "openshell-driver-kyma.serviceHostsEnabled" . -}}
# Browser route for the URLs `openshell service expose` prints:
# <workspace>--<sandbox>[--<service>].<domain>. Only authorities of that shape are
# routed; an exact-host VirtualService of another application keeps precedence
# over this wildcard. The destination is the Service's http-services port, so the
# ingress gateway speaks HTTP/1.1 to the gateway and WebSocket upgrades pass.
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: {{ include "openshell-driver-kyma.fullname" . }}-sandbox-services
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
spec:
  hosts:
    - {{ printf "*.%s" .Values.gatewayIngress.domain | quote }}
  gateways:
    - {{ .Values.gatewayIngress.istioGateway | quote }}
  http:
    - match:
        - authority:
            regex: '^[a-z0-9]+(-[a-z0-9]+)*--[a-z0-9]+(-[a-z0-9]+)*(--[a-z0-9]+(-[a-z0-9]+)*)?\.{{ regexReplaceAll "\\." .Values.gatewayIngress.domain "\\." }}(:[0-9]+)?$'
      route:
        - destination:
            host: {{ include "openshell-driver-kyma.fullname" . }}.{{ .Release.Namespace }}.svc.cluster.local
            port:
              number: 80
      timeout: 0s
{{- end }}
```

- [ ] **Step 5: Write the ingress-gateway policies**

Create `deploy/helm/openshell-driver-kyma/templates/gateway-ingress-auth.yaml`:

```yaml
{{- if .Values.gatewayIngress.enabled -}}
{{- $prefix := include "openshell-driver-kyma.gatewayIngressPolicyPrefix" . -}}
{{- $in := .Values.gatewayIngress -}}
# Policies on the cluster's Istio ingress gateway, in its namespace. With any ALLOW
# policy on that gateway Istio denies what no rule allows, so these are also what
# lets the hosts through on a cluster that allowlists per host.
#
# The RequestAuthentication selects the whole ingress gateway: a request to any
# host that carries an invalid token of this issuer is answered 401 there.
# Requests without a token, or with another issuer's, are not affected.
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: {{ $prefix }}-openshell-jwt
  namespace: {{ $in.ingressNamespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- toYaml $in.ingressSelector | nindent 6 }}
  jwtRules:
    - issuer: {{ .Values.gateway.oidc.issuer | quote }}
      {{- with .Values.gateway.oidc.jwksUri }}
      jwksUri: {{ . | quote }}
      {{- end }}
      audiences:
        - {{ .Values.gateway.oidc.audience | quote }}
      # The gateway validates the same token again.
      forwardOriginalToken: true
---
# The CLI host: a valid token of the issuer and, when allowedCidrs is set, a
# source address in it.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: {{ $prefix }}-openshell-cli
  namespace: {{ $in.ingressNamespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- toYaml $in.ingressSelector | nindent 6 }}
  action: ALLOW
  rules:
    - from:
        - source:
            requestPrincipals:
              - {{ printf "%s/*" .Values.gateway.oidc.issuer | quote }}
            {{- with $in.allowedCidrs }}
            remoteIpBlocks:
              {{- toYaml . | nindent 14 }}
            {{- end }}
      to:
        - operation:
            hosts:
              - {{ include "openshell-driver-kyma.gatewayIngressHost" . | quote }}
{{- if $in.serviceHosts.enabled }}
---
# Sandbox service hosts: browsers carry no token, so the source address is the
# fence. Istio's hosts take only a prefix wildcard, so this admits allowedCidrs
# to every host under the domain, not only to sandbox service hosts.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: {{ $prefix }}-openshell-services
  namespace: {{ $in.ingressNamespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- toYaml $in.ingressSelector | nindent 6 }}
  action: ALLOW
  rules:
    - from:
        - source:
            remoteIpBlocks:
              {{- toYaml $in.allowedCidrs | nindent 14 }}
      to:
        - operation:
            hosts:
              - {{ printf "*.%s" $in.domain | quote }}
{{- end }}
{{- end }}
```

- [ ] **Step 6: Run the checks and see them pass**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -5`
Expected: `CHART_RENDER_OK`

Run: `KUBECONFIG=/dev/null helm lint deploy/helm/openshell-driver-kyma | tail -1`
Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 7: Commit**

```bash
git add scripts/check-chart-render.sh deploy/helm/openshell-driver-kyma/templates
git diff --cached --stat
git commit -m "feat(chart): Istio routes and ingress-gateway policies for gatewayIngress"
```

---

### Task 4: Provider hook Job authenticates with OIDC client credentials

**Files:**
- Modify: `deploy/helm/openshell-driver-kyma/templates/_inference-provider-guards.tpl:64-71` (the OIDC refusal)
- Modify: `deploy/helm/openshell-driver-kyma/templates/inference-provider-hook.yaml` (header comment, `env`, script)
- Modify: `deploy/helm/openshell-driver-kyma/templates/NOTES.txt`
- Test: `scripts/check-chart-render.sh`

**Interfaces:**
- Consumes: values `gateway.oidc.issuer`, `audience`, `clientId`, `clientCredentialsSecret.{name,key}`; helper `gatewayIngressHost`; bash helper `inference_try NAME EXPECT [helm args...]` and variables `inference_url`, `inference_common` already in `scripts/check-chart-render.sh`; Python helper `succeeded(name)`.
- Produces: render name `good-8-inference-oidc`. Upstream CLI behaviour relied on (source: `crates/openshell-cli/src/commands/gateway.rs` and `oidc_auth.rs` at v0.1.2): `openshell gateway add <url> --name N --oidc-issuer I --oidc-client-id C --oidc-audience A` registers an OIDC gateway whatever the URL scheme, and with `OPENSHELL_OIDC_CLIENT_SECRET` in the environment it obtains and stores a token with the client-credentials grant; later commands select the gateway with the global flag `--gateway N`. `--gateway-endpoint` bypasses the stored gateway and sends no token.

- [ ] **Step 1: Add the failing cases and assertions**

In the bash part of `scripts/check-chart-render.sh`, replace

```bash
inference_try bad-3h-inference-oidc 'gateway.oidc.issuer' --set "inferenceProvider.baseUrl=$inference_url" \
	--set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=openshell
```

with

```bash
# With OIDC the hook needs a client and its secret for the client-credentials grant.
inference_try bad-3h-inference-oidc 'gateway.oidc.clientCredentialsSecret.name' \
	--set "inferenceProvider.baseUrl=$inference_url" \
	--set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=osh-client \
	--set gateway.oidc.clientId=osh-client
inference_try bad-3h-inference-oidc-no-client 'gateway.oidc.clientId' \
	--set "inferenceProvider.baseUrl=$inference_url" \
	--set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=osh-client \
	--set gateway.oidc.clientCredentialsSecret.name=oidc-client
inference_try good-8-inference-oidc '' --set "inferenceProvider.baseUrl=$inference_url" \
	--set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=osh-client \
	--set gateway.oidc.clientId=osh-client --set gateway.oidc.clientCredentialsSecret.name=oidc-client
```

and in the header comment replace `the gateway's Service or against an OIDC or TLS gateway it cannot reach;` with `the gateway's Service, against a TLS gateway, or against an OIDC gateway without a client secret;`.

In the Python part, insert after Task 3's block (before `if failures:`):

```python
# The provider hook under OIDC: it registers the gateway once with the client-credentials
# grant and then addresses it by name. --gateway-endpoint bypasses the registered gateway
# and its token, so it must not appear; the client secret reaches the CLI only through
# its environment, from the operator's Secret.
def hook_of(name):
    job = next(d for d in docs(work / f"{name}.yaml") if d.get("kind") == "Job"
               and d["metadata"]["name"].endswith("-inference-provider-hook"))
    container = job["spec"]["template"]["spec"]["containers"][0]
    return container.get("env", []), container["command"][-1]

if rendered("good-8-inference-oidc") is not None:
    env, script = hook_of("good-8-inference-oidc")
    literal = {e["name"]: e.get("value") for e in env}
    for key, want in (("OPENSHELL_NO_BROWSER", "1"), ("OIDC_ISSUER", "https://issuer.example"),
                      ("OIDC_CLIENT_ID", "osh-client"), ("OIDC_AUDIENCE", "osh-client")):
        if literal.get(key) != want:
            failures.append(f"good-8-inference-oidc: hook env {key}={literal.get(key)!r}, want {want!r}")
    secret = [e for e in env if e["name"] == "OPENSHELL_OIDC_CLIENT_SECRET"]
    ref = (secret[0].get("valueFrom") or {}).get("secretKeyRef") if len(secret) == 1 else None
    if len(secret) != 1 or "value" in secret[0] or ref != {"name": "oidc-client", "key": "client-secret"}:
        failures.append("good-8-inference-oidc: OPENSHELL_OIDC_CLIENT_SECRET must be exactly one secretKeyRef "
                        f"to gateway.oidc.clientCredentialsSecret with no literal value: {secret}")
    if re.search(r"\$\{?OPENSHELL_OIDC_CLIENT_SECRET\b", script):
        failures.append("good-8-inference-oidc: the hook script expands OPENSHELL_OIDC_CLIENT_SECRET; "
                        "the CLI must read it from its own environment")
    add = re.search(r'openshell gateway add "\$\{GATEWAY_URL\}" --name in-cluster(?:[^\n]*\\\n)*[^\n]*', script)
    if not add or any(f not in add.group(0) for f in
                      ('--oidc-issuer "${OIDC_ISSUER}"', '--oidc-client-id "${OIDC_CLIENT_ID}"',
                       '--oidc-audience "${OIDC_AUDIENCE}"')):
        failures.append("good-8-inference-oidc: the hook does not register the gateway with "
                        "`openshell gateway add ... --oidc-issuer --oidc-client-id --oidc-audience`")
    if "--gateway-endpoint" in script or "openshell --gateway in-cluster" not in script:
        failures.append("good-8-inference-oidc: under OIDC the hook must address the registered gateway "
                        "(--gateway in-cluster), never --gateway-endpoint, which sends no token")
# Without OIDC nothing changes: no registration, no OIDC environment.
env, script = hook_of("rbac-inference")
if "gateway add" in script or '--gateway-endpoint "${GATEWAY_URL}"' not in script or any(
        e["name"].startswith(("OPENSHELL_OIDC", "OIDC_")) or e["name"] == "OPENSHELL_NO_BROWSER" for e in env):
    failures.append("rbac-inference: without OIDC the hook must dial --gateway-endpoint and carry no OIDC settings")

```

- [ ] **Step 2: Run the check and see it fail**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -10`
Expected: `CHART_RENDER_FAIL:` with `bad-3h-inference-oidc: failed the render without naming 'gateway.oidc.clientCredentialsSecret.name': …`, `bad-3h-inference-oidc-no-client: failed the render without naming 'gateway.oidc.clientId': …` and `good-8-inference-oidc: expected the render to succeed, it failed: … cannot be combined with gateway.oidc.issuer …`.

- [ ] **Step 3: Replace the guard**

In `deploy/helm/openshell-driver-kyma/templates/_inference-provider-guards.tpl`, replace the block

```yaml
{{- /* With an OIDC issuer the gateway runs allow_unauthenticated_users = false
(gateway-config.yaml), and upstream then answers a call without a bearer token
with Unauthenticated (openshell-server src/multiplex.rs AuthGrpcRouter at the
pinned tag). The hook's CLI calls carry no token, so every one fails and so does
the install. */ -}}
{{- if .Values.gateway.oidc.issuer -}}
{{- fail "inferenceProvider.enabled=true cannot be combined with gateway.oidc.issuer: the provider hook calls the gateway without a token, and a gateway with OIDC refuses unauthenticated calls. Leave inferenceProvider disabled and register the profile and provider from an authenticated CLI session (docs/production-deployment.md)." -}}
{{- end -}}
```

with

```yaml
{{- /* With an OIDC issuer the gateway runs allow_unauthenticated_users = false
(gateway-config.yaml), and upstream then answers a call without a bearer token
with Unauthenticated (openshell-server src/multiplex.rs AuthGrpcRouter at the
pinned tag). The hook therefore authenticates with the client-credentials grant
(inference-provider-hook.yaml), which needs the client and its secret. */ -}}
{{- if .Values.gateway.oidc.issuer -}}
{{- if not .Values.gateway.oidc.clientId -}}
{{- fail "inferenceProvider.enabled=true with gateway.oidc.issuer requires gateway.oidc.clientId: the provider hook authenticates to the gateway with that client's client-credentials grant." -}}
{{- end -}}
{{- if not (and .Values.gateway.oidc.clientCredentialsSecret.name .Values.gateway.oidc.clientCredentialsSecret.key) -}}
{{- fail "inferenceProvider.enabled=true with gateway.oidc.issuer requires gateway.oidc.clientCredentialsSecret.name (and .key): a Secret you manage in .Release.Namespace holding the OIDC client secret, which the provider hook exchanges for a token. Without one, leave inferenceProvider disabled and register the profile and provider from an authenticated CLI session (docs/production-deployment.md)." -}}
{{- end -}}
{{- end -}}
```

- [ ] **Step 4: Give the hook its OIDC environment**

In `deploy/helm/openshell-driver-kyma/templates/inference-provider-hook.yaml`, replace the header comment paragraph

```yaml
# Auth note: this script assumes the gateway runs with
# --disable-tls + allow_unauthenticated_users=true (the default when
# gateway.oidc.issuer is unset). A gateway with OIDC enabled refuses the
# Job's token-less CLI calls, so the chart refuses inferenceProvider.enabled
# together with gateway.oidc.issuer (inferenceProviderGuards); in an
# OIDC-enabled cluster the operator registers the profile and provider from
# an authenticated CLI session (docs/production-deployment.md).
```

with

```yaml
# Auth note: without gateway.oidc.issuer the gateway runs with --disable-tls and
# allow_unauthenticated_users=true, and the hook dials it directly. With an
# issuer the gateway refuses calls without a bearer token, so the hook registers
# the gateway once (`openshell gateway add ... --oidc-*`); the CLI exchanges
# OPENSHELL_OIDC_CLIENT_SECRET for a token with the client-credentials grant and
# stores it, and every later call names that gateway. The client secret comes
# from gateway.oidc.clientCredentialsSecret and is never expanded in the script.
```

After the `CLI_VERSION` env entry (the two lines `- name: CLI_VERSION` / `value: {{ .Values.upstream.version | quote }}`), insert:

```yaml
            {{- if .Values.gateway.oidc.issuer }}
            - name: OPENSHELL_NO_BROWSER
              value: "1"
            - name: OIDC_ISSUER
              value: {{ .Values.gateway.oidc.issuer | quote }}
            - name: OIDC_CLIENT_ID
              value: {{ .Values.gateway.oidc.clientId | quote }}
            - name: OIDC_AUDIENCE
              value: {{ .Values.gateway.oidc.audience | quote }}
            - name: OPENSHELL_OIDC_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.gateway.oidc.clientCredentialsSecret.name | quote }}
                  key: {{ .Values.gateway.oidc.clientCredentialsSecret.key | quote }}
            {{- end }}
```

- [ ] **Step 5: Make the script address one gateway**

In the same file, every CLI call reads `openshell --gateway-endpoint "${GATEWAY_URL}" …` (seven occurrences). Replace them with a shell function:

```bash
f=deploy/helm/openshell-driver-kyma/templates/inference-provider-hook.yaml
grep -c 'openshell --gateway-endpoint "${GATEWAY_URL}"' "$f"     # expect 7
sed -i.bak 's/openshell --gateway-endpoint "\${GATEWAY_URL}"/osh/g' "$f" && rm "$f.bak"
grep -c 'openshell --gateway-endpoint' "$f"                       # expect 0
```

Then define the function. Replace the script lines

```yaml
              # 4. Register the provider profile (upstream's profile model).
```

with

```yaml
              # The gateway every call below addresses. With OIDC the CLI registers
              # it once and exchanges OPENSHELL_OIDC_CLIENT_SECRET, which it reads
              # from its own environment, for a token (client-credentials grant).
              {{- if .Values.gateway.oidc.issuer }}
              openshell gateway add "${GATEWAY_URL}" --name in-cluster \
                --oidc-issuer "${OIDC_ISSUER}" --oidc-client-id "${OIDC_CLIENT_ID}" \
                --oidc-audience "${OIDC_AUDIENCE}"
              osh() { openshell --gateway in-cluster "$@"; }
              {{- else }}
              osh() { openshell --gateway-endpoint "${GATEWAY_URL}" "$@"; }
              {{- end }}

              # 4. Register the provider profile (upstream's profile model).
```

- [ ] **Step 6: Tell the operator how to connect**

In `deploy/helm/openshell-driver-kyma/templates/NOTES.txt`, insert at the very top of the file:

```
{{- if .Values.gatewayIngress.enabled }}

═══════════════════════════════════════════════════════════════════
Remote access
═══════════════════════════════════════════════════════════════════

The gateway is published at https://{{ include "openshell-driver-kyma.gatewayIngressHost" . }}
behind OIDC. Register it once with the openshell CLI (a browser opens for login):

  openshell gateway add https://{{ include "openshell-driver-kyma.gatewayIngressHost" . }} --name kyma \
    --oidc-issuer {{ .Values.gateway.oidc.issuer }} \
    --oidc-client-id {{ .Values.gateway.oidc.clientId }} \
    --oidc-audience {{ .Values.gateway.oidc.audience }}
{{- if .Values.gatewayIngress.serviceHosts.enabled }}

`openshell service expose <sandbox> <port>` prints URLs of the form
http://<workspace>--<sandbox>.{{ .Values.gatewayIngress.domain }}/ (redirected to https),
reachable from gatewayIngress.allowedCidrs. The service must listen on 127.0.0.1.
{{- end }}
{{- end }}
```

- [ ] **Step 7: Run the checks and see them pass**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -5`
Expected: `CHART_RENDER_OK`

Run: `KUBECONFIG=/dev/null helm template t deploy/helm/openshell-driver-kyma --set gateway.enabled=true --set gateway.sandboxJwt.enabled=true --set gatewayService.enabled=true --set inferenceProvider.enabled=true --set inferenceProvider.type=anthropic --set inferenceProvider.baseUrl=http://gateway.llm.svc.cluster.local:8080/anthropic --set inferenceProvider.modelId=claude-opus-4-7 --set inferenceProvider.credentialSecret.name=creds --set inferenceProvider.credentialSecret.key=api-key --set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=osh-client --set gateway.oidc.clientId=osh-client --set gateway.oidc.clientCredentialsSecret.name=oidc-client --show-only templates/inference-provider-hook.yaml | grep -n -E "gateway add|osh\(\)|osh provider" | head -12`
Expected: one `openshell gateway add "${GATEWAY_URL}" --name in-cluster \` line, one `osh() { openshell --gateway in-cluster "$@"; }` line, and `osh provider …` calls.

The script is `/bin/sh` (busybox ash): check it parses. Run: `KUBECONFIG=/dev/null helm template t deploy/helm/openshell-driver-kyma --set gateway.enabled=true --set gateway.sandboxJwt.enabled=true --set gatewayService.enabled=true --set inferenceProvider.enabled=true --set inferenceProvider.type=anthropic --set inferenceProvider.baseUrl=http://gateway.llm.svc.cluster.local:8080/anthropic --set inferenceProvider.modelId=claude-opus-4-7 --set inferenceProvider.credentialSecret.name=creds --set inferenceProvider.credentialSecret.key=api-key --set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=osh-client --set gateway.oidc.clientId=osh-client --set gateway.oidc.clientCredentialsSecret.name=oidc-client --show-only templates/inference-provider-hook.yaml | python3 -c "import sys,yaml; print([d for d in yaml.safe_load_all(sys.stdin) if d and d['kind']=='Job'][0]['spec']['template']['spec']['containers'][0]['command'][-1])" > /tmp/hook.sh && sh -n /tmp/hook.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 8: Commit**

```bash
git add scripts/check-chart-render.sh deploy/helm/openshell-driver-kyma/templates
git diff --cached --stat
git commit -m "feat(chart): provider hook authenticates with OIDC client credentials"
```

---

### Task 5: Live acceptance script

**Files:**
- Create: `scripts/remote-access-check.sh` (executable)

**Interfaces:**
- Consumes: the chart of Tasks 1-4; the `openshell` CLI on PATH; a kubeconfig; values from environment variables only.
- Produces: a pass/fail table on stdout and exit status 0 only when every check passed. Task 7 runs it. Environment contract: `OSH_DOMAIN`, `OSH_OIDC_ISSUER`, `OSH_OIDC_CLIENT_ID`, `OSH_ALLOWED_CIDRS` (comma-separated), `OSH_VALUES` (path of the release's values file) are required; `OSH_RELEASE` (default `ods`), `OSH_NAMESPACE` (default `openshell-system`), `OSH_CLIENT_SECRET` (name of the Secret holding the client secret, default `openshell-oidc-client`), `OSH_GATEWAY_NAME` (default `kyma`), `OSH_SKIP_INSTALL=1`, `OSH_CHECK_IDLE=1` are optional.

- [ ] **Step 1: Write the script**

Create `scripts/remote-access-check.sh`:

```bash
#!/usr/bin/env bash
# Live acceptance check for remote gateway access (the chart's gatewayIngress):
# installs it on a real Kyma cluster and proves the CLI and a sandbox service URL
# work through the cluster's ingress gateway, with OIDC.
#
# CI cannot run this: it needs Istio, the Kyma gateway and a real OIDC issuer. Run it
# from a laptop whose address is in OSH_ALLOWED_CIDRS. Every cluster-specific value
# comes from the environment and is never written to disk:
#
#   OSH_DOMAIN          the cluster's wildcard domain, without "*."
#   OSH_OIDC_ISSUER     the OIDC issuer URL
#   OSH_OIDC_CLIENT_ID  the OIDC client id (also the audience)
#   OSH_ALLOWED_CIDRS   comma-separated source CIDR blocks for the ingress policies
#   OSH_VALUES          the release's values file
# Optional: OSH_RELEASE (ods), OSH_NAMESPACE (openshell-system), OSH_CLIENT_SECRET
# (openshell-oidc-client: a Secret in OSH_NAMESPACE whose key client-secret holds the
# OIDC client secret; needed when the values enable inferenceProvider),
# OSH_GATEWAY_NAME (kyma), OSH_SKIP_INSTALL=1 (check an install that is already
# there), OSH_CHECK_IDLE=1 (also hold an idle stream for 400 s).
#
# `openshell gateway add` opens a browser for the OIDC login on first use.
# Requires: kubectl (with KUBECONFIG set), helm, curl, python3, openshell.
set -euo pipefail

: "${OSH_DOMAIN:?set OSH_DOMAIN to the cluster wildcard domain}"
: "${OSH_OIDC_ISSUER:?set OSH_OIDC_ISSUER}"
: "${OSH_OIDC_CLIENT_ID:?set OSH_OIDC_CLIENT_ID}"
: "${OSH_ALLOWED_CIDRS:?set OSH_ALLOWED_CIDRS (comma-separated)}"
: "${OSH_VALUES:?set OSH_VALUES to the release values file}"
RELEASE=${OSH_RELEASE:-ods}
NS=${OSH_NAMESPACE:-openshell-system}
SECRET=${OSH_CLIENT_SECRET:-openshell-oidc-client}
GW=${OSH_GATEWAY_NAME:-kyma}
HOST="openshell.${OSH_DOMAIN}"
SANDBOX=rac-web
ROOT=$(git rev-parse --show-toplevel)
CHART="$ROOT/deploy/helm/openshell-driver-kyma"

results=()
failed=0
pass() { results+=("PASS  $1"); }
fail() { results+=("FAIL  $1"); failed=1; }
check() { # description command...
	local what=$1
	shift
	if "$@"; then pass "$what"; else fail "$what"; fi
}
log() { printf '\n=== %s\n' "$*"; }
osh() { openshell --gateway "$GW" "$@"; }
http_code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@" || true; }

cidrs_json=$(python3 -c 'import json,sys; print(json.dumps([c.strip() for c in sys.argv[1].split(",") if c.strip()]))' \
	"$OSH_ALLOWED_CIDRS")

if [[ ${OSH_SKIP_INSTALL:-} != 1 ]]; then
	log "upgrading $RELEASE with gatewayIngress"
	if helm upgrade "$RELEASE" "$CHART" -n "$NS" -f "$OSH_VALUES" \
		--set gatewayIngress.enabled=true \
		--set "gatewayIngress.domain=$OSH_DOMAIN" \
		--set gatewayIngress.serviceHosts.enabled=true \
		--set-json "gatewayIngress.allowedCidrs=$cidrs_json" \
		--set "gateway.oidc.issuer=$OSH_OIDC_ISSUER" \
		--set "gateway.oidc.audience=$OSH_OIDC_CLIENT_ID" \
		--set "gateway.oidc.clientId=$OSH_OIDC_CLIENT_ID" \
		--set gateway.oidc.authOnly=true \
		--set "gateway.oidc.clientCredentialsSecret.name=$SECRET" \
		--wait --timeout 10m >/dev/null; then
		pass "helm upgrade with gatewayIngress (provider hook included)"
	else
		fail "helm upgrade with gatewayIngress (kubectl -n $NS get pods,jobs)"
	fi
fi

log "rendered objects"
fullname=$(kubectl -n "$NS" get deploy -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=openshell-driver-kyma" \
	-o jsonpath='{.items[0].metadata.name}')
check "VirtualService $fullname-gateway" kubectl -n "$NS" get virtualservice "$fullname-gateway" -o name
check "VirtualService $fullname-sandbox-services" kubectl -n "$NS" get virtualservice "$fullname-sandbox-services" -o name
for suffix in jwt cli services; do
	kind=authorizationpolicy
	[[ $suffix == jwt ]] && kind=requestauthentication
	check "$kind $NS-$fullname-openshell-$suffix in istio-system" \
		kubectl -n istio-system get "$kind" "$NS-$fullname-openshell-$suffix" -o name
done
port=$(kubectl -n "$NS" get deploy "$fullname" \
	-o jsonpath='{.spec.template.spec.containers[?(@.name=="gateway")].ports[?(@.name=="grpc")].containerPort}')
check "gateway binds port 80 (got $port)" test "$port" = 80

log "the edge refuses a call without a token"
code=$(http_code -X POST -H 'content-type: application/grpc' "https://$HOST/openshell.v1.OpenShell/ListSandboxes")
check "POST without a bearer is refused at the edge (HTTP $code, want 403)" test "$code" = 403

log "CLI through the ingress (a browser opens for the OIDC login)"
openshell gateway add "https://$HOST" --name "$GW" --oidc-issuer "$OSH_OIDC_ISSUER" \
	--oidc-client-id "$OSH_OIDC_CLIENT_ID" --oidc-audience "$OSH_OIDC_CLIENT_ID" || true
check "openshell status through https://openshell.<domain>" osh status
osh sandbox delete "$SANDBOX" >/dev/null 2>&1 || true
check "sandbox create" osh sandbox create --detach --name "$SANDBOX" --from python:3.12-slim \
	-- python3 -m http.server 8080 --bind 127.0.0.1
ready=""
for _ in $(seq 1 36); do
	ready=$(osh sandbox list 2>/dev/null | awk -v n="$SANDBOX" '$1 == n { print $NF }')
	[[ $ready == Ready ]] && break
	sleep 5
done
check "sandbox reaches Ready (phase: ${ready:-none})" test "$ready" = Ready
out=$(osh sandbox exec --name "$SANDBOX" -- sh -c 'echo exec-ok' 2>&1 || true)
check "sandbox exec through the ingress" grep -q exec-ok <<<"$out"

log "sandbox service URL"
url=$(osh service expose "$SANDBOX" 8080 2>&1 | grep -oE 'https?://[^ ]+' | head -1 || true)
check "service expose prints http://default--$SANDBOX.<domain>/ (got ${url/$OSH_DOMAIN/<domain>})" \
	test "$url" = "http://default--$SANDBOX.$OSH_DOMAIN/"
code=$(http_code "http://default--$SANDBOX.$OSH_DOMAIN/")
check "the printed http:// URL redirects to https (HTTP $code, want 301)" test "$code" = 301
body=$(curl -s -m 20 "https://default--$SANDBOX.$OSH_DOMAIN/" || true)
check "https://default--$SANDBOX.<domain>/ serves the sandbox's directory listing" \
	grep -q "Directory listing for /" <<<"$body"
code=$(http_code "https://default--no-such-sandbox.$OSH_DOMAIN/")
check "an unknown sandbox host is answered by the gateway, not by a sandbox (HTTP $code, want 404 or 503)" \
	test "$code" = 404 -o "$code" = 503

if kubectl -n "$NS" get job -l "app.kubernetes.io/instance=$RELEASE" -o name 2>/dev/null | grep -q inference-provider-hook \
	|| grep -qE '^inferenceProvider:' "$OSH_VALUES"; then
	log "provider registered by the hook (client credentials)"
	check "openshell provider list succeeds with the user's token" osh provider list
fi

if [[ ${OSH_CHECK_IDLE:-} == 1 ]]; then
	log "idle stream for 400 s (Envoy's stream idle timeout is 300 s)"
	out=$(osh sandbox exec --name "$SANDBOX" -- sh -c 'sleep 400; echo idle-ok' 2>&1 || true)
	check "an exec stream idle for 400 s survives" grep -q idle-ok <<<"$out"
fi

log "cleanup"
osh service delete "$SANDBOX" >/dev/null 2>&1 || true
check "sandbox delete" osh sandbox delete "$SANDBOX"

printf '\n'
printf '%s\n' "${results[@]}" | sed "s/${OSH_DOMAIN//./\\.}/<domain>/g"
if [[ $failed == 1 ]]; then
	printf '\nREMOTE_ACCESS_FAIL\n'
	exit 1
fi
printf '\nREMOTE_ACCESS_OK\n'
```

- [ ] **Step 2: Check it statically**

Run: `chmod +x scripts/remote-access-check.sh && bash -n scripts/remote-access-check.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

Run: `scripts/remote-access-check.sh 2>&1 | head -2`
Expected: the script stops at the first missing variable: a line containing `OSH_DOMAIN: set OSH_DOMAIN to the cluster wildcard domain`.

Run (only if `shellcheck` is installed; skip otherwise): `shellcheck scripts/remote-access-check.sh`
Expected: no findings.

Run: `grep -nE "kyma\.ondemand|accounts\.ondemand|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/" scripts/remote-access-check.sh`
Expected: no output (no cluster, tenant or address literal in the script).

- [ ] **Step 3: Commit**

```bash
git add scripts/remote-access-check.sh
git diff --cached --stat
git commit -m "test: live acceptance check for remote gateway access"
```

---

### Task 6: Documentation, changelog and version 0.10.0

**Files:**
- Modify: `docs/production-deployment.md` (decision table, sections 1-4, "Reaching a service inside a sandbox")
- Modify: `docs/getting-started.md` (Appendix B)
- Modify: `docs/openshell-api-programmatic-usage.md` (endpoint table row, section A)
- Modify: `docs/kyma-vs-openshift.md` ("External access" table, "Public APIRule guard")
- Modify: `docs/tutorial-anthropic-direct.md` (two `gatewayApirule` mentions, version pins)
- Modify: `docs/walkthrough-claude-files.md` (version pins)
- Modify: `docs/internal/runbook-upstream-sync.md` (one paragraph)
- Modify: `README.md` (version line, production line)
- Modify: `CHANGELOG.md`, `Cargo.toml`, `Cargo.lock`, `deploy/helm/openshell-driver-kyma/Chart.yaml`

**Interfaces:**
- Consumes: the values, guards, object names and script of Tasks 1-5, exactly as named in Global Constraints.
- Produces: nothing other tasks consume.

- [ ] **Step 1: Rewrite the production runbook's access chapter**

In `docs/production-deployment.md`:

In the first paragraph replace the two lines

```markdown
and now want a production-grade install: OIDC user auth, public access
through the Kyma API Gateway, image digests pinned, an `imagePullSecrets`
```

with

```markdown
and now want a production-grade install: OIDC user auth, remote access
through the cluster's Istio ingress gateway, image digests pinned, an
`imagePullSecrets`
```

Replace the decision table row `| Public APIRule + OIDC | OIDC + sandbox-JWT | Standard SAP IAS pattern, no VPN, MFA | Public attack surface |` with `| Remote access (`gatewayIngress`) + OIDC | OIDC at the edge and at the gateway + sandbox-JWT | Standard SAP IAS pattern, no port-forward, MFA | Public attack surface; needs rights in `istio-system` |` and the line `The Public APIRule option is the focus of the rest of this doc.` with `The remote-access option is the focus of the rest of this doc.`.

Replace section `## 1. Provision an OIDC client` (its heading and body, up to the next `## 2.` heading) with:

````markdown
## 1. Provision an OIDC client

Use SAP IAS (or any other OIDC IdP). Create one application of type OpenID
Connect:

- **Client id** → `gateway.oidc.clientId` and `gateway.oidc.audience` (IAS
  puts the client id into the token's `aud`).
- **Authorization Code with PKCE**, with the redirect URI
  `http://127.0.0.1:*/callback`: the CLI listens on an ephemeral loopback port
  during login. If your IdP rejects a wildcard port, log in with the device
  grant instead (`OPENSHELL_NO_BROWSER=1 openshell gateway add …`).
- **A client secret**, only if you use `inferenceProvider`: the chart's
  provider hook authenticates with the client-credentials grant. Store it in
  a Secret you manage, never in a values file:

  ```bash
  kubectl -n openshell-system create secret generic openshell-oidc-client \
    --from-literal=client-secret='<the client secret>'
  ```
- **Issuer** → `gateway.oidc.issuer`, for IAS `https://<your-tenant>.accounts.ondemand.com`.

Keep the issuer reachable from the cluster (the gateway and the ingress
gateway fetch its JWKS) and from your users' laptops (the CLI redirects to it
on first auth).

**Authorization.** Upstream's gateway defaults to RBAC: a token needs the role
`openshell-admin` or `openshell-user` in the claim `realm_access.roles`. IAS
tokens carry neither, so choose one:

- `gateway.oidc.authOnly: true` accepts every identity the issuer
  authenticates (who may log in is then decided in the IdP);
- or set `gateway.oidc.rolesClaim` (for IAS `groups`), `adminRole` and
  `userRole` to group names you assign in the IdP. The technical client of
  the provider hook then needs the user role too.
````

In section `## 2. Decide on chart values`, replace the `oidc:` block of the example (the comment `# OIDC required for the public-APIRule path. The chart's` through `userRole:  "openshell-user"`) with:

```yaml
  # OIDC is required for remote access: the chart refuses to publish an
  # unauthenticated gateway.
  oidc:
    issuer: "https://<your-tenant>.accounts.ondemand.com"
    audience: "<client-id>"
    clientId: "<client-id>"
    authOnly: true                 # or rolesClaim + adminRole + userRole
    clientCredentialsSecret:       # only with inferenceProvider
      name: openshell-oidc-client
```

Replace the `gatewayApirule:` block of the example (from `gatewayApirule:` through `          - requiredScopes: []   # rely on OIDC roles in the gateway`) with:

```yaml
gatewayIngress:
  enabled: true
  domain: "<your-cluster-id>.kyma.ondemand.com"   # the Kyma gateway's *.<domain>
  # Source addresses allowed through the ingress gateway. Optional for the CLI
  # host (a token is required either way), required for serviceHosts.
  allowedCidrs: ["203.0.113.0/24"]
  # Publish `openshell service expose` URLs. Read "Reaching a service inside a
  # sandbox" below first: this admits allowedCidrs to every host of the domain.
  serviceHosts:
    enabled: true
```

Replace the comment block that starts `# No `inferenceProvider` block. Its post-install Job registers the provider` and ends `# sandboxes the endpoint and model it would have set:` with:

```yaml
# `inferenceProvider` works with OIDC when gateway.oidc.clientCredentialsSecret
# names the client secret: its post-install Job logs in with the
# client-credentials grant. Without a client secret, leave it disabled, register
# the provider yourself from an authenticated CLI session (step 3b), and give
# sandboxes the endpoint and model it would have set:
```

In `## 3. Install`, replace the bullet

```markdown
- Refuse to render `gatewayApirule.yaml` if `gateway.oidc.issuer` is
  empty (the chart's `B1` security guard).
```

with:

```markdown
- Refuse to render if `gatewayIngress.enabled` is set without
  `gateway.oidc.issuer`, `audience` and `clientId` (the chart never publishes
  an unauthenticated gateway), without `gatewayIngress.domain`, or with
  `serviceHosts.enabled` and no `allowedCidrs`.

Installing with `gatewayIngress.enabled` creates a RequestAuthentication and
AuthorizationPolicies in `istio-system`, so the installing identity needs
rights there. The RequestAuthentication selects the whole ingress gateway: a
request to any host that carries an invalid token of your issuer is answered
401 there. Requests without a token, or with another issuer's, are unaffected.
```

In `### 3b. Register the inference provider`, replace the first two paragraphs (from `Once the install has finished` through `allowed to reach it (claude-code runs under `node`):`) with:

````markdown
Register the gateway with the `openshell` CLI on a laptop; a browser opens for
the OIDC login:

```bash
openshell gateway add https://openshell.<cluster-domain> --name kyma \
  --oidc-issuer https://<your-tenant>.accounts.ondemand.com \
  --oidc-client-id <client-id> --oidc-audience <client-id>
```

(`helm install` prints this line with your values.) When the token expires,
`openshell gateway login kyma` renews it.

With `inferenceProvider.enabled` and a client secret, the chart's hook has
already registered the provider and this step is done. Otherwise register it
from that authenticated session, with the profile the hook would have
imported. Write it for your endpoint: `host` and `port` are those of
`ANTHROPIC_BASE_URL` above (the path is not part of the binding), and
`binaries` are the processes allowed to reach it (claude-code runs under
`node`):
````

In `## 4. Verify`, replace the lines `# APIRule reconciled` / `kubectl -n openshell-system get apirule` with:

```bash
# Routes and ingress policies rendered
kubectl -n openshell-system get virtualservice
kubectl -n istio-system get requestauthentication,authorizationpolicy | grep openshell

# The edge refuses a call without a token (403), the CLI gets through
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://openshell.<cluster-domain>/openshell.v1.OpenShell/ListSandboxes
openshell status
```

and add after the code block: `` `scripts/remote-access-check.sh` runs these and the sandbox-service checks end to end against a live cluster. ``

In `## Reaching a service inside a sandbox`, replace the last paragraph (from `Reaching such a URL without a port-forward means publishing the gateway, not` through `hostnames). The latter is not wired into the chart yet.`) with:

```markdown
With `gatewayIngress.serviceHosts.enabled`, the same command prints a public
URL, `http://default--web.<cluster-domain>/`, which the Kyma gateway redirects
to HTTPS; no port-forward and no `--resolve`. Three things to know:

- A browser sends no token, so these hosts are fenced by
  `gatewayIngress.allowedCidrs` only. Put authentication into the service
  itself if the address ranges are shared.
- Istio's host matching takes only a prefix wildcard, so the policy admits
  `allowedCidrs` to **every** host under the cluster domain, not only to
  sandbox service hosts. On a cluster that allowlists other applications per
  host, that widens their fence to the same address ranges. Leave
  `serviceHosts.enabled: false` and use the port-forward URLs if that matters.
- The gateway then binds port 80 in its pod (so the printed URL carries no
  port), which adds the safe sysctl `net.ipv4.ip_unprivileged_port_start=0` to
  the pod. The in-cluster Service port stays `gateway.grpcPort`.

Sandbox pods themselves are never published.
```

- [ ] **Step 2: Update the other documents**

`docs/getting-started.md` — replace the body of `## Appendix B: public exposure via Kyma APIRule` (heading and paragraph) with:

```markdown
## Appendix B: remote access without a port-forward

To use the `openshell` CLI from a laptop without a port-forward, publish the
gateway through the cluster's Istio ingress gateway: set
`gatewayIngress.enabled=true`, `gatewayIngress.domain` and
`gateway.oidc.{issuer,audience,clientId}`. The chart refuses to publish an
unauthenticated gateway. `gatewayIngress.serviceHosts.enabled` additionally
publishes the URLs `openshell service expose` prints. See
[`production-deployment.md`](production-deployment.md) for the full setup.
```

`docs/openshell-api-programmatic-usage.md` — replace the table row `| Public (only with `gatewayApirule.enabled` + OIDC) | `https://<gatewayApirule.host>` |` with `| Public (only with `gatewayIngress.enabled` + OIDC) | `https://openshell.<cluster-domain>` (`gatewayIngress.host`) |`, and replace section `### A. Public hostname via Kyma `APIRule`` (heading and paragraph, up to `### B.`) with:

```markdown
### A. Public hostname via the Kyma ingress gateway

When the `openshell-driver-kyma` Helm chart is installed with
`gatewayIngress.enabled=true`, a `gatewayIngress.domain` and
`gateway.oidc.{issuer,audience,clientId}`, the gateway is reachable at
`https://openshell.<cluster-domain>`. The ingress gateway requires a valid
token of the issuer (and, with `gatewayIngress.allowedCidrs`, a source address
in it) before forwarding; the gateway validates the same token again. Native
gRPC clients dial the `:443` HTTPS endpoint with `authorization: Bearer <token>`.
```

`docs/kyma-vs-openshift.md` — in the "External access" table replace `` `gatewayApirule` publishes the gateway behind OIDC `` with `` `gatewayIngress` publishes the gateway behind OIDC (VirtualService + ingress policies) `` and `` used in `gatewayApirule.host` `` with `` set as `gatewayIngress.domain` ``; replace the section `## Public APIRule guard` (heading and paragraph) with:

```markdown
## Public ingress guard

The chart refuses to render with `gatewayIngress.enabled=true` unless
`gateway.oidc.issuer`, `audience` and `clientId` are set. Without this guard,
an operator could combine a public host with
`allow_unauthenticated_users=true` (set automatically when no issuer) and
`--disable-tls`, producing a world-writable sandbox factory.
```

`docs/tutorial-anthropic-direct.md` — replace `**No `gatewayApirule` / OIDC block.**` with `**No `gatewayIngress` / OIDC block.**` and `Set `gatewayApirule.enabled=true` and` with `Set `gatewayIngress.enabled=true` and`.

`docs/internal/runbook-upstream-sync.md` — insert this subsection immediately before the heading `### An upstream release is broken`:

```markdown
### `rendered gateway config accepted upstream` is red with `GATEWAY_ARGS_REJECTED`

`scripts/check-gateway-config.sh` runs the pinned gateway image with the chart's
rendered command line plus `--help`: with the defaults, with remote access on
and with RBAC roles. Upstream renamed or removed a flag the chart passes
(`--server-san`, `--oidc-roles-claim`, `--oidc-admin-role`, …); the output
carries upstream's own `unexpected argument` message. Fix the flag in
`deploy/helm/openshell-driver-kyma/templates/deployment.yaml`.

```

`README.md` — replace `(OIDC user auth, public Kyma APIRule,` with `(OIDC user auth, remote access through the Kyma ingress gateway,`.

- [ ] **Step 3: Bump the version to 0.10.0**

```bash
sed -i.bak 's/^version = "0.9.1"/version = "0.10.0"/' Cargo.toml && rm Cargo.toml.bak
sed -i.bak -e 's/^version: 0.9.1/version: 0.10.0/' -e 's/^appVersion: "0.9.1"/appVersion: "0.10.0"/' \
  deploy/helm/openshell-driver-kyma/Chart.yaml && rm deploy/helm/openshell-driver-kyma/Chart.yaml.bak
sed -i.bak 's/\*\*Version 0.9.1.\*\*/**Version 0.10.0.**/' README.md && rm README.md.bak
sed -i.bak -e 's/helm install chart 0.9.1"/helm install chart 0.10.0"/' -e 's/--version 0.9.1 \\/--version 0.10.0 \\/' \
  -e 's/`openshell-driver-kyma` `0.9.1`/`openshell-driver-kyma` `0.10.0`/' docs/tutorial-anthropic-direct.md \
  && rm docs/tutorial-anthropic-direct.md.bak
sed -i.bak -e 's/Installing the chart (`0.9.1`)/Installing the chart (`0.10.0`)/' -e 's/--version 0.9.1 \\/--version 0.10.0 \\/' \
  docs/walkthrough-claude-files.md && rm docs/walkthrough-claude-files.md.bak
git grep -n '0\.9\.1' -- ':!CHANGELOG.md' ':!docs/superpowers' ':!Cargo.lock'
```

Expected from the last command: no output.

Run: `make fmt && make test 2>&1 | grep -E "^test result|error" | head -6`
Expected: three `test result: ok.` lines, no `error`. `git status --short Cargo.lock` then shows ` M Cargo.lock` (the workspace crates at 0.10.0).

- [ ] **Step 4: Write the changelog entry**

In `CHANGELOG.md`, insert before `## [0.9.1] — 2026-09-30`:

```markdown
## [0.10.0] — 2026-09-30

**UPGRADE NOTE: `gatewayApirule` is removed.** Move to `gatewayIngress` (table
below) before `helm upgrade`; a values file that still carries `gatewayApirule`
is ignored, so the gateway silently loses its public route.

### Added

- **Remote access (`gatewayIngress`)**: publishes the gateway through the
  cluster's Istio ingress gateway with OIDC, so the `openshell` CLI works
  without a port-forward. Renders a VirtualService for `openshell.<domain>` in
  the release namespace and, on the ingress gateway in `istio-system`, a
  RequestAuthentication plus an ALLOW AuthorizationPolicy that requires a token
  of the issuer (and, with `allowedCidrs`, a source address). The gateway
  validates the same token again. The chart refuses to publish a gateway
  without `gateway.oidc.{issuer,audience,clientId}`.
- **Published service URLs (`gatewayIngress.serviceHosts`)**:
  `openshell service expose` prints `http://<workspace>--<sandbox>.<domain>/`
  (redirected to HTTPS), routed by a wildcard VirtualService to the gateway and
  fenced by `allowedCidrs`. The gateway then binds port 80 in its pod (safe
  sysctl `net.ipv4.ip_unprivileged_port_start=0`) and takes the domain from
  `--server-san`. The policy admits `allowedCidrs` to every host under the
  domain; see production-deployment.
- **`gateway.oidc.authOnly`**, `rolesClaim`, `clientId`, `jwksUri` and
  `clientCredentialsSecret`. `authOnly: true` selects upstream's
  authentication-only mode (both roles passed empty); `adminRole` and
  `userRole` must now be set together.
- **`inferenceProvider` with OIDC**: the provider hook logs in with the
  client-credentials grant when `gateway.oidc.clientCredentialsSecret` names
  the client secret. The pair was refused before.
- `scripts/remote-access-check.sh`, the live acceptance check, and a flag check
  in `scripts/check-gateway-config.sh` (the pinned gateway image must know every
  flag the chart renders).

### Removed

- **`gatewayApirule`** and its APIRule template: never verified, and APIRule v2
  needs an Istio sidecar on the gateway pod.

### Values migration

| 0.9.x | 0.10.0 |
|---|---|
| `gatewayApirule.enabled` | `gatewayIngress.enabled` |
| `gatewayApirule.host: openshell.<domain>` | `gatewayIngress.domain: <domain>` (and `host` only if it is not `openshell.<domain>`) |
| `gatewayApirule.gateway` | `gatewayIngress.istioGateway` |
| `gatewayApirule.rules[].jwt.authentications[].issuer` / `jwksUri` | `gateway.oidc.issuer` / `gateway.oidc.jwksUri` |
| (none) | `gateway.oidc.clientId` (required with `gatewayIngress`) |

```

- [ ] **Step 5: Verify the docs and the whole tree**

Run: `git grep -n "gatewayApirule" -- ':!CHANGELOG.md' ':!docs/superpowers'`
Expected: no output.

Run: `git grep -nE "c-[0-9a-f]{7}\.kyma|@gmail|sk-ant-[A-Za-z0-9]" -- ':!docs/superpowers' | grep -v "c-0000000"`
Expected: no output.

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -1 && KUBECONFIG=/dev/null helm lint deploy/helm/openshell-driver-kyma | tail -1`
Expected: `CHART_RENDER_OK` and `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 6: Commit**

```bash
git add docs README.md CHANGELOG.md Cargo.toml Cargo.lock deploy/helm/openshell-driver-kyma/Chart.yaml
git diff --cached --stat
git commit -m "docs: remote access chapter, changelog and version 0.10.0"
```

---

### Task 7 (gated, run by the controller with the user): live acceptance and release

Every step here is outward-facing or touches the live cluster. Stop and get the user's explicit approval before the steps marked **[approval]**. No subagent runs any of it.

**Files:** none (fixes found live go through a normal commit on the branch, with the render checks re-run).

**Interfaces:**
- Consumes: branch `feat/remote-gateway-access` with Tasks 1-6; `scripts/remote-access-check.sh`; from the user, at run time and never written to a file: the IAS issuer and client id, a Secret `openshell-oidc-client` they create in `openshell-system`, and the allowed CIDR blocks (the ones of their existing ingress allowlist policies).
- Produces: release `v0.10.0`.

- [ ] **Step 1 [approval]: Push the branch and open the pull request**

```bash
git fetch origin --prune --tags
gh auth status          # the active account must be st-gr
git push -u origin feat/remote-gateway-access
gh pr create --base main --title "feat!: remote gateway access through the Kyma ingress gateway (0.10.0)" --body-file <(printf '%s\n' "See docs/superpowers/specs/2026-09-30-remote-gateway-access-design.md." "" "🤖 Generated with [Claude Code](https://claude.com/claude-code)")
gh pr checks --watch
```

Expected: every check passes (`rendered gateway config accepted upstream` now includes the flag check).

- [ ] **Step 2 [approval]: Release candidate image**

```bash
git tag v0.10.0-rc.1 && git push origin v0.10.0-rc.1
DIGEST=$(docker buildx imagetools inspect ghcr.io/st-gr/openshell-driver-kyma:v0.10.0-rc.1 | awk '/^Digest:/{print $2}')
docker manifest inspect "ghcr.io/st-gr/openshell-driver-kyma@$DIGEST" >/dev/null && echo "digest verified"
```

Take the digest from the registry, never from the workflow log. Expected: `digest verified`.

- [ ] **Step 3 [approval]: Live acceptance on the cluster**

The user creates the client-secret Secret (`kubectl -n openshell-system create secret generic openshell-oidc-client --from-literal=client-secret=…`) and supplies issuer and client id in the terminal. Put the release-candidate digest into a copy of the release's values file, then:

```bash
OSH_DOMAIN=… OSH_OIDC_ISSUER=… OSH_OIDC_CLIENT_ID=… OSH_ALLOWED_CIDRS=… \
OSH_VALUES=<values file with the rc digest> OSH_CHECK_IDLE=1 scripts/remote-access-check.sh
```

Expected: `REMOTE_ACCESS_OK`. Known risks and what to do if a check fails (spec §12):

| Failing check | Likely cause | Action |
|---|---|---|
| browser login rejected | the IdP refuses `http://127.0.0.1:*/callback` | re-run with `OPENSHELL_NO_BROWSER=1` (device grant); document it |
| `openshell status` → Unauthenticated though the edge passed | token audience ≠ `gateway.oidc.audience`, or the ingress dropped the token | compare `aud` in the token; check `forwardOriginalToken` in the live RequestAuthentication |
| `openshell status` → PermissionDenied | RBAC mode with roles the token lacks | `gateway.oidc.authOnly=true`, or set `rolesClaim`/roles |
| helm upgrade fails in the provider hook | the client-credentials token is refused, or `gateway add` over `http://` | read the Job's log; this is the spec's hook risk — fall back to registering the provider from the CLI (docs step 3b) and record the finding |
| idle stream cut at 300 s | Envoy stream idle timeout | add an opt-in `EnvoyFilter` value in a follow-up; record the finding |
| pod stuck `CreateContainerConfigError` / sysctl forbidden | the cluster rejects the sysctl | record it; fall back to `serviceHosts.enabled=false` |

Revert the cluster to the released chart if the candidate is not kept running.

- [ ] **Step 4 [approval]: Merge, tag, deploy**

```bash
gh pr merge --squash
git fetch origin main --tags && git tag v0.10.0 origin/main && git push origin v0.10.0
DIGEST=$(docker buildx imagetools inspect ghcr.io/st-gr/openshell-driver-kyma:v0.10.0 | awk '/^Digest:/{print $2}')
docker manifest inspect "ghcr.io/st-gr/openshell-driver-kyma@$DIGEST" >/dev/null && echo "digest verified"
```

Then `helm upgrade` the release with that digest and the user's remote-access values, and run `OSH_SKIP_INSTALL=1 scripts/remote-access-check.sh` once more. Expected: `REMOTE_ACCESS_OK`.
