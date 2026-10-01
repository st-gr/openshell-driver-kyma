# Remote gateway access on Kyma — design

**Status:** proposed (2026-09-30). Targets chart/driver 0.10.0.
**Supersedes:** the unverified `gatewayApirule` block (removed by this design).
**Depends on:** v0.9.1 (sandbox pod exposure removed; `openshell service expose`
documented).

## 1. Goal

Use the OpenShell CLI and a browser against sandboxes on a Kyma cluster
**without a `kubectl port-forward`**, the upstream way: publish the *gateway*
(never the sandbox pods, which reset every inbound connection that does not
come through the gateway's relay), authenticate users with OIDC, and let
`openshell service expose` print URLs that work from the laptop.

Success looks like:

```bash
openshell gateway add https://openshell.<domain> --name kyma \
  --oidc-issuer https://<tenant>.accounts.ondemand.com \
  --oidc-client-id <client-id> --oidc-audience <client-id>   # browser login once
openshell sandbox create --detach --name web --from python:3.12-slim \
  -- python3 -m http.server 8080 --bind 127.0.0.1
openshell service expose web 8080        # → http://default--web.<domain>/  (opens in a browser)
openshell sandbox connect web            # works, including long idle shells
```

Out of scope: the WebSocket tunnel (upstream's edge mode is
Cloudflare-Access-specific: `/auth/connect` reads a `CF_Authorization`
cookie), TLS between the ingress and the gateway pod (follow-up, §11), browser
SSO for service URLs (no ext-authz on the cluster), RBAC roles (values stay,
default auth-only).

## 2. Decisions

| # | Decision | Why |
|---|----------|-----|
| D1 | OIDC end to end with SAP IAS: the edge validates the JWT, the gateway validates the same JWT. | Upstream's intended cloud mode; per-user identity, workspaces and audit work; the edge check is defense in depth. |
| D2 | Plain Istio resources: `VirtualService`s in the release namespace, `RequestAuthentication` + `AuthorizationPolicy` on the ingress gateway in `istio-system`, written as DENY or ALLOW policies per `gatewayIngress.policyAction`. | APIRule v2 needs a sidecar on the gateway pod (PeerAuthentication, NetworkPolicy, probe changes). DENY (default) names only the chart's hosts and is safe on a gateway without ALLOW policies, where an ALLOW policy would shut out every other host; ALLOW is for a gateway that already allowlists per host, as the user's does. |
| D3 | No tunnel. The CLI sends gRPC with a bearer straight through Istio. | Istio carries gRPC; the tunnel exists for edges that reject POSTs. |
| D4 | Gateway stays plaintext in-pod (`--disable-tls`). | Upstream: "Kubernetes deployments must leave `mtls_auth` unset and use OIDC or a trusted access proxy." The ingress→pod hop is plaintext like today's supervisor hop. |
| D5 | With published service hosts (`serviceHosts.enabled`) the gateway binds **port 80** in-pod (safe sysctl) and gets `--server-san *.<domain>`; otherwise its listener is unchanged. | `endpoint_url` prints `<scheme>://<host>:<bind-port>/` and omits the port only for http/80; Kyma's `http:80` server redirects to HTTPS. Result: `http://<ws>--<sb>.<domain>/`, copy-pasteable. |
| D6 | Service hosts are published only behind `allowedCidrs`, and per workspace (`serviceHosts.workspaces`): routes and policies match `<workspace>--*`. | Browsers carry no bearer; IP allowlisting is the cluster's existing pattern. Istio hosts take only prefix or suffix wildcards, and the domain's wildcard would cover the CLI host and other applications. The chart refuses to publish service hosts without CIDRs. |
| D7 | `gatewayIngress` replaces `gatewayApirule`. | The APIRule block was never verified and cannot work without a sidecar. Breaking → 0.10.0. |
| D8 | `gateway.oidc.authOnly: true` selects upstream's authentication-only mode explicitly; the chart default stays `false`. | Upstream defaults the roles to `openshell-admin`/`openshell-user` read from `realm_access.roles`, so empty role values mean RBAC with those defaults, which IAS tokens never satisfy. `authOnly` passes both roles empty, so any identity IAS issues is accepted and the hook's technical client needs no group claims. Making it an explicit switch keeps existing OIDC installs from loosening silently. |
| D9 | In-cluster automation (inference-provider hook Job, smokes) authenticates with the client-credentials grant of the **same** IAS application. | Same `aud` for people (PKCE) and the Job (secret); upstream's CLI switches to client credentials when `OPENSHELL_OIDC_CLIENT_SECRET` is set. |

## 3. Architecture and flows

```text
laptop CLI ─OIDC code+PKCE (browser)─▶ SAP IAS
laptop CLI ─gRPC + bearer─▶ https://openshell.<domain>     Kyma ingress gateway (TLS, *.<domain> cert)
    RequestAuthentication: issuer = IAS, audiences = [<client-id>], forwardOriginalToken
    AuthorizationPolicy (DENY or ALLOW, per policyAction): host openshell.<domain> only with a principal "<issuer>/*" [and from allowedCidrs]
    → VirtualService → Service <release>:8080 (h2c) → gateway (plaintext in-pod, OIDC validates the bearer)

browser ─▶ https://default--web.<domain>/                    (URL printed by `openshell service expose`)
    AuthorizationPolicy (same action): hosts <workspace>--* of the published workspaces only from allowedCidrs
    → wildcard VirtualService (authority regex `<ws>--<sb>[--<svc>].<domain>`) → Service :80 `http-services` (HTTP/1.1) → gateway :80 in-pod → relay → sandbox loopback

hook Job / smokes ─client credentials (OPENSHELL_NO_BROWSER=1, OPENSHELL_OIDC_CLIENT_SECRET)─▶ Service :8080
supervisors ─sandbox JWT─▶ Service :8080                       (unchanged)
laptop port-forward ─▶ Service :8080                           (unchanged; now also needs a bearer)
```

Request handling at the edge, in order: TLS termination with Kyma's wildcard
certificate → JWT validation when a token is present (RequestAuthentication)
→ ALLOW policies (deny-by-default on this cluster) → routing by host.

Unchanged: driver, enrichment, namespaces, supervisor ↔ gateway, sandbox JWT.

## 4. Chart surface

### 4.1 Values

```yaml
gatewayIngress:
  enabled: false
  domain: ""                      # required: the cluster's wildcard domain, e.g. c-xxxxxxx.kyma.ondemand.com
  host: ""                        # CLI/API host; empty = openshell.<domain>
  istioGateway: kyma-system/kyma-gateway
  ingressNamespace: istio-system  # where RequestAuthentication/AuthorizationPolicies render
  ingressSelector:                # workload selector of those policies
    istio: ingressgateway
  policyAction: DENY              # DENY for an ingress gateway without ALLOW policies, ALLOW for one that already allowlists (D2)
  allowedCidrs: []                # remoteIpBlocks. Required for serviceHosts; optional extra fence for the CLI host.
  serviceHosts:
    enabled: false                # publish sandbox service URLs (browser)
    workspaces: [default]         # the workspaces whose service hosts are routed and fenced (D6)

gateway:
  oidc:
    issuer: ""                    # existing
    audience: ""                  # existing; = the IAS client id
    clientId: ""                  # new: public client id the CLI and the Job use
    jwksUri: ""                   # new, optional, for the RequestAuthentication only: Istio discovers it from the issuer when empty; the gateway always does
    authOnly: false               # new: true = authentication-only (both roles passed empty)
    rolesClaim: ""                # new: passed as --oidc-roles-claim when set
    adminRole: ""                 # existing; empty (with userRole) = upstream's default roles
    userRole: ""                  # existing; must be set together with adminRole
    clientCredentialsSecret:      # new: Secret with the IAS client secret, for the hook Job and smokes
      name: ""
      key: client-secret
```

`gatewayApirule` is removed (values and template).

### 4.2 Templates

New, rendered only when `gatewayIngress.enabled`:

- `gateway-virtualservice.yaml` — `VirtualService <fullname>-gateway` in the
  release namespace: `hosts: [<host>]`, `gateways: [<istioGateway>]`, one
  `http` route to `<fullname>.<ns>.svc.cluster.local:<gateway.grpcPort>`,
  `timeout: 0s` (streaming RPCs: `WatchSandboxes`, `Exec`, `RelayStream`).
- `gateway-services-virtualservice.yaml` (when `serviceHosts.enabled`) —
  `VirtualService <fullname>-sandbox-services`: `hosts: ["*.<domain>"]`, same
  gateway, one `http` route with
  `match.authority.regex: ^(<listed workspaces, |-joined>)--[a-z0-9]+(-[a-z0-9]+)*(--[a-z0-9]+(-[a-z0-9]+)*)?\.<domain, dots escaped>(:[0-9]+)?$`
  to the Service's `http-services` port (80) and `timeout: 0s`. Exact-host
  VirtualServices of other apps keep precedence (Envoy matches exact domains
  before wildcards); non-matching `*.<domain>` hosts get Envoy's 404.
- `gateway-ingress-auth.yaml` — in `gatewayIngress.ingressNamespace`, named
  `<release-namespace>-<fullname>-openshell-{jwt,cli,services}` so two releases
  never collide there:
  - `RequestAuthentication …-openshell-jwt`: `selector: <ingressSelector>`,
    one `jwtRules` entry `{issuer, audiences: [audience], forwardOriginalToken: true}`
    plus `jwksUri` when set. It validates only requests that carry a token of
    this issuer; requests without one pass to the policies.
  - `AuthorizationPolicy …-openshell-cli`, `to.operation.hosts: [<host>, "<host>:*"]`
    (Istio matches the authority as sent, so the port form is listed too):
    with `policyAction: ALLOW`, one rule `from.source.requestPrincipals: ["<issuer>/*"]`
    plus `remoteIpBlocks: <allowedCidrs>` when non-empty (one `source`, so they
    AND); with `DENY`, a rule `notRequestPrincipals: ["<issuer>/*"]` and, with
    CIDRs, a second rule `notRemoteIpBlocks: <allowedCidrs>` (rules OR, so a
    request passes only with a token and from a listed address).
  - `AuthorizationPolicy …-openshell-services` (when `serviceHosts.enabled`):
    `to.operation.hosts: ["<workspace>--*", …]` for the listed workspaces, with
    `remoteIpBlocks` (ALLOW) or `notRemoteIpBlocks` (DENY) `<allowedCidrs>`.

Changed:

- `deployment.yaml`: gateway `--port` becomes the bind port (`80` when
  `serviceHosts.enabled`, else `gateway.grpcPort`; helper
  `openshell-driver-kyma.gatewayBindPort`); `containerPort grpc` follows; the
  pod gets `sysctls: [{name: net.ipv4.ip_unprivileged_port_start, value: "0"}]`
  (appended to the operator's own) when the bind port is below 1024;
  `--server-san *.<domain>` when `serviceHosts.enabled` (upstream derives the
  service-routing domain from wildcard SANs even with TLS disabled, and keeps
  `openshell.localhost`); `--oidc-roles-claim` when `rolesClaim` is set; with
  `authOnly`, `--oidc-admin-role ""` and `--oidc-user-role ""`.
- `service.yaml`: with `serviceHosts.enabled`, an extra port `http-services`
  (80 → `targetPort: grpc`): under an `http-*` name Istio speaks HTTP/1.1 to
  the gateway, so WebSocket upgrades of sandbox services pass. `grpc` stays
  `gateway.grpcPort`.
- `networkpolicy.yaml`: the driver-pod ingress rule lists the bind port.
- `inference-provider-hook.yaml`: when `gateway.oidc.issuer` is set, the Job
  gets `OPENSHELL_NO_BROWSER=1`, `OPENSHELL_OIDC_CLIENT_SECRET` from
  `clientCredentialsSecret`, registers the gateway with
  `openshell gateway add http://<svc>:<grpcPort> --name in-cluster --oidc-issuer … --oidc-client-id … --oidc-audience …`
  and addresses it with `--gateway in-cluster` (`--gateway-endpoint` bypasses
  the stored token).
- `NOTES.txt`: prints the `gateway add` line and the service-URL shape when
  ingress is enabled.
- `scripts/check-gateway-config.sh`: runs the pinned gateway image with the
  rendered command line plus `--help`, so an unknown flag fails the check.

### 4.3 Render guards (`{{ fail }}`)

| Condition | Message names |
|-----------|---------------|
| `gatewayIngress.enabled` without `gateway.enabled` + `gatewayService.enabled` | the Service the VirtualService routes to |
| `gatewayIngress.enabled` without `gateway.oidc.issuer`, `audience` and `clientId` | the existing refusal to publish an unauthenticated gateway, kept verbatim in spirit |
| `gatewayIngress.enabled` without `gatewayIngress.domain` | the wildcard domain |
| `gatewayIngress.enabled` with `gateway.tls.enabled` | plaintext in-pod only (TLS origination is §11) |
| `serviceHosts.enabled` with empty `allowedCidrs` | browser URLs have no auth |
| `gatewayIngress.domain` not a lowercase DNS name (`*.`, scheme, trailing dot, uppercase) | the value |
| `gatewayIngress.host` not one label under `domain`, or containing `--` | the value |
| an `allowedCidrs` entry that is not an address or CIDR block | the entry |
| `serviceHosts.enabled` with `gateway.grpcPort=80` | the Service's `http-services` port |
| exactly one of `gateway.oidc.adminRole` / `userRole`, or `authOnly` with a role | upstream refuses the former at startup |
| `inferenceProvider.enabled` with `gateway.oidc.issuer` and no `clientId` or `clientCredentialsSecret.name` | the hook cannot authenticate (today the pair is refused outright; this replaces that guard) |

### 4.4 RBAC

None added for the driver. Installing the chart with `gatewayIngress.enabled`
requires rights in `istio-system` (cluster-admin), which the chart's
ClusterRoles already require.

## 5. IAS setup (operator)

One IAS application of type OpenID Connect:

- client id → `gateway.oidc.clientId` and `gateway.oidc.audience`;
- Authorization Code + PKCE enabled; redirect URI `http://127.0.0.1:*/callback`
  (the CLI binds an ephemeral port; if IAS rejects wildcard ports, fall back
  to the device grant: `OPENSHELL_NO_BROWSER=1` without a secret);
- a client secret, stored by the operator in a Secret in the release
  namespace (`clientCredentialsSecret`), used only by the hook Job and smokes;
- issuer `https://<tenant>.accounts.ondemand.com` → `gateway.oidc.issuer`.

The chart never sees tenant, client id or secret values at build time; they
are passed at install like today's OIDC values.

## 6. CLI and browser usage

```bash
openshell gateway add https://openshell.<domain> --name kyma \
  --oidc-issuer https://<tenant>.accounts.ondemand.com \
  --oidc-client-id <client-id> --oidc-audience <client-id>
openshell gateway select kyma
openshell sandbox create --detach --name web --from python:3.12-slim -- python3 -m http.server 8080 --bind 127.0.0.1
openshell service expose web 8080      # → http://default--web.<domain>/
```

The printed URL redirects to HTTPS at Kyma's `http:80` server. The browser must
come from an `allowedCidrs` range; the sandbox service itself may add its own
auth. `curl` works without `--resolve` now (public DNS).

## 7. Security considerations

- **Policy action (found in review).** An ingress gateway without ALLOW
  policies lets everything through, and the first ALLOW policy flips it to
  deny-by-default for every host. The chart therefore defaults to DENY
  policies that name only its own hosts, and writes ALLOW policies only when
  the operator states the gateway already allowlists (`policyAction: ALLOW`).
- **Service-host scope (found in review).** A `*.<domain>` policy would also
  cover the CLI host (voiding the token check for sources in `allowedCidrs`)
  and every other application. Service hosts are matched per workspace, as
  `<workspace>--*`, and the route is limited to the same workspaces, so an
  unlisted workspace is not reachable rather than unfenced.
- **Unauthenticated callers.** With OIDC on, every gateway caller needs a
  bearer, including in-cluster ones; the gateway's ClusterIP stays reachable
  from the cluster (NetworkPolicy unchanged) but is no longer anonymous.
- **Token exposure.** The bearer crosses ingress → pod in plaintext inside the
  cluster network, as the sandbox JWT does today. §11 covers TLS origination.
- **RequestAuthentication scope.** It selects the whole ingress gateway: a
  request to *any* host carrying an invalid token of *our* issuer gets 401
  there. Tokens of other issuers and token-less requests are unaffected.
- **Wildcard VirtualService.** Routes only authorities matching the
  `<ws>--<sb>[--<svc>]` regex; everything else under `*.<domain>` that no exact
  VirtualService claims gets 404 at the edge (and is denied by the allowlists
  first).
- The chart keeps refusing to publish a gateway without OIDC.

## 8. Error handling and failure modes

| Failure | Behaviour |
|---------|-----------|
| Token missing/expired at the edge | 403 `RBAC: access denied` (CLI: `openshell gateway login kyma`) |
| Token valid at the edge, rejected by the gateway (audience mismatch) | gRPC `Unauthenticated`; the plan's live check covers both validators with one token |
| Browser from a non-allowlisted IP | 403 at the edge |
| Sandbox not Ready / service not exposed | gateway's own 404/503 service-routing errors, unchanged |
| Hook Job cannot get a token | Job fails with the CLI's client-credentials error; `helm install` fails as today |

## 9. Verification

The real thing is the acceptance gate; CI is a regression guard.

1. **Render checks** (`scripts/check-chart-render.sh`): a `render-ingress`
   case (all on) asserting VirtualService hosts/gateways/destination/timeout,
   the regex, RequestAuthentication issuer/audiences/`forwardOriginalToken`,
   both AuthorizationPolicies' hosts/principals/ipBlocks and their namespace
   (`ingressNamespace`), deployment args (`--port 80`, two `--server-san`,
   `--oidc-*`), the sysctl, the NetworkPolicy port, the hook Job's OIDC env;
   plus one `bad-*` case per guard in §4.3; `check 5` RBAC table unchanged;
   `helm-lint.yml` renders the ingress case.
2. **Live acceptance** (`scripts/remote-access-check.sh`, run from the laptop
   with the kubeconfig and the IAS values in environment variables; writes no
   domain or secret to disk; prints a pass/fail table):
   - install/upgrade `ods` with `gatewayIngress` on;
   - `openshell gateway add https://openshell.<domain> …` (browser login) then
     `sandbox create` / `exec` / `delete` through the ingress;
   - `curl -X POST https://openshell.<domain>/openshell.v1.OpenShell/ListSandboxes` without a token → 403;
   - `service expose` + `curl https://default--web.<domain>/` → 200 from an
     allowlisted IP; the named-service URL likewise;
   - `sandbox connect`, idle for 6 minutes, then a keystroke → still attached
     (catches Envoy's 5-minute stream-idle timeout; mitigation if it trips:
     an opt-in EnvoyFilter on the ingress listener, `streamIdleTimeout` value);
   - hook Job: `inferenceProvider.enabled` with OIDC → provider registered;
   - cleanup, revert, nothing left in `istio-system` but the operator's own
     policies.
3. **No mock-OIDC smoke in CI.** The first draft proposed a kind smoke with a
   mock issuer. Upstream's gateway accepts a plain-HTTP issuer only on a
   numeric loopback address (`--oidc-dangerously-allow-insecure-http`), so an
   in-cluster mock would need test-only sidecars in the gateway pod and the
   hook Job, or a CA the gateway image trusts. CI instead proves what it can
   without an issuer: the render checks above, and `check-gateway-config.sh`
   running the pinned gateway image against the rendered command line. The
   OIDC paths are proven by the live acceptance run.

## 10. Documentation and versioning

- `docs/production-deployment.md`: the "Public APIRule" chapter becomes
  "Remote access" (IAS setup, values, allowlist breadth, URL behaviour, what
  stays port-forward-only).
- `docs/getting-started.md` Appendix B rewritten for `gatewayIngress`.
- `docs/kyma-vs-openshift.md` "External access", `docs/openshell-api-programmatic-usage.md`
  endpoint table, `docs/internal/runbook-upstream-sync.md` (new render case).
- `CHANGELOG.md` 0.10.0: breaking removal of `gatewayApirule`, migration table
  (`gatewayApirule.host` → `gatewayIngress.host`, rules → policies), new values.
- Chart/Cargo version 0.10.0.

## 11. Follow-ups (not in this design)

- TLS origination ingress → gateway: `gateway.tls.enabled` with a
  `DestinationRule` (SIMPLE, CA in an `istio-system` Secret), gateway bound on
  443 so URLs print as `https://…/` natively.
- Browser SSO for service hosts via an ext-authz provider, once the cluster's
  Istio CR configures one.
- RBAC roles from IAS groups (`rolesClaim: groups`).

## 12. Risks and verification items carried into the plan

| Risk | Check | Fallback |
|------|-------|----------|
| IAS rejects `http://127.0.0.1:*/callback` | IAS app registration | device grant (`OPENSHELL_NO_BROWSER=1`) |
| The hook Job's client-credentials login or its token is refused (upstream's CLI takes `--oidc-issuer` for any URL scheme, per its source; unproven against IAS) | live hook run | register the provider from an authenticated CLI session (docs step 3b) |
| The cluster rejects the pod sysctl `net.ipv4.ip_unprivileged_port_start` | live install | `serviceHosts.enabled=false` (CLI access is unaffected) |
| RequestAuthentication strips the token despite `forwardOriginalToken` | live: gateway accepts the request | none needed if it forwards |
| Envoy stream idle timeout cuts idle `connect` sessions | live 6-minute idle test | opt-in EnvoyFilter |
| Wildcard VirtualService conflicts with Kyma-managed VirtualServices | `istioctl analyze`-style check in the live script, Kyma Istio module status | per-sandbox exact-host VirtualServices for unnamed services only |
| Audience mismatch between PKCE and client-credentials tokens | live hook run | a second audience value is not supported by the gateway; keep one IAS application |
