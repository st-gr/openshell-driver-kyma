#!/usr/bin/env bash
#
# Fail if crates/openshell-driver-kyma/src/vendor/ has drifted from the
# upstream ref pinned in crates/openshell-driver-kyma/src/vendor/UPSTREAM.lock.
#
# Sibling to scripts/check-proto-drift.sh, which guards the vendored protos
# after they drifted six upstream changes unnoticed. This guards vendored
# Rust source the same way, so it does not happen again for driver_mounts.rs.
#
# It is a separate lock file and a separate script rather than an entry in
# proto/UPSTREAM.lock: scripts/vendor-proto.sh rewrites that file wholesale
# on every re-vendor (`mv "$tmp/lock" proto/UPSTREAM.lock`), which would
# silently delete any non-proto entry added to it. There is also no
# `vendor-proto.sh`-style automation for this file — re-vendoring is manual,
# documented in the header of vendor/driver_mounts.rs.
#
# Three things are checked:
#
#   1. local (header + local patch reversed) == upstream at the pinned commit
#      -> catches someone hand-editing the vendored file
#   2. recorded sha256 == upstream at the pinned commit
#      -> catches a lock file edited to match a doctored local copy
#   3. the "VENDOR LOCAL PATCH" block, once reversed, must exactly reproduce
#      the one line it replaces (`use crate::container_paths::...`)
#      -> catches the patch reversal itself silently going stale
#
# Note this compares against the *pinned* commit, so it does not go red
# merely because upstream moved on. Re-vendoring is a deliberate, reviewable
# commit (edit vendor/driver_mounts.rs and vendor/UPSTREAM.lock together).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

cd "${SCRIPT_DIR}/.."

LOCK=crates/openshell-driver-kyma/src/vendor/UPSTREAM.lock
[[ -f $LOCK ]] || die "$LOCK not found"

commit=$(lock_get commit "$LOCK")
ref=$(lock_get ref "$LOCK")
header_lines=$(lock_get header_lines "$LOCK")
[[ -n $commit ]] || die "no commit pinned in $LOCK"
[[ -n $header_lines ]] || die "no header_lines recorded in $LOCK"

printf 'Checking vendored driver source against %s (%s)\n\n' "$ref" "${commit:0:12}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

status=0

# Reverse this file's one documented deviation: the inline
# "VENDOR LOCAL PATCH" block (a local reimplementation of two constants
# upstream imports from a sibling module we do not vendor) is replaced back
# with the single upstream import line it stands in for. Files with no such
# block pass through unchanged.
reverse_local_patch() {
	awk '
		/^\/\/ --- BEGIN VENDOR LOCAL PATCH ---$/ {
			print "use crate::container_paths::{CONTROL_ROOTS, OCI_RUNTIME_MOUNT_ROOTS};"
			skip = 1
			next
		}
		/^\/\/ --- END VENDOR LOCAL PATCH ---$/ { skip = 0; next }
		skip { next }
		{ print }
	'
}

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

	strip_header "$local_path" "$header_lines" | reverse_local_patch >"$tmp/local"
	local_sha=$(sha256_of "$tmp/local")

	if [[ $local_sha != "$upstream_sha" ]]; then
		printf '  DRIFT    %s\n' "$local_path"
		printf '           vendored (header + local patch reversed): %s\n' "$local_sha"
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
Vendored driver source does not match upstream ${ref}.

If upstream changed and you intend to adopt it: re-run the construction
documented in the header of crates/openshell-driver-kyma/src/vendor/driver_mounts.rs
against the new commit, then update
crates/openshell-driver-kyma/src/vendor/UPSTREAM.lock to match.

Do NOT hand-edit files under crates/openshell-driver-kyma/src/vendor/ outside
that process — they are a vendored copy, and undocumented local edits defeat
the one guarantee this check makes.
EOF
	exit 1
fi

printf 'All vendored driver source matches upstream %s.\n' "$ref"
