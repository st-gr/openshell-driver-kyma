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
#   OSH_POLICY_ACTION  DENY (default) for an ingress gateway without ALLOW policies, ALLOW
#                      for one that already allowlists per host; as the chart's
#                      gatewayIngress.policyAction, and for the same reason.
#   OSH_SOURCE_ADDRESS connection (default): the allowlist compares the address of the
#                      connection the ingress gateway accepted, which no header can change;
#                      forwarded: the address Istio takes from X-Forwarded-For, for an ingress
#                      gateway behind an HTTP proxy. As the chart's gatewayIngress.sourceAddress.
#   OSH_CLUSTER_CIDRS  comma-separated in-cluster source ranges (pod and node networks).
#                      The OpenShell gateway and the provider hook reach the issuer through
#                      the same public host. Default: kube-system/shoot-info (Gardener).
#   KEYCLOAK_NAMESPACE (keycloak), OSH_NAMESPACE (openshell-system), KEYCLOAK_IMAGE
#   OSH_RENDER_ONLY=1  print the manifests and exit; needs no cluster
#   OSH_DELETE=1       remove what this script created (needs no other variable)
#
# The script labels the namespace and the Secret it creates (openshell.test/fixture=keycloak)
# and refuses to deploy into, overwrite or delete anything without that label.
#
# Credentials are generated here and stored only in the cluster: never printed, never
# rendered, never passed as a command-line argument:
#   <KEYCLOAK_NAMESPACE>/keycloak-credentials  admin-password (admin console, user admin),
#                                              user-password (realm user dev),
#                                              client-secret (client openshell-ci)
#   <OSH_NAMESPACE>/openshell-oidc-client      client-secret, for the chart's
#                                              gateway.oidc.clientCredentialsSecret
# Requires: kubectl (with KUBECONFIG set), openssl.
set -euo pipefail

NS=${KEYCLOAK_NAMESPACE:-keycloak}
OSH_NS=${OSH_NAMESPACE:-openshell-system}
# Keycloak 26.4, pinned by digest (docker buildx imagetools inspect quay.io/keycloak/keycloak:26.4).
KEYCLOAK_IMAGE=${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak@sha256:9409c59bdfb65dbffa20b11e6f18b8abb9281d480c7ca402f51ed3d5977e6007}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_LABEL=openshell.test/fixture

die() {
	echo "$*" >&2
	exit 1
}
# fixture_label KIND NAME / -n NAMESPACE KIND NAME: the object's fixture label, empty when
# it has none; fails when the object does not exist.
fixture_label() { kubectl get "$@" -o jsonpath='{.metadata.labels.openshell\.test/fixture}'; }

if [[ ${OSH_DELETE:-} == 1 ]]; then
	if label=$(fixture_label namespace "$NS" 2>/dev/null); then
		[[ $label == keycloak ]] \
			|| die "namespace $NS was not created by this script (no label $FIXTURE_LABEL=keycloak); not deleting it"
		kubectl -n istio-system delete authorizationpolicy keycloak-test-idp --ignore-not-found
		kubectl delete namespace "$NS"
	fi
	if label=$(fixture_label -n "$OSH_NS" secret openshell-oidc-client 2>/dev/null) && [[ $label == keycloak ]]; then
		kubectl -n "$OSH_NS" delete secret openshell-oidc-client
	fi
	exit 0
fi

: "${OSH_DOMAIN:?set OSH_DOMAIN to the cluster wildcard domain}"
: "${OSH_ALLOWED_CIDRS:?set OSH_ALLOWED_CIDRS (comma-separated)}"
ACTION=${OSH_POLICY_ACTION:-DENY}
[[ $ACTION == DENY || $ACTION == ALLOW ]] \
	|| die "OSH_POLICY_ACTION must be DENY (an ingress gateway without ALLOW policies) or ALLOW (one that already allowlists)"
SOURCE=${OSH_SOURCE_ADDRESS:-connection}
[[ $SOURCE == connection || $SOURCE == forwarded ]] \
	|| die "OSH_SOURCE_ADDRESS must be connection (the accepted connection's address) or forwarded (the address from X-Forwarded-For)"
domain_re='^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)+$'
[[ $OSH_DOMAIN =~ $domain_re ]] || die "OSH_DOMAIN is not a lowercase DNS name (give the domain alone, without \"*.\")"
# check_cidrs NAME LIST: every comma-separated entry is an address or CIDR block.
check_cidrs() {
	local entry cidr_re='^(([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?|[0-9a-fA-F:]*:[0-9a-fA-F:]*(/[0-9]{1,3})?)$'
	local -a entries
	IFS=',' read -r -a entries <<<"$2"
	for entry in "${entries[@]}"; do
		[[ ${entry// /} =~ $cidr_re ]] || die "$1 entry '$entry' is not an IP address or CIDR block"
	done
}
check_cidrs OSH_ALLOWED_CIDRS "$OSH_ALLOWED_CIDRS"
HOST="keycloak.${OSH_DOMAIN}"

CLUSTER_CIDRS=${OSH_CLUSTER_CIDRS:-}
if [[ -z $CLUSTER_CIDRS && ${OSH_RENDER_ONLY:-} != 1 ]]; then
	CLUSTER_CIDRS=$(kubectl -n kube-system get configmap shoot-info \
		-o jsonpath='{.data.podNetwork},{.data.nodeNetwork}' 2>/dev/null || true)
	[[ $CLUSTER_CIDRS == *,* && $CLUSTER_CIDRS != , ]] \
		|| die "cannot read the pod and node networks from kube-system/shoot-info; set OSH_CLUSTER_CIDRS"
fi
[[ -z $CLUSTER_CIDRS ]] || check_cidrs OSH_CLUSTER_CIDRS "$CLUSTER_CIDRS"

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
	local realm_sum blocks=notIpBlocks
	realm_sum=$(openssl dgst -sha256 -r "$DIR/realm.json" | cut -d' ' -f1)
	[[ $ACTION == ALLOW ]] && blocks=ipBlocks
	if [[ $SOURCE == forwarded ]]; then
		blocks=notRemoteIpBlocks
		[[ $ACTION == ALLOW ]] && blocks=remoteIpBlocks
	fi
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
# Only the Istio ingress gateway's namespace reaches Keycloak: every caller, the OpenShell
# gateway included, comes through the public host.
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
# Keycloak's host on the ingress gateway is reachable from the listed addresses only: the
# operator's, and the cluster's own (the OpenShell gateway and the provider hook reach the
# issuer through the public host). DENY names only this host, so it is safe on a gateway
# without ALLOW policies whose servers are all HTTP (checked before anything is created);
# ALLOW is for a gateway that already denies what nothing allows.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: keycloak-test-idp
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  action: ${ACTION}
  rules:
    - from:
        - source:
            ${blocks}:
$(yaml_list '              ' "${OSH_ALLOWED_CIDRS},${CLUSTER_CIDRS}")
      to:
        - operation:
            hosts:
              - "${HOST}"
              - "${HOST}:*"
YAML
}

if [[ ${OSH_RENDER_ONLY:-} == 1 ]]; then
	manifests
	exit 0
fi

# The DENY policy below is matched by host only on HTTP servers. On a TCP or TLS-passthrough
# server of the same ingress gateway Istio applies it without the host and would refuse every
# connection from other addresses (scripts/ingress-non-http-servers.sh): nothing is created
# on such a gateway.
if [[ $ACTION == DENY ]]; then
	rc=0
	servers=$("$DIR/../../scripts/ingress-non-http-servers.sh" 2>&1) || rc=$?
	[[ $rc == 0 ]] || die "OSH_POLICY_ACTION=DENY cannot be used on this ingress gateway: it would close its servers that are not HTTP to every source address but the listed ones: $servers"
fi

kubectl get namespace "$OSH_NS" >/dev/null 2>&1 \
	|| die "namespace $OSH_NS does not exist: install the chart first, or set OSH_NAMESPACE"
if label=$(fixture_label namespace "$NS" 2>/dev/null); then
	[[ $label == keycloak ]] \
		|| die "namespace $NS exists and was not created by this script (no label $FIXTURE_LABEL=keycloak); set KEYCLOAK_NAMESPACE to another name"
else
	kubectl create namespace "$NS"
	kubectl label namespace "$NS" "$FIXTURE_LABEL=keycloak" pod-security.kubernetes.io/enforce=baseline >/dev/null
fi
if label=$(fixture_label -n "$OSH_NS" secret openshell-oidc-client 2>/dev/null) && [[ $label != keycloak ]]; then
	die "$OSH_NS/openshell-oidc-client exists and was not created by this script: it may hold your real client secret. Not overwriting it."
fi
kubectl -n "$NS" create configmap openshell-realm --from-file=realm.json="$DIR/realm.json" \
	--dry-run=client -o yaml | kubectl apply -f -
# printf is a shell builtin, so no credential appears in a process's arguments.
if ! kubectl -n "$NS" get secret keycloak-credentials >/dev/null 2>&1; then
	kubectl -n "$NS" create secret generic keycloak-credentials \
		--from-file=admin-password=<(printf %s "$(openssl rand -hex 16)") \
		--from-file=user-password=<(printf %s "$(openssl rand -hex 12)") \
		--from-file=client-secret=<(printf %s "$(openssl rand -hex 32)") >/dev/null
	echo "created $NS/keycloak-credentials"
fi
# The chart's Secret holds the same client secret.
client_secret=$(kubectl -n "$NS" get secret keycloak-credentials -o jsonpath='{.data.client-secret}' | base64 -d)
[[ -n $client_secret ]] || die "$NS/keycloak-credentials has no client-secret"
kubectl -n "$OSH_NS" create secret generic openshell-oidc-client \
	--from-file=client-secret=<(printf %s "$client_secret") --dry-run=client -o yaml \
	| kubectl label --local -f - "$FIXTURE_LABEL=keycloak" -o yaml | kubectl apply -f - >/dev/null
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
  OSH_CLIENT_SECRET=openshell-oidc-client
  OSH_POLICY_ACTION=${ACTION}
  OSH_EXTRA_VALUES=e2e/keycloak/values.yaml   (lets the gateway pod reach this issuer)
  OSH_NEIGHBOUR_URLS=...                      (yours to choose: other applications behind this ingress gateway)

Remove it again with OSH_DELETE=1 $0
NEXT
