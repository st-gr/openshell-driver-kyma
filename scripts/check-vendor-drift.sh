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
# Five things are checked:
#
#   1. local (header + local patch reversed) == upstream at the pinned commit
#      -> catches someone hand-editing the vendored file body
#   2. recorded sha256 == upstream at the pinned commit
#      -> catches a lock file edited to match a doctored local copy
#   3. the "VENDOR LOCAL PATCH" block, once reversed, must exactly reproduce
#      the one line it replaces (`use crate::container_paths::...`)
#      -> catches the patch reversal itself silently going stale
#   4. the CONTROL_ROOTS and OCI_RUNTIME_MOUNT_ROOTS *values* inside the
#      "VENDOR LOCAL PATCH" block, resolved and compared in order against
#      upstream's crates/openshell-core/src/container_paths.rs (a `kind =
#      "constants"` [[files]] entry — see UPSTREAM.lock), must match
#      -> catches an edit *inside* the patch block itself (e.g. dropping
#         "/run/openshell"), which (1)-(3) cannot see because the patch
#         block is deliberately excluded from the byte-for-byte comparison
#   5. the provenance header's `commit:` line == the `commit` pinned in
#      UPSTREAM.lock
#      -> catches a falsified header, which is otherwise stripped by
#         header_lines before any of the above ever sees it
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

# Resolve upstream container_paths.rs's CONTROL_ROOTS (a list of named
# constants) and OCI_RUNTIME_MOUNT_ROOTS (already literals) to their ordered
# string values, one `NAME value` pair per line. Fails loudly if an
# identifier in CONTROL_ROOTS has no matching `pub const NAME: &str = "..."`
# — better than silently comparing an empty list.
extract_upstream_constants() {
	awk '
		/^pub const [A-Za-z_0-9]+: &str = "/ {
			line = $0
			sub(/^pub const /, "", line)
			name = line
			sub(/:.*/, "", name)
			val = line
			sub(/^[^"]*"/, "", val)
			sub(/".*/, "", val)
			names[name] = val
		}
		/^pub const CONTROL_ROOTS: &\[&str\] = &\[/ { in_control = 1; next }
		in_control {
			if ($0 ~ /\];/) { in_control = 0; next }
			line = $0
			sub(/\/\/.*/, "", line)
			gsub(/[ \t,]+/, " ", line)
			gsub(/^ +| +$/, "", line)
			if (line != "") control_order[++cn] = line
			next
		}
		/^pub const OCI_RUNTIME_MOUNT_ROOTS: &\[&str\] = &\[/ {
			line = $0
			sub(/^.*&\[/, "", line)
			sub(/\];.*$/, "", line)
			m = split(line, parts, ",")
			for (i = 1; i <= m; i++) {
				v = parts[i]
				gsub(/^[ \t"]+|[ \t"]+$/, "", v)
				if (v != "") oci_order[++on] = v
			}
		}
		END {
			for (i = 1; i <= cn; i++) {
				id = control_order[i]
				if (!(id in names)) {
					print "ERROR: unresolved identifier " id " in upstream CONTROL_ROOTS" > "/dev/stderr"
					exit 1
				}
				print "CONTROL_ROOTS " names[id]
			}
			for (i = 1; i <= on; i++) print "OCI_RUNTIME_MOUNT_ROOTS " oci_order[i]
		}
	' "$1"
}

# Same extraction for the local "VENDOR LOCAL PATCH" block, where both
# arrays are already string literals.
extract_local_constants() {
	awk '
		/^\/\/ --- BEGIN VENDOR LOCAL PATCH ---$/ { in_patch = 1; next }
		/^\/\/ --- END VENDOR LOCAL PATCH ---$/ { in_patch = 0; next }
		!in_patch { next }
		/^const CONTROL_ROOTS: &\[&str\] = &\[/ { in_control = 1; next }
		in_control {
			if ($0 ~ /\];/) { in_control = 0; next }
			line = $0
			gsub(/[ \t,"]+/, " ", line)
			gsub(/^ +| +$/, "", line)
			if (line != "") print "CONTROL_ROOTS " line
			next
		}
		/^const OCI_RUNTIME_MOUNT_ROOTS: &\[&str\] = &\[/ {
			line = $0
			sub(/^.*&\[/, "", line)
			sub(/\];.*$/, "", line)
			m = split(line, parts, ",")
			for (i = 1; i <= m; i++) {
				v = parts[i]
				gsub(/^[ \t"]+|[ \t"]+$/, "", v)
				if (v != "") print "OCI_RUNTIME_MOUNT_ROOTS " v
			}
		}
	' "$1"
}

# The provenance header's `commit:` line, stripped by header_lines before
# every other check runs — so it needs its own, separate assertion against
# the commit pinned in UPSTREAM.lock.
header_commit_of() {
	sed -n 's/^\/\/[[:space:]]*commit:[[:space:]]*//p' "$1" | head -1
}

# Parse the [[files]] entries: upstream_path / local_path / kind / sha256.
# kind defaults to "file" (byte-for-byte, via reverse_local_patch); a
# "constants" entry compares resolved CONTROL_ROOTS / OCI_RUNTIME_MOUNT_ROOTS
# values instead, and has no local file of its own to fetch from upstream.
while read -r upstream_path local_path kind recorded_sha; do
	[[ -n $upstream_path ]] || continue

	if [[ ! -f $local_path ]]; then
		printf '  MISSING  %s (declared in %s)\n' "$local_path" "$LOCK"
		status=1
		continue
	fi

	fetch_upstream "$commit" "$upstream_path" >"$tmp/upstream"

	if [[ $kind == constants ]]; then
		label="$local_path (CONTROL_ROOTS/OCI_RUNTIME_MOUNT_ROOTS values, vs $upstream_path)"
		extract_upstream_constants "$tmp/upstream" >"$tmp/upstream_extracted"
		extract_local_constants "$local_path" >"$tmp/local_extracted"
		upstream_sha=$(sha256_of "$tmp/upstream_extracted")
		local_sha=$(sha256_of "$tmp/local_extracted")
	else
		label="$local_path"
		upstream_sha=$(sha256_of "$tmp/upstream")
		strip_header "$local_path" "$header_lines" | reverse_local_patch >"$tmp/local"
		local_sha=$(sha256_of "$tmp/local")

		header_commit=$(header_commit_of "$local_path")
		if [[ -n $header_commit && $header_commit != "$commit" ]]; then
			printf '  DRIFT    %s: provenance header commit (%s) does not match %s commit (%s)\n' \
				"$local_path" "$header_commit" "$LOCK" "$commit"
			status=1
		fi
	fi

	if [[ $local_sha != "$upstream_sha" ]]; then
		printf '  DRIFT    %s\n' "$label"
		printf '           vendored (header + local patch reversed): %s\n' "$local_sha"
		printf '           upstream @ %s:  %s\n' "${commit:0:12}" "$upstream_sha"
		if [[ $kind == constants ]]; then
			diff -u "$tmp/upstream_extracted" "$tmp/local_extracted" || true
		else
			diff -u "$tmp/upstream" "$tmp/local" | head -40 || true
		fi
		status=1
	elif [[ $recorded_sha != "$upstream_sha" ]]; then
		printf '  STALE    %s: %s records %s but upstream is %s\n' \
			"$label" "$LOCK" "$recorded_sha" "$upstream_sha"
		status=1
	else
		printf '  ok       %s\n' "$label"
	fi
done < <(awk '
	/^\[\[files\]\]/      { u=""; l=""; s=""; k="file"; next }
	/^upstream_path/      { gsub(/.*= *"|"/, ""); u=$0; next }
	/^local_path/         { gsub(/.*= *"|"/, ""); l=$0; next }
	/^kind/                { gsub(/.*= *"|"/, ""); k=$0; next }
	/^sha256/             { gsub(/.*= *"|"/, ""); s=$0; print u, l, k, s; next }
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
