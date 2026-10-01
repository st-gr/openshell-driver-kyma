# Production deployment

This runbook is for operators going beyond the in-cluster /
port-forward path covered by [`getting-started.md`](getting-started.md).
It assumes you've already verified the chart works behind a port-forward
and now want a production-grade install: OIDC user auth, remote access
through the cluster's Istio ingress gateway, image digests pinned, an
`imagePullSecrets`
where needed.

The cluster's CNI must enforce `NetworkPolicy` in every sandbox namespace:
upstream's isolation fence for sandbox pods is a set of NetworkPolicies, and
without enforcement sandbox pods can bypass OpenShell's network policy.

## Decision: how do users reach the gateway?

| Option | Auth | Pros | Cons |
|---|---|---|---|
| Remote access (`gatewayIngress`) + OIDC | OIDC at the edge and at the gateway + sandbox-JWT | Standard OIDC login, no port-forward, MFA from your IdP | Public attack surface; needs rights in `istio-system` |
| SCC Service Channel + port-forward | None at gateway, OIDC at kubectl | No public exposure | All users must be on corporate VPN; see [`cloud-connector-setup.md`](cloud-connector-setup.md) |
| Mesh-internal only | sandbox-JWT only (CLI requires `allow_unauthenticated_users`) | Simplest | Caller must be inside the cluster |

The remote-access option is the focus of the rest of this doc.

## 1. Provision an OIDC client

Any OIDC provider that issues **JWT access tokens** works: the `openshell` CLI
sends the access token, and both the ingress gateway and the OpenShell gateway
validate its signature, issuer and audience. You need:

- **A public client for the CLI** → `gateway.oidc.clientId`: Authorization
  Code with PKCE and the redirect URI `http://127.0.0.1:*/callback` (the CLI
  listens on an ephemeral loopback port during login). If your provider
  rejects a wildcard port, log in with the device grant instead
  (`OPENSHELL_NO_BROWSER=1 openshell gateway add …`).
- **An audience** → `gateway.oidc.audience`: the value the access token's
  `aud` claim must contain. Some providers put the client id there; others
  (Keycloak) need an audience mapper on the client.
- **The issuer URL** → `gateway.oidc.issuer`, over HTTPS. Keep it reachable
  from the cluster (the gateway and the ingress gateway fetch its JWKS) and
  from your users' laptops (the CLI redirects to it on first auth).

  If the issuer is published through **this cluster's own ingress gateway**,
  the gateway pod reaches it on the ingress pod's container port (8443 for
  Istio) wherever the CNI applies NetworkPolicy after DNAT (Calico does), and
  the chart's policy for the pod allows 443 only. The gateway then fails at
  startup with `OIDC discovery request failed`. Add the rule shown at
  `networkPolicy.extraEgress` in `values.yaml`. The same goes for an ingress
  allowlist: it must admit the cluster's own pod and node networks to the
  issuer's host.
- **A client secret**, only if you use `inferenceProvider`: the chart's
  provider hook authenticates with the client-credentials grant. If your
  provider wants a separate confidential client for that grant (Keycloak
  does), name it in `gateway.oidc.clientCredentialsSecret.clientId`; its
  tokens need the same issuer and audience. Store the secret in a Secret you
  manage, never in a values file:

  ```bash
  kubectl -n openshell-system create secret generic openshell-oidc-client \
    --from-literal=client-secret='<the client secret>'
  ```

**Authorization.** Upstream's gateway defaults to RBAC: a token needs the role
`openshell-admin` or `openshell-user` in the claim `realm_access.roles`
(Keycloak's shape). Choose one:

- keep the defaults and grant those roles in your provider, or name your own
  with `gateway.oidc.rolesClaim`, `adminRole` and `userRole` (both roles must
  be set together). The client the provider hook uses needs the **admin**
  role: it registers a platform-wide provider profile. The Secret holding its
  client secret is therefore a platform-admin credential;
- or set `gateway.oidc.authOnly: true` to accept every identity the issuer
  authenticates. Every such identity is then a platform admin of the gateway,
  across all workspaces: who may log in is decided in the provider alone.

## 2. Decide on chart values

Create a values overlay file (NEVER commit it; it carries cluster IDs
and audience names). Example skeleton:

```yaml
# my-values.prod.yaml — gitignored, kept in your team's secret store

namespace: openshell-system

image:
  # Pin the driver image by digest: a tag that starts with `sha256:` renders
  # as <repository>@sha256:<digest>. Resolve a digest once with:
  #   docker buildx imagetools inspect ghcr.io/st-gr/openshell-driver-kyma:<version> \
  #     --format '{{json .Manifest.Digest}}'
  repository: ghcr.io/st-gr/openshell-driver-kyma
  tag: "sha256:<digest>"
  pullPolicy: IfNotPresent

# If your driver image is in a private registry:
imagePullSecrets:
  - name: ghcr-pull-secret

gateway:
  enabled: true
  # The gateway, supervisor and sandbox-runtime images default to digests of
  # the upstream OpenShell release named by `upstream.version` (v0.1.2). Leave
  # them alone unless you move that version too: they must match each other
  # and the driver.

  # OIDC is required for remote access: the chart refuses to publish an
  # unauthenticated gateway.
  oidc:
    issuer: "https://<your-issuer>"
    audience: "<audience>"
    clientId: "<client-id>"
    # Roles: upstream's defaults (openshell-admin / openshell-user in
    # realm_access.roles) apply unless you set rolesClaim + adminRole +
    # userRole, or authOnly: true.
    clientCredentialsSecret:       # only with inferenceProvider
      name: openshell-oidc-client

  sandboxJwt:
    enabled: true
    ttlSecs: 3600

  # Persist the gateway's DB across pod restarts. Without this, every
  # gateway pod restart wipes the provider profile and provider you register
  # in step 3b, so sandboxes cannot be created with `--provider` until you
  # register them again.
  dbPersistence:
    enabled: true
    dbUrl: ""               # empty = chart renders a PVC; set to postgres URL for external DB
    storageSize: 1Gi
    storageClassName: ""

gatewayService:
  enabled: true

gatewayIngress:
  enabled: true
  domain: "<your-cluster-id>.kyma.ondemand.com"   # the Kyma gateway's *.<domain>
  # DENY or ALLOW: read "Choose the policy action" in step 3 before installing.
  policyAction: DENY
  # Source addresses allowed through the ingress gateway. Optional for the CLI
  # host (a token is required either way), required for serviceHosts.
  allowedCidrs: ["203.0.113.0/24"]
  # Publish `openshell service expose` URLs for these workspaces; see "Reaching
  # a service inside a sandbox" below.
  serviceHosts:
    enabled: true
    workspaces: [default]

# `inferenceProvider` works with OIDC when gateway.oidc.clientCredentialsSecret
# names the client secret: its post-install Job logs in with the
# client-credentials grant. Without a client secret, leave it disabled, register
# the provider yourself from an authenticated CLI session (step 3b), and give
# sandboxes the endpoint and model it would have set:
driver:
  sandboxEnv:
    - ANTHROPIC_BASE_URL=http://gateway.your-llm-ns.svc.cluster.local:8080/anthropic
    - ANTHROPIC_MODEL=claude-opus-4-7
  # Silence Claude's optional telemetry endpoints when the in-cluster
  # gateway can't service them.
  disableClaudeTelemetry: true
```

## Why these settings keep the agent isolated

The chart follows upstream OpenShell's model (NVIDIA's
[Inference](https://docs.nvidia.com/openshell/how-it-works/inference) and
[Provider profiles](https://docs.nvidia.com/openshell/how-it-works/providers/profiles)
pages): a credential and the network access it needs travel together, as a
provider profile that you attach to a sandbox. Each sandbox is a pair of pods,
a workload pod that runs the agent and a hardened supervisor pod. The data
flow:

```text
agent process   ── ANTHROPIC_BASE_URL, placeholder key ──▶  its supervisor pod
(workload pod: no network of its own,                          │  checks the request against the
 ingress only from its supervisor)                             │  profile-derived network policy,
                                                               │  substitutes the real key
                                                               ▼  (only at the profile's host:port)
                                                       your in-cluster LLM upstream
```

Who can see and do what:

| Component | Sees the API key? | Can dial the upstream? |
|---|---|---|
| **Agent** (workload pod) | no — only a placeholder | no — upstream's NetworkPolicy gives the workload no egress; its traffic goes through its supervisor |
| **Supervisor pod** | resolves it, only for requests to the profile's endpoint | yes — upstream gives supervisor pods their own egress policy (allow-all) |
| **Gateway sidecar** (driver+gateway pod) | yes (the provider record in its DB) | no — it holds the provider and forwards no request bytes |

The key is bound to the endpoint's host and port (the path of the endpoint
URL is not part of the binding: `inferenceProvider.baseUrl` when the chart's
hook registers the provider, `ANTHROPIC_BASE_URL` on the OIDC path above).
`binaries` in the profile gates which processes may reach the endpoint
(`inferenceProvider.binaries` with the hook; the profile you import in step 3b
on the OIDC path); upstream v0.1.2 does not yet restrict the key by calling
binary, so treat the endpoint as the scope.

The provider and its profile live in the gateway's DB. That is what
`gateway.dbPersistence.enabled` provides: without it, every gateway pod
restart wipes them, and sandboxes cannot be created with `--provider` until
they are registered again (step 3b).

**NetworkPolicies.** Upstream fences sandboxes per namespace
(`openshell-sandbox-workloads` and `openshell-sandbox-supervisors`, created by
the driver). Kubernetes NetworkPolicies are additive, so the chart adds none
that select sandbox pods, apart from `<fullname>-sandbox-ssh` (shared mode
with the in-pod gateway), which restricts SSH ingress (TCP 2222) on sandbox
pods to the gateway pod, as upstream's chart does. In managed mode the driver
applies the same restriction in each workspace namespace itself
(`driver.managedSshIngress`, on by default with the in-pod gateway and
`networkPolicy.enabled`, as upstream's). With an external gateway
(`gateway.enabled=false`) the gateway's own deployment owns that policy. There
is no `gatewayUpstreamEgress` value: an in-cluster upstream needs no
NetworkPolicy from this chart.

## 3. Install

```bash
helm install ods deploy/helm/openshell-driver-kyma \
  -n openshell-system --create-namespace \
  -f my-values.prod.yaml \
  --wait --timeout=180s
```

The pre-install hook will:

- Refuse if the agent-sandbox CRD isn't installed.
- Refuse to render if `gatewayIngress.enabled` is set without
  `gateway.oidc.issuer`, `audience` and `clientId` (the chart never publishes
  an unauthenticated gateway), without `gatewayIngress.domain`, or with
  `serviceHosts.enabled` and no `allowedCidrs`.

Installing with `gatewayIngress.enabled` creates a RequestAuthentication and
AuthorizationPolicies in `istio-system`, so the installing identity needs
rights there. The RequestAuthentication selects the whole ingress gateway: a
request to any host that carries an invalid token of your issuer is answered
401 there. Requests without a token, or with another issuer's, pass it
untouched and are judged by the AuthorizationPolicies alone.

### Choose the policy action

`gatewayIngress.policyAction` must match your ingress gateway, because Istio
changes behaviour with the first ALLOW policy on a workload:

```bash
kubectl -n istio-system get authorizationpolicies
```

- **No policy with action ALLOW selects the ingress gateway** (a stock Kyma
  cluster): Istio lets every request through. Keep `policyAction: DENY`. The
  chart writes DENY policies that name only its own hosts, and every other
  application behind the gateway is left alone. `ALLOW` here would be an
  outage: the gateway would start denying every host no policy allows, which
  is every other application.
- **The ingress gateway already has ALLOW policies** (it allowlists per host):
  Istio denies whatever no policy allows, so this chart's hosts answer
  `403 RBAC: access denied` until you set `policyAction: ALLOW`, which adds
  ALLOW rules for them.

Either way the result is the same for this chart's hosts: the gateway host is
reached only with a valid token of your issuer (and, with `allowedCidrs`, from
a listed address), and sandbox service hosts only from `allowedCidrs`.

### 3b. Register the inference provider

Register the gateway with the `openshell` CLI on a laptop; a browser opens for
the OIDC login:

```bash
openshell gateway add https://openshell.<cluster-domain> --name kyma \
  --oidc-issuer https://<your-issuer> \
  --oidc-client-id <client-id> --oidc-audience <audience>
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

```yaml
# profile.yaml
id: kyma-anthropic
display_name: Anthropic via gateway.your-llm-ns.svc.cluster.local
description: Anthropic inference through the cluster's inference proxy
category: inference
inference_capable: true
credentials:
  - name: api_key
    description: Anthropic API key
    env_vars: [ANTHROPIC_API_KEY]
    required: true
    auth_style: header
    header_name: x-api-key
discovery:
  credentials: [api_key]
endpoints:
  - host: gateway.your-llm-ns.svc.cluster.local
    port: 8080
    protocol: rest
    access: read-write
    enforcement: enforce
binaries: [/usr/bin/node, /usr/local/bin/node, /usr/bin/claude, /usr/local/bin/claude]
```

```bash
openshell provider profile lint   -f profile.yaml --global
openshell provider profile import -f profile.yaml --global
ANTHROPIC_API_KEY='sk-ant-…' openshell provider create \
  --name ods-anthropic --type kyma-anthropic \
  --credential ANTHROPIC_API_KEY --global-profile
```

Sandboxes are then created with `--provider ods-anthropic`.

## 4. Verify

```bash
# Pods Ready (driver + gateway sidecar)
kubectl -n openshell-system get pods

# The gateway accepted the driver
kubectl -n openshell-system logs deploy/ods-openshell-driver-kyma -c gateway \
  | grep "Compute driver connected"

# Routes and ingress policies rendered
kubectl -n openshell-system get virtualservice
kubectl -n istio-system get requestauthentication,authorizationpolicy | grep openshell

# The edge refuses a call without a token (403), the CLI gets through
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://openshell.<cluster-domain>/openshell.v1.OpenShell/ListSandboxes
openshell status
```

## 5. Operational notes

- **JWT signing-key rotation.** The signing key lives in a Secret
  written by the pre-install hook. To rotate, delete the Secret and
  re-run `helm upgrade --install` (the hook re-runs and recreates).
  Existing supervisor sessions reconnect automatically with the new
  key on next refresh.
- **Image upgrades.** Resolve the new digest, edit the values overlay,
  `helm upgrade`. The chart's `checksum/values` annotation rolls the
  pod automatically. Pass your values file each time; do not use
  `--reuse-values`, which keeps the previous chart's defaults and ignores
  the new chart's.
- **NetworkPolicy.** Sandbox network access is governed by OpenShell's
  sandbox policy, which the supervisor enforces (`openshell sandbox create
  --policy`, and the rules a provider profile contributes; see NVIDIA's
  [Policies](https://docs.nvidia.com/openshell/how-it-works/policies/overview)),
  not by Kubernetes NetworkPolicies. Do not add a NetworkPolicy that selects
  sandbox pods: it could only widen upstream's fence.
- **Upstream images.** The chart pins the supervisor
  (`driver.supervisorImage`), the sandbox runtime
  (`driver.sandboxRuntimeImage`) and the gateway (`gateway.image.tag`) by
  digest to upstream's `upstream.version`. Move them together with
  `upstream.version`, and install an `openshell` CLI of the same release.
- **Tracing.** The driver's health port serves only `/healthz` and
  `/readyz`. Upstream's driver exports traces over OTLP: set
  `driver.otlpEndpoint` (plain `http://`; see Known limitations). With
  `networkPolicy.enabled` the chart lets the driver pod reach that endpoint's
  port (80 when the URL names none), on any address.

## Reaching a service inside a sandbox

Nothing in this chart routes traffic to a sandbox pod, and nothing can:
upstream's sandbox runtime brokers the workload's `bind`/`listen`/`accept`
syscalls and resets every inbound connection that does not arrive through the
gateway's relay, even one from inside the pod. An `APIRule` or
`VirtualService` to the pod answers `503 … reset reason: connection
termination` (verified live on Kyma; releases before 0.9.1 shipped such a
route behind `driver.enableApirule`, now removed).

Use upstream's path instead. The service must listen on `127.0.0.1`:

```bash
openshell sandbox create --detach --name web --from python:3.12-slim \
  -- python3 -m http.server 8080 --bind 127.0.0.1
openshell service expose web 8080          # → http://default--web.openshell.localhost:8080/
openshell service expose web 8080 admin    # → http://default--web--admin.openshell.localhost:8080/
openshell service list web
```

The gateway relays the URL to the loopback port through the supervisor. With
the CLI on a `kubectl port-forward` to the gateway (the setup in
[`getting-started.md`](getting-started.md)), Chrome resolves
`*.openshell.localhost` to the forwarded port by itself; `curl` needs
`--resolve default--web.openshell.localhost:8080:127.0.0.1`. A server bound to
`0.0.0.0` or `[::]` opens the relay but never answers.

With `gatewayIngress.serviceHosts.enabled` the service is published at
`https://default--web.<cluster-domain>/`; no port-forward and no `--resolve`.

Read the printed URL with care. Through the remote gateway the `openshell` CLI
prints `http://default--web.<cluster-domain>:443/`: it takes the scheme from
the gateway (which serves plain HTTP behind the ingress) and the port from the
gateway endpoint. Use the host with `https://`. API and SDK clients get
`http://default--web.<cluster-domain>/` from the gateway, which the Kyma
gateway redirects to HTTPS.

Things to know:

- A browser sends no token, so these hosts are fenced by
  `gatewayIngress.allowedCidrs` only. Put authentication into the service
  itself if the address ranges are shared.
- Service hosts are published per workspace. Routes and policies match
  `<workspace>--*` for the workspaces in `gatewayIngress.serviceHosts.workspaces`
  (default `[default]`), never the whole domain, so no other host under the
  domain is affected. A workspace that is not listed is not reachable from
  outside: add it to the list and `helm upgrade`.
- The fence is at the ingress gateway. A pod inside the cluster reaches a
  service URL through the gateway's Service without passing it, as it always
  could with the port-forward URLs.
- The gateway then binds port 80 in its pod, so that the URL it hands to API
  and SDK clients carries no port. That adds the safe sysctl
  `net.ipv4.ip_unprivileged_port_start=0` to the pod. The in-cluster Service
  port stays `gateway.grpcPort`.

Sandbox pods themselves are never published.

## Known limitations

- **Operator mode** (`driver.workspaceMode=operator`): the namespace owner must
  grant the driver `create` and `delete` on Secrets in each operator namespace.
  Upstream ships that Role in its separate `openshell-workspace` chart; this
  chart does not.
- **Managed mode**: the gateway id (default: the release fullname) must be at
  most 33 characters; a longer release name must set
  `gateway.sandboxJwt.gatewayId`.
- **SAP AI Core bridge** (`bedrockBridge`): with `networkPolicy.enabled`, its
  NetworkPolicy admits only OpenShell pods in the release namespace
  (`.Release.Namespace`). A sandbox reaches it only if it runs there: shared
  mode with `namespace` equal to the release namespace. Sandboxes in managed or
  operator mode, or in a different `namespace`, cannot.
- **`driver.otlpEndpoint` must be plain `http://`.** Upstream v0.1.2 builds its
  OTLP exporter without TLS, so an `https://` endpoint logs an error and exports
  nothing.
- **`gateway.dbPersistence.enabled=false`**: a gateway restart loses the
  provider and profile. With the chart's hook (`inferenceProvider.enabled`,
  no OIDC issuer) the next `helm upgrade` re-runs the hook and re-creates
  them. The OIDC path has no hook, so nothing does: register them again from
  an authenticated CLI session (step 3b).
- **`driver.sandboxEnv` values cannot contain a comma** (the driver splits the
  list on commas), nor can `inferenceProvider.baseUrl` or `modelId`. Set such a
  variable per sandbox instead.
- **Provider `binaries`** do not yet restrict who may use the key; it is bound
  to the endpoint's host and port (see above).
