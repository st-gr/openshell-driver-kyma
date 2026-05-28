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

driver:
  enableNetworkPolicy: true   # default-on as of 2026-05-28
```

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
