# Remote Gateway Access (revision 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the remote-access chart on PR #81 so that the OpenShell gateway is the only authenticator and serves TLS, and the cluster's shared Istio ingress gateway only routes and re-encrypts to it, with nothing that applies to that ingress gateway as a whole.

**Architecture:** Upstream's `grpcRoute` + `backendTLSPolicy` shape, written with Istio objects: the Kyma gateway terminates public TLS, a `VirtualService` routes by host, a `DestinationRule` originates TLS to the gateway pod and verifies its certificate against the chart CA, whose public certificate a post-install Job copies into the ingress gateway's namespace. The ingress gateway gets host-scoped source-address `AuthorizationPolicy`s only; the `RequestAuthentication` of revision 1 is removed. The gateway serves TLS on its usual port, so upstream's CLI prints `https://<host>/` service URLs.

**Tech Stack:** Helm 3 templates (Sprig), Istio `networking.istio.io/v1` and `security.istio.io/v1`, bash + Python 3 (PyYAML) render checks, Docker (the pinned upstream gateway image, `alpine/kubectl`), upstream `openshell` CLI v0.1.2.

**Spec:** `docs/superpowers/specs/2026-09-30-remote-gateway-access-design.md` (revision 2, approved 2026-10-01). The plan of 2026-09-30 describes revision 1, which is what the branch holds today.

## Global Constraints

- Work on branch `feat/remote-gateway-access` (PR #81, head `5d9adf3` when this plan was written). The code of revision 1 is reworked in place; nothing of it is released.
- **Nothing the chart renders may apply to the ingress gateway as a whole.** No `RequestAuthentication`, ever. Every `AuthorizationPolicy` has a workload selector and every rule names this release's hosts, none by the domain's wildcard. The ingress gateway's namespace gets only those policies, the CA Secret `<release-namespace>-<fullname>-gateway-ca`, and the `Role` and `RoleBinding` `<release-namespace>-<fullname>-gateway-ca-hook`.
- Never write a real cluster domain, issuer, tenant, client id, CIDR, application host or secret into any file, commit, log or subagent prompt. Fixtures use exactly: domain `example.org`, issuer `https://issuer.example`, client and audience `osh-client`, hook client `osh-hook`, CIDRs `203.0.113.0/24` and `2001:db8::/32`.
- Local helm runs with `KUBECONFIG=/dev/null`. Tasks 1 to 6 touch no cluster; no subagent ever runs `helm install`/`upgrade`/`rollback` or `kubectl` against one. Task 7 is run by the controller with the user, step by step.
- No Rust changes. (Rust builds and tests only in the dev container, `make fmt && make test`; this plan does not need them.) Chart and Cargo version stay `0.10.0`.
- Exact names, used verbatim: values `gateway.tls.enabled`, `gateway.tls.clientCa.enabled`, `gatewayIngress.caHook.image`; removed value `gateway.oidc.jwksUri`; removed helper `openshell-driver-kyma.gatewayBindPort`; new helper `openshell-driver-kyma.gatewayIngressCaSecretName`; new templates `gateway-destinationrule.yaml` and `gateway-ingress-ca.yaml`; objects `DestinationRule <fullname>-gateway-tls`, `ServiceAccount`/`Job <fullname>-gateway-ca-hook`; hook image `docker.io/alpine/kubectl:1.35.3@sha256:c4a11ae9a1cbac1f203bfe7efa481ae9c33b1bfdf1f73bc84f62cb973f039e4b`.
- `scripts/check-chart-render.sh` must end with `CHART_RENDER_OK`, `scripts/check-gateway-config.sh` with `GATEWAY_CONFIG_ACCEPTED`, `scripts/remote-access-check-test.sh` with `REMOTE_ACCESS_SELFTEST_OK`, and `helm lint` with `0 chart(s) failed`.
- In the bash part of `scripts/check-chart-render.sh` and in the other shell scripts, continuation and body lines are indented with **tabs**; the code blocks below contain them. The Python part of `check-chart-render.sh` uses four spaces.
- Every code block in this plan was applied to a copy of the branch and run, in this order, before the plan was written: the "Expected" lines are that run's output.
- Commit as the repository's configured identity (pass no `-c user.email`); inspect `git diff --cached` before every commit; end commit messages with `Co-Authored-By: <the committing model's name> <noreply@anthropic.com>`.
- `scripts/check-chart-render.sh` is oversized (over 1300 lines). This plan edits its check 8 in the file's own style and does not restructure it.

## Review Focus

1. **A release installed before 0.10.0 turns on gateway TLS**: its certificate does not name its Service and upstream's generator keeps existing Secrets. Expected: the live check refuses to upgrade it, or deletes the three PKI Secrets with `OSH_REGENERATE_PKI=1` (Task 5, self-test part 5); the chart cannot detect it at render time, so the docs and the guard message say it (Tasks 2 and 6).
2. **`gateway.sandboxJwt.serverTlsSecretName` set by the operator**: the CA must be copied from that Secret, not from the default name (Task 3, `good-8-pki-names`).
3. **A neighbour of the ingress gateway that answers differently only while the upgrade runs** (a pod restart on its side): one differing probe round must not roll the release back, two in a row must (Task 5, `neighbours_differ`; the self-test covers the persistent case only).
4. **`gatewayIngress.ingressNamespace` other than `istio-system`**: Secret, Role, RoleBinding, policies and the `DestinationRule`'s `exportTo` must all follow it. No render case sets it; read `gateway-ingress-ca.yaml`, `gateway-destinationrule.yaml` and `gateway-ingress-auth.yaml` for a hard-coded namespace.
5. **Sandboxes with an Istio sidecar (`driver.istioInjectSandboxes`) and gateway TLS**: unverified, documented under Known limitations (Task 6). The `DestinationRule`'s `exportTo` keeps the TLS rule away from them; whether their sidecar passes the supervisor's own TLS on a port named `grpc` is not tested by anything here.

---

### Task 1: The ingress gateway checks no token

**Files:**
- Modify: `deploy/helm/openshell-driver-kyma/templates/gateway-ingress-auth.yaml` (rewritten)
- Modify: `deploy/helm/openshell-driver-kyma/values.yaml` (`gateway.oidc.jwksUri`, the `gatewayIngress` comments)
- Test: `scripts/check-chart-render.sh`
- Commit first: `docs/superpowers/specs/2026-09-30-remote-gateway-access-design.md`, this plan

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: in `gatewayIngress.ingressNamespace`, `AuthorizationPolicy <release-namespace>-<fullname>-openshell-cli` (rendered only with `allowedCidrs` or `policyAction: ALLOW`) and `…-openshell-services`; no `RequestAuthentication`. In the check script: `expected_ingress(release_ns, fullname, host, cidrs, services, action="DENY", workspaces=("default",))`, `INGRESS_KINDS`, `T`, and the block `# 8b.`, which Tasks 2 and 3 extend.

- [ ] **Step 1: Commit the approved spec and this plan**

```bash
git add docs/superpowers/specs/2026-09-30-remote-gateway-access-design.md \
  docs/superpowers/plans/2026-10-01-remote-gateway-access-rev2.md
git diff --cached --stat
git commit -m "docs: remote gateway access, revision 2 (the gateway authenticates; the ingress only routes)" \
  -m "Co-Authored-By: <the committing model's name> <noreply@anthropic.com>"
```

- [ ] **Step 2: Change the render checks**

In `scripts/check-chart-render.sh`, replace

```bash
#      are exactly the documented ones, in the ingress gateway's namespace; and the
#      provider hook authenticates with the client-credentials grant under OIDC.
```

with

```bash
#      are exactly the documented ones, in the ingress gateway's namespace; and the
#      provider hook authenticates with the client-credentials grant under OIDC.
#      8b: in every render, nothing applies to the shared ingress gateway as a whole:
#      no RequestAuthentication, and no AuthorizationPolicy rule without this
#      release's hosts.
```

In `scripts/check-chart-render.sh`, replace

```bash
try good-8-host '' t "${ingress_common[@]}" --set gatewayIngress.host=osh.example.org \
	--set gateway.oidc.jwksUri=https://issuer.example/oauth2/certs
# The issuer reaches the policies verbatim, a trailing slash included.
try good-8-issuer-slash '' t "${ingress_common[@]}" --set gateway.oidc.issuer=https://issuer.example/
```

with

```bash
try good-8-host '' t "${ingress_common[@]}" --set gatewayIngress.host=osh.example.org
```

In `scripts/check-chart-render.sh`, replace

```python
INGRESS_RENDERS = ("good-8-ingress", "good-8-services", "good-8-host", "good-8-issuer-slash",
                   "good-8-long-names", "good-8-rbac-roles", "good-8-oidc-default-roles",
```

with

```python
INGRESS_RENDERS = ("good-8-ingress", "good-8-services", "good-8-host",
                   "good-8-long-names", "good-8-rbac-roles", "good-8-oidc-default-roles",
```

In `scripts/check-chart-render.sh`, replace everything from the line that begins (after its indentation) with

```text
# The Istio objects. Routes live in the release namespace
```

through the next line that begins with

```text
failures.append(f"{name}: {'/'.join(key)} is
```

(both lines included) with:

```python
# The Istio objects. Routes live in the release namespace, policies on the ingress
# gateway in its own namespace, named for the release namespace so releases never collide.
# The ingress gateway checks no token: the OpenShell gateway is the only authenticator, as
# upstream intends (8b says why). The policies are source-address fences. Their action
# follows the gateway: DENY (default) for a gateway that lets everything through, where an
# ALLOW policy would make it deny every other application's hosts; ALLOW for a gateway that
# already allowlists. The CLI host gets a policy only where there is something to state:
# allowedCidrs, or ALLOW, which must admit the host. Service hosts are matched per workspace
# ("<workspace>--*"), never by the domain's wildcard, which would cover the CLI host and
# other applications.
INGRESS_KINDS = ("VirtualService", "RequestAuthentication", "AuthorizationPolicy")
SELECTOR = {"matchLabels": {"istio": "ingressgateway"}}
CIDRS = ["203.0.113.0/24", "2001:db8::/32"]

def service_host(workspaces):
    return (r"^(" + "|".join(workspaces) + r")--[a-z0-9]+(-[a-z0-9]+)*(--[a-z0-9]+(-[a-z0-9]+)*)?"
            r"\.example\.org(:[0-9]+)?$")

def ingress_objects(name):
    return {(d["kind"], d["metadata"]["namespace"], d["metadata"]["name"]): d["spec"]
            for d in docs(work / f"{name}.yaml") if d.get("kind") in INGRESS_KINDS}

def route(service, port, match=None):
    # No timeout field: Istio's default is no timeout, which the streaming RPCs need, and its
    # CRD validation rejects an explicit `0s` (live run on Kyma: "must be ... greater than 1ms").
    rule = {"route": [{"destination": {"host": service, "port": {"number": port}}}]}
    return [dict(match=[{"authority": {"regex": match}}], **rule) if match else rule]

def expected_ingress(release_ns, fullname, host, cidrs, services, action="DENY", workspaces=("default",)):
    service = f"{fullname}.{release_ns}.svc.cluster.local"
    prefix = f"{release_ns}-{fullname}"
    blocks = "remoteIpBlocks" if action == "ALLOW" else "notRemoteIpBlocks"
    want = {
        ("VirtualService", release_ns, f"{fullname}-gateway"): {
            "hosts": [host], "gateways": ["kyma-system/kyma-gateway"], "http": route(service, 8080)},
    }
    if cidrs or action == "ALLOW":
        # With and without a port: Istio matches hosts against the authority as sent.
        rule = {"to": [{"operation": {"hosts": [host, host + ":*"]}}]}
        if cidrs:
            rule["from"] = [{"source": {blocks: cidrs}}]
        want[("AuthorizationPolicy", "istio-system", f"{prefix}-openshell-cli")] = {
            "selector": SELECTOR, "action": action, "rules": [rule]}
    if services:
        want[("VirtualService", release_ns, f"{fullname}-sandbox-services")] = {
            "hosts": ["*.example.org"], "gateways": ["kyma-system/kyma-gateway"],
            "http": route(service, 80, service_host(workspaces))}
        want[("AuthorizationPolicy", "istio-system", f"{prefix}-openshell-services")] = {
            "selector": SELECTOR, "action": action,
            "rules": [{"from": [{"source": {blocks: cidrs}}],
                       "to": [{"operation": {"hosts": [w + "--*" for w in workspaces]}}]}]}
    return want

T = ("default", "t-openshell-driver-kyma")   # helm template's namespace and the fullname of release t
INGRESS_OBJECTS = {
    # DENY without allowedCidrs: nothing to deny, so no policy for the CLI host.
    "good-8-ingress": expected_ingress(*T, "openshell.example.org", None, False),
    "good-8-services": expected_ingress(*T, "openshell.example.org", CIDRS, True),
    "good-8-host": expected_ingress(*T, "osh.example.org", None, False),
    "good-8-long-names": expected_ingress("a-rather-long-release-namespace-name", "prod-sandboxes-openshell-driver-kyma",
                                          "openshell.example.org", CIDRS, True),
    # ALLOW without allowedCidrs: the rule has no source, it only admits the host.
    "good-8-allow": expected_ingress(*T, "openshell.example.org", None, False, action="ALLOW"),
    "good-8-allow-services": expected_ingress(*T, "openshell.example.org", CIDRS, True, action="ALLOW",
                                              workspaces=("default", "team-a")),
}
for name, want in INGRESS_OBJECTS.items():
    if not succeeded(name):
        continue
    got = ingress_objects(name)
    for key in sorted(set(got) | set(want)):
        if got.get(key) != want.get(key):
            failures.append(f"{name}: {'/'.join(key)} is {got.get(key)}, want {want.get(key)}")
```

In `scripts/check-chart-render.sh`, replace everything from the line that begins (after its indentation) with

```text
for name in INGRESS_OBJECTS:
```

through the next line that begins with

```text
"and other applications")
```

(both lines included) with:

```python

# 8b. The cluster's ingress gateway is shared with every other application behind it, so
# nothing the chart renders may apply to it as a whole, in any render of this script.
# - No RequestAuthentication. It has no host scope: on the ingress gateway it makes Envoy
#   answer 401 to every Bearer token it cannot validate, on every host. In a live run that
#   broke another application's login and its API keys.
# - Every AuthorizationPolicy selects a workload, and every rule names hosts, none of them
#   by the domain's wildcard.
if re.search(r"^kind:\s*RequestAuthentication", templates, re.M):
    failures.append("a template renders a RequestAuthentication; the gateway validates tokens itself")
if "jwksUri" in ((yaml.safe_load(values) or {}).get("gateway") or {}).get("oidc", {}):
    failures.append("values.yaml still has gateway.oidc.jwksUri, which only fed the removed RequestAuthentication")
for path in sorted(work.glob("*.yaml")):
    rc = work / f"{path.stem}.rc"
    if rc.exists() and rc.read_text() != "0":
        continue
    for d in docs(path):
        where = f"{path.stem}: {d.get('kind')} {d['metadata'].get('name')}"
        if d.get("kind") == "RequestAuthentication":
            failures.append(f"{where}: a RequestAuthentication applies to every host of the workload it selects")
        if d.get("kind") != "AuthorizationPolicy":
            continue
        if not (d["spec"].get("selector") or {}).get("matchLabels"):
            failures.append(f"{where}: no workload selector")
        for rule in d["spec"].get("rules") or [{}]:
            hosts = [h for t in rule.get("to") or [] for h in (t.get("operation") or {}).get("hosts") or []]
            if not hosts or any(h.startswith("*") for h in hosts):
                failures.append(f"{where}: a rule matches hosts {hosts}; every rule must name this release's "
                                "hosts, and a suffix wildcard covers other applications")
```

- [ ] **Step 3: Run the checks and watch them fail**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -30`

Expected: `CHART_RENDER_FAIL:` with 22 failures, among them

```text
  - good-8-ingress: RequestAuthentication/istio-system/default-t-openshell-driver-kyma-openshell-jwt is {'selector': …}, want None
  - good-8-allow: AuthorizationPolicy/istio-system/default-t-openshell-driver-kyma-openshell-cli is {… 'requestPrincipals': ['https://issuer.example/*'] …}, want …
  - a template renders a RequestAuthentication; the gateway validates tokens itself
  - values.yaml still has gateway.oidc.jwksUri, which only fed the removed RequestAuthentication
  - good-8-rbac-roles: RequestAuthentication default-t-openshell-driver-kyma-openshell-jwt: a RequestAuthentication applies to every host of the workload it selects
```

- [ ] **Step 4: Rewrite the policies and remove the value**

Write `deploy/helm/openshell-driver-kyma/templates/gateway-ingress-auth.yaml` (the whole file):

```yaml
{{- if .Values.gatewayIngress.enabled -}}
{{- $prefix := include "openshell-driver-kyma.gatewayIngressPolicyPrefix" . -}}
{{- $in := .Values.gatewayIngress -}}
{{- $allow := eq $in.policyAction "ALLOW" -}}
{{- $host := include "openshell-driver-kyma.gatewayIngressHost" . -}}
# Source-address fences on the cluster's Istio ingress gateway, in its namespace.
#
# The ingress gateway is shared with every other application of the cluster, so
# nothing here may apply to it as a whole: every rule names this release's hosts.
# There is no RequestAuthentication. It has no host scope, and one on the ingress
# gateway makes Envoy answer 401 to every Bearer token it cannot validate, on every
# host: other applications' logins and API keys break. The OpenShell gateway
# validates the caller's token itself, as upstream intends.
#
# gatewayIngress.policyAction follows the ingress gateway. Without any ALLOW policy
# Istio lets every request through, and the first ALLOW policy would make the gateway
# deny every other application's hosts: there the chart writes DENY policies (the
# default), which name only its own hosts. A gateway that already has ALLOW policies
# denies whatever no policy allows: there the chart writes ALLOW policies for its hosts.
{{- if or $allow $in.allowedCidrs }}
---
# The CLI host. With allowedCidrs, only those source addresses reach it; under ALLOW
# without them, every source does (the gateway authenticates). Under DENY without
# them there is nothing to deny and no policy. Hosts are listed with and without a
# port: Istio matches them against the authority as the client sent it.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: {{ $prefix }}-openshell-cli
  namespace: {{ $in.ingressNamespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- toYaml $in.ingressSelector | nindent 6 }}
  action: {{ $in.policyAction }}
  rules:
    - to:
        - operation:
            hosts:
              - {{ $host | quote }}
              - {{ printf "%s:*" $host | quote }}
      {{- with $in.allowedCidrs }}
      from:
        - source:
            {{ ternary "remoteIpBlocks" "notRemoteIpBlocks" $allow }}:
              {{- toYaml . | nindent 14 }}
      {{- end }}
{{- end }}
{{- if $in.serviceHosts.enabled }}
---
# Sandbox service hosts: the gateway does not authenticate a browser's request to a
# service URL, so the source address is the only fence. They are matched per
# workspace, as <workspace>--*: Istio's hosts take only a prefix or a suffix wildcard,
# and the domain's wildcard would also cover the CLI host and every other application
# under the domain.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: {{ $prefix }}-openshell-services
  namespace: {{ $in.ingressNamespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- toYaml $in.ingressSelector | nindent 6 }}
  action: {{ $in.policyAction }}
  rules:
    - from:
        - source:
            {{ ternary "remoteIpBlocks" "notRemoteIpBlocks" $allow }}:
              {{- toYaml $in.allowedCidrs | nindent 14 }}
      to:
        - operation:
            hosts:
              {{- range $in.serviceHosts.workspaces }}
              - {{ printf "%s--*" . | quote }}
              {{- end }}
{{- end }}
{{- end }}
```

In `deploy/helm/openshell-driver-kyma/values.yaml`, delete:

```yaml
    # JWKS URL for the ingress gateway's RequestAuthentication (gatewayIngress).
    # Empty lets Istio discover it from the issuer; the gateway always does.
    jwksUri: ""
```

In `deploy/helm/openshell-driver-kyma/values.yaml`, replace

```yaml
# Renders, in the release namespace, a VirtualService for `host`, and in
# `ingressNamespace` a RequestAuthentication (the issuer's tokens) and an ALLOW
# AuthorizationPolicy for `host` that requires such a token. Installing with this
# block enabled therefore needs rights in `ingressNamespace`.
```

with

```yaml
# The gateway is the only authenticator, as upstream intends: it validates the
# caller's OIDC token itself. The ingress gateway routes and, with allowedCidrs,
# fences by source address; it checks no token.
#
# Renders, in the release namespace, a VirtualService for `host`, and in
# `ingressNamespace` AuthorizationPolicies that name only this release's hosts.
# Nothing it renders applies to the ingress gateway as a whole. Installing with
# this block enabled needs rights in `ingressNamespace`.
```

In `deploy/helm/openshell-driver-kyma/values.yaml`, replace

```yaml
  # Source addresses or CIDR blocks (Istio remoteIpBlocks). Optional extra fence
  # for `host`; required for serviceHosts.
  allowedCidrs: []
```

with

```yaml
  # Source addresses or CIDR blocks (Istio remoteIpBlocks). Optional fence for
  # `host` (the gateway authenticates every call either way); required for
  # serviceHosts.
  allowedCidrs: []
```

- [ ] **Step 5: Run the checks and watch them pass**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -30`
Expected: last line `CHART_RENDER_OK`

Run: `KUBECONFIG=/dev/null helm lint deploy/helm/openshell-driver-kyma`
Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 6: Commit**

```bash
git add deploy/helm/openshell-driver-kyma/templates/gateway-ingress-auth.yaml \
  deploy/helm/openshell-driver-kyma/values.yaml \
  scripts/check-chart-render.sh
git diff --cached --stat
git commit -m "fix(chart): the ingress gateway checks no token; nothing applies to it as a whole" \
  -m "Co-Authored-By: <the committing model's name> <noreply@anthropic.com>"
```


### Task 2: The gateway serves TLS, with a certificate that names its Service

**Files:**
- Modify: `deploy/helm/openshell-driver-kyma/templates/_gateway-ingress.tpl` (helper `gatewayBindPort` removed, TLS guards)
- Modify: `deploy/helm/openshell-driver-kyma/templates/deployment.yaml`, `deploy/helm/openshell-driver-kyma/templates/networkpolicy.yaml` (the gateway's port; no sysctl)
- Modify: `deploy/helm/openshell-driver-kyma/templates/gateway-jwt-pki-hook.yaml` (`--server-san`)
- Modify: `deploy/helm/openshell-driver-kyma/values.yaml` (comments)
- Test: `scripts/check-chart-render.sh`, `scripts/check-gateway-config.sh`, `.github/workflows/helm-lint.yml`

**Interfaces:**
- Consumes: Task 1's `T`, `INGRESS_RENDERS`, `gateway_parts`, `flag`.
- Produces: `gatewayIngress.enabled` renders only with `gateway.tls.enabled=true` and `gateway.tls.clientCa.enabled=false`; the gateway binds `gateway.grpcPort` in every render; the PKI hook passes `--server-san=<fullname>`, `<fullname>.<ns>`, `<fullname>.<ns>.svc`, `<fullname>.<ns>.svc.cluster.local`, `localhost`, `127.0.0.1`. In the check script: `ingress_common` carries `--set gateway.tls.enabled=true`; `pki_sans(name)`.

After this task the chart is not installable with `gatewayIngress` until Task 3 adds the TLS rule at the ingress gateway: the ingress would still send plaintext to a TLS listener. Nothing is deployed between the two.

- [ ] **Step 1: Change the render checks, the gateway flag check and the lint workflow**

In `scripts/check-chart-render.sh`, replace

```bash
#   8. remote access (gatewayIngress): values that cannot work (no OIDC, no domain, a
#      host outside it, gateway TLS, service hosts without an allowlist, a malformed
#      CIDR, one OIDC role without the other) fail the render; the gateway's listener,
#      Service and NetworkPolicy follow the bind port; the Istio routes and policies
```

with

```bash
#   8. remote access (gatewayIngress): values that cannot work (no OIDC, no domain, a
#      host outside it, a gateway without TLS or with a client CA, service hosts
#      without an allowlist, a malformed CIDR, one OIDC role without the other) fail
#      the render; the gateway serves TLS on its usual port, with a certificate that
#      names this release's Service; the Istio routes and policies
```

In `scripts/check-chart-render.sh`, replace

```bash
	--set gateway.oidc.clientId=osh-client --set gateway.oidc.authOnly=true)
ingress_services=(
```

with

```bash
	--set gateway.oidc.clientId=osh-client --set gateway.oidc.authOnly=true
	--set gateway.tls.enabled=true)
ingress_services=(
```

In `scripts/check-chart-render.sh`, replace

```bash
# Another release name and namespace, and pod sysctls the operator already sets.
try good-8-long-names '' prod-sandboxes "${ingress_common[@]}" "${ingress_services[@]}" \
	--namespace a-rather-long-release-namespace-name \
	--set-json 'podSecurityContext.sysctls=[{"name":"net.ipv4.ping_group_range","value":"0 0"}]'
```

with

```bash
# Another release name and namespace.
try good-8-long-names '' prod-sandboxes "${ingress_common[@]}" "${ingress_services[@]}" \
	--namespace a-rather-long-release-namespace-name
```

In `scripts/check-chart-render.sh`, replace

```bash
try bad-8-tls 'gateway.tls.enabled' t "${ingress_common[@]}" --set gateway.tls.enabled=true
```

with

```bash
# Behind the ingress gateway the gateway serves TLS, and takes no client certificate:
# the ingress gateway has none to present.
try bad-8-no-tls 'requires gateway.tls.enabled=true' t "${ingress_common[@]}" --set gateway.tls.enabled=false
try bad-8-client-ca 'gateway.tls.clientCa.enabled' t "${ingress_common[@]}" --set gateway.tls.clientCa.enabled=true
```

In `scripts/check-chart-render.sh`, delete:

```bash
# Pod security settings the operator already has: the sysctl is not listed twice (the API
# server rejects a duplicate), and a null context still renders.
try good-8-sysctl-present '' t "${ingress_common[@]}" "${ingress_services[@]}" \
	--set-json 'podSecurityContext.sysctls=[{"name":"net.ipv4.ip_unprivileged_port_start","value":"0"}]'
try good-8-null-pod-security '' t --set-json 'podSecurityContext=null'
```

In `scripts/check-chart-render.sh`, replace

```bash
                   "good-8-allow", "good-8-allow-services", "good-8-sysctl-present", "good-8-null-pod-security")
```

with

```bash
                   "good-8-allow", "good-8-allow-services")
```

In `scripts/check-chart-render.sh`, replace everything from the line that begins (after its indentation) with

```text
# The gateway's listener. Upstream prints a service URL with the bind port
```

through the next line that begins with

```text
f"which must include the gateway's bind port {port} and no stale 8080")
```

(both lines included) with:

```python
# The gateway's listener. Behind the ingress gateway it serves TLS on its usual port,
# without a client CA (the ingress gateway has no client certificate to present). It then
# reports https service URLs, which upstream's CLI prints with the gateway endpoint's port:
# https://<host>/ through the ingress. No privileged port, so no pod sysctl. With published
# service hosts it takes the service domain from a wildcard --server-san, and the Service
# adds an http-* port on the same listener.
LISTENER = {  # render -> (TLS, --server-san, Service ports on the listener)
    "render-shared-true": (False, [], {"grpc": 8080}),
    "good-8-ingress": (True, [], {"grpc": 8080}),
    "good-8-services": (True, ["*.example.org"], {"grpc": 8080, "http-services": 80}),
    "good-8-long-names": (True, ["*.example.org"], {"grpc": 8080, "http-services": 80}),
}
for name, (tls, sans, service_ports) in LISTENER.items():
    if name != "render-shared-true" and not succeeded(name):
        continue
    gateway, pod, service, policy = gateway_parts(name)
    args = gateway["args"]
    got = (flag(args, "--port"), [p["containerPort"] for p in gateway["ports"] if p["name"] == "grpc"],
           (pod.get("securityContext") or {}).get("sysctls"), flag(args, "--server-san"))
    if got != (["8080"], [8080], None, sans):
        failures.append(f"{name}: gateway (--port, grpc containerPort, pod sysctls, --server-san) is {got}, "
                        f"want {(['8080'], [8080], None, sans)}")
    got = (flag(args, "--tls-cert"), flag(args, "--tls-key"), "--tls-client-ca" in args, "--disable-tls" in args)
    want = ((["/etc/openshell-tls/server/tls.crt"], ["/etc/openshell-tls/server/tls.key"], False, False)
            if tls else ([], [], False, True))
    if got != want:
        failures.append(f"{name}: gateway TLS (--tls-cert, --tls-key, has --tls-client-ca, has --disable-tls) "
                        f"is {got}, want {want}")
    ports = {p["name"]: (p["port"], p["targetPort"]) for p in service["spec"]["ports"]
             if p["name"] in ("grpc", "http-services")}
    if ports != {n: (p, "grpc") for n, p in service_ports.items()}:
        failures.append(f"{name}: the Service's listener ports are {ports}, want {service_ports} -> grpc")
    allowed = [p["port"] for p in policy["spec"]["ingress"][0]["ports"]] if policy else []
    if 8080 not in allowed:
        failures.append(f"{name}: the driver pod's NetworkPolicy admits ports {allowed}, not the gateway's 8080")
```

In `scripts/check-chart-render.sh`, replace

```bash
# Nothing of it without gatewayIngress: not by default, and not with OIDC alone.
```

with

```python
# The PKI hook mints the gateway's server certificate for the names clients verify it
# under: this release's Service (sandboxes, the provider hook, the ingress gateway) and
# loopback (a port-forward). Upstream's own defaults name a release called "openshell",
# so without these no client in the cluster could verify a gateway that serves TLS.
def pki_sans(name):
    job = next(d for d in docs(work / f"{name}.yaml") if d.get("kind") == "Job"
               and d["metadata"]["name"].endswith("-jwt-pki-hook"))
    return [a.split("=", 1)[1] for a in job["spec"]["template"]["spec"]["containers"][0]["args"]
            if a.startswith("--server-san=")]

for name, (ns, fullname) in (("render-shared-true", T), ("good-8-long-names", (
        "a-rather-long-release-namespace-name", "prod-sandboxes-openshell-driver-kyma"))):
    if name != "render-shared-true" and not succeeded(name):
        continue
    want = [fullname, f"{fullname}.{ns}", f"{fullname}.{ns}.svc", f"{fullname}.{ns}.svc.cluster.local",
            "localhost", "127.0.0.1"]
    if pki_sans(name) != want:
        failures.append(f"{name}: the PKI hook's --server-san are {pki_sans(name)}, want {want}")
# Nothing of it without gatewayIngress: not by default, and not with OIDC alone.
```

In `scripts/check-gateway-config.sh`, replace

```bash
  --set gateway.oidc.clientId=osh-client \
  --set gateway.oidc.authOnly=true
check_args rbac-roles \
```

with

```bash
  --set gateway.oidc.clientId=osh-client \
  --set gateway.oidc.authOnly=true \
  --set gateway.tls.enabled=true
check_args rbac-roles \
```

In `.github/workflows/helm-lint.yml`, replace

```yaml
            --set gateway.oidc.clientId=osh-client \
            --set gateway.oidc.authOnly=true \
            > /dev/null
```

with

```yaml
            --set gateway.oidc.clientId=osh-client \
            --set gateway.oidc.authOnly=true \
            --set gateway.tls.enabled=true \
            > /dev/null
```

- [ ] **Step 2: Run the checks and watch them fail**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -30`

Expected: `CHART_RENDER_FAIL:` with 23 failures: every `good-8-*` render with `gatewayIngress` fails with the old guard, and the certificate has no names:

```text
  - good-8-ingress: expected the render to succeed, it failed: Error: execution error at (openshell-driver-kyma/templates/gateway-virtualservice.yaml:2:4): gatewayIngress.enabled=true cannot be combined with gateway.tls.enabled=true: …
  - bad-8-no-tls: rendered, but the driver or upstream would refuse it at startup
  - render-shared-true: the PKI hook's --server-san are [], want ['t-openshell-driver-kyma', 't-openshell-driver-kyma.default', 't-openshell-driver-kyma.default.svc', 't-openshell-driver-kyma.default.svc.cluster.local', 'localhost', '127.0.0.1']
```

- [ ] **Step 3: Require TLS, drop the port-80 listener, name the Service in the certificate**

In `deploy/helm/openshell-driver-kyma/templates/_gateway-ingress.tpl`, replace

```yaml
{{/*
The port the gateway binds in the pod. Upstream prints a service URL as
<scheme>://<host>:<bind port>/ and leaves the port out only for http on 80
(openshell-server src/service_routing.rs endpoint_url at the pinned tag), so with
published service hosts the gateway binds 80: the URL is then http://<host>/,
which the Kyma gateway's http server redirects to https. Otherwise it binds
gateway.grpcPort, as before. The Service keeps gateway.grpcPort either way.
*/}}
{{- define "openshell-driver-kyma.gatewayBindPort" -}}
{{- if include "openshell-driver-kyma.serviceHostsEnabled" . -}}80{{- else -}}{{ .Values.gateway.grpcPort }}{{- end -}}
{{- end -}}

{{/*
Name prefix of the policies rendered into gatewayIngress.ingressNamespace. It
```

with

```yaml
{{/*
Name prefix of the policies rendered into gatewayIngress.ingressNamespace. It
```

In `deploy/helm/openshell-driver-kyma/templates/_gateway-ingress.tpl`, replace

```yaml
{{- if .Values.gateway.tls.enabled -}}
{{- fail "gatewayIngress.enabled=true cannot be combined with gateway.tls.enabled=true: the ingress gateway forwards plaintext HTTP/2 to the gateway pod. Set gateway.tls.enabled=false." -}}
{{- end -}}
```

with

```yaml
{{- /* Upstream's shape for a gateway behind a TLS-terminating proxy that re-encrypts
(its chart's grpcRoute.backendTLSPolicy): the gateway serves TLS and takes no client
certificate, because the proxy has none to present. */ -}}
{{- if not .Values.gateway.tls.enabled -}}
{{- fail "gatewayIngress.enabled=true requires gateway.tls.enabled=true: the gateway terminates TLS itself and the ingress gateway re-encrypts to it, so the hop into the pod is encrypted and the service URLs the gateway reports are https. An install from before 0.10.0 must regenerate its PKI first (CHANGELOG.md, 0.10.0 upgrade note)." -}}
{{- end -}}
{{- if .Values.gateway.tls.clientCa.enabled -}}
{{- fail "gatewayIngress.enabled=true cannot be combined with gateway.tls.clientCa.enabled=true: the ingress gateway presents no client certificate to the gateway. Callers authenticate with OIDC." -}}
{{- end -}}
```

In `deploy/helm/openshell-driver-kyma/templates/deployment.yaml`, replace everything from the line that begins (after its indentation) with

```text
{{- $podSecurity := deepCopy
```

through the next line that begins with

```text
{{- toYaml $podSecurity | nindent 8 }}
```

(both lines included) with:

```yaml
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
```

In `deploy/helm/openshell-driver-kyma/templates/deployment.yaml`, replace

```yaml
            - {{ include "openshell-driver-kyma.gatewayBindPort" . | quote }}
```

with

```yaml
            - {{ .Values.gateway.grpcPort | quote }}
```

In `deploy/helm/openshell-driver-kyma/templates/deployment.yaml`, replace

```yaml
              containerPort: {{ include "openshell-driver-kyma.gatewayBindPort" . }}
```

with

```yaml
              containerPort: {{ .Values.gateway.grpcPort }}
```

In `deploy/helm/openshell-driver-kyma/templates/networkpolicy.yaml`, replace

```yaml
        - port: {{ include "openshell-driver-kyma.gatewayBindPort" . }}
```

with

```yaml
        - port: {{ .Values.gateway.grpcPort }}
```

In `deploy/helm/openshell-driver-kyma/templates/gateway-jwt-pki-hook.yaml`, replace

```yaml
            - --jwt-secret-name={{ include "openshell-driver-kyma.jwtSecretName" . }}
```

with

```yaml
            - --jwt-secret-name={{ include "openshell-driver-kyma.jwtSecretName" . }}
            # The names clients verify the gateway under: this release's Service
            # (sandboxes, the provider hook, the ingress gateway) and loopback (a
            # port-forward). Upstream's own defaults name a release called "openshell".
            {{- $service := include "openshell-driver-kyma.fullname" . }}
            - --server-san={{ $service }}
            - --server-san={{ $service }}.{{ .Release.Namespace }}
            - --server-san={{ $service }}.{{ .Release.Namespace }}.svc
            - --server-san={{ $service }}.{{ .Release.Namespace }}.svc.cluster.local
            - --server-san=localhost
            - --server-san=127.0.0.1
```

In `deploy/helm/openshell-driver-kyma/values.yaml`, replace

```yaml
  # When `enabled: false` (default), the chart passes `--disable-tls` to
  # the gateway and it serves plaintext HTTP — suitable only for
  # in-cluster deployments behind a TLS-terminating reverse proxy
  # (gatewayIngress and the Kyma gateway), or for fully-trusted local dev.
  # NOT safe for direct public exposure.
```

with

```yaml
  # When `enabled: false` (default), the chart passes `--disable-tls` to
  # the gateway and it serves plaintext HTTP — suitable only for
  # in-cluster use and a port-forward. NOT safe for direct public exposure.
```

In `deploy/helm/openshell-driver-kyma/values.yaml`, replace

```yaml
  # so the gateway terminates HTTPS itself.
  #
```

with

```yaml
  # so the gateway terminates HTTPS itself. Sandboxes then dial https:// and
  # verify the gateway against the chart CA. gatewayIngress requires it: the
  # ingress gateway re-encrypts to the gateway pod.
  #
  # The PKI hook creates the certificate once and never replaces it. A release
  # installed before 0.10.0 has one without this release's Service names, which
  # no client can verify: delete the three PKI Secrets before the upgrade that
  # turns this on (CHANGELOG.md, 0.10.0 upgrade note).
  #
```

In `deploy/helm/openshell-driver-kyma/values.yaml`, replace

```yaml
  # reverse proxy, OR when distributing the chart's client-tls Secret to
  # a small set of admins as a simple SPIFFE-ish auth model.
```

with

```yaml
  # reverse proxy, OR when distributing the chart's client-tls Secret to
  # a small set of admins as a simple SPIFFE-ish auth model. Not with
  # gatewayIngress: the ingress gateway presents no client certificate.
```

In `deploy/helm/openshell-driver-kyma/values.yaml`, replace

```yaml
  # Publish sandbox services (`openshell service expose`) at
  # https://<workspace>--<sandbox>[--<service>].<domain>/. Through the remote
  # gateway the CLI prints that URL as http://<host>:443/ (the gateway's scheme,
  # the endpoint's port): use the host with https://.
  # A browser sends no token, so these hosts are fenced by allowedCidrs only.
  # They are published per workspace: routes and policies match <workspace>--*
  # for the workspaces listed here, never the whole domain, so nothing else under
  # the domain is affected and a workspace that is not listed is not reachable.
  # With this on, the gateway binds port 80 in the pod (the pod gets the safe
  # sysctl net.ipv4.ip_unprivileged_port_start=0), so the URL it hands to API
  # and SDK clients is http://<host>/, which the Kyma gateway redirects to https.
```

with

```yaml
  # Publish sandbox services (`openshell service expose`) at
  # https://<workspace>--<sandbox>[--<service>].<domain>/, the URL the CLI prints.
  # (API and SDK clients get the gateway's own value, which carries the port the
  # gateway binds in the pod, :8080; drop the port.)
  # The gateway does not authenticate requests to these hosts, so they are fenced
  # by allowedCidrs only. They are published per workspace: routes and policies
  # match <workspace>--* for the workspaces listed here, never the whole domain,
  # so nothing else under the domain is affected and a workspace that is not
  # listed is not reachable.
```

- [ ] **Step 4: Run the checks and watch them pass**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -30`
Expected: last line `CHART_RENDER_OK`

Run: `grep -rn gatewayBindPort deploy/helm/openshell-driver-kyma/templates; KUBECONFIG=/dev/null helm lint deploy/helm/openshell-driver-kyma`
Expected: no `gatewayBindPort` line, then `1 chart(s) linted, 0 chart(s) failed`

Run: `./scripts/check-gateway-config.sh 2>&1 | grep -E "GATEWAY_(ARGS|CONFIG)_"` (needs Docker)
Expected:

```text
GATEWAY_ARGS_ACCEPTED (defaults, 15 args)
GATEWAY_ARGS_ACCEPTED (remote-access, 28 args)
GATEWAY_ARGS_ACCEPTED (rbac-roles, 25 args)
GATEWAY_CONFIG_ACCEPTED
```

- [ ] **Step 5: Prove the pinned generator puts the names into the certificate**

```bash
IMAGE=$(KUBECONFIG=/dev/null helm template t deploy/helm/openshell-driver-kyma --set gateway.enabled=true \
  --set gateway.sandboxJwt.enabled=true --set gatewayService.enabled=true \
  --show-only templates/gateway-jwt-pki-hook.yaml | awk '/image:/ { gsub(/"/, "", $2); print $2; exit }')
docker run --rm --entrypoint openshell-gateway "$IMAGE" generate-certs --namespace x \
  --server-secret-name a --client-secret-name b --jwt-secret-name c \
  --server-san=t-openshell-driver-kyma.default.svc.cluster.local --server-san=127.0.0.1 --dry-run 2>/dev/null \
  | awk '/# Server certificate/ { on = 1; next } on && /BEGIN/ { p = 1 } p { print } p && /END/ { exit }' \
  | openssl x509 -noout -ext subjectAltName
```

Expected: a list that contains `DNS:t-openshell-driver-kyma.default.svc.cluster.local` next to upstream's defaults (`DNS:openshell`, `DNS:openshell.openshell.svc`, …).

- [ ] **Step 6: Commit**

```bash
git add deploy/helm/openshell-driver-kyma/templates/_gateway-ingress.tpl \
  deploy/helm/openshell-driver-kyma/templates/deployment.yaml \
  deploy/helm/openshell-driver-kyma/templates/networkpolicy.yaml \
  deploy/helm/openshell-driver-kyma/templates/gateway-jwt-pki-hook.yaml \
  deploy/helm/openshell-driver-kyma/values.yaml \
  scripts/check-chart-render.sh \
  scripts/check-gateway-config.sh \
  .github/workflows/helm-lint.yml
git diff --cached --stat
git commit -m "fix(chart): gateway TLS behind the ingress; the certificate names the release's Service" \
  -m "Co-Authored-By: <the committing model's name> <noreply@anthropic.com>"
```


### Task 3: TLS from the ingress gateway to the gateway pod

**Files:**
- Create: `deploy/helm/openshell-driver-kyma/templates/gateway-destinationrule.yaml`
- Create: `deploy/helm/openshell-driver-kyma/templates/gateway-ingress-ca.yaml`
- Modify: `deploy/helm/openshell-driver-kyma/templates/_gateway-ingress.tpl` (helper `gatewayIngressCaSecretName`, guard)
- Modify: `deploy/helm/openshell-driver-kyma/values.yaml` (`gatewayIngress.caHook.image`, comments)
- Test: `scripts/check-chart-render.sh`

**Interfaces:**
- Consumes: Task 1's `expected_ingress`, `INGRESS_KINDS`, block `# 8b.`; Task 2's TLS guard and PKI block.
- Produces: `DestinationRule <fullname>-gateway-tls` (release namespace, `exportTo` the ingress namespace); in the ingress namespace `Secret <release-namespace>-<fullname>-gateway-ca` (no data in the manifest) and the hook's `Role`/`RoleBinding <release-namespace>-<fullname>-gateway-ca-hook`; in the release namespace `ServiceAccount` and `Job <fullname>-gateway-ca-hook`. In the check script: `check_ca(name, release_ns, fullname, server_secret=None)`, `CA_HOOK_IMAGE`.

- [ ] **Step 1: Change the render checks**

In `scripts/check-chart-render.sh`, replace

```bash
#      names this release's Service; the Istio routes and policies
#      are exactly the documented ones, in the ingress gateway's namespace; and the
#      provider hook authenticates with the client-credentials grant under OIDC.
```

with

```bash
#      names this release's Service; the Istio routes, the TLS rule from the ingress
#      gateway to the pod and the policies are exactly the documented ones; the
#      ingress gateway's namespace gets nothing but those policies, the chart CA's
#      public certificate and the right of one Job to write it; and the provider
#      hook authenticates with the client-credentials grant under OIDC.
```

In `scripts/check-chart-render.sh`, replace

```bash
try bad-8-client-ca 'gateway.tls.clientCa.enabled' t "${ingress_common[@]}" --set gateway.tls.clientCa.enabled=true
```

with

```bash
try bad-8-client-ca 'gateway.tls.clientCa.enabled' t "${ingress_common[@]}" --set gateway.tls.clientCa.enabled=true
try bad-8-no-ca-hook-image 'gatewayIngress.caHook.image' t "${ingress_common[@]}" --set gatewayIngress.caHook.image=
# A server TLS Secret under the operator's own name is the one the CA is copied from.
try good-8-pki-names '' t "${ingress_common[@]}" --set gateway.sandboxJwt.serverTlsSecretName=own-server-tls
```

In `scripts/check-chart-render.sh`, replace

```python
INGRESS_KINDS = ("VirtualService", "RequestAuthentication", "AuthorizationPolicy")
```

with

```python
INGRESS_KINDS = ("VirtualService", "DestinationRule", "RequestAuthentication", "AuthorizationPolicy")
```

In `scripts/check-chart-render.sh`, replace

```bash
            "hosts": [host], "gateways": ["kyma-system/kyma-gateway"], "http": route(service, 8080)},
    }
```

with

```bash
            "hosts": [host], "gateways": ["kyma-system/kyma-gateway"], "http": route(service, 8080)},
        # The ingress gateway re-encrypts to the gateway pod and verifies its certificate
        # against the chart CA and the Service name (upstream's backendTLSPolicy, for Istio).
        # exportTo keeps the rule from sandboxes with an Istio sidecar, which speak TLS themselves.
        ("DestinationRule", release_ns, f"{fullname}-gateway-tls"): {
            "host": service, "exportTo": ["istio-system"],
            "trafficPolicy": {"tls": {"mode": "SIMPLE", "credentialName": f"{prefix}-gateway-ca",
                                      "sni": service, "subjectAltNames": [service]}}},
    }
```

In `scripts/check-chart-render.sh`, replace

```bash
# The PKI hook mints the gateway's server certificate for the names clients verify it
```

with

```python
# The chart CA in the ingress gateway's namespace. Istio reads a DestinationRule's
# credentialName from a Secret next to the gateway workload, the CA under ca.crt. The
# chart renders that Secret without data, so Helm never overwrites what the Job writes:
# the PKI hook creates the CA, which does not exist when the chart is rendered. The Job
# sees only the CA certificate of the server TLS Secret, never its key, and may read and
# patch that one Secret in the ingress gateway's namespace, nothing else there.
CA_HOOK_IMAGE = (((yaml.safe_load(values) or {}).get("gatewayIngress") or {}).get("caHook") or {}).get("image") or ""
if not re.fullmatch(r"[^\s@]+@sha256:[0-9a-f]{64}", CA_HOOK_IMAGE):
    failures.append(f"gatewayIngress.caHook.image {CA_HOOK_IMAGE!r} is not pinned by digest")

def check_ca(name, release_ns, fullname, server_secret=None):
    documents = docs(work / f"{name}.yaml")
    prefix = f"{release_ns}-{fullname}"
    secret_name, hook = f"{prefix}-gateway-ca", f"{fullname}-gateway-ca-hook"

    def one(kind, namespace, obj_name):
        found = [d for d in documents
                 if (d.get("kind"), d["metadata"].get("namespace"), d["metadata"]["name"]) == (kind, namespace, obj_name)]
        if len(found) != 1:
            failures.append(f"{name}: {len(found)} {kind} {namespace}/{obj_name} rendered, want 1")
        return found[0] if found else None

    secret = one("Secret", "istio-system", secret_name)
    if secret and (secret.get("type") != "Opaque" or secret.get("data") or secret.get("stringData")
                   or "helm.sh/hook" in (secret["metadata"].get("annotations") or {})):
        failures.append(f"{name}: the CA Secret must be an Opaque Secret of the release without data "
                        f"(the Job writes ca.crt), not a hook: {secret}")
    role = one("Role", "istio-system", f"{prefix}-gateway-ca-hook")
    want_rules = [{"apiGroups": [""], "resources": ["secrets"], "resourceNames": [secret_name],
                   "verbs": ["get", "patch"]}]
    if role and role.get("rules") != want_rules:
        failures.append(f"{name}: the CA hook's Role grants {role.get('rules')}, want {want_rules}")
    binding = one("RoleBinding", "istio-system", f"{prefix}-gateway-ca-hook")
    if binding and (binding["roleRef"] != {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role",
                                           "name": f"{prefix}-gateway-ca-hook"}
                    or binding["subjects"] != [{"kind": "ServiceAccount", "name": hook, "namespace": release_ns}]):
        failures.append(f"{name}: the CA hook's RoleBinding is {binding['roleRef']} -> {binding['subjects']}")
    account = one("ServiceAccount", release_ns, hook)
    job = one("Job", release_ns, hook)
    for d in (account, role, binding, job):
        hooks = ((d or {}).get("metadata", {}).get("annotations") or {}).get("helm.sh/hook")
        if d and hooks != "post-install,post-upgrade":
            failures.append(f"{name}: {d['kind']} {d['metadata']['name']} has helm.sh/hook {hooks!r}, "
                            "want post-install,post-upgrade")
    if not job:
        return
    pod = job["spec"]["template"]["spec"]
    container = pod["containers"][0]
    env = {e["name"]: e.get("value") for e in container.get("env", [])}
    script = container["command"][-1]
    want_ca = {"name": "ca", "secret": {"secretName": server_secret or f"{fullname}-server-tls",
                                        "items": [{"key": "ca.crt", "path": "ca.crt"}]}}
    if [v for v in pod.get("volumes", []) if "secret" in v] != [want_ca]:
        failures.append(f"{name}: the CA hook mounts {pod.get('volumes')}; of Secrets it must see only ca.crt "
                        "of the server TLS Secret, never its key")
    if (pod.get("serviceAccountName") != hook or container.get("image") != CA_HOOK_IMAGE
            or (env.get("INGRESS_NAMESPACE"), env.get("CA_SECRET")) != ("istio-system", secret_name)
            or '-n "${INGRESS_NAMESPACE}" patch secret "${CA_SECRET}"' not in script or "/pki/ca.crt" not in script):
        failures.append(f"{name}: the CA hook Job does not patch {secret_name} in istio-system from /pki/ca.crt "
                        f"with the pinned image: env {env}, image {container.get('image')!r}")
    labels = job["spec"]["template"]["metadata"]["labels"]
    if labels.get("app.kubernetes.io/name") == "openshell-driver-kyma" or labels.get("sidecar.istio.io/inject") != "false":
        failures.append(f"{name}: the CA hook pod's labels are {labels}: with the driver pod's name label its "
                        "NetworkPolicy would select the hook, and sidecar injection must be off")
    pod_security, security = pod.get("securityContext") or {}, container.get("securityContext") or {}
    if (pod_security.get("runAsNonRoot") is not True or security.get("allowPrivilegeEscalation") is not False
            or security.get("readOnlyRootFilesystem") is not True
            or (security.get("capabilities") or {}).get("drop") != ["ALL"]):
        failures.append(f"{name}: the CA hook's security context is {pod_security} / {security}")

for name, (ns, fullname) in (("good-8-ingress", T), ("good-8-long-names", (
        "a-rather-long-release-namespace-name", "prod-sandboxes-openshell-driver-kyma"))):
    if succeeded(name):
        check_ca(name, ns, fullname)
if rendered("good-8-pki-names") is not None:
    check_ca("good-8-pki-names", *T, server_secret="own-server-tls")

# The PKI hook mints the gateway's server certificate for the names clients verify it
```

In `scripts/check-chart-render.sh`, replace

```bash
    stray = sorted("/".join(k) for k in ingress_objects(name))
    if stray:
```

with

```bash
    stray = sorted("/".join(k) for k in ingress_objects(name)) + sorted(
        f"{d['kind']}/istio-system/{d['metadata']['name']}" for d in docs(work / f"{name}.yaml")
        if d["metadata"].get("namespace") == "istio-system")
    if stray:
```

In `scripts/check-chart-render.sh`, replace

```bash
# - Every AuthorizationPolicy selects a workload, and every rule names hosts, none of them
#   by the domain's wildcard.
```

with

```bash
# - Every AuthorizationPolicy selects a workload, and every rule names hosts, none of them
#   by the domain's wildcard.
# - Its namespace gets nothing else but the chart CA's Secret and the Role and RoleBinding
#   that let one Job write it (check_ca above holds them to that one Secret).
```

In `scripts/check-chart-render.sh`, replace

```python
        if d.get("kind") == "RequestAuthentication":
            failures.append(f"{where}: a RequestAuthentication applies to every host of the workload it selects")
```

with

```python
        if d.get("kind") == "RequestAuthentication":
            failures.append(f"{where}: a RequestAuthentication applies to every host of the workload it selects")
        if d["metadata"].get("namespace") == "istio-system" and d.get("kind") != "AuthorizationPolicy":
            suffix = {"Secret": "-gateway-ca", "Role": "-gateway-ca-hook", "RoleBinding": "-gateway-ca-hook"}
            if not d["metadata"]["name"].endswith(suffix.get(d.get("kind"), "/")):
                failures.append(f"{where}: rendered into the ingress gateway's namespace, which gets only this "
                                "release's AuthorizationPolicies, its CA Secret and the CA hook's Role and RoleBinding")
```

- [ ] **Step 2: Run the checks and watch them fail**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -30`

Expected: `CHART_RENDER_FAIL:` with 23 failures, among them

```text
  - bad-8-no-ca-hook-image: rendered, but the driver or upstream would refuse it at startup
  - good-8-ingress: DestinationRule/default/t-openshell-driver-kyma-gateway-tls is None, want {'host': 't-openshell-driver-kyma.default.svc.cluster.local', 'exportTo': ['istio-system'], …}
  - gatewayIngress.caHook.image '' is not pinned by digest
  - good-8-ingress: 0 Secret istio-system/default-t-openshell-driver-kyma-gateway-ca rendered, want 1
  - good-8-pki-names: 0 Job default/t-openshell-driver-kyma-gateway-ca-hook rendered, want 1
```

- [ ] **Step 3: Add the DestinationRule, the CA Secret and its Job**

In `deploy/helm/openshell-driver-kyma/templates/_gateway-ingress.tpl`, replace

```yaml
{{- printf "%s-%s" .Release.Namespace (include "openshell-driver-kyma.fullname" .) -}}
{{- end -}}
```

with

```yaml
{{- printf "%s-%s" .Release.Namespace (include "openshell-driver-kyma.fullname" .) -}}
{{- end -}}

{{/*
The Secret in gatewayIngress.ingressNamespace that holds the chart CA's public
certificate. The ingress gateway verifies the gateway pod's certificate against it
(gateway-destinationrule.yaml); gateway-ingress-ca.yaml keeps it current.
*/}}
{{- define "openshell-driver-kyma.gatewayIngressCaSecretName" -}}
{{- printf "%s-gateway-ca" (include "openshell-driver-kyma.gatewayIngressPolicyPrefix" .) -}}
{{- end -}}
```

In `deploy/helm/openshell-driver-kyma/templates/_gateway-ingress.tpl`, replace

```yaml
{{- fail "gatewayIngress.enabled=true cannot be combined with gateway.tls.clientCa.enabled=true: the ingress gateway presents no client certificate to the gateway. Callers authenticate with OIDC." -}}
{{- end -}}
```

with

```yaml
{{- fail "gatewayIngress.enabled=true cannot be combined with gateway.tls.clientCa.enabled=true: the ingress gateway presents no client certificate to the gateway. Callers authenticate with OIDC." -}}
{{- end -}}
{{- if not $in.caHook.image -}}
{{- fail "gatewayIngress.enabled=true requires gatewayIngress.caHook.image: the image (a shell, base64 and kubectl) of the Job that copies the chart CA's public certificate into gatewayIngress.ingressNamespace." -}}
{{- end -}}
```

Write `deploy/helm/openshell-driver-kyma/templates/gateway-destinationrule.yaml` (the whole file):

```yaml
{{- if .Values.gatewayIngress.enabled -}}
{{- $service := printf "%s.%s.svc.cluster.local" (include "openshell-driver-kyma.fullname" .) .Release.Namespace -}}
# TLS from the cluster's ingress gateway to the gateway pod, which serves TLS itself
# (gateway.tls.enabled): the ingress gateway terminates the client's TLS, re-encrypts,
# and verifies the pod's certificate against the chart CA and the Service name. It is
# upstream's grpcRoute.backendTLSPolicy written for Istio.
#
# exportTo limits it to the ingress gateway's namespace. A sandbox with an Istio
# sidecar dials the same Service and speaks TLS itself; this rule must not reach it.
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: {{ include "openshell-driver-kyma.fullname" . }}-gateway-tls
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
spec:
  host: {{ $service }}
  exportTo:
    - {{ .Values.gatewayIngress.ingressNamespace | quote }}
  trafficPolicy:
    tls:
      mode: SIMPLE
      # A Secret in the ingress gateway's namespace with the CA under ca.crt
      # (gateway-ingress-ca.yaml).
      credentialName: {{ include "openshell-driver-kyma.gatewayIngressCaSecretName" . }}
      sni: {{ $service }}
      subjectAltNames:
        - {{ $service }}
{{- end }}
```

Write `deploy/helm/openshell-driver-kyma/templates/gateway-ingress-ca.yaml` (the whole file):

```yaml
{{- if .Values.gatewayIngress.enabled -}}
{{- $in := .Values.gatewayIngress -}}
{{- $caSecret := include "openshell-driver-kyma.gatewayIngressCaSecretName" . -}}
{{- $hookName := printf "%s-gateway-ca-hook" (include "openshell-driver-kyma.fullname" .) -}}
{{- $ingressHookName := printf "%s-gateway-ca-hook" (include "openshell-driver-kyma.gatewayIngressPolicyPrefix" .) -}}
# The chart CA's public certificate, in the ingress gateway's namespace, where Istio
# reads a DestinationRule's credentialName from (gateway-destinationrule.yaml).
#
# The chart renders the Secret without data and the Job below writes ca.crt into it
# after every install and upgrade: the CA is created by the PKI hook
# (gateway-jwt-pki-hook.yaml) and does not exist when the chart is rendered. Helm
# owns the Secret, so `helm uninstall` removes it, and leaves the Job's data alone
# on upgrades because the manifest names none. Until the Job has run on a first
# install the ingress gateway cannot verify the gateway and answers 503.
apiVersion: v1
kind: Secret
metadata:
  name: {{ $caSecret }}
  namespace: {{ $in.ingressNamespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
type: Opaque
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $hookName }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
  annotations:
    helm.sh/hook: post-install,post-upgrade
    helm.sh/hook-weight: "-7"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
---
# All the Job may do in the ingress gateway's namespace: read and patch that one Secret.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ $ingressHookName }}
  namespace: {{ $in.ingressNamespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
  annotations:
    helm.sh/hook: post-install,post-upgrade
    helm.sh/hook-weight: "-7"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: [{{ $caSecret | quote }}]
    verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $ingressHookName }}
  namespace: {{ $in.ingressNamespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
  annotations:
    helm.sh/hook: post-install,post-upgrade
    helm.sh/hook-weight: "-7"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ $ingressHookName }}
subjects:
  - kind: ServiceAccount
    name: {{ $hookName }}
    namespace: {{ .Release.Namespace }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $hookName }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "openshell-driver-kyma.labels" . | nindent 4 }}
  annotations:
    helm.sh/hook: post-install,post-upgrade
    helm.sh/hook-weight: "-6"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  backoffLimit: 3
  activeDeadlineSeconds: 120
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        # Not the chart's selectorLabels: the driver pod's NetworkPolicy would select
        # this pod too.
        app.kubernetes.io/name: openshell-driver-kyma-gateway-ca-hook
        app.kubernetes.io/instance: {{ .Release.Name }}
        sidecar.istio.io/inject: "false"
    spec:
      restartPolicy: OnFailure
      serviceAccountName: {{ $hookName }}
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: gateway-ca
          image: {{ $in.caHook.image | quote }}
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          env:
            - name: HOME
              value: /tmp
            - name: INGRESS_NAMESPACE
              value: {{ $in.ingressNamespace | quote }}
            - name: CA_SECRET
              value: {{ $caSecret | quote }}
          volumeMounts:
            - name: ca
              mountPath: /pki
              readOnly: true
            - name: tmp
              mountPath: /tmp
          command:
            - /bin/sh
            - -eu
            - -c
            - |
              ca=$(base64 -w0 /pki/ca.crt)
              if [ -z "${ca}" ]; then
                echo "[gateway-ca] the server TLS Secret has no ca.crt" >&2
                exit 1
              fi
              kubectl -n "${INGRESS_NAMESPACE}" patch secret "${CA_SECRET}" --type merge \
                -p "{\"data\":{\"ca.crt\":\"${ca}\"}}"
              echo "[gateway-ca] ${INGRESS_NAMESPACE}/${CA_SECRET} holds the chart CA"
      volumes:
        # Only the CA certificate of the server TLS Secret is mounted: the Job never
        # sees the gateway's private key and needs no access to Secrets here.
        - name: ca
          secret:
            secretName: {{ include "openshell-driver-kyma.serverTlsSecretName" . }}
            items:
              - key: ca.crt
                path: ca.crt
        - name: tmp
          emptyDir: {}
{{- end }}
```

In `deploy/helm/openshell-driver-kyma/values.yaml`, replace

```yaml
# fences by source address; it checks no token.
#
# Renders, in the release namespace, a VirtualService for `host`, and in
# `ingressNamespace` AuthorizationPolicies that name only this release's hosts.
# Nothing it renders applies to the ingress gateway as a whole. Installing with
# this block enabled needs rights in `ingressNamespace`.
```

with

```yaml
# fences by source address; it checks no token. Requires gateway.tls.enabled: the
# ingress gateway terminates the client's TLS and re-encrypts to the gateway pod,
# verifying its certificate against the chart CA.
#
# Renders, in the release namespace, a VirtualService for `host` and a
# DestinationRule (TLS to the gateway pod), and in `ingressNamespace` a Secret with
# the chart CA's public certificate and AuthorizationPolicies that name only this
# release's hosts. Nothing it renders applies to the ingress gateway as a whole.
# Installing with this block enabled needs rights in `ingressNamespace`.
```

In `deploy/helm/openshell-driver-kyma/values.yaml`, replace

```yaml
  serviceHosts:
    enabled: false
    workspaces: [default]
```

with

```yaml
  serviceHosts:
    enabled: false
    workspaces: [default]
  # The post-install Job that copies the chart CA's public certificate into
  # `ingressNamespace`, where the ingress gateway reads it. The image needs a
  # shell, base64 and kubectl; the Job may read and patch that one Secret only.
  caHook:
    image: docker.io/alpine/kubectl:1.35.3@sha256:c4a11ae9a1cbac1f203bfe7efa481ae9c33b1bfdf1f73bc84f62cb973f039e4b
```

- [ ] **Step 4: Run the checks and watch them pass**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -30`
Expected: last line `CHART_RENDER_OK`

Run: `KUBECONFIG=/dev/null helm lint deploy/helm/openshell-driver-kyma`
Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 5: Prove the Job's command in its image, without a cluster**

```bash
T="$HOME/.cache/ca-hook-test"; rm -rf "$T"; mkdir -p "$T/pki"
printf -- '-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n' > "$T/pki/ca.crt"
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: x-gateway-ca\n  namespace: istio-system\ntype: Opaque\n' > "$T/secret.yaml"
docker run --rm --user 65532:65532 --read-only --tmpfs /tmp -e HOME=/tmp -v "$T:/t:ro" --entrypoint /bin/sh \
  docker.io/alpine/kubectl:1.35.3@sha256:c4a11ae9a1cbac1f203bfe7efa481ae9c33b1bfdf1f73bc84f62cb973f039e4b -eu -c '
ca=$(base64 -w0 /t/pki/ca.crt)
kubectl patch --local -f /t/secret.yaml --type merge -p "{\"data\":{\"ca.crt\":\"${ca}\"}}" -o jsonpath="{.data.ca\.crt}" | base64 -d'
rm -rf "$T"
```

Expected: the three lines of the certificate file, unchanged. (The work directory is under `$HOME`: Docker Desktop on macOS does not share `/tmp`.)

- [ ] **Step 6: Commit**

```bash
git add deploy/helm/openshell-driver-kyma/templates/gateway-destinationrule.yaml \
  deploy/helm/openshell-driver-kyma/templates/gateway-ingress-ca.yaml \
  deploy/helm/openshell-driver-kyma/templates/_gateway-ingress.tpl \
  deploy/helm/openshell-driver-kyma/values.yaml \
  scripts/check-chart-render.sh
git diff --cached --stat
git commit -m "feat(chart): the ingress gateway re-encrypts to the gateway and verifies it against the chart CA" \
  -m "Co-Authored-By: <the committing model's name> <noreply@anthropic.com>"
```


### Task 4: The provider hook reaches a gateway that serves TLS

**Files:**
- Modify: `deploy/helm/openshell-driver-kyma/templates/inference-provider-hook.yaml`
- Modify: `deploy/helm/openshell-driver-kyma/templates/_inference-provider-guards.tpl`
- Test: `scripts/check-chart-render.sh`

**Interfaces:**
- Consumes: the client TLS Secret of the PKI hook (helper `openshell-driver-kyma.clientTlsSecretName`, key `ca.crt`); the check script's `hook_of`, `rendered`, `inference_try`.
- Produces: with `gateway.tls.enabled` and `gateway.oidc.issuer`, a hook Job whose `GATEWAY_URL` is `https://…`, with a volume `gateway-ca` (only `ca.crt`) at `/pki`, and a script that copies it to `${XDG_CONFIG_HOME:-${HOME}/.config}/openshell/gateways/in-cluster/mtls/ca.crt` after `openshell gateway add`. `inferenceProvider` with gateway TLS and without OIDC stays refused.

- [ ] **Step 1: Change the render checks**

In `scripts/check-chart-render.sh`, replace

```bash
# ...and the hook dials http:// with no client certificate, so it cannot reach a gateway
# with TLS: in three series, both together fail; TLS alone and the provider alone render.
inference_try bad-3h-inference-tls 'gateway.tls.enabled' --set "inferenceProvider.baseUrl=$inference_url" \
	--set gateway.tls.enabled=true
```

with

```bash
# ...and against a gateway with TLS the hook has a path only under OIDC, where it registers
# the gateway and trusts the chart CA. Without OIDC both together fail; TLS alone, the
# provider alone, and both with OIDC render.
inference_try bad-3h-inference-tls 'requires gateway.oidc.issuer' --set "inferenceProvider.baseUrl=$inference_url" \
	--set gateway.tls.enabled=true
inference_try good-8-inference-oidc-tls '' --set "inferenceProvider.baseUrl=$inference_url" \
	--set gateway.oidc.issuer=https://issuer.example --set gateway.oidc.audience=osh-client \
	--set gateway.oidc.clientId=osh-client --set gateway.oidc.clientCredentialsSecret.name=oidc-client \
	--set gateway.tls.enabled=true
```

In `scripts/check-chart-render.sh`, replace

```bash
# Without OIDC nothing changes: no registration, no OIDC environment.
```

with

```python
# Against a gateway that serves TLS the hook dials https:// and trusts the chart CA: it
# mounts only ca.crt of the client TLS Secret (it presents no client certificate) and puts
# it where upstream's CLI reads a registered gateway's CA, once `gateway add` has registered
# the gateway. The health port stays plain HTTP. Without TLS none of it is rendered.
CA_DIR = 'ca_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/openshell/gateways/in-cluster/mtls"'
CA_COPY = 'cp /pki/ca.crt "${ca_dir}/ca.crt"'
for name, tls in (("good-8-inference-oidc-tls", True), ("good-8-inference-oidc", False)):
    if rendered(name) is None:
        continue
    job = next(d for d in docs(work / f"{name}.yaml") if d.get("kind") == "Job"
               and d["metadata"]["name"].endswith("-inference-provider-hook"))
    pod = job["spec"]["template"]["spec"]
    env, script = hook_of(name)
    urls = {e["name"]: e.get("value") or "" for e in env}
    volume = [v for v in pod.get("volumes", []) if v.get("name") == "gateway-ca"]
    mount = [m for m in pod["containers"][0].get("volumeMounts", []) if m.get("name") == "gateway-ca"]
    if tls:
        ok = (urls.get("GATEWAY_URL", "").startswith("https://t-openshell-driver-kyma.")
              and volume == [{"name": "gateway-ca", "secret": {"secretName": "t-openshell-driver-kyma-client-tls",
                                                              "items": [{"key": "ca.crt", "path": "ca.crt"}]}}]
              and mount == [{"name": "gateway-ca", "mountPath": "/pki", "readOnly": True}]
              and CA_DIR in script and CA_COPY in script
              and script.index("openshell gateway add") < script.index(CA_COPY) < script.index("osh() {"))
    else:
        ok = (urls.get("GATEWAY_URL", "").startswith("http://t-openshell-driver-kyma.")
              and not volume and not mount and "/pki" not in script)
    if not ok or not urls.get("GATEWAY_HEALTH_URL", "").startswith("http://"):
        failures.append(f"{name}: with gateway TLS {'on' if tls else 'off'} the hook has GATEWAY_URL "
                        f"{urls.get('GATEWAY_URL')!r}, GATEWAY_HEALTH_URL {urls.get('GATEWAY_HEALTH_URL')!r}, "
                        f"CA volume {volume}, mount {mount}, CA copy in script: {CA_COPY in script}")
# Without OIDC nothing changes: no registration, no OIDC environment.
```

- [ ] **Step 2: Run the checks and watch them fail**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -30`

Expected: `CHART_RENDER_FAIL:` with these two failures

```text
  - bad-3h-inference-tls: failed the render without naming 'requires gateway.oidc.issuer': Error: … inferenceProvider.enabled=true cannot be combined with gateway.tls.enabled=true: …
  - good-8-inference-oidc-tls: expected the render to succeed, it failed: Error: … inferenceProvider.enabled=true cannot be combined with gateway.tls.enabled=true: …
```

- [ ] **Step 3: Dial https and trust the chart CA**

In `deploy/helm/openshell-driver-kyma/templates/inference-provider-hook.yaml`, replace

```yaml
# from gateway.oidc.clientCredentialsSecret and is never expanded in the script.
#
```

with

```yaml
# from gateway.oidc.clientCredentialsSecret and is never expanded in the script.
# When the gateway serves TLS (gateway.tls.enabled, which needs OIDC here), the
# hook dials https:// and trusts the chart CA, mounted from the client TLS Secret.
#
```

In `deploy/helm/openshell-driver-kyma/templates/inference-provider-hook.yaml`, replace

```yaml
              value: "http://{{ include "openshell-driver-kyma.fullname" . }}.{{ .Release.Namespace }}.svc.cluster.local:{{ .Values.gateway.grpcPort }}"
            - name: GATEWAY_HEALTH_URL
              # Gateway HTTP healthz lives on a different port from the gRPC
              # port. Requires `gw-health` to be in the chart's Service.
```

with

```yaml
              value: "{{ ternary "https" "http" .Values.gateway.tls.enabled }}://{{ include "openshell-driver-kyma.fullname" . }}.{{ .Release.Namespace }}.svc.cluster.local:{{ .Values.gateway.grpcPort }}"
            - name: GATEWAY_HEALTH_URL
              # Gateway HTTP healthz lives on a different port from the gRPC
              # port, in plain HTTP whatever gateway.tls.enabled says. Requires
              # `gw-health` to be in the chart's Service.
```

In `deploy/helm/openshell-driver-kyma/templates/inference-provider-hook.yaml`, replace

```yaml
            - name: profile
              mountPath: /profile
              readOnly: true
          command:
```

with

```yaml
            - name: profile
              mountPath: /profile
              readOnly: true
            {{- if .Values.gateway.tls.enabled }}
            - name: gateway-ca
              mountPath: /pki
              readOnly: true
            {{- end }}
          command:
```

In `deploy/helm/openshell-driver-kyma/templates/inference-provider-hook.yaml`, replace

```yaml
                --oidc-audience "${OIDC_AUDIENCE}"
              osh() { openshell --gateway in-cluster "$@"; }
```

with

```yaml
                --oidc-audience "${OIDC_AUDIENCE}"
              {{- if .Values.gateway.tls.enabled }}
              # The gateway's certificate is signed by the chart CA. The CLI reads a
              # registered gateway's CA from that gateway's directory (upstream
              # openshell-cli src/tls.rs, with_default_paths, at the pinned tag).
              ca_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/openshell/gateways/in-cluster/mtls"
              mkdir -p "${ca_dir}"
              cp /pki/ca.crt "${ca_dir}/ca.crt"
              {{- end }}
              osh() { openshell --gateway in-cluster "$@"; }
```

In `deploy/helm/openshell-driver-kyma/templates/inference-provider-hook.yaml`, replace

```yaml
        - name: profile
          configMap:
            name: {{ include "openshell-driver-kyma.fullname" . }}-inference-profile
```

with

```yaml
        - name: profile
          configMap:
            name: {{ include "openshell-driver-kyma.fullname" . }}-inference-profile
        {{- if .Values.gateway.tls.enabled }}
        # Only the CA certificate of the client TLS Secret: the hook presents no
        # client certificate.
        - name: gateway-ca
          secret:
            secretName: {{ include "openshell-driver-kyma.clientTlsSecretName" . }}
            items:
              - key: ca.crt
                path: ca.crt
        {{- end }}
```

In `deploy/helm/openshell-driver-kyma/templates/_inference-provider-guards.tpl`, replace

```yaml
{{- /* The hook dials the gateway at http:// (GATEWAY_URL and GATEWAY_HEALTH_URL in
inference-provider-hook.yaml, whatever gateway.tls.enabled says) and mounts no
client certificate, so against a gateway that terminates TLS every call fails
and so does the install. */ -}}
{{- if .Values.gateway.tls.enabled -}}
{{- fail "inferenceProvider.enabled=true cannot be combined with gateway.tls.enabled=true: the provider hook always dials the gateway over http:// and presents no client certificate, so it cannot reach a gateway that terminates TLS. Set inferenceProvider.enabled=false and register the profile and provider from a CLI session that trusts the gateway's CA (docs/production-deployment.md), or set gateway.tls.enabled=false." -}}
{{- end -}}
```

with

```yaml
{{- /* Against a gateway that serves TLS the hook dials https:// and trusts the
chart CA only on its OIDC path, where it registers the gateway and the CLI reads
that gateway's CA (inference-provider-hook.yaml). Without OIDC it has no such
path: every call would fail, and so would the install. */ -}}
{{- if and .Values.gateway.tls.enabled (not .Values.gateway.oidc.issuer) -}}
{{- fail "inferenceProvider.enabled=true with gateway.tls.enabled=true requires gateway.oidc.issuer: the provider hook reaches a gateway that serves TLS only as a registered OIDC gateway. Set gateway.oidc (the hook then logs in with the client-credentials grant and trusts the chart CA), or set inferenceProvider.enabled=false and register the profile and provider from a CLI session that trusts the gateway's CA (docs/production-deployment.md), or set gateway.tls.enabled=false." -}}
{{- end -}}
```

- [ ] **Step 4: Run the checks and watch them pass**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -30`
Expected: last line `CHART_RENDER_OK`

Run: `KUBECONFIG=/dev/null helm lint deploy/helm/openshell-driver-kyma`
Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 5: Commit**

```bash
git add deploy/helm/openshell-driver-kyma/templates/inference-provider-hook.yaml \
  deploy/helm/openshell-driver-kyma/templates/_inference-provider-guards.tpl \
  scripts/check-chart-render.sh
git diff --cached --stat
git commit -m "feat(chart): the provider hook dials a TLS gateway and trusts the chart CA" \
  -m "Co-Authored-By: <the committing model's name> <noreply@anthropic.com>"
```


### Task 5: The live check watches the ingress gateway's other applications

**Files:**
- Create: `scripts/remote-access-check-test.sh` (mode 755)
- Modify: `scripts/remote-access-check.sh` (rewritten)
- Modify: `.github/workflows/helm-lint.yml`
- Modify: `e2e/keycloak/deploy.sh`, `e2e/keycloak/README.md`, `e2e/keycloak/test.sh` (comments and the printed values)

**Interfaces:**
- Consumes: the chart of Tasks 1 to 4 (object names, `gateway.tls.enabled`, the PKI hook's `--…-secret-name` arguments).
- Produces: `scripts/remote-access-check.sh` with the new required variable `OSH_NEIGHBOUR_URLS`, the modes `OSH_PROBE_ONLY=1` (with `OSH_PROBE_BASELINE=<file>`) and `OSH_REGENERATE_PKI=1`, the tuning variables `OSH_PROBE_INTERVAL_SECONDS` (10) and `OSH_PROBE_RECHECK_SECONDS` (5), and without `OSH_OIDC_JWKS_URI`. It ends with `REMOTE_ACCESS_OK` or `REMOTE_ACCESS_FAIL`. `scripts/remote-access-check-test.sh` ends with `REMOTE_ACCESS_SELFTEST_OK`. Task 7 runs both.

- [ ] **Step 1: Write the test and add it to CI**

Write `scripts/remote-access-check-test.sh` (the whole file):

```bash
#!/usr/bin/env bash
# Tests for scripts/remote-access-check.sh that need no cluster: the neighbour probes,
# which watch the other applications behind a shared ingress gateway, and the rollback
# they trigger.
#   1. the probes report each neighbour's status without a token, with a foreign JWT and
#      with a Bearer key, and OSH_PROBE_BASELINE detects a change;
#   2. an install run refuses to start without OSH_NEIGHBOUR_URLS;
#   3. the dry run installs gateway TLS and no value of the removed edge token check;
#   4. when a neighbour starts refusing Bearer tokens during the upgrade (what a
#      RequestAuthentication on the ingress gateway does), the script rolls the release
#      back to the revision it found, reports the failure, and goes no further;
#   5. a release whose gateway certificate does not name its Service (every install from
#      before 0.10.0) is not upgraded unless OSH_REGENERATE_PKI=1 says to replace the PKI.
# The neighbour is a local web server; helm, kubectl and openshell are stand-ins for 4 and 5.
# Requires: helm, curl, python3.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/remote-access-check.sh"
WORK=$(mktemp -d)
server_pid=""
trap '[[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$WORK"' EXIT
die() {
	echo "REMOTE_ACCESS_SELFTEST_FAIL: $*"
	exit 1
}

# The neighbour: answers 200, and 401 to any request with an Authorization header while
# $WORK/broken exists.
cat >"$WORK/neighbour.py" <<'PY'
import http.server, os, sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        broken = os.path.exists(sys.argv[1]) and self.headers.get("Authorization")
        self.send_response(401 if broken else 200)
        self.end_headers()
    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
python3 "$WORK/neighbour.py" "$WORK/broken" >"$WORK/port" &
server_pid=$!
disown "$server_pid"
for _ in $(seq 1 50); do
	[[ -s $WORK/port ]] && break
	sleep 0.1
done
NEIGHBOUR="http://127.0.0.1:$(cat "$WORK/port")/app"

# 1. Probes and baseline comparison.
OSH_PROBE_ONLY=1 OSH_NEIGHBOUR_URLS="$NEIGHBOUR" "$SCRIPT" >"$WORK/baseline"
want="no-token 200 $NEIGHBOUR
foreign-jwt 200 $NEIGHBOUR
bearer-key 200 $NEIGHBOUR"
[[ $(cat "$WORK/baseline") == "$want" ]] || die "the probes of a healthy neighbour are: $(cat "$WORK/baseline")"
OSH_PROBE_ONLY=1 OSH_NEIGHBOUR_URLS="$NEIGHBOUR" OSH_PROBE_BASELINE="$WORK/baseline" "$SCRIPT" >/dev/null \
	|| die "an unchanged neighbour was reported as changed"
touch "$WORK/broken"
if OSH_PROBE_ONLY=1 OSH_NEIGHBOUR_URLS="$NEIGHBOUR" OSH_PROBE_BASELINE="$WORK/baseline" "$SCRIPT" >"$WORK/changed"; then
	die "a neighbour that refuses Bearer tokens was not reported"
fi
grep -q '^NEIGHBOUR_CHANGED$' "$WORK/changed" || die "no NEIGHBOUR_CHANGED line: $(cat "$WORK/changed")"
[[ $(grep -c '^> .* 401 ' "$WORK/changed") == 2 && $(grep -c '^> no-token' "$WORK/changed") == 0 ]] \
	|| die "expected exactly the two Bearer probes to change: $(cat "$WORK/changed")"
rm "$WORK/broken"

# 2 and 3. The values an install run needs, with documentation-only names.
printf 'gateway:\n  enabled: true\n  sandboxJwt:\n    enabled: true\ngatewayService:\n  enabled: true\n' >"$WORK/values.yaml"
run() { # [VAR=value...]: the script with the required variables of an install run
	env KUBECONFIG=/dev/null OSH_DOMAIN=example.org OSH_OIDC_ISSUER=https://issuer.example \
		OSH_OIDC_CLIENT_ID=osh-client OSH_ALLOWED_CIDRS=203.0.113.0/24 OSH_VALUES="$WORK/values.yaml" \
		OSH_AUTH_ONLY=1 "$@" "$SCRIPT"
}
if run >"$WORK/no-neighbours" 2>&1; then
	die "an install run started without OSH_NEIGHBOUR_URLS"
fi
grep -q OSH_NEIGHBOUR_URLS "$WORK/no-neighbours" || die "the refusal does not name OSH_NEIGHBOUR_URLS: $(cat "$WORK/no-neighbours")"
run OSH_DRY_RUN=1 >"$WORK/dry-run"
grep -qx 'gateway.tls.enabled=true' "$WORK/dry-run" || die "the dry run does not install gateway TLS: $(cat "$WORK/dry-run")"
if grep -qi 'jwks' "$WORK/dry-run"; then
	die "the dry run still sets a JWKS value: $(cat "$WORK/dry-run")"
fi

# 4. A neighbour breaks during the upgrade. The helm stand-in breaks it on `upgrade` and
# mends it on `rollback`; it answers `template` with the real helm, which needs no cluster.
REAL_HELM=$(command -v helm)
mkdir "$WORK/bin"
cat >"$WORK/bin/helm" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$WORK/helm.log"
case " \$* " in
*" template "*) exec "$REAL_HELM" "\$@" ;;
*" history "*) echo '[{"revision": 41}]' ;;
*" upgrade "*)
	touch "$WORK/broken"
	sleep 6
	;;
*" rollback "*) rm -f "$WORK/broken" ;;
esac
STUB
cat >"$WORK/bin/kubectl" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$WORK/kubectl.log"
case " \$* " in
*" get deploy "*) printf 'ods-openshell-driver-kyma' ;;
# STUB_OLD_PKI=1: the server TLS Secret exists, with a certificate that names nothing.
*" get secret "*) [[ \${STUB_OLD_PKI:-} == 1 ]] || exit 1 ;;
esac
STUB
cat >"$WORK/bin/openshell" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$WORK/openshell.log"
STUB
chmod +x "$WORK/bin/helm" "$WORK/bin/kubectl" "$WORK/bin/openshell"
if PATH="$WORK/bin:$PATH" run OSH_NEIGHBOUR_URLS="$NEIGHBOUR" OSH_PROBE_INTERVAL_SECONDS=1 \
	OSH_PROBE_RECHECK_SECONDS=1 >"$WORK/run" 2>&1; then
	die "the run passed although a neighbour broke during the upgrade: $(cat "$WORK/run")"
fi
grep -q '^REMOTE_ACCESS_FAIL$' "$WORK/run" || die "no REMOTE_ACCESS_FAIL: $(cat "$WORK/run")"
grep -q 'FAIL  another application behind the ingress gateway answers differently' "$WORK/run" \
	|| die "the failure does not name the neighbours: $(cat "$WORK/run")"
grep -q -- '-n openshell-system rollback ods 41 ' "$WORK/helm.log" \
	|| die "helm was not asked to roll back to revision 41: $(cat "$WORK/helm.log")"
grep -q 'PASS  the neighbours answer as before again' "$WORK/run" \
	|| die "the run does not confirm the neighbours recovered: $(cat "$WORK/run")"
[[ ! -e $WORK/openshell.log ]] || die "the run went on to the CLI checks after the rollback: $(cat "$WORK/openshell.log")"
[[ ! -e $WORK/broken ]] || die "the neighbour is still broken"

# 5. A certificate from before 0.10.0: no upgrade without OSH_REGENERATE_PKI=1, and with
# it the three PKI Secrets are deleted first.
rm -f "$WORK/helm.log" "$WORK/kubectl.log"
if PATH="$WORK/bin:$PATH" STUB_OLD_PKI=1 run OSH_NEIGHBOUR_URLS="$NEIGHBOUR" >"$WORK/old-pki" 2>&1; then
	die "a release with a certificate from before 0.10.0 was upgraded: $(cat "$WORK/old-pki")"
fi
grep -q 'OSH_REGENERATE_PKI=1' "$WORK/old-pki" || die "the refusal does not name OSH_REGENERATE_PKI: $(cat "$WORK/old-pki")"
if grep -q '^upgrade ' "$WORK/helm.log"; then
	die "helm upgrade ran against a certificate no client can verify: $(cat "$WORK/helm.log")"
fi
rm -f "$WORK/helm.log" "$WORK/kubectl.log"
PATH="$WORK/bin:$PATH" STUB_OLD_PKI=1 run OSH_NEIGHBOUR_URLS="$NEIGHBOUR" OSH_REGENERATE_PKI=1 \
	OSH_PROBE_INTERVAL_SECONDS=1 OSH_PROBE_RECHECK_SECONDS=1 >"$WORK/regenerate" 2>&1 || true
grep -q -- 'delete secret --ignore-not-found ods-openshell-driver-kyma-server-tls ods-openshell-driver-kyma-client-tls ods-openshell-driver-kyma-jwt-keys' \
	"$WORK/kubectl.log" || die "the three PKI Secrets were not deleted: $(cat "$WORK/kubectl.log")"
grep -q '^upgrade ' "$WORK/helm.log" || die "no upgrade after the PKI Secrets were deleted: $(cat "$WORK/helm.log")"
rm -f "$WORK/broken"

echo "REMOTE_ACCESS_SELFTEST_OK"
```

In `.github/workflows/helm-lint.yml`, replace

```yaml
      - 'scripts/check-chart-render.sh'
      - 'scripts/check-upstream-args.sh'
      - 'scripts/proto-lib.sh'
      - 'scripts/testdata/**'
      - 'crates/openshell-driver-kyma/src/kyma_args.rs'
      - 'Cargo.toml'
  push:
    branches: [main]
    paths:
      - 'deploy/helm/**'
      - 'scripts/check-chart-render.sh'
```

with

```yaml
      - 'scripts/check-chart-render.sh'
      - 'scripts/remote-access-check.sh'
      - 'scripts/remote-access-check-test.sh'
      - 'scripts/check-upstream-args.sh'
      - 'scripts/proto-lib.sh'
      - 'scripts/testdata/**'
      - 'crates/openshell-driver-kyma/src/kyma_args.rs'
      - 'Cargo.toml'
  push:
    branches: [main]
    paths:
      - 'deploy/helm/**'
      - 'scripts/check-chart-render.sh'
      - 'scripts/remote-access-check.sh'
      - 'scripts/remote-access-check-test.sh'
```

In `.github/workflows/helm-lint.yml`, replace

```yaml
      - name: Assert the driver's configuration surface
        shell: bash
        run: ./scripts/check-chart-render.sh
```

with

```yaml
      - name: Assert the driver's configuration surface
        shell: bash
        run: ./scripts/check-chart-render.sh

      - name: The live check watches the ingress gateway's other applications
        shell: bash
        run: ./scripts/remote-access-check-test.sh
```

```bash
chmod +x scripts/remote-access-check-test.sh
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `./scripts/remote-access-check-test.sh; echo "exit $?"`

Expected: the script of revision 1 has no probe mode and stops at its first required variable:

```text
…/scripts/remote-access-check.sh: line 37: OSH_DOMAIN: set OSH_DOMAIN to the cluster wildcard domain
exit 1
```

- [ ] **Step 3: Rewrite the live check; update the fixture's comments and printed values**

Write `scripts/remote-access-check.sh` (the whole file):

```bash
#!/usr/bin/env bash
# Live acceptance check for remote gateway access (the chart's gatewayIngress): upgrades
# a release on a real Kyma cluster and proves that the CLI and a sandbox service URL work
# through the cluster's ingress gateway, with OIDC, and that no other application behind
# that ingress gateway is affected.
#
# CI cannot run this: it needs Istio, the Kyma gateway and a real OIDC issuer. Run it
# from a laptop whose address is in OSH_ALLOWED_CIDRS. Every cluster-specific value
# comes from the environment and is never written to disk:
#
#   OSH_DOMAIN          the cluster's wildcard domain, without "*."
#   OSH_OIDC_ISSUER     the OIDC issuer URL
#   OSH_OIDC_CLIENT_ID  the OIDC client id the CLI logs in with
#   OSH_ALLOWED_CIDRS   comma-separated source CIDR blocks for the ingress policies
#   OSH_VALUES          the release's values file
#   OSH_NEIGHBOUR_URLS  comma-separated URLs of OTHER applications behind the same
#                       ingress gateway, one per application
#
# The neighbour probes are the safety net. The ingress gateway is shared: a change that
# applies to it as a whole breaks other applications' logins and API keys while this
# release's own hosts look fine (a RequestAuthentication did exactly that in a live run).
# Before the upgrade the script records each neighbour URL's HTTP status without a token,
# with a JWT of an issuer nobody here knows, and with a Bearer value that is no JWT. It
# repeats the probes while the upgrade runs and once more after it. If an answer changes
# and stays changed, it rolls the release back to the revision it found and stops.
# OSH_PROBE_ONLY=1 prints the probes and exits; with OSH_PROBE_BASELINE=<file> it exits 1
# when they differ from that file. It needs OSH_NEIGHBOUR_URLS only.
#
# Optional: OSH_RELEASE (ods), OSH_NAMESPACE (openshell-system), OSH_CLIENT_SECRET
# (openshell-oidc-client: a Secret in OSH_NAMESPACE whose key client-secret holds the
# OIDC client secret; needed when the values enable inferenceProvider),
# OSH_HOOK_CLIENT_ID (the confidential client that secret belongs to, when it is not
# OSH_OIDC_CLIENT_ID), OSH_OIDC_AUDIENCE (the tokens' audience; default the client id),
# OSH_EXTRA_VALUES (a second values file, applied after OSH_VALUES),
# OSH_AUTH_ONLY=1 (accept every authenticated identity instead of upstream's roles),
# OSH_POLICY_ACTION (ALLOW when the ingress gateway already has ALLOW policies; the
# chart's default, DENY, is for a gateway without any),
# OSH_REGENERATE_PKI=1 (delete the release's three PKI Secrets before the upgrade when
# the gateway's certificate does not name the release's Service, as on every install from
# before 0.10.0; existing sandboxes must be recreated afterwards),
# OSH_GATEWAY_NAME (kyma), OSH_SKIP_INSTALL=1 (check an install that is already
# there), OSH_CHECK_IDLE=1 (also hold an idle stream for 400 s), OSH_REVERT=1 (afterwards
# upgrade the release back to OSH_VALUES alone and check nothing of it is left in the
# ingress gateway's namespace),
# OSH_DRY_RUN=1 (render the chart with the values this script would install, print them
# and exit).
#
# e2e/keycloak/deploy.sh sets up a test identity provider and prints these values.
#
# `openshell gateway add` opens a browser for the OIDC login on first use.
# Requires: kubectl (with KUBECONFIG set), helm, curl, openssl, python3, openshell.
set -euo pipefail

http_code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@" || true; }

# A token no issuer of this cluster signed: three base64url parts, like any JWT.
FOREIGN_JWT=$(python3 -c '
import base64, json
part = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b"=").decode()
print(".".join((part({"alg": "RS256", "typ": "JWT", "kid": "neighbour-probe"}),
                part({"iss": "https://neighbour-probe.invalid", "sub": "probe", "aud": "probe", "exp": 4102444800}),
                "c2lnbmF0dXJl")))')

# probe_neighbours: one line "<probe> <HTTP status> <url>" per probe and neighbour URL.
probe_neighbours() {
	local url
	for url in ${OSH_NEIGHBOUR_URLS//,/ }; do
		printf 'no-token %s %s\n' "$(http_code "$url")" "$url"
		printf 'foreign-jwt %s %s\n' "$(http_code -H "authorization: Bearer $FOREIGN_JWT" "$url")" "$url"
		printf 'bearer-key %s %s\n' "$(http_code -H 'authorization: Bearer sk-neighbour-probe' "$url")" "$url"
	done
}
# neighbours_differ BASELINE: true when two probe rounds in a row differ from BASELINE
# (one round alone may be a neighbour's own hiccup). The last round is left in $probes.
probes=""
neighbours_differ() {
	probes=$(probe_neighbours)
	[[ $probes != "$1" ]] || return 1
	sleep "${OSH_PROBE_RECHECK_SECONDS:-5}"
	probes=$(probe_neighbours)
	[[ $probes != "$1" ]]
}
# probe_changes BASELINE CURRENT: the probe lines that differ ("<" before, ">" now).
probe_changes() { diff <(printf '%s\n' "$1") <(printf '%s\n' "$2") | grep '^[<>]' || true; }

if [[ ${OSH_PROBE_ONLY:-} == 1 ]]; then
	: "${OSH_NEIGHBOUR_URLS:?set OSH_NEIGHBOUR_URLS (comma-separated URLs of other applications behind the ingress gateway)}"
	probes=$(probe_neighbours)
	printf '%s\n' "$probes"
	if [[ -n ${OSH_PROBE_BASELINE:-} ]] && [[ $probes != "$(cat "$OSH_PROBE_BASELINE")" ]]; then
		printf '\nNEIGHBOUR_CHANGED\n'
		probe_changes "$(cat "$OSH_PROBE_BASELINE")" "$probes"
		exit 1
	fi
	exit 0
fi

: "${OSH_DOMAIN:?set OSH_DOMAIN to the cluster wildcard domain}"
: "${OSH_OIDC_ISSUER:?set OSH_OIDC_ISSUER}"
: "${OSH_OIDC_CLIENT_ID:?set OSH_OIDC_CLIENT_ID}"
: "${OSH_ALLOWED_CIDRS:?set OSH_ALLOWED_CIDRS (comma-separated)}"
: "${OSH_VALUES:?set OSH_VALUES to the release values file}"
if [[ ${OSH_DRY_RUN:-} != 1 && ${OSH_SKIP_INSTALL:-} != 1 ]]; then
	: "${OSH_NEIGHBOUR_URLS:?set OSH_NEIGHBOUR_URLS (comma-separated URLs of other applications behind the ingress gateway): this script does not change a shared ingress gateway without watching its other applications}"
fi
RELEASE=${OSH_RELEASE:-ods}
NS=${OSH_NAMESPACE:-openshell-system}
SECRET=${OSH_CLIENT_SECRET:-openshell-oidc-client}
GW=${OSH_GATEWAY_NAME:-kyma}
HOST="openshell.${OSH_DOMAIN}"
SANDBOX=rac-web
ROOT=$(git rev-parse --show-toplevel)
CHART="$ROOT/deploy/helm/openshell-driver-kyma"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

results=()
failed=0
pass() { results+=("PASS  $1"); }
fail() { results+=("FAIL  $1"); failed=1; }
check() { # description command...
	local what=$1
	shift
	if "$@"; then pass "$what"; else fail "$what"; fi
}
log() { printf '\n=== %s\n' "$*"; }
mask() { sed "s/${OSH_DOMAIN//./\\.}/<domain>/g"; }
osh() { openshell --gateway "$GW" "$@"; }

cidrs_json=$(python3 -c 'import json,sys; print(json.dumps([c.strip() for c in sys.argv[1].split(",") if c.strip()]))' \
	"$OSH_ALLOWED_CIDRS")

AUDIENCE=${OSH_OIDC_AUDIENCE:-$OSH_OIDC_CLIENT_ID}
helm_args=(--set gatewayIngress.enabled=true
	--set "gatewayIngress.domain=$OSH_DOMAIN"
	--set gatewayIngress.serviceHosts.enabled=true
	--set-json "gatewayIngress.allowedCidrs=$cidrs_json"
	--set gateway.tls.enabled=true
	--set "gateway.oidc.issuer=$OSH_OIDC_ISSUER"
	--set "gateway.oidc.audience=$AUDIENCE"
	--set "gateway.oidc.clientId=$OSH_OIDC_CLIENT_ID"
	--set "gateway.oidc.clientCredentialsSecret.name=$SECRET")
if [[ -n ${OSH_HOOK_CLIENT_ID:-} ]]; then
	helm_args+=(--set "gateway.oidc.clientCredentialsSecret.clientId=$OSH_HOOK_CLIENT_ID")
fi
if [[ ${OSH_AUTH_ONLY:-} == 1 ]]; then
	helm_args+=(--set gateway.oidc.authOnly=true)
fi
if [[ -n ${OSH_POLICY_ACTION:-} ]]; then
	helm_args+=(--set "gatewayIngress.policyAction=$OSH_POLICY_ACTION")
fi
values_args=(-f "$OSH_VALUES")
extra_values=()
if [[ -n ${OSH_EXTRA_VALUES:-} ]]; then
	extra_values=(-f "$OSH_EXTRA_VALUES")
fi
render() { # [helm template args...]: the chart with the values this script installs
	helm template "$RELEASE" "$CHART" -n "$NS" "${values_args[@]}" ${extra_values[@]+"${extra_values[@]}"} \
		"${helm_args[@]}" "$@"
}
if [[ ${OSH_DRY_RUN:-} == 1 ]]; then
	render >/dev/null
	printf '%s\n' ${extra_values[@]+"${extra_values[@]}"} "${helm_args[@]}"
	exit 0
fi

# finish: print the results and exit with the verdict.
finish() {
	printf '\n'
	printf '%s\n' "${results[@]}" | mask
	if [[ $failed == 1 ]]; then
		printf '\nREMOTE_ACCESS_FAIL\n'
		exit 1
	fi
	printf '\nREMOTE_ACCESS_OK\n'
	exit 0
}

# The provider the chart's hook registers with these values; empty when the values do
# not enable inferenceProvider (the hook template then renders nothing).
provider=$(render --show-only templates/inference-provider-hook.yaml 2>/dev/null \
	| awk '/- name: PROVIDER_NAME/ { getline; gsub(/^[[:space:]]*value:[[:space:]]*"?|"?[[:space:]]*$/, ""); print; exit }' || true)

log "release"
fullname=$(kubectl -n "$NS" get deploy -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=openshell-driver-kyma" \
	-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z $fullname ]]; then
	fail "release $RELEASE has no Deployment in $NS: this script upgrades an existing release"
	finish
fi
service="$fullname.$NS.svc.cluster.local"
ca_secret="$NS-$fullname-gateway-ca"
# The PKI Secrets, by the names the chart's PKI hook gives them with these values.
pki_hook=$(render --show-only templates/gateway-jwt-pki-hook.yaml)
secret_of() { sed -n "s/^ *- --$1-secret-name=//p" <<<"$pki_hook" | head -1; }
server_secret=$(secret_of server)
client_secret=$(secret_of client)
jwt_secret=$(secret_of jwt)
# The subject alternative names of the gateway's server certificate, or nothing.
server_sans() {
	kubectl -n "$NS" get secret "$server_secret" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
		| base64 --decode 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null || true
}

if [[ ${OSH_SKIP_INSTALL:-} != 1 ]]; then
	log "PKI"
	if kubectl -n "$NS" get secret "$server_secret" -o name >/dev/null 2>&1 \
		&& ! grep -q "DNS:$service" <<<"$(server_sans)"; then
		if [[ ${OSH_REGENERATE_PKI:-} == 1 ]]; then
			check "PKI Secrets deleted; the upgrade creates them again, for the release's Service names" \
				kubectl -n "$NS" delete secret --ignore-not-found "$server_secret" "$client_secret" "$jwt_secret"
		else
			fail "the gateway's certificate is from before 0.10.0 and does not name $service, so no client could verify it. Re-run with OSH_REGENERATE_PKI=1: it deletes $server_secret, $client_secret and $jwt_secret, and existing sandboxes must be recreated"
			finish
		fi
	else
		pass "the gateway's certificate names the release's Service, or the upgrade creates it"
	fi

	revision=$(helm -n "$NS" history "$RELEASE" --max 1 -o json \
		| python3 -c 'import json, sys; print(json.load(sys.stdin)[-1]["revision"])')
	log "neighbours before the upgrade"
	baseline=$(probe_neighbours)
	printf '%s\n' "$baseline" | mask

	log "upgrading $RELEASE with gatewayIngress (revision $revision is the way back)"
	helm upgrade "$RELEASE" "$CHART" -n "$NS" "${values_args[@]}" ${extra_values[@]+"${extra_values[@]}"} \
		"${helm_args[@]}" --wait --timeout 10m >/dev/null 2>"$WORK/helm.err" &
	helm_pid=$!
	helm_rc=0
	broken=0
	while kill -0 "$helm_pid" 2>/dev/null; do
		sleep "${OSH_PROBE_INTERVAL_SECONDS:-10}"
		if neighbours_differ "$baseline"; then
			broken=1
			break
		fi
	done
	if [[ $broken == 0 ]]; then
		wait "$helm_pid" || helm_rc=$?
		if neighbours_differ "$baseline"; then broken=1; fi
	fi
	if [[ $broken == 1 ]]; then
		kill "$helm_pid" 2>/dev/null || true
		wait "$helm_pid" 2>/dev/null || true
		fail "another application behind the ingress gateway answers differently since the upgrade began: $(probe_changes "$baseline" "$probes" | tr '\n' ' ')"
		log "rolling $RELEASE back to revision $revision"
		check "helm rollback to revision $revision" helm -n "$NS" rollback "$RELEASE" "$revision" --wait --timeout 10m
		if neighbours_differ "$baseline"; then
			fail "the neighbours still answer differently after the rollback: $(probe_changes "$baseline" "$probes" | tr '\n' ' ')"
		else
			pass "the neighbours answer as before again"
		fi
		finish
	fi
	pass "$(wc -l <<<"$baseline" | tr -d ' ') neighbour probes unchanged by the upgrade"
	if [[ $helm_rc == 0 ]]; then
		pass "helm upgrade with gatewayIngress${provider:+ (the provider hook ran)}"
	else
		# Nothing below can pass against a release that did not install.
		fail "helm upgrade with gatewayIngress (kubectl -n $NS get pods,jobs); the release may be half-applied: $(head -3 "$WORK/helm.err" | tr '\n' ' ')"
		finish
	fi
fi

log "rendered objects"
check "VirtualService $fullname-gateway" kubectl -n "$NS" get virtualservice "$fullname-gateway" -o name
check "VirtualService $fullname-sandbox-services" kubectl -n "$NS" get virtualservice "$fullname-sandbox-services" -o name
check "DestinationRule $fullname-gateway-tls" kubectl -n "$NS" get destinationrule "$fullname-gateway-tls" -o name
for suffix in cli services; do
	check "authorizationpolicy $NS-$fullname-openshell-$suffix in istio-system" \
		kubectl -n istio-system get authorizationpolicy "$NS-$fullname-openshell-$suffix" -o name
done
left=$(kubectl -n istio-system get requestauthentication -o name 2>/dev/null | grep -c -- "$NS-$fullname-" || true)
check "no RequestAuthentication of this release on the ingress gateway (found $left)" test "$left" = 0
args=$(kubectl -n "$NS" get deploy "$fullname" -o jsonpath='{.spec.template.spec.containers[?(@.name=="gateway")].args}')
check "the gateway serves TLS (--tls-cert, no --disable-tls)" \
	test "$(grep -c -- '--tls-cert' <<<"$args")$(grep -c -- '--disable-tls' <<<"$args")" = 10
check "the gateway's certificate names $service" grep -q "DNS:$service" <<<"$(server_sans)"
chart_ca=$(kubectl -n "$NS" get secret "$server_secret" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)
ingress_ca=$(kubectl -n istio-system get secret "$ca_secret" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)
check "istio-system/$ca_secret holds the chart CA" test -n "$chart_ca" -a "$chart_ca" = "$ingress_ca"

log "the gateway refuses a call without a token"
# The ingress gateway checks no token. The gateway answers in gRPC's own terms: HTTP 200
# with grpc-status 16 (unauthenticated). A 503 here means the ingress gateway cannot reach
# or verify the gateway pod: see the DestinationRule and the CA Secret above.
grpc=$(curl -s -m 20 -o /dev/null -D - -X POST -H 'content-type: application/grpc' \
	"https://$HOST/openshell.v1.OpenShell/ListSandboxes" | tr -d '\r' \
	| awk -F': ' 'tolower($1) == "grpc-status" { print $2 }' || true)
check "a gRPC call without a bearer is refused by the gateway (grpc-status ${grpc:-none}, want 16)" test "$grpc" = 16

log "CLI through the ingress (a browser opens for the OIDC login)"
openshell gateway add "https://$HOST" --name "$GW" --oidc-issuer "$OSH_OIDC_ISSUER" \
	--oidc-client-id "$OSH_OIDC_CLIENT_ID" --oidc-audience "$AUDIENCE" || true
check "openshell status through https://openshell.<domain>" osh status
osh sandbox delete "$SANDBOX" >/dev/null 2>&1 || true
check "sandbox create" osh sandbox create --detach --name "$SANDBOX" --from python:3.12-slim \
	-- python3 -m http.server 8080 --bind 127.0.0.1
ready=""
for _ in $(seq 1 36); do
	ready=$(osh sandbox list 2>/dev/null | awk -v n="$SANDBOX" '$1 == n { print $NF }')
	[[ $ready == Ready ]] && break
	sleep 5
done
check "sandbox reaches Ready (phase: ${ready:-none})" test "$ready" = Ready
# The marker is computed in the sandbox, so an error that echoes the command cannot match.
# shellcheck disable=SC2016 # the sandbox's shell expands it
out=$(osh sandbox exec --name "$SANDBOX" -- sh -c 'echo exec-$((6 * 7))' 2>&1 || true)
check "sandbox exec through the ingress" grep -q exec-42 <<<"$out"

log "sandbox service URL"
url=$(osh service expose "$SANDBOX" 8080 2>&1 | grep -oE 'https?://[^ ]+' | head -1 || true)
# The gateway serves TLS, so it reports an https URL, and upstream's CLI replaces its port
# with the gateway endpoint's: the printed URL is the one that works.
check "service expose prints https://default--$SANDBOX.<domain>/ (printed: $url)" \
	test "$url" = "https://default--$SANDBOX.$OSH_DOMAIN/"
body=$(curl -s -m 20 "https://default--$SANDBOX.$OSH_DOMAIN/" || true)
check "https://default--$SANDBOX.<domain>/ serves the sandbox's directory listing" \
	grep -q "Directory listing for /" <<<"$body"
code=$(http_code "https://default--no-such-sandbox.$OSH_DOMAIN/")
check "an unknown sandbox host is answered by the gateway, not by a sandbox (HTTP $code, want 404 or 503)" \
	test "$code" = 404 -o "$code" = 503
code=$(http_code "https://unpublished--$SANDBOX.$OSH_DOMAIN/")
check "a workspace that is not published is not served (HTTP $code, want 403 or 404)" \
	test "$code" = 403 -o "$code" = 404

if [[ -n $provider ]]; then
	log "provider registered by the hook (client credentials, over TLS)"
	out=$(osh provider list 2>&1 || true)
	check "provider $provider is registered: the hook's login worked and it trusted the chart CA" \
		grep -qw -- "$provider" <<<"$out"
fi

if [[ ${OSH_CHECK_IDLE:-} == 1 ]]; then
	log "idle stream for 400 s (Envoy's stream idle timeout is 300 s)"
	# shellcheck disable=SC2016 # the sandbox's shell expands it
	out=$(osh sandbox exec --name "$SANDBOX" -- sh -c 'sleep 400; echo idle-$((6 * 7))' 2>&1 || true)
	check "an exec stream idle for 400 s survives" grep -q idle-42 <<<"$out"
fi

log "cleanup"
osh service delete "$SANDBOX" >/dev/null 2>&1 || true
check "sandbox delete" osh sandbox delete "$SANDBOX"

if [[ ${OSH_REVERT:-} == 1 ]]; then
	log "reverting $RELEASE to $OSH_VALUES alone"
	if helm upgrade "$RELEASE" "$CHART" -n "$NS" -f "$OSH_VALUES" --wait --timeout 10m >/dev/null; then
		pass "helm upgrade back to the values file"
	else
		fail "helm upgrade back to the values file (kubectl -n $NS get pods)"
	fi
	left=$(kubectl -n istio-system get authorizationpolicy,requestauthentication,secret,role,rolebinding -o name 2>/dev/null \
		| grep -c -- "/$NS-$fullname-" || true)
	check "nothing of this release is left in istio-system (found $left)" test "$left" = 0
fi

if [[ -n ${OSH_NEIGHBOUR_URLS:-} && -n ${baseline:-} ]]; then
	log "neighbours at the end"
	if neighbours_differ "$baseline"; then
		fail "another application behind the ingress gateway answers differently than before the run: $(probe_changes "$baseline" "$probes" | tr '\n' ' ')"
	else
		pass "the neighbours answer as before the run"
	fi
fi

finish
```

In `e2e/keycloak/deploy.sh`, replace

```bash
# Only the Istio ingress gateway and istiod (which fetches the JWKS for the ingress
# gateway's RequestAuthentication) reach Keycloak.
```

with

```bash
# Only the Istio ingress gateway's namespace reaches Keycloak: every caller, the OpenShell
# gateway included, comes through the public host.
```

In `e2e/keycloak/deploy.sh`, replace

```bash
  OSH_HOOK_CLIENT_ID=openshell-ci
  OSH_OIDC_JWKS_URI=http://keycloak.${NS}.svc.cluster.local:8080/realms/openshell/protocol/openid-connect/certs
  OSH_CLIENT_SECRET=openshell-oidc-client
  OSH_POLICY_ACTION=${ACTION}
  OSH_EXTRA_VALUES=e2e/keycloak/values.yaml   (lets the gateway pod reach this issuer)
```

with

```bash
  OSH_HOOK_CLIENT_ID=openshell-ci
  OSH_CLIENT_SECRET=openshell-oidc-client
  OSH_POLICY_ACTION=${ACTION}
  OSH_EXTRA_VALUES=e2e/keycloak/values.yaml   (lets the gateway pod reach this issuer)
  OSH_NEIGHBOUR_URLS=...                      (yours to choose: other applications behind this ingress gateway)
```

In `e2e/keycloak/README.md`, replace

```markdown
pod and node networks (the OpenShell gateway and the provider hook reach the
issuer through that public host; the ingress gateway's JWKS fetch uses the
in-cluster Service). Credentials are generated into Secrets in the cluster and
```

with

```markdown
pod and node networks (the OpenShell gateway and the provider hook reach the
issuer through that public host). Credentials are generated into Secrets in the cluster and
```

In `e2e/keycloak/test.sh`, replace

```bash
#   3. the realm imports into a throwaway Keycloak (Docker) and issues tokens the
#      OpenShell gateway and the ingress gateway accept: issuer, audience, roles, for
```

with

```bash
#   3. the realm imports into a throwaway Keycloak (Docker) and issues tokens the
#      OpenShell gateway accepts: issuer, audience, roles, for
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `./scripts/remote-access-check-test.sh`
Expected: `REMOTE_ACCESS_SELFTEST_OK` (a few seconds)

Run: `shellcheck scripts/remote-access-check.sh scripts/remote-access-check-test.sh e2e/keycloak/deploy.sh e2e/keycloak/test.sh && echo clean`
Expected: `clean`

Run: `OSH_RENDER_ONLY=1 OSH_DOMAIN=example.org OSH_ALLOWED_CIDRS=203.0.113.0/24 OSH_CLUSTER_CIDRS=10.96.0.0/13 e2e/keycloak/deploy.sh | grep -c -i -E "jwks|RequestAuthentication"`
Expected: `0`

- [ ] **Step 5: Prove the test can fail**

```bash
cp scripts/remote-access-check.sh "$HOME/.cache/rac.keep"
sed -i.bak 's/neighbours_differ "\$baseline"/false/g' scripts/remote-access-check.sh
./scripts/remote-access-check-test.sh | head -1
cp "$HOME/.cache/rac.keep" scripts/remote-access-check.sh
rm -f scripts/remote-access-check.sh.bak "$HOME/.cache/rac.keep"
./scripts/remote-access-check-test.sh | tail -1
```

Expected: first `REMOTE_ACCESS_SELFTEST_FAIL: the failure does not name the neighbours: …` (a script that never compares the neighbours is caught), then `REMOTE_ACCESS_SELFTEST_OK` with the script restored. `git status --short scripts/remote-access-check.sh` shows it modified once, as Step 3 left it.

- [ ] **Step 6: Commit**

```bash
git add scripts/remote-access-check.sh \
  scripts/remote-access-check-test.sh \
  .github/workflows/helm-lint.yml \
  e2e/keycloak/deploy.sh \
  e2e/keycloak/README.md \
  e2e/keycloak/test.sh
git diff --cached --stat
git commit -m "test: the live check watches the ingress gateway's other applications and rolls back" \
  -m "Co-Authored-By: <the committing model's name> <noreply@anthropic.com>"
```


### Task 6: Documentation, install notes and changelog

**Files:**
- Modify: `deploy/helm/openshell-driver-kyma/templates/NOTES.txt`, `deploy/helm/openshell-driver-kyma/values.example.yaml`
- Modify: `docs/production-deployment.md`, `docs/getting-started.md`, `docs/openshell-api-programmatic-usage.md`, `docs/kyma-vs-openshift.md`, `docs/tutorial-anthropic-direct.md`
- Modify: `CHANGELOG.md` (the 0.10.0 entry)
- Modify: `docs/superpowers/plans/2026-09-30-remote-gateway-access.md` (one line: superseded)

**Interfaces:**
- Consumes: the behaviour of Tasks 1 to 5.
- Produces: no statement left that the ingress gateway validates tokens, that the gateway binds port 80, or that the CLI prints `http://<host>:443/`. Reader-facing documents do not link maintainer scripts.

- [ ] **Step 1: Apply the edits**

In `deploy/helm/openshell-driver-kyma/templates/NOTES.txt`, replace

```text
The gateway is published at https://{{ include "openshell-driver-kyma.gatewayIngressHost" . }}
behind OIDC. Register it once with the openshell CLI (a browser opens for login):
```

with

```text
The gateway is published at https://{{ include "openshell-driver-kyma.gatewayIngressHost" . }}
and authenticates every call with OIDC. Register it once with the openshell CLI
(a browser opens for login):
```

In `deploy/helm/openshell-driver-kyma/templates/NOTES.txt`, replace

```text
https://<workspace>--<sandbox>.{{ .Values.gatewayIngress.domain }}/ (the CLI prints it as
http://<host>:443/: use the host with https://),
reachable from gatewayIngress.allowedCidrs, for the workspaces
```

with

```text
https://<workspace>--<sandbox>.{{ .Values.gatewayIngress.domain }}/,
reachable from gatewayIngress.allowedCidrs, for the workspaces
```

In `deploy/helm/openshell-driver-kyma/values.example.yaml`, replace

```yaml
# Publishes the gateway through the cluster's Istio ingress gateway. Refused
# unless gateway.oidc.{issuer,audience,clientId} are set (the chart never
# publishes an unauthenticated gateway). See docs/production-deployment.md.
gatewayIngress:
```

with

```yaml
# Publishes the gateway through the cluster's Istio ingress gateway. Refused
# unless gateway.oidc.{issuer,audience,clientId} are set (the chart never
# publishes an unauthenticated gateway) and gateway.tls.enabled is true (the
# gateway serves TLS; the ingress gateway re-encrypts to it). An install from
# before 0.10.0 regenerates its PKI first. See docs/production-deployment.md.
gatewayIngress:
```

In `docs/production-deployment.md`, replace

```markdown
| Remote access (`gatewayIngress`) + OIDC | OIDC at the edge and at the gateway + sandbox-JWT | Standard OIDC login, no port-forward, MFA from your IdP | Public attack surface; needs rights in `istio-system` |
```

with

```markdown
| Remote access (`gatewayIngress`) + OIDC | OIDC at the gateway + sandbox-JWT; optional source-address fence at the ingress gateway | Standard OIDC login, no port-forward, MFA from your IdP | Public attack surface; needs rights in `istio-system` |
```

In `docs/production-deployment.md`, replace

```markdown
Any OIDC provider that issues **JWT access tokens** works: the `openshell` CLI
sends the access token, and both the ingress gateway and the OpenShell gateway
validate its signature, issuer and audience. You need:
```

with

```markdown
Any OIDC provider that issues **JWT access tokens** works: the `openshell` CLI
sends the access token, and the OpenShell gateway validates its signature,
issuer and audience. The ingress gateway checks no token. You need:
```

In `docs/production-deployment.md`, replace

```markdown
- **The issuer URL** → `gateway.oidc.issuer`, over HTTPS. Keep it reachable
  from the cluster (the gateway and the ingress gateway fetch its JWKS) and
  from your users' laptops (the CLI redirects to it on first auth).
```

with

```markdown
- **The issuer URL** → `gateway.oidc.issuer`, over HTTPS. Keep it reachable
  from the cluster (the gateway fetches its JWKS) and from your users' laptops
  (the CLI redirects to it on first auth).
```

In `docs/production-deployment.md`, replace

```markdown
- or set `gateway.oidc.authOnly: true` to accept every identity the issuer
  authenticates. Every such identity is then a platform admin of the gateway,
  across all workspaces: who may log in is decided in the provider alone.
```

with

````markdown
- or set `gateway.oidc.authOnly: true` to accept every identity the issuer
  authenticates. Every such identity is then a platform admin of the gateway,
  across all workspaces: who may log in is decided in the provider alone.

### SAP Cloud Identity Services (IAS)

IAS is an ordinary OIDC provider to this chart: an OpenID Connect application
in your tenant, its client id as `clientId` and `audience`, and the tenant as
issuer.

```yaml
gateway:
  oidc:
    issuer: "https://<tenant>.accounts.ondemand.com"
    audience: "<client id of the application>"
    clientId: "<client id of the application>"
    rolesClaim: groups            # with adminRole and userRole; or authOnly: true
    adminRole: "<group of platform admins>"
    userRole: "<group of users>"
```

**This recipe has not been verified against an IAS tenant.** Check three things
on yours before you rely on it:

1. The application issues access tokens as JWTs, and their `aud` claim contains
   the client id. The gateway cannot validate an opaque access token.
2. The application is a public client with PKCE and accepts the redirect URI
   `http://127.0.0.1:<any port>/callback`. If it does not, log in with the
   device grant (`OPENSHELL_NO_BROWSER=1 openshell gateway add …`).
3. Group membership reaches the access token in the claim you name in
   `rolesClaim`. If it does not, use `authOnly: true` and decide in IAS who may
   log in to the application.
````

In `docs/production-deployment.md`, replace

```markdown
  # OIDC is required for remote access: the chart refuses to publish an
  # unauthenticated gateway.
  oidc:
```

with

```markdown
  # Remote access needs the gateway to serve TLS: the ingress gateway
  # re-encrypts to it and verifies its certificate against the chart CA.
  # Upgrading an install from before 0.10.0? Read "Upgrading to gateway TLS"
  # in step 3 first.
  tls:
    enabled: true

  # OIDC is required for remote access: the chart refuses to publish an
  # unauthenticated gateway.
  oidc:
```

In `docs/production-deployment.md`, replace

```markdown
  # Source addresses allowed through the ingress gateway. Optional for the CLI
  # host (a token is required either way), required for serviceHosts.
```

with

```markdown
  # Source addresses allowed through the ingress gateway. Optional for the CLI
  # host (the gateway asks for a token either way), required for serviceHosts.
```

In `docs/production-deployment.md`, replace

```markdown
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
```

with

````markdown
- Refuse to render if `gatewayIngress.enabled` is set without
  `gateway.oidc.issuer`, `audience` and `clientId` (the chart never publishes
  an unauthenticated gateway), without `gateway.tls.enabled`, without
  `gatewayIngress.domain`, or with `serviceHosts.enabled` and no `allowedCidrs`.

Installing with `gatewayIngress.enabled` creates, in `istio-system`,
AuthorizationPolicies and a Secret with the chart CA's public certificate, so
the installing identity needs rights there. The ingress gateway is shared with
every other application of the cluster, and nothing the chart creates applies
to it as a whole: every policy rule names this release's hosts, and there is no
RequestAuthentication (on an ingress gateway it would answer 401 to every other
application's Bearer tokens). The ingress gateway checks no token. It routes,
re-encrypts to the gateway pod, and fences by source address where you set
`allowedCidrs`; the gateway authenticates every call.

For the first seconds of a first install the gateway host answers 503: a
post-install Job copies the chart CA into `istio-system`, and until then the
ingress gateway cannot verify the gateway pod.

### Upgrading to gateway TLS

An install from before 0.10.0 has a gateway certificate that does not name the
release's Service, which no client can verify, and the PKI hook never replaces
an existing certificate. Before the upgrade that sets `gateway.tls.enabled`,
delete the three PKI Secrets (all three: upstream's generator refuses a partial
set); the upgrade creates them again:

```bash
kubectl -n openshell-system delete secret \
  ods-openshell-driver-kyma-server-tls \
  ods-openshell-driver-kyma-client-tls \
  ods-openshell-driver-kyma-jwt-keys
```

Sandboxes from before the upgrade must be recreated: their pods carry the
plaintext gateway endpoint and tokens of the old signing key.
````

In `docs/production-deployment.md`, replace

```markdown
Either way the result is the same for this chart's hosts: the gateway host is
reached only with a valid token of your issuer (and, with `allowedCidrs`, from
a listed address), and sandbox service hosts only from `allowedCidrs`.
```

with

```markdown
Either way the result is the same for this chart's hosts: sandbox service
hosts are reached only from `allowedCidrs`, and so is the gateway host when
`allowedCidrs` is set. Without `allowedCidrs` the gateway host is open to every
address (under DENY the chart then writes no policy for it), and the gateway's
own token check is the only gate.
```

In `docs/production-deployment.md`, replace

```markdown
# Routes and ingress policies rendered
kubectl -n openshell-system get virtualservice
kubectl -n istio-system get requestauthentication,authorizationpolicy | grep openshell

# The edge refuses a call without a token (403), the CLI gets through
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://openshell.<cluster-domain>/openshell.v1.OpenShell/ListSandboxes
openshell status
```

with

```markdown
# Routes, the TLS rule to the gateway pod, and the ingress policies and CA
kubectl -n openshell-system get virtualservice,destinationrule
kubectl -n istio-system get authorizationpolicy,secret | grep openshell

# The gateway refuses a call without a token (grpc-status: 16), the CLI gets through
curl -s -o /dev/null -D - -X POST -H 'content-type: application/grpc' \
  https://openshell.<cluster-domain>/openshell.v1.OpenShell/ListSandboxes | grep -i grpc-status
openshell status
```

In `docs/production-deployment.md`, replace

```markdown
- **Image upgrades.** Resolve the new digest, edit the values overlay,
```

with

````markdown
- **Port-forward to a gateway that serves TLS.** With `gateway.tls.enabled`
  a port-forwarded gateway is `https://127.0.0.1:8080`, with a certificate of
  the chart's own CA. Register it and give the CLI that CA once
  (`$XDG_CONFIG_HOME` replaces `~/.config` when set):

  ```bash
  openshell gateway add https://127.0.0.1:8080 --name kyma-forward \
    --oidc-issuer <issuer> --oidc-client-id <client-id> --oidc-audience <audience>
  mkdir -p ~/.config/openshell/gateways/kyma-forward/mtls
  kubectl -n openshell-system get secret ods-openshell-driver-kyma-client-tls \
    -o jsonpath='{.data.ca\.crt}' | base64 --decode \
    > ~/.config/openshell/gateways/kyma-forward/mtls/ca.crt
  ```
- **Image upgrades.** Resolve the new digest, edit the values overlay,
````

In `docs/production-deployment.md`, replace

```markdown
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
```

with

```markdown
With `gatewayIngress.serviceHosts.enabled` the service is published at
`https://default--web.<cluster-domain>/`, which is the URL the CLI prints; no
port-forward and no `--resolve`. Clients of the gRPC API or the SDK receive the
gateway's own value, `https://default--web.<cluster-domain>:8080/`, with the
port the gateway binds in its pod: drop the port.

Things to know:

- The gateway does not authenticate a request to a service URL, so these hosts
  are fenced by `gatewayIngress.allowedCidrs` only. Put authentication into the
  service itself if the address ranges are shared.
```

In `docs/production-deployment.md`, replace

```markdown
  service URL through the gateway's Service without passing it, as it always
  could with the port-forward URLs.
- The gateway then binds port 80 in its pod, so that the URL it hands to API
  and SDK clients carries no port. That adds the safe sysctl
  `net.ipv4.ip_unprivileged_port_start=0` to the pod. The in-cluster Service
  port stays `gateway.grpcPort`.
```

with

```markdown
  service URL through the gateway's Service without passing it, as it always
  could with the port-forward URLs.
```

In `docs/production-deployment.md`, replace

```markdown
- **Managed mode**: the gateway id (default: the release fullname) must be at
```

with

```markdown
- **Gateway TLS with Istio-injected sandboxes** (`gateway.tls.enabled`, which
  `gatewayIngress` requires, together with `driver.istioInjectSandboxes`): not
  verified. A sandbox's sidecar may treat the gateway Service's `grpc` port as
  plaintext HTTP/2 and break the supervisor's TLS connection to the gateway.
  Create a sandbox on your cluster before you rely on the combination.
- **Managed mode**: the gateway id (default: the release fullname) must be at
```

In `docs/getting-started.md`, replace

```markdown
gateway through the cluster's Istio ingress gateway: set
`gatewayIngress.enabled=true`, `gatewayIngress.domain` and
`gateway.oidc.{issuer,audience,clientId}`. The chart refuses to publish an
unauthenticated gateway. `gatewayIngress.serviceHosts.enabled` additionally
publishes the URLs `openshell service expose` prints. See
```

with

```markdown
gateway through the cluster's Istio ingress gateway: set
`gatewayIngress.enabled=true`, `gatewayIngress.domain`,
`gateway.tls.enabled=true` and `gateway.oidc.{issuer,audience,clientId}`. The
gateway authenticates every call with OIDC, and the chart refuses to publish an
unauthenticated one. `gatewayIngress.serviceHosts.enabled` additionally
publishes the URLs `openshell service expose` prints. An install from before
0.10.0 must delete its PKI Secrets first ("Upgrading to gateway TLS" there). See
```

In `docs/getting-started.md`, replace

```markdown
The chart refuses to render `inferenceProvider.enabled` together with
`gateway.oidc.issuer`: the Job calls the gateway without a token, which a
gateway with OIDC refuses. With OIDC, register the profile and provider from
an authenticated CLI session instead; see
[`production-deployment.md`](production-deployment.md), step 3b.
```

with

```markdown
With `gateway.oidc.issuer` the Job logs in with the client-credentials grant
and needs `gateway.oidc.clientCredentialsSecret`; without a client secret,
register the profile and provider from an authenticated CLI session instead;
see [`production-deployment.md`](production-deployment.md), step 3b.
```

In `docs/openshell-api-programmatic-usage.md`, replace

```markdown
`https://openshell.<cluster-domain>`. The ingress gateway requires a valid
token of the issuer (and, with `gatewayIngress.allowedCidrs`, a source address
in it) before forwarding; the gateway validates the same token again. Native
gRPC clients dial the `:443` HTTPS endpoint with `authorization: Bearer <token>`.
```

with

```markdown
`https://openshell.<cluster-domain>`. The gateway validates the token of every
call; the ingress gateway checks none, and with `gatewayIngress.allowedCidrs`
admits only those source addresses. Native gRPC clients dial the `:443` HTTPS
endpoint with `authorization: Bearer <token>`. A sandbox service URL the API
returns carries the port the gateway binds in its pod (`:8080`); through the
ingress gateway, drop the port.
```

In `docs/kyma-vs-openshift.md`, replace

```markdown
`gatewayIngress` publishes the gateway behind OIDC (VirtualService + ingress policies) |
```

with

```markdown
`gatewayIngress` publishes the gateway, which authenticates with OIDC (VirtualService, TLS from the ingress gateway to the gateway pod, source-address policies) |
```

In `docs/tutorial-anthropic-direct.md`, replace

```markdown
  internet** (no port-forward). Set `gatewayIngress.enabled=true` and
  `gateway.oidc.issuer`. See
```

with

```markdown
  internet** (no port-forward). Set `gatewayIngress.enabled=true`,
  `gateway.tls.enabled=true` and `gateway.oidc`. See
```

In `CHANGELOG.md`, replace everything from the line that begins (after its indentation) with

```text
## [0.10.0]
```

through the next line that begins with

```text
| (none) | `gateway.oidc.clientId` (required with `gatewayIngress`) |
```

(both lines included) with:

````markdown
## [0.10.0] — unreleased

**UPGRADE NOTE: `gatewayApirule` is removed.** Move to `gatewayIngress` (table
below) before `helm upgrade`; the chart refuses a values file that still enables
`gatewayApirule`, so the gateway cannot silently lose its public route.

**UPGRADE NOTE: turning on `gateway.tls.enabled`, which `gatewayIngress`
requires, needs a new PKI on an existing install, once.** The PKI hook creates
the gateway's certificate at the first install and never replaces it, and until
this release it did not put the release's Service names into it, so no client
could verify it. Before the upgrade that enables gateway TLS, delete the three
PKI Secrets (all three: upstream's generator refuses a partial set); the upgrade
creates them again:

```bash
kubectl -n <namespace> delete secret \
  <fullname>-server-tls <fullname>-client-tls <fullname>-jwt-keys
```

Sandboxes from before that upgrade must be recreated: their pods carry the
plaintext gateway endpoint and tokens of the old signing key. Installs that keep
gateway TLS off need nothing.

### Added

- **Remote access (`gatewayIngress`)**: publishes the gateway through the
  cluster's Istio ingress gateway, the way upstream intends a Kubernetes gateway
  to be reached, so the `openshell` CLI works without a port-forward. The
  gateway is the only authenticator: it serves TLS (`gateway.tls.enabled`,
  required) and validates every caller's OIDC token itself. The ingress gateway
  terminates the client's TLS, routes `openshell.<domain>` (a VirtualService),
  re-encrypts to the gateway pod and verifies its certificate against the chart
  CA (a DestinationRule; a post-install Job, which may write that one Secret
  only, copies the CA's public certificate into `istio-system`). This is
  upstream's `grpcRoute` with `backendTLSPolicy`, written for Istio. The chart
  refuses to publish a gateway without `gateway.oidc.{issuer,audience,clientId}`.
- **Nothing the chart renders applies to the shared ingress gateway as a
  whole.** It creates no RequestAuthentication (on an ingress gateway one
  answers 401 to every other application's Bearer tokens), and every
  AuthorizationPolicy rule names this release's hosts. `allowedCidrs` is an
  optional source-address fence for the gateway host.
- **`gatewayIngress.policyAction`** chooses how the policies are written:
  `DENY` (default) for an ingress gateway without ALLOW policies, naming only
  the chart's own hosts and leaving every other host alone; `ALLOW` for a
  gateway that already allowlists per host. An ALLOW policy on a gateway
  without any would make it deny every other application's hosts; see
  production-deployment before choosing.
- **Published service URLs (`gatewayIngress.serviceHosts`)**:
  services exposed with `openshell service expose` are reachable at
  `https://<workspace>--<sandbox>.<domain>/`, the URL the CLI prints, routed to
  the gateway and fenced by `allowedCidrs` (required: the gateway does not
  authenticate a request to a service URL). Published per workspace
  (`serviceHosts.workspaces`, default `[default]`): routes and policies match
  `<workspace>--*`, never the whole domain. API and SDK clients receive the
  gateway's own URL, with the port it binds in its pod (`:8080`); drop the port.
- **`gateway.oidc.authOnly`**, `rolesClaim`, `clientId` and
  `clientCredentialsSecret`. `authOnly: true` selects upstream's
  authentication-only mode (both roles passed empty; every authenticated
  identity is then a platform admin); `adminRole` and
  `userRole` must now be set together.
- **`networkPolicy.extraEgress`**: extra egress rules for the driver+gateway
  pod, for destinations that are not on 443 from the pod's point of view, such
  as an OIDC issuer published through the cluster's own ingress gateway.
- **`inferenceProvider` with OIDC, and with gateway TLS**: the provider hook
  logs in with the client-credentials grant when
  `gateway.oidc.clientCredentialsSecret` names the client secret (and, for
  providers with a separate confidential client, its `clientId`), and against a
  gateway that serves TLS it dials `https://` and trusts the chart CA. Both
  pairs were refused before; the provider with gateway TLS but without OIDC
  still is.
- `e2e/keycloak`: a Keycloak test identity provider for clusters without one
  (upstream's development realm, no credential in the repository), with its
  own test.
- `scripts/remote-access-check.sh`, the live acceptance check. While it
  upgrades a release it watches other applications behind the same ingress
  gateway, and rolls the release back if one of them starts answering
  differently; `scripts/remote-access-check-test.sh` tests that without a
  cluster. And a flag check in `scripts/check-gateway-config.sh` (the pinned
  gateway image must know every flag the chart renders).

### Fixed

- **`gateway.tls.enabled` produced a certificate no client could verify.** The
  PKI hook now passes the release's Service names and loopback to upstream's
  certificate generator, as upstream's own chart does; before, the certificate
  carried only upstream's default names (`openshell`, `openshell.openshell.svc`,
  …). Existing installs: see the upgrade note.

### Removed

- **`gatewayApirule`** and its APIRule template: never verified, and APIRule v2
  needs an Istio sidecar on the gateway pod.

### Values migration

| 0.9.x | 0.10.0 |
|---|---|
| `gatewayApirule.enabled` | `gatewayIngress.enabled` |
| `gatewayApirule.host: openshell.<domain>` | `gatewayIngress.domain: <domain>` (and `host` only if it is not `openshell.<domain>`) |
| `gatewayApirule.gateway` | `gatewayIngress.istioGateway` |
| `gatewayApirule.rules[].jwt.authentications[].issuer` | `gateway.oidc.issuer` (the gateway validates tokens; the ingress gateway does not) |
| (none) | `gateway.oidc.clientId` and `gateway.tls.enabled: true` (required with `gatewayIngress`) |
````

In `docs/superpowers/plans/2026-09-30-remote-gateway-access.md`, insert after the first line (`# Remote Gateway Access Implementation Plan`):

```markdown

> **Superseded.** This plan implemented revision 1 of the design, which was withdrawn (it put a `RequestAuthentication` on a shared ingress gateway). See `2026-10-01-remote-gateway-access-rev2.md`.
```

- [ ] **Step 2: Search for what must be gone**

```bash
grep -rn -iE "jwksUri|JWKS_URI|requestPrincipal|at the edge|ip_unprivileged_port_start|:443/|binds? (port )?80|same token again|behind OIDC|gatewayBindPort" \
  --include='*.md' --include='*.yaml' --include='*.yml' --include='*.txt' --include='*.sh' --include='*.tpl' \
  README.md CHANGELOG.md docs e2e scripts deploy .github | grep -v '^docs/superpowers/'
```

Expected: exactly the two lines of `scripts/check-chart-render.sh` that assert `gateway.oidc.jwksUri` is gone.

```bash
grep -rn "RequestAuthentication" README.md CHANGELOG.md docs e2e deploy | grep -v '^docs/superpowers/'
```

Expected: only sentences that say there is none and why (`docs/production-deployment.md`, `CHANGELOG.md`, the comment in `templates/gateway-ingress-auth.yaml`).

- [ ] **Step 3: Run every check once more**

Run: `KUBECONFIG=/dev/null ./scripts/check-chart-render.sh 2>&1 | tail -30`
Expected: last line `CHART_RENDER_OK`

Run: `KUBECONFIG=/dev/null helm lint deploy/helm/openshell-driver-kyma && ./scripts/remote-access-check-test.sh | tail -1`
Expected: `1 chart(s) linted, 0 chart(s) failed` and `REMOTE_ACCESS_SELFTEST_OK`

Run: `grep -c ':443/' deploy/helm/openshell-driver-kyma/templates/NOTES.txt`
Expected: `0`

- [ ] **Step 4: Commit**

```bash
git add deploy/helm/openshell-driver-kyma/templates/NOTES.txt \
  deploy/helm/openshell-driver-kyma/values.example.yaml \
  docs/production-deployment.md \
  docs/getting-started.md \
  docs/openshell-api-programmatic-usage.md \
  docs/kyma-vs-openshift.md \
  docs/tutorial-anthropic-direct.md \
  CHANGELOG.md \
  docs/superpowers/plans/2026-09-30-remote-gateway-access.md
git diff --cached --stat
git commit -m "docs: remote access with the gateway as the only authenticator; 0.10.0 changelog" \
  -m "Co-Authored-By: <the committing model's name> <noreply@anthropic.com>"
```


### Task 7 (gated, run by the controller with the user): live acceptance and release

Every step here is outward-facing or touches the live cluster. Stop and get the user's explicit approval before each step marked **[approval]**; approval of one step does not carry to the next. No subagent runs any of it. The final whole-branch review of Tasks 1 to 6 is complete, and its fixes committed, before Step 1.

**Files:** none. A fix found live goes through a normal commit on the branch, with the checks of Task 6 Step 3 re-run, and a new release candidate.

**Interfaces:**
- Consumes: branch `feat/remote-gateway-access` with Tasks 1 to 6; `scripts/remote-access-check.sh`; the Keycloak test identity provider of `e2e/keycloak` on the cluster. From the user, at run time, on the command line only and never in a file, a log, a commit or a prompt: the cluster domain, the URLs of the cluster's other applications behind the ingress gateway, and the source CIDRs (read at run time from the cluster's existing ingress allowlist policy).
- Produces: release `v0.10.0`.

- [ ] **Step 1 [approval]: Push the branch**

```bash
git fetch origin --prune --tags
gh auth status            # the active account must be st-gr
git log --oneline origin/feat/remote-gateway-access..HEAD
git push origin feat/remote-gateway-access
gh pr checks 81 --watch
```

Expected: every check of PR #81 green, including `helm-lint` with its new step. Then, with approval, replace the PR's title and description: they describe revision 1 (`gh pr edit 81 --title … --body-file …`; the description ends with the attribution line of the repository's convention).

- [ ] **Step 2 [approval]: Release candidate image**

```bash
git tag v0.10.0-rc.2 && git push origin v0.10.0-rc.2
gh run watch "$(gh run list --workflow release-tag.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
DIGEST=$(docker buildx imagetools inspect ghcr.io/st-gr/openshell-driver-kyma:v0.10.0-rc.2 | awk '/^Digest:/ { print $2 }')
docker manifest inspect "ghcr.io/st-gr/openshell-driver-kyma@$DIGEST" >/dev/null && echo "$DIGEST"
```

Expected: one `sha256:` digest, taken from the registry (never from the workflow's log). Put it into the values file used for the live run, which lives outside the repository.

- [ ] **Step 3: Look before touching (read-only)**

```bash
export KUBECONFIG=<the kubeconfig>
helm -n openshell-system list                                   # the release and its revision: the way back
kubectl -n keycloak get deploy,pods                             # the test identity provider is up
kubectl -n istio-system get requestauthentication               # none of this release
openshell --gateway <port-forward gateway> sandbox list         # sandboxes that will have to be recreated
scripts/ingress-non-http-servers.sh                             # TCP / TLS-passthrough servers on the ingress gateway: none expected
OSH_PROBE_ONLY=1 OSH_NEIGHBOUR_URLS=<url>,<url>,<url> scripts/remote-access-check.sh | tee "$HOME/.cache/neighbours.before"
```

Expected: one probe line per neighbour and kind, each with the status the application gives today and `-` as origin. Show them to the user. The neighbour list has one URL per other application behind the ingress gateway. Choose URLs that answer all three probes the same way with a 2xx or 3xx (a login page, a public config endpoint): on a URL that already answers 401 or 403 to a Bearer probe a change shows only through the origin column, and a URL that cannot be reached is refused. (Corrected after the whole-branch review, which also added: `scripts/ingress-non-http-servers.sh` must print nothing here, and Step 4 passes `OSH_POLICY_ACTION` explicitly.)

- [ ] **Step 4 [approval]: Run the live check**

Tell the user first what it will do: delete and regenerate the release's three PKI Secrets (existing sandboxes must be recreated), upgrade the release to the release candidate with `gatewayIngress` and gateway TLS, and roll back by itself if a neighbour's answer changes.

```bash
OSH_DOMAIN=<domain> OSH_ALLOWED_CIDRS=<cidrs> OSH_POLICY_ACTION=ALLOW \
OSH_OIDC_ISSUER=https://keycloak.<domain>/realms/openshell OSH_OIDC_CLIENT_ID=openshell-cli \
OSH_HOOK_CLIENT_ID=openshell-ci OSH_CLIENT_SECRET=openshell-oidc-client \
OSH_VALUES=<values file with the rc digest> OSH_EXTRA_VALUES=e2e/keycloak/values.yaml \
OSH_NEIGHBOUR_URLS=<url>,<url>,<url> OSH_REGENERATE_PKI=1 OSH_CHECK_IDLE=1 \
  scripts/remote-access-check.sh
```

(`OSH_POLICY_ACTION=ALLOW` because this cluster's ingress gateway already allowlists per host. The browser login is the user's: user `dev`, password read from the cluster into the clipboard, never printed.)

Expected: `REMOTE_ACCESS_OK`, with among others

```text
PASS  <n> neighbour probes unchanged by the upgrade
PASS  no RequestAuthentication of this release on the ingress gateway (found 0)
PASS  istio-system/<…>-gateway-ca holds the chart CA
PASS  a gRPC call without a bearer is refused by the gateway (grpc-status 16, want 16)
PASS  service expose prints https://default--rac-web.<domain>/ (printed: …)
PASS  the ingress gateway does not take the client address from a client's X-Forwarded-For header (HTTP 200, want 200)
PASS  provider <name> is registered: the hook's login worked and it trusted the chart CA
PASS  an exec stream idle for 400 s survives
PASS  the neighbours answer as before the run
```

If the script rolled back: stop. Report the probe lines that changed to the user, do not re-run, and go back to the design.

If a check fails otherwise, find the cause before changing anything (the spec's §13 lists the unproven points and their fallbacks: the CA Secret's key, HTTP/1.1 over TLS to the pod, the CLI's CA directory, the supervisors' certificate check). A fix is a commit, the checks, and a new release candidate; this step is then run again from Step 2.

- [ ] **Step 5: Confirm with the user that their other applications work**

Ask the user to log in to each neighbouring application once, in a browser. The probes cover status codes; the incident of revision 1 showed as a login loop. Compare once more:

```bash
OSH_PROBE_ONLY=1 OSH_NEIGHBOUR_URLS=<url>,<url>,<url> OSH_PROBE_BASELINE="$HOME/.cache/neighbours.before" \
  scripts/remote-access-check.sh; rm -f "$HOME/.cache/neighbours.before"
```

Expected: the same lines as in Step 3 and exit status 0.

- [ ] **Step 6 [approval]: Release**

With the user's decision on each: whether remote access stays enabled on the cluster or the release goes back to its values file (`OSH_REVERT=1` with `OSH_SKIP_INSTALL=1`), and whether the Keycloak test identity provider is removed (`OSH_DELETE=1 e2e/keycloak/deploy.sh`).

```bash
# on the branch: the release date
sed -i.bak 's/^## \[0.10.0\] — unreleased$/## [0.10.0] — <today, YYYY-MM-DD>/' CHANGELOG.md && rm CHANGELOG.md.bak
git add CHANGELOG.md && git diff --cached --stat
git commit -m "docs: 0.10.0 release date" -m "Co-Authored-By: <the committing model's name> <noreply@anthropic.com>"
git push origin feat/remote-gateway-access && gh pr checks 81 --watch
gh pr merge 81 --squash
git fetch origin && git tag v0.10.0 origin/main && git push origin v0.10.0
DIGEST=$(docker buildx imagetools inspect ghcr.io/st-gr/openshell-driver-kyma:v0.10.0 | awk '/^Digest:/ { print $2 }')
docker manifest inspect "ghcr.io/st-gr/openshell-driver-kyma@$DIGEST" >/dev/null && echo "$DIGEST"
```

Expected: PR #81 merged, tag `v0.10.0` on `main`, the release workflow green, one registry digest. Deploying that digest to the cluster is a `helm upgrade` with the user's values and its own approval; after it, Step 5's comparison is run once more.
