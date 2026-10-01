# Keycloak test identity provider

A Keycloak **test** instance for the remote-access live check
(`scripts/remote-access-check.sh`), for clusters whose operator has no OIDC
provider at hand. Not for production: dev mode, an in-memory database, one
replica.

`realm.json` is upstream OpenShell's own development realm
(`scripts/keycloak-realm.json` at v0.1.2, Apache-2.0) with the differences a
reachable instance needs: no credential in the file (the user password and the
client secret are `${…}` placeholders Keycloak resolves from its environment),
no password grant, TLS required for external requests, brute-force throttling,
one user. It keeps upstream's shape, so the gateway runs with upstream's
defaults (roles `openshell-admin` / `openshell-user` in `realm_access.roles`):

| | |
|---|---|
| Realm | `openshell` |
| CLI client (`gateway.oidc.clientId`) | `openshell-cli`: public, PKCE S256, redirect `http://127.0.0.1:*` |
| Hook client (`gateway.oidc.clientCredentialsSecret.clientId`) | `openshell-ci`: confidential, service account with both roles |
| Audience (`gateway.oidc.audience`) | `openshell-cli`, on both clients' access tokens |
| User | `dev`, both roles |

## Deploy

```bash
OSH_DOMAIN=<cluster-domain> OSH_ALLOWED_CIDRS=<your CIDR blocks> e2e/keycloak/deploy.sh
```

Set `OSH_POLICY_ACTION=ALLOW` if the ingress gateway already has ALLOW
AuthorizationPolicies (the default, `DENY`, is for one without; same rule as the
chart's `gatewayIngress.policyAction`).

Keycloak is published at `keycloak.<cluster-domain>` through the cluster's
Istio ingress gateway, reachable from your CIDR blocks and from the cluster's own
pod and node networks (the OpenShell gateway and the provider hook reach the
issuer through that public host; the ingress gateway's JWKS fetch uses the
in-cluster Service). Credentials are generated into Secrets in the cluster and
never printed; the script ends with the values `remote-access-check.sh` needs
and the command that reads the `dev` password. The script labels the namespace
and the Secret it creates and refuses to deploy into, overwrite or delete
anything it did not create. `OSH_DELETE=1` removes it all.

An OpenShell release that uses this issuer also needs `values.yaml` of this
directory (`-f e2e/keycloak/values.yaml`, or `OSH_EXTRA_VALUES` for the live
check): the gateway reaches the issuer through the cluster's own ingress
gateway, on its pod's port 8443, which the chart's NetworkPolicy does not allow
by itself.

## Test

```bash
e2e/keycloak/test.sh
```

Renders the manifests in both policy actions, checks them and the realm for
literal credentials, runs the script against a `kubectl` stand-in to prove it
leaves a foreign namespace alone, then
imports the realm into a throwaway Keycloak in Docker and checks the tokens:
the client-credentials grant, and a browser login with PKCE on a loopback
redirect, each for issuer, audience, roles and the claims the gateway
validates.
