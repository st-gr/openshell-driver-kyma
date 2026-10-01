#!/usr/bin/env bash
# Deploys a Keycloak TEST identity provider for the remote-access live check
# (scripts/remote-access-check.sh), published at keycloak.<domain> through the cluster's
# Istio ingress gateway. The realm (realm.json) is upstream OpenShell's own development
# realm: realm `openshell`, roles openshell-admin and openshell-user, the public PKCE
# client `openshell-cli` for the CLI and the confidential client `openshell-ci` for the
# client-credentials grant, both with the audience `openshell-cli`.
#
# NOT a production identity provider: Keycloak's dev mode, an in-memory database
# (sessions and signing keys are lost on restart, the realm is re-imported), one replica.
#
#   OSH_DOMAIN         the cluster's wildcard domain, without "*."
#   OSH_ALLOWED_CIDRS  comma-separated source CIDR blocks that may reach Keycloak
# Optional:
#   OSH_CLUSTER_CIDRS  comma-separated in-cluster source ranges (pod and node networks).
#                      The OpenShell gateway and the provider hook reach the issuer through
#                      the same public host. Default: kube-system/shoot-info (Gardener).
#   KEYCLOAK_NAMESPACE (keycloak), OSH_NAMESPACE (openshell-system), KEYCLOAK_IMAGE
#   OSH_RENDER_ONLY=1  print the manifests and exit; needs no cluster
#   OSH_DELETE=1       remove everything this script created
#
# Credentials are generated in the cluster, never printed and never rendered:
#   <KEYCLOAK_NAMESPACE>/keycloak-credentials  admin-password (admin console, user admin),
#                                              user-password (realm user dev),
#                                              client-secret (client openshell-ci)
#   <OSH_NAMESPACE>/openshell-oidc-client      client-secret, for the chart's
#                                              gateway.oidc.clientCredentialsSecret
# Requires: kubectl (with KUBECONFIG set), openssl.
set -euo pipefail

: "${OSH_DOMAIN:?set OSH_DOMAIN to the cluster wildcard domain}"
: "${OSH_ALLOWED_CIDRS:?set OSH_ALLOWED_CIDRS (comma-separated)}"
NS=${KEYCLOAK_NAMESPACE:-keycloak}
OSH_NS=${OSH_NAMESPACE:-openshell-system}
# Keycloak 26.4, pinned by digest (docker buildx imagetools inspect quay.io/keycloak/keycloak:26.4).
KEYCLOAK_IMAGE=${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak@sha256:9409c59bdfb65dbffa20b11e6f18b8abb9281d480c7ca402f51ed3d5977e6007}
HOST="keycloak.${OSH_DOMAIN}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ${OSH_DELETE:-} == 1 ]]; then
	kubectl -n istio-system delete authorizationpolicy keycloak-test-idp --ignore-not-found
	kubectl delete namespace "$NS" --ignore-not-found
	kubectl -n "$OSH_NS" delete secret openshell-oidc-client --ignore-not-found
	exit 0
fi

CLUSTER_CIDRS=${OSH_CLUSTER_CIDRS:-}
if [[ -z $CLUSTER_CIDRS && ${OSH_RENDER_ONLY:-} != 1 ]]; then
	CLUSTER_CIDRS=$(kubectl -n kube-system get configmap shoot-info \
		-o jsonpath='{.data.podNetwork},{.data.nodeNetwork}' 2>/dev/null || true)
	[[ $CLUSTER_CIDRS == *,* && $CLUSTER_CIDRS != , ]] \
		|| { echo "cannot read the pod and node networks from kube-system/shoot-info; set OSH_CLUSTER_CIDRS" >&2; exit 1; }
fi

# yaml_list INDENT ITEMS: a comma-separated list as YAML sequence items.
yaml_list() {
	local indent=$1 item
	local -a items
	IFS=',' read -r -a items <<<"$2"
	for item in "${items[@]}"; do
		[[ -n ${item// /} ]] && printf '%s- "%s"\n' "$indent" "${item// /}"
	done
	return 0
}

manifests() {
	local realm_sum
	realm_sum=$(openssl dgst -sha256 -r "$DIR/realm.json" | cut -d' ' -f1)
	cat <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: ${NS}
  labels:
    app: keycloak
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
        sidecar.istio.io/inject: "false"
      annotations:
        # Rolls the pod when the realm changes: dev mode imports it at start.
        openshell.test/realm-sha256: "${realm_sum}"
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: keycloak
          image: ${KEYCLOAK_IMAGE}
          args: ["start-dev", "--import-realm"]
          env:
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              value: admin
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-credentials
                  key: admin-password
            # Placeholders in realm.json.
            - name: OSH_USER_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-credentials
                  key: user-password
            - name: OSH_CI_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: keycloak-credentials
                  key: client-secret
            # The public URL: it is the issuer in every token and discovery document.
            - name: KC_HOSTNAME
              value: "https://${HOST}"
            # TLS ends at the ingress gateway, which forwards X-Forwarded-*.
            - name: KC_PROXY_HEADERS
              value: xforwarded
            - name: KC_HTTP_ENABLED
              value: "true"
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /realms/openshell
              port: http
            initialDelaySeconds: 20
            periodSeconds: 5
            failureThreshold: 24
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          volumeMounts:
            - name: realm
              mountPath: /opt/keycloak/data/import
              readOnly: true
      volumes:
        - name: realm
          configMap:
            name: openshell-realm
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: ${NS}
spec:
  selector:
    app: keycloak
  ports:
    - name: http
      port: 8080
      targetPort: http
---
# Only the Istio ingress gateway and istiod (which fetches the JWKS for the ingress
# gateway's RequestAuthentication) reach Keycloak.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: keycloak
  namespace: ${NS}
spec:
  podSelector:
    matchLabels:
      app: keycloak
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: istio-system
      ports:
        - protocol: TCP
          port: 8080
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: keycloak
  namespace: ${NS}
spec:
  hosts:
    - "${HOST}"
  gateways:
    - kyma-system/kyma-gateway
  http:
    - route:
        - destination:
            host: keycloak.${NS}.svc.cluster.local
            port:
              number: 8080
---
# Admits the listed addresses to Keycloak's host on the ingress gateway: the operator's,
# and the cluster's own (the OpenShell gateway and the provider hook reach the issuer
# through the public host).
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: keycloak-test-idp
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  action: ALLOW
  rules:
    - from:
        - source:
            remoteIpBlocks:
$(yaml_list '              ' "${OSH_ALLOWED_CIDRS},${CLUSTER_CIDRS}")
      to:
        - operation:
            hosts:
              - "${HOST}"
YAML
}

if [[ ${OSH_RENDER_ONLY:-} == 1 ]]; then
	manifests
	exit 0
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null
kubectl -n "$NS" create configmap openshell-realm --from-file=realm.json="$DIR/realm.json" \
	--dry-run=client -o yaml | kubectl apply -f -
if ! kubectl -n "$NS" get secret keycloak-credentials >/dev/null 2>&1; then
	kubectl -n "$NS" create secret generic keycloak-credentials \
		--from-literal=admin-password="$(openssl rand -hex 16)" \
		--from-literal=user-password="$(openssl rand -hex 12)" \
		--from-literal=client-secret="$(openssl rand -hex 32)" >/dev/null
	echo "created $NS/keycloak-credentials"
fi
# The chart's Secret holds the same client secret; the pipe keeps it off the terminal.
kubectl -n "$OSH_NS" create secret generic openshell-oidc-client \
	--from-literal=client-secret="$(kubectl -n "$NS" get secret keycloak-credentials \
		-o jsonpath='{.data.client-secret}' | base64 -d)" \
	--dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "synced $OSH_NS/openshell-oidc-client"
manifests | kubectl apply -f -
kubectl -n "$NS" rollout status deployment/keycloak --timeout=300s

cat <<NEXT

Keycloak is up at https://${HOST} (realm openshell).

  Log in as:  dev
  Password:   kubectl -n ${NS} get secret keycloak-credentials -o jsonpath='{.data.user-password}' | base64 -d

For scripts/remote-access-check.sh:
  OSH_OIDC_ISSUER=https://${HOST}/realms/openshell
  OSH_OIDC_CLIENT_ID=openshell-cli
  OSH_HOOK_CLIENT_ID=openshell-ci
  OSH_OIDC_JWKS_URI=http://keycloak.${NS}.svc.cluster.local:8080/realms/openshell/protocol/openid-connect/certs
  OSH_CLIENT_SECRET=openshell-oidc-client

Remove it again with OSH_DELETE=1 $0
NEXT
