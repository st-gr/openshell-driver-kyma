# Why an init container for supervisor delivery

## The upstream approach

NVIDIA's Rust Kubernetes driver delivers the supervisor binary by
mounting it from the node filesystem with a `hostPath` volume. The binary
is pre-staged on every node — typically by a DaemonSet or by baking it
into the node image — and pods mount it read-only.

```yaml
volumes:
  - name: supervisor
    hostPath:
      path: /opt/openshell/bin
      type: Directory
```

## Why we diverge on Kyma

Kyma applies Pod Security Admission (PSA). The default `restricted`
profile, and even the `baseline` profile, **prohibit `hostPath`
volumes**. Permitting hostPath in the sandbox namespace would require
either:

- Labeling the namespace `pod-security.kubernetes.io/enforce: privileged`
  (which we already need for the supervisor's elevated capabilities, but
  this still doesn't change that hostPath is not a clean fit),
- A custom validating admission webhook that allowlists this single
  hostPath (operational overhead per cluster), or
- A DaemonSet that pre-stages the binary on every node, with its own
  elevated permissions and lifecycle.

A DaemonSet adds: a separate ServiceAccount, RBAC, image-pull policy,
node affinity rules, upgrade coordination, and a privileged container
running everywhere. None of these are Kyma-specific friction —
they're operational debt anywhere — but they outweigh the cost of just
copying a single binary at pod start.

## Our approach

We use an init container, but the upstream supervisor image is
**distroless** — only `/openshell-sandbox` exists, no `cp`, no `sh`,
no busybox. So the init container invokes the supervisor binary's own
`copy-self` subcommand (the same approach argoexec's emissary uses):
the binary writes itself into an `emptyDir` volume shared with the
agent container, which then mounts it read-only and execs the binary
from there.

```yaml
initContainers:
  - name: supervisor-init
    image: ghcr.io/nvidia/openshell/supervisor:latest
    command:
      - "/openshell-sandbox"
      - "copy-self"
      - "/opt/openshell/bin/openshell-sandbox"
    volumeMounts:
      - name: supervisor-bin
        mountPath: /opt/openshell/bin

containers:
  - name: agent
    command: ["/opt/openshell/bin/openshell-sandbox"]
    volumeMounts:
      - name: supervisor-bin
        mountPath: /opt/openshell/bin
        readOnly: true

volumes:
  - name: supervisor-bin
    emptyDir: {}
```

## Trade-offs

| | hostPath | Init container (ours) |
|---|---|---|
| Works under PSA `restricted` / `baseline` | No | N/A — sandbox ns is `privileged`, but we still avoid hostPath |
| Node pre-staging required | Yes (DaemonSet or node image) | No |
| Cold start cost | None (binary already on node) | One `copy-self` (~15 MB, well under one second) |
| Image pull | None | One pull per node, cached after first |
| Supervisor version | Tied to node-image build | Tied to init container tag (rolling change is `kubectl set image`) |
| BYOC compatibility | Works with any agent image | Works with any agent image |
| Extra cluster permissions | DaemonSet, hostPath admission, SCC/PSA exception | None beyond what the agent itself needs |

The init container approach trades a negligible cold-start cost for a
significantly simpler operational story. No DaemonSet, no node access
beyond what the kubelet already grants, no admission exception just to
deliver a 15 MB binary.

## What still requires `privileged`

The agent container itself runs with `privileged: true`, `runAsUser: 0`,
and the capability set `[SYS_ADMIN, NET_ADMIN, SYS_PTRACE, SYSLOG]`. The
supervisor uses these to set up network namespaces and install Landlock
and seccomp filters — the security boundary OpenShell provides depends on
them. That requirement is independent of how the supervisor binary is
delivered; it's a property of what the supervisor *does*.

The init container approach removes the *additional* exception that
hostPath would require on top of those privileged capabilities. It does
not eliminate the need for the privileged PSA label on the sandbox
namespace.
