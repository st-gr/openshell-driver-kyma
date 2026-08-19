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

# ---------------------------------------------------------------------------
# Advisory: is upstream ahead of the pin?
#
# Everything above compares against the PINNED ref, so it stays green forever
# while upstream moves on — by design, since bumping the pin must be a
# deliberate commit. The cost is that "six releases behind" is invisible.
# That is the same blind spot that let the original vendoring drift for two
# months, so report it here.
#
# Deliberately non-fatal: an upstream release is not a defect in this repo,
# and failing the build on someone else's tag push would make CI red for
# reasons no PR can fix. It escalates the *wording* — not the exit code —
# when the contract actually differs.
#
# Every exit path below also prints a `VENDOR_TARGET_TAG: <tag>` line: the
# tag a re-vendor should target, as distinct from GATEWAY_REF (which pins
# the gateway *image*, not the contract, and can legitimately sit behind or
# ahead of it — see upstream-sync.yml's "Set proto contract target tag"
# step, which parses this line rather than reusing GATEWAY_TAG). It is
# always $ref except in the one case where upstream is genuinely ahead.
# ---------------------------------------------------------------------------
echo
latest=$(latest_upstream_tag || true)

if [[ -z $latest ]]; then
	printf 'Note: could not reach upstream to check for newer releases.\n'
	printf '      The pinned-ref check above still passed.\n'
	# Nothing indicates upstream moved, so the safe vendor target is the
	# tag already pinned -- see VENDOR_TARGET_TAG below.
	printf 'VENDOR_TARGET_TAG: %s\n' "$ref"
	exit 0
fi

if [[ $latest == "$ref" ]]; then
	printf 'Pin is current: %s is the latest upstream release.\n' "$ref"
	printf 'VENDOR_TARGET_TAG: %s\n' "$ref"
	exit 0
fi

# `sort -V | tail -1` picking $ref means the pin is at or ahead of $latest —
# e.g. pinned to a release candidate upstream has not tagged as latest yet.
newest=$(printf '%s\n%s\n' "$ref" "$latest" | sort -V | tail -1)
if [[ $newest == "$ref" ]]; then
	printf 'Pin (%s) is at or ahead of the latest upstream tag (%s).\n' "$ref" "$latest"
	# Never regress: the pin is already the newest thing worth vendoring to.
	printf 'VENDOR_TARGET_TAG: %s\n' "$ref"
	exit 0
fi

behind=$(git ls-remote --tags "$UPSTREAM_REPO_DEFAULT" 'v*' 2>/dev/null |
	awk '{print $2}' | sed 's#refs/tags/##; s/\^{}$//' |
	grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V -u |
	awk -v a="$ref" -v b="$latest" '$0>a && $0<=b' | wc -l | tr -d ' ')

printf 'ADVISORY: upstream is at %s; this repo is pinned to %s (%s release(s) behind).\n' \
	"$latest" "$ref" "$behind"

# Does the contract actually differ, or is it just a version number?
latest_commit=$(upstream_tag_commit "$latest")
contract_changed=0
if [[ -n $latest_commit ]]; then
	while read -r upstream_path local_path recorded_sha; do
		[[ -n $upstream_path ]] || continue
		if ! fetch_upstream "$latest_commit" "$upstream_path" >"$tmp/latest" 2>/dev/null; then
			continue
		fi
		if [[ "$(sha256_of "$tmp/latest")" != "$recorded_sha" ]]; then
			printf '          CHANGED: %s differs at %s\n' "$upstream_path" "$latest"
			contract_changed=1
		fi
	done < <(awk '
		/^\[\[files\]\]/ { u=""; l=""; s=""; next }
		/^upstream_path/ { gsub(/.*= *"|"/, ""); u=$0; next }
		/^local_path/    { gsub(/.*= *"|"/, ""); l=$0; next }
		/^sha256/        { gsub(/.*= *"|"/, ""); s=$0; print u, l, s; next }
	' "$LOCK")
fi

if [[ $contract_changed -eq 1 ]]; then
	cat <<EOF

          The driver contract itself changed between ${ref} and ${latest}.
          Review the diff before upgrading the gateway past ${ref}:
              git diff ${ref}..${latest} -- proto/    # in an OpenShell clone
          Adopt with:
              make proto-vendor TAG=${latest} && make proto && make test
EOF
else
	printf '          Vendored protos are byte-identical at %s — no contract change.\n' "$latest"
	printf '          Bumping the pin is optional; nothing here is at risk.\n'
fi

printf 'VENDOR_TARGET_TAG: %s\n' "$latest"
exit 0
