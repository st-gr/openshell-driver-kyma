# Production deployment

This runbook is for operators going beyond the in-cluster /
port-forward path covered by [`getting-started.md`](getting-started.md).
It assumes you've already verified the chart works behind a port-forward
and now want a production-grade install: OIDC user auth, public access
through the Kyma API Gateway, image digests pinned, an `imagePullSecrets`
where needed.

The cluster's CNI must enforce `NetworkPolicy` in every sandbox namespace:
upstream's isolation fence for sandbox pods is a set of NetworkPolicies, and
without enforcement sandbox pods can bypass OpenShell's network policy.

## Decision: how do users reach the gateway?

| Option | Auth | Pros | Cons |
|---|---|---|---|
| Public APIRule + OIDC | OIDC + sandbox-JWT | Standard SAP IAS pattern, no VPN, MFA | Public attack surface |
| SCC Service Channel + port-forward | None at gateway, OIDC at kubectl | No public exposure | All users must be on corporate VPN; see [`cloud-connector-setup.md`](cloud-connector-setup.md) |
| Mesh-internal only | sandbox-JWT only (CLI requires `allow_unauthenticated_users`) | Simplest | Caller must be inside the cluster |

The Public APIRule option is the focus of the rest of this doc.

## 1. Provision an OIDC client

Use SAP IAS (or any other OIDC IdP). Two values matter:

- `issuer` — your IAS tenant's OIDC issuer URL.
- `audience` — an OAuth client ID with the `openshell` audience.

Keep the issuer reachable from the cluster (the gateway fetches the
JWKS at startup) and from your users' laptops (the CLI redirects to it
on first auth).

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

  # OIDC required for the public-APIRule path. The chart's
  # gateway-apirule.yaml refuses to render with an empty issuer.
  oidc:
    issuer: "https://<your-tenant>.accounts.ondemand.com"
    audience: "openshell"
    adminRole: "openshell-admin"
    userRole:  "openshell-user"

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

gatewayApirule:
  enabled: true
  host: "openshell.<your-cluster-id>.kyma.ondemand.com"
  gateway: kyma-system/kyma-gateway
  rules:
    - path: /*
      methods: [POST]
      jwt:
        authentications:
          - issuer: "https://<your-tenant>.accounts.ondemand.com"
            jwksUri: "https://<your-tenant>.accounts.ondemand.com/oauth2/certs"
        authorizations:
          - requiredScopes: []   # rely on OIDC roles in the gateway

# No `inferenceProvider` block. Its post-install Job registers the provider
# with the gateway's CLI, without a token, and a gateway with OIDC refuses
# unauthenticated calls, so the chart refuses `inferenceProvider.enabled`
# together with `gateway.oidc.issuer`. Register the provider yourself after
# the install, from an authenticated CLI session (step 3b), and give
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
- Refuse to render `gatewayApirule.yaml` if `gateway.oidc.issuer` is
  empty (the chart's `B1` security guard).

### 3b. Register the inference provider

Once the install has finished (step 4 shows how to check the gateway is up),
register the gateway with the `openshell` CLI on a laptop
(`openshell gateway add https://openshell.<cluster-domain>`); the CLI
redirects to your OIDC issuer on first use.

With OIDC on, the provider is registered from that authenticated CLI session
(an admin role), with the profile the chart's hook would have imported. Write
it for your endpoint: `host` and `port` are those of `ANTHROPIC_BASE_URL`
above (the path is not part of the binding), and `binaries` are the processes
allowed to reach it (claude-code runs under `node`):

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

# APIRule reconciled
kubectl -n openshell-system get apirule
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

## Exposing a sandbox through an APIRule (opt-in exception)

`driver.enableApirule` (default `false`) publishes each sandbox's port 8080 on
a Kyma hostname. It is an explicit exception to upstream's isolation, so read
what it does before turning it on.

```yaml
driver:
  enableApirule: true
  clusterDomain: "<cluster-domain>"     # required with enableApirule
  ingressNamespace: istio-system        # where the Istio ingress gateway runs
```

For each sandbox the driver then creates three objects, all
owner-referenced to the sandbox's `Sandbox` CR (so they are deleted with it)
and labelled `app.kubernetes.io/managed-by: openshell-driver-kyma`:

- a Service `<cr>-svc` on port 8080, selecting the sandbox's workload pod;
- a NetworkPolicy `<cr>-expose` that admits only the Istio ingress gateway
  (pods labelled `istio: ingressgateway` in `driver.ingressNamespace`) to TCP
  8080 of that workload pod;
- an APIRule `<cr>`, host `<workspace>--<name>.<cluster-domain>` in every
  workspace mode, through `kyma-system/kyma-gateway`, path `/*`, methods
  `GET` and `POST`, with `noAuth`.

Upstream's workload pods otherwise accept ingress only from their own
supervisor. Exposure lets traffic from the internet reach whatever listens on
port 8080 in the sandbox, without passing the supervisor, and the APIRule has
no authentication. Enable it only for sandboxes that are meant to serve
requests, and put authentication in the service itself. A failure to create
the objects never fails the sandbox: it is logged and recorded as a
`Warning` Event with reason `ExposureFailed` on the `Sandbox`
(`kubectl describe sandbox <cr>`). The driver's RBAC gains the matching
Service, NetworkPolicy, APIRule and Event rights only when the option is on.
In managed and operator mode those rights are cluster-wide, because sandboxes
live in many namespaces: the driver may then create and patch APIRules, and
patch Services and NetworkPolicies, in every namespace.
This is separate from `gatewayApirule`, which publishes the gateway, with
OIDC, and is documented above.

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
