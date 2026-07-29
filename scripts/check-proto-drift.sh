#!/usr/bin/env bash
#
# Fail if the vendored protos have drifted from the upstream ref pinned in
# proto/UPSTREAM.lock.
#
# Why this exists: the protos were vendored once on 2026-05-27 recording only
# a content hash — no upstream ref — and nothing compared them against
# upstream afterwards. Six upstream changes accumulated unnoticed, two of them
# wire-breaking. This script is the guard that turns the next such change into
# a red build instead of a silent latent failure.
#
# Two independent things are checked, because either alone can be defeated:
#
#   1. local (header stripped) == upstream at the pinned commit
#      -> catches someone hand-editing a vendored file
#   2. recorded sha256 == upstream at the pinned commit
#      -> catches a lock file edited to match a doctored local copy
#
# Note this compares against the *pinned* commit, so it does not go red merely
# because upstream moved on. Bumping the pin is a deliberate, reviewable commit
# via `make proto-vendor TAG=<tag>`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

cd "${SCRIPT_DIR}/.."

LOCK=proto/UPSTREAM.lock
[[ -f $LOCK ]] || die "$LOCK not found"

commit=$(lock_get commit)
ref=$(lock_get ref)
header_lines=$(lock_get header_lines)
[[ -n $commit ]] || die "no commit pinned in $LOCK"
[[ -n $header_lines ]] || die "no header_lines recorded in $LOCK"

printf 'Checking vendored protos against %s (%s)\n\n' "$ref" "${commit:0:12}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

status=0

# Parse the [[files]] entries: upstream_path / local_path / sha256 triples.
while read -r upstream_path local_path recorded_sha; do
	[[ -n $upstream_path ]] || continue

	if [[ ! -f $local_path ]]; then
		printf '  MISSING  %s (declared in %s)\n' "$local_path" "$LOCK"
		status=1
		continue
	fi

	fetch_upstream "$commit" "$upstream_path" >"$tmp/upstream"
	upstream_sha=$(sha256_of "$tmp/upstream")

	strip_header "$local_path" "$header_lines" >"$tmp/local"
	local_sha=$(sha256_of "$tmp/local")

	if [[ $local_sha != "$upstream_sha" ]]; then
		printf '  DRIFT    %s\n' "$local_path"
		printf '           vendored (header stripped): %s\n' "$local_sha"
		printf '           upstream @ %s:  %s\n' "${commit:0:12}" "$upstream_sha"
		diff -u "$tmp/upstream" "$tmp/local" | head -40 || true
		status=1
	elif [[ $recorded_sha != "$upstream_sha" ]]; then
		printf '  STALE    %s: %s records %s but upstream is %s\n' \
			"$local_path" "$LOCK" "$recorded_sha" "$upstream_sha"
		status=1
	else
		printf '  ok       %s\n' "$local_path"
	fi
done < <(awk '
	/^\[\[files\]\]/      { u=""; l=""; s=""; next }
	/^upstream_path/      { gsub(/.*= *"|"/, ""); u=$0; next }
	/^local_path/         { gsub(/.*= *"|"/, ""); l=$0; next }
	/^sha256/             { gsub(/.*= *"|"/, ""); s=$0; print u, l, s; next }
' "$LOCK")

echo
if [[ $status -ne 0 ]]; then
	cat <<EOF
Vendored protos do not match upstream ${ref}.

If upstream changed and you intend to adopt it:
    make proto-vendor TAG=<new-tag>
    make proto && make test     # expect compile errors to work through

Do NOT hand-edit files under proto/ — they are a vendored copy, and local
edits silently break wire compatibility with the gateway.
EOF
	exit 1
fi

printf 'All vendored protos match upstream %s.\n' "$ref"
