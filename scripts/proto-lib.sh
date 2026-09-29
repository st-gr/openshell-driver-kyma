# shellcheck shell=bash
#
# Shared helpers for the upstream pin and image-resolution scripts.

set -euo pipefail

UPSTREAM_REPO_DEFAULT="https://github.com/NVIDIA/OpenShell"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# Highest `v*` tag upstream, by version sort. Uses `git ls-remote` rather than
# the GitHub API: no auth, no rate limit, and it works in CI without a token.
# Prints nothing (and returns non-zero) if the network is unavailable — callers
# must treat that as "unknown", never as "up to date".
latest_upstream_tag() {
	git ls-remote --tags "$UPSTREAM_REPO_DEFAULT" 'v*' 2>/dev/null |
		awk '{print $2}' |
		sed 's#refs/tags/##; s/\^{}$//' |
		grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
		sort -V |
		tail -1
}

# Resolve `<repo>:<tag>` to an immutable `<repo>@sha256:<digest>` reference.
# Uses the OCI registry API directly rather than `docker buildx imagetools`
# so this works on a runner with no local Docker daemon state.
#
# Pinning by digest is not cosmetic: a tag is mutable, so testing `:latest`
# would neither be reproducible across re-runs nor safe to write into
# values.yaml.
resolve_image_digest() {
	local repo=$1 tag=$2 token digest
	local path=${repo#ghcr.io/}

	token=$(curl -fsSL "https://ghcr.io/token?scope=repository:${path}:pull&service=ghcr.io" |
		sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
	[[ -n $token ]] || die "could not obtain a pull token for ${repo}"

	digest=$(curl -fsSL -o /dev/null -D - \
		-H "Authorization: Bearer ${token}" \
		-H "Accept: application/vnd.oci.image.index.v1+json" \
		-H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
		-H "Accept: application/vnd.oci.image.manifest.v1+json" \
		-H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
		"https://ghcr.io/v2/${path}/manifests/${tag}" |
		tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]*//p' | tail -1)

	[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "could not resolve ${repo}:${tag} to a digest (got '${digest}')"
	printf '%s@%s\n' "$repo" "$digest"
}

# The upstream NVIDIA/OpenShell tag the workspace links, read from the one-line
# `openshell-driver-kubernetes = { git = "...", tag = "..." }` in Cargo.toml.
pinned_upstream_tag() {
	local root
	root=$(git rev-parse --show-toplevel)
	sed -nE 's/^openshell-driver-kubernetes = \{ git = "[^"]+", tag = "([^"]+)" \}.*/\1/p' \
		"${root}/Cargo.toml" | head -1 | grep .
}
