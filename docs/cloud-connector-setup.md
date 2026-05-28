# Routing OpenShell CLI traffic through SAP Cloud Connector

This runbook is for an SAP Basis team configuring SAP Cloud Connector
(SCC) so that an end user's local OpenShell CLI reaches a Kyma cluster
over the corporate VPN instead of the public internet.

## Architecture

```text
Your laptop (openshell CLI)            BTP subaccount: <subaccount-name>
   │                                     ┌──────────────────────────────────┐
   │  gRPC / HTTPS (localhost:8080)      │                                  │
   ▼                                     │  Kyma cluster                    │
  kubectl port-forward                   │   ┌──────────────────────────┐   │
   │  K8s API request                    │   │ openshell-driver-kyma    │   │
   ▼                                     │   │  + openshell-gateway     │   │
  kubeconfig → server: SCC-host:N        │   └──────────────────────────┘   │
   │                                     │            ▲                     │
   ▼                                     │            │ Kubernetes API      │
  Corporate VPN                          │            │                     │
   │                                     │   ┌────────┴─────────────┐       │
   ▼                                     │   │ Kyma API server      │       │
  SAP Cloud Connector (in Basis DC)──────┼──▶│ <cluster-id>.kyma…   │       │
   │  Service Channel: Kubernetes        │   └──────────────────────┘       │
   │  outbound TLS tunnel                │                                  │
   └─────────────────────────────────────┘                                  │
                                         └──────────────────────────────────┘
```

## What SCC's "Service Channel for Kubernetes" actually provides

SCC's only inbound-to-BTP mechanism for Kyma is the **Service Channel
for Kubernetes**, which exposes the cluster's **Kubernetes API** on a
local SCC port. It is **not** a generic HTTPS reverse proxy — it cannot
directly route arbitrary traffic to in-cluster HTTP services. To reach a
custom HTTP service in the cluster (the OpenShell gateway), you still
go through the K8s API: open a Service Channel, point a kubeconfig at
the SCC-local port, and use `kubectl port-forward` to bring the
in-cluster service to your laptop's `localhost`.

Service Channel types currently supported by SCC (as of 2026):
**Kubernetes**, **HANA Cloud**, **ABAP Cloud**, **RFC**. Each is typed —
there is no arbitrary-HTTPS channel.

## Multi-cluster, multi-subaccount scaling

One SCC supports any number of Service Channels. The local port per
channel is determined by either:

- A **local instance number** `N` — the channel binds `30033 + N` for
  Kubernetes channels (default), or
- An **explicit port** picked by the admin (SCC 2.18 and newer).

Pattern when the same SCC serves multiple Kyma clusters across multiple
subaccounts:

| Subaccount | Kyma cluster | Instance N | Local port |
|---|---|---|---|
| `<subaccount-A>` | cluster A | 0 | `30033` |
| `<subaccount-B>` | cluster B | 1 | `30034` |
| `<subaccount-C>` | cluster C | 2 | `30035` |
| … | … | … | … |

Adding a new cluster is a Basis-side, no-restart operation: connect the
subaccount once, add a Service Channel with the next free `N`, hand the
user a kubeconfig pointing at `https://<scc-host>:3003<N+3>`.

`Location ID` is **not** needed for the multi-cluster-via-one-SCC case.
It is only required when *multiple SCCs* serve the *same* subaccount
(HA pair), so BTP knows which CC to dial through.

## Prerequisites the Basis team owns

1. SAP Cloud Connector **2.16.x or newer** (Service Channel for
   Kubernetes is GA since 2.13).
2. The SCC host is reachable from the corporate VPN range on the local
   ports the channels will bind. Firewall rule:
   `VPN-CIDR → SCC-IP : 30033/TCP` (and `+1`, `+2`, … per cluster).
3. Outbound from SCC to the BTP region's connectivity host on `443/TCP`.
   For a GCP `us-central1` BTP region the host is
   `connectivitycert.cf.us10.hana.ondemand.com`. Look up the exact host
   in BTP cockpit → subaccount → *Connectivity* → *Cloud Connectors*.

## Step-by-step in the SCC Admin UI

### 1. Connect each subaccount (one-time, per subaccount)

*Subaccounts* → *Add Subaccount* → enter:

- Region: matches the subaccount's BTP region (e.g.
  `cf.us10.hana.ondemand.com` for GCP `us-central1`).
- Subaccount ID: from BTP cockpit → subaccount → "Subaccount ID" field.
- Display name: a human-readable label (the subaccount technical name).
- Login email + password of an SCC admin user in BTP.
- Location ID: leave blank unless you operate multiple SCCs.

### 2. Add a Kubernetes Service Channel for each cluster

Select the subaccount → *On-Premise To Cloud* → *Service Channels* →
**Add** → choose type **Kubernetes API server**.

The "Add Service Channel" dialog asks for four required fields:

- **K8s Cluster Host** — the FQDN of the Kyma apiserver, taken
  from the cluster's existing kubeconfig (`server:` field, minus
  `https://` and minus the trailing `:443`). For BTP Kyma it's of
  the form `api.<shoot-id>.kyma.ondemand.com`. Enter ONLY the
  hostname, not a URL.
- **K8s Service ID** — a unique label that identifies this channel
  within the SCC instance. Convention: the cluster's shoot ID (the
  segment between `api.` and `.kyma.ondemand.com`, e.g.
  `c-abc1234`). It must be unique across all Service Channels on
  the same SCC; reusing the shoot ID makes that natural.
- **Local Port** — any free TCP port on the SCC host EXCEPT
  `8443` (reserved by SCC's own admin UI) and `8080` (reserved by
  SCC's HTTPS proxy listener). The form rejects any port it can't
  bind with "port not available" — fast feedback, but in a
  multi-user SCC every existing Service Channel is already holding
  one port, and you can't see those bindings from the BTP cockpit.
  Two practical paths:
  - **Ask the Basis team** for an allocated port. Any production
    SCC with more than one Service Channel maintains a
    per-subaccount port range. This is the operational norm.
  - **Guess if you must.** SAP's older SCC convention was
    auto-assigned `30033 + N` for the Nth K8s channel, so anywhere
    between `30033` and `30099` is a reasonable first guess.
    `9090`, `9091`, `11443`, `13443`, `15443` are also typically
    free. Avoid `6443` / `8443` / `8080`. If the first try fails
    you'll know within seconds, so iterate.
- **Connections** — TCP connection pool size. `1` is plenty for
  one developer running `kubectl` interactively; raise to `2`-`4`
  if multiple users share the channel or you need parallel
  port-forwards (the openshell-driver-kyma chart's port-forward
  to the gateway sidecar adds one more connection).
- **Enabled** — leave checked.

Repeat once per cluster. Channels for different subaccounts on the same
SCC are entirely independent — they only need unique local ports.

### 3. Verify

- Each channel reports **Connected** in the SCC UI.
- BTP cockpit → subaccount → *Connectivity* → *Cloud Connectors* shows
  the SCC.
- The SCC subaccount overview ("Initiated By", "Tunnel ID", "Region
  Host", "Subaccount") and the Service Channel detail page both
  display operator-environment identifiers. Treat the whole SCC UI as
  containing potential PII and **never paste screenshots into a
  committed file or public ticket** — the repo's `.gitignore` blocks
  `sensitive-*`, `*PII*`, and image extensions specifically because
  this is the most common way these values escape.
- Hand the requesting user, per cluster:
  - SCC reachable hostname / IP.
  - The channel's local port.
  - The TLS trust certificate (the Kyma API server cert as proxied
    through the channel — SCC exposes it under
    *Connector → On-Premise to Cloud → Service Channels*).

## What the user does after Basis hands over the channel

1. Make sure the corporate VPN is up and `<scc-host>:<port>` accepts a
   TCP connection.
2. Download a fresh **kubeconfig.yaml** for the Kyma cluster from BTP
   cockpit (subaccount → *Kyma Environment* → *KubeconfigURL*).
3. Edit the `server:` URL in the kubeconfig from
   `https://api.<cluster-id>.kyma.ondemand.com` to
   `https://<scc-host>:<port>`. If Basis provided a TLS trust bundle,
   add it under `certificate-authority-data:`.
4. Verify connectivity:

   ```bash
   kubectl --kubeconfig kubeconfig.yaml get ns
   ```

   A browser pops once for OIDC; subsequent calls reuse the cached
   token.
5. Port-forward the OpenShell gateway to localhost:

   ```bash
   kubectl --kubeconfig kubeconfig.yaml \
     -n openshell-system port-forward svc/openshell-gateway 8080:8080
   ```

6. Point the OpenShell CLI at `http://localhost:8080`:

   ```bash
   openshell gateway add http://localhost:8080 --local
   openshell sandbox create -- claude
   ```

## Open prerequisite: the OpenShell gateway

The companion deployment of `openshell-driver-kyma` only handles the
gateway's compute-driver gRPC contract. Without the OpenShell gateway
running in the same pod, there is no `svc/openshell-gateway` to
`port-forward` against.

The upstream NVIDIA gateway needs a small fork (~20 lines of Rust) to
add a `--compute-driver-socket` flag — see the design spec at
`docs/superpowers/specs/2026-05-26-openshell-driver-kyma-design.md`
section 6. Two paths:

1. **Wait for upstream**: open an issue at NVIDIA/OpenShell asking for
   first-class external compute-driver socket support.
2. **Fork now**: add the flag to the gateway, build a custom image,
   deploy it as a sidecar in the same pod as `openshell-driver-kyma`
   sharing an `emptyDir` for the UDS. The reference deployment is
   sketched in `deploy/gateway-with-driver.yaml` of the upstream
   OpenShift driver repo.

Once the gateway is in place, the runbook above completes the private
routing path: VPN → SCC Service Channel → Kyma API server →
port-forward → OpenShell gateway.

## References

- [SAP Help Portal — On-Premises-To-Cloud Connections (Service Channels)](https://help.sap.com/docs/connectivity/sap-btp-connectivity-cf/on-premise-to-on-demand-connections-service-channels)
- [SAP Help Portal — Configure a Service Channel for a Kubernetes Cluster](https://help.sap.com/docs/connectivity/sap-btp-connectivity-cf/configure-service-channel-for-kubernetes-cluster?version=Cloud)
- [SAP Help Portal — Adding and Managing Subaccounts (Location ID)](https://help.sap.com/docs/connectivity/sap-btp-connectivity-cf/managing-subaccounts)
- [SAP Learning — Setting and Configuring Kubectl for Kyma](https://learning.sap.com/courses/developing-applications-in-sap-btp-kyma-runtime/setting-and-configuring-kubectl-for-kyma_b3d25bea-0ef5-498e-bd15-10ef0c23ed06)
- [SAP-samples/kyma-runtime-samples — DSAGTT22 step 2](https://github.com/SAP-samples/kyma-runtime-samples/blob/main/dsagtt22/tutorial/step2.md)

## What this runbook actually gives you with this chart

After SCC routes your laptop's `kubectl` to the Kyma apiserver, the
recommended pattern with this chart is:

1. `kubectl -n <release-ns> port-forward svc/<release>-openshell-driver-kyma 8080:8080`
2. `openshell --gateway-endpoint http://localhost:8080 sandbox …`

The port-forward goes through the same SCC tunnel `kubectl` uses —
no second tunnel, no second VPN. The CLI talks to localhost; SCC
forwards through to the gateway sidecar's Service VIP.

For an Always-On / no-VPN production path, see
[`production-deployment.md`](production-deployment.md) (uses an
OIDC-protected Kyma APIRule instead of port-forward).
