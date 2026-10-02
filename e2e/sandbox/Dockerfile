# Minimal sandbox base image, the base of e2e/sandbox-claude.
#
# The OpenShell supervisor running inside the sandbox pod requires:
#   - a `sandbox` user + group (default; configurable via policy.process.run_as_user)
#   - iproute2 for network-namespace setup (veth pairs, `ip netns`)
#   - nftables for bypass detection (log + reject for direct connections)
#
# Distroless / scratch images won't work — the supervisor needs a real
# rootfs with /usr/sbin/ip, /usr/sbin/nft, glibc, and the standard
# /etc/passwd lookup path.
#
# Use a high UID/GID matching the upstream `bring-your-own-container`
# example — avoids host-UID collisions when user namespaces are off.
#
# Pin the base by digest so a future ubuntu:24.04 retag can't silently
# change what this builds. Resolve a fresh digest with:
#   docker buildx imagetools inspect ubuntu:24.04 \
#     --format '{{json .Manifest.Digest}}'

FROM ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         curl \
         iproute2 \
         nftables \
         ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# uid/gid 10001 is what upstream OpenShell v0.1.2's supervisor runs the
# workload as by default (its run_as_user); a matching passwd entry gives
# `sandbox connect` a named prompt instead of "I have no name!".
RUN groupadd -g 10001 sandbox \
    && useradd -m -u 10001 -g sandbox sandbox

RUN install -d -o sandbox -g sandbox /sandbox
WORKDIR /sandbox

# The OpenShell supervisor replaces CMD at runtime; this default is just
# so the image can be `docker run` standalone for sanity-checking.
CMD ["/bin/bash"]
