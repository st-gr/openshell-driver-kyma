# Remote gateway access on Kyma — design (revision 2)

**Status:** approved (2026-10-01), with the four recommended options of §11.
Targets chart/driver 0.10.0.
**Supersedes:** revision 1 of this document (2026-09-30). Revision 1 was
implemented on PR #81 and live-tested; it is withdrawn because it broke a
neighbouring application on the shared ingress gateway (§2). Nothing of it is
released. The implementation plan is
`docs/superpowers/plans/2026-10-01-remote-gateway-access-rev2.md`; the plan of
2026-09-30 describes revision 1 and is kept as the record of what PR #81 holds.
**Depends on:** v0.9.1 (sandbox pod exposure removed; `openshell service expose`
documented).

## 1. Goal

Use the OpenShell CLI and a browser against sandboxes on a Kyma cluster without a
`kubectl port-forward`, the way upstream intends a Kubernetes gateway to be
reached: the **gateway** terminates TLS and authenticates with OIDC; the cluster's
ingress only routes to it. Sandbox pods are never published.

```bash
openshell gateway add https://openshell.<domain> --name kyma \
  --oidc-issuer <issuer> --oidc-client-id <client-id> --oidc-audience <audience>
openshell sandbox create --detach --name web --from python:3.12-slim \
  -- python3 -m http.server 8080 --bind 127.0.0.1
openshell service expose web 8080        # prints https://default--web.<domain>/
openshell sandbox connect web            # works, including long idle shells
```

The identity provider is any OIDC provider that issues JWT access tokens. SAP IAS
is the intended production provider (§8); the repository's Keycloak fixture is the
test provider.

Out of scope: TLS passthrough and client certificates end to end (§12), Gateway
API objects (not installed on Kyma today; §12), browser SSO for service URLs,
upstream's WebSocket tunnel (Cloudflare-Access-specific).

## 2. What revision 1 got wrong

| # | Defect | Consequence | Rule for this revision |
|---|---|---|---|
| W1 | A `RequestAuthentication` on the shared ingress gateway, to check OpenShell tokens at the edge. It has no host scope: Envoy answered 401 to **every** Bearer token it could not validate, on every host. | A neighbouring application's login looped, and API calls with Bearer keys to other hosts were refused, for about 24 minutes. | Nothing this chart renders may apply to the ingress gateway as a whole. Every policy in the ingress namespace names this release's hosts. No `RequestAuthentication`, ever. |
| W2 | The claim "requests with another issuer's token are unaffected" went into the spec, the template and the docs without a test; the review accepted it; the acceptance run probed only OpenShell's hosts. | W1 reached a live cluster. | The acceptance run probes neighbouring hosts before and after the install with no token, a foreign JWT and a non-JWT Bearer key, and rolls back on any change (§10.2). |
| W3 | "Bind port 80 so the printed service URL is right." Upstream's CLI replaces the URL's port with the gateway endpoint's and keeps the scheme the gateway reports. | The CLI printed `http://<host>:443/`. | The gateway reports `https` because it serves TLS (D3). No privileged port, no sysctl. |
| W4 | An ALLOW policy flips an ingress gateway without ALLOW policies to deny-by-default; a `*.<domain>` policy covers other hosts. | Found in review, fixed before the live run. | Kept from revision 1: `policyAction`, per-workspace service hosts (D6, D7). |

## 3. Upstream's model

Upstream's chart (v0.1.2) offers three ways to reach a Kubernetes gateway. None
has an authentication object at the edge; the gateway validates OIDC tokens
itself.

| Upstream | Edge | Gateway pod |
|---|---|---|
| `openshiftRoute` | TLS passthrough | terminates TLS |
| `grpcRoute`, HTTPS listener, `server.disableTls=true` | terminates TLS | plaintext, OIDC |
| `grpcRoute` + `backendTLSPolicy` | terminates TLS, re-encrypts, validates the pod's certificate against the chart's CA | TLS on, client certificates off, OIDC |

This design is the third shape, written with Istio objects because Gateway API is
not installed on Kyma today: the Kyma gateway terminates public TLS, a
`VirtualService` routes by host, a `DestinationRule` originates TLS to the gateway
pod and validates its certificate.

## 4. Decisions

| # | Decision | Why |
|---|----------|-----|
| D1 | The gateway is the only authenticator. No token check at the ingress. | Upstream's model; W1. The live run of revision 1 showed the gateway refusing unauthenticated gRPC on its own. |
| D2 | Plain Istio objects, all host-scoped: `VirtualService`s and a `DestinationRule` in the release namespace; in the ingress namespace only `AuthorizationPolicy`s whose every rule names this release's hosts, and one Secret holding the public CA certificate. | W1. An `AuthorizationPolicy` rule with `hosts` is host-scoped; a `RequestAuthentication` is not. |
| D3 | With remote access the gateway serves TLS (`gateway.tls.enabled`) without client-certificate verification, on its usual port, and the ingress re-encrypts to it. | Upstream's default is TLS on. The gateway then reports `https://<host>:8080/` and the CLI, replacing the port with the endpoint's, prints `https://<host>/` (upstream unit-tests exactly this case). The ingress-to-pod hop is encrypted and the pod's certificate verified. |
| D4 | The ingress validates the gateway's certificate against the chart's CA (`DestinationRule` `credentialName`), not `insecureSkipVerify`. | Parity with `backendTLSPolicy`. Cost: one Secret with a public CA certificate in the ingress namespace, kept current by a hook (§6.4). |
| D5 | The PKI hook mints the server certificate with this release's Service names. | Today it passes no names, so the certificate carries only upstream's defaults (`openshell`, `openshell.openshell.svc…`; verified on the live install) and no in-cluster client can verify it. `gateway.tls.enabled` has therefore never worked in this chart. Upstream's chart passes its Service names the same way. |
| D6 | `gatewayIngress.policyAction` (`DENY` default, `ALLOW` for a gateway that already allowlists) decides how the source-address fence is written. DENY with `allowedCidrs` is refused on an ingress gateway that has TCP or TLS-passthrough servers. | Unchanged from revision 1 (W4). The refusal is from the review of this revision: Istio builds a DENY rule for a non-HTTP server without its hosts (an HTTP-only field) and keeps the source addresses, so the fence would refuse every connection to such a server from another address. ALLOW rules with HTTP-only fields are skipped there. |
| D7 | Service hosts are published per workspace (`serviceHosts.workspaces`): routes and policies match `<workspace>--*`, behind `allowedCidrs`. | Unchanged from revision 1. Upstream's gateway runs only gRPC through its authenticators; requests to a service host go to the sandbox relay unauthenticated unless client certificates are required (source: `multiplex.rs`, `http.rs`; the live run of revision 1 served a token-less request). The source-address fence is therefore the only protection, and the chart refuses to publish service hosts without CIDRs. |
| D8 | `gateway.oidc.authOnly` is explicit; `adminRole` and `userRole` are set together. | Unchanged: upstream defaults the roles to `openshell-admin` / `openshell-user`. |
| D9 | The provider hook authenticates with the client-credentials grant and trusts the chart's CA. | Unchanged grant; new: the gateway speaks TLS inside the cluster too. |
| D10 | `gatewayIngress` replaces `gatewayApirule`; a leftover `gatewayApirule.enabled` fails the render. | Unchanged. |

## 5. Architecture and flows

```text
CLI ─OIDC code+PKCE─▶ issuer
CLI ─gRPC + bearer, TLS─▶ https://openshell.<domain>      Kyma gateway (TLS, *.<domain> certificate)
    [optional fence: AuthorizationPolicy, hosts openshell.<domain>, source addresses]
    → VirtualService (host) → DestinationRule: TLS, CA-verified, SNI = Service name
    → gateway pod :8080 (TLS; OIDC validates the bearer)

browser ─▶ https://default--web.<domain>/
    fence: AuthorizationPolicy, hosts <workspace>--*, source addresses (mandatory)
    → VirtualService (*.<domain>, authority regex of the published workspaces)
    → DestinationRule (same) → gateway pod :8080 → relay → sandbox loopback port

supervisors   ─sandbox JWT, TLS (chart CA)─▶ Service :8080
provider hook ─client credentials, TLS (chart CA)─▶ Service :8080
```

The ingress gateway gains routes for this release's hosts and policies that name
only those hosts. It gains nothing that selects it without a host and no token
handling.

## 6. Chart surface

Relative to `main` (0.9.1). The code of revision 1 on PR #81 is reworked in place;
§6.6 lists what changes there.

### 6.1 Values

```yaml
gatewayIngress:
  enabled: false
  domain: ""                      # required: the cluster's wildcard domain, without "*."
  host: ""                        # CLI/API host; empty = openshell.<domain>
  istioGateway: kyma-system/kyma-gateway
  ingressNamespace: istio-system
  ingressSelector:
    istio: ingressgateway
  policyAction: DENY              # DENY: gateway without ALLOW policies; ALLOW: one that already allowlists
  allowedCidrs: []                # source addresses; required for serviceHosts, optional for the CLI host
  serviceHosts:
    enabled: false
    workspaces: [default]

gateway:
  tls:
    enabled: false                # must be true with gatewayIngress
    clientCa:
      enabled: false              # must stay false with gatewayIngress: the ingress presents no client certificate
  oidc:
    issuer: ""
    audience: ""
    clientId: ""
    authOnly: false
    rolesClaim: ""
    adminRole: ""
    userRole: ""
    clientCredentialsSecret:
      name: ""
      key: client-secret
      clientId: ""

networkPolicy:
  extraEgress: []                 # e.g. an issuer published through this cluster's own ingress
```

Removed against revision 1: `gateway.oidc.jwksUri` (it fed only the
`RequestAuthentication`).

### 6.2 Objects

In the release namespace, with `gatewayIngress.enabled`:

- `VirtualService <fullname>-gateway`: `hosts: [<host>]`, the Istio gateway, one
  route to the Service's `grpc` port. No `timeout` field (Istio rejects `0s`; its
  default is none, which the streaming RPCs need).
- `VirtualService <fullname>-sandbox-services` (with `serviceHosts.enabled`):
  `hosts: ["*.<domain>"]`, one route matched by the authority regex
  `^(<published workspaces>)--<sandbox>(--<service>)?\.<domain>(:<port>)?$`, to the
  Service's `http-services` port.
- `DestinationRule <fullname>-gateway-tls`: `host: <fullname>.<ns>.svc.cluster.local`,
  `exportTo: [<ingressNamespace>]` so only the ingress gateway uses it,
  `trafficPolicy.tls: {mode: SIMPLE, credentialName: <ns>-<fullname>-gateway-ca,
  sni: <service>, subjectAltNames: [<service>]}` with `<service>` the same FQDN, so
  the name is verified whatever Istio's defaults are. `exportTo` also keeps the
  rule from sandboxes with an Istio sidecar, which speak TLS to the gateway
  themselves.

In `ingressNamespace`, named `<ns>-<fullname>-…` so two releases never collide:

- `Secret <ns>-<fullname>-gateway-ca`: key `ca.crt`, the chart CA's public
  certificate (§6.4), and, while its hook runs, the `Role` and `RoleBinding`
  `<ns>-<fullname>-gateway-ca-hook` that let the hook write it.
- `AuthorizationPolicy <ns>-<fullname>-openshell-cli`, hosts `[<host>, "<host>:*"]`:
  with `policyAction: ALLOW`, one ALLOW rule, with `from.source.remoteIpBlocks`
  when `allowedCidrs` is set and without `from` otherwise; with `DENY`, one DENY
  rule `notRemoteIpBlocks` when `allowedCidrs` is set, and no policy at all
  otherwise.
- `AuthorizationPolicy <ns>-<fullname>-openshell-services` (with
  `serviceHosts.enabled`): hosts `["<workspace>--*", …]`, `remoteIpBlocks` (ALLOW)
  or `notRemoteIpBlocks` (DENY) `allowedCidrs`.

No `RequestAuthentication`. No policy rule without `to.operation.hosts`.

### 6.3 Gateway pod and Service

- TLS on: `--tls-cert`, `--tls-key` from the server-TLS Secret (the existing wiring
  of `gateway.tls.enabled`); no `--tls-client-ca`. The gateway keeps binding
  `gateway.grpcPort` (8080), as upstream's chart does. Revision 1's port-80
  binding, its sysctl and the bind-port helper are removed.
- `--server-san "*.<domain>"` with `serviceHosts.enabled`, which is how upstream
  learns the service-URL domain. `--oidc-*` flags as in revision 1.
- Service: `grpc` (`gateway.grpcPort`) and, with `serviceHosts.enabled`,
  `http-services` (80 → `grpc`), so Istio speaks HTTP/1.1 for browser traffic and
  WebSocket upgrades pass. Both carry TLS to the pod.
- The driver hands sandboxes `https://<Service>:<grpcPort>` and the client-TLS
  Secret (existing logic of `gateway.tls.enabled`), so supervisors verify the
  gateway against the chart CA.
- Service URLs: the CLI prints `https://<workspace>--<sandbox>.<domain>/`. Clients
  of the raw API or the SDK receive the gateway's own value,
  `https://<host>:8080/`, as from any upstream gateway behind a port-mapping edge,
  and must drop the port.

### 6.4 PKI

- The PKI hook (`openshell-gateway generate-certs`, upstream's own job) gains
  `--server-san` for `<fullname>`, `<fullname>.<ns>`, `<fullname>.<ns>.svc`,
  `<fullname>.<ns>.svc.cluster.local`, `localhost` and `127.0.0.1`, mirroring
  upstream's chart. It applies whenever the hook runs, with or without remote
  access.
- CA for the ingress: the chart renders `Secret <ns>-<fullname>-gateway-ca` in
  `ingressNamespace` **without data**, and a post-install, post-upgrade and
  post-rollback hook Job writes `ca.crt` into it (a rollback from a revision
  without remote access recreates the Secret empty). The CA does not exist when the chart is rendered (the
  PKI hook creates it), and a manifest without data means Helm never overwrites
  what the Job wrote. Helm owns the Secret, so `helm uninstall` removes it. The
  Job mounts only `ca.crt` of the server-TLS Secret (it never sees the key and
  needs no access to Secrets in the release namespace) and may `get` and `patch`
  exactly that one Secret in `ingressNamespace`, nothing else there. Its image
  (`gatewayIngress.caHook.image`: a shell, `base64` and `kubectl`) is pinned by
  digest. Until the Job has run on a first install the ingress answers 503.

### 6.5 Provider hook

With `gateway.oidc.issuer` and `gateway.tls.enabled`: `GATEWAY_URL` is
`https://<Service>:<grpcPort>`; the Job mounts the CA (`ca.crt` of the client-TLS
Secret) and, once `openshell gateway add … --oidc-*` has registered the gateway,
places it at the CLI's CA location for that gateway
(`${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateways/in-cluster/mtls/ca.crt`,
read from upstream's `tls.rs` and `paths.rs`). The existing
refusal of `inferenceProvider` + `gateway.tls.enabled` narrows to the case without
OIDC.

### 6.6 Changes to the code on PR #81

| Keep | Change | Remove |
|---|---|---|
| `gatewayIngress` values and guards; `policyAction`; per-workspace service hosts; `networkPolicy.extraEgress`; OIDC values, `authOnly`, role guards; hook client credentials and `clientCredentialsSecret.clientId`; `http-services` port; the leftover-`gatewayApirule` guard; the flag check in `check-gateway-config.sh`; `e2e/keycloak`; `remote-access-check.sh` | The CLI-host policy loses its token condition; the guard on `gatewayIngress` + `gateway.tls.enabled` inverts (TLS required, client CA forbidden); PKI hook gains SANs; provider hook over TLS; acceptance checks (§10.2); docs, NOTES and CHANGELOG | `RequestAuthentication`; `gateway.oidc.jwksUri`; the port-80 binding, its sysctl and helper; every statement about edge token validation and about `http://<host>:443/` |

### 6.7 Render guards

Kept from revision 1: no publishing without `gateway.oidc.{issuer,audience,clientId}`;
domain, host, CIDR and workspace shapes; boolean types; non-empty
`ingressSelector`, `ingressNamespace`, `istioGateway`; `policyAction` in
`DENY`/`ALLOW`; `serviceHosts` needs `allowedCidrs`; role pairing; leftover
`gatewayApirule.enabled`.

New: `gatewayIngress.enabled` requires `gateway.tls.enabled=true`,
`gateway.tls.clientCa.enabled=false` and a `gatewayIngress.caHook.image`; and
`policyAction: DENY` with `allowedCidrs` is refused when a Gateway on the ingress
gateway has a server that is not HTTP. The chart reads the Gateways with `lookup`,
which sees nothing in `helm template`; `scripts/ingress-non-http-servers.sh` makes
the same check with kubectl, and the live check and the Keycloak fixture call it.

## 7. Migration

- From 0.9.x: `gatewayApirule` → `gatewayIngress` (table in the CHANGELOG).
- **Existing installs that turn on `gateway.tls.enabled`** must regenerate the PKI
  once, because the existing server certificate lacks the Service names and
  upstream's job skips existing Secrets:
  `kubectl delete secret -n <ns> <fullname>-server-tls <fullname>-client-tls <fullname>-jwt-keys`
  before the upgrade (all three: the job refuses a partial set). Existing sandboxes
  must be recreated: their pods carry the plaintext gateway endpoint and tokens of
  the old signing key. Installs that never enable gateway TLS need nothing.
- A port-forward to a TLS gateway needs the chart CA on the client
  (`ca.crt` of the client-TLS Secret, in the gateway's `mtls/` directory); the docs
  give the two commands.

## 8. Identity providers and IAS

The chart is provider-neutral: issuer, audience, the CLI's public client, the
roles claim and role names (or `authOnly`), and for the provider hook a client
secret with, where the provider needs one, a separate confidential client.

SAP IAS is expected to work as such a provider and is **not verified**: no tenant
was available. Three things must hold there, and the acceptance script proves
them when someone runs it against a tenant:

1. access tokens are JWTs whose `aud` contains the configured audience;
2. a public client with PKCE accepts a loopback redirect on an arbitrary port
   (otherwise the CLI's device grant, `OPENSHELL_NO_BROWSER=1`);
3. group membership arrives in a claim the gateway can read (`rolesClaim`), or
   `authOnly` is used; the hook's client needs the admin role under RBAC.

The docs describe IAS as a configuration recipe marked unverified until then.
Keycloak (`e2e/keycloak`, upstream's development realm) is the verified provider.

## 9. Security considerations

- **Shared ingress.** W1 is the governing constraint: host-scoped objects only.
  The render check enforces it on every render (§10.1). Two limits, found in the
  review of this revision: a DENY rule is host-scoped only on HTTP servers (D6:
  refused where it would not be), and `<workspace>--*` is a prefix, so it also
  matches another application's host whose name begins with `<workspace>--`.
- **The source-address fence** compares the client address the ingress gateway
  sees. Where the mesh trusts forwarding hops (`numTrustedProxies`) and nothing
  in front rewrites `X-Forwarded-For`, a client can forge it. The live check
  tests that with a forged header; the docs tell operators to.
- **Who can reach what.** The gateway API: anyone who can reach the CLI host
  (optionally fenced by `allowedCidrs`), authenticated by the gateway. A published
  service URL: any source in `allowedCidrs`, not authenticated by the gateway
  (D7); put authentication into the service if the address ranges are shared.
  In-cluster callers reach both through the Service without passing the ingress.
- **No edge token check.** An unauthenticated request now reaches the gateway
  and is refused there instead of at the ingress. That is upstream's model; the
  optional source-address fence on the CLI host restores an outer layer.
- **`authOnly`** makes every identity the issuer authenticates a platform admin.
- **The hook's client secret** is a platform-admin credential under RBAC.
- **The CA Secret in the ingress namespace** holds a public certificate; its hook
  can patch only that Secret.
- The chart keeps refusing to publish a gateway without OIDC.

## 10. Verification

### 10.1 Render checks (`scripts/check-chart-render.sh`)

- Exact objects for both policy actions, with and without `allowedCidrs` and
  service hosts; the `DestinationRule`; the CA Secret's name and namespace.
- **Blast-radius assertions, over every render in the suite:** no
  `RequestAuthentication`; every `AuthorizationPolicy` rule has non-empty
  `to.operation.hosts`, none starting with `*`; the only objects rendered into
  `ingressNamespace` are `AuthorizationPolicy`s, the CA Secret and its hook's
  `Role` and `RoleBinding`, which grant `get` and `patch` on that Secret alone.
- PKI hook arguments carry the Service names; gateway arguments have the TLS
  flags and no client CA; the guards of §6.7.
- `scripts/check-gateway-config.sh` keeps proving the pinned image accepts the
  rendered flags.

### 10.2 Live acceptance (`scripts/remote-access-check.sh`)

Runs only with the operator's explicit go-ahead. New against revision 1:

- **Neighbour probes.** `OSH_NEIGHBOUR_URLS` lists URLs of other applications
  behind the same ingress; the script refuses to install without it. Before the
  install it records each one's HTTP status with no token, with a foreign JWT as
  Bearer and with a non-JWT Bearer key; it repeats them every 10 s while the
  upgrade runs and once after it. A difference that persists over two rounds
  fails the run and rolls the release back to the revision it found, before
  anything else happens. `scripts/remote-access-check-test.sh` proves that
  without a cluster (a local neighbour that starts refusing Bearer tokens, and
  stand-ins for helm and kubectl), and CI runs it.
- **PKI.** The script does not upgrade a release whose gateway certificate lacks
  the Service name unless `OSH_REGENERATE_PKI=1` tells it to delete the three PKI
  Secrets first (§7). A certificate it cannot read is never deleted.
- **Nothing is changed that cannot be undone or watched** (from the review): the
  release's latest revision must be a deployed one, which is the rollback target;
  every neighbour must answer; the probes record, besides the status, whether an
  answer is the ingress gateway's own refusal, so a 401 that moves from an
  application to the ingress gateway shows; `OSH_POLICY_ACTION` is mandatory, and
  under DENY the ingress gateway must have no server that is not HTTP.
- Requests with a forged `X-Forwarded-For` of one to four entries (a mesh that
  trusts N hops ignores a shorter header) must be answered like plain ones: on
  the neighbour URLs before the upgrade, where a change refuses the run, and on
  the service URL after it. `OSH_FENCE_ONLY=1` runs that test alone.
- The printed service URL must be `https://default--<sandbox>.<domain>/` exactly.
- A call without a token must be refused by the **gateway** (`grpc-status 16`).
- Kept: sandbox create and exec through the ingress, the service URL serving the
  sandbox's page, an unpublished workspace not served, the hook's provider present
  by name, an exec stream idle for 400 s.

### 10.3 Fixture

`e2e/keycloak` stays as it is (its own policy is host-scoped and follows
`OSH_POLICY_ACTION`); its `values.yaml` keeps the egress rule for an issuer behind
the cluster's own ingress. The acceptance script sets `gateway.tls.enabled`.

## 11. Decisions for the reviewer

Decided on 2026-10-01: the recommended option of each.

1. **Certificate verification at the ingress (D4).** Recommended: verify against
   the chart CA, at the price of one Secret (a public certificate) in the ingress
   namespace and a small hook with rights to that Secret alone. Alternative:
   `insecureSkipVerify: true`, encrypted but unverified, with nothing in the
   ingress namespace besides the policies and one moving part fewer.
2. **Gateway port in the pod (D3).** Recommended: 8080, as upstream; the CLI
   prints the right URL, raw API and SDK clients get `:8080` and must drop it.
   Alternative: bind 443 with the unprivileged-port sysctl (proven on this
   cluster in revision 1); every client then gets `https://<host>/`, at the cost
   of a pod sysctl upstream does not use.
3. **One shape or two.** Recommended: remote access always means TLS in the pod.
   The plaintext shape (upstream's second row in §3) would also work without the
   edge token check, but it prints the wrong URL and doubles the test matrix.
4. **Release.** Recommended: rework PR #81 in place and release this as 0.10.0;
   nothing of revision 1 ships.

## 12. Follow-ups (not in this design)

- Gateway API (`grpcRoute`, `backendTLSPolicy`): adopt upstream's templates when
  Kyma offers Gateway API; the objects of §6.2 map onto them one to one.
- TLS passthrough with a dedicated host and certificate, for client certificates
  end to end.
- Verifying IAS against a tenant (§8).
- Browser SSO for service hosts, once the cluster offers an external authorizer.

## 13. Risks carried into the plan

All are read from source or documentation and unproven live in this shape.

| Risk | Check | Fallback |
|------|-------|----------|
| Istio does not accept a CA-only Secret with key `ca.crt` under `credentialName` (its 1.30.4 source reads `cacert`, then `ca.crt`) | live, first | key `cacert`; or decision 1's alternative |
| Istio's HTTP/1.1 upstream over TLS on the `http-services` port fails against the gateway's listener (upstream's source offers `h2` and `http/1.1` by ALPN) | live service URL | route service hosts to the `grpc` port |
| The CA Secret is empty until the Job has run on a first install | live first install | the ingress answers 503 for those seconds; documented |
| A sandbox with an Istio sidecar (`driver.istioInjectSandboxes`) cannot reach a gateway that serves TLS: the sidecar may treat the Service's `grpc` port as plaintext HTTP/2 | not covered by the live run (the test cluster does not inject) | documented as unverified under Known limitations |
| Upstream's CLI does not use the CA at the gateway's `mtls/ca.crt` for an OIDC gateway | live hook run | `--gateway-insecure` in the Job, in-cluster only |
| Supervisors fail to verify the regenerated certificate | live sandbox create | the supervisor log; the SAN list is the first suspect |
| The PKI regeneration on an existing install is forgotten | the gateway serves the old certificate; in-cluster clients fail to verify it | §7; the chart cannot detect it at render time |
| A neighbouring application is affected again | neighbour probes with automatic rollback (§10.2) | none: the run stops |
