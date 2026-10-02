#!/usr/bin/env bash
# Lists the servers of the Istio Gateways on the cluster's ingress gateway that are not
# HTTP: TCP, TLS, and HTTPS in passthrough mode.
#
# Why it matters: an AuthorizationPolicy with action DENY that fences a host by source
# address ("not from these CIDR blocks, to this host") is host-scoped only where Istio can
# see a host. For a TCP or TLS-passthrough server Istio builds the DENY rule without the
# host condition (hosts are an HTTP-only field) and keeps the rest: every connection to
# that server from outside the CIDR blocks is refused, whatever application it belongs
# to. ALLOW policies are not affected: Istio skips an ALLOW rule with HTTP-only fields on
# such a server. So DENY policies with source addresses must not be installed on an
# ingress gateway that has such servers.
#
# Prints one line per server: <namespace>/<name> port <number> (<protocol>[, <tls mode>]).
# Exit status: 0 none, 1 at least one, 2 the Gateways could not be read (treat it as 1).
#
# OSH_INGRESS_SELECTOR  the ingress gateway's pod labels, k=v[,k=v] (default
#                       istio=ingressgateway, the chart's gatewayIngress.ingressSelector).
#                       A Gateway whose selector names another value for one of these
#                       labels belongs to another gateway deployment and is skipped.
# Requires: kubectl (with KUBECONFIG set), python3.
set -euo pipefail

if ! gateways=$(kubectl get gateways.networking.istio.io -A -o json 2>/dev/null); then
	echo "cannot list the cluster's Istio Gateways (kubectl get gateways.networking.istio.io -A)" >&2
	exit 2
fi
python3 -c '
import json, sys

selector = dict(pair.split("=", 1) for pair in sys.argv[1].split(",") if "=" in pair)
try:
    items = json.load(sys.stdin)["items"]
except (ValueError, KeyError, TypeError):
    print("cannot read the list of Istio Gateways", file=sys.stderr)
    sys.exit(2)
found = []
for gateway in items:
    spec = gateway.get("spec") or {}
    if any(k in selector and selector[k] != v for k, v in (spec.get("selector") or {}).items()):
        continue
    for server in spec.get("servers") or []:
        protocol = str((server.get("port") or {}).get("protocol") or "").upper()
        mode = str((server.get("tls") or {}).get("mode") or "").upper()
        if protocol not in ("HTTP", "HTTPS", "HTTP2", "GRPC", "GRPC-WEB") or mode in ("PASSTHROUGH", "AUTO_PASSTHROUGH"):
            meta = gateway["metadata"]
            found.append("%s/%s port %s (%s%s)" % (meta.get("namespace"), meta.get("name"),
                                                   (server.get("port") or {}).get("number"), protocol,
                                                   ", " + mode if mode else ""))
print("\n".join(found), end="\n" if found else "")
sys.exit(1 if found else 0)
' "${OSH_INGRESS_SELECTOR:-istio=ingressgateway}" <<<"$gateways"
