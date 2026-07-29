#!/usr/bin/env bash
#
# Re-vendor the upstream protos at a given tag and rewrite proto/UPSTREAM.lock.
#
#   scripts/vendor-proto.sh v0.0.91
#   make proto-vendor TAG=v0.0.91
#
# Vendoring by hand is what produced the drift this script exists to prevent:
# the first vendoring recorded no upstream ref at all, so there was nothing to
# check against. Everything this writes — tag, resolved commit SHA, per-file
# checksums — is what `check-proto-drift.sh` later enforces.
#
# After running this, expect the build to break. That is the point: the
# breakage enumerates exactly which call sites the contract change affects.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

cd "${SCRIPT_DIR}/.."

TAG=${1:-}
[[ -n $TAG ]] || die "usage: $0 <upstream-tag>   (e.g. $0 v0.0.91)"

# Files to vendor: upstream path -> local path.
FILES=(
	"proto/compute_driver.proto:proto/compute_driver.proto"
	"proto/options.proto:proto/options.proto"
)

command -v python3 >/dev/null 2>&1 || die "python3 is required to parse the GitHub API response"

# Read `.object.sha` / `.object.type` out of a GitHub git-ref response.
json_object_field() {
	python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["'"$1"'"])'
}

printf 'Resolving %s ...\n' "$TAG"
ref_json=$(curl -fsSL "https://api.github.com/repos/NVIDIA/OpenShell/git/ref/tags/${TAG}") ||
	die "could not resolve tag $TAG (does it exist upstream?)"

commit=$(printf '%s' "$ref_json" | json_object_field sha)
obj_type=$(printf '%s' "$ref_json" | json_object_field type)

# A lightweight tag points straight at a commit; an annotated tag points at a
# tag object that must be dereferenced. Querying the tag-object endpoint
# unconditionally 404s on lightweight tags, so branch on the type.
if [[ $obj_type == tag ]]; then
	commit=$(curl -fsSL "https://api.github.com/repos/NVIDIA/OpenShell/git/tags/${commit}" |
		json_object_field sha) || die "could not dereference annotated tag $TAG"
fi

[[ $commit =~ ^[0-9a-f]{40}$ ]] || die "resolved commit looks wrong: '$commit'"
printf '  %s = %s (%s tag)\n\n' "$TAG" "$commit" "$obj_type"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

vendored_at=$(date -u +%Y-%m-%d)

# The header we prepend, minus the SPDX banner it is inserted after.
make_header() {
	cat <<EOF

// VENDORED from NVIDIA/OpenShell — do not edit by hand.
//   repo:   ${UPSTREAM_REPO_DEFAULT}
//   ref:    ${TAG}
//   commit: ${commit}
// Re-vendor with \`make proto-vendor TAG=<tag>\`; provenance + checksums
// are recorded in proto/UPSTREAM.lock and enforced by CI.
EOF
}
header_lines=$(make_header | wc -l | tr -d ' ')

{
	cat <<'EOF'
# Provenance for protos vendored from NVIDIA/OpenShell.
# Regenerate with: make proto-vendor TAG=<tag>
# Verified in CI by scripts/check-proto-drift.sh.
#
# sha256 values are of the PRISTINE upstream file content, i.e. the vendored
# copy with our provenance header stripped. The check script strips it the
# same way before hashing, so local edits to the body still fail the check.
EOF
	printf 'repo = "%s"\n' "$UPSTREAM_REPO_DEFAULT"
	printf 'ref = "%s"\n' "$TAG"
	printf 'commit = "%s"\n' "$commit"
	printf 'vendored_at = "%s"\n' "$vendored_at"
	printf 'header_lines = %s\n' "$header_lines"
} >"$tmp/lock"

for entry in "${FILES[@]}"; do
	upstream_path=${entry%%:*}
	local_path=${entry##*:}

	fetch_upstream "$commit" "$upstream_path" >"$tmp/pristine"
	sha=$(sha256_of "$tmp/pristine")

	# Reassemble: SPDX banner, provenance header, then the rest verbatim.
	{
		head -n "$SPDX_LINES" "$tmp/pristine"
		make_header
		tail -n "+$((SPDX_LINES + 1))" "$tmp/pristine"
	} >"$local_path"

	printf '  vendored %-32s sha256 %s\n' "$local_path" "$sha"

	{
		printf '\n[[files]]\n'
		printf 'upstream_path = "%s"\n' "$upstream_path"
		printf 'local_path = "%s"\n' "$local_path"
		printf 'sha256 = "%s"\n' "$sha"
	} >>"$tmp/lock"
done

mv "$tmp/lock" proto/UPSTREAM.lock

cat <<EOF

Wrote proto/UPSTREAM.lock (${TAG} = ${commit:0:12}).

Next:
    scripts/check-proto-drift.sh   # should pass immediately
    make proto                     # regenerate Rust bindings
    make test                      # work through the resulting compile errors
EOF
