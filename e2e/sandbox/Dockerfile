# Minimal sandbox base image used by `make e2e-cli`.
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

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         curl \
         iproute2 \
         nftables \
         ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1000660000 sandbox \
    && useradd -m -u 1000660000 -g sandbox sandbox

RUN install -d -o sandbox -g sandbox /sandbox
WORKDIR /sandbox

# The OpenShell supervisor replaces CMD at runtime; this default is just
# so the image can be `docker run` standalone for sanity-checking.
CMD ["/bin/bash"]
