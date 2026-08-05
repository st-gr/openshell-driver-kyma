# shellcheck shell=bash
#
# Shared helpers for the proto vendoring/drift scripts.
#
# The vendored protos carry a provenance header that upstream does not have,
# so every comparison has to strip it before hashing. Keeping that logic in
# one place means `vendor-proto.sh` and `check-proto-drift.sh` can never
# disagree about what "the pristine file" means — a disagreement there would
# make CI either permanently red or permanently useless.

set -euo pipefail

UPSTREAM_REPO_DEFAULT="https://github.com/NVIDIA/OpenShell"

# The header is inserted *after* the two SPDX lines so the license banner
# stays at the top of the file where linters and humans expect it.
SPDX_LINES=2

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

# Read a top-level scalar from UPSTREAM.lock, e.g. `lock_get ref`.
lock_get() {
	local key=$1 lock=${2:-proto/UPSTREAM.lock}
	sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" \
		"$lock" | head -1
}

# Strip the provenance header, reproducing the pristine upstream bytes.
# Keeps the SPDX banner, drops the `header_lines` block that follows it.
strip_header() {
	local file=$1 header_lines=$2
	{
		head -n "$SPDX_LINES" "$file"
		tail -n "+$((SPDX_LINES + header_lines + 1))" "$file"
	}
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

# Commit SHA a tag resolves to. Prefers the dereferenced (`^{}`) entry so
# annotated tags yield the commit, not the tag object.
upstream_tag_commit() {
	local tag=$1
	git ls-remote "$UPSTREAM_REPO_DEFAULT" "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null |
		sort -k2 |
		tail -1 |
		awk '{print $1}'
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

# Fetch one proto from a pinned upstream commit to stdout.
fetch_upstream() {
	local commit=$1 path=$2
	curl -fsSL "https://raw.githubusercontent.com/NVIDIA/OpenShell/${commit}/${path}" \
		|| die "could not fetch ${path} at ${commit}"
}
