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

# Fetch one proto from a pinned upstream commit to stdout.
fetch_upstream() {
	local commit=$1 path=$2
	curl -fsSL "https://raw.githubusercontent.com/NVIDIA/OpenShell/${commit}/${path}" \
		|| die "could not fetch ${path} at ${commit}"
}
