# Production deployment

This runbook is for operators going beyond the in-cluster /
port-forward path covered by [`getting-started.md`](getting-started.md).
It assumes you've already verified the chart works behind a port-forward
and now want a production-grade install: OIDC user auth, public access
through the Kyma API Gateway, image digests pinned, an `imagePullSecrets`
where needed.

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
  # Pin via the full <repository>@sha256:<digest> reference; the chart's
  # image helper expects <repo>:<tag>, so for digest-pinning today the
  # operational pattern is one of:
  #   (a) Kustomize overlay that patches `spec.template.spec.containers[*].image`
  #   (b) Wait for the chart helper update tracked under "Follow-ups" in
  #       CHANGELOG.md to support `tag: "sha256:..."` natively.
  # Resolve a digest once with:
  #   docker buildx imagetools inspect ghcr.io/st-gr/openshell-driver-kyma:v1.0.0 \
  #     --format '{{json .Manifest.Digest}}'
  repository: ghcr.io/st-gr/openshell-driver-kyma
  tag: v1.0.0
  pullPolicy: IfNotPresent

# If your driver image is in a private registry:
imagePullSecrets:
  - name: ghcr-pull-secret

gateway:
  enabled: true
  image:
    # Same digest-pin discipline as the driver image above.
    repository: ghcr.io/st-gr/openshell-gateway
    tag: v0.0.50
    pullPolicy: IfNotPresent

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
    saTokenTtlSecs: 3600

  # Persist the gateway's DB across pod restarts. Without this, every
  # gateway pod restart wipes the provider/inference DB set by the
  # post-install Job, breaking every sandbox's bundle fetch.
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

# Gateway-side inference provider config. The chart runs a post-install
# Job that calls `openshell provider create` + `openshell inference set`
# against the in-pod gateway. The chart never sees the API key — it's
# mounted into the Job from a Secret you create separately:
#   kubectl -n openshell-system create secret generic my-anthropic-creds \
#     --from-literal=api-key=sk-ant-…
inferenceProvider:
  enabled: true
  type: anthropic
  baseUrl: "http://gateway.your-llm-ns.svc.cluster.local:8080/anthropic"
  modelId: "claude-opus-4-7"
  credentialSecret:
    name: my-anthropic-creds
    key: api-key

# NetworkPolicy egress rule for the driver+gateway pod (NOT sandbox)
# to reach the in-cluster LLM upstream. Required when
# inferenceProvider.baseUrl points at a *.svc.cluster.local address.
# Operators must label their upstream namespace at install time:
#   kubectl label namespace your-llm-ns \
#     kubernetes.io/metadata.name=your-llm-ns
gatewayUpstreamEgress:
  enabled: true
  namespace: your-llm-ns
  port: 8080

driver:
  enableNetworkPolicy: true   # default-on as of 2026-05-28
  # Silence Claude's optional telemetry endpoints when the in-cluster
  # gateway can't service them.
  disableClaudeTelemetry: true
```

## Why these settings keep the agent isolated

The chart matches NVIDIA OpenShell's documented architecture
([docs.nvidia.com/openshell/about/how-it-works](https://docs.nvidia.com/openshell/about/how-it-works);
the "in-process inference router" choice was made deliberately in
[NVIDIA/OpenShell#998](https://github.com/NVIDIA/OpenShell/issues/998) —
"No subprocess, no loopback hop"). The data flow:

```text
agent process    ─https://inference.local/v1/messages─▶  supervisor's policy proxy
(user code in                                                 │  TLS terminates with sandbox-CA-signed
 agent container)                                             │  per-SNI cert from /etc/openshell-tls/
                                                              ▼
                                                  in-process inference router
                                                              │  strips caller creds,
                                                              │  injects real URL+key
                                                              │  from GetInferenceBundle
                                                              ▼
                                                  your in-cluster LLM upstream
```

Two distinct processes inside the sandbox pod, with different visibility:

| Component | Sees `inference.local`? | Sees real URL? | Sees API key? | Can dial upstream? |
|---|---|---|---|---|
| **Agent** (user code, agent container) | yes (env) | no | no | no — doesn't know URL/key |
| **Supervisor** (privileged, separate process ns) | yes | yes (from bundle) | yes (from bundle) | yes — this is the actual dialer |
| **Gateway sidecar** (driver+gateway pod) | no | yes (DB) | yes (DB) | no — it serves bundles, doesn't forward bytes |

Bundle persistence is what `gateway.dbPersistence.enabled` provides — without it, every gateway pod restart wipes the provider config and breaks every sandbox's `GetInferenceBundle` until reconfigured.

The `gatewayUpstreamEgress` NetworkPolicy rule lands on the **sandbox-pod**
policy because that's where the supervisor's outbound HTTPS originates.
The driver+gateway pod's NP is unaffected — the gateway sidecar never
makes outbound LLM requests itself.

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

## 4. Verify

```bash
# Pods Ready (driver + gateway sidecar)
kubectl -n openshell-system get pods

# OIDC + sandbox-JWT both initialized
kubectl -n openshell-system logs deploy/ods-openshell-driver-kyma -c gateway \
  | grep -E "OIDC|sandbox JWT|TokenReview"

# APIRule reconciled
kubectl -n openshell-system get apirule
```

The `OIDC validator initialized` line plus the
`gateway-minted sandbox JWT enabled` line plus a 200 from
`curl -k https://openshell.<cluster-id>.kyma.ondemand.com/healthz`
together confirm the full chain.

## 5. Operational notes

- **JWT signing-key rotation.** The signing key lives in a Secret
  written by the pre-install hook. To rotate, delete the Secret and
  re-run `helm upgrade --install` (the hook re-runs and recreates).
  Existing supervisor sessions reconnect automatically with the new
  key on next refresh.
- **Image upgrades.** Resolve the new digest, edit the values overlay,
  `helm upgrade`. The chart's `checksum/values` annotation rolls the
  pod automatically.
- **NetworkPolicy.** Default-on as of 2026-05-28. The sandbox egress
  allow-list is `DNS + in-pod gateway VIP + 0.0.0.0/0:443 (RFC1918
  excluded)`. If your sandboxes need an internal HTTP service, add
  an overlay NetworkPolicy in the sandbox namespace; do NOT widen the
  default.
- **Supervisor image upgrade policy.** Pin
  `driver.supervisorImage` to a digest in the values file. The chart
  ships `:latest` so the e2e harness keeps working without an
  always-changing PR; production should always digest-pin.
